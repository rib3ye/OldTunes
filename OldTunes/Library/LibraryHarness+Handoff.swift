import AppKit
import GRDB

/// File ▸ Add Folder's "Also add to the Music app", against a stand-in for Music: what Music is
/// offered, what OldTunes keeps for itself, and that every song shows exactly once, whether
/// Music copies the files into its own folder or keeps them where they are. No Apple Event is
/// sent and Noah's Music library is never written; Music's side of a re-ingest is played by fake
/// Music-library rows in this bench's private index, like the NFC/NFD check does.
extension LibraryHarnessBench {
    func checkMusicHandoff() async {
        let base = evidence.appendingPathComponent("handoff", isDirectory: true)
        do {
            try await runHandoffChecks(base)
        } catch {
            fail("hand-off checks ran to the end", "\(error)")
        }
        await removeHandoffFixtures(base)
    }

    private func runHandoffChecks(_ base: URL) async throws {
        let fm = FileManager.default
        try? fm.removeItem(at: base)
        let media = base.appendingPathComponent("music-media", isDirectory: true)
        try fm.createDirectory(at: media, withIntermediateDirectories: true)
        let source = evidence.appendingPathComponent("fixtures", isDirectory: true)
        // Two of these are kinds Music's Info.plist doesn't list (CAF, FLAC); the stand-in refuses those.
        let album = try makeFolder(base, "album", from: source, [
            "harness-one.aiff", "harness-two.m4a", "harness-three.wav", "harness-four.caf", "verify.flac",
            "verify-id3v23.mp3", "sub/harness-nested-five.aiff", "notes.txt"])
        let expected = Self.playableFiles(under: FolderScanner.canonicalPath(album.path))

        // 1. First hand-off; Music copies what it takes into its own folder.
        let music = FakeMusicAdder(refusing: ["flac", "caf"], mediaFolder: media, firstPID: Self.fakePIDBase)
        let first = try await ingest.addFolder(album, handingOffTo: music)
        let offered = await music.offered
        let prepares = await music.prepares
        check("hand-off: Music is offered every playable file once, in Finder order, after one readiness check",
              offered == expected && prepares == 1,
              "\(offered.count) offered of \(expected.count): \(offered.map(Self.name).joined(separator: ", "))")
        check("hand-off: the report says what Music took and what it refused",
              first.handedOff.count == 5 && first.refused.map(Self.name) == ["harness-four.caf", "verify.flac"]
                  && first.notSent.isEmpty && first.stopReason == nil && first.alreadyInMusic == 0,
              "took \(first.handedOff.count), refused \(first.refused.map(Self.name)), not sent \(first.notSent.count), " +
              "already there \(first.alreadyInMusic)")
        var rows = try await folderRowNames(under: album)
        let roots = try await index.folderRoots()
        check("hand-off: only the refused files become OldTunes folder songs, and the folder is remembered",
              rows == ["harness-four.caf", "verify.flac"] && first.folderTracks == 2 && roots.contains(first.root),
              "folder songs \(rows), folderTracks \(first.folderTracks)")

        // 2. Music's re-ingest brings its copies in, at paths of its own.
        let taken = await music.taken
        try await insertFakeMusicRows(taken)
        _ = try await ingest.addFolder(album)   // the plain rescan every launch does
        rows = try await folderRowNames(under: album)
        let musicRows = try await fakeMusicRowCount(taken)
        check("hand-off: with Music's copies in the library, each of the 7 songs shows once (Music copied the files)",
              rows == ["harness-four.caf", "verify.flac"] && musicRows == 5 && rows.count + musicRows == expected.count
                  && taken.allSatisfy { $0.copy != $0.original },
              "folder songs \(rows), Music songs \(musicRows)")

        // 3. A real re-ingest drops the fake Music rows (Music never had them), and must still keep
        //    the originals out of the folder songs.
        let report = await ingest.refresh()
        rows = try await folderRowNames(under: album)
        check("hand-off: a re-ingest keeps the handed-off originals out of the folder songs",
              report.status == .ok && rows == ["harness-four.caf", "verify.flac"], "folder songs \(rows)")

        // 4. Adding the folder again with the box on: Music already has five; only the refused two go again.
        let again = FakeMusicAdder(refusing: ["flac", "caf"], mediaFolder: media, firstPID: Self.fakePIDBase + 100)
        let second = try await ingest.addFolder(album, handingOffTo: again)
        let offeredAgain = await again.offered.map(Self.name)
        check("hand-off: adding the folder again offers Music only what it doesn't have",
              offeredAgain == ["harness-four.caf", "verify.flac"] && second.alreadyInMusic == 5 && second.handedOff.isEmpty,
              "offered \(offeredAgain), already in Music \(second.alreadyInMusic)")

        // 5. No permission (or Music won't open): nothing is offered, every song is OldTunes-only.
        let denied = try makeFolder(base, "denied", from: source, ["harness-one.aiff", "harness-two.m4a", "harness-three.wav"])
        let refusedReason = "OldTunes isn’t allowed to control Music (bench)."
        let blocked = FakeMusicAdder(notReady: refusedReason, firstPID: Self.fakePIDBase + 200)
        let none = try await ingest.addFolder(denied, handingOffTo: blocked)
        rows = try await folderRowNames(under: denied)
        let offeredBlocked = await blocked.offered.count
        check("hand-off: when Music isn't ready nothing is offered, and the songs are added to OldTunes only",
              offeredBlocked == 0 && none.notSent.count == 3 && none.stopReason == refusedReason && rows.count == 3,
              "offered \(offeredBlocked), not sent \(none.notSent.count), folder songs \(rows)")

        // 6. Same folder later, permission granted, Music keeps files where they are: the folder songs
        //    give way to Music's, which now have the very same paths.
        let inPlace = FakeMusicAdder(firstPID: Self.fakePIDBase + 300)
        let moved = try await ingest.addFolder(denied, handingOffTo: inPlace)
        let movedRows = try await folderRowNames(under: denied)
        let inPlaceTaken = await inPlace.taken
        try await insertFakeMusicRows(inPlaceTaken)
        _ = try await ingest.addFolder(denied)
        let afterIngest = try await folderRowNames(under: denied)
        let inPlaceMusic = try await fakeMusicRowCount(inPlaceTaken)
        check("hand-off: folder songs from an earlier plain add leave when Music takes them, and show once (Music kept the files)",
              moved.handedOff.count == 3 && movedRows.isEmpty && afterIngest.isEmpty && inPlaceMusic == 3
                  && inPlaceTaken.allSatisfy { $0.copy == $0.original },
              "took \(moved.handedOff.count); folder songs \(movedRows) then \(afterIngest); Music songs \(inPlaceMusic)")

        // 7. Music stops answering partway: the rest are not sent, and stay in OldTunes.
        let stopping = try makeFolder(base, "stopping", from: source,
                                      ["harness-one.aiff", "harness-two.m4a", "harness-three.wav", "verify-id3v23.mp3"])
        let stopReason = "Music didn’t answer in time (bench)."
        let quitter = FakeMusicAdder(stopAt: 2, stopReason: stopReason, firstPID: Self.fakePIDBase + 400)
        let partial = try await ingest.addFolder(stopping, handingOffTo: quitter)
        rows = try await folderRowNames(under: stopping)
        let offeredBeforeStop = await quitter.offered.count
        check("hand-off: when Music stops partway, the rest stay in OldTunes and the reason is kept",
              partial.handedOff.count == 2 && partial.notSent.map(Self.name) == ["harness-two.m4a", "verify-id3v23.mp3"]
                  && partial.stopReason == stopReason && offeredBeforeStop == 3
                  && rows == ["harness-two.m4a", "verify-id3v23.mp3"],
              "took \(partial.handedOff.map(Self.name)), not sent \(partial.notSent.map(Self.name)), folder songs \(rows)")

        try await checkReingestDuringHandoff(base, source)
        try await checkRebuildRestore(album, first)
        checkHandoffAlert(first, partial)
    }

