import AppKit
import GRDB
import SFBAudioEngine

/// Harness checks added by the independent verification pass: more audio formats, folder edge
/// cases, browser case variants, the C-API row decoder, Deadline cancellation, and reads racing
/// writes.
extension LibraryHarnessBench {
    // MARK: - Formats

    /// Two fixtures the shell cannot make: an MP3 with COMM/TCMP frames and a FLAC with a cover.
    /// Both are written with SFBAudioEngine onto copies of the shell-made files.
    func prepareFormatFixtures(in dir: URL) throws {
        let fm = FileManager.default
        let mp3 = dir.appendingPathComponent("verify-id3v23.mp3")
        let flac = dir.appendingPathComponent("verify.flac")
        guard fm.fileExists(atPath: mp3.path), fm.fileExists(atPath: flac.path) else {
            Log.info("library harness: no MP3/FLAC fixtures from tools/make-library-fixtures.sh; format checks will fail")
            return
        }
        let commTCMP = dir.appendingPathComponent("verify-comm-tcmp.mp3")
        try? fm.removeItem(at: commTCMP)
        try fm.copyItem(at: mp3, to: commTCMP)
        let mp3File = try AudioFile(readingPropertiesAndMetadataFrom: commTCMP)
        mp3File.metadata.title = "Verify COMM Song"
        mp3File.metadata.comment = "verify comment"
        mp3File.metadata.isCompilation = true
        mp3File.metadata.bpm = 128
        mp3File.metadata.grouping = "verify group"
        try mp3File.writeMetadata()

        let art = dir.appendingPathComponent("verify-art.flac")
        try? fm.removeItem(at: art)
        try fm.copyItem(at: flac, to: art)
        let flacFile = try AudioFile(readingPropertiesAndMetadataFrom: art)
        flacFile.metadata.title = "Verify FLAC With Art"
        if let png = Self.fixtureArtwork() {
            flacFile.metadata.attachPicture(AttachedPicture(imageData: png, type: .frontCover))
        }
        try flacFile.writeMetadata()
    }

