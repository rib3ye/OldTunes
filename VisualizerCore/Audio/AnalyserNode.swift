import Accelerate
import Foundation

/// Web Audio's AnalyserNode frequency analysis, done the way Chrome does it, so the visualizer sees
/// the numbers Geiss HDR sees in Chrome (Web Audio spec §1.8.4, Chromium's RealtimeAnalyser):
///
/// 1. Multiply the fftSize newest samples by a Blackman window (α = 0.16, periodic: n / N).
/// 2. Real FFT. vDSP's is twice the true DFT, so the input is halved first, as Chrome's FFTFrame does.
/// 3. Magnitude of each bin divided by fftSize, the packed Nyquist value dropped from bin 0.
/// 4. Smooth over time: τ · previous + (1 − τ) · new, in Double, stored as Float.
/// 5. 20 · log10 of each bin, in Float.
///
/// Each call to `analyse` is one getFloatFrequencyData at a new moment, so it applies the smoothing
/// once. Not thread-safe: one instance per render loop.
public final class AnalyserNode {
    public let fftSize: Int
    public let smoothingTimeConstant: Double
    public var binCount: Int { fftSize / 2 }

    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]
    /// Chrome's MagnitudeBuffer: the smoothed linear magnitudes, carried from call to call.
    private var magnitudes: [Float]
    private var input: [Float]
    private var real: [Float]
    private var imag: [Float]

    public init(fftSize: Int = AudioFrame.fftSize, smoothingTimeConstant: Double = AudioFrame.smoothingTimeConstant) {
        precondition(fftSize >= 32 && fftSize & (fftSize - 1) == 0, "fftSize must be a power of two")
        self.fftSize = fftSize
        self.smoothingTimeConstant = min(1, max(0, smoothingTimeConstant))
        log2n = vDSP_Length(fftSize.trailingZeroBitCount)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("vDSP could not set up a \(fftSize)-point FFT")
        }
        self.setup = setup
        // Chrome computes the window in Double and multiplies each sample by it as a Float.
        window = (0..<fftSize).map { i in
            let x = Double(i) / Double(fftSize)
            return Float(0.42 - 0.5 * cos(2 * Double.pi * x) + 0.08 * cos(2 * Double.pi * 2 * x))
        }
        magnitudes = [Float](repeating: 0, count: fftSize / 2)
        input = [Float](repeating: 0, count: fftSize)
        real = [Float](repeating: 0, count: fftSize / 2)
        imag = [Float](repeating: 0, count: fftSize / 2)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Analyses `timeDomain` (exactly `fftSize` samples, oldest first) and writes `binCount` decibel
    /// values to `decibels`. A silent bin reads −infinity, as in Chrome.
    public func analyse(_ timeDomain: UnsafeBufferPointer<Float>, decibels: UnsafeMutableBufferPointer<Float>) {
        precondition(timeDomain.count == fftSize && decibels.count == binCount)
        let n = fftSize
        let half = n / 2
        for i in 0..<n { input[i] = timeDomain[i] * window[i] * 0.5 }

        let k = smoothingTimeConstant
        let scale = 1.0 / Double(n)
        real.withUnsafeMutableBufferPointer { re in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                input.withUnsafeBufferPointer { samples in
                    samples.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                // Bin 0's imaginary slot holds the Nyquist value in vDSP's packed layout.
                im[0] = 0
                for bin in 0..<half {
                    let magnitude = hypot(Double(re[bin]), Double(im[bin])) * scale
                    var smoothed = Float(k * Double(magnitudes[bin]) + (1 - k) * magnitude)
                    if !smoothed.isFinite { smoothed = 0 }
                    magnitudes[bin] = smoothed
                    decibels[bin] = 20 * log10f(smoothed)
                }
            }
        }
    }

    /// Forgets the smoothing history, as a fresh AnalyserNode starts.
    public func reset() {
        for i in magnitudes.indices { magnitudes[i] = 0 }
    }
}