    /// Music announces each add, so a re-ingest can rescan the folder while files are still being
    /// offered. A file Music already took must never be a folder song at that moment.
    private func checkReingestDuringHandoff(_ base: URL, _ source: URL) async throws {
        let race = try makeFolder(base, "race", from: source, ["harness-one.aiff", "harness-two.m4a", "harness-three.wav"])
        _ = try await ingest.addFolder(race)   // plain add first, so the folder is scanned by every re-ingest
        let ingest = self.ingest, index = self.index
        let racer = FakeMusicAdder(firstPID: Self.fakePIDBase + 500) { n in
            guard n == 1 else { return [] }
            _ = await ingest.refresh()
            let rows = (try? await index.folderFiles(under: FolderScanner.canonicalPath(race.path))) ?? [:]
            return rows.keys.map(Self.name).sorted()
        }
        let report = try await ingest.addFolder(race, handingOffTo: racer)
        let observed = await racer.observed
        let during = observed[1] ?? ["(no re-ingest ran)"]
        let after = try await folderRowNames(under: race)
        check("hand-off: a re-ingest during the hand-off never keeps a song Music took as a folder song",
              during == ["harness-three.wav", "harness-two.m4a"] && after.isEmpty && report.handedOff.count == 3,
              "folder songs mid-way \(during) (harness-one.aiff was already Music's), after \(after)")
    }

