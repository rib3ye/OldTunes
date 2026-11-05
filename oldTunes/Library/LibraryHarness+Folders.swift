import AppKit
import AVFoundation
import GRDB
import iTunesLibrary
import SFBAudioEngine

/// The second half of the library harness: added folders, tag-edit updates, FTS integrity, and
/// the 3x-scale benchmark (RESEARCH.md §10 R11).
extension LibraryHarnessBench {
    private struct FolderFixtures {
        var dir: URL
        var tagged: URL
        var id3: URL
        var deleteMe: URL
        var expected: [String]
    }

    // MARK: - Folders

    func checkFolders() async throws {
        let fixtures = try await prepareFixtures()
        var started = ContinuousClock.now
        let added = try await ingest.addFolder(fixtures.dir)
        check("addFolder indexes every playable fixture", added == fixtures.expected.count,
              "\(added) of \(fixtures.expected.count) files in \(ms(since: started))")

        var rows = try await folderTracks()
        check("folder rows have origin folder and bucket local",
              rows.count == fixtures.expected.count && rows.values.allSatisfy { $0.origin == .folder && $0.bucket == .local },
              rows.keys.map { URL(fileURLWithPath: $0).lastPathComponent }.sorted().joined(separator: ", "))
        check("m4p, m4b and non-audio files are skipped",
              !rows.keys.contains { $0.hasSuffix(".m4p") || $0.hasSuffix(".m4b") || $0.hasSuffix(".txt") }, "")

        if let t = rows[fixtures.tagged.path] {
            let ok = t.title == "Harness Tagged Song" && t.artist == "The Harness Band" && t.album == "Fixture Album"
                && t.albumArtist == "Harness Various" && t.composer == "Harness Composer" && t.genre == "Rock"
                && t.year == 2005 && t.trackNumber == 3 && t.trackCount == 12 && t.discNumber == 1 && t.discCount == 2
                && t.duration > 0.5 && t.kind == "AAC audio file" && t.sampleRate > 0
            check("MP4 tags read: title, artist, album, album artist, composer, genre, year, track 3/12, disc 1/2", ok,
                  "'\(t.title)' / '\(t.artist)' / '\(t.album)' / aa '\(t.albumArtist)' / c '\(t.composer)' / '\(t.genre)' " +
                  "year \(t.year) track \(t.trackNumber)/\(t.trackCount) disc \(t.discNumber)/\(t.discCount) " +
                  "bpm \(t.bpm) \(fmt(t.duration)) s \(t.kind) \(t.sampleRate) Hz \(t.bitRate) kbps art=\(t.hasArtwork) " +
                  "comment '\(t.comments)' grouping '\(t.grouping)'")
            started = ContinuousClock.now
            let art = await ingest.artworkData(for: t)
            check("artworkData for a folder track reads embedded art", (art?.count ?? 0) > 0,
                  "\(art?.count ?? 0) bytes in \(ms(since: started))")
            let song = await ingest.cloudSong(for: t)
            check("cloudSong for a folder track is nil", song == nil, "")
        } else {
            fail("tagged.m4a indexed", "")
        }
        if let t = rows[fixtures.id3.path] {
            // No year here: TagLib (via SFBAudioEngine) wrote no TDRC frame into this AIFF (checked
            // with xxd), so there is nothing to read. Year is covered by the MP4 fixture.
            check("ID3 tags read from an AIFF: title, artist, album, genre, track 7/9",
                  t.title == "Harness ID3 Song" && t.artist == "ID3 Artist" && t.album == "ID3 Album"
                      && t.genre == "Jazz" && t.trackNumber == 7 && t.trackCount == 9,
                  "'\(t.title)' / '\(t.artist)' / '\(t.album)' / '\(t.genre)' year \(t.year) track \(t.trackNumber)/\(t.trackCount) kind \(t.kind)")
        }
        let untagged = rows.values.first { $0.fileURL?.lastPathComponent == "harness-one.aiff" }
        check("an untagged file is named after its file, like iTunes", untagged?.title == "harness-one",
              "'\(untagged?.title ?? "nil")', \(fmt(untagged?.duration ?? 0)) s, \(untagged?.kind ?? "")")

        let found = try await index.ids(for: TrackQuery(search: "harness-"))
        let named = rows.values.filter { $0.title.hasPrefix("harness-") }.map(\.id)
        check("folder tracks are searchable by title", Set(named).isSubset(of: Set(found)) && !named.isEmpty,
              "'harness-' → \(found.count) rows, \(named.count) fixtures named harness-*")
        let onMac = try await index.ids(for: TrackQuery(scope: .onThisMac))
        check(".onThisMac = 5 library files + folder tracks", onMac.count == 5 + fixtures.expected.count, "\(onMac.count)")

        let again = try await ingest.addFolder(fixtures.dir)
        check("adding the same folder again changes nothing", again == 0, "\(again) changed")

        let before = try await folderIDs()
        let report = await ingest.refresh()
        logReport("refresh with folder", report)
        var after = try await folderIDs()
        check("refresh() keeps folder rows and their ids", after == before && report.folderTracks == fixtures.expected.count,
              "\(after.count) rows, report.folderTracks=\(report.folderTracks)")
        check("refresh() leaves the Music-library count alone", report.musicLibrarySongs == 15_900,
              "\(report.musicLibrarySongs)")

        try FileManager.default.removeItem(at: fixtures.deleteMe)
        let report2 = await ingest.refresh()
        logReport("refresh after deleting delete-me.wav", report2)
        after = try await folderIDs()
        var expected = before
        expected[fixtures.deleteMe.path] = nil
        check("deleting one file + refresh() removes exactly that row", after == expected && after.count == before.count - 1,
              "\(before.count) → \(after.count); other ids unchanged: \(after == expected)")
        rows = try await folderTracks()
        Log.info("library harness: folder rows now \(rows.count)")
    }

