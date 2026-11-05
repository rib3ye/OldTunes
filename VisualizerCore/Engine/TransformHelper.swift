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
//  Changed for oldTunes, 2026: the TransformHelper class in coords.js (Geiss HDR v335), ported to Swift.

/// Converts between two coordinate spaces:
/// 1. Screen space: [0 … W−1] × [0 … H−1].
/// 2. Normalized space: [−1 … 1] × [−1 … 1], but aspect-aware. It is a crop of a square, so a 2:1 wide
///    window spans [−1 … 1] in x and only [−0.5 … 0.5] in y.
public struct TransformHelper: Sendable {
    public let w: Double
    public let h: Double
    public let invW: Double
    public let invH: Double
    public let x0x1: Double
    public let y0y1: Double
    public let invX0x1: Double
    public let invY0y1: Double

    public init(width: Double, height: Double) {
        // The window is fitted maximally to a [−1 … 1] × [−1 … 1] square.
        let aspect = width * 1.0 / height
        var x0 = -1.0
        var y0 = -1.0
        var x1 = 1.0
        var y1 = 1.0
        if aspect > 1.0 {
            // wide
            y0 /= aspect
            y1 /= aspect
        } else {
            // tall
            x0 *= aspect
            x1 *= aspect
        }
        w = width
        h = height
        invW = 1.0 / width
        invH = 1.0 / height
        x0x1 = x1 - x0
        y0y1 = y1 - y0
        invX0x1 = 1.0 / x0x1
        invY0y1 = 1.0 / y0y1
    }

    /// Normalized [−1 … 1] to screen [0 … W]: `(fx · inv_x0x1 + 0.5) · W`.
    @inline(__always)
    public func normToScreenX(_ fx: Double) -> Double { (fx * invX0x1 + 0.5) * w }

    @inline(__always)
    public func normToScreenY(_ fy: Double) -> Double { (fy * invY0y1 + 0.5) * h }

    /// Screen [0 … W] to normalized [−1 … 1]: `(dx · inv_W − 0.5) · x0x1`.
    @inline(__always)
    public func screenToNormX(_ dx: Double) -> Double { (dx * invW - 0.5) * x0x1 }

    @inline(__always)
    public func screenToNormY(_ dy: Double) -> Double { (dy * invH - 0.5) * y0y1 }
}
