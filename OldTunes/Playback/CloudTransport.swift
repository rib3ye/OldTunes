import Foundation
import MusicKit

/// Streams iCloud library songs through `ApplicationMusicPlayer.shared` (RESEARCH.md §5.3).
///
/// The MusicKit queue only ever holds one song, with shuffle and repeat forced off, so the player
/// cannot move on by itself and "now playing" cannot drift from what is audible. MusicKit gives no
/// end-of-song callback, so the end is detected from the 10 Hz clock by CloudEndDetector.
///
/// MusicKit has no volume on macOS and plays the song in another process, so CloudVolume sets the
/// level in that process: OldTunes's own volume, times the song's Sound Check gain when that is on,
/// capped at full, the most that process plays at. So Sound Check turns iCloud songs down but can't
/// turn them up; a file gets its boost, as OldTunes changes its samples itself (LocalSoundCheck).
/// Nothing listens to the song, so OldTunes needs no System Audio Recording. If macOS ever lacks
/// the call, the song plays at its own level and the volume slider greys out.
@MainActor
final class CloudTransport: Transport {
    var onFinish: (() -> Void)?
    var onError: ((Error) -> Void)?
    /// Off makes plays not count toward the Music library's play history (macOS 26.4+).
    /// The harness turns it off so test runs leave Noah's play counts alone.
    var affectsListeningHistory = true
    /// Why the last end-of-song fired, for the log.
    private(set) var lastFinishReason = ""
    /// Fallback when the Now Playing opt-out is unavailable. Fired when MusicKit turns to
    /// .playing, so the coordinator can take back media controls (NowPlayingPublisher.reclaim()).
    var onMusicKitStartedPlaying: (() -> Void)?
    /// Harness only, nil in the app: songs whose load fails the way MusicKit's prepareToPlay
    /// fails for some uploaded songs, without touching MusicKit, so that path can be tested on
    /// demand. The failing set shifts from run to run on the real library.
    var simulatedPrepareFailure: ((Song) -> (any Error)?)?

    /// Settings ▸ Sound Check; it changes the song playing too.
    var isSoundCheckOn = false {
        didSet { applyGain() }
    }
    /// The Sound Check gain of the song being loaded or played, as a factor (SoundCheck). The
    /// coordinator sets it before each load.
    var soundCheckGain: Float = 1 {
        didSet { applyGain() }
    }
    /// The level last handed to MusicKit's player (CloudVolume), 0 to 1. Internal for the harness.
    private(set) var level: Float = 1
    /// Whether OldTunes sets the song's level itself: false once CloudVolume found no call to set it
    /// with. When false, the volume slider greys out: it would change nothing anyone hears.
    private(set) var ownsVolume = true
    /// Harness only, and OLDTUNES_SIMULATE_NO_CLOUD_VOLUME: play as if macOS had no setRelativeVolume:.
    /// Takes effect at the next song, as a missing call would from the first.
    var simulatesMissingVolumeCall = false

    private(set) var duration: TimeInterval = 0
    /// False until the first load, so a local-only session never starts MusicKit's player service.
    private var loaded = false
    /// What the user asked for. MusicKit's own status lags a play() by a few ticks.
    private var wantsPlay = false
    private var pausedByUs = false
    private var finished = false
    /// Set by a seek to the last half second; the next tick that wants to play ends the song.
    private var endRequested = false
    private var end = CloudEndDetector()
    private var mismatchTicks = 0
    /// When MusicKit was last asked to start, or seeked. Its status lags such a request by a few
    /// ticks, so a disagreement is only taken as someone else's doing once MusicKit has been seen
    /// playing or a second has passed.
    private var settleFrom = ContinuousClock.now
    /// True while awaiting MusicKit's play(), however long that takes.
    private var starting = false
    private var musicKitWasPlaying = false
    private var appVolume: Float = 0.75
    /// Whether MusicKit's private macOS adapter accepted the Now Playing opt-out.
    private(set) var keepsMediaControlsInApp = false

    var position: TimeInterval { loaded ? max(0, ApplicationMusicPlayer.shared.playbackTime) : 0 }
    var isPlaying: Bool { loaded && wantsPlay }

    /// OldTunes's own volume, which MusicKit's player plays the song at.
    var volume: Float {
        get { appVolume }
        set {
            appVolume = min(max(newValue, 0), 1)
            applyGain()
        }
    }

    /// Hands the level to MusicKit's player once a song is loaded; before the first load there is no
    /// player to hand it to, and starting one would start MusicKit's player service for nothing.
    /// MusicKit's player plays nothing louder than full (2 plays as 1), so a Sound Check boost is
    /// capped there.
    private func applyGain() {
        level = min(appVolume * (isSoundCheckOn ? soundCheckGain : 1), 1)
        guard loaded else { return }
        ownsVolume = !simulatesMissingVolumeCall && CloudVolume.set(level)
    }

