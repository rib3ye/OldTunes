import AppKit
import AVFoundation
import iTunesLibrary
import ScriptingBridge

/// OLDTUNES_HARNESS=musicdownload — the live check of Download (RESEARCH.md §6.9, §10-R7), run
/// only with Noah's go-ahead, on a Bench build: a Debug build reaches more of Music than what
/// ships (RESEARCH.md §3.1). It really downloads one song from his iCloud Music Library to this
/// Mac. The file uses disk, and no script can take it back: afterwards, in Music, choose the song
/// and Remove Download. Until then the library bench's counts fail ("5 local files", "15,895
/// cloud-only", ".onThisMac = 5 library files + folder tracks", "R1: the 5 local Music files are
/// readable by the app"), since one more song is a file. The only live check that can't clean up
/// after itself.
///
/// It sends the real MusicSongDownloader's `download` (what Download sends for each song), but
/// waits up to 10 minutes for Music's answer instead of 30 s, to learn whether Music answers at
/// once or only once the file is down. Then it reads Music's own database through iTunesLibrary,
/// apart from the scripting path, every 2 s for up to 10 minutes, and logs:
/// - how long Music took to answer, and what it answered;
/// - each library-changed notification Music posted, by its time after the request;
/// - when the song's location turned to a file, when that file was there, and when its size held
///   still across two looks (with the size each time it changed);
/// - that the song kept its persistent ID (a song with its title, artist, album and length under
///   an ID the library didn't have before the request fails at once, as its new ID; look-alikes
///   that were there before are duplicates, never its new ID, and when more than one is new,
///   none is named), and that exactly one more song is a file than before. A read of the library
///   that comes back empty, or with more songs gone than the one asked about, stops the check
///   with "couldn’t read the library", naming no song (`readable`); and nothing is sent unless
///   two reads just before the request both hold the song and are within a song of each other
///   (`startAgrees`), the look-alikes of both counting as there before;
/// - the file: its extension, whether it is a package (a .movpkg), whether OldTunes may open it,
///   and whether AVFoundation calls it protected. Never its name: Music names its media files
///   after the song, and the log names the song only by persistent ID;
/// - what Music answers a second `download` of the same song, now on this Mac;
/// - whether Music stayed hidden and in the background, and which app was in front, before,
///   during (each change) and after.
///
///   OLDTUNES_DOWNLOAD_PID=<the 16-hex-digit persistent ID of one song only in iCloud>
///
/// Pick a short song. It must be a Music library song that is only in iCloud (no file on this
/// Mac); anything else is refused before anything is sent.
@MainActor
enum MusicDownloadLiveTest {
    static func run() async {
        defer { Log.flush(); NSApp.terminate(nil) }
        guard let hex = ProcessInfo.processInfo.environment["OLDTUNES_DOWNLOAD_PID"],
              let pid = MusicPersistentID.bitPattern(fromHex: hex) else {
            Log.error("musicdownload: set OLDTUNES_DOWNLOAD_PID to a song's 16-hex-digit persistent ID; nothing changed")
            return
        }
        let reader = MusicSongReader()
        let before = await reader.look(for: pid)
        guard let song = before.song, song.isSong, song.isRemote, song.location == nil else {
            Log.error("musicdownload: \(hex) isn't a song in Music's library that is only in iCloud " +
                      "(\(before.song.map { "song \($0.isSong), remote \($0.isRemote), file \($0.location != nil)" } ?? "not listed")); nothing changed")
            return
        }
        Log.info("musicdownload: \(hex), \(String(format: "%.0f", Double(song.milliseconds) / 1000)) s long, " +
                 "\(before.files) songs are files before; \(musicState())")

        var results: [(String, Bool)] = []
        func step(_ name: String, _ ok: Bool, _ detail: String) {
            results.append((name, ok))
            Log.info("musicdownload: \(ok ? "PASS" : "FAIL") \(name) — \(detail)")
        }
        func summary() {
            Log.info("musicdownload: SUMMARY " + results.map { "\($0.0)=\($0.1 ? "PASS" : "FAIL")" }.joined(separator: " ") +
                     "; remove the download by hand: Music ▸ the song ▸ Remove Download")
        }

        let downloader = MusicSongDownloader(replyTimeout: 600)
        if let reason = await downloader.prepare() {
            Log.error("musicdownload: \(reason) Nothing changed.")
            return
        }
        Log.info("musicdownload: Music ready: \(musicState())")
        // Every later read, and which look-alikes were there already, is measured against these,
        // so nothing is sent without two that agree (`startAgrees`).
        let firstLook = await reader.look(for: pid, like: song)
        let start = await reader.look(for: pid, like: song)
        guard Self.startAgrees(firstLook.songs, start.songs) else {
            Log.error("musicdownload: \(unreadable) just before the request (\(firstLook.songs) songs, then \(start.songs)); " +
                      "nothing changed")
            return
        }
        guard firstLook.song != nil, start.song != nil else {
            Log.error("musicdownload: \(hex) left Music's library before the request; nothing changed")
            return
        }
        let filesBefore = start.files
        // Songs that already look like this one (a 20-year library has duplicates): never its new ID.
        let older = Set((firstLook.lookalikes + start.lookalikes).map(\.persistentID))

        // Every library-changed notification from here on, by when it came.
        let arrivals = Arrivals()
        let observer = DistributedNotificationCenter.default().addObserver(forName: .ITLibraryDidChange, object: nil,
                                                                           queue: .main) { _ in
            MainActor.assumeIsolated { arrivals.times.append(Date()) }
        }
        defer { DistributedNotificationCenter.default().removeObserver(observer) }

        let requested = Date()
        func since() -> String { String(format: "%.1f", Date().timeIntervalSince(requested)) }
        let outcome = await downloader.download(pid)
        let answered = since()
        Log.info("musicdownload: Music answered after \(answered) s: \(outcome); \(musicState())")
        step("Music took the request", outcome == .requested, "\(outcome) after \(answered) s")
        switch outcome {
        case .requested, .unanswered:
            break   // Music carries out a request it didn't answer in time: watch for the file anyway.
        case .refused, .stopped:
            summary()
            return
        }

        // Its file, as Music's database lists it.
        var isFile: String?, there: String?, stable: String?
        var lastSize: Int64?, landed: MusicSongReader.Song?
        var lastState = musicState()
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline {
            let look = await reader.look(for: pid, like: song)
            // A read that came back short would look like the song leaving, or a look-alike arriving.
            guard Self.readable(look.songs, start: start.songs) else {
                step("the same song, by its persistent ID", false, "\(unreadable), \(since()) s after the request " +
                     "(\(look.songs) songs read, \(start.songs) before)")
                summary()
                return
            }
            guard let now = look.song else {
                let newer = look.lookalikes.map(\.persistentID).filter { !older.contains($0) }
                step("the same song, by its persistent ID", false, Self.vanished(hex, after: since(), older: older, newer: newer))
                summary()
                return
            }
            if now.isFile, isFile == nil {
                isFile = since()
                Log.info("musicdownload: Music lists it as a file after \(isFile ?? "") s: \(Self.fileKind(now.location))")
            }
            if now.isFile, let url = now.location, FileManager.default.fileExists(atPath: url.path) {
                if there == nil {
                    there = since()
                    Log.info("musicdownload: its file is there after \(there ?? "") s")
                }
                let size = Self.size(of: url)
                if size != lastSize { Log.info("musicdownload: \(size) bytes after \(since()) s") }
                if let lastSize, size == lastSize, size > 0 {
                    stable = since()
                    landed = now
                    break
                }
                lastSize = size
            }
            let state = musicState()
            if state != lastState {
                Log.info("musicdownload: during, after \(since()) s: \(state)")
                lastState = state
            }
            try? await Task.sleep(for: .seconds(2))
        }
        let notes = arrivals.times.map { String(format: "+%.1f", $0.timeIntervalSince(requested)) }
        Log.info("musicdownload: Music posted \(notes.count) library-changed notifications, at \(notes.joined(separator: " ")) s")
        guard let landed, let url = landed.location else {
            step("the song came down as a file", false, "after 10 minutes: listed as a file \(isFile.map { "at \($0) s" } ?? "never"), " +
                 "file there \(there.map { "at \($0) s" } ?? "never")")
            summary()
            return
        }
        step("the song came down as a file", true, "listed as a file at \(isFile ?? "?") s, there at \(there ?? "?") s, " +
             "its size still at \(stable ?? "?") s: \(lastSize ?? 0) bytes")
        step("the same song, by its persistent ID", landed.persistentID == pid, "still \(hex)")
        let after = await reader.look(for: pid)
        step("exactly one more song is a file", Self.readable(after.songs, start: start.songs) && after.files == filesBefore + 1,
             Self.readable(after.songs, start: start.songs) ? "\(filesBefore) → \(after.files)" : unreadable)

        let protected = try? await AVURLAsset(url: url).load(.hasProtectedContent)
        Log.info("musicdownload: the file: .\(url.pathExtension), \(PlaybackCoordinator.isDirectory(url) ? "a package" : "a plain file"), " +
                 "OldTunes \(PlaybackCoordinator.isShut(url) ? "may not" : "may") open it, " +
                 "protected: \(protected.map { $0 ? "yes" : "no" } ?? "unreadable")")

        // The same request again, the song a file now: what Music answers, and what Download
        // would make of it.
        let again = Date()
        let second = await secondDownload(pid)
        Log.info("musicdownload: a second download of the song, now a file, answered after " +
                 "\(String(format: "%.1f", Date().timeIntervalSince(again))) s: \(second)")
        Log.info("musicdownload: after: \(musicState())")
        summary()
    }

