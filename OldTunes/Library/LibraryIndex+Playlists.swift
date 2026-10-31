import Foundation
import GRDB

/// Playlist changes OldTunes made through Music (the source list's right-click commands, and
/// songs added to playlists), applied to the index at once. Music's change notification brings a
/// re-ingest about 7 s later that rewrites every playlist from Music's own database; until then
/// the source list shows these.
extension LibraryIndex {
    func apply(_ edit: PlaylistEdit) async throws {
        try await pool.write { db in
            var slots = try PlaylistSlot.fetchAll(db)
            switch edit {
            case .added(let info, let songsFrom):
                slots.removeAll { $0.id == info.id }
                try db.execute(sql: "DELETE FROM playlist WHERE id = ?", arguments: [info.id])
                try db.execute(sql: """
                    INSERT INTO playlist (id, name, kind, parent_id, track_count, sort_index) VALUES (?, ?, ?, ?, ?, 0)
                    """, arguments: [info.id, info.name, info.kind.storedValue, info.parentID, info.trackCount])
                if let songsFrom {
                    try db.execute(sql: """
                        INSERT INTO playlist_item (playlist_id, song_id, position)
                        SELECT ?, song_id, position FROM playlist_item WHERE playlist_id = ?
                        """, arguments: [info.id, songsFrom])
                }
                PlaylistSlot.place(PlaylistSlot(info), in: &slots)
            case .renamed(let id, let name):
                guard let at = slots.firstIndex(where: { $0.id == id }) else { return }
                var slot = slots.remove(at: at)
                slot.name = name
                try db.execute(sql: "UPDATE playlist SET name = ? WHERE id = ?", arguments: [name, id])
                PlaylistSlot.place(slot, in: &slots)
            case .deleted(let id):
                let doomed = PlaylistSlot.subtree(of: id, in: slots)
                slots.removeAll { doomed.contains($0.id) }
                // playlist_item rows go with them (ON DELETE CASCADE).
                try db.execute(sql: "DELETE FROM playlist WHERE id IN (SELECT value FROM json_each(?))",
                               arguments: [Self.jsonArray(doomed)])
            case .songsRemoved(let id, let persistentIDs):
                try db.execute(sql: """
                    DELETE FROM playlist_item WHERE playlist_id = ? AND song_id IN (
                        SELECT id FROM song WHERE persistent_id IN (SELECT value FROM json_each(?))
                        AND origin = \(Track.Origin.musicLibrary.rawValue)
                    ) AND EXISTS (SELECT 1 FROM playlist WHERE id = ? AND kind = \(PlaylistInfo.Kind.regular.storedValue))
                    """, arguments: [id, Self.jsonArray(persistentIDs), id])
                try db.execute(sql: """
                    UPDATE playlist SET track_count = (SELECT COUNT(*) FROM playlist_item WHERE playlist_id = ?) WHERE id = ?
                    """, arguments: [id, id])
            case .songsAdded(let id, let persistentIDs):
                // After the playlist's last entry, in the order Music took them, repeats kept.
                // The joins leave out what the index can't place: a persistent ID no Music-library
                // song has, and a playlist that isn't a plain one here. A row per ID in VALUES
                // would fail the foreign key instead and roll back the whole edit. An ID left out
                // leaves a gap in the positions, which ordering by position doesn't mind.
                let start = try Int.fetchOne(db, sql: """
                    SELECT COALESCE(MAX(position) + 1, 0) FROM playlist_item WHERE playlist_id = ?
                    """, arguments: [id]) ?? 0
                try db.execute(sql: """
                    INSERT INTO playlist_item (playlist_id, song_id, position)
                    SELECT p.id, s.id, ? + j.key FROM json_each(?) j
                    JOIN song s ON s.persistent_id = j.value AND s.origin = \(Track.Origin.musicLibrary.rawValue)
                    JOIN playlist p ON p.id = ? AND p.kind = \(PlaylistInfo.Kind.regular.storedValue)
                    """, arguments: [start, Self.jsonArray(persistentIDs), id])
                // Counted as ingest counts it: every entry, repeats included.
                try db.execute(sql: """
                    UPDATE playlist SET track_count = (SELECT COUNT(*) FROM playlist_item WHERE playlist_id = ?) WHERE id = ?
                    """, arguments: [id, id])
            }
            for (position, slot) in slots.enumerated() where slot.sortIndex != position {
                try db.execute(sql: "UPDATE playlist SET sort_index = ? WHERE id = ?", arguments: [position, slot.id])
            }
            // The next re-ingest must rewrite the playlists from Music even if they hash the same
            // as the last ingest's, or an edit Music never actually made would stay on screen.
            try db.execute(sql: "DELETE FROM meta WHERE key = 'playlists_hash'")
            // And a re-ingest that read Music's playlists before this edit must not put back what
            // it read over it (replaceMusicLibrary's `playlistStamp`).
            try db.execute(sql: """
                INSERT INTO meta (key, value) VALUES ('playlist_edit_stamp', 1)
                ON CONFLICT (key) DO UPDATE SET value = value + 1
                """)
        }
        // Songs going in, chunk after chunk of a long add, are news only to a list showing that
        // playlist; AppController reloads nothing else for them.
        if case .songsAdded(let id, _) = edit {
            await Self.postDidChange(songsAddedTo: id)
        } else {
            await Self.postDidChange()
        }
    }

