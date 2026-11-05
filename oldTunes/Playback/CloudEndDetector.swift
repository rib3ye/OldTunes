import Foundation
import MusicKit

/// Decides when a MusicKit song has ended, from what the 10 Hz clock sees. MusicKit has no
/// end-of-item callback (RESEARCH.md §10-R3). A plain value with an injected clock, so the
/// harness can replay recorded and invented tick sequences through it.
///
/// Designed from the R3 experiment (evidence/playback/r3_probe.log). At the natural end of a
/// one-song queue, within one 100 ms tick, `playbackTime` jumps from 0.04 s before the end
/// straight to 0.00 and `playbackStatus` goes .playing → .paused; `queue.currentEntry` stays set.
/// So the heuristic RESEARCH.md proposed ("status leaves .playing while position >= duration - 1")
/// never fires: by the time the status changes, the position is already 0. Instead:
///
/// - **End:** the first tick after .playing where the status is something else, the position is
///   reset to ~0 (or parked at the end), nobody paused it, and either the last position seen while
///   playing was within 1.5 s of the end or the wall clock says the end has come (ticks can be
///   starved while the main thread is busy).
/// - **Watchdog:** still wanting to play 3 s after the wall-clock time the song should have ended
///   (projected from the duration and the last tick on which the position moved), while MusicKit
///   is either not playing or frozen at the end. Never seen; insurance against a MusicKit change.
struct CloudEndDetector {
    /// MusicKit has reported .playing at least once since the last restart (play or seek).
    private(set) var sawPlaying = false
    private(set) var lastPlayingPosition: TimeInterval = 0
    private var wasPlaying = false
    private var lastAdvance: ContinuousClock.Instant
    private var lastAdvancePosition: TimeInterval = 0

    init(now: ContinuousClock.Instant = .now) {
        lastAdvance = now
    }

    mutating func restart(at position: TimeInterval, now: ContinuousClock.Instant = .now) {
        wasPlaying = false
        sawPlaying = false
        lastPlayingPosition = position
        lastAdvance = now
        lastAdvancePosition = position
    }

    /// One clock tick. Returns why the song ended, or nil while it is still going.
    mutating func evaluate(status: MusicPlayer.PlaybackStatus, position: TimeInterval, duration: TimeInterval,
                           now: ContinuousClock.Instant, pausedByUs: Bool, wantsPlay: Bool) -> String? {
        guard duration > 0 else { return nil }
        if status == .playing {
            if abs(position - lastAdvancePosition) > 0.01 {
                lastAdvance = now
                lastAdvancePosition = position
            }
            lastPlayingPosition = position
            wasPlaying = true
            sawPlaying = true
        } else if wasPlaying {
            wasPlaying = false
            let parked = position < 1.0 || position >= duration - 1.0
            let nearEnd = lastPlayingPosition >= duration - 1.5 || now >= projectedEnd(duration) - .seconds(1)
            if !pausedByUs, parked, nearEnd {
                return "status \(status) at \(fmt(position)) s, last playing tick at \(fmt(lastPlayingPosition)) of \(fmt(duration)) s"
            }
        }
        if wantsPlay, now >= projectedEnd(duration) + .seconds(3), status != .playing || position >= duration - 0.5 {
            return "watchdog: 3 s past the projected end, status \(status) at \(fmt(position)) s of \(fmt(duration)) s"
        }
        return nil
    }

    private func projectedEnd(_ duration: TimeInterval) -> ContinuousClock.Instant {
        lastAdvance + .seconds(max(0, duration - lastAdvancePosition))
    }

    private func fmt(_ x: Double) -> String { String(format: "%.2f", x) }
}
