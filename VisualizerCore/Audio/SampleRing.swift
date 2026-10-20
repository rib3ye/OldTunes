import Foundation
import os

/// The last few seconds of the music, mixed to mono, for the visualizer to analyse.
///
/// The audio tap's IOProc writes every buffer it gets; the render loop reads the 2048 samples an
/// AnalyserNode would hold at a given moment. One lock guards everything, and each side holds it only
/// for a copy of a few thousand floats. The sample array is never copied out whole: a second
/// reference to it would make the IOProc's next write copy all of it.
public final class SampleRing: Sendable {
    /// How the writer is doing, for the silence watchdog.
    public struct Stats: Sendable, Equatable {
        /// Frames written since the ring was made (or since the sample rate last changed).
        public var framesWritten: UInt64 = 0
        /// Of those, frames whose mono sample was not exactly zero. A denied permission gives exact zeros.
        public var nonZeroFrames: UInt64 = 0
        /// Host time of the newest frame; 0 before the first write.
        public var newestHostTime: UInt64 = 0
        public var sampleRate: Double = 0
    }

    /// Chrome's AnalyserNode takes in audio 128 frames at a time, so its window always ends on a
    /// multiple of 128. Reads snap their end down the same way.
    public static let renderQuantum: UInt64 = 128

    private struct State: Sendable {
        var samples: [Float]
        var stats = Stats()
    }

    public let capacity: Int
    private let state: OSAllocatedUnfairLock<State>

    /// Four seconds at 48 kHz by default: enough to look back past a Bluetooth output's latency.
    public init(capacity: Int = 4 * 48_000) {
        self.capacity = capacity
        state = OSAllocatedUnfairLock(initialState: State(samples: [Float](repeating: 0, count: capacity)))
    }

    /// Called from the IOProc with interleaved float samples. Mixes to mono the way Web Audio's
    /// "speakers" down-mix does for stereo, ½(L + R), and scales by `gain`. `firstFrameHostTime` is the
    /// host time of the buffer's first frame (the IOProc's input time stamp). Never allocates, except
    /// once to clear the ring when the sample rate changes.
    public func writeInterleaved(_ samples: UnsafePointer<Float>, frames: Int, channels: Int, gain: Float,
                                 firstFrameHostTime: UInt64, sampleRate: Double) {
        guard frames > 0, channels > 0 else { return }
        let scale = gain / Float(channels)
        // Unchecked: the closure reads the caller's pointer, which is only used while the lock is held.
        state.withLockUnchecked { s in
            if s.stats.sampleRate != sampleRate { Self.restart(&s, sampleRate) }
            let capacity = s.samples.count
            var index = Int(s.stats.framesWritten % UInt64(capacity))
            var nonZero: UInt64 = 0
            s.samples.withUnsafeMutableBufferPointer { ring in
                for frame in 0..<frames {
                    var sum: Float = 0
                    let base = frame * channels
                    for channel in 0..<channels { sum += samples[base + channel] }
                    let mono = sum * scale
                    if mono != 0 { nonZero += 1 }
                    ring[index] = mono
                    index += 1
                    if index == capacity { index = 0 }
                }
            }
            Self.advance(&s, frames: frames, nonZero: nonZero, firstFrameHostTime: firstFrameHostTime)
        }
    }

    /// Mono samples, already mixed. For benches and synthetic sources.
    public func writeMono(_ samples: UnsafeBufferPointer<Float>, gain: Float = 1,
                          firstFrameHostTime: UInt64, sampleRate: Double) {
        guard let base = samples.baseAddress else { return }
        writeInterleaved(base, frames: samples.count, channels: 1, gain: gain,
                         firstFrameHostTime: firstFrameHostTime, sampleRate: sampleRate)
    }

    /// Copies the `out.count` samples that end at `hostTime` (the newest when nil), with the end snapped
    /// down to a 128-frame render quantum. Returns false, and fills zeros, until that much audio has
    /// been written. A `hostTime` older than the ring holds reads the oldest window it still has.
    @discardableResult
    public func read(into out: UnsafeMutableBufferPointer<Float>, endingAt hostTime: UInt64? = nil) -> Bool {
        let count = out.count
        guard count > 0, count <= capacity else { return false }
        // Unchecked: the closure writes the caller's buffer, which is only used while the lock is held.
        return state.withLockUnchecked { s in
            let written = s.stats.framesWritten
            guard written >= UInt64(count), s.stats.sampleRate > 0 else {
                out.update(repeating: 0)
                return false
            }
            var end = written
            if let hostTime, hostTime < s.stats.newestHostTime {
                let behind = HostClock.seconds(s.stats.newestHostTime - hostTime) * s.stats.sampleRate
                end -= min(UInt64(max(0, behind)), written)
            }
            end -= end % Self.renderQuantum
            let oldest = written > UInt64(s.samples.count) ? written - UInt64(s.samples.count) : 0
            end = max(end, oldest + UInt64(count))
            let capacity = s.samples.count
            var index = Int((end - UInt64(count)) % UInt64(capacity))
            s.samples.withUnsafeBufferPointer { ring in
                for i in 0..<count {
                    out[i] = ring[index]
                    index += 1
                    if index == capacity { index = 0 }
                }
            }
            return true
        }
    }

    public var stats: Stats { state.withLock { $0.stats } }

    /// Forgets everything written so far.
    public func reset() {
        state.withLock { s in Self.restart(&s, 0) }
    }

    private static func restart(_ s: inout State, _ sampleRate: Double) {
        for i in s.samples.indices { s.samples[i] = 0 }
        s.stats = Stats(sampleRate: sampleRate)
    }

    private static func advance(_ s: inout State, frames: Int, nonZero: UInt64, firstFrameHostTime: UInt64) {
        s.stats.framesWritten += UInt64(frames)
        s.stats.nonZeroFrames += nonZero
        let span = HostClock.ticks(seconds: Double(frames - 1) / s.stats.sampleRate)
        s.stats.newestHostTime = firstFrameHostTime + span
    }
}

/// Host-time conversions (mach_absolute_time ticks, the clock Core Audio and display links use).
public enum HostClock {
    private static let timebase: (numer: Double, denom: Double) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (Double(info.numer), Double(info.denom))
    }()

    public static func seconds(_ ticks: UInt64) -> Double {
        Double(ticks) * timebase.numer / timebase.denom / 1e9
    }

    public static func ticks(seconds: Double) -> UInt64 {
        UInt64(max(0, seconds * 1e9 * timebase.denom / timebase.numer))
    }

    public static var now: UInt64 { mach_absolute_time() }
}