    private func folderTracks() async throws -> [String: Track] {
        let ids = try await index.pool.read { db in
            try Int64.fetchAll(db, sql: "SELECT id FROM song WHERE origin = 1")
        }
        var out: [String: Track] = [:]
        for track in try await index.tracks(ids: ids) {
            if let path = track.fileURL?.path { out[path] = track }
        }
        return out
    }

    private func folderIDs() async throws -> [String: Int64] {
        try await index.pool.read { db in
            var map: [String: Int64] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT location_path, id FROM song WHERE origin = 1") {
                map[row[0]] = row[1]
            }
            return map
        }
    }

    /// tools/make-library-fixtures.sh made the say/afconvert files (run it once per evidence
    /// folder); this adds the two tagged ones and a file to delete.
    private func prepareFixtures() async throws -> FolderFixtures {
        let dir = evidence.appendingPathComponent("fixtures", isDirectory: true)
        let source = evidence.appendingPathComponent("fixtures-src/tagged-source.aiff")
        let fm = FileManager.default

        let deleteMe = dir.appendingPathComponent("delete-me.wav")
        try? fm.removeItem(at: deleteMe)
        try fm.copyItem(at: dir.appendingPathComponent("harness-three.wav"), to: deleteMe)

        let tagged = dir.appendingPathComponent("tagged.m4a")
        try? fm.removeItem(at: tagged)
        try await exportTaggedM4A(from: source, to: tagged)

        let id3 = dir.appendingPathComponent("id3-tagged.aiff")
        try? fm.removeItem(at: id3)
        try fm.copyItem(at: source, to: id3)
        let file = try AudioFile(readingPropertiesAndMetadataFrom: id3)
        file.metadata.title = "Harness ID3 Song"
        file.metadata.artist = "ID3 Artist"
        file.metadata.albumTitle = "ID3 Album"
        file.metadata.genre = "Jazz"
        file.metadata.releaseDate = "1999"
        file.metadata.trackNumber = 7
        file.metadata.trackTotal = 9
        try file.writeMetadata()
        try prepareFormatFixtures(in: dir)

        // Counted independently of FolderScanner: everything except the files meant to be skipped
        // (wrong extension, or hidden: a dot file or anything inside a dot folder).
        var expected: [String] = []
        if let walker = fm.enumerator(atPath: dir.path) {
            while let relative = walker.nextObject() as? String {
                let ext = (relative as NSString).pathExtension.lowercased()
                let hidden = (relative as NSString).pathComponents.contains { $0.hasPrefix(".") }
                if !hidden && ["aiff", "aif", "m4a", "wav", "caf", "mp3", "flac"].contains(ext) { expected.append(relative) }
            }
        }
        Log.info("library harness: fixtures \(expected.sorted())")
        return FolderFixtures(dir: dir, tagged: tagged, id3: id3, deleteMe: deleteMe, expected: expected)
    }

    private func exportTaggedM4A(from source: URL, to target: URL) async throws {
        func item(_ id: AVMetadataIdentifier, _ value: any NSCopying & NSObjectProtocol, _ type: CFString? = nil) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = id
            item.value = value
            if let type { item.dataType = type as String }
            return item
        }
        var items = [
            item(.iTunesMetadataSongName, "Harness Tagged Song" as NSString),
            item(.iTunesMetadataArtist, "The Harness Band" as NSString),
            item(.iTunesMetadataAlbum, "Fixture Album" as NSString),
            item(.iTunesMetadataAlbumArtist, "Harness Various" as NSString),
            item(.iTunesMetadataComposer, "Harness Composer" as NSString),
            item(.iTunesMetadataUserGenre, "Rock" as NSString),
            item(.iTunesMetadataReleaseDate, "2005" as NSString),
            item(.iTunesMetadataUserComment, "fixture comment" as NSString),
            item(.iTunesMetadataGrouping, "fixture group" as NSString),
            item(.iTunesMetadataTrackNumber, Data([0, 0, 0, 3, 0, 12, 0, 0]) as NSData),
            item(.iTunesMetadataDiscNumber, Data([0, 0, 0, 1, 0, 2]) as NSData),
        ]
        if let png = Self.fixtureArtwork() {
            items.append(item(.iTunesMetadataCoverArt, png as NSData, kCMMetadataBaseDataType_PNG))
        }
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetAppleM4A) else {
            throw CocoaError(.featureUnsupported)
        }
        session.metadata = items
        if #available(macOS 15, *) {
            try await session.export(to: target, as: .m4a)
        } else {
            throw CocoaError(.featureUnsupported)
        }
    }

    static func fixtureArtwork() -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        for x in 0..<32 { for y in 0..<32 { rep.setColor(NSColor(deviceRed: 0.2, green: 0.4, blue: 0.9, alpha: 1), atX: x, y: y) } }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Tag-edit update

    func checkUpdate() async throws {
        let all = try await index.ids(for: TrackQuery(sort: TrackSort(field: .name, ascending: true)))
        guard let target = try await index.tracks(ids: [all[all.count / 2]]).first else {
            return fail("update target found", "")
        }
        let newTitle = "Zyxwvut Harness Retitled"
        let postsBefore = changePosts
        var started = ContinuousClock.now
        try await index.update(ids: [target.id], applying: TagPatch(title: newTitle, genre: "Harness Genre"))
        let updateMs = ms(since: started)

        started = ContinuousClock.now
        let hits = try await index.ids(for: TrackQuery(search: "zyxwvut"))
        let searchMs = ms(since: started)
        check("update(ids:applying:) makes the new title findable at once", hits == [target.id],
              "'\(target.title)' → '\(newTitle)'; update \(updateMs), search \(searchMs) → \(hits)")
        let shortHits = try await index.ids(for: TrackQuery(search: "zy"))
        check("…through the prefix table too", shortHits.contains(target.id), "'zy' → \(shortHits.count) rows")
        if target.title.count >= 3 {
            let old = try await index.ids(for: TrackQuery(search: target.title))
            check("…and no longer found by the old title", !old.contains(target.id), "'\(target.title)' → \(old.count) rows")
        }
        let reloaded = try await index.tracks(ids: [target.id]).first
        let byName = try await index.ids(for: TrackQuery(sort: TrackSort(field: .name, ascending: true)))
        let position = byName.firstIndex(of: target.id) ?? -1
        check("…with its sort key recomputed", reloaded?.title == newTitle && position > byName.count * 9 / 10,
              "name-sort position \(all.firstIndex(of: target.id) ?? -1) → \(position) of \(byName.count)")
        let genres = try await index.browserValues(.genre, for: TrackQuery())
        check("…and the browser sees the new genre", genres.contains("Harness Genre"), "")
        check("update posts .libraryDidChange", changePosts > postsBefore, "")

        // Re-ingest restores Music's own title: the upsert path must re-index FTS as well.
        let report = await ingest.refresh()
        logReport("refresh after update", report)
        let restored = try await index.ids(for: TrackQuery(search: "zyxwvut"))
        var backByOld = [target.id]
        if target.title.count >= 3 { backByOld = try await index.ids(for: TrackQuery(search: target.title)) }
        check("refresh() re-indexes a changed row (edit gone, old title found again)",
              restored.isEmpty && backByOld.contains(target.id), "'zyxwvut' → \(restored.count) rows")
    }

    // MARK: - Watching Music

    /// Posts the library-changed distributed notification three times in quick succession, the
    /// way Music.app bursts while it saves, and expects exactly one refresh, 5 s after the last.
    /// (A distributed notification is not an Apple Event and does not touch Music's library.)
    func checkChangeWatching() async throws {
        await ingest.startWatchingForChanges()
        let before = await ingest.refreshCount
        var lastPost = Date()
        for _ in 0..<3 {
            notices.post()
            lastPost = Date()
            try await Task.sleep(for: .milliseconds(700))
        }
        let deadline = Date().addingTimeInterval(90)
        while await ingest.refreshCount == before, Date() < deadline {
            try await Task.sleep(for: .milliseconds(250))
        }
        try await Task.sleep(for: .seconds(3))   // room for a second, unwanted refresh to show up
        let after = await ingest.refreshCount
        let delay = await ingest.lastRefreshStarted.map { $0.timeIntervalSince(lastPost) } ?? -1
        check("3 change notifications → exactly one debounced refresh", after == before + 1 && delay >= 4.9,
              "\(after - before) refresh(es), started \(fmt(delay)) s after the last post")
    }

    /// Notifications that never let up for 5 s, as while Music brings down a long Download or
    /// takes a long Add to Playlist: one every 3 s for 36 s. The re-ingest must still start about
    /// 30 s after the first (LibraryIngest.changeMaxWait), while they are still coming, so songs
    /// show up as they land rather than only at the end.
    func checkChangeMaxWait() async throws {
        await ingest.startWatchingForChanges()
        // Past the previous check's refresh and any notification it left waiting.
        try await Task.sleep(for: .seconds(6))
        let before = await ingest.refreshCount
        let firstPost = Date()
        var lastPost = firstPost
        var firstStart: Date?
        for _ in 0..<13 {
            notices.post()
            lastPost = Date()
            for _ in 0..<12 {
                try await Task.sleep(for: .milliseconds(250))
                if firstStart == nil, let started = await ingest.lastRefreshStarted, started > firstPost { firstStart = started }
            }
        }
        // The re-ingest started meanwhile, and one more for the notifications after it began.
        let deadline = Date().addingTimeInterval(120)
        while await ingest.refreshCount < before + 2, Date() < deadline {
            try await Task.sleep(for: .milliseconds(250))
        }
        try await Task.sleep(for: .seconds(3))
        let after = await ingest.refreshCount
        let wait = firstStart.map { $0.timeIntervalSince(firstPost) } ?? -1
        check("change notifications that keep coming still re-ingest within 30 s of the first, not after the last",
              (29...33).contains(wait) && (firstStart.map { $0 < lastPost } ?? false),
              "the first re-ingest started \(fmt(wait)) s after the first of 13 posts, "
              + "\(fmt(lastPost.timeIntervalSince(firstPost))) s of posts; \(after - before) refreshes in all")
    }

    /// The change debounce's rule (LibraryIngest.changeWait), on durations alone: while Music
    /// keeps posting, the max wait starts at 30 s and doubles after each re-ingest it starts, up to
    /// 5 minutes, and 5 s of quiet puts it back. Otherwise an hours-long Download or a ⌘A add
    /// would re-ingest the library every 30 s throughout (RESEARCH.md §6.9). Posts nothing.
    func checkChangeBackOff() {
        func ms(_ d: Duration) -> Int { Int(d.components.seconds) * 1000 + Int(d.components.attoseconds / 1_000_000_000_000_000) }
        /// The debounce on a made-up clock, as LibraryIngest runs it: Music's notices at `posts`
        /// (ms); when each re-ingest starts.
        func reingests(_ posts: [Int]) -> [Int] {
            var forced = 0, first: Int?, last: Int?, pending: (fire: Int, forced: Int)?
            var starts: [Int] = []
            for t in posts {
                if let p = pending, p.fire < t {
                    starts.append(p.fire)
                    (forced, first, pending) = (p.forced, nil, nil)
                }
                let since = t - (first ?? t)
                first = first ?? t
                let next = LibraryIngest.changeWait(sinceFirst: .milliseconds(since), sinceLast: last.map { .milliseconds(t - $0) },
                                                    forced: &forced)
                last = t
                pending = (t + ms(next.wait), next.forcedOnStart)
            }
            return starts + (pending.map { [$0.fire] } ?? [])
        }
        let maxWaits = (0...6).map { ms(LibraryIngest.changeMaxWait(after: $0)) / 1000 }
        let stream = Array(stride(from: 0, through: 900_000, by: 2_800))
        let backedOff = reingests(stream)
        let quietThenMore = reingests(stream + Array(stride(from: 1_000_000, through: 1_040_000, by: 2_800)))
        // A run that ends just before a forced re-read leaves nothing waiting to settle: the quiet
        // before the next run is what puts the wait back.
        let endedForced = reingests(Array(stride(from: 0, through: 28_000, by: 2_800)) + Array(stride(from: 100_000, through: 140_000, by: 2_800)))
        check("while Music posts every 2.8 s for 15 minutes, the library is re-read 30, 60, 120, 240 and 300 s after the "
              + "first notice each waited for, then once 5 s after the last, not every 30 s; 5 s of quiet puts it back to 30 s, "
              + "even after a run that ended on a forced re-read",
              maxWaits == [30, 60, 120, 240, 300, 300, 300] && backedOff == [30_000, 90_800, 212_400, 452_800, 753_600, 903_800]
              && quietThenMore.suffix(2) == [1_030_000, 1_044_200] && endedForced == [30_000, 130_000, 144_200],
              "max waits \(maxWaits) s; re-reads at \(backedOff.map { fmt(Double($0) / 1000) }) s; after the quiet "
              + "\(quietThenMore.suffix(2).map { fmt(Double($0) / 1000) }) s; after a forced end \(endedForced) ms")
        let benchOwn = reingests([0, 700, 1_400] + (0..<13).map { 20_000 + 3_000 * $0 })
        check("…and this bench's own two change checks see what they expect on it: one re-read 5 s after a burst, then one "
              + "30 s after the first of 13 posts 3 s apart, and one 5 s after the last",
              benchOwn == [6_400, 50_000, 61_000], "re-reads at \(benchOwn) ms")
    }

    /// The stale-playlists retry's rule (LibraryIngest.staleRetryWait), on counts alone: a re-ingest
    /// that found Music's playlists edited while it read them reads them again 5 s later, and while
    /// every pass finds another edit (an add whose chunks land faster than iTunesLibrary loads, with
    /// Music posting nothing) 30 s later, then twice as long each time, up to 5 minutes, not every
    /// 5 s for the whole add; a pass that reads them whole ends the run (RESEARCH.md §6.10).
    /// Posts nothing.
    func checkStaleRetryBackOff() {
        var passes = 0
        func wait(stale: Bool) -> Int? { LibraryIngest.staleRetryWait(stale: stale, stalePasses: &passes).map { Int($0.components.seconds) } }
        let inARow = (0..<7).map { _ in wait(stale: true) }
        let counted = passes
        let whole = wait(stale: false)
        let afterWhole = passes
        let next = [wait(stale: true), wait(stale: true)]
        check("a re-ingest that found the playlists edited while it read them reads them again 5 s later; while each pass "
              + "finds another edit, 30, 60, 120, 240, then 300 s later; one that reads them whole asks for none, and the "
              + "next edit is read again 5 s later",
              inARow == [5, 30, 60, 120, 240, 300, 300] && counted == 7 && whole == nil && afterWhole == 0 && next == [5, 30],
              "waits \(inARow.map { $0.map(String.init) ?? "none" }) s, \(counted) in a row; then \(whole.map(String.init) ?? "none"), "
              + "\(afterWhole) in a row; then \(next.map { $0.map(String.init) ?? "none" }) s")
    }

    /// How a failed check whose counts a library-changed notice can upset is told: Music posts
    /// its own on its own (iCloud Library syncing, a play count; it keeps running hidden once
    /// oldTunes starts it), and each starts a re-ingest. Nil: a plain failure, the check having
    /// heard only the notices it posted itself. Otherwise how many were Music's, for a BLOCKED.
    nonisolated static func musicNotices(heard: Int, posted: Int) -> Int? {
        heard > posted ? heard - posted : nil
    }

    /// `check`, for a check that counts re-ingests (`musicNotices`): a failure while Music posted
    /// notices of its own is BLOCKED, to run again, not FAIL.
    func checkCounting(_ name: String, _ ok: Bool, _ detail: String, heard: Int, posted: Int) {
        guard !ok, let own = Self.musicNotices(heard: heard, posted: posted) else {
            return check(name, ok, detail)
        }
        blocked(name, "Music posted \(own) \(own == 1 ? "notice" : "notices") of its own during the check; run again. \(detail)")
    }

    /// `checkCounting`, with the notices heard around a check that began at `began`
    /// (`LibraryHarnessNotices.counts`).
    func checkCounting(_ name: String, _ ok: Bool, _ detail: String, since began: Date) {
        let counts = notices.counts(since: began)
        checkCounting(name, ok, detail, heard: counts.heard, posted: counts.posted)
    }

    /// LibraryIngest.refreshIfIdle, through which the download watch asks for its re-reads
    /// (RESEARCH.md §6.9): a re-ingest when none is running, waiting its turn, or scheduled by a
    /// change notice, and nothing otherwise. Posts one library-changed notice, as
    /// checkChangeWatching does; a running oldTunes re-reads its own library once for it. Its
    /// counts are exact, so a part that fails while Music posted notices of its own is BLOCKED
    /// (`checkCounting`).
    func checkRefreshIfIdle() async throws {
        await ingest.startWatchingForChanges()
        let began = Date()
        // Past the previous check's re-ingests and anything they left waiting.
        try await Task.sleep(for: .seconds(6))
        var before = await ingest.refreshCount
        let idle = await ingest.refreshIfIdle()
        var after = await ingest.refreshCount
        checkCounting("refreshIfIdle with nothing running or coming: one re-ingest, and its report",
                      idle?.status == .ok && after == before + 1,
                      "\(idle.map { "\($0.status)" } ?? "skipped"), \(after - before) refreshes", since: began)

        before = await ingest.refreshCount
        let mark = Date()
        let running = Task { await self.ingest.refresh() }
        let started = Date().addingTimeInterval(10)
        while (await ingest.lastRefreshStarted ?? .distantPast) <= mark, Date() < started {
            try await Task.sleep(for: .milliseconds(20))
        }
        let during = await ingest.refreshIfIdle()
        _ = await running.value
        try await Task.sleep(for: .seconds(1))
        after = await ingest.refreshCount
        checkCounting("…while one runs: skipped, and only that one re-ingest happens",
                      during == nil && after == before + 1, "\(during == nil ? "skipped" : "ran one"), \(after - before) refreshes",
                      since: began)

        // A notice schedules a re-ingest 5 s later; one asked for meanwhile is that one.
        let heardBefore = notices.total
        before = await ingest.refreshCount
        notices.post()
        let posted = Date()
        let arrival = Date().addingTimeInterval(3)
        while notices.total == heardBefore, Date() < arrival { try await Task.sleep(for: .milliseconds(20)) }
        // The ingest heard it as this bench did, and has handed it to the debounce by now.
        try await Task.sleep(for: .milliseconds(300))
        let pending = await ingest.refreshIfIdle()
        let settled = Date().addingTimeInterval(60)
        while await ingest.refreshCount == before, Date() < settled { try await Task.sleep(for: .milliseconds(250)) }
        try await Task.sleep(for: .seconds(3))   // room for a second, unwanted one
        after = await ingest.refreshCount
        let delay = await ingest.lastRefreshStarted.map { $0.timeIntervalSince(posted) } ?? -1
        checkCounting("…right after a library-changed notice: skipped, then exactly the one debounced re-ingest, 5 s after the notice",
                      notices.total - heardBefore == 1 && pending == nil && after == before + 1 && delay >= 4.9,
                      "notices heard \(notices.total - heardBefore); \(pending == nil ? "skipped" : "ran one"), then "
                      + "\(after - before) refreshes, the last \(fmt(delay)) s after the notice", since: began)
    }

    /// LibraryIngest.refreshSoon, through which an add's end asks for its re-read (RESEARCH.md
    /// §6.10): a re-ingest at once when none is running; one more behind one that is, so it reads
    /// what the add just did; nothing when one is already waiting its turn or scheduled by a
    /// change notice. Posts one library-changed notice. Its counts are exact (`checkCounting`).
    func checkRefreshSoon() async throws {
        let began = Date()
        // Past the previous check's notice and the re-ingest it brought.
        try await Task.sleep(for: .seconds(6))
        var before = await ingest.refreshCount
        let idle = await ingest.refreshSoon()
        var after = await ingest.refreshCount
        let written = await ingest.lastWrittenRefreshStarted, latest = await ingest.lastRefreshStarted
        checkCounting("refreshSoon with nothing running or coming: one re-ingest, its report, and it counts as the library read",
                      idle?.status == .ok && after == before + 1 && written != nil && written == latest,
                      "\(idle.map { "\($0.status)" } ?? "skipped"), \(after - before) refreshes", since: began)

        before = await ingest.refreshCount
        var mark = Date()
        let running = Task { await self.ingest.refresh() }
        var started = Date().addingTimeInterval(10)
        while (await ingest.lastRefreshStarted ?? .distantPast) <= mark, Date() < started {
            try await Task.sleep(for: .milliseconds(20))
        }
        let behind = await ingest.refreshSoon()
        _ = await running.value
        after = await ingest.refreshCount
        checkCounting("…while one runs: one more behind it, so it reads what came since",
                      behind?.status == .ok && after == before + 2,
                      "\(behind.map { "\($0.status)" } ?? "skipped"), \(after - before) refreshes", since: began)

        before = await ingest.refreshCount
        mark = Date()
        let first = Task { await self.ingest.refresh() }
        started = Date().addingTimeInterval(10)
        while (await ingest.lastRefreshStarted ?? .distantPast) <= mark, Date() < started {
            try await Task.sleep(for: .milliseconds(20))
        }
        let second = Task { await self.ingest.refresh() }
        try await Task.sleep(for: .milliseconds(100))   // it has asked by now, and waits its turn
        let waitingItsTurn = await ingest.refreshSoon()
        _ = await first.value
        _ = await second.value
        after = await ingest.refreshCount
        checkCounting("…with one already waiting its turn: nothing, never a second behind the first",
                      waitingItsTurn == nil && after == before + 2,
                      "\(waitingItsTurn == nil ? "skipped" : "ran one"), \(after - before) refreshes", since: began)

        let heardBefore = notices.total
        before = await ingest.refreshCount
        notices.post()
        let arrival = Date().addingTimeInterval(3)
        while notices.total == heardBefore, Date() < arrival { try await Task.sleep(for: .milliseconds(20)) }
        // The ingest heard it as this bench did, and has handed it to the debounce by now.
        try await Task.sleep(for: .milliseconds(300))
        let pending = await ingest.refreshSoon()
        let settled = Date().addingTimeInterval(60)
        while await ingest.refreshCount == before, Date() < settled { try await Task.sleep(for: .milliseconds(250)) }
        try await Task.sleep(for: .seconds(3))   // room for a second, unwanted one
        after = await ingest.refreshCount
        checkCounting("…right after a library-changed notice: nothing, then only the debounced re-ingest",
                      pending == nil && after == before + 1,
                      "\(pending == nil ? "skipped" : "ran one"), then \(after - before) refreshes", since: began)
    }

    /// A re-ingest that read Music's playlists before a playlist edit landed leaves them as edited
    /// and stores no hash (RESEARCH.md §6.8), then retries after the delay and settling window, on its own
    /// path, not through the change debounce: Music's last notice may have come before the edit,
    /// and then nothing else would rewrite them (LibraryIngest.staleRetryWait; the log says
    /// "library: playlists changed while they were being read; reading them again in 5 s"). The
    /// edit is to this bench's scratch index, never to Music. A notice of Music's during it can do
    /// the retry's job, so whether it would pass or fail, a run in which Music posted is BLOCKED
    /// (`checkCounting`).
    func checkStalePlaylistsRetry() async throws {
        guard let list = try await index.playlists().first(where: { $0.kind == .regular }) else {
            return fail("a re-ingest that read the playlists before an edit asks for another pass", "no plain playlist in the index")
        }
        let edited = "Harness Edited While Reading"
        let began = Date()
        // Past the previous check's notice and the re-ingest it brought.
        try await Task.sleep(for: .seconds(6))
        let before = await ingest.refreshCount
        let mark = Date()
        let reading = Task { await self.ingest.refresh() }
        let started = Date().addingTimeInterval(10)
        while (await ingest.lastRefreshStarted ?? .distantPast) <= mark, Date() < started {
            try await Task.sleep(for: .milliseconds(20))
        }
        // It read the edit stamp as it began, and iTunesLibrary takes seconds to load: the edit lands meanwhile.
        try await Task.sleep(for: .milliseconds(300))
        try await index.apply(.renamed(list.id, to: edited))
        _ = await reading.value
        let firstEnded = Date()
        let kept = try await index.playlists().first { $0.id == list.id }?.name
        let deadline = Date().addingTimeInterval(60)
        while await ingest.refreshCount < before + 2, Date() < deadline { try await Task.sleep(for: .milliseconds(250)) }
        try await Task.sleep(for: .seconds(3))   // room for a third, unwanted one
        let after = await ingest.refreshCount
        let gap = await ingest.lastRefreshStarted.map { $0.timeIntervalSince(firstEnded) } ?? -1
        let restored = try await index.playlists().first { $0.id == list.id }?.name
        let counts = notices.counts(since: began)
        checkCounting("a re-ingest that read the playlists before an edit landed leaves the edit, and one more pass follows by "
                      + "itself, after the retry delay and settling window, and rewrites them from Music",
                      kept == edited && after == before + 2 && restored == list.name && gap < 15 && counts.heard == counts.posted,
                      "playlist \(MusicPersistentID.hex(list.id)): edit kept \(kept == edited), \(after - before) refreshes, "
                      + "Music's name back \(restored == list.name); the second began \(fmt(gap)) s after the first ended",
                      heard: counts.heard, posted: counts.posted)
    }

    // MARK: - Timeouts

    /// A body that never finishes and ignores cancellation, like the hung MusicKit requests of
    /// §3.6. `withTimeout` must give up on time; a nested call is fenced by an outer 3 s timeout
    /// so the harness cannot hang even if that regresses.
    func checkDeadline() async {
        let hang: @Sendable () async throws -> Int = {
            await withUnsafeContinuation { (_: UnsafeContinuation<Int, Never>) in }
        }
        var started = ContinuousClock.now
        let mine = try? await withTimeout(0.3, hang)
        let mineMs = msValue(since: started)
        check("withTimeout returns at its deadline when the body hangs", mine == nil && mineMs < 1_000,
              "\(fmt(mineMs)) ms for a 0.3 s deadline")

        started = ContinuousClock.now
        _ = try? await withTimeout(3) { try await withTimeout(0.3, hang) }
        let supportMs = msValue(since: started)
        Log.info("library harness: nested withTimeout(0.3) on the same hung body " +
                 (supportMs > 2_900 ? "never returned; the outer 3 s fence fired" : "returned") +
                 " after \(fmt(supportMs)) ms")
    }

    // MARK: - FTS integrity

    func checkFTSIntegrity() async throws {
        for table in ["song_fts", "song_tri"] {
            do {
                try await index.pool.write { db in
                    // rank = 1 also compares the index against the external content table.
                    try db.execute(sql: "INSERT INTO \(table)(\(table), rank) VALUES('integrity-check', 1)")
                }
                check("FTS integrity-check \(table) against song", true, "after ingest, edits, folder add and delete")
            } catch {
                fail("FTS integrity-check \(table) against song", "\(error)")
            }
        }
        let sizes = try await index.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT name, SUM(pgsize) AS bytes FROM dbstat GROUP BY name ORDER BY bytes DESC LIMIT 8")
                .map { "\($0["name"] as String? ?? "?")=\(($0["bytes"] as Int64? ?? 0) / 1024)KB" }
        }
        Log.info("library harness: largest objects \(sizes.joined(separator: " "))")
    }

    // MARK: - Scale (R11)

    /// Copies the library three times into a scratch index (47,700 rows, the size §4.4 was
    /// measured at) and re-times the sorts and searches.
    func checkScale() async throws {
        let url = evidence.appendingPathComponent("index_x3.sqlite")
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        let big = try LibraryIndex(path: url)
        let columns = SongRecord.columns.filter { $0 != "persistent_id" }.joined(separator: ", ")
        let source = index.url.path
        let started = ContinuousClock.now
        try await big.pool.writeWithoutTransaction { db in
            try db.execute(sql: "ATTACH DATABASE ? AS src", arguments: [source])
            try db.inTransaction {
                for _ in 0..<3 {
                    try db.execute(sql: "INSERT INTO song (\(columns)) SELECT \(columns) FROM src.song WHERE origin = 0")
                }
                try db.execute(sql: "ANALYZE")
                return .commit
            }
            try db.execute(sql: "DETACH DATABASE src")
        }
        let rows = try await big.count()
        Log.info("library harness: R11 built \(rows)-row index in \(ms(since: started))")

        // The same one-letter search with the bulk write still in the WAL, then after a checkpoint.
        for label in ["before checkpoint", "after checkpoint"] {
            if label == "after checkpoint" {
                _ = try await big.pool.writeWithoutTransaction { db in try db.checkpoint(.truncate) }
            }
            var times: [Double] = []
            for _ in 0..<5 {
                let t = ContinuousClock.now
                _ = try await big.ids(for: TrackQuery(search: "o"))
                times.append(msValue(since: t))
            }
            Log.info("library harness: R11 'o' \(label): median \(fmt(times.sorted()[2])) ms")
        }

        var parts: [String] = []
        var slowestSort = 0.0
        for field in [TrackSortField.name, .artist, .album, .dateAdded] {
            var times: [Double] = []
            for _ in 0..<7 {
                let t = ContinuousClock.now
                _ = try await big.ids(for: TrackQuery(sort: TrackSort(field: field, ascending: true)))
                times.append(msValue(since: t))
            }
            let median = times.sorted()[3]
            slowestSort = max(slowestSort, median)
            parts.append("\(field.rawValue)=\(fmt(median))")
        }
        for text in ["o", "oa", "oas", "oasis", "nderw", "the beatles"] {
            var times: [Double] = []
            var count = 0
            for _ in 0..<5 {
                let t = ContinuousClock.now
                count = try await big.ids(for: TrackQuery(search: text)).count
                times.append(msValue(since: t))
            }
            parts.append("'\(text)'=\(fmt(times.sorted()[2]))(\(count))")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        check("R11: at 3x (\(rows) rows) every sort stays under 16.7 ms (one frame)", rows == 47_700 && slowestSort < 16.7,
              "median ms: \(parts.joined(separator: " ")); file \(size / 1_048_576) MB")
    }
}

