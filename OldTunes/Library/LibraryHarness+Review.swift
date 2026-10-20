import Foundation
import GRDB

/// Regression checks for the adversarial review's library findings, and for the per-song checkbox:
/// - 2: the compilation flag was stored but never decoded into `Track.isCompilation`.
/// - 4: a playlist never came out in its own order.
/// - 14, part 3: cancelling a read surfaced as "SQLite error 9: interrupted" instead of a cancellation.
/// - The checkbox: starts from Music's own state, and OldTunes' own choice survives re-ingest.
extension LibraryHarnessBench {
    // MARK: - Finding 2: "Part of a compilation"

    func checkCompilationDecoding() async throws {
        let (stored, fromMusic) = try await index.pool.read { db in
            (Set(try Int64.fetchAll(db, sql: "SELECT id FROM song WHERE is_compilation = 1")),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM song WHERE origin = 0 AND is_compilation = 1") ?? 0)
        }
        let every = try await index.tracks(ids: index.ids(for: TrackQuery()))
        let decoded = Set(every.filter(\.isCompilation).map(\.id))
        check("every row stored as a compilation decodes Track.isCompilation = true, and no other row does",
              !stored.isEmpty && decoded == stored,
              "\(stored.count) rows stored (\(fromMusic) from Music; the review counted 4,249), \(decoded.count) decoded")

        let known = try await knownCompilation()
        check("a compilation song from Music decodes isCompilation = true", known?.isCompilation == true,
              known.map { "'\($0.title)' on '\($0.album)', id \($0.id)" } ?? "no song from Music is stored as a compilation")
    }

    /// Clearing and setting the flag through `update(ids:applying:)`, the path a Get Info save takes.
    func checkCompilationEdits() async throws {
        guard let known = try await knownCompilation() else {
            return fail("compilation edit target found", "no song from Music is stored as a compilation")
        }
        for value in [false, true] {
            let posts = changePosts
            try await index.update(ids: [known.id], applying: TagPatch(isCompilation: value))
            let decoded = try await index.tracks(ids: [known.id]).first?.isCompilation
            let stored = try await index.pool.read { db in
                try Bool.fetchOne(db, sql: "SELECT is_compilation FROM song WHERE id = ?", arguments: [known.id])
            }
            check("update(ids:applying:) with isCompilation = \(value) round-trips through the decoder, one post",
                  decoded == value && stored == value && changePosts == posts + 1,
                  "'\(known.title)': stored \(stored.map { "\($0)" } ?? "nil"), decoded \(decoded.map { "\($0)" } ?? "nil"), " +
                  "\(changePosts - posts) .libraryDidChange posts")
        }
    }

    /// The song from Music stored as a compilation with the lowest persistent id, so every run
    /// traces the same one without this file naming a song from the library.
    private func knownCompilation() async throws -> Track? {
        let id = try await index.pool.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM song WHERE origin = 0 AND is_compilation = 1 ORDER BY persistent_id LIMIT 1")
        }
        guard let id else { return nil }
        return try await index.tracks(ids: [id]).first
    }

    // MARK: - Finding 4: playlist order