    /// The index can be rebuilt from scratch (AppAssembly); the record of hand-offs then comes back
    /// from AppController's copy before the folders are scanned again.
    private func checkRebuildRestore(_ album: URL, _ first: MusicHandoffReport) async throws {
        let root = first.root
        try await index.pool.write { db in
            try db.execute(sql: "DELETE FROM music_handoff WHERE substr(path, 1, length(?)) = ?",
                           arguments: [root + "/", root + "/"])
        }
        _ = try await ingest.addFolder(album)
        let withoutRecord = try await folderRowNames(under: album)
        await ingest.restoreHandoffs(first.handedOff)
        _ = try await ingest.addFolder(album)
        let restored = try await folderRowNames(under: album)
        check("hand-off: a rebuilt index gets the record back, and the originals leave the folder songs again",
              withoutRecord.count == 7 && restored == ["harness-four.caf", "verify.flac"],
              "without the record \(withoutRecord.count) folder songs; restored \(restored)")
    }

    private func checkHandoffAlert(_ refusedSome: MusicHandoffReport, _ stopped: MusicHandoffReport) {
        let refused = MusicHandoffReport.alert(for: [refusedSome])
        Log.info("library harness: hand-off alert “\(refused?.message ?? "nil")” — \(refused?.informative ?? "")")
        check("hand-off alert: counts the songs, lists each refused file, says they stay in OldTunes",
              refused?.message == "2 of the 7 songs weren’t added to the Music app."
                  && refused?.details == "harness-four.caf\nverify.flac"
                  && refused?.informative.contains("Music didn’t accept 2 files.") == true
                  && refused?.informative.contains("in OldTunes, but not in Music") == true
                  && refused?.informative.contains("iCloud Music Library") == true,
              "\(String(describing: refused))")

        var allTaken = MusicHandoffReport(root: refusedSome.root)
        allTaken.handedOff = refusedSome.handedOff
        allTaken.alreadyInMusic = 3
        check("hand-off alert: nothing to say when Music took every new file",
              MusicHandoffReport.alert(for: [allTaken]) == nil, "")

        var both = stopped
        both.refused = [stopped.root + "/odd.caf"]
        let mixed = MusicHandoffReport.alert(for: [both, refusedSome])
        let stopAlert = MusicHandoffReport.alert(for: [stopped])
        check("hand-off alert: the stop reason comes first, says how to try again, and lists refused and unsent files apart",
              stopAlert?.informative.hasPrefix(stopped.stopReason ?? "?") == true
                  && stopAlert?.informative.contains("try again") == true
                  && stopAlert?.message == "2 of the 4 songs weren’t added to the Music app."
                  && mixed?.details.contains("Music didn’t accept:\nstopping/odd.caf\nalbum/harness-four.caf") == true
                  && mixed?.details.contains("Not sent to Music:\nstopping/harness-two.m4a") == true,
              "stop: \(String(describing: stopAlert)); mixed details: \(mixed?.details ?? "nil")")
    }

    // MARK: - Fixtures

    nonisolated private static let fakePIDBase: Int64 = -9_100_000_000_000_000_000

