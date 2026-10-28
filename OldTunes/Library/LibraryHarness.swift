import AppKit
import GRDB
import MusicKit

/// OLDTUNES_HARNESS=library — runs the library module against Noah's real library and logs a
/// PASS/FAIL line per check, then quits.
///
/// Needs OLDTUNES_DB_PATH pointing into a scratchpad folder (evidence/library/ or fixes/library/):
/// the harness deletes that database first so every run exercises a first ingest, and refuses to
/// run against any other path so it can never touch the app's real index. Reads the Music
/// library; never writes to it. The audio files it adds as a folder come from
/// tools/make-library-fixtures.sh, run once on that folder before the first run there.
@MainActor
enum LibraryHarness {
    static func run() async {
        if let bench = LibraryHarnessBench() {
            await bench.runAll()
        }
        Log.flush()
        NSApp.terminate(nil)
    }
}

/// The checks, in order. Shared state (the index, the ingest, all rows) lives here so later
/// steps can reuse what earlier ones loaded.
@MainActor
final class LibraryHarnessBench {
    let evidence: URL
    let index: LibraryIndex
    let ingest: LibraryIngest
    private(set) var passed = 0
    private(set) var failed = 0
    private(set) var blockedCount = 0
    private(set) var changePosts = 0
    private(set) var changePostsOffMain = 0
    private(set) var allTracks: [Track] = []

