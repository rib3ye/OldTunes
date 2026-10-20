import Foundation

/// The one 10 Hz timer behind both transports (RESEARCH.md §5.5). One path means the LCD and
/// scrubber cannot drift between engines, and 10 Hz is already six times finer than a 240 pt
/// scrubber can show for a three-minute song.
///
/// Runs in `.common` run-loop mode so the LCD keeps moving while a menu is open or the scrubber
/// is being dragged (both put the run loop in event-tracking mode).
@MainActor
final class PlaybackClock {
    static let interval: TimeInterval = 0.1

    var onTick: (() -> Void)?
    private var timer: Timer?

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            // Scheduled on the main run loop below, so this always runs on the main thread.
            MainActor.assumeIsolated { self?.onTick?() }
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
