import Foundation
import VisualizerCore

/// Decides whether the tap has gone deaf: a song is playing, but nothing but exact zeros arrives.
///
/// Two causes look the same from here: the "System Audio Recording Only" permission is off (the tap
/// then delivers zeros and no error), or the tap has gone silent on its own, as one report says it
/// can in long sessions on macOS 26.5. So after `silenceLimit` of zeros it asks for one rebuild; if
/// zeros continue for another `silenceLimit`, it asks for the hint. While the permission hint shows, it
/// asks for a new tap every `rebuildSpacing`, since a tap made while the permission was off may stay
/// deaf after the user turns it back on. Any non-zero sample clears the hint.
/// Exact zeros only: real music that is merely quiet is never mistaken for silence. When the output is
/// AirPlay it asks for an AirPlay message instead, since that audio may never pass through the tap.
struct SilenceWatchdog: Equatable {
    enum Hint: Equatable { case permission, airPlay }
    enum Advice: Equatable { case none, rebuild, showHint(Hint), clearHint }

    static let silenceLimit: TimeInterval = 3
    /// At most one rebuild this often; a second silence soon after goes straight to the hint. Also how
    /// often a new tap is tried while the permission hint shows.
    static let rebuildSpacing: TimeInterval = 30

    private(set) var hint: Hint?
    private var lastNonZero: UInt64 = 0
    private var silentSince: TimeInterval?
    private var rebuiltThisSilence = false
    private var lastRebuild = -TimeInterval.infinity

    /// Call about twice a second. `audible`: a song is playing and its position is moving.
    mutating func observe(now: TimeInterval, audible: Bool, airPlay: Bool, nonZeroFrames: UInt64) -> Advice {
        let heard = nonZeroFrames > lastNonZero
        lastNonZero = nonZeroFrames
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
            guard hint == .permission, now - lastRebuild >= Self.rebuildSpacing else { return .none }
            lastRebuild = now
            return .rebuild
        }
        let next: Hint = airPlay ? .airPlay : .permission
        hint = next
        return .showHint(next)
    }
}

/// Runs the SilenceWatchdog against the real player and tap, twice a second, while the visualizer
/// is on: rebuilds the tap when asked and tells the visualizer view when to show or clear the hint.
@available(macOS 14.2, *)
@MainActor
final class TapWatchdog {
    private let tap: MusicAudioTap
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

    init(tap: MusicAudioTap, player: PlaybackControlling?) {
        self.tap = tap
        self.player = player
    }

    func start() {
        guard timer == nil else { return }
        watchdog = SilenceWatchdog()
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
        case .rebuild where watchdog.hint == .permission:
            Log.info("visualizer: watchdog: still only zeros under the permission hint; trying a new tap")
            Task { await tap.rebuild(reason: "permission hint retry") }
        case .rebuild:
            Log.info("visualizer: watchdog: only zeros for \(Int(SilenceWatchdog.silenceLimit)) s while playing; rebuilding the tap")
            Task { await tap.rebuild(reason: "silent while playing") }
        case .showHint(let hint):
            Log.info("visualizer: watchdog: still only zeros after a rebuild; showing the \(hint == .airPlay ? "AirPlay" : "permission") hint")
            onHint?(hint)
        case .clearHint:
            Log.info("visualizer: watchdog: sound is arriving again; hint cleared")
            onHint?(nil)
        }
    }
}
