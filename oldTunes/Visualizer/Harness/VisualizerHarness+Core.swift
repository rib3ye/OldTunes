import Foundation
import VisualizerCore

/// OLDTUNES_VIS_MODE=core — the pieces every other part leans on: SampleRing and HostClock.
/// No audio, no window; runs in well under a second.
extension VisualizerHarness {
    static func core(_ bench: VisualizerBench) {
        hostClock(bench)
        ringBasics(bench)
        ringWrap(bench)
        ringLookBack(bench)
        ringStereoAndRate(bench)
        frameShape(bench)
    }

    private static func hostClock(_ bench: VisualizerBench) {
        let back = HostClock.seconds(HostClock.ticks(seconds: 1.0))
        bench.check("host clock round trip", abs(back - 1.0) < 1e-6, "1 s → ticks → \(back) s")
    }

    /// A ramp, so every sample says where it came from.
    private static func ramp(_ count: Int, from start: Int = 0) -> [Float] {
        (0..<count).map { Float(start + $0) }
    }

    private static func ringBasics(_ bench: VisualizerBench) {
        let ring = SampleRing(capacity: 8192)
        var out = [Float](repeating: 1, count: 2048)
        let early = out.withUnsafeMutableBufferPointer { ring.read(into: $0) }
        bench.check("empty ring reads zeros", !early && out.allSatisfy { $0 == 0 }, "returned \(early)")

        let samples = ramp(4096)
        samples.withUnsafeBufferPointer { ring.writeMono($0, firstFrameHostTime: 1_000, sampleRate: 48_000) }
        let ok = out.withUnsafeMutableBufferPointer { ring.read(into: $0) }
        bench.check("latest 2048 samples", ok && out.first == 2048 && out.last == 4095,
                    "first \(out.first ?? -1), last \(out.last ?? -1) (want 2048…4095)")
        let stats = ring.stats
        bench.check("stats count frames and non-zero frames", stats.framesWritten == 4096 && stats.nonZeroFrames == 4095,
                    "written \(stats.framesWritten), non-zero \(stats.nonZeroFrames)")

        // 4,100 written: the window's end snaps down to 4,096, the last full 128-frame quantum.
        ramp(4, from: 4096).withUnsafeBufferPointer { ring.writeMono($0, firstFrameHostTime: 2_000, sampleRate: 48_000) }
        out.withUnsafeMutableBufferPointer { _ = ring.read(into: $0) }
        bench.check("window end snaps to a render quantum", out.last == 4095, "last \(out.last ?? -1) (want 4095)")
    }

    private static func ringWrap(_ bench: VisualizerBench) {
        let ring = SampleRing(capacity: 1000)
        for chunk in 0..<5 {
            ramp(500, from: chunk * 500).withUnsafeBufferPointer {
                ring.writeMono($0, firstFrameHostTime: UInt64(chunk) * 1_000, sampleRate: 48_000)
            }
        }
        var out = [Float](repeating: 0, count: 512)
        out.withUnsafeMutableBufferPointer { _ = ring.read(into: $0) }
        // 2,500 written: the end snaps to 2,432, so the window is 1,920…2,431, across the wrap.
        bench.check("reads across the wrap", out.first == 1920 && out.last == 2431,
                    "first \(out.first ?? -1), last \(out.last ?? -1) (want 1920…2431)")
    }

    private static func ringLookBack(_ bench: VisualizerBench) {
        let ring = SampleRing()
        let start: UInt64 = 10_000_000
        ramp(48_000).withUnsafeBufferPointer { ring.writeMono($0, firstFrameHostTime: start, sampleRate: 48_000) }
        var out = [Float](repeating: 0, count: 2048)
        let halfway = start + HostClock.ticks(seconds: 0.5)
        out.withUnsafeMutableBufferPointer { _ = ring.read(into: $0, endingAt: halfway) }
        // Half a second into one second of audio ends near frame 24,000, snapped to 23,936.
        bench.check("reads the window that ended at a host time", out.last == 23_935,
                    "last \(out.last ?? -1) (want 23935)")

        out.withUnsafeMutableBufferPointer { _ = ring.read(into: $0, endingAt: start / 2) }
        bench.check("a time older than the ring reads its oldest window", out.first == 0 && out.last == 2047,
                    "first \(out.first ?? -1), last \(out.last ?? -1)")
    }

    private static func ringStereoAndRate(_ bench: VisualizerBench) {
        let ring = SampleRing(capacity: 4096)
        let interleaved: [Float] = (0..<2048).flatMap { _ in [Float(1), Float(3)] }
        interleaved.withUnsafeBufferPointer {
            ring.writeInterleaved($0.baseAddress!, frames: 2048, channels: 2, gain: 0.5,
                                  firstFrameHostTime: 5_000, sampleRate: 48_000)
        }
        var out = [Float](repeating: 0, count: 2048)
        out.withUnsafeMutableBufferPointer { _ = ring.read(into: $0) }
        bench.check("stereo mixes to ½(L+R) times the gain", out.allSatisfy { $0 == 1 },
                    "got \(out.first ?? -1) (want (1+3)/2 × 0.5 = 1)")

        ramp(16).withUnsafeBufferPointer { ring.writeMono($0, firstFrameHostTime: 6_000, sampleRate: 44_100) }
        let stats = ring.stats
        bench.check("a new sample rate starts the ring over", stats.framesWritten == 16 && stats.sampleRate == 44_100,
                    "written \(stats.framesWritten) at \(Int(stats.sampleRate)) Hz")
    }

    private static func frameShape(_ bench: VisualizerBench) {
        let silent = AudioFrame.silent
        bench.check("a silent frame has the AnalyserNode's shape",
                    silent.wave.count == 2048 && silent.spectrum.count == 1024 && silent.bandEnergy.count == 4,
                    "wave \(silent.wave.count), spectrum \(silent.spectrum.count), bands \(silent.bandEnergy.count)")
    }
}