    func checkFolderFormats() async throws {
        let rows = try await folderRowsByName()
        func row(_ name: String) -> Track? {
            let t = rows[name]
            if t == nil { fail("fixture \(name) indexed", "") }
            return t
        }
        func describe(_ t: Track) -> String {
            "'\(t.title)' / '\(t.artist)' / '\(t.album)' / aa '\(t.albumArtist)' / c '\(t.composer)' / '\(t.genre)' " +
            "year \(t.year) track \(t.trackNumber)/\(t.trackCount) disc \(t.discNumber)/\(t.discCount) bpm \(t.bpm) " +
            "comment '\(t.comments)' grouping '\(t.grouping)' \(fmt(t.duration)) s \(t.kind) \(t.bitRate) kbps \(t.sampleRate) Hz art=\(t.hasArtwork)"
        }

        if let t = row("verify-id3v23.mp3") {
            check("ID3v2.3 MP3: TIT2/TPE1/TALB/TPE2/TCOM, TCON '(17)' → Rock, TYER 1997, TRCK 4/10, TPOS 2/3",
                  t.title == "Verify MP3 Song" && t.artist == "MP3 Artist" && t.album == "MP3 Album"
                      && t.albumArtist == "MP3 Album Artist" && t.composer == "MP3 Composer" && t.genre == "Rock"
                      && t.year == 1997 && t.trackNumber == 4 && t.trackCount == 10 && t.discNumber == 2 && t.discCount == 3
                      && t.kind == "MPEG audio file" && t.bitRate == 128,
                  describe(t))
        }
        if let t = row("verify-id3v24.mp3") {
            check("ID3v2.4 MP3: TDRC '2001-05-02' → 2001, TRCK 9", t.title == "Verify MP3 v24" && t.year == 2001
                      && t.trackNumber == 9 && t.genre == "Electronic", describe(t))
        }
        if let t = row("verify-comm-tcmp.mp3") {
            let compilation = try await index.pool.read { db in
                try Int.fetchOne(db, sql: "SELECT is_compilation FROM song WHERE id = ?", arguments: [t.id]) ?? -1
            }
            check("MP3 COMM, TCMP, TBPM, grouping (written by TagLib)",
                  t.title == "Verify COMM Song" && t.comments == "verify comment" && compilation == 1 && t.isCompilation
                      && t.bpm == 128 && t.grouping == "verify group",
                  describe(t) + " is_compilation=\(compilation) Track.isCompilation=\(t.isCompilation)")
        }
        if let t = row("verify.flac") {
            check("FLAC Vorbis comments via AVFoundation's vorb/ identifiers",
                  t.title == "Verify FLAC Song" && t.artist == "FLAC Artist" && t.album == "FLAC Album" && t.year == 2010
                      && t.trackNumber == 5 && t.trackCount == 11 && t.genre == "Ambient" && t.kind == "FLAC audio file"
                      && t.duration > 1 && t.bitRate > 0,
                  describe(t))
        }
        if let t = row("verify-vorbis-extra.flac") {
            let (compilation, artistKey) = try await index.pool.read { db -> (Int, String) in
                let row = try Row.fetchOne(db, sql: "SELECT is_compilation, sk_artist FROM song WHERE id = ?", arguments: [t.id])
                return (row?[0] ?? -1, row?[1] ?? "")
            }
            check("FLAC lower-case fields, TOTALTRACKS, disc '2/4', COMPILATION, BPM, ARTISTSORT",
                  t.title == "Vorbis Extra" && t.artist == "VX Artist" && t.albumArtist == "VX Album Artist"
                      && t.composer == "VX Composer" && t.genre == "Folk" && t.year == 1972 && t.trackNumber == 3
                      && t.trackCount == 7 && t.discNumber == 2 && t.discCount == 4 && t.bpm == 99
                      && t.comments == "vx comment" && compilation == 1 && t.isCompilation
                      && artistKey == SortKey.make("Artist, VX"),
                  describe(t) + " is_compilation=\(compilation) Track.isCompilation=\(t.isCompilation) sk_artist='\(artistKey)'")
        }
        if let t = row("verify-art.flac") {
            let started = ContinuousClock.now
            let art = await ingest.artworkData(for: t)
            check("FLAC embedded cover: hasArtwork and artworkData", t.hasArtwork && (art?.count ?? 0) > 0,
                  "\(art?.count ?? 0) bytes in \(ms(since: started)); \(describe(t))")
        }
        if let t = row("verify-id3v1.mp3") {
            check("ID3v1-only MP3 (TAG trailer, no ID3v2): title, artist, album, year, track, genre",
                  t.title == "Verify ID3v1 Song" && t.artist == "V1 Artist" && t.album == "V1 Album" && t.year == 1985
                      && t.trackNumber == 6 && t.genre == "Jazz",
                  describe(t))
        }
        if let t = row("verify-alac.m4a") {
            check("ALAC m4a: kind Apple Lossless, ©day 2012, trkn 2/8", t.title == "Verify ALAC Song"
                      && t.kind == "Apple Lossless audio file" && t.year == 2012 && t.trackNumber == 2 && t.trackCount == 8,
                  describe(t))
        }
        if let t = row("harness-three.wav") {
            // say writes 22,050 Hz 16-bit mono: 352.8 kbps.
            check("PCM bit rate from the format (22,050 Hz × 16 bit × 1 ch = 353 kbps)", t.bitRate == 353, describe(t))
        }
        let zeroRate = rows.filter { $0.value.bitRate == 0 }.keys.sorted()
        check("every folder track has a bit rate", zeroRate.isEmpty, zeroRate.joined(separator: ", "))
    }

    private func folderRowsByName() async throws -> [String: Track] {
        let ids = try await index.pool.read { db in try Int64.fetchAll(db, sql: "SELECT id FROM song WHERE origin = 1") }
        var out: [String: Track] = [:]
        for track in try await index.tracks(ids: ids) {
            if let name = track.fileURL?.lastPathComponent { out[name] = track }
        }
        return out
    }

