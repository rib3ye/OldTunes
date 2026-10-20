import AppKit
import AVFoundation
import GRDB
import iTunesLibrary

/// OLDTUNES_HARNESS=musicadd — the live check of File ▸ Add Folder's "Also add to the Music
/// app", run only with Noah's go-ahead: it really adds a song to his Music library, and Sync
/// Library then uploads it to his iCloud Music Library. The song is invented, a 10-second 440 Hz
/// tone tagged “OldTunes Hand-off Test Tone” by “OldTunes Test”, made fresh for each run.
///
/// It goes through the real hand-off (LibraryIngest with MusicAppLibraryAdder, what the menu
/// item does with the box on) into a private index, proves Music has the song by reading Music's
/// own database through iTunesLibrary (independent of the scripting path), then proves the
/// private index shows it exactly once after a re-ingest.
///
///   OLDTUNES_DB_PATH=/abs/scratchpad/…/index.sqlite   OLDTUNES_MUSICADD_DIR=/abs/scratchpad/…/dir
///
/// Taking the test song back out (also only with Noah's go-ahead):
///
///   OLDTUNES_MUSICADD_REMOVE=<the 16-hex-digit persistent ID the run logged>
///
/// deletes that one track from Music's library if its name is the test tone's, then moves its
/// file to the Trash.
@MainActor
enum MusicAddLiveTest {
    nonisolated static let title = "OldTunes Hand-off Test Tone"

    static func run() async {
        defer { Log.flush(); NSApp.terminate(nil) }
        let env = ProcessInfo.processInfo.environment
        if let hex = env["OLDTUNES_MUSICADD_REMOVE"] {
            await remove(hex: hex)
            return
        }
        // Both paths in a scratchpad, so the run can never touch the app's real index.
        guard let db = env["OLDTUNES_DB_PATH"], db.contains("/scratchpad/"),
              let dirPath = env["OLDTUNES_MUSICADD_DIR"], dirPath.contains("/scratchpad/") else {
            Log.error("musicadd: set OLDTUNES_DB_PATH and OLDTUNES_MUSICADD_DIR inside a scratchpad; nothing added")
            return
        }
        do {
            try await addTestTone(in: URL(fileURLWithPath: dirPath, isDirectory: true))
        } catch {
            Log.error("musicadd: FAIL \(error)")
        }
    }

    private static func addTestTone(in base: URL) async throws {
        let run = base.appendingPathComponent("run-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        let folder = run.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tone = try await makeTone(scratch: run, into: folder)
        Log.info("musicadd: made \(tone.path)")

        let index = try LibraryIndex()
        let ingest = LibraryIngest(index: index)
        let before = await ingest.refresh()
        Log.info("musicadd: private index \(index.url.path): \(before.status), \(before.musicLibrarySongs) Music songs")
        guard before.status == .ok else { return }

        let started = Date()
        let report = try await ingest.addFolder(folder, handingOffTo: MusicAppLibraryAdder())
        let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
        Log.info("musicadd: hand-off in \(seconds) s (includes starting Music and any permission prompt): " +
                 "to Music \(report.handedOff.count), refused \(report.refused.count), not sent \(report.notSent.count) " +
                 "\(report.stopReason ?? ""), folder tracks \(report.folderTracks)")
        guard report.handedOff.count == 1 else {
            Log.error("musicadd: FAIL Music didn't take the test tone; nothing was added")
            return
        }
        let pid = try await index.pool.read { db in
            try Row.fetchOne(db, sql: "SELECT persistent_id FROM music_handoff WHERE path = ?", arguments: [report.handedOff[0]])
                .flatMap { $0["persistent_id"] as Int64? }
        }
        Log.info("musicadd: Music's persistent ID for it: \(pid.map(MusicPersistentID.hex) ?? "not reported")")

        let lookup = MusicLibraryLookup()
        let found = await lookup.waitFor(persistentID: pid, title: title, seconds: 60)
        Log.info("musicadd: \(found.item == nil ? "FAIL" : "PASS") Music's database lists it after \(found.seconds) s" +
                 (found.item.map { ": “\($0.title)”, file \($0.location ?? "none"), " +
                                   "\($0.location == tone.path ? "kept in place" : "copied by Music")" } ?? ""))

        let after = await ingest.refresh()
        let rows = try await index.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id, origin, persistent_id, location_path FROM song WHERE title = ?", arguments: [title])
                .map { (origin: $0["origin"] as Int, pid: $0["persistent_id"] as Int64?, path: $0["location_path"] as String?) }
        }
        let folderRows = try await index.folderFiles(under: FolderScanner.canonicalPath(folder.path))
        let once = rows.count == 1 && rows[0].origin == Track.Origin.musicLibrary.rawValue && folderRows.isEmpty
            && (pid == nil || rows[0].pid == pid)
        Log.info("musicadd: \(once ? "PASS" : "FAIL") after a re-ingest (\(after.status)) the private index shows it once: " +
                 "\(rows.count) row(s) \(rows.map { "origin \($0.origin) at \($0.path ?? "nil")" }), \(folderRows.count) folder row(s)")
        let hex = (found.item?.persistentID ?? pid).map(MusicPersistentID.hex) ?? "unknown"
        Log.info("musicadd: SUMMARY music=\(found.item == nil ? "FAIL" : "PASS") once=\(once ? "PASS" : "FAIL"); " +
                 "the test song stays in Music until removed with OLDTUNES_MUSICADD_REMOVE=\(hex)")
    }

