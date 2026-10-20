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
            DistributedNotificationCenter.default().postNotificationName(
                .ITLibraryDidChange, object: nil, userInfo: nil, deliverImmediately: true)
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