    // MARK: - Folder edge cases

    func checkFolderEdges() async throws {
        let dir = evidence.appendingPathComponent("fixtures", isDirectory: true)
        let rootsBefore = try await index.folderRoots()

        let ghost = evidence.appendingPathComponent("no-such-folder-\(UUID().uuidString)")
        do {
            _ = try await ingest.addFolder(ghost)
            fail("addFolder on a missing path throws", "returned without error")
        } catch {
            let roots = try await index.folderRoots()
            check("addFolder on a missing path throws and stores no root", roots == rootsBefore, "\(error)")
        }

        // A file inside an added folder, added again on its own: already indexed, nothing changes.
        let one = dir.appendingPathComponent("harness-one.aiff")
        let againOne = try await ingest.addFolder(one)
        let folderCount = try await index.rowCount(origin: .folder)
        check("adding a single already-indexed file changes nothing", againOne == 0, "\(againOne) changed, \(folderCount) folder rows")

        // Retag a file in place: the rescan re-reads it, keeps its id, and search sees the new title.
        let target = dir.appendingPathComponent("verify-comm-tcmp.mp3")
        let before = try await folderRowsByName()["verify-comm-tcmp.mp3"]
        let file = try AudioFile(readingPropertiesAndMetadataFrom: target)
        file.metadata.title = "Qwertyuiop Retagged"
        try file.writeMetadata()
        // mtime has 1 s resolution; make sure the rewrite is visible even inside the same second.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: target.path)
        let changed = try await ingest.addFolder(dir)
        let after = try await folderRowsByName()["verify-comm-tcmp.mp3"]
        let hits = try await index.ids(for: TrackQuery(search: "qwertyuiop"))
        check("a retagged folder file is re-read on rescan, keeps its id, and is searchable by its new title",
              changed == 1 && after?.id == before?.id && after?.title == "Qwertyuiop Retagged" && hits == [after?.id].compactMap { $0 },
              "\(changed) re-read; id \(before?.id ?? -1) → \(after?.id ?? -1); title '\(after?.title ?? "nil")'; search → \(hits)")

        try await checkMusicOwnedPathIsSkipped(dir)
    }

    /// A file the Music library already lists must not be indexed twice. Simulated with a fake
    /// Music-library row whose path is the folder file's path in the other Unicode normalization
    /// (Music and a directory walk can disagree on NFC vs NFD for accented names).
    private func checkMusicOwnedPathIsSkipped(_ dir: URL) async throws {
        let rows = try await folderRowsByName()
        guard let (name, track) = rows.first(where: { $0.key.contains("caf") && $0.key.unicodeScalars.contains { $0.value > 127 } }),
              let path = try await index.pool.read({ db in
                  try String.fetchOne(db, sql: "SELECT location_path FROM song WHERE id = ?", arguments: [track.id])
              }) else {
            return fail("accented fixture (café-nfc.aiff) indexed", "\(rows.keys.sorted())")
        }
        // The stored spelling, not `fileURL.path`: URL hands back the decomposed form.
        // Byte comparisons: Swift's == treats the two normalizations as equal.
        let nfc = path.precomposedStringWithCanonicalMapping
        let isNFC = path.utf8.elementsEqual(nfc.utf8)
        let other = isNFC ? path.decomposedStringWithCanonicalMapping : nfc
        let fakePID: Int64 = -42_4242
        try await index.pool.write { db in
            try db.execute(sql: """
                INSERT INTO song (origin, persistent_id, title, location_path, bucket, location_type, sk_title)
                VALUES (0, ?, 'Fake Music Copy', ?, 0, 1, 'fake music copy')
                """, arguments: [fakePID, other])
        }
        let countBefore = try await index.rowCount(origin: .folder)
        _ = try await ingest.addFolder(dir)
        let dropped = try await folderRowsByName()[name] == nil
        let countAfter = try await index.rowCount(origin: .folder)
        check("a folder file the Music library already owns is not indexed twice (path differs only in NFC/NFD)",
              dropped && countAfter == countBefore - 1 && !path.utf8.elementsEqual(other.utf8),
              "'\(name)' \(isNFC ? "NFC" : "NFD") on disk (\(path.utf8.count) bytes), Music row in the other form " +
              "(\(other.utf8.count) bytes); folder rows \(countBefore) → \(countAfter)")

        try await index.pool.write { db in
            try db.execute(sql: "DELETE FROM song WHERE persistent_id = ?", arguments: [fakePID])
        }
        _ = try await ingest.addFolder(dir)
        let restored = try await folderRowsByName()[name]
        check("…and is indexed again once Music no longer has it", restored != nil && restored?.id != track.id,
              "id \(track.id) → \(restored?.id ?? -1) (ids are never reused)")
    }

