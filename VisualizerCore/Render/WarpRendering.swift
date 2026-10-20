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
//  Changed for OldTunes, 2026: the presenter interface the engine calls in webgpu_present.js
//  (Geiss HDR v335), as a Swift protocol so the engine and the Metal renderer meet in one place.

/// One warp map: motion.js's `src_dxy`, a 512×512 grid of interleaved (dx, dy) offsets. The engine
/// hands the same map to the renderer every step; the renderer uploads it again only when `id` changes,
/// as the original compares the Float32Array it was given last time.
public struct WarpField: Sendable {
    public let id: UInt64
    public let size: Int
    public let dxy: [Float]

    public init(id: UInt64, size: Int, dxy: [Float]) {
        precondition(dxy.count == size * size * 2, "a warp field is size × size (dx, dy) pairs")
        self.id = id
        self.size = size
        self.dxy = dxy
    }
}

/// What engine.js and main.js call on the presenter (webgpu_present.js), minus the title overlay.
/// The engine side (Driver, WarpEngine) calls it; the Metal renderer implements it.
@MainActor
public protocol WarpRendering: AnyObject {
    /// Feedback-buffer size in pixels: the engine draws its dots in these coordinates.
    var indexWidth: Int { get }
    var indexHeight: Int { get }

    /// `SetWarpMap(slot, warp_map)`: the map in one of the four slots (0...3).
    func setWarpMap(slot: Int, field: WarpField)

    /// `warpAndDrawWaveform(w0, w1, w2, w3, shift_x, shift_y, waveform, darkening, time)`: one simulation
    /// step. Auto-exposure, then the warp of the old frame into the new one, then the dots, drawn
    /// additively into the high byte. `points` holds (x, y, size_px, alpha) per dot, in pixel-centre
    /// coordinates of the feedback buffer.
    func warpAndDrawWaveform(weights: SIMD4<Float>, shift: SIMD2<Float>, points: [Float],
                             darkening: Float, time: Float)

    /// `uploadPaletteRGBA8UNorm(paletteRGBA)`: 256 RGBA entries, values 0…3 where 1 is SDR white.
    func uploadPalette(_ rgba: [Float])
}
