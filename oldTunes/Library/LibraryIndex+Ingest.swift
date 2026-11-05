import Foundation
import GRDB

/// The writes `LibraryIngest` makes. Each origin has its own upsert, so re-ingesting the Music
/// library can never touch an added-folder row and a folder rescan can never touch a library row.
extension LibraryIndex {
    struct MusicLibraryWrite: Sendable {
        var inserted = 0
        var updated = 0
        var unchanged = 0
        var deleted = 0
        var playlists = 0
        var playlistItems = 0
        /// False when the playlists hashed the same as last time and were left alone.
        var playlistsRewritten = false
        /// True when the snapshot predates an edit or began before Music had time to expose it.
        /// The playlists stay as edited and the ingest schedules another read.
        var playlistsStale = false
        /// Minimum delay before a retry may start a new snapshot, in seconds from this write.
        var playlistRetryAfter: TimeInterval = 0
        var analyzed = false
        var seconds: Double = 0

        /// Whether readers would see anything different.
        var changedIndex: Bool { inserted + updated + deleted > 0 || playlistsRewritten }
    }

    /// Upserts every Music-library song by persistent id (so ids survive re-ingest), deletes the
    /// library rows that are gone, and replaces the playlists. One transaction. Rows whose content
    /// hash is unchanged are not touched at all.
    ///
    /// `playlistStamp` is `playlistEditStamp()` as it stood just before `playlists` were read
    /// from Music. If an edit has been applied since (an Add to Playlist going in, say), the
    /// snapshot may be from before it, and writing it would take the edit off screen until the
    /// next re-ingest. So the playlists are left as they are, and no hash is stored, which makes
    /// that next re-ingest rewrite them. `playlistReadStarted` also protects reads that begin
    /// just after an edit, while iTunesLibrary can still expose the old playlists. Nil stamps
    /// (the benches) write them as before.
    func replaceMusicLibrary(_ records: [SongRecord], playlists: [PlaylistRecord],
                             playlistStamp: Int64? = nil, playlistReadStarted: Date = Date()) async throws -> MusicLibraryWrite {
        let started = Date()
        var result = try await pool.write { db -> MusicLibraryWrite in
            var result = MusicLibraryWrite()
            var existing: [Int64: Int64] = [:]
            let rows = try Row.fetchCursor(db, sql: "SELECT persistent_id, content_hash FROM song WHERE origin = 0")
            while let row = try rows.next() { existing[row[0]] = row[1] }

            let upsert = try db.cachedStatement(sql: Self.musicLibraryUpsertSQL)
            var seen = Set<Int64>()
            seen.reserveCapacity(records.count)
            for record in records {
                guard let pid = record.persistentID else { continue }
                seen.insert(pid)
                let hash = record.contentHash
                switch existing[pid] {
                case hash?: result.unchanged += 1; continue
                case nil: result.inserted += 1
                default: result.updated += 1
                }
                try upsert.execute(arguments: record.arguments(contentHash: hash))
            }

            let gone = Set(existing.keys).subtracting(seen)
            if !gone.isEmpty {
                try db.execute(sql: """
                    DELETE FROM song WHERE origin = 0 AND persistent_id IN (SELECT value FROM json_each(?))
                    """, arguments: [Self.jsonArray(gone)])
                result.deleted = db.changesCount
            }

            // Inserted or deleted songs change the id mapping, so those force a rewrite too. A
            // song deleted meanwhile has already taken its playlist entries with it (cascade).
            result.playlists = playlists.count
            let editedAt = try Double.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'playlist_edited_at'")
            let settling = editedAt.map { playlistReadStarted.timeIntervalSince1970 < $0 + Self.playlistSettleSeconds } ?? false
            if let playlistStamp, try Self.playlistEditStamp(db) != playlistStamp || settling {
                result.playlistsStale = true
                result.playlistRetryAfter = max(0, (editedAt ?? 0) + Self.playlistSettleSeconds - Date().timeIntervalSince1970)
            } else {
                let playlistHash = Self.hash(playlists)
                let storedHash = try Int64.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'playlists_hash'")
                if storedHash != playlistHash || result.inserted + result.deleted > 0 {
                    result.playlistItems = try Self.writePlaylists(playlists, db)
                    try db.execute(sql: "INSERT OR REPLACE INTO meta (key, value) VALUES ('playlists_hash', ?)",
                                   arguments: [playlistHash])
                    result.playlistsRewritten = true
                }
            }
            // Without fresh statistics the planner sorts with a temp b-tree instead of ix_title
            // (§4.2). Only the row count moves the statistics, so skip it when that is unchanged.
            if result.inserted + result.deleted > 0 {
                try db.execute(sql: "ANALYZE")
                result.analyzed = true
            }
            return result
        }
        result.seconds = Date().timeIntervalSince(started)
        return result
    }

