import Foundation

/// Turns the tap's sample ring into AudioFrames, one per engine step: reads the 2048 samples that
/// end at the step's moment, applies the gain, and runs Geiss HDR's getFrame on them.
///
/// The gain undoes OldTunes' own local-file volume, which is applied before the tap hears the sound
/// (cloud songs' volume is the output device's, applied after it), so the picture doesn't dim with the
/// volume slider. Not thread-safe: one instance per render loop.
public final class AudioFeed {
    public let ring: SampleRing
    private let builder: AudioFrameBuilder
    private var window: [Float]

    public init(ring: SampleRing, builder: AudioFrameBuilder = AudioFrameBuilder()) {
        self.ring = ring
        self.builder = builder
        window = [Float](repeating: 0, count: builder.analyser.fftSize)
    }

    /// The frame for the window ending at `hostTime` (the newest audio when nil). Silent until the ring
    /// holds a full window; the analyser's smoothing still runs, as an AnalyserNode fed silence would.
    public func frame(endingAt hostTime: UInt64? = nil, gain: Float = 1, waveScale: Double = 1) -> AudioFrame {
        let sampleRate = ring.stats.sampleRate
        window.withUnsafeMutableBufferPointer { _ = ring.read(into: $0, endingAt: hostTime) }
        if gain != 1 {
            for i in window.indices { window[i] *= gain }
        }
        return window.withUnsafeBufferPointer {
            builder.frame(timeDomain: $0, sampleRate: sampleRate > 0 ? sampleRate : 48_000, waveScale: waveScale)
        }
    }
}