    // MARK: - Pragmas

    /// §4.2's pragmas as a reader connection actually sees them.
    func checkPragmas() async throws {
        let values = try await index.pool.read { db in
            (try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "",
             try Int.fetchOne(db, sql: "PRAGMA synchronous") ?? -1,
             try Int.fetchOne(db, sql: "PRAGMA cache_size") ?? 0,
             try Int.fetchOne(db, sql: "PRAGMA temp_store") ?? -1,
             try Int.fetchOne(db, sql: "PRAGMA mmap_size") ?? 0,
             try Int.fetchOne(db, sql: "PRAGMA foreign_keys") ?? -1)
        }
        check("§4.2 pragmas in effect (WAL, synchronous NORMAL, 64 MiB cache, temp in memory, 256 MiB mmap, FKs on)",
              values.0 == "wal" && values.1 == 1 && values.2 == -65_536 && values.3 == 2 && values.4 == 268_435_456 && values.5 == 1,
              "\(values)")
    }

    // MARK: - Browser

    func checkBrowserCaseVariants() async throws {
        let pair = try await index.pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT artist FROM song WHERE artist COLLATE NOCASE =
                  (SELECT artist FROM song WHERE artist <> '' GROUP BY artist COLLATE NOCASE
                   HAVING COUNT(DISTINCT artist) > 1 LIMIT 1)
                GROUP BY artist
                """)
        }
        let artists = try await index.browserValues(.artist, for: TrackQuery())
        let folded = Set(artists.map { $0.lowercased() })
        check("artist pane merges spellings that differ only in case", folded.count == artists.count,
              "\(artists.count) entries, \(folded.count) case-folded; example \(pair)")
        guard pair.count >= 2 else { return }
        let byFirst = try await index.ids(for: TrackQuery(artist: pair[0]))
        let bySecond = try await index.ids(for: TrackQuery(artist: pair[1]))
        let shown = artists.filter { $0.caseInsensitiveCompare(pair[0]) == .orderedSame }
        let raw = try await index.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM song WHERE artist IN (?, ?)", arguments: [pair[0], pair[1]]) ?? 0
        }
        check("filtering by either spelling returns both spellings' songs", byFirst == bySecond && byFirst.count == raw,
              "shown as \(shown); '\(pair[0])' → \(byFirst.count), '\(pair[1])' → \(bySecond.count), rows with either: \(raw)")
        let albums = try await index.browserValues(.album, for: TrackQuery(artist: pair[1]))
        check("the album pane narrows by either spelling", !albums.isEmpty, "\(albums.count) albums")
    }

    // MARK: - Row decoding

    /// The C-API decoder against an independent decode by column name through GRDB.
    func checkTrackDecoding() async throws {
        let all = try await index.ids(for: TrackQuery(sort: TrackSort(field: .artist, ascending: true)))
        let reference = try await index.pool.read { db -> [Int64: Track] in
            var out: [Int64: Track] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT * FROM song") {
                let added: Int64 = row["added_at"]
                let bucket = Track.Bucket(rawValue: row["bucket"]) ?? .cloud
                let path: String? = row["location_path"]
                let t = Track(id: row["id"], origin: Track.Origin(rawValue: row["origin"]) ?? .musicLibrary,
                              persistentID: row["persistent_id"], cloudID: row["cloud_id"], storeItemID: row["store_item_id"],
                              title: row["title"], artist: row["artist"], album: row["album"], albumArtist: row["album_artist"],
                              composer: row["composer"], genre: row["genre"], comments: row["comments"], grouping: row["grouping"],
                              year: row["year"], trackNumber: row["track_number"], trackCount: row["track_count"],
                              discNumber: row["disc_number"], discCount: row["disc_count"], bpm: row["bpm"],
                              duration: Double(row["total_time_ms"] as Int64) / 1000,
                              dateAdded: added == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(added)),
                              playCount: row["play_count"], rating: row["rating"], kind: row["kind"], bitRate: row["bit_rate"],
                              sampleRate: row["sample_rate"], fileSize: row["file_size"], hasArtwork: row["has_artwork"],
                              albumPID: row["album_pid"], bucket: bucket, isCloud: row["is_cloud"],
                              locationType: row["location_type"],
                              fileURL: bucket == .local ? path.map { URL(fileURLWithPath: $0) } : nil,
                              isCompilation: row["is_compilation"],
                              // OldTunes' own choice wins over the ingested one. Optional reads so
                              // this also runs against an index from before those columns existed.
                              isChecked: (row["checked_override"] as Bool?) ?? (row["is_checked"] as Bool?) ?? true,
                              soundCheckEnergy: (row["sound_check_energy"] as Int?) ?? 0)
                out[t.id] = t
            }
            return out
        }

        var times: [Double] = []
        var scanned: [Track] = []
        for _ in 0..<5 {
            let started = ContinuousClock.now
            scanned = try await index.tracks(ids: all)
            times.append(msValue(since: started))
        }
        let mismatched = scanned.filter { reference[$0.id] != $0 }
        check("tracks(ids:) for every row equals an independent by-name decode, in order",
              scanned.count == all.count && scanned.map(\.id) == all && mismatched.isEmpty,
              "\(scanned.count) rows, median \(fmt(times.sorted()[2])) ms (scan path); \(mismatched.count) differ" +
              (mismatched.first.map { "; first: \($0) vs \(String(describing: reference[$0.id]))" } ?? ""))

        // The bound-list path, in chunks below the scan threshold, plus unknown and repeated ids.
        let chunk = Array(all.shuffled().prefix(LibraryIndex.scanThreshold - 1))
        let started = ContinuousClock.now
        let listed = try await index.tracks(ids: chunk)
        let listedMs = ms(since: started)
        let visible = Array(all[100..<140])
        let visibleStarted = ContinuousClock.now
        let page = try await index.tracks(ids: visible + [-1, 999_999_999] + [visible[0]])
        let pageMs = ms(since: visibleStarted)
        check("tracks(ids:) bound-list path: order kept, unknown ids skipped, repeats repeated",
              listed.map(\.id) == chunk && listed.allSatisfy { reference[$0.id] == $0 }
                  && page.map(\.id) == visible + [visible[0]],
              "\(chunk.count) ids in \(listedMs); a 40-row page in \(pageMs)")
    }

    // MARK: - Deadline

    func checkDeadlineCancellation() async {
        let hang: @Sendable () async throws -> Int = {
            await withUnsafeContinuation { (_: UnsafeContinuation<Int, Never>) in }
        }
        var started = ContinuousClock.now
        let task = Task { try await withTimeout(30, hang) }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let result = await task.result
        let cancelledMs = msValue(since: started)
        var isCancellation = false
        if case .failure(let error) = result { isCancellation = error is CancellationError }
        check("withTimeout returns promptly when its caller is cancelled", isCancellation && cancelledMs < 1_000,
              "\(fmt(cancelledMs)) ms (cancelled at 100 ms of a 30 s deadline), \(result)")

        started = ContinuousClock.now
        let quick = try? await withTimeout(30) { 42 }
        check("withTimeout returns a fast body's value at once", quick == 42 && msValue(since: started) < 100,
              "\(fmt(msValue(since: started))) ms")

        started = ContinuousClock.now
        let alreadyCancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await withTimeout(30, hang)
        }
        let early = await alreadyCancelled.result
        check("withTimeout in an already-cancelled task throws at once",
              (try? early.get()) == nil && msValue(since: started) < 1_000, "\(fmt(msValue(since: started))) ms")
    }

    // MARK: - Concurrency

    /// Reads (sorts, searches, browser panes, rows) racing a full refresh and tag-edit updates.
    /// Nothing may throw, and a final refresh must restore every edited title.
    func checkConcurrentReadsDuringWrites() async throws {
        // Victims come from the Music library only: the closing refresh rewrites those rows from
        // Music, but never a folder row (only a changed file is rescanned). Picking from every id
        // left an edited folder title behind about one run in fifty (16 folder rows of 15,916).
        let musicIDs = try await index.pool.read { db in try Int64.fetchAll(db, sql: "SELECT id FROM song WHERE origin = 0") }
        let victims = Array(musicIDs.shuffled().prefix(20))
        let index = self.index
        let ingest = self.ingest
        let queries = ["o", "be", "the", "love", "nderw", "a b", "x\"y", "beatles"]
        let started = ContinuousClock.now

        let refresh = Task { await ingest.refresh() }
        // Artwork is read on the same actor that parses the Music library, so it waits for the parse.
        let artTrack = allTracks.first { $0.hasArtwork && $0.isCloudOnly }
        let artTask = Task { () -> (Int, Double) in
            try? await Task.sleep(for: .milliseconds(300))
            let artStarted = ContinuousClock.now
            var data: Data?
            if let artTrack { data = await ingest.artworkData(for: artTrack) }
            return (data?.count ?? 0, self.msValue(since: artStarted))
        }
        let readErrors = await withTaskGroup(of: String?.self) { group in
            for i in 0..<300 {
                group.addTask {
                    do {
                        let field = TrackSortField.allCases[i % TrackSortField.allCases.count]
                        let query = TrackQuery(search: i % 3 == 0 ? queries[i % queries.count] : "",
                                               sort: TrackSort(field: field, ascending: i % 2 == 0))
                        let found = try await index.ids(for: query)
                        if i % 10 == 0 { _ = try await index.tracks(ids: Array(found.prefix(50))) }
                        if i % 25 == 0 { _ = try await index.browserValues(.artist, for: query) }
                        return nil
                    } catch {
                        return "read \(i): \(error)"
                    }
                }
            }
            for (n, id) in victims.enumerated() {
                group.addTask {
                    do {
                        try await index.update(ids: [id], applying: TagPatch(title: "Concurrent Edit \(n) Plmokn"))
                        return nil
                    } catch {
                        return "update \(id): \(error)"
                    }
                }
            }
            var errors: [String] = []
            for await error in group { if let error { errors.append(error) } }
            return errors
        }
        let racedReport = await refresh.value
        let racedMs = ms(since: started)
        let (artBytes, artMs) = await artTask.value
        Log.info("library harness: artworkData requested 300 ms into a refresh: \(artBytes) bytes after \(fmt(artMs)) ms " +
                 "(it waits for the iTunesLibrary parse on the same actor)")
        check("300 reads and 20 updates racing a refresh: nothing throws", readErrors.isEmpty && racedReport.status == .ok,
              "\(readErrors.count) errors in \(racedMs); refresh \(racedReport.status) \(readErrors.prefix(3))")

        let report = await ingest.refresh()
        let leftover = try await index.ids(for: TrackQuery(search: "plmokn"))
        check("a refresh after the race restores every edited title from Music", leftover.isEmpty && report.status == .ok,
              "\(leftover.count) edited rows left")
    }
}
