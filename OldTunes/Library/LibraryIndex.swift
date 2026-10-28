import Foundation
import GRDB
import SQLite3

/// The SQLite index behind search, sorting, and showing rows before ingest finishes (RESEARCH.md §2).
///
/// A class holding a `DatabasePool` rather than an actor: the pool is already concurrency-safe
/// and gives parallel reads, which an actor would serialize for nothing.
final class LibraryIndex: LibraryReading, LibraryWriting, Sendable {
    let pool: DatabasePool
    let url: URL

    /// Default path ~/Library/Application Support/OldTunes/index.sqlite; env OLDTUNES_DB_PATH overrides
    /// in Debug and Bench builds (LaunchEnvironment).
    init(path: URL? = nil) throws {
        let env = LaunchEnvironment.value("OLDTUNES_DB_PATH")
        let url = path ?? env.map { URL(fileURLWithPath: $0) } ?? Self.defaultURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var config = Configuration()
        config.label = "OldTunes.index"
        // §4.2's pragmas. DatabasePool already puts the file in WAL mode.
        config.prepareDatabase { db in
            try db.execute(sql: """
                PRAGMA synchronous = NORMAL;
                PRAGMA cache_size = -65536;
                PRAGMA temp_store = MEMORY;
                PRAGMA mmap_size = 268435456;
                """)
        }
        pool = try DatabasePool(path: url.path, configuration: config)
        try LibrarySchema.migrator().migrate(pool)
        self.url = url
    }

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OldTunes/index.sqlite")
    }

    // MARK: - LibraryReading

    func ids(for query: TrackQuery) async throws -> [Track.ID] {
        var ids = try await pool.read { db -> [Int64] in
            let plan = LibraryQueryPlan(query)
            if plan.matchesNothing { return [] }
            let statement = plan.idsStatement(sortedBy: query.sort.field)
            return try db.fetchIDs(sql: statement.sql, arguments: statement.arguments)
        }
        // Descending is the same order backwards (§4.4), reversed in place rather than re-queried.
        if !query.sort.ascending { ids.reverse() }
        return ids
    }

    func tracks(ids: [Track.ID]) async throws -> [Track] {
        guard !ids.isEmpty else { return [] }
        // A big request (the UI materializing a whole list) scans the table and skips unwanted
        // rows: binding 15,900 ids as JSON costs 12 ms in SQLite alone, the scan 1.6 ms.
        let wanted: Set<Int64>? = ids.count >= Self.scanThreshold ? Set(ids) : nil
        let sql = "SELECT \(TrackRowDecoder.columnList) FROM song"
            + (wanted == nil ? " WHERE id IN (SELECT value FROM json_each(?))" : "")
        let arguments: StatementArguments = wanted == nil ? [Self.jsonArray(ids)] : []
        let byID = try await pool.read { db -> [Int64: Track] in
            var out: [Int64: Track] = [:]
            out.reserveCapacity(wanted?.count ?? ids.count)
            try db.forEachRow(sql: sql, arguments: arguments) { statement in
                if let wanted, !wanted.contains(sqlite3_column_int64(statement, 0)) { return }
                let track = TrackRowDecoder.track(statement)
                out[track.id] = track
            }
            return out
        }
        return ids.compactMap { byID[$0] }
    }

    /// Above this many ids `tracks(ids:)` scans instead of binding the list.
    static let scanThreshold = 4_000

    func summary(for ids: [Track.ID]) async throws -> LibrarySummary {
        guard !ids.isEmpty else { return .empty }
        let json = Self.jsonArray(ids)
        return try await pool.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*), COALESCE(SUM(total_time_ms), 0), COALESCE(SUM(file_size), 0)
                FROM song WHERE id IN (SELECT value FROM json_each(?))
                """, arguments: [json])
            guard let row else { return .empty }
            let count: Int = row[0]
            let ms: Int64 = row[1]
            let bytes: Int64 = row[2]
            return LibrarySummary(count: count, totalSeconds: Double(ms) / 1000, totalBytes: bytes)
        }
    }

    func playlists() async throws -> [PlaylistInfo] {
        try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, name, kind, parent_id, track_count FROM playlist ORDER BY sort_index
                """)
            return rows.map { row in
                PlaylistInfo(id: row[0], name: row[1], kind: PlaylistInfo.Kind(storedValue: row[2]),
                             parentID: row[3], trackCount: row[4])
            }
        }
    }

    func browserValues(_ field: BrowserField, for query: TrackQuery) async throws -> [String] {
        try await pool.read { db in
            let plan = LibraryQueryPlan(query, browserPane: field)
            if plan.matchesNothing { return [] }
            return try String.fetchAll(db, sql: plan.browserSQL(field), arguments: plan.arguments)
        }
    }

    func count() async throws -> Int {
        try await pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM song") ?? 0 }
    }

    // MARK: - Helpers

    /// Binds any number of ids as one parameter. A placeholder per id would hit SQLite's
    /// variable limit on a large selection.
    static func jsonArray(_ ids: some Collection<Int64>) -> String {
        "[" + ids.map(String.init).joined(separator: ",") + "]"
    }

    /// Tells the UI the index changed. Always on the main thread (Contracts.swift).
    static func postDidChange() async {
        await MainActor.run {
            NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        }
    }
}