    /// Why the check stops when a read of Music's library can't be trusted (`readable`).
    nonisolated static let unreadable = "couldn’t read the library, so no song is named"

    /// Whether a read of Music's library, `songs` songs, can be trusted beside the one just before
    /// the request (`start`): not empty, and not smaller by more than the one song asked about. A
    /// download takes no song away, so a read short of that missed some, and the song or a
    /// look-alike missing from it says nothing.
    nonisolated static func readable(_ songs: Int, start: Int) -> Bool {
        songs > 0 && songs + 1 >= start
    }

    /// Whether the two reads taken just before the request, of `first` and then `second` songs,
    /// agree well enough for every later read to be measured against them: neither empty, and no
    /// more than one song apart. `readable` lets a later read hold more songs than the start, so
    /// a start read that came back short would hide a look-alike, which a later, whole read could
    /// then pass off as the song's new ID.
    nonisolated static func startAgrees(_ first: Int, _ second: Int) -> Bool {
        first > 0 && second > 0 && abs(first - second) <= 1
    }

    /// The step's detail when the song no longer shows under its persistent ID `hex`, `seconds`
    /// after the request. `newer`: songs like it whose IDs weren't there just before the request.
    /// One is its new ID; more can't be told apart, so none is named. `older`: the look-alikes
    /// that were there before, never its new ID.
    nonisolated static func vanished(_ hex: String, after seconds: String, older: Set<Int64>, newer: [Int64]) -> String {
        if newer.count == 1 { return "persistent ID changed \(hex) → \(MusicPersistentID.hex(newer[0])) after \(seconds) s" }
        var detail = "\(hex) left Music's library after \(seconds) s"
        if newer.count > 1 {
            detail += "; \(newer.count) songs like it are new since the request, more than the one it asked for, "
                + "so none is named as its new ID"
        }
        if !older.isEmpty {
            detail += "; look-alikes there before the request, so not its new ID: "
                + older.sorted().map(MusicPersistentID.hex).joined(separator: ", ")
        }
        return detail
    }