    /// A 10-second 440 Hz tone with invented tags, alone in `folder`; the plain PCM it is made
    /// from stays in `scratch`, outside the folder, so only the tagged file is offered to Music.
    private static func makeTone(scratch: URL, into folder: URL) async throws -> URL {
        let pcm = scratch.appendingPathComponent("tone.caf")
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 441_000),
              let samples = buffer.floatChannelData?[0] else { throw CocoaError(.featureUnsupported) }
        buffer.frameLength = 441_000
        for i in 0..<441_000 { samples[i] = 0.2 * sin(2 * .pi * 440 * Float(i) / 44_100) }
        do {
            let file = try AVAudioFile(forWriting: pcm, settings: format.settings)
            try file.write(from: buffer)
        }

        func item(_ id: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = id
            item.value = value as NSString
            return item
        }
        let out = folder.appendingPathComponent("\(title).m4a")
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: pcm), presetName: AVAssetExportPresetAppleM4A) else {
            throw CocoaError(.featureUnsupported)
        }
        session.metadata = [
            item(.iTunesMetadataSongName, title),
            item(.iTunesMetadataArtist, "OldTunes Test"),
            item(.iTunesMetadataAlbum, "OldTunes Test"),
            item(.iTunesMetadataUserGenre, "Test"),
            item(.iTunesMetadataUserComment, "Made by OldTunes' musicadd live check. Safe to delete."),
        ]
        guard #available(macOS 15, *) else { throw CocoaError(.featureUnsupported) }
        try await session.export(to: out, as: .m4a)
        return out
    }

    /// Deletes the test song from Music's library, refusing any track not named like it. Reads
    /// Music's database first, so running it again after a removal only confirms the removal.
    private static func remove(hex: String) async {
        guard let pid = MusicPersistentID.bitPattern(fromHex: hex) else {
            Log.error("musicadd: “\(hex)” is not a 16-hex-digit persistent ID; nothing removed")
            return
        }
        let lookup = MusicLibraryLookup()
        if await lookup.waitForRemoval(persistentID: pid, seconds: 0) {
            Log.info("musicadd: PASS Music's database doesn't list \(hex); nothing to remove")
            return
        }
        guard await MusicAutomation.launchHiddenIfNeeded() else {
            Log.error("musicadd: \(MusicAutomation.addUnavailableReason) Nothing removed.")
            return
        }
        let expected = title
        let file: URL?
        do {
            file = try await MusicScriptingSession.run { () -> URL? in
                let session = try MusicScriptingSession(for: .addingSongs)
                let track = try session.track(persistentID: pid)
                let name = try session.name(of: track)
                guard name == expected else {
                    throw TagEditError(message: "Track \(hex) is “\(name ?? "nil")”, not the test tone; nothing removed.")
                }
                let file = try? session.location(of: track)
                try session.delete(track)
                return file
            }
        } catch {
            Log.error("musicadd: FAIL removing \(hex): \(error.localizedDescription)")
            return
        }
        Log.info("musicadd: removed \(hex) from Music's library")
        // Music may move a file in its Media folder to the Trash itself as it deletes the track.
        if let file, file.lastPathComponent.contains(expected) {
            var trashed: NSURL?
            do {
                try FileManager.default.trashItem(at: file, resultingItemURL: &trashed)
                Log.info("musicadd: moved its file to the Trash: \(trashed?.path ?? file.path)")
            } catch where !FileManager.default.fileExists(atPath: file.path) {
                Log.info("musicadd: its file is already gone from \(file.path); Music removed it")
            } catch {
                Log.error("musicadd: FAIL its file is still at \(file.path): \(error.localizedDescription)")
            }
        }
        let gone = await lookup.waitForRemoval(persistentID: pid, seconds: 60)
        Log.info("musicadd: \(gone ? "PASS" : "FAIL") Music's database no longer lists \(hex)")
    }
}

/// Reads Music's library database through iTunesLibrary, apart from the scripting path that
/// writes it. Owns its own ITLibrary off the main actor.
private actor MusicLibraryLookup {
    struct Item: Sendable { var title: String; var location: String?; var persistentID: Int64 }
    private var library: ITLibrary?

    /// iTunesLibrary's unsigned persistent ID as the index's Int64 bit pattern.
    private static func pid(_ item: ITLibMediaItem) -> Int64 { Int64(bitPattern: item.persistentID.uint64Value) }

    private func items() -> [ITLibMediaItem] {
        if library == nil { library = try? ITLibrary(apiVersion: "1.0", options: .none) }
        guard let library else { return [] }
        _ = library.reloadData()
        return library.allMediaItems
    }

    /// Polls until Music lists the song: by persistent ID when the add reported one, else by title.
    func waitFor(persistentID: Int64?, title: String, seconds: Double) async -> (item: Item?, seconds: String) {
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            let match = items().first { item in
                if let persistentID { return Self.pid(item) == persistentID }
                return item.title == title
            }
            if let match {
                let item = Item(title: match.title, location: match.location?.path, persistentID: Self.pid(match))
                return (item, String(format: "%.1f", Date().timeIntervalSince(start)))
            }
            try? await Task.sleep(for: .seconds(2))
        }
        return (nil, String(format: "%.1f", Date().timeIntervalSince(start)))
    }

    /// Polls until Music no longer lists the song; always looks at least once.
    func waitForRemoval(persistentID: Int64, seconds: Double) async -> Bool {
        let start = Date()
        while true {
            if !items().contains(where: { Self.pid($0) == persistentID }) { return true }
            if Date().timeIntervalSince(start) >= seconds { return false }
            try? await Task.sleep(for: .seconds(2))
        }
    }
}