    func checkPlaylistOrder() async throws {
        let playlists = try await index.playlists()
        let idByPID = try await pidMap()
        /// Music's order as the index ids it should produce: songs only, each at its first position
        /// (the track list needs each id once; a playlist may list a song twice).
        func musicOrder(_ playlist: PlaylistInfo) async throws -> [Int64]? {
            guard let pids = try await ingest.itlib.musicMemberPIDs(ofPlaylist: playlist.id) else { return nil }
            var seen = Set<Int64>()
            return pids.compactMap { idByPID[$0] }.filter { seen.insert($0).inserted }
        }
        func ids(_ scope: LibraryScope, _ field: TrackSortField, ascending: Bool = true, search: String = "") async throws -> [Int64] {
            try await index.ids(for: TrackQuery(scope: scope, search: search, sort: TrackSort(field: field, ascending: ascending)))
        }

        if let favorites = playlists.first(where: { $0.name == "Favorite Songs" }), let music = try await musicOrder(favorites) {
            let started = ContinuousClock.now
            let ascending = try await ids(.playlist(favorites.id), .playlistOrder)
            let elapsed = ms(since: started)
            let descending = try await ids(.playlist(favorites.id), .playlistOrder, ascending: false)
            let byArtist = try await ids(.playlist(favorites.id), .artist)
            check("'Favorite Songs' sorted by playlist order is Music's own order",
                  !ascending.isEmpty && ascending == music,
                  "\(ascending.count) shown, \(music.count) in Music, in \(elapsed); shown first " +
                  "\(ascending.prefix(3).compactMap(title(of:))), Music first \(music.prefix(3).compactMap(title(of:))); " +
                  "artist order would start \(byArtist.prefix(2).compactMap(title(of:)))")
            check("…descending is that order reversed", !descending.isEmpty && descending == Array(ascending.reversed()),
                  "last shown first: \(descending.prefix(2).compactMap(title(of:)))")
            let hits = try await ids(.playlist(favorites.id), .playlistOrder, search: "a")
            let hitSet = Set(hits)
            check("…and a search inside it keeps the playlist's order", !hits.isEmpty && hits == ascending.filter(hitSet.contains),
                  "\(hits.count) of \(ascending.count) match 'a'")
        } else {
            fail("'Favorite Songs' found in the index and in Music",
                 "index playlists: \(playlists.prefix(25).map(\.name).joined(separator: ", "))")
        }

        var matched = 0
        var mismatched: [String] = []
        var slowest = (ms: 0.0, first: 0.0, name: "", count: 0)
        for playlist in playlists where playlist.trackCount > 0 {
            guard let music = try await musicOrder(playlist) else {
                mismatched.append("\(playlist.name) (gone from Music)")
                continue
            }
            // Timed as the median of 5, like the harness's other sort timings: one cold sample
            // swings past a frame whenever the machine is busy (seen at 19.9 ms under load).
            var times: [Double] = []
            var shown: [Int64] = []
            for _ in 0..<5 {
                let started = ContinuousClock.now
                shown = try await ids(.playlist(playlist.id), .playlistOrder)
                times.append(msValue(since: started))
            }
            let median = times.sorted()[2]
            if median > slowest.ms { slowest = (median, times[0], playlist.name, shown.count) }
            if shown == music { matched += 1 } else { mismatched.append("\(playlist.name) [\(playlist.kind), \(shown.count)]") }
        }
        check("every playlist with songs shows in Music's own order", matched > 0 && mismatched.isEmpty,
              "\(matched) match, \(mismatched.count) differ\(mismatched.isEmpty ? "" : ": \(mismatched.prefix(10))")")
        check("a playlist-order fetch stays under one frame (16.7 ms, median of 5)", slowest.ms < 16.7,
              "slowest median \(fmt(slowest.ms)) ms (first \(fmt(slowest.first)) ms) for '\(slowest.name)' (\(slowest.count) songs)")

        // The ORDER BY binds the playlist id after every WHERE placeholder. Use all of them at once:
        // the scope, a trigram join ("the"), a prefix condition ("a*") and a browser filter.
        var bound: [String] = []
        var boundWrong: [String] = []
        for playlist in playlists where playlist.trackCount > 20 {
            let order = try await ids(.playlist(playlist.id), .playlistOrder)
            let genres = Dictionary(grouping: try await index.tracks(ids: order).filter { !$0.genre.isEmpty }, by: \.genre)
            guard let genre = genres.max(by: { $0.value.count < $1.value.count })?.key else { continue }
            var query = TrackQuery(scope: .playlist(playlist.id), search: "the a", sort: TrackSort(field: .playlistOrder, ascending: true))
            query.genre = genre
            let hits = try await index.ids(for: query)
            query.sort.ascending = false
            let reversed = try await index.ids(for: query)
            // The same filters over the whole library, sorted some other way, then kept in playlist order.
            query.scope = .library
            query.sort = TrackSort(field: .name, ascending: true)
            let members = Set(try await index.ids(for: query))
            let expected = order.filter(members.contains)
            let label = "\(playlist.name)/\(genre): \(hits.count)"
            if hits == expected && reversed == Array(hits.reversed()) { bound.append(label) } else { boundWrong.append(label) }
        }
        check("a playlist-order search with a browser filter keeps the playlist's order (every placeholder bound in order)",
              boundWrong.isEmpty && bound.contains { !$0.hasSuffix(": 0") && !$0.hasSuffix(": 1") },
              "'the a' + top genre: right \(bound), wrong \(boundWrong)")

        // No playlist in this library lists a song twice, so give one a repeat at each end for a
        // moment: song #3 again before the start, song #1 again after the end. Each must show once,
        // at its first position. The rows are removed again before anything else reads them.
        if let target = playlists.first(where: { $0.kind == .regular && $0.trackCount >= 3 }) {
            let order = try await ids(.playlist(target.id), .playlistOrder)
            if order.count >= 3 {
                let (first, third) = (order[0], order[2])
                let (before, after) = try await index.pool.write { db -> (Int, Int) in
                    let row = try Row.fetchOne(db, sql: "SELECT MIN(position), MAX(position) FROM playlist_item WHERE playlist_id = ?",
                                               arguments: [target.id])
                    let (low, high): (Int, Int) = (row?[0] ?? 0, row?[1] ?? 0)
                    try db.execute(sql: "INSERT INTO playlist_item (playlist_id, song_id, position) VALUES (?, ?, ?), (?, ?, ?)",
                                   arguments: [target.id, third, low - 1, target.id, first, high + 1])
                    return (low - 1, high + 1)
                }
                let repeated = try await ids(.playlist(target.id), .playlistOrder)
                let reversed = try await ids(.playlist(target.id), .playlistOrder, ascending: false)
                try await index.pool.write { db in
                    try db.execute(sql: "DELETE FROM playlist_item WHERE playlist_id = ? AND position IN (?, ?)",
                                   arguments: [target.id, before, after])
                }
                let restored = try await ids(.playlist(target.id), .playlistOrder)
                let expected = [third] + order.filter { $0 != third }
                check("a song a playlist lists twice shows once, at its first position",
                      repeated == expected && reversed == Array(expected.reversed()) && restored == order,
                      "'\(target.name)': \(repeated.count) ids for \(order.count + 2) items; first \(repeated.prefix(3).compactMap(title(of:)))")
            }
        }
        if let biggest = playlists.max(by: { $0.trackCount < $1.trackCount }) {
            let plan = try await index.pool.read { db in
                let statement = LibraryQueryPlan(TrackQuery(scope: .playlist(biggest.id), sort: TrackSort(field: .playlistOrder, ascending: true)))
                    .idsStatement(sortedBy: .playlistOrder)
                return try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + statement.sql, arguments: statement.arguments)
                    .map { $0["detail"] as String? ?? "" }.joined(separator: " | ")
            }
            Log.info("library harness: EXPLAIN playlist order for '\(biggest.name)' (\(biggest.trackCount)): \(plan)")
        }