    /// Whether Music stayed out of sight: hidden, not active, and which app was in front. The
    /// `musicplaylists` live check logs it too.
    static func musicState() -> String {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
        guard let music = NSRunningApplication.runningApplications(withBundleIdentifier: MusicAutomation.bundleID).first else {
            return "Music not running; in front: \(front)"
        }
        return "Music hidden \(music.isHidden), active \(music.isActive); in front: \(front)"
    }

    /// Where Music says the song is, by extension and kind, never by name: Music names its media
    /// files after the song.
    private static func fileKind(_ url: URL?) -> String {
        guard let url else { return "no location" }
        guard FileManager.default.fileExists(atPath: url.path) else { return ".\(url.pathExtension), not there yet" }
        return ".\(url.pathExtension), \(PlaybackCoordinator.isDirectory(url) ? "a package" : "a plain file")"
    }

    /// A file's size, or a package's: every file inside it.
    private static func size(of url: URL) -> Int64 {
        guard PlaybackCoordinator.isDirectory(url) else {
            return ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        }
        var total: Int64 = 0
        let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        while let file = files?.nextObject() as? URL {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    /// The calls MusicSongDownloader makes, keeping Music's own error number, and what Download
    /// would make of the answer.
    private static func secondDownload(_ pid: Int64) async -> String {
        let answer: (error: TagEditError?, sent: Bool)
        do {
            answer = try await MusicScriptingSession.run { () -> (error: TagEditError?, sent: Bool) in
                guard MusicAutomation.isMusicRunning else { return (TagEditError(message: "Music isn’t running"), false) }
                let session = try MusicScriptingSession(for: .downloadingSongs, timeout: 600)
                let track: SBObject
                do {
                    track = try session.track(persistentID: pid)
                } catch let error as TagEditError {
                    return (error, false)
                }
                do {
                    try session.download(track)
                } catch let error as TagEditError {
                    return (error, true)
                }
                return (nil, true)
            }
        } catch {
            answer = (error as? TagEditError ?? TagEditError(message: error.localizedDescription), false)
        }
        guard let error = answer.error else { return "no error; Download would read it as taken" }
        let outcome = MusicSongDownloader.outcome(of: error, downloadSent: answer.sent)
        return "error \(error.code.map { String($0) } ?? "with no number")\(error.missingCommand ? " (no such command)" : "") " +
            "\(answer.sent ? "to the download" : "to the lookup"): \(error.message); Download would read it as \(outcome)"
    }
}

/// When Music's library-changed notifications came.
@MainActor
private final class Arrivals {
    var times: [Date] = []
}

/// One song in Music's database, through iTunesLibrary: separate from the ScriptingBridge path
/// that asks for the download. Owns its own ITLibrary off the main actor.
private actor MusicSongReader {
    struct Song: Sendable {
        var persistentID: Int64
        var title: String
        var artist: String
        var album: String
        var milliseconds: Int
        var isSong: Bool
        /// Only in iCloud: Music's database names no file for it.
        var isRemote: Bool
        /// A file on this Mac, as far as Music's database says.
        var isFile: Bool
        var location: URL?
    }

    struct Look: Sendable {
        var song: Song?
        /// Songs whose location is a file on this Mac.
        var files: Int
        /// Every other song with `like`'s title, artist, album and length (within a second), in
        /// the library's order.
        var lookalikes: [Song] = []
        /// Every song read; none when iTunesLibrary couldn't be read (`MusicDownloadLiveTest.readable`).
        var songs = 0
    }

    private var library: ITLibrary?

    func look(for persistentID: Int64, like wanted: Song? = nil) -> Look {
        if library == nil { library = try? ITLibrary(apiVersion: "1.0", options: .none) }
        guard let library else { return Look(song: nil, files: -1) }
        _ = library.reloadData()
        var look = Look(song: nil, files: 0)
        for item in library.allMediaItems {
            let song = Song(persistentID: Int64(bitPattern: item.persistentID.uint64Value), title: item.title,
                            artist: item.artist?.name ?? "", album: item.album.title ?? "", milliseconds: item.totalTime,
                            isSong: item.mediaKind == .kindSong, isRemote: item.locationType == .remote,
                            isFile: item.locationType == .file && item.location != nil, location: item.location)
            if song.isSong { look.songs += 1 }
            if song.isSong && song.isFile { look.files += 1 }
            if song.persistentID == persistentID {
                look.song = song
            } else if let wanted, song.isSong, song.title == wanted.title, song.artist == wanted.artist,
                      song.album == wanted.album, abs(song.milliseconds - wanted.milliseconds) <= 1_000 {
                look.lookalikes.append(song)
            }
        }
        return look
    }
}
