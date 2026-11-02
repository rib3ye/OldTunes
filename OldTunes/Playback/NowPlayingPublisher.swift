import Foundation
import MediaPlayer

/// Makes the keyboard's play/pause, next and previous keys (and the Touch Bar, headphone
/// buttons, and the Now Playing menu) drive OldTunes, and tells macOS what is playing.
///
/// MusicKit does not publish anything through this process's MPNowPlayingInfoCenter. Its player
/// service (com.apple.MediaPlayer.RemotePlayerService, a separate process) registers its own Now
/// Playing player under OldTunes' name instead, which knows only its one-song queue: sent Next it
/// ends that queue (paused at 0:00), sent Previous it restarts the song (measured in the verify
/// run). So OldTunes publishes its own entry for both kinds of song and handles every
/// command here, through the coordinator. CloudMediaControls disables MusicKit's automatic Now
/// Playing takeover before playback starts. This keeps startup commands on the same queue as
/// every other command, without temporarily advertising a false pause.
///
/// If that optional macOS bridge is unavailable, reclaim() retains the old best-effort behavior:
/// re-announce playing on the next clock tick and again 0.5 s later. Only this fallback has a
/// startup window in which MusicKit can receive a key meant for OldTunes's queue.
@MainActor
final class NowPlayingPublisher {
    struct Actions: Sendable {
        var play: @MainActor @Sendable () -> Void
        var pause: @MainActor @Sendable () -> Void
        var toggle: @MainActor @Sendable () -> Void
        var next: @MainActor @Sendable () -> Void
        var previous: @MainActor @Sendable () -> Void
        var seek: @MainActor @Sendable (TimeInterval) -> Void
    }

    /// What was last sent. The shown text is part of it, so a tag edit to the playing song is
    /// re-sent even though the song itself did not change.
    private struct Pushed: Equatable {
        var id: Track.ID?
        var title: String?
        var artist: String?
        var album: String?
        var isPlaying: Bool
        var isLoading: Bool
        var duration: TimeInterval
    }

    private var pushed: Pushed?
    /// Where the system thinks playback is, extrapolated from the last push. A gap bigger than a
    /// second means a seek, which is the only time the elapsed time needs re-sending.
    private var pushedPosition: TimeInterval = 0
    private var pushedAt = Date()

    init(actions: Actions) {
        let center = MPRemoteCommandCenter.shared()
        Self.handle(center.playCommand, actions.play)
        Self.handle(center.pauseCommand, actions.pause)
        Self.handle(center.togglePlayPauseCommand, actions.toggle)
        Self.handle(center.nextTrackCommand, actions.next)
        Self.handle(center.previousTrackCommand, actions.previous)
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { @Sendable event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let seconds = event.positionTime
            Self.onMain { actions.seek(seconds) }
            return .success
        }
    }

    func update(_ state: PlaybackState) {
        let now = Date()
        let current = Pushed(id: state.nowPlaying?.id, title: state.nowPlaying?.displayTitle,
                             artist: state.nowPlaying?.artist, album: state.nowPlaying?.album,
                             isPlaying: state.isPlaying, isLoading: state.isLoading, duration: state.duration)
        let expected = pushedPosition + ((pushed.map { $0.isPlaying && !$0.isLoading } ?? false) ? now.timeIntervalSince(pushedAt) : 0)
        guard current != pushed || abs(state.position - expected) > 1.0 else { return }

        let info = MPNowPlayingInfoCenter.default()
        if let track = state.nowPlaying {
            info.nowPlayingInfo = [
                MPMediaItemPropertyTitle: track.displayTitle,
                MPMediaItemPropertyArtist: track.artist,
                MPMediaItemPropertyAlbumTitle: track.album,
                MPMediaItemPropertyPlaybackDuration: state.duration,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: state.position,
                // Still loading: the clock must not run in Control Center before the audio does.
                MPNowPlayingInfoPropertyPlaybackRate: state.isPlaying && !state.isLoading ? 1.0 : 0.0,
                MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
                MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            ]
            // macOS, unlike iOS, does not infer this from the rate.
            info.playbackState = state.isPlaying ? .playing : .paused
        } else {
            info.nowPlayingInfo = nil
            info.playbackState = .stopped
        }
        pushed = current
        pushedPosition = state.position
        pushedAt = now
    }

    /// Re-announces "playing" as a fresh paused → playing change, which is what makes macOS pick
    /// a Now Playing player. The two states go out on separate run-loop turns so they are not
    /// coalesced into no change at all.
    func reclaim() async {
        let info = MPNowPlayingInfoCenter.default()
        guard info.playbackState == .playing else { return }
        info.playbackState = .paused
        try? await Task.sleep(for: .milliseconds(50))
        info.playbackState = pushed?.isPlaying == true ? .playing : .paused
    }

    private static func handle(_ command: MPRemoteCommand, _ action: @escaping @MainActor @Sendable () -> Void) {
        command.isEnabled = true
        // @Sendable keeps the handler off the main actor. Without it Swift 6 infers @MainActor
        // from this context and checks the executor on entry, so a call from any other thread
        // would crash before onMain could hop.
        command.addTarget { @Sendable _ in
            onMain(action)
            return .success
        }
    }

    /// MediaPlayer calls handlers on the main thread in practice but does not promise it.
    private nonisolated static func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body() }
        } else {
            Task { @MainActor in body() }
        }
    }
}