/// HARNESS ONLY. The library-changed notices heard during the change checks, each either one this
/// bench posted or one of Music's. Music posts its own by itself (`musicNotices`), and a re-ingest
/// one starts can still be running when a check begins, so a check counts from before it began.
@MainActor
final class LibraryHarnessNotices {
    /// How long before a check its notices still count: the 5 s debounce plus the longest re-ingest.
    static let lookBack: TimeInterval = 25

    private var observer: (any NSObjectProtocol)?
    private var ownOnTheWay = 0
    private var arrivals: [(at: Date, own: Bool)] = []

    /// All the notices heard so far.
    var total: Int { arrivals.count }

    func start() {
        observer = DistributedNotificationCenter.default().addObserver(forName: .ITLibraryDidChange, object: nil,
                                                                       queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.arrived() }
        }
    }

    func stop() {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
    }

    /// Posts the notice Music posts. The next one to arrive is taken for it.
    func post() {
        ownOnTheWay += 1
        DistributedNotificationCenter.default().postNotificationName(
            .ITLibraryDidChange, object: nil, userInfo: nil, deliverImmediately: true)
    }

    /// The notices heard from `lookBack` before `began` until now, and how many were this bench's.
    func counts(since began: Date) -> (heard: Int, posted: Int) {
        let counted = arrivals.filter { $0.at >= began.addingTimeInterval(-Self.lookBack) }
        return (counted.count, counted.filter(\.own).count)
    }

    private func arrived() {
        let own = ownOnTheWay > 0
        if own { ownOnTheWay -= 1 }
        arrivals.append((Date(), own))
    }
}
