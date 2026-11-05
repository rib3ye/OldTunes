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
//  Changed for oldTunes, 2026: const.js (Geiss HDR v335), ported to Swift.

/// const.js: sizes shared by the engine and the renderer.
public enum VisualizerConstants {
    /// `kWarpMapSize`: a warp map is this many cells on a side. The GPU warp textures match it.
    public static let warpMapSize = 512
    /// `kNoiseTexSize`, `kNoiseTexCount`: the renderer's noise textures.
    public static let noiseTextureSize = 256
    public static let noiseTextureCount = 4
    /// `kMaxActiveWarps`: warp maps blended at once, one per slot.
    public static let maxActiveWarps = 4
}