    /// A folder of copies of the shell-made fixtures (see LibraryHarness+Folders.swift).
    private func makeFolder(_ base: URL, _ name: String, from source: URL, _ files: [String]) throws -> URL {
        let dir = base.appendingPathComponent(name, isDirectory: true)
        for file in files {
            let target = dir.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source.appendingPathComponent(file), to: target)
        }
        return dir
    }

    /// The playable files under `root` in Finder order, found without FolderScanner.
    private static func playableFiles(under root: String) -> [String] {
        let kinds: Set<String> = ["mp3", "m4a", "aac", "aif", "aiff", "aifc", "wav", "caf", "flac"]
        var out: [String] = []
        let walker = FileManager.default.enumerator(atPath: root)
        while let relative = walker?.nextObject() as? String {
            if kinds.contains((relative as NSString).pathExtension.lowercased()) {
                out.append((root as NSString).appendingPathComponent(relative))
            }
        }
        return out.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    nonisolated private static func name(_ path: String) -> String { (path as NSString).lastPathComponent }

    private func folderRowNames(under dir: URL) async throws -> [String] {
        let rows = try await index.folderFiles(under: FolderScanner.canonicalPath(dir.path))
        return rows.keys.map(Self.name).sorted()
    }

    /// What Music's re-ingest would write for the songs it took: a library row at Music's path.
    private func insertFakeMusicRows(_ taken: [FakeMusicAdder.Taken]) async throws {
        try await index.pool.write { db in
            for song in taken {
                let title = "Handoff Bench " + Self.name(song.original)
                try db.execute(sql: """
                    INSERT INTO song (origin, persistent_id, title, location_path, bucket, location_type, sk_title)
                    VALUES (0, ?, ?, ?, 0, 1, ?)
                    """, arguments: [song.persistentID, title, song.copy, title.lowercased()])
            }
        }
    }

    private func fakeMusicRowCount(_ taken: [FakeMusicAdder.Taken]) async throws -> Int {
        let pids = taken.map(\.persistentID)
        return try await index.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM song WHERE origin = 0 AND persistent_id IN (SELECT value FROM json_each(?))",
                             arguments: [LibraryIndex.jsonArray(pids)]) ?? 0
        }
    }

    /// Leaves the index as the later checks expect it: no hand-off folders, rows, records or fake
    /// Music songs.
    private func removeHandoffFixtures(_ base: URL) async {
        let prefix = FolderScanner.canonicalPath(base.path) + "/"
        do {
            try await index.pool.write { db in
                try db.execute(sql: "DELETE FROM song WHERE origin = 1 AND substr(location_path, 1, length(?)) = ?",
                               arguments: [prefix, prefix])
                try db.execute(sql: "DELETE FROM song WHERE origin = 0 AND persistent_id BETWEEN ? AND ?",
                               arguments: [Self.fakePIDBase, Self.fakePIDBase + 10_000])
                try db.execute(sql: "DELETE FROM folder_root WHERE substr(path, 1, length(?)) = ?", arguments: [prefix, prefix])
                try db.execute(sql: "DELETE FROM music_handoff WHERE substr(path, 1, length(?)) = ?", arguments: [prefix, prefix])
            }
            await LibraryIndex.postDidChange()
        } catch {
            fail("hand-off fixtures removed from the index", "\(error)")
        }
        try? FileManager.default.removeItem(at: base)
    }
}

/// Stands in for Music.app in the hand-off checks and never sends an Apple Event. Takes every
/// file except the kinds in `refusing`; with a `mediaFolder` it copies what it takes there, like
/// Music with "Copy files to Music Media folder when adding to Library" on, so the song Music
/// lists has a different path from the original.
actor FakeMusicAdder: MusicLibraryAdding {
    struct Taken: Sendable {
        var original: String
        /// Where Music's copy lives; the original's path when Music keeps files in place.
        var copy: String
        var persistentID: Int64
    }

    private let refusing: Set<String>
    private let mediaFolder: URL?
    private let notReady: String?
    private let stopAt: Int?
    private let stopReason: String
    /// Runs inside the n-th add (0-based), before it answers; what it returns is kept in `observed`.
    private let duringAdd: (@Sendable (Int) async -> [String])?
    private var nextPID: Int64
    private(set) var prepares = 0
    private(set) var offered: [String] = []
    private(set) var taken: [Taken] = []
    private(set) var observed: [Int: [String]] = [:]

    init(refusing: Set<String> = [], mediaFolder: URL? = nil, notReady: String? = nil, stopAt: Int? = nil,
         stopReason: String = "", firstPID: Int64, duringAdd: (@Sendable (Int) async -> [String])? = nil) {
        self.refusing = refusing
        self.mediaFolder = mediaFolder
        self.notReady = notReady
        self.stopAt = stopAt
        self.stopReason = stopReason
        self.nextPID = firstPID
        self.duringAdd = duringAdd
    }

    func prepare() async -> String? {
        prepares += 1
        return notReady
    }

    func add(_ file: URL) async -> MusicAddOutcome {
        let n = offered.count
        offered.append(file.path)
        if let duringAdd { observed[n] = await duringAdd(n) }
        if n == stopAt { return .stopped(stopReason) }
        if refusing.contains(file.pathExtension.lowercased()) { return .refused("the bench's Music refuses .\(file.pathExtension)") }
        var copy = file.path
        if let mediaFolder {
            let target = mediaFolder.appendingPathComponent("\(n)-\(nextPID)-\(file.lastPathComponent)")
            do { try FileManager.default.copyItem(at: file, to: target) } catch { return .refused("copy failed: \(error)") }
            copy = target.path
        }
        let pid = nextPID
        nextPID += 1
        taken.append(Taken(original: file.path, copy: copy, persistentID: pid))
        return .added(persistentID: pid)
    }
}
