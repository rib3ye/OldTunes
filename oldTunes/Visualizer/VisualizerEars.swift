import Foundation
import VisualizerCore

/// What the ears are doing, for the log, the silence watchdog and the bench.
struct TapStatus: Sendable, Equatable {
    var isRunning = false
    /// The processes a tap listens to: our own, plus our RemotePlayerService once MusicKit starts it
    /// (AudioHAL.ourRemotePlayers). Empty for SelfCapture, which captures oldTunes as an app.
    var tapped: [AudioHAL.Process] = []
    var outputDevice = ""
    var outputIsAirPlay = false
    var format = ""
    var buildMilliseconds = 0.0
    var failure: String?
    /// What the HAL showed when a tap was built, for the log: how many audio processes it listed,
    /// which of the tapped processes and Apple's players were running output, and each
    /// RemotePlayerService left out because it was running before oldTunes started.
    var seen = ""

    var remotePlayerTapped: Bool { tapped.contains { $0.bundleID == AudioHAL.remotePlayerBundleID } }
}

/// What the visualizer hears the music with. The app uses SelfCapture, ScreenCaptureKit on oldTunes
/// itself, which needs no permission; the test benches use MusicAudioTap, a process tap, which needs
/// System Audio Recording (VisualizerAudio). Both write the same SampleRing.
@MainActor
protocol VisualizerEars: AnyObject {
    var ring: SampleRing { get }
    var status: TapStatus { get }
    /// How far behind the present the render loop reads the ring: about how late the newest sound
    /// arrives, so each step finds new sound rather than the last delivery again.
    var readDelay: TimeInterval { get }
    func start() async
    func stop()
    func rebuild(reason: String) async
}

@available(macOS 14.4, *)
extension SelfCapture: VisualizerEars {
    /// Sound arrives in 20 ms buffers, 31–34 ms after it played on the median and 46–49 ms at worst
    /// in a run (SelfCapture). Past about 30 ms late, the newest sound is older than 50 ms for a few
    /// milliseconds before the next buffer lands, so now and then (buffers about 38 ms late or more)
    /// two steps read the same window. Reading further back would make the picture trail the sound
    /// by more, which is worse.
    var readDelay: TimeInterval { 0.05 }
}
