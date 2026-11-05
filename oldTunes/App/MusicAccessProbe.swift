import AppKit

/// OLDTUNES_HARNESS=musicaccess — which ways of naming Music's songs and playlists Music answers
/// for this copy of oldTunes. Read-only: it changes nothing in the Music library, so it needs no
/// go-ahead. In the App Sandbox, Music checks each event against the access groups in oldTunes's
/// entitlements (com.apple.security.scripting-targets) and answers -10004 (errAEPrivilegeError)
/// for anything outside them, and its dictionary alone doesn't say which ways it lets through
/// (RESEARCH.md §3.1). Each question carries the answer measured on October 28, 2026 (Music 1.7,
/// only com.apple.Music.library.read-write), so a change in Music shows as UNEXPECTED. Each runs
/// as its own small AppleScript, so one refusal doesn't hide the rest. Then the same lookups go
/// through oldTunes's own scripting session.
///
///   OLDTUNES_ACCESS_FILE_PID=<16 hex digits>      a song with a file on this Mac (a file track)
///   OLDTUNES_ACCESS_PLAYLIST_PID=<16 hex digits>  the playlist for the session's lookup, e.g. a folder
///   OLDTUNES_ACCESS_SAME_WRITE=<persistent ID, Int64>  also save that song's title and comment
///       through the real tag-save path, each set to the value it already has
///
/// Music must be running; the probe starts it hidden if it isn't.
@MainActor
enum MusicAccessProbe {
    static func run() async {
        defer { Log.flush(); NSApp.terminate(nil) }
        guard await MusicAutomation.launchHiddenIfNeeded() else {
            Log.error("musicaccess: Music couldn't be started; nothing asked")
            return
        }
        Log.info("musicaccess: Automation permission \(await MusicAutomation.permission(askIfNeeded: false))")
        let env = ProcessInfo.processInfo.environment
        let songID = ask("a song's persistent ID, from the application's tracks", "persistent ID of track 1")
        var playlistID = ask("a playlist's persistent ID, from the application's playlists", "persistent ID of playlist 2")

        ask("the application's version (open to every app)", "version")
        ask("count of sources", "count sources")
        ask("source 1's name", "name of source 1")
        ask("count of the library playlist's tracks", "count tracks of library playlist 1 of source 1")
        ask("count of the application's tracks", "count tracks")
        ask("count of the application's playlists", "count playlists")
        ask("track 1's name", "name of track 1")
        ask("track 1's comment", "comment of track 1")
        ask("count of track 1's artworks", "count artworks of track 1")
        ask("user playlist 1's name, through source 1", "name of user playlist 1 of source 1")
        ask("user playlist 1's name, from the application", "name of user playlist 1", expect: .refused)
        if let songID {
            let found = "first track whose persistent ID is \"\(songID)\""
            ask("a song found by persistent ID, its name", "name of (\(found))")
            ask("the same, through source 1's library playlist",
                "name of (first track of library playlist 1 of source 1 whose persistent ID is \"\(songID)\")")
            ask("its name through Music's own reference to it", "name of (get \(found))", twoStep: true)
            ask("its name through a generic item", "name of item 1 of (every track whose persistent ID is \"\(songID)\")",
                expect: .refused)
        }
        if let fileID = env["OLDTUNES_ACCESS_FILE_PID"] {
            let found = "first track whose persistent ID is \"\(fileID)\""
            ask("a file song's name", "name of (\(found))")
            ask("a file song's name through Music's own reference to it", "name of (get \(found))", twoStep: true)
        }
        if let playlistID {
            ask("a playlist found by persistent ID, its name", "name of (first playlist whose persistent ID is \"\(playlistID)\")")
            ask("its name through Music's own reference to it",
                "name of (get first playlist whose persistent ID is \"\(playlistID)\")", twoStep: true)
        }

        // The same lookups through oldTunes's own scripting session (ScriptingBridge), on its
        // queue as the app runs them, and once more on the main thread.
        if let chosen = env["OLDTUNES_ACCESS_PLAYLIST_PID"] { playlistID = chosen }
        if let song = songID.flatMap(MusicPersistentID.bitPattern(fromHex:)),
           let list = playlistID.flatMap(MusicPersistentID.bitPattern(fromHex:)) {
            let onQueue = try? await MusicScriptingSession.run { sessionLookups(song: song, playlist: list) }
            for line in onQueue ?? [(false, "the session couldn't be made")] { tally("session on its queue", line) }
            for line in sessionLookups(song: song, playlist: list) { tally("session on the main thread", line) }
        }
        Log.info("musicaccess: SUMMARY \(asExpected) as expected, \(unexpected) unexpected")
    }

    private enum Expect { case answer, refused }
    private static var asExpected = 0
    private static var unexpected = 0

    /// Asks Music one thing and logs whether it answered as expected; returns the answer as text.
    /// With `twoStep`, `expression` is `property of (get lookup)`: the lookup is one event, and
    /// the property is asked of the reference Music answered with, in a second.
    @discardableResult
    private static func ask(_ what: String, _ expression: String, expect: Expect = .answer,
                            twoStep: Bool = false) -> String? {
        var source = "tell application id \"com.apple.Music\" to get \(expression)"
        if twoStep, let split = expression.range(of: " of (get ") {
            source = """
                tell application id "com.apple.Music"
                    set found to (get \(expression[split.upperBound...].dropLast()))
                    return \(expression[..<split.lowerBound]) of found
                end tell
                """
        }
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        let answer = result.map { $0.stringValue ?? String(describing: $0).prefix(120).description }
        let outcome = answer.map { "ANSWERED: \($0.prefix(40))" }
            ?? "REFUSED: error \((error?[NSAppleScript.errorNumber] as? Int).map(String.init) ?? "?")"
        tally(what, ((answer != nil) == (expect == .answer), outcome))
        return answer
    }

    /// One (as expected, what happened) per step.
    nonisolated private static func sessionLookups(song: Int64, playlist: Int64) -> [(Bool, String)] {
        var lines: [(Bool, String)] = []
        func step(_ what: String, _ body: () throws -> String?) {
            do { lines.append((true, "\(what) ANSWERED: \(try body() ?? "nil")")) }
            catch let error as TagEditError { lines.append((false, "\(what) REFUSED: \(error.message)")) }
            catch { lines.append((false, "\(what) REFUSED: \(error)")) }
        }
        guard let session = try? MusicScriptingSession(for: .savingTags) else { return [(false, "the session couldn't be made")] }
        step("a song found by persistent ID, its name") { try session.name(of: session.track(persistentID: song)) }
        step("a playlist found by persistent ID, its name") { try session.name(of: session.playlist(persistentID: playlist)) }
        if let pid = ProcessInfo.processInfo.environment["OLDTUNES_ACCESS_SAME_WRITE"].flatMap(Int64.init) {
            step("a song's title and comment saved unchanged") {
                let track = try session.track(persistentID: pid)
                var patch = TagPatch()
                patch.title = try session.name(of: track)
                patch.comments = track.value(forKey: "comment") as? String ?? ""
                try session.apply(patch, to: track)
                return "“\(patch.title ?? "")” and “\(patch.comments ?? "")” written back"
            }
        }
        return lines
    }

    private static func tally(_ what: String, _ line: (Bool, String)) {
        if line.0 { asExpected += 1 } else { unexpected += 1 }
        Log.info("musicaccess: \(line.0 ? "" : "UNEXPECTED ")\(what) \(line.1)")
    }
}