        for scope in [LibraryScope.library, .onThisMac] {
            let fallback = try await ids(scope, .playlistOrder)
            let artist = try await ids(scope, .artist)
            check("outside a playlist, playlist order is artist order (\(scope))", !fallback.isEmpty && fallback == artist,
                  "\(fallback.count) ids")
        }
    }

    // MARK: - The per-song checkbox

    func checkCheckedState() async throws {
        let musicUnchecked = try await ingest.itlib.musicUncheckedPIDs()
        let every = try await index.tracks(ids: index.ids(for: TrackQuery()))
        let decodedUnchecked = Set(every.filter { !$0.isChecked }.compactMap(\.persistentID))
        check("Track.isChecked starts as Music's own checkbox (!isUserDisabled)",
              decodedUnchecked == musicUnchecked && every.count > 15_900,
              "\(musicUnchecked.count) songs unchecked in Music, \(decodedUnchecked.count) decoded unchecked, \(every.count) rows")

        let cloud = every.filter { $0.origin == .musicLibrary && $0.isCloudOnly && $0.isChecked }
        guard cloud.count >= 2, let folder = every.first(where: { $0.origin == .folder && $0.fileURL != nil }),
              let folderURL = folder.fileURL else {
            return fail("checkbox targets found", "\(cloud.count) checked cloud songs, folder rows: \(every.contains { $0.origin == .folder })")
        }
        let song = cloud[cloud.count / 3], control = cloud[cloud.count * 2 / 3]
        let musicOff = every.first { $0.origin == .musicLibrary && !$0.isChecked }
        let watched = [song.id, control.id, folder.id] + (musicOff.map { [$0.id] } ?? [])
        func state() async throws -> [Int64: Bool] {
            Dictionary(uniqueKeysWithValues: try await index.tracks(ids: watched).map { ($0.id, $0.isChecked) })
        }

        let postsBefore = changePosts, offMainBefore = changePostsOffMain
        do {
            try await index.setChecked(ids: [song.id, folder.id, 999_999_999], checked: false)
            if let musicOff { try await index.setChecked(ids: [musicOff.id], checked: true) }
        } catch {
            return fail("setChecked(ids:checked:) stores OldTunes' choice", "\(error)")
        }
        let calls = musicOff == nil ? 1 : 2
        check("setChecked posts .libraryDidChange once per call, on the main thread",
              changePosts - postsBefore == calls && changePostsOffMain == offMainBefore,
              "\(changePosts - postsBefore) posts for \(calls) calls, \(changePostsOffMain - offMainBefore) off main")
        let set = try await state()
        check("setChecked shows at once through tracks(ids:), unknown ids ignored",
              set[song.id] == false && set[folder.id] == false && set[control.id] == true
                  && (musicOff.map { set[$0.id] == true } ?? true),
              "'\(song.title)' \(set[song.id] as Any), folder '\(folder.title)' \(set[folder.id] as Any)" +
              (musicOff.map { ", Music-unchecked '\($0.title)' \(set[$0.id] as Any)" } ?? ", Music has no unchecked song to re-check"))
        let quiet = changePosts
        try await index.setChecked(ids: [], checked: true)
        check("setChecked with no ids posts nothing", changePosts == quiet, "")

        // Make the next refresh see Music's checkbox change under both cloud songs: store the
        // opposite of Music's value and force a rewrite. The override must win on `song`; `control`
        // has none, so it must follow Music again, which shows the refresh really rewrote the value.
        try await index.pool.write { db in
            try db.execute(sql: "UPDATE song SET is_checked = 1 - is_checked, content_hash = 0 WHERE id IN (?, ?)",
                           arguments: [song.id, control.id])
            // A marker title the folder rescan must overwrite, proving the folder row was rewritten.
            try db.execute(sql: "UPDATE song SET title = 'Checkbox Rescan Marker' WHERE id = ?", arguments: [folder.id])
        }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(30)], ofItemAtPath: folderURL.path)
        let flipped = try await state()
        for n in 1...2 {
            let report = await ingest.refresh()
            logReport("refresh \(n) after setChecked", report)
        }
        let after = try await state()
        let rows = try await index.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id, is_checked, checked_override, title FROM song WHERE id IN (?, ?, ?)",
                             arguments: [song.id, control.id, folder.id])
                .map { "id \($0["id"] as Int64): is_checked=\($0["is_checked"] as Int) override=\(($0["checked_override"] as Int?).map(String.init) ?? "NULL")" }
        }
        let folderTitle = try await index.tracks(ids: [folder.id]).first?.title ?? ""
        check("OldTunes' unchecked survives two refresh() calls while Music's own value changes under it",
              flipped[song.id] == false && after[song.id] == false, rows.joined(separator: "; "))
        check("…a song with no override follows Music's value again (the refresh did rewrite it)",
              flipped[control.id] == false && after[control.id] == true,
              "control '\(control.title)': \(flipped[control.id] as Any) before the refresh, \(after[control.id] as Any) after")
        check("…a folder song's unchecked survives a rescan that rewrote its row",
              after[folder.id] == false && folderTitle != "Checkbox Rescan Marker",
              "folder '\(folderTitle)' checked=\(after[folder.id] as Any)")
        if let musicOff {
            check("…a song Music unchecked stays checked after OldTunes checks it", after[musicOff.id] == true,
                  "'\(musicOff.title)'")
        }

        // The app holds the index as `any LibraryReading & LibraryWriting` (GetInfoWindowController),
        // so the call must reach LibraryIndex's implementation, not the protocol's throwing default.
        let writer: any LibraryReading & LibraryWriting = index
        var viaProtocol: Bool?
        var thrown = ""
        do {
            try await writer.setChecked(ids: [control.id], checked: false)
            viaProtocol = try await writer.tracks(ids: [control.id]).first?.isChecked
        } catch {
            thrown = " (threw \(error))"
        }
        check("setChecked through `any LibraryReading & LibraryWriting` reaches the index", viaProtocol == false,
              "control '\(control.title)' isChecked \(viaProtocol.map { "\($0)" } ?? "nil")\(thrown)")
    }

    // MARK: - Finding 14, part 3: cancellation

    /// Cancels reads 0-4.9 ms after they start, the way a new keystroke or a reload cancels the
    /// load in flight. Every failure must be a CancellationError; anything else is logged as an
    /// ERROR, exactly as the track list does.
    func checkCancelledReadsAreCancellation() async {
        let index = self.index
        let all = (try? await index.ids(for: TrackQuery())) ?? []
        var finished = 0, cancelled = 0
        var interrupted: [String] = [], other: [String] = []
        for i in 0..<240 {
            let task: Task<Int, any Error>
            switch i % 3 {
            case 0: task = Task { try await index.ids(for: TrackQuery(search: "o")).count }   // a keystroke
            case 1: task = Task { try await index.ids(for: TrackQuery()).count }              // the launch list
            default: task = Task { try await index.tracks(ids: all).count }                   // every row
            }
            try? await Task.sleep(for: .microseconds(i % 40 * 125))
            task.cancel()
            do {
                _ = try await task.value
                finished += 1
            } catch is CancellationError {
                cancelled += 1
            } catch {
                Log.error("cancel probe: read \(i) failed: \(error)")
                if let error = error as? DatabaseError, error.resultCode == .SQLITE_INTERRUPT {
                    interrupted.append("\(error)")
                } else {
                    other.append("\(error)")
                }
            }
        }
        check("a cancelled read throws CancellationError, never 'SQLite error 9: interrupted', and logs no ERROR",
              interrupted.isEmpty && other.isEmpty && cancelled > 0,
              "240 reads cancelled 0-4.9 ms in: \(finished) finished first, \(cancelled) CancellationError, " +
              "\(interrupted.count) interrupted, \(other.count) other\((interrupted.first ?? other.first).map { "; first: \($0)" } ?? "")")
    }
}