    /// How many playlist edits `apply(_:)` has written. A re-ingest reads it just before it reads
    /// Music's playlists and hands it back to `replaceMusicLibrary`: if it has moved by the
    /// write, an edit landed meanwhile that the snapshot may not have.
    func playlistEditStamp() async throws -> Int64 {
        try await pool.read { db in try Self.playlistEditStamp(db) }
    }

    static func playlistEditStamp(_ db: Database) throws -> Int64 {
        try Int64.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'playlist_edit_stamp'") ?? 0
    }
}

/// One playlist row's place in the source list, for re-ordering after an edit.
private struct PlaylistSlot {
    var id: Int64
    var name: String
    var kind: PlaylistInfo.Kind
    var parentID: Int64?
    var sortIndex: Int

    init(_ info: PlaylistInfo) {
        self.init(id: info.id, name: info.name, kind: info.kind, parentID: info.parentID, sortIndex: -1)
    }

    init(id: Int64, name: String, kind: PlaylistInfo.Kind, parentID: Int64?, sortIndex: Int) {
        self.id = id
        self.name = name
        self.kind = kind
        self.parentID = parentID
        self.sortIndex = sortIndex
    }

    static func fetchAll(_ db: Database) throws -> [PlaylistSlot] {
        try Row.fetchAll(db, sql: "SELECT id, name, kind, parent_id, sort_index FROM playlist ORDER BY sort_index")
            .map { PlaylistSlot(id: $0[0], name: $0[1], kind: PlaylistInfo.Kind(storedValue: $0[2]),
                                parentID: $0[3], sortIndex: $0[4]) }
    }

    /// iTunesLibrary lists a folder's playlists as Music shows them: smart ones, then plain ones,
    /// each by name (seen on Noah's library); folders are taken to come first, as in iTunes.
    /// Only the order among one folder's playlists matters to the source list.
    static func place(_ slot: PlaylistSlot, in slots: inout [PlaylistSlot]) {
        let siblings = slots.indices.filter { slots[$0].parentID == slot.parentID }
        if let next = siblings.first(where: { slot.sortsBefore(slots[$0]) }) {
            slots.insert(slot, at: next)
        } else if let last = siblings.last {
            slots.insert(slot, at: last + 1)
        } else {
            slots.append(slot)
        }
    }

    /// `id` and every playlist inside it, at any depth.
    static func subtree(of id: Int64, in slots: [PlaylistSlot]) -> Set<Int64> {
        var found: Set<Int64> = [id]
        var frontier = [id]
        while let parent = frontier.popLast() {
            for slot in slots where slot.parentID == parent && found.insert(slot.id).inserted {
                frontier.append(slot.id)
            }
        }
        return found
    }

    private var rank: Int {
        switch kind {
        case .folder: 0
        case .smart, .genius: 1
        case .regular: 2
        }
    }

    private func sortsBefore(_ other: PlaylistSlot) -> Bool {
        if rank != other.rank { return rank < other.rank }
        return name.localizedStandardCompare(other.name) == .orderedAscending
    }
}
