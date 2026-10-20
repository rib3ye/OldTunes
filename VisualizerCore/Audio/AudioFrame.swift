//  Geiss HDR
//  Copyright (c) 2026 Ryan Geiss
//  www.geisswerks.com/geiss_hdr
//
//  License: Apache-2.0 - see VisualizerCore/LICENSE.txt
//
//  Attribution Notice: see VisualizerCore/NOTICE.txt
//    Derivative works and redistributions must retain this NOTICE file.
//
//  Naming / Branding Notice: see VisualizerCore/NOTICE.txt
//    "Geiss" and "Geiss HDR" are reserved names for the original Geiss HDR project.
//    The Apache-2.0 license does not grant permission to use those names, or
//    confusingly similar names, for derivative works except as needed to describe
//    the origin of the work or reproduce the content of the NOTICE file.
//
//  Output permissions (for still images and still image sequences generated
//    using this software): see VisualizerCore/OUTPUTS.txt
//
//  Changed for OldTunes, 2026: the frame AudioInput.getFrame() returns in audio_input.js
//  (Geiss HDR v335), ported to Swift.

import Foundation

/// One video frame's worth of audio analysis, in the shape `AudioInput.getFrame()` hands the engine:
/// an AnalyserNode with fftSize 2048 and smoothingTimeConstant 0.6, read once per engine step.
public struct AudioFrame: Sendable {
    /// The latest 2048 samples, mono, times the user's wave scale (getFloatTimeDomainData).
    public var wave: [Float]
    /// Root mean square of `wave`.
    public var rms: Double
    /// Mean absolute step between neighbouring samples, divided by the wave scale.
    public var visualEnergy: Double
    /// 1024 bins of linear power tilted by frequency, `10^(dB/10) · binHz`, made from
    /// getFloatFrequencyData so the bands are perceptually even.
    public var spectrum: [Float]
    /// Mean of `spectrum` in each of `AudioFrame.bands`: bass, mid, high, all.
    public var bandEnergy: [Float]

    public static let fftSize = 2048
    public static let binCount = fftSize / 2
    public static let smoothingTimeConstant = 0.6

    /// main.js `g_level_bands`, in Hz.
    public static let bands: [(low: Double, high: Double)] = [(30, 200), (200, 2200), (2200, 12000), (30, 12000)]

    public init(wave: [Float], rms: Double, visualEnergy: Double, spectrum: [Float], bandEnergy: [Float]) {
        self.wave = wave
        self.rms = rms
        self.visualEnergy = visualEnergy
        self.spectrum = spectrum
        self.bandEnergy = bandEnergy
    }

    /// What a silent input produces, for before the tap delivers anything.
    public static let silent = AudioFrame(wave: [Float](repeating: 0, count: fftSize), rms: 0, visualEnergy: 0,
                                          spectrum: [Float](repeating: 0, count: binCount),
                                          bandEnergy: [Float](repeating: 0, count: bands.count))
}

/// `AudioInput.getFrame({ waveScale, wantWave: true, wantSpec: true, bandsHz: g_level_bands })` and its
/// `NormalizeSpectrumAndSumBands`, fed with the time-domain window instead of an AnalyserNode.
/// Keeps the original's arithmetic: Double maths, Float32Array storage. Not thread-safe.
public final class AudioFrameBuilder {
    public let analyser: AnalyserNode
    /// The last frame's getFloatFrequencyData, before getFrame turns it into the perceptual spectrum.
    public private(set) var decibels: [Float]

    public init(analyser: AnalyserNode = AnalyserNode()) {
        self.analyser = analyser
        decibels = [Float](repeating: 0, count: analyser.binCount)
    }

    /// `timeDomain` is the AnalyserNode's window: its fftSize newest mono samples, oldest first.
    public func frame(timeDomain: UnsafeBufferPointer<Float>, sampleRate: Double, waveScale: Double = 1) -> AudioFrame {
        let n = analyser.fftSize
        precondition(timeDomain.count == n)

        // --- waveform ---
        var wave = [Float](repeating: 0, count: n)
        var sumSq = 0.0
        var energySum = 0.0
        var prev = Double(timeDomain[0]) * waveScale
        for i in 0..<n {
            let v = Double(timeDomain[i]) * waveScale
            wave[i] = Float(v)
            sumSq += v * v
            energySum += abs(v - prev)
            prev = v
        }
        let rms = (sumSq / Double(n)).squareRoot()
        let visualEnergy = energySum / Double(n - 1) / waveScale

        // --- spectrum ---
        decibels.withUnsafeMutableBufferPointer { analyser.analyse(timeDomain, decibels: $0) }
        let bins = analyser.binCount
        let nyquist = sampleRate / 2
        var spectrum = [Float](repeating: 0, count: bins)
        for i in 0..<bins {
            // _binToHz divides by N − 1, not N; kept as written.
            let freq = Double(i) * (nyquist / Double(bins - 1))
            spectrum[i] = Float(pow(10, Double(decibels[i]) / 10) * freq)
        }
        let bandEnergy = AudioFrame.bands.map { band -> Float in
            let i0 = Self.hzToBin(band.low, nyquist: nyquist, bins: bins)
            let i1 = Self.hzToBin(band.high, nyquist: nyquist, bins: bins)
            let lo = max(0, min(i0, i1))
            let hi = min(bins - 1, max(i0, i1))
            var sum = 0.0
            if hi >= lo { for i in lo...hi { sum += Double(spectrum[i]) } }
            let norm = hi >= lo ? hi - lo + 1 : 1
            return Float(sum / Double(norm))
        }
        return AudioFrame(wave: wave, rms: rms, visualEnergy: visualEnergy, spectrum: spectrum, bandEnergy: bandEnergy)
    }

    /// `_hzToBin`: Math.round of the clamped frequency's share of Nyquist, times N − 1.
    static func hzToBin(_ hz: Double, nyquist: Double, bins: Int) -> Int {
        let clamped = max(0, min(nyquist, hz))
        return Int(((clamped / nyquist) * Double(bins - 1)).rounded())
    }
}
