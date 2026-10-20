import Foundation
import GRDB

/// The FROM and WHERE clauses for a `TrackQuery`, shared by the id list and the column browser.
///
/// The first full-text condition is a join, as in §4.4: measured on this library with the sqlite3
/// CLI, `"o"*` (4,722 rows) sorts in 2.2 ms joined against 3.2 ms as `s.id IN (subquery)`. A
/// second full-text condition and the playlist scope stay `IN (subquery)`, which can never
/// repeat a row (a playlist may list a song twice).
struct LibraryQueryPlan {
    private(set) var from = "song s"
    private(set) var conditions: [String] = []
    private(set) var arguments = StatementArguments()
    /// The query can match nothing (unsearchable text), so skip the database entirely.
    private(set) var matchesNothing = false
    /// The playlist the scope names, whose positions `.playlistOrder` sorts by.
    private(set) var playlistID: Int64?

    /// Everything in the query: scope, search and all three browser filters.
    init(_ query: TrackQuery) {
        self.init(query, browserFilters: BrowserField.allCases)
    }

    /// For one browser pane: scope, search, and only the filters to the left of `field`
    /// (genre narrows artist; genre and artist narrow album).
    init(_ query: TrackQuery, browserPane field: BrowserField) {
        let left = BrowserField.allCases.prefix { $0 != field }
        self.init(query, browserFilters: Array(left))
    }

    private init(_ query: TrackQuery, browserFilters: [BrowserField]) {
        switch query.scope {
        case .library:
            break
        case .onThisMac:
            conditions.append("s.bucket = \(Track.Bucket.local.rawValue)")
        case .playlist(let id):
            playlistID = id
            conditions.append("s.id IN (SELECT song_id FROM playlist_item WHERE playlist_id = ?)")
            arguments += [id]
        }

        let pattern = SearchPattern(query.search)
        if pattern.matchesNothing { matchesNothing = true }
        if let trigram = pattern.trigram { addMatch(table: "song_tri", pattern: trigram) }
        if let prefix = pattern.prefix { addMatch(table: "song_fts", pattern: prefix) }

        // Case-insensitive, matching how `browserSQL` merges case variants into one entry.
        for field in browserFilters {
            guard let value = query.value(for: field) else { continue }
            conditions.append("s.\(field.column) = ? COLLATE NOCASE")
            arguments += [value]
        }
    }

    private mutating func addMatch(table: String, pattern: String) {
        if from == "song s" {
            from = "\(table) JOIN song s ON s.id = \(table).rowid"
            conditions.append("\(table) MATCH ?")
        } else {
            conditions.append("s.id IN (SELECT rowid FROM \(table) WHERE \(table) MATCH ?)")
        }
        arguments += [pattern]
    }

    var whereClause: String {
        conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
    }

    /// The ordered id list for one sort: its SQL, and every argument it binds (the WHERE
    /// clause's, then any the ORDER BY adds; placeholders bind in order of appearance).
    func idsStatement(sortedBy field: TrackSortField) -> (sql: String, arguments: StatementArguments) {
        let select = "SELECT s.id FROM \(from) \(whereClause) ORDER BY "
        // A playlist's own order, as Music lists it. A song listed twice sits at its first
        // position, since the list shows each id once (the filter above is an IN, never a join).
        if field == .playlistOrder, let playlistID {
            let position = "(SELECT MIN(pi.position) FROM playlist_item pi WHERE pi.playlist_id = ? AND pi.song_id = s.id)"
            return (select + position + ", s.id", arguments + [playlistID])
        }
        return (select + field.orderBy, arguments)
    }

    /// Distinct non-empty values, ordered by their fold key. A raw value can carry several sort
    /// keys (the library's sort fields vary per song), so the smallest one represents it.
    ///
    /// Spellings that differ only in case ("Alice In Chains" / "Alice in Chains"; 69 of this
    /// library's 4,374 artist entries were such duplicates) are one entry, as in iTunes, shown in
    /// their most common spelling; the filters match case-insensitively to agree. NOCASE folds
    /// ASCII only, so "Björk" and "Bjork" stay two artists, as they were in iTunes.
    func browserSQL(_ field: BrowserField) -> String {
        let column = "s.\(field.column)"
        let key = "s.\(field.sortKeyColumn)"
        let filter = conditions + ["\(column) <> ''"]
        return """
            SELECT value FROM (
              SELECT value, k, ROW_NUMBER() OVER (PARTITION BY value COLLATE NOCASE ORDER BY n DESC, value) AS r
              FROM (SELECT \(column) AS value, COUNT(*) AS n, MIN(\(key)) AS k FROM \(from)
                    WHERE \(filter.joined(separator: " AND ")) GROUP BY \(column))
            ) WHERE r = 1 ORDER BY k, value
            """
    }
}

extension TrackQuery {
    fileprivate func value(for field: BrowserField) -> String? {
        switch field {
        case .genre: genre
        case .artist: artist
        case .album: album
        }
    }
}

extension BrowserField {
    fileprivate var column: String { rawValue }
    fileprivate var sortKeyColumn: String { "sk_\(rawValue)" }
}

extension TrackSortField {
    /// Each matches one index column-for-column, so SQLite walks the index instead of sorting.
    /// The trailing id makes every order total. Ascending only: descending is `reversed()`.
    var orderBy: String {
        switch self {
        case .name: "s.sk_title, s.sk_artist, s.id"                                        // ix_title
        case .artist: "s.sk_artist, s.sk_album, s.disc_number, s.track_number, s.id"       // ix_artist
        case .album: "s.sk_album, s.disc_number, s.track_number, s.id"                     // ix_album
        case .dateAdded: "s.added_at, s.id"                                                // ix_added
        case .time: "s.total_time_ms, s.id"                                                // ix_time
        case .genre: "s.sk_genre, s.sk_artist, s.sk_album, s.disc_number, s.track_number, s.id" // ix_genre
        case .year: "s.year, s.sk_artist, s.sk_album, s.disc_number, s.track_number, s.id" // ix_year
        case .playCount: "s.play_count, s.id"                                              // ix_plays
        // Outside a playlist there is no playlist order, so artist order. Inside one,
        // `LibraryQueryPlan.idsStatement` orders by the playlist's positions instead.
        case .playlistOrder: "s.sk_artist, s.sk_album, s.disc_number, s.track_number, s.id" // ix_artist
        }
    }
}
