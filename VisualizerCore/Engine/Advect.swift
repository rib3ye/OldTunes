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
//  Changed for oldTunes, 2026: AdvectPoint in warp.js (Geiss HDR v335), ported to Swift. The rest
//  of warp.js (the CPU warp) is unused by the original and not ported.

/// `AdvectPoint(sx0, sy0, xform, warps, warp_str, speed_mult, shift_x, shift_y)`: moves a screen point
/// along the blended motion of the four warp maps, the way the GPU warp moves the image. It looks for
/// the point whose motion lands exactly on (sx0, sy0), in four steps; three are usually accurate to
/// a hundredth of a pixel.
///
/// `fields` holds the four maps' `src_dxy` (a missing map counts as no motion); `strengths` holds the
/// four Float32 warp strengths. Returns screen coordinates.
public func advectPoint(x sx0: Double, y sy0: Double, transform xform: TransformHelper, fields: [[Float]],
                        strengths: [Float], speedMultiplier: Double, shiftX: Double, shiftY: Double) -> (x: Double, y: Double) {
    let size = VisualizerConstants.warpMapSize
    let sizeD = Double(size)
    // Screen to normalized.
    let x0 = xform.screenToNormX(sx0)
    let y0 = xform.screenToNormY(sy0)
    var x = x0
    var y = y0

    func field(_ i: Int) -> [Float] { i < fields.count ? fields[i] : [] }
    func strength(_ i: Int) -> Double { strengths.js(i) }
    let src1 = field(0)
    let src2 = field(1)
    let src3 = field(2)
    let src4 = field(3)

    // Iterate until we find the point that points exactly to (x0, y0).
    let iterations = 4
    for _ in 0..<iterations {
        // To warp-map coordinates, [0 … kWarpMapSize].
        let wx = (x * 0.5 + 0.5) * sizeD
        let wy = (y * 0.5 + 0.5) * sizeD

        let iwx0 = toInt32(jsMax(0, jsMin(Double(size - 1), Double(toInt32(wx)))))
        let iwy0 = toInt32(jsMax(0, jsMin(Double(size - 1), Double(toInt32(wy)))))
        let iwx1 = toInt32(jsMax(0, jsMin(Double(size - 1), Double(toInt32(wx + 1)))))
        let iwy1 = toInt32(jsMax(0, jsMin(Double(size - 1), Double(toInt32(wy + 1)))))

        let fx = wx - wx.rounded(.down)
        let fy = wy - wy.rounded(.down)

        // A bilinear lookup in each of the four maps.
        let i00 = (iwx0 + iwy0 * size) * 2
        let i10 = (iwx1 + iwy0 * size) * 2
        let i01 = (iwx0 + iwy1 * size) * 2
        let i11 = (iwx1 + iwy1 * size) * 2
        func sample(_ src: [Float], _ c: Int) -> Double {
            src.js(i00 + c) * (1 - fx) * (1 - fy) +
                src.js(i10 + c) * fx * (1 - fy) +
                src.js(i01 + c) * (1 - fx) * fy +
                src.js(i11 + c) * fx * fy
        }
        let wx1 = sample(src1, 0)
        let wx2 = sample(src2, 0)
        let wx3 = sample(src3, 0)
        let wx4 = sample(src4, 0)
        let wy1 = sample(src1, 1)
        let wy2 = sample(src2, 1)
        let wy3 = sample(src3, 1)
        let wy4 = sample(src4, 1)

        // The four maps, weighted: an xy delta in normalized coordinates.
        var dx = wx1 * strength(0) + wx2 * strength(1) + wx3 * strength(2) + wx4 * strength(3)
        var dy = wy1 * strength(0) + wy2 * strength(1) + wy3 * strength(2) + wy4 * strength(3)

        // This 0.5 matches the GPU warp, which has an errant 0.5 on its warp vector.
        dx *= 0.5 * speedMultiplier
        dy *= 0.5 * speedMultiplier

        dx += shiftX * xform.invW * xform.x0x1
        dy += shiftY * xform.invH * xform.y0y1

        x = (x0 - dx)
        y = (y0 - dy)
    }

    // Back to screen coordinates.
    return (xform.normToScreenX(x), xform.normToScreenY(y))
}
