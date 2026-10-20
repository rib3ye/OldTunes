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