    private static func hash(_ playlists: [PlaylistRecord]) -> Int64 {
        var h = StableHasher()
        for playlist in playlists {
            h.combine(playlist.info.id)
            h.combine(playlist.info.name)
            h.combine(playlist.info.kind.storedValue)
            h.combine(playlist.info.parentID)
            h.combine(playlist.sortIndex)
            h.combine(playlist.memberPIDs.count)
            for pid in playlist.memberPIDs { h.combine(pid) }
        }
        return h.value
    }

    private static func writePlaylists(_ playlists: [PlaylistRecord], _ db: Database) throws -> Int {
        try db.execute(sql: "DELETE FROM playlist")   // cascades to playlist_item
        var idByPID: [Int64: Int64] = [:]
        let rows = try Row.fetchCursor(db, sql: "SELECT persistent_id, id FROM song WHERE origin = 0")
        while let row = try rows.next() { idByPID[row[0]] = row[1] }

        let insertPlaylist = try db.cachedStatement(sql: """
            INSERT INTO playlist (id, name, kind, parent_id, track_count, sort_index) VALUES (?, ?, ?, ?, ?, ?)
            """)
        let insertItem = try db.cachedStatement(sql: """
            INSERT INTO playlist_item (playlist_id, song_id, position) VALUES (?, ?, ?)
            """)
        var items = 0
        for playlist in playlists {
            let info = playlist.info
            try insertPlaylist.execute(arguments: [info.id, info.name, info.kind.storedValue, info.parentID,
                                                   info.trackCount, playlist.sortIndex])
            for (position, pid) in playlist.memberPIDs.enumerated() {
                guard let songID = idByPID[pid] else { continue }
                try insertItem.execute(arguments: [info.id, songID, position])
                items += 1
            }
        }
        return items
    }

    /// Stores each song's MusicKit id. Rows MusicKit did not return lose a stale id, so the
    /// resolver never asks for a song the library no longer has. Returns rows that changed.
    ///
    /// Diffed in memory first: this runs on every re-ingest and the ids almost never change, so
    /// it costs one indexed read instead of 15,900 no-op UPDATEs.
    func applyCloudIDs(_ cloudIDs: [Int64: String]) async throws -> Int {
        try await pool.write { db in
            var stale: [(pid: Int64, cloudID: String?)] = []
            let rows = try Row.fetchCursor(db, sql: "SELECT persistent_id, cloud_id FROM song WHERE origin = 0")
            while let row = try rows.next() {
                let pid: Int64 = row[0]
                let stored: String? = row[1]
                let wanted = cloudIDs[pid]
                if stored != wanted { stale.append((pid, wanted)) }
            }
            let update = try db.cachedStatement(sql: "UPDATE song SET cloud_id = ? WHERE persistent_id = ?")
            for (pid, cloudID) in stale { try update.execute(arguments: [cloudID, pid]) }
            return stale.count
        }
    }