    init?() {
        guard let dbPath = ProcessInfo.processInfo.environment["OLDTUNES_DB_PATH"],
              ["/scratchpad/evidence/library/", "/scratchpad/fixes/library/"].contains(where: dbPath.contains) else {
            Log.error("library harness: OLDTUNES_DB_PATH must point into scratchpad/evidence/library/ or " +
                      "scratchpad/fixes/library/; refusing to run")
            return nil
        }
        let dbURL = URL(fileURLWithPath: dbPath)
        evidence = dbURL.deletingLastPathComponent()
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
        do {
            index = try LibraryIndex()
        } catch {
            Log.error("library harness: could not open index: \(error)")
            return nil
        }
        ingest = LibraryIngest(index: index)
        NotificationCenter.default.addObserver(forName: .libraryDidChange, object: nil, queue: nil) { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.changePosts += 1 }
            } else {
                Task { @MainActor in
                    self?.changePosts += 1
                    self?.changePostsOffMain += 1
                }
            }
        }
    }

    func runAll() async {
        Log.info("library harness: index at \(index.url.path)")
        do {
            try await checkFirstIngest()
            try await checkPragmas()
            try await checkSorts()
            try await checkQueryPlans()
            try await checkSearch()
            try await checkBlankSortLast()
            try await checkSecondRefreshKeepsIDs()
            try await checkSummaryPlaylistsBrowser()
            try await checkBrowserCaseVariants()
            try await checkTrackDecoding()
            try await checkCompilationDecoding()
            try await checkSoundCheck()
            try await checkPlaylistOrder()
            try await checkCloudSongs()
            try await checkArtworkAndLocalFiles()
            try await checkFolders()
            try await checkFolderFormats()
            try await checkFolderEdges()
            await checkMusicHandoff()
            try await checkUpdate()
            try await checkCompilationEdits()
            try await checkCheckedState()
            try await checkChangeWatching()
            await checkDeadline()
            await checkDeadlineCancellation()
            try await checkConcurrentReadsDuringWrites()
            await checkCancelledReadsAreCancellation()
            try await checkFTSIntegrity()
            try await checkScale()
        } catch {
            fail("harness step threw", "\(error)")
        }
        Log.info("library harness: SUMMARY \(passed) passed, \(failed) failed, \(blockedCount) blocked outside the code")
    }

    // MARK: - Ingest

    private func checkFirstIngest() async throws {
        let report = await ingest.refresh()
        logReport("first refresh", report)
        check("ingest status ok", report.status == .ok, "\(report.status)")
        check("15,900 Music-library songs", report.musicLibrarySongs == 15_900, "\(report.musicLibrarySongs)")
        check("5 local files", report.localFiles == 5, "\(report.localFiles)")
        check("15,895 cloud-only", report.cloudOnly == 15_895, "\(report.cloudOnly)")
        check("no missing files", report.missing == 0, "\(report.missing)")
        check("MusicKit returned 15,900 songs", report.musicKitSongs == 15_900, "\(report.musicKitSongs)")
        check("join 15,900/15,900", report.joined == 15_900, "\(report.joined)/\(report.musicLibrarySongs)")
        let sub = report.subscription
        check("subscription read", sub?.canPlayCatalogContent == true && sub?.hasCloudLibraryEnabled == true,
              "canPlayCatalog=\(sub?.canPlayCatalogContent as Any) cloudLibrary=\(sub?.hasCloudLibraryEnabled as Any)")

        let counts = try await index.pool.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM song") ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM song WHERE cloud_id IS NOT NULL") ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM song WHERE store_item_id <> 0") ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM song WHERE album_pid <> 0") ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM song WHERE has_artwork = 1") ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM song WHERE added_at = 0") ?? 0)
        }
        check("index holds 15,900 rows", counts.0 == 15_900, "\(counts.0)")
        check("cloud_id stored for every song", counts.1 == 15_900, "\(counts.1)")
        check("StoreItemID key returns values (§0 says 6,742)", counts.2 == 6_742,
              "\(counts.2) non-zero; key '\(ITLibKeys.storeItemID)'")
        check("AlbumPersistentID key returns values", counts.3 > 15_000,
              "\(counts.3) non-zero; key '\(ITLibKeys.albumPersistentID)'")
        Log.info("library harness: has_artwork=\(counts.4) (§0: 10,277), added_at unknown=\(counts.5) (§0: 52)")
        check(".libraryDidChange posted on the main thread after each commit",
              changePosts >= 2 && changePostsOffMain == 0, "posts=\(changePosts) offMain=\(changePostsOffMain)")

        let all = try await index.ids(for: TrackQuery(sort: TrackSort(field: .name, ascending: true)))
        let started = ContinuousClock.now
        allTracks = try await index.tracks(ids: all)
        Log.info("library harness: tracks(ids:) for all \(allTracks.count) rows in \(ms(since: started))")
        check("tracks(ids:) keeps the requested order", allTracks.map(\.id) == all, "\(allTracks.count) rows")
    }

    // MARK: - Sorting

    private func checkSorts() async throws {
        let required: Set<TrackSortField> = [.name, .artist, .album, .dateAdded]
        for field in TrackSortField.allCases {
            var orders: [Bool: [Int64]] = [:]
            for ascending in [true, false] {
                let query = TrackQuery(sort: TrackSort(field: field, ascending: ascending))
                var times: [Double] = []
                var ids: [Int64] = []
                for _ in 0..<9 {
                    let started = ContinuousClock.now
                    ids = try await index.ids(for: query)
                    times.append(msValue(since: started))
                }
                orders[ascending] = ids
                let median = times.sorted()[times.count / 2]
                let detail = "\(ids.count) ids, median \(fmt(median)) ms, first \(fmt(times[0])) ms, max \(fmt(times.max() ?? 0)) ms"
                let name = "sort \(field.rawValue) \(ascending ? "asc" : "desc")"
                if required.contains(field) {
                    check("\(name) < 5 ms", median < 5 && ids.count == 15_900, detail)
                } else {
                    check(name, ids.count == 15_900, detail)
                }
            }
            check("sort \(field.rawValue): descending is the ascending order reversed",
                  orders[false] == orders[true].map { Array($0.reversed()) }, "")
        }

        // Raw statement cost without the async hop, for comparison with §4.4's numbers.
        let raw = try await index.pool.read { db -> [String] in
            try TrackSortField.allCases.map { field in
                let sql = "SELECT s.id FROM song s ORDER BY \(field.orderBy)"
                let started = ContinuousClock.now
                for _ in 0..<5 { _ = try Int64.fetchAll(db, sql: sql) }
                return "\(field.rawValue)=\(fmt(self.msValue(since: started) / 5))"
            }
        }
        Log.info("library harness: raw sort SQL (ms, inside the read): \(raw.joined(separator: " "))")

        let byDate = try await index.ids(for: TrackQuery(sort: TrackSort(field: .dateAdded, ascending: true)))
        let tracks = try await index.tracks(ids: [byDate[0], byDate[byDate.count - 1]])
        let first = tracks.first?.dateAdded, last = tracks.last?.dateAdded
        let ordered: Bool
        if let first, let last { ordered = first <= last } else { ordered = first == nil }
        check("dateAdded ascending is oldest first, unknown dates first (so last when the UI flips it)", ordered,
              "first=\(first.map { "\($0)" } ?? "unknown") last=\(last.map { "\($0)" } ?? "unknown")")
    }

    private func checkQueryPlans() async throws {
        for field in TrackSortField.allCases {
            let plan = try await index.pool.read { db in
                try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN SELECT s.id FROM song s ORDER BY \(field.orderBy)")
                    .map { $0["detail"] as String? ?? "" }.joined(separator: " | ")
            }
            let noTemp = !plan.uppercased().contains("TEMP B-TREE")
            if field == .name {
                check("EXPLAIN name sort uses ix_title, no temp b-tree", plan.contains("ix_title") && noTemp, plan)
            } else {
                check("EXPLAIN \(field.rawValue) sort has no temp b-tree", noTemp, plan)
            }
        }
        // Search always sorts its matches with a temp b-tree (FTS yields rowid order, §4.4).
        for text in ["o", "oasis", "oasis wo"] {
            let plan = try await index.pool.read { db in
                let statement = LibraryQueryPlan(TrackQuery(search: text)).idsStatement(sortedBy: .name)
                return try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + statement.sql, arguments: statement.arguments)
                    .map { $0["detail"] as String? ?? "" }.joined(separator: " | ")
            }
            Log.info("library harness: EXPLAIN search '\(text)': \(plan)")
        }
    }

    // MARK: - Search

    private func checkSearch() async throws {
        let queries = ["o", "oa", "oas", "oasis", "nderw", "beatles", "the beatles", "oasis wonderwall",
                       "st wo", "oasis wo", "ac/dc", "don't", "bjork", "\"oasis*", "foo\" OR *bar", "a*b", "*"]
        for text in queries {
            var times: [Double] = []
            var ids: [Int64] = []
            do {
                for _ in 0..<5 {
                    let started = ContinuousClock.now
                    ids = try await index.ids(for: TrackQuery(search: text, sort: TrackSort(field: .name, ascending: true)))
                    times.append(msValue(since: started))
                }
            } catch {
                fail("search '\(text)' does not throw", "\(error)")
                continue
            }
            let expected = bruteForceSearch(text)
            let got = Set(ids)
            let pattern = SearchPattern(text)
            let median = times.sorted()[times.count / 2]
            let route = "tri=\(pattern.trigram ?? "-") prefix=\(pattern.prefix ?? "-")"
            var detail = "\(ids.count) rows, median \(fmt(median)) ms, first \(fmt(times[0])) ms [\(route)]; brute force \(expected.count)"
            if got != expected {
                let missing = expected.subtracting(got).prefix(3).compactMap(title(of:))
                let extra = got.subtracting(expected).prefix(3).compactMap(title(of:))
                detail += "; missing \(missing) extra \(extra)"
            }
            check("search '\(text)' matches a brute-force scan", got == expected && ids.count == got.count, detail)
        }

        let scoped = try await index.ids(for: TrackQuery(scope: .onThisMac, search: "o"))
        check("search honors scope (.onThisMac + 'o')", scoped.count <= 5, "\(scoped.count) rows")
    }

    /// What the search should return, computed the slow way in Swift over every row.
    private func bruteForceSearch(_ text: String) -> Set<Int64> {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return Set(allTracks.map(\.id)) }
        func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        func words(_ s: String) -> [Substring] { s.split { !($0.isLetter || $0.isNumber) } }
        let long = tokens.filter { $0.count >= 3 }.map(fold)
        let short = tokens.filter { $0.count < 3 }.flatMap(words).map { fold(String($0)) }
        if long.isEmpty && short.isEmpty { return [] }
        var out = Set<Int64>()
        for t in allTracks {
            let fields = [t.title, t.artist, t.album, t.albumArtist, t.composer, t.genre].map(fold)
            let fieldWords = fields.flatMap(words)
            let ok = long.allSatisfy { token in fields.contains { $0.contains(token) } }
                && short.allSatisfy { token in fieldWords.contains { $0.hasPrefix(token) } }
            if ok { out.insert(t.id) }
        }
        return out
    }

    private func checkBlankSortLast() async throws {
        for (field, column) in [(TrackSortField.artist, "sk_artist"), (.album, "sk_album")] {
            let ids = try await index.ids(for: TrackQuery(sort: TrackSort(field: field, ascending: true)))
            let blank = try await index.pool.read { db in
                try Int64.fetchAll(db, sql: "SELECT id FROM song WHERE \(column) = ?", arguments: [SortKey.blank])
            }
            let tail = Set(ids.suffix(blank.count))
            check("blank \(field.rawValue) rows sort last", !blank.isEmpty && tail == Set(blank),
                  "\(blank.count) blank rows (§4.3: ~320 artist, ~1,076 album), all in the last \(blank.count) positions")
        }
    }

    private func checkSecondRefreshKeepsIDs() async throws {
        let before = try await pidMap()
        let postsBefore = changePosts
        let report = await ingest.refresh()
        logReport("second refresh", report)
        let after = try await pidMap()
        check("second refresh keeps every id for the same persistent id", before == after && after.count == 15_900,
              "\(after.count) rows compared")
        // The change notification is coarse (§8.5); a re-ingest that finds nothing new must not
        // make the UI reload three times.
        try await Task.sleep(for: .milliseconds(200))
        check("an unchanged re-ingest posts no .libraryDidChange", changePosts == postsBefore,
              "\(changePosts - postsBefore) posts")
    }

    func pidMap() async throws -> [Int64: Int64] {
        try await index.pool.read { db in
            var map: [Int64: Int64] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT persistent_id, id FROM song WHERE origin = 0") {
                map[row[0]] = row[1]
            }
            return map
        }
    }

    // MARK: - Summary, playlists, browser

    private func checkSummaryPlaylistsBrowser() async throws {
        let all = try await index.ids(for: TrackQuery())
        var started = ContinuousClock.now
        let summary = try await index.summary(for: all)
        let days = summary.totalSeconds / 86_400
        let gb = Double(summary.totalBytes) / 1_000_000_000
        check("summary() for the whole library", summary.count == 15_900,
              "\(summary.count) songs, \(fmt(days)) days, \(fmt(gb)) GB in \(ms(since: started))")

        started = ContinuousClock.now
        let playlists = try await index.playlists()
        let sample = playlists.prefix(10).map { "\($0.name) [\($0.kind), \($0.trackCount)]" }
        check("playlists() returns Music.app's playlists", !playlists.isEmpty,
              "\(playlists.count) playlists in \(ms(since: started)): \(sample.joined(separator: "; "))")
        let kinds = Dictionary(grouping: playlists, by: \.kind).mapValues(\.count)
        Log.info("library harness: playlist kinds \(kinds), with parent \(playlists.filter { $0.parentID != nil }.count)")
        if let list = playlists.first(where: { $0.kind != .folder && $0.trackCount > 0 }) {
            let ids = try await index.ids(for: TrackQuery(scope: .playlist(list.id)))
            check("playlist scope returns its songs", !ids.isEmpty && ids.count <= list.trackCount,
                  "'\(list.name)': \(ids.count) distinct of \(list.trackCount) items")
        }

        started = ContinuousClock.now
        let genres = try await index.browserValues(.genre, for: TrackQuery())
        let genreMs = ms(since: started)
        let genre = genres.first { $0 == "Rock" } ?? genres.first ?? ""
        started = ContinuousClock.now
        let allArtists = try await index.browserValues(.artist, for: TrackQuery())
        let artistsAllMs = ms(since: started)
        let artists = try await index.browserValues(.artist, for: TrackQuery(genre: genre))
        let artist = artists.first ?? ""
        let albums = try await index.browserValues(.album, for: TrackQuery(genre: genre, artist: artist))
        Log.info("library harness: browser genres=\(genres.count) (\(genreMs)) first=\(genres.prefix(8)); " +
                 "artists all=\(allArtists.count) (\(artistsAllMs)) in '\(genre)'=\(artists.count) first=\(artists.prefix(5)); " +
                 "albums for '\(artist)'=\(albums.count) \(albums.prefix(5))")
        check("browser panes return values", !genres.isEmpty && !artists.isEmpty && !albums.isEmpty,
              "\(genres.count) genres, \(artists.count) artists, \(albums.count) albums")
        check("browser genre filter narrows the artist pane", artists.count < allArtists.count,
              "\(artists.count) < \(allArtists.count)")
        let genresIgnoringOwnFilter = try await index.browserValues(.genre, for: TrackQuery(genre: genre, artist: artist))
        check("browser pane ignores filters at and right of itself", genresIgnoringOwnFilter == genres, "")
        check("browser values have no blanks", !genres.contains("") && !artists.contains(""), "")

        let filtered = try await index.ids(for: TrackQuery(genre: genre, artist: artist))
        let rows = try await index.tracks(ids: filtered)
        // Case-insensitive: the browser merges "Alice In Chains" and "Alice in Chains".
        check("ids(for:) honors browser filters", !rows.isEmpty && rows.allSatisfy {
                  $0.genre.caseInsensitiveCompare(genre) == .orderedSame && $0.artist.caseInsensitiveCompare(artist) == .orderedSame },
              "\(rows.count) rows for \(genre) / \(artist)")
    }

    // MARK: - Cloud resolution

    private func checkCloudSongs() async throws {
        let cloud = allTracks.filter { $0.isCloudOnly && $0.cloudID != nil }
        let uploaded = cloud.filter { $0.storeItemID == 0 }
        let matched = cloud.filter { $0.storeItemID != 0 }
        let picks = [uploaded.first, uploaded.dropFirst(uploaded.count / 2).first, matched.first].compactMap { $0 }
        guard picks.count == 3 else { return fail("found 3 cloud tracks", "\(picks.count)") }
        let reader = PersistentIDReader()

        // A fresh resolver has no map yet, exactly like a double-click during launch.
        let cold = LibraryIngest(index: index)
        for track in picks {
            let started = ContinuousClock.now
            let song = await cold.cloudSong(for: track)
            check("cloudSong before the map is ready: '\(track.title)'",
                  song.map { reader.persistentID(of: $0) == track.persistentID } ?? false,
                  "\(ms(since: started)), store id \(track.storeItemID), song id \(song?.id.rawValue ?? "nil")")
        }

        var noID = picks[0]
        noID.cloudID = nil
        let started = ContinuousClock.now
        let byTitle = await LibraryIngest(index: index).cloudSong(for: noID)
        check("cloudSong with no stored cloud id (title lookup)",
              byTitle.map { reader.persistentID(of: $0) == noID.persistentID } ?? false, "\(ms(since: started))")

        for track in picks {
            let started = ContinuousClock.now
            let song = await ingest.cloudSong(for: track)
            check("cloudSong from the ready map: '\(track.title)'",
                  song.map { reader.persistentID(of: $0) == track.persistentID } ?? false, "\(ms(since: started))")
        }

        if let track = matched.first {
            var started = ContinuousClock.now
            do {
                let song = try await MusicKitSource.catalogSong(storeItemID: track.storeItemID)
                check("catalog step 3 resolves a store id", song != nil,
                      "\(track.storeItemID) → '\(song?.title ?? "nil")' (library title '\(track.title)') in \(ms(since: started))")
            } catch MusicTokenRequestError.developerTokenRequestFailed {
                blocked("catalog step 3 resolves a store id",
                        "developerTokenRequestFailed in \(ms(since: started)): the App ID needs the MusicKit App Service (§3.4, a portal step for Noah)")
            } catch {
                fail("catalog step 3 resolves a store id", "\(track.storeItemID) '\(track.title)': \(error) in \(ms(since: started))")
            }
            // Through the resolver: a row the library map lacks falls to step 3 and fails soft.
            var orphan = track
            orphan.persistentID = 42
            started = ContinuousClock.now
            let first = await ingest.cloudSong(for: orphan)
            let firstMs = ms(since: started)
            started = ContinuousClock.now
            let second = await ingest.cloudSong(for: orphan)
            check("cloudSong falls through to step 3 and fails soft when the catalog is unavailable",
                  first == nil && second == nil, "first \(firstMs), repeat \(ms(since: started)) (no retry once refused)")
        }

        // R5: is PlayParameters Codable round-trip safe, so the map could be persisted if needed?
        if let song = await ingest.cloudSong(for: picks[0]), let parameters = song.playParameters {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let json = try encoder.encode(parameters)
            let back = try JSONDecoder().decode(PlayParameters.self, from: json)
            let again = try encoder.encode(back)
            Log.info("library harness: R5 PlayParameters \(String(decoding: json, as: UTF8.self)); decoded == original: \(back == parameters)")
            check("R5: PlayParameters survive a JSON round trip (re-encoded JSON identical)", again == json,
                  "\(json.count) bytes; Equatable says \(back == parameters), so compare by JSON, not ==")
            Log.info("library harness: PlayParameters mirror: \(Mirror(reflecting: parameters).children.map { "\($0.label ?? "?"): \(type(of: $0.value))" })")
        }

        // Where the join-key cost goes, over 2,000 songs.
        let songs = await withTaskGroup(of: Song?.self) { group in
            for track in allTracks.prefix(2_000) { group.addTask { await self.ingest.cloudSong(for: track) } }
            var out: [Song] = []
            for await song in group { if let song { out.append(song) } }
            return out
        }
        let params = songs.compactMap(\.playParameters)
        let keyEncoder = JSONEncoder()
        var keyStarted = ContinuousClock.now
        let blobs = params.compactMap { try? keyEncoder.encode($0) }
        let encodeMs = ms(since: keyStarted)
        keyStarted = ContinuousClock.now
        let keyReader = PersistentIDReader()
        let viaReader = songs.compactMap { keyReader.persistentID(of: $0) }.count
        Log.info("library harness: join key cost for \(params.count) songs: encode only \(encodeMs), " +
                 "PersistentIDReader (encode + read) \(ms(since: keyStarted)) → \(viaReader) keys, \(blobs.count) blobs")
    }

    // MARK: - Artwork and local files

    private func checkArtworkAndLocalFiles() async throws {
        if let track = allTracks.first(where: { $0.hasArtwork && $0.isCloudOnly }) {
            var started = ContinuousClock.now
            let data = await ingest.artworkData(for: track)
            let firstMs = ms(since: started)
            started = ContinuousClock.now
            _ = await ingest.artworkData(for: track)
            check("artworkData for a cloud track", (data?.count ?? 0) > 0,
                  "'\(track.title)': \(data?.count ?? 0) bytes \(imageKind(data)), \(firstMs) first, \(ms(since: started)) again")
        }

        let local = try await index.tracks(ids: index.ids(for: TrackQuery(scope: .onThisMac)))
        let readable = local.compactMap { track -> String? in
            guard let url = track.fileURL, let data = FileManager.default.contents(atPath: url.path) else { return nil }
            return "\(url.lastPathComponent)=\(data.count)"
        }
        check("R1: the 5 local Music files are readable by the app", local.count == 5 && readable.count == 5,
              readable.joined(separator: ", "))
    }

    private func imageKind(_ data: Data?) -> String {
        guard let data, data.count > 4 else { return "" }
        let b = [UInt8](data.prefix(4))
        if b[0] == 0xFF && b[1] == 0xD8 { return "(JPEG)" }
        if b[0] == 0x89 && b[1] == 0x50 { return "(PNG)" }
        return "(\(b.map { String(format: "%02X", $0) }.joined()))"
    }

    // MARK: - Helpers

    func check(_ name: String, _ ok: Bool, _ detail: String) {
        if ok {
            passed += 1
            Log.info("PASS \(name)\(detail.isEmpty ? "" : ": \(detail)")")
        } else {
            fail(name, detail)
        }
    }

    func fail(_ name: String, _ detail: String) {
        failed += 1
        Log.error("FAIL \(name)\(detail.isEmpty ? "" : ": \(detail)")")
    }

    /// Cannot pass on this Mac until a human does something outside the code.
    func blocked(_ name: String, _ detail: String) {
        blockedCount += 1
        Log.error("BLOCKED \(name): \(detail)")
    }

    func title(of id: Int64) -> String? {
        allTracks.first { $0.id == id }.map { "\($0.title) / \($0.artist)" }
    }

    func logReport(_ label: String, _ r: IngestReport) {
        Log.info("library harness: \(label): status=\(r.status) songs=\(r.musicLibrarySongs) local=\(r.localFiles) " +
                 "cloud=\(r.cloudOnly) missing=\(r.missing) musicKit=\(r.musicKitSongs) joined=\(r.joined) " +
                 "folder=\(r.folderTracks) seconds=\(fmt(r.seconds))")
    }

    nonisolated func msValue(since start: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - start
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    func ms(since start: ContinuousClock.Instant) -> String { "\(fmt(msValue(since: start))) ms" }

    nonisolated func fmt(_ value: Double) -> String { String(format: "%.3f", value) }
}
