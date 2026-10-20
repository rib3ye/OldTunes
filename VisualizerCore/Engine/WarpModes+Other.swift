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
//  Changed for OldTunes, 2026: the radial ripple and starfish modes of buildWarpMap in motion.js
//  (Geiss HDR v335), ported to Swift: 9 and 10.

import Foundation

/// Mode 9, RADIAL RIPPLES: a pond splash around (cx, cy).
struct RadialRipplesKernel: WarpKernel {
    let cx: Double
    let cy: Double
    let freq: Double
    let phase: Double
    let mag: Double
    let bias: Double

    func fill(rows: Range<Int>, into out: UnsafeMutableBufferPointer<Float>) {
        let size = WarpMapBuilder.size
        WarpMapBuilder.axis.withUnsafeBufferPointer { axis in
            var o = 0
            for dy in rows {
                let fdy = axis[dy]
                for dx in 0..<size {
                    let fdx = axis[dx]
                    let tx = fdx - cx
                    let ty = fdy - cy
                    let rad = (tx * tx + ty * ty).squareRoot()
                    let scale = 1.0 + mag * (cos(rad * freq + phase) + bias)
                    let sdx = fdx * scale
                    let sdy = fdy * scale
                    out[o] = Float(sdx - fdx)
                    out[o + 1] = Float(sdy - fdy)
                    o += 2
                }
            }
        }
    }
}

/// Mode 10, STARFISH: a zoom modulated by angle into `fins` arms.
struct StarfishKernel: WarpKernel {
    let str: Double
    let fins: Double
    let cx: Double
    let cy: Double

    func fill(rows: Range<Int>, into out: UnsafeMutableBufferPointer<Float>) {
        let size = WarpMapBuilder.size
        WarpMapBuilder.axis.withUnsafeBufferPointer { axis in
            var o = 0
            for dy in rows {
                let fdy = axis[dy]
                for dx in 0..<size {
                    let fdx = axis[dx]
                    let tx = fdx - cx
                    let ty = fdy - cy
                    let ang = atan2(tx, ty)
                    let scale = 0.987 + 0.010 * cos(ang * fins)
                    var sdx = fdx * scale
                    var sdy = fdy * scale

                    // Calm the motion near the centre, to avoid a discontinuity there.
                    let rad = (tx * tx + ty * ty).squareRoot()
                    let att = jsMax(0, jsMin(1.0, (rad - 0.05) * 4))
                    sdx = fdx + (sdx - fdx) * att * str
                    sdy = fdy + (sdy - fdy) * att * str
                    out[o] = Float(sdx - fdx)
                    out[o + 1] = Float(sdy - fdy)
                    o += 2
                }
            }
        }
    }
}

extension WarpMapBuilder {
    static func planRadialRipples(_ bank: inout RandomBank, _ prefs: inout WarpPrefs) -> any WarpKernel {
        prefs.circScale = 4.0
        let cx = (bank.next() * 2 - 1) * 0.25
        let cy = (bank.next() * 2 - 1) * 0.25
        prefs.adjustCenter(cx, cy)

        let freq = 6 + 18 * bank.next()
        let phase = bank.next() * 6.28
        let base = (0.00012 + 0.00005 * bank.next())
        let mag = base / freq * 100.0 * bank.pick(1.0, else: -1.0)
        let bias = bank.next() * 2 - 1
        return RadialRipplesKernel(cx: cx, cy: cy, freq: freq, phase: phase, mag: mag, bias: bias)
    }

    static func planStarfish(_ bank: inout RandomBank, _ prefs: inout WarpPrefs) -> any WarpKernel {
        var str = 0.4 + 1.4 * bank.next()
        if bank.next() < 0.3 {
            str = str * -0.25
        }
        let fins = 3 + (bank.next() * 6).rounded(.down)
        let cx = (bank.next() * 2 - 1) * 0.12
        let cy = (bank.next() * 2 - 1) * 0.12
        prefs.adjustCenter(cx, cy)
        return StarfishKernel(str: str, fins: fins, cx: cx, cy: cy)
    }
}
