import Foundation

/// The real hand-off for File ▸ Add Folder's "Also add to the Music app": Music.app's scripting
/// `add` command (hookAdd), through the same ScriptingBridge session and queue as tag saves.
/// One file per event, so a file Music turns down is named, and the rest still go in.
///
/// Sends `add` and one property read, nothing else: never play, pause or next track (§6.5).
/// Only `prepare()` starts Music. ScriptingBridge would start it again for any event, so `add`
/// first checks that Music is still running: quitting Music stops a hand-off, as it stops a
/// Download or an add to a playlist. An actor, because one adder hands off every folder of an
/// Add Folder (AppController) and remembers a quit: `prepare()` then doesn't start Music for the
/// folders after, which are added to oldTunes only, their files listed as not sent.
actor MusicAppLibraryAdder: MusicLibraryAdding {
    static let musicQuitReason = "Music quit, so oldTunes stopped adding songs to it."

    /// Music has run for this hand-off (`prepare()`): from then on, not running means it quit.
    private var musicRan = false
    /// The user quit Music during this hand-off, which stops it: nothing starts Music again for it.
    private var musicQuit = false

    func prepare() async -> String? {
        // A folder after the one Music quit during, or Music quit between two folders: starting
        // it again would undo the quit.
        if musicRan, !MusicAutomation.isMusicRunning { musicQuit = true }
        guard !musicQuit else { return Self.musicQuitReason }
        // The grant can only be read while Music runs; start it hidden if it isn't.
        guard await MusicAutomation.launchHiddenIfNeeded() else { return MusicAutomation.addUnavailableReason }
        musicRan = true
        var status = await MusicAutomation.permission(askIfNeeded: false)
        // Asked right after the user ticked "Also add to the Music app" and clicked Add, so the
        // system prompt (with NSAppleEventsUsageDescription) comes up in context.
        if status == .undetermined { status = await MusicAutomation.permission(askIfNeeded: true) }
        switch status {
        case .granted: return nil
        case .denied, .undetermined: return MusicAutomation.addDeniedReason
        case .musicUnavailable: return MusicAutomation.addUnavailableReason
        case .failed(let status): return "oldTunes couldn’t check its permission to control Music (error \(status))."
        }
    }

    func add(_ file: URL) async -> MusicAddOutcome {
        let outcome: MusicAddOutcome
        do {
            outcome = try await MusicScriptingSession.run { () -> MusicAddOutcome in
                // On the scripting queue, just before anything is sent: ScriptingBridge would start
                // Music again for the `add`, and this can wait its turn here behind a Download or
                // an add to a playlist while the user quits Music to stop them.
                guard MusicAutomation.isMusicRunning else { return .stopped(Self.musicQuitReason) }
                let session = try MusicScriptingSession(for: .addingSongs)
                guard let track = try session.add(file: file) else {
                    return .refused("Music answered with nothing")
                }
                // Only for the log and the live check; the add stands without it.
                return .added(persistentID: try? session.persistentID(of: track))
            }
        } catch {
            outcome = Self.outcome(of: error)
        }
        if outcome == .stopped(Self.musicQuitReason) { musicQuit = true }
        return outcome
    }

    /// What a failed `add` means for the hand-off. Music gone (-600, -609) means it quit, or
    /// crashed, since `add` found it running just before sending. Any other error after which
    /// nothing more should be sent stops the hand-off in the session's words; the rest turn down
    /// this one file. Pure, so a bench can check it. `MusicSongDownloader.outcome(of:downloadSent:)`
    /// is the same rule for downloads.
    static func outcome(of error: any Error) -> MusicAddOutcome {
        guard let error = error as? TagEditError, MusicScriptingSession.endsConversation(error.code) else {
            return .refused(error.localizedDescription)
        }
        return [-600, -609].contains(error.code) ? .stopped(musicQuitReason) : .stopped(error.message)
    }
}