    func load(_ what: Playable) async throws {
        guard case .cloud(let song) = what else { throw TransportError.unsupported }
        if let error = simulatedPrepareFailure?(song) {
            // A real failed prepare takes a moment too.
            try await Task.sleep(for: .milliseconds(300))
            throw error
        }
        let player = ApplicationMusicPlayer.shared
        keepsMediaControlsInApp = CloudMediaControls.keepCommandsInApp()
        player.state.shuffleMode = .off
        // Fully qualified on purpose: the property is `RepeatMode?`, so a bare `.none` compiles
        // to Optional.none and writes nil instead of "don't repeat" (RESEARCH.md §5.3).
        player.state.repeatMode = MusicPlayer.RepeatMode.none
        let queue = ApplicationMusicPlayer.Queue(for: [song])
        if #available(macOS 26.4, *) { queue.affectsListeningHistory = affectsListeningHistory }
        player.queue = queue
        loaded = true
        wantsPlay = false
        pausedByUs = false
        finished = false
        endRequested = false
        // The clock skips this transport while a song loads, so it never saw the old one stop.
        musicKitWasPlaying = false
        duration = song.duration ?? 0
        settleFrom = .now
        end = CloudEndDetector()
        try await withTimeout(20) { @MainActor in try await ApplicationMusicPlayer.shared.prepareToPlay() }
        // After prepareToPlay, when MusicKit's player has its server, and before play(), so the song
        // starts at its level. The level outlasts a song, but setting it again costs nothing.
        applyGain()
        if simulatesMissingVolumeCall { Log.info("cloud: no setRelativeVolume: (simulated); this song plays at its own level") }
    }

    func play() async throws {
        guard loaded else { throw TransportError.notPlayable }
        // Set before the await so the clock does not show a pause while MusicKit starts up.
        wantsPlay = true
        pausedByUs = false
        finished = false
        mismatchTicks = 0
        end.restart(at: position)
        // The clock keeps ticking while MusicKit starts; none of that is someone else's pause.
        starting = true
        defer {
            starting = false
            settleFrom = .now
        }
        do {
            try await withTimeout(10) { @MainActor in try await ApplicationMusicPlayer.shared.play() }
        } catch {
            wantsPlay = false
            throw error
        }
        // A pause() that arrived while MusicKit was starting must win. Otherwise MusicKit can
        // finish starting after it, and mirrorExternalControl would then adopt "playing".
        if loaded, !wantsPlay { ApplicationMusicPlayer.shared.pause() }
    }

    func pause() {
        guard loaded else { return }
        ApplicationMusicPlayer.shared.pause()
        wantsPlay = false
        pausedByUs = true
    }

    func stop() {
        guard loaded else { return }
        let player = ApplicationMusicPlayer.shared
        player.stop()
        // stop() alone leaves the song queued and paused, and MusicKit keeps offering it in Now
        // Playing, where a play/pause key press would resume it behind the coordinator's back.
        player.queue = []
        loaded = false
        wantsPlay = false
        endRequested = false
        musicKitWasPlaying = false
        duration = 0
    }

    func seek(to seconds: TimeInterval) {
        guard loaded else { return }
        let t = max(0, duration > 0 ? min(seconds, duration) : seconds)
        ApplicationMusicPlayer.shared.playbackTime = t
        finished = false
        settleFrom = .now
        end.restart(at: t)
        // Dragged to the very end. MusicKit then often jumps to its end state (paused at 0)
        // before any tick sees it playing at the new position, which the detector cannot tell
        // from an outside pause: the song just stopped. End it here instead, as a file does.
        endRequested = duration > 0 && t >= duration - 0.5
    }

    /// End-of-song detection runs here; the rules and the experiment behind them are in
    /// CloudEndDetector. Also notices MusicKit starting to play, and follows pauses made
    /// outside OldTunes.
    func clockDidTick() {
        guard loaded else { return }
        let player = ApplicationMusicPlayer.shared
        let status = player.state.playbackStatus
        if status == .playing, !musicKitWasPlaying, !keepsMediaControlsInApp { onMusicKitStartedPlaying?() }
        musicKitWasPlaying = status == .playing
        guard !finished else { return }
        if endRequested, wantsPlay {
            endRequested = false
            finish("seeked to the end")
            return
        }
        if let reason = end.evaluate(status: status, position: max(0, player.playbackTime), duration: duration,
                                     now: .now, pausedByUs: pausedByUs, wantsPlay: wantsPlay) {
            finish(reason)
            return
        }
        mirrorExternalControl(status)
    }

    /// MusicKit's player service publishes its own Now Playing entry and serves Play/Pause from
    /// it, so a pause can happen without going through pause(). Adopt MusicKit's status once it has
    /// disagreed for half a second, which is longer than its lag after our own play().
    ///
    /// The settle time, not only "seen playing", gates it: a key that reaches MusicKit's player
    /// within its first 100 ms of playing pauses it before any tick has seen it play (measured in
    /// the verify run), and that pause used to be ignored for good, leaving "playing" at 0:00 over
    /// silence. A song that never starts is now shown paused for the same reason.
    private func mirrorExternalControl(_ status: MusicPlayer.PlaybackStatus) {
        let playing = status == .playing
        let settled = !starting && (end.sawPlaying || ContinuousClock.now - settleFrom > .seconds(1))
        guard wantsPlay != playing, playing || settled else {
            mismatchTicks = 0
            return
        }
        mismatchTicks += 1
        if mismatchTicks >= 5 {
            mismatchTicks = 0
            wantsPlay = playing
            pausedByUs = false
            Log.info("cloud: MusicKit \(playing ? "resumed" : "paused") outside OldTunes; following it")
        }
    }

    private func finish(_ reason: String) {
        finished = true
        wantsPlay = false
        lastFinishReason = reason
        Log.info("cloud: end of song (\(reason))")
        onFinish?()
    }
}
