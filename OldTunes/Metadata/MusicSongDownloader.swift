import Foundation
import ScriptingBridge

/// The real `SongDownloading`: Music.app's scripting `download` command (hookDwnl), through the
/// same ScriptingBridge session and queue as tag saves (RESEARCH.md §6.9). One song per
/// conversation, so a tag save or a playlist command waits behind one song at most, never a
/// whole batch.
///
/// Sends `download` and the whose-lookup that finds the song, nothing else: never play, pause
/// or next track (§6.5). Only `prepare()` starts Music. ScriptingBridge would start it again for
/// any event, so `download(_:)` first checks that Music is still running.
struct MusicSongDownloader: SongDownloading {
    static let musicQuitReason = "Music quit, so OldTunes stopped asking it to download songs."
    static let timeoutReason = "Music didn’t answer in time, so OldTunes stopped asking it to download songs."

    /// How long to wait for each of Music's answers, in seconds; nil is the session's 30 s. The
    /// live download check waits 10 minutes, to learn whether Music answers `download` at once or
    /// only once the file is here. On Nov 1, 2026 Music answered in 0.3 s; the uploaded song's
    /// file first appeared at 5.3 s. The default remains 30 s (RESEARCH.md §10-R7).
    var replyTimeout: TimeInterval?

    func prepare() async -> String? {
        // The grant can only be read while Music runs; start it hidden if it isn't.
        guard await MusicAutomation.launchHiddenIfNeeded() else { return MusicAutomation.downloadUnavailableReason }
        var status = await MusicAutomation.permission(askIfNeeded: false)
        // Asked right after the user chose Download, so the system prompt (with
        // NSAppleEventsUsageDescription) comes up in context.
        if status == .undetermined { status = await MusicAutomation.permission(askIfNeeded: true) }
        switch status {
        case .granted: return nil
        case .denied, .undetermined: return MusicAutomation.downloadDeniedReason
        case .musicUnavailable: return MusicAutomation.downloadUnavailableReason
        case .failed(let status): return "OldTunes couldn’t check its permission to control Music (error \(status))."
        }
    }

    func download(_ persistentID: Int64) async -> MusicDownloadOutcome {
        let timeout = replyTimeout
        do {
            return try await MusicScriptingSession.run { () -> MusicDownloadOutcome in
                // On the scripting queue, just before anything is sent: quitting Music is how a
                // user stops a long batch.
                guard MusicAutomation.isMusicRunning else { return .stopped(Self.musicQuitReason) }
                let session = try MusicScriptingSession(for: .downloadingSongs, timeout: timeout)
                // One body, because the song's reference can't leave it, but two catches: only
                // the download itself can leave Music fetching a song OldTunes stopped waiting for.
                let track: SBObject
                do {
                    track = try session.track(persistentID: persistentID)
                } catch {
                    return Self.outcome(of: error, downloadSent: false)
                }
                do {
                    try session.download(track)
                } catch {
                    return Self.outcome(of: error, downloadSent: true)
                }
                return .requested
            }
        } catch {
            // No session: Music can't be reached.
            return Self.outcome(of: error, downloadSent: false)
        }
    }

    /// What a failed lookup (`downloadSent` false) or download means for the batch. A timeout
    /// before the download was sent left nothing behind, so it only stops the batch; after it,
    /// Music still carries out the request it didn't answer in time. Music gone (-600, -609)
    /// means it quit, or crashed: `prepare()` had it running, and `download(_:)` checks again
    /// before each song. A refusal carries Music's error number for the three-in-a-row rule
    /// (`DownloadWatch.RefusalStreak`), but not a lookup's: a song that can't be found has most
    /// likely left the library, which says nothing about the next song.
    static func outcome(of error: any Error, downloadSent: Bool) -> MusicDownloadOutcome {
        guard let error = error as? TagEditError else { return .refused(error.localizedDescription) }
        switch error.code {
        case -1712: return downloadSent ? .unanswered(timeoutReason) : .stopped(timeoutReason)
        case -600, -609: return .stopped(musicQuitReason)
        default:
            if MusicScriptingSession.stopsBatch(error) {
                return .stopped(error.message, retryWontHelp: retryWontHelp(after: error))
            }
            return .refused(error.message, code: downloadSent ? error.code : nil)
        }
    }

    /// Whether choosing Download again would stop the same way: the sandbox lets nothing reach
    /// Music (-1742) or doesn't let this request through (-10004), or Music's dictionary has no
    /// `download`. `MusicPlaylistEditor.retryWontHelp(after:)` is the same rule for adds.
    static func retryWontHelp(after error: TagEditError) -> Bool {
        error.missingCommand || [-10004, -1742].contains(error.code)
    }
}