    func rowCount(origin: Track.Origin) async throws -> Int {
        try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM song WHERE origin = ?", arguments: [origin.rawValue]) ?? 0
        }
    }

    // MARK: - Added folders

    func folderRoots() async throws -> [String] {
        try await pool.read { db in try String.fetchAll(db, sql: "SELECT path FROM folder_root ORDER BY path") }
    }

    func addFolderRoot(_ path: String) async throws {
        try await pool.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO folder_root (path) VALUES (?)", arguments: [path])
        }
    }

    /// The folder rows under `root`, with what a rescan needs to skip unchanged files.
    func folderFiles(under root: String) async throws -> [String: FolderScanner.FileInfo] {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT location_path, file_size, file_mtime FROM song
                WHERE origin = 1 AND (location_path = ? OR substr(location_path, 1, length(?)) = ?)
                """, arguments: [root, prefix, prefix])
            var out: [String: FolderScanner.FileInfo] = [:]
            for row in rows {
                let path: String = row[0]
                out[path] = FolderScanner.FileInfo(path: path, size: row[1], mtime: row[2])
            }
            return out
        }
    }

    /// Paths Music owns, so a folder scan does not index the same song twice: the files the Music
    /// library lists, plus every file oldTunes handed to Music (whose copy may live elsewhere).
    func musicOwnedPaths() async throws -> Set<String> {
        try await pool.read { db in
            var paths = Set(try String.fetchAll(db, sql: "SELECT location_path FROM song WHERE origin = 0 AND location_path IS NOT NULL"))
            paths.formUnion(try String.fetchAll(db, sql: "SELECT path FROM music_handoff"))
            return paths
        }
    }

    /// Notes a file Music took from File ▸ Add Folder. From now on no folder scan indexes it, and
    /// the song shows once, through the Music library.
    func recordHandoff(path: String, persistentID: Int64?) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO music_handoff (path, persistent_id, handed_at) VALUES (?, ?, ?)
                """, arguments: [path, persistentID, Int64(Date().timeIntervalSince1970)])
        }
    }

    /// Puts back hand-off records kept outside the database, after the index was rebuilt.
    /// Returns how many were missing.
    func restoreHandoffs(_ paths: [String]) async throws -> Int {
        guard !paths.isEmpty else { return 0 }
        return try await pool.write { db in
            let insert = try db.cachedStatement(sql: "INSERT OR IGNORE INTO music_handoff (path) VALUES (?)")
            var added = 0
            for path in paths {
                try insert.execute(arguments: [path])
                added += db.changesCount
            }
            return added
        }
    }

    /// Inserts new folder files and refreshes the tags of changed ones. A file keeps its id and
    /// its first-seen date for as long as its path exists.
    func upsertFolderRecords(_ records: [SongRecord]) async throws {
        guard !records.isEmpty else { return }
        try await pool.write { db in
            let upsert = try db.cachedStatement(sql: Self.folderUpsertSQL)
            for record in records { try upsert.execute(arguments: record.arguments(contentHash: record.contentHash)) }
        }
    }

    func deleteFolderRows(paths: [String]) async throws -> Int {
        guard !paths.isEmpty else { return 0 }
        let json = String(data: (try? JSONEncoder().encode(paths)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
        return try await pool.write { db in
            try db.execute(sql: """
                DELETE FROM song WHERE origin = 1 AND location_path IN (SELECT value FROM json_each(?))
                """, arguments: [json])
            return db.changesCount
        }
    }

    /// A root that is not mounted right now (an external drive) keeps its rows, marked missing,
    /// so plugging the drive back in restores them with their ids.
    /// Returns how many rows flipped.
    func setFolderRoot(_ root: String, available: Bool) async throws -> Int {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        let bucket = available ? Track.Bucket.local.rawValue : Track.Bucket.missing.rawValue
        return try await pool.write { db in
            try db.execute(sql: """
                UPDATE song SET bucket = ?
                WHERE origin = 1 AND bucket <> ? AND (location_path = ? OR substr(location_path, 1, length(?)) = ?)
                """, arguments: [bucket, bucket, root, prefix, prefix])
            return db.changesCount
        }
    }

    // MARK: - SQL

    private static var insertSQL: String {
        let columns = SongRecord.columns
        return "INSERT INTO song (\(columns.joined(separator: ", "))) VALUES (\(columns.map { _ in "?" }.joined(separator: ", ")))"
    }

    /// Every column except the identity ones is refreshed from the library.
    private static let musicLibraryUpsertSQL: String = {
        let updated = SongRecord.columns.filter { $0 != "origin" && $0 != "persistent_id" && $0 != "file_mtime" }
        return insertSQL + " ON CONFLICT(persistent_id) DO UPDATE SET "
            + updated.map { "\($0) = excluded.\($0)" }.joined(separator: ", ")
    }()

    /// The conflict target names the partial unique index, so it only ever matches folder rows.
    /// `added_at` is left alone: "date added" is when the file was first seen.
    private static let folderUpsertSQL: String = {
        let updated = SongRecord.columns.filter { !["origin", "persistent_id", "location_path", "added_at"].contains($0) }
        return insertSQL + " ON CONFLICT(location_path) WHERE origin = 1 DO UPDATE SET "
            + updated.map { "\($0) = excluded.\($0)" }.joined(separator: ", ")
    }()
}
