import Foundation
import GRDB

/// Playlist changes OldTunes made through Music (the source list's right-click commands),
/// applied to the index at once. Music's change notification brings a re-ingest about 7 s later
/// that rewrites every playlist from Music's own database; until then the source list shows these.
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
            }
            for (position, slot) in slots.enumerated() where slot.sortIndex != position {
                try db.execute(sql: "UPDATE playlist SET sort_index = ? WHERE id = ?", arguments: [position, slot.id])
            }
            // The next re-ingest must rewrite the playlists from Music even if they hash the same
            // as the last ingest's, or an edit Music never actually made would stay on screen.
            try db.execute(sql: "DELETE FROM meta WHERE key = 'playlists_hash'")
        }
        await Self.postDidChange()
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
