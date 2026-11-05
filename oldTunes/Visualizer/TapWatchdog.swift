import Foundation
import VisualizerCore

/// Decides whether the ears have gone deaf: a song is playing, but nothing but exact zeros arrives.
///
/// Several causes look the same from here: a capture that stopped delivering, ears gone silent on
/// their own (one report says a process tap can in long sessions on macOS 26.5), or, for the benches'
/// tap, the "System Audio Recording Only" permission being off (the tap then delivers zeros and no
/// error). So after `silenceLimit` of zeros it asks for one rebuild; if zeros continue for another
/// `silenceLimit`, it asks for the hint. While the can't-hear hint shows, it asks for new ears every
/// `rebuildSpacing`. Any non-zero sample clears the hint.
/// Exact zeros only: real music that is merely quiet is never mistaken for silence. When the output is
/// AirPlay it asks for an AirPlay message instead, since that audio may never pass through the tap.
struct SilenceWatchdog: Equatable {
    /// `stopped` comes from VisualizerAudio, never from the watchdog: SelfCapture was stopped from
    /// the menu bar and nothing else can listen without System Audio Recording.
    enum Hint: Equatable { case cantHear, airPlay, stopped }
    enum Advice: Equatable { case none, rebuild, showHint(Hint), clearHint }

    static let silenceLimit: TimeInterval = 3
    /// At most one rebuild this often; a second silence soon after goes straight to the hint. Also how
    /// often new ears are tried while the can't-hear hint shows.
    static let rebuildSpacing: TimeInterval = 30

    private(set) var hint: Hint?
    /// Whether any non-zero sample has arrived since this watchdog was made.
    private(set) var hasHeard = false
    private var lastNonZero: UInt64
    private var silentSince: TimeInterval?
    private var rebuiltThisSilence = false
    private var lastRebuild = -TimeInterval.infinity

    /// `baseline`: the ring's non-zero count already there, from other ears, which doesn't count as heard.
    init(baseline: UInt64 = 0) {
        lastNonZero = baseline
    }

    /// Call about twice a second. `audible`: a song is playing and its position is moving.
    mutating func observe(now: TimeInterval, audible: Bool, airPlay: Bool, nonZeroFrames: UInt64) -> Advice {
        // A count lower than last time is a new ring (its sample rate changed, as when other ears take
        // over at another rate): everything in it is new.
        let heard = nonZeroFrames < lastNonZero ? nonZeroFrames > 0 : nonZeroFrames > lastNonZero
        lastNonZero = nonZeroFrames
        if heard { hasHeard = true }
        if heard {
            silentSince = nil
            rebuiltThisSilence = false
            if hint != nil {
                hint = nil
                return .clearHint
            }
            return .none
        }
        guard audible else {
            silentSince = nil
            return .none
        }
        guard let since = silentSince else {
            silentSince = now
            return .none
        }
        guard now - since >= Self.silenceLimit else { return .none }
        if !rebuiltThisSilence {
            rebuiltThisSilence = true
            silentSince = now
            guard now - lastRebuild >= Self.rebuildSpacing else { return .none }
            lastRebuild = now
            return .rebuild
        }
        guard hint == nil else {
            guard hint == .cantHear, now - lastRebuild >= Self.rebuildSpacing else { return .none }
            lastRebuild = now
            return .rebuild
        }
        let next: Hint = airPlay ? .airPlay : .cantHear
        hint = next
        return .showHint(next)
    }
}

/// Runs the SilenceWatchdog against the real player and the ears in use, twice a second, while the
/// visualizer is on: rebuilds them when asked and says when to show or clear the hint.
@available(macOS 14.2, *)
@MainActor
final class TapWatchdog {
    private var tap: any VisualizerEars
    private var player: PlaybackControlling?
    private var watchdog = SilenceWatchdog()
    private var timer: Timer?
    private var observer: UUID?
    private var state = PlaybackState()
    private var lastPosition: TimeInterval = -1
    /// The hint to show, or nil to hide it.
    var onHint: ((SilenceWatchdog.Hint?) -> Void)?
    /// For benches: replaces "is a song audibly playing" with a fixed answer.
    var audibleOverride: Bool?

    init(tap: any VisualizerEars, player: PlaybackControlling?) {
        self.tap = tap
        self.player = player
    }

    /// Watches other ears from now on, starting over: what the ring already holds came from the old
    /// ones. Clears any hint the old ones caused.
    func watch(_ ears: any VisualizerEars) {
        tap = ears
        if watchdog.hint != nil { onHint?(nil) }
        watchdog = SilenceWatchdog(baseline: ears.ring.stats.nonZeroFrames)
    }

    /// Whether the ears watched have heard any sound since `watch(_:)` or `start()`.
    var hasHeard: Bool { watchdog.hasHeard }

    func start() {
        guard timer == nil else { return }
        watchdog = SilenceWatchdog(baseline: tap.ring.stats.nonZeroFrames)
        if let player {
            state = player.state
            observer = player.addObserver { [weak self] in self?.state = $0 }
        }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let observer { player?.removeObserver(observer) }
        observer = nil
        if watchdog.hint != nil { onHint?(nil) }
        watchdog = SilenceWatchdog()
    }

    private func tick() {
        let moving = state.position != lastPosition
        lastPosition = state.position
        let audible = audibleOverride ?? (state.isPlaying && !state.isLoading && moving)
        let advice = watchdog.observe(now: ProcessInfo.processInfo.systemUptime, audible: audible,
                                      airPlay: tap.status.outputIsAirPlay, nonZeroFrames: tap.ring.stats.nonZeroFrames)
        switch advice {
        case .none:
            break
        case .rebuild where watchdog.hint == .cantHear:
            Log.info("visualizer: watchdog: still only zeros under the can't-hear hint; trying again")
            Task { await tap.rebuild(reason: "can't-hear hint retry") }
        case .rebuild:
            Log.info("visualizer: watchdog: only zeros for \(Int(SilenceWatchdog.silenceLimit)) s while playing; rebuilding the ears")
            Task { await tap.rebuild(reason: "silent while playing") }
        case .showHint(let hint):
            Log.info("visualizer: watchdog: still only zeros after a rebuild; showing the \(hint == .airPlay ? "AirPlay" : "can't-hear") hint")
            onHint?(hint)
        case .clearHint:
            Log.info("visualizer: watchdog: sound is arriving again; hint cleared")
            onHint?(nil)
        }
    }
}
