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
//  Changed for oldTunes, 2026: the zooming modes of buildWarpMap in motion.js (Geiss HDR v335),
//  ported to Swift: 0–2, 11–15, 17–19, 21–25, 27–29 and 31–38.

import Foundation

// MARK: - Modes 0, 1, 2, 12, 15, 17, 22: zooms written in the new style

/// Mode 0, SIMPLE ZOOM; mode 1, POWER ZOOM (`power` = true): zoom toward the centre plus a very mild
/// rotation.
struct CenterZoomKernel: WarpKernel {
    let zoom: Double
    let cosRot: Double
    let sinRot: Double
    let power: Bool

    func fill(rows: Range<Int>, into out: UnsafeMutableBufferPointer<Float>) {
        let size = WarpMapBuilder.size
        WarpMapBuilder.axis.withUnsafeBufferPointer { axis in
            var o = 0
            for dy in rows {
                let fdy = axis[dy]
                for dx in 0..<size {
                    let fdx = axis[dx]
                    var sdx: Double
                    var sdy: Double
                    if power {
                        let r = (fdx * fdx + fdy * fdy)
                        sdx = fdx + (0.0 - fdx) * r * zoom
                        sdy = fdy + (0.0 - fdy) * r * zoom
                    } else {
                        sdx = fdx + (0.0 - fdx) * zoom
                        sdy = fdy + (0.0 - fdy) * zoom
                    }
                    let rx = sdx * cosRot - sdy * sinRot
                    let ry = sdx * sinRot + sdy * cosRot
                    sdx = rx
                    sdy = ry
                    out[o] = Float(sdx - fdx)
                    out[o + 1] = Float(sdy - fdy)
                    o += 2
                }
            }
        }
    }
}

/// Mode 2, LANDING: zooming over terrain, plus a very mild rotation.
struct LandingKernel: WarpKernel {
    let str: Double
    let cosAngle: Double
    let sinAngle: Double
    let cosRot: Double
    let sinRot: Double

    func fill(rows: Range<Int>, into out: UnsafeMutableBufferPointer<Float>) {
        let size = WarpMapBuilder.size
        WarpMapBuilder.axis.withUnsafeBufferPointer { axis in
            var o = 0
            for dy in rows {
                let fdy = axis[dy]
                for dx in 0..<size {
                    let fdx = axis[dx]
                    var rx = fdx * cosAngle - fdy * sinAngle
                    var ry = fdx * sinAngle + fdy * cosAngle
                    var sdx = fdx
                    var sdy = fdy
                    let zoom = 1.0 - (1.0 / (-ry + 1.4)) * str
                    sdx *= zoom
                    sdy *= zoom
                    rx = sdx * cosRot - sdy * sinRot
                    ry = sdx * sinRot + sdy * cosRot
                    sdx = rx
                    sdy = ry
                    out[o] = Float(sdx - fdx)
                    out[o + 1] = Float(sdy - fdy)
                    o += 2
                }
            }
        }
    }
}

/// Mode 12, SPHERE.
struct SphereKernel: WarpKernel {
    let power: Double
    let scale: Double
    let invScale: Double
    let str: Double

    func fill(rows: Range<Int>, into out: UnsafeMutableBufferPointer<Float>) {
        let size = WarpMapBuilder.size
        WarpMapBuilder.axis.withUnsafeBufferPointer { axis in
            var o = 0
            for dy in rows {
                let fdy = axis[dy]
                for dx in 0..<size {
                    let fdx = axis[dx]
                    let origRad = (fdx * fdx + fdy * fdy + 0.00001).squareRoot()
                    let rad = pow(origRad * scale, power) * invScale
                    let invRad = 1.0 / origRad
                    let nx = fdx * invRad
                    let ny = fdy * invRad
                    let sdx = fdx + nx * (rad - origRad) * str
                    let sdy = fdy + ny * (rad - origRad) * str
                    out[o] = Float(sdx - fdx)
                    out[o + 1] = Float(sdy - fdy)
                    o += 2
                }
            }
        }
    }
}

/// Mode 15, BLACK HOLE. 0.5 gives a strong perspective zoom, 1.0 a black hole, 1.5 a black hole with
/// hints of a sphere.
struct BlackHoleKernel: WarpKernel {
    let str: Double

    func fill(rows: Range<Int>, into out: UnsafeMutableBufferPointer<Float>) {
        let size = WarpMapBuilder.size
        WarpMapBuilder.axis.withUnsafeBufferPointer { axis in
            var o = 0
            for dy in rows {
                let fdy = axis[dy]
                for dx in 0..<size {
                    let fdx = axis[dx]
                    var sdx = fdx
                    var sdy = fdy
                    let rad = (fdx * fdx + fdy * fdy).squareRoot()
                    var scale = 0.97 + 0.1 * rad
                    scale = pow(scale, 4)
                    sdx *= scale
                    sdy *= scale
                    sdx = fdx + (sdx - fdx) * -str
                    sdy = fdy + (sdy - fdy) * -str
                    out[o] = Float(sdx - fdx)
                    out[o + 1] = Float(sdy - fdy)
                    o += 2
                }
            }
        }
    }
}

/// Mode 17, 1/Z ZOOM: RAD = 1/Z, so Z = 1/RAD; move along Z and project back.
struct InverseZoomKernel: WarpKernel {
    let speed: Double
    let cosRot: Double
    let sinRot: Double

    func fill(rows: Range<Int>, into out: UnsafeMutableBufferPointer<Float>) {
        let size = WarpMapBuilder.size
        WarpMapBuilder.axis.withUnsafeBufferPointer { axis in
            var o = 0
            for dy in rows {
                let fdy = axis[dy]
                for dx in 0..<size {
                    let fdx = axis[dx]
                    let origRad = (fdx * fdx + fdy * fdy + 0.00001).squareRoot()
                    let invRad = 1.0 / origRad
                    let nx = fdx * invRad
                    let ny = fdy * invRad
                    var dist = invRad
                    dist += speed
                    let rad = 1.0 / dist
                    var sdx = fdx + nx * (rad - origRad)
                    var sdy = fdy + ny * (rad - origRad)
                    let rx = sdx * cosRot - sdy * sinRot
                    let ry = sdx * sinRot + sdy * cosRot
                    sdx = rx
                    sdy = ry
                    out[o] = Float(sdx - fdx)
                    out[o + 1] = Float(sdy - fdy)
                    o += 2
                }
            }
        }
    }
}

/// Mode 22, FISSURE, a.k.a. two-plane zoom: the camera flies between two infinite planes.
struct FissureKernel: WarpKernel {
    let cosTheta: Double
    let sinTheta: Double
    let cosMinusTheta: Double
    let sinMinusTheta: Double
    let dz: Double
    let planeY: Double
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
                    // Rotate around the Z axis.
                    let rrx = fdx - cx
                    let rry = fdy - cy
                    let rx = rrx * cosTheta - rry * sinTheta
                    let ry = rrx * sinTheta + rry * cosTheta

                    // Camera at (0, 0, 0), virtual screen plane at z = 1, infinite XZ planes at y = ±plane_y.
                    // The view ray, normalized:
                    var vx = rx
                    var vy = ry
                    var vz = 1.0
                    var vNormScale = 1.0 / (vx * vx + vy * vy + vz * vz).squareRoot()
                    vx *= vNormScale
                    vy *= vNormScale
                    vz *= vNormScale

                    // Where the ray meets y = ±plane_y.
                    let whichPlaneY = planeY * ((ry < 0) ? -1 : 1)
                    var t = whichPlaneY / vy
                    let ix = vx * t
                    let iy = vy * t
                    var iz = vz * t

                    // Move that point, and look at it again.
                    iz += dz
                    vx = ix
                    vy = iy
                    vz = iz
                    vNormScale = 1.0 / (vx * vx + vy * vy + vz * vz).squareRoot()
                    vx *= vNormScale
                    vy *= vNormScale
                    vz *= vNormScale

                    // Project it back onto the screen plane.
                    t = 1 / vz
                    let fx = vx * t
                    let fy = vy * t

                    // Rotate back, so the displacement makes sense.
                    var sdx = fx * cosMinusTheta - fy * sinMinusTheta
                    var sdy = fx * sinMinusTheta + fy * cosMinusTheta
                    sdx += cx
                    sdy += cy
                    out[o] = Float(sdx - fdx)
                    out[o + 1] = Float(sdy - fdy)
                    o += 2
                }
            }
        }
    }
}

extension WarpMapBuilder {
    /// `LinearInterp(lo, hi, t)`.
    @inline(__always)
    static func linearInterp(_ lo: Double, _ hi: Double, _ t: Double) -> Double {
        lo + (hi - lo) * t
    }

    /// `LogInterp(lo, hi, t)`: lo and hi must both be > 0; t may leave [0, 1].
    @inline(__always)
    static func logInterp(_ lo: Double, _ hi: Double, _ t: Double) -> Double {
        lo * pow(hi / lo, t)
    }

    static func planSimpleZoom(_ bank: inout RandomBank, _ prefs: inout WarpPrefs) -> any WarpKernel {
        prefs.wavePrefsWeight *= 10
        var zoom = 0.004 + 0.016 * bank.next()
        if bank.next() < 0.1 {
            zoom *= -0.25
        }
        // Add in a very mild rotation.
        let rot = (bank.next() * 2 - 1) * 0.0015
        return CenterZoomKernel(zoom: zoom, cosRot: cos(rot), sinRot: sin(rot), power: false)
    }

    static func planPowerZoom(_ bank: inout RandomBank, _ prefs: inout WarpPrefs) -> any WarpKernel {
        prefs.wavePrefsWeight *= 10
        var zoom = (0.4 + 2.7 * bank.next()) * 0.03 * 1.8
        if bank.next() < 0.01 {
            zoom *= -0.4
        }
        let rot = (bank.next() * 2 - 1) * 0.0015
        return CenterZoomKernel(zoom: zoom, cosRot: cos(rot), sinRot: sin(rot), power: true)
    }

    static func planLanding(_ bank: inout RandomBank, _ prefs: inout WarpPrefs) -> any WarpKernel {
        prefs.wavePrefsWeight *= 5
        let str = 0.027 * (0.1 + 0.9 * bank.next())
        let angle = bank.next() * 6.28
        let rot = (bank.next() * 2 - 1) * 0.0015
        return LandingKernel(str: str, cosAngle: cos(angle), sinAngle: sin(angle), cosRot: cos(rot), sinRot: sin(rot))
    }

    static func planSphere(_ bank: inout RandomBank, _ prefs: inout WarpPrefs) -> any WarpKernel {
        prefs.wavePrefsWeight *= 10
        let power = linearInterp(1.03, 1.10, bank.next())
        // Below 1: a crop of an oversized sphere; 1: a sphere fitted to the screen; above 1: an egg.
        let t1 = bank.next()
        let t = (t1 + bank.next()) * 0.5
        let scale = logInterp(1.5, 4.0, t)
        let str = 0.1 + 0.4 * bank.next()
        return SphereKernel(power: power, scale: scale, invScale: 1.0 / scale, str: str)
    }

    static func planBlackHole(_ bank: inout RandomBank, _ prefs: inout WarpPrefs) -> any WarpKernel {
        prefs.wavePrefsWeight *= 10  // A very dominant effect.
        prefs.circRadLo = 0.9
        prefs.circRadHi = 1.5
        let str = (0.75 + 1.5 * bank.next())
        return BlackHoleKernel(str: str)
    }

    static func planInverseZoom(_ bank: inout RandomBank, _ prefs: inout WarpPrefs) -> any WarpKernel {
        prefs.wavePrefsWeight *= 10
        let speedMin = 0.015
        let speedMax = 0.16
        let speedPow = 2.0  // > 1 biases toward speedMin; [0, 1] toward speedMax.
        _ = pow(bank.next(), 3.0)  // The original draws a `t` it never uses.
        let speed = linearInterp(speedMin, speedMax, pow(bank.next(), speedPow))
        let rot = (bank.next() * 2 - 1) * 0.0015
        return InverseZoomKernel(speed: speed, cosRot: cos(rot), sinRot: sin(rot))
    }

    static func planFissure(_ bank: inout RandomBank, _ prefs: inout WarpPrefs) -> any WarpKernel {
        prefs.wavePrefsWeight *= 10
        // This mode suppresses the motion of the others while it's active; it doesn't play nice.
        prefs.hogMotionWeight *= 10

        let theta = bank.next() * 6.28
        let dz = (0.015 + 0.015 * bank.next()) * 1.0
        let planeY = 1.01 + 0.5 * bank.next()

        // (cx, cy) centres both the fissure and the wave. It only moves across the fissure, which
        // keeps the wave more centred.
        let waveOffset = (bank.next() * 2 - 1) * 0.6
        let cx = waveOffset * cos(-theta + Double.pi / 2)
        let cy = waveOffset * sin(-theta + Double.pi / 2)

        // Instead of AdjustCenter, most of the time:
        if bank.next() < 0.99 {
            prefs.flatAngleLo = -theta
            prefs.flatAngleHi = -theta
            prefs.flatCxLo = cx
            prefs.flatCxHi = cx
            prefs.flatCyLo = cy
            prefs.flatCyHi = cy
            prefs.flatAngleBiasTowardHorizontalAngles = 0.0
            prefs.flatStereoSepLo *= 0.5
            prefs.flatStereoSepHi *= 0.7
            prefs.flatStereoAmplitudeScale *= 0.6
            prefs.circCxLo = cx
            prefs.circCxHi = cx
            prefs.circCyLo = cy
            prefs.circCyHi = cy
        }
        // But do update these two, so radial beat dots show up centred.
        prefs.motionCx = cx
        prefs.motionCy = cy

        return FissureKernel(cosTheta: cos(theta), sinTheta: sin(theta), cosMinusTheta: cos(-theta),
                             sinMinusTheta: sin(-theta), dz: dz, planeY: planeY, cx: cx, cy: cy)
    }
}

// MARK: - The old modes: zoom about (cx, cy) by a per-pixel scale, plus a turn

/// The per-pixel scale of one of the ported classic modes.
protocol TurnScale: Sendable {
    func scale(dx: Int, dy: Int, dx2: Double, dy2: Double) -> Double
}

/// The classic modes' shared shape: `sdx = cx + scale · (dx2·c − dy2·s)`, `sdy = cy + scale · (dx2·s + dy2·c)`.
struct TurnZoomKernel<Rule: TurnScale>: WarpKernel {
    let cx: Double
    let cy: Double
    let c: Double
    let s: Double
    let rule: Rule

    func fill(rows: Range<Int>, into out: UnsafeMutableBufferPointer<Float>) {
        let size = WarpMapBuilder.size
        WarpMapBuilder.axis.withUnsafeBufferPointer { axis in
            var o = 0
            for dy in rows {
                let fdy = axis[dy]
                for dx in 0..<size {
                    let fdx = axis[dx]
                    let dx2 = fdx - cx
                    let dy2 = fdy - cy
                    let scale = rule.scale(dx: dx, dy: dy, dx2: dx2, dy2: dy2)
                    let sdx = cx + scale * (dx2 * c - dy2 * s)
                    let sdy = cy + scale * (dx2 * s + dy2 * c)
                    out[o] = Float(sdx - fdx)
                    out[o + 1] = Float(sdy - fdy)
                    o += 2
                }
            }
        }
    }
}

/// Mode 11: Geiss mode 8, the beautiful rippled outward zoom. Original: 0.85 + 0.1·sin(√r·f1). The
/// radius conversion stays inside the sine, so the ring spacing is kept. (Its `damping` is 1.0.)
struct GloriousRipplesScale: TurnScale {
    let f1: Double
    func scale(dx: Int, dy: Int, dx2: Double, dy2: Double) -> Double {
        let r = (dx2 * dx2 + dy2 * dy2).squareRoot() * 320
        return 0.98 + 0.017 * sin(r.squareRoot() * f1)
    }
}

/// Mode 13: Geiss mode 4, a sphere-like zoom. Original: 0.9 + pixelRadius·0.0025·0.14.
struct SphereZoomScale: TurnScale {
    func scale(dx: Int, dy: Int, dx2: Double, dy2: Double) -> Double {
        let r = (dx2 * dx2 + dy2 * dy2).squareRoot()
        return 0.975 + r * 0.028
    }
}

/// Mode 14: Geiss mode 16, a quadratic radial zoom. Its lower limit of −1.5 becomes 0.375.
struct QuadraticZoomScale: TurnScale {
    func scale(dx: Int, dy: Int, dx2: Double, dy2: Double) -> Double {
        let r2 = dx2 * dx2 + dy2 * dy2
        // 320² · 0.00025 · 0.09 / 4 = 0.576.
        return jsMax(0.375, 1.0125 - r2 * 0.576)
    }
}

/// Mode 18: Geiss mode 7, f(rad) zoom and rotation plus noise. The noise walks through the bank one
/// entry per pixel, wrapping at 253, so pixel p reads entry (start + p) mod 253.
struct NoisyZoomScale: TurnScale {
    let f1: Double
    let f2: Double
    let bank: [Float]
    let start: Int
    func scale(dx: Int, dy: Int, dx2: Double, dy2: Double) -> Double {
        let r = (dx2 * dx2 + dy2 * dy2).squareRoot() * f2
        let index = (start + dy * WarpMapBuilder.size + dx) % (WarpMapBuilder.randomBankCount - 3)
        return f1 - r + bank.js(index) * 0.01
    }
}

/// Mode 19: Geiss mode 25, a smooth perspective zoom. Original: 3 / (3 + rad).
struct ReciprocalZoomScale: TurnScale {
    func scale(dx: Int, dy: Int, dx2: Double, dy2: Double) -> Double {
        let r = (dx2 * dx2 + dy2 * dy2).squareRoot()
        return 1 - 0.25 * r / (3 + r)
    }
}

/// Mode 21: Geiss mode 5, a perspective zoom (its "√ radius" variant).
struct PerspectiveZoomScale: TurnScale {
    let f1: Double
    let f2: Double
    func scale(dx: Int, dy: Int, dx2: Double, dy2: Double) -> Double {
        // Original radius normalization: pixelRadius / 200.
        let r = (dx2 * dx2 + dy2 * dy2).squareRoot() * 1.6
        let perspective = r.squareRoot()
        return f2 - f1 * perspective
    }
}

/// Mode 23: Geiss mode 21, blocky zoom speeds stepped on |x| and |y|.
struct SquareChunkScale: TurnScale {
    func scale(dx: Int, dy: Int, dx2: Double, dy2: Double) -> Double {
        let stepsX = (abs(dx2) * 10).rounded(.down)
        let stepsY = (abs(dy2) * 10).rounded(.down)
        return 0.9875 - (stepsX + stepsY) * 0.0075
    }
}

/// Mode 24: Geiss mode 22, concentric rings zooming faster outward, in steps.
struct RingScale: TurnScale {
    func scale(dx: Int, dy: Int, dx2: Double, dy2: Double) -> Double {
        let r = (dx2 * dx2 + dy2 * dy2).squareRoot()
        let ring = (r * 10).rounded(.down)
        return 0.9875 - ring * 0.01
    }
}

/// Mode 25: Geiss mode 23, concentric rings cycling through four zoom speeds.
struct CyclingRingScale: TurnScale {
    func scale(dx: Int, dy: Int, dx2: Double, dy2: Double) -> Double {
        let r = (dx2 * dx2 + dy2 * dy2).squareRoot()
        let ring = (r * 20).rounded(.down).truncatingRemainder(dividingBy: 4)
        return 0.9875 - ring * 0.03
    }
}

/// Mode 27: Geiss mode 13, a black-hole zoom: inward near the centre, outward farther out.
struct BlackHoleZoomScale: TurnScale {
    let f1: Double
    func scale(dx: Int, dy: Int, dx2: Double, dy2: Double) -> Double {
        let r = (dx2 * dx2 + dy2 * dy2).squareRoot() * 320
        // Original: 1 + (0.04 − r·√r·0.00025·0.14)·f1.
        return 1 + (0.01 - r * r.squareRoot() * 0.00000875) * f1
    }
}

/// Mode 28: Geiss mode 14, horizontal bands of inward and outward zoom. Keeps the original's tiny
/// per-pixel random wobble, walking the bank like mode 18.
struct BandedZoomScale: TurnScale {
    let bank: [Float]
    let start: Int
    func scale(dx: Int, dy: Int, dx2: Double, dy2: Double) -> Double {
        let index = (start + dy * WarpMapBuilder.size + dx) % (WarpMapBuilder.randomBankCount - 3)
        let jitter = bank.js(index)
        let phase = dy2 * 6 / (1 + jitter / 480)
        return 0.975 + 0.05 * cos(phase)
    }
}

/// Mode 29: Geiss mode 15, angular zoom making 2–6 petals.
struct PetalScale: TurnScale {
    let petals: Double
    let f2: Double
    let f3: Double
    func scale(dx: Int, dy: Int, dx2: Double, dy2: Double) -> Double {
        let angle = atan2(dy2, dx2)
        return f2 + f3 * sin(angle * petals)
    }
}

/// Mode 31: Geiss mode 17, a horizontal tunnel. Original: 0.97 − y²·0.40.
struct HorizontalTunnelScale: TurnScale {
    func scale(dx: Int, dy: Int, dx2: Double, dy2: Double) -> Double {
        0.9925 - dy2 * dy2 * 0.10
    }
}

/// Mode 32: Geiss mode 18, a vertical tunnel. Original: 0.97 − x²·0.40.
struct VerticalTunnelScale: TurnScale {
    func scale(dx: Int, dy: Int, dx2: Double, dy2: Double) -> Double {
        0.9925 - dx2 * dx2 * 0.10
    }
}

/// Mode 33: Geiss mode 19, a vortex zoom. Original: 1.04 − rad·0.25.
struct VortexZoomScale: TurnScale {
    func scale(dx: Int, dy: Int, dx2: Double, dy2: Double) -> Double {
        let r = (dx2 * dx2 + dy2 * dy2).squareRoot()
        return 1.01 - r * 0.0625
    }
}

/// Mode 34: Geiss mode 20, a curved y-dependent perspective zoom. Original: 1.15 − √(y + 1.4)·0.20.
struct CurvedPerspectiveScale: TurnScale {
    func scale(dx: Int, dy: Int, dx2: Double, dy2: Double) -> Double {
        1.0375 - (dy2 + 1.4).squareRoot() * 0.05
    }
}

/// Mode 35: Geiss mode 9, a checkerboard of radial zoom and uniform zoom.
struct CheckerZoomScale: TurnScale {
    let f1: Double
    let f2: Double
    let scale2: Double
    func scale(dx: Int, dy: Int, dx2: Double, dy2: Double) -> Double {
        let r = (dx2 * dx2 + dy2 * dy2).squareRoot() * f2
        return ((dx & 1) == (dy & 1)) ? f1 - r : scale2
    }
}

/// Mode 38: Geiss mode 3, a y-dependent zoom. Original: 0.95 − y·0.0005, y converted by 240, motion
/// reduced 4×.
struct YDependentScale: TurnScale {
    func scale(dx: Int, dy: Int, dx2: Double, dy2: Double) -> Double {
        0.9875 - dy2 * 0.03
    }
}

/// Mode 26: Geiss mode 11, a checkerboard of opposing rotations and slightly different zooms.
struct CheckerRotationKernel: WarpKernel {
    let cx: Double
    let cy: Double
    let scale1: Double
    let scale2: Double
    let c1: Double
    let s1: Double
    let c2: Double
    let s2: Double

    func fill(rows: Range<Int>, into out: UnsafeMutableBufferPointer<Float>) {
        let size = WarpMapBuilder.size
        WarpMapBuilder.axis.withUnsafeBufferPointer { axis in
            var o = 0
            for dy in rows {
                let fdy = axis[dy]
                for dx in 0..<size {
                    let fdx = axis[dx]
                    let dx2 = fdx - cx
                    let dy2 = fdy - cy
                    let first = ((dx & 1) == (dy & 1))
                    let scale = first ? scale1 : scale2
                    let c = first ? c1 : c2
                    let s = first ? s1 : s2
                    let sdx = cx + scale * (dx2 * c - dy2 * s)
                    let sdy = cy + scale * (dx2 * s + dy2 * c)
                    out[o] = Float(sdx - fdx)
                    out[o + 1] = Float(sdy - fdy)
                    o += 2
                }
            }
        }
    }
}

/// Mode 36: Geiss mode 10, a horizontal contraction that varies with y, plus a vertical contraction
/// toward the top. The old y / FXH becomes (fdy + 1) / 2.
struct HorizontalContractionKernel: WarpKernel {
    let cx: Double

    func fill(rows: Range<Int>, into out: UnsafeMutableBufferPointer<Float>) {
        let size = WarpMapBuilder.size
        WarpMapBuilder.axis.withUnsafeBufferPointer { axis in
            var o = 0
            for dy in rows {
                let fdy = axis[dy]
                for dx in 0..<size {
                    let fdx = axis[dx]
                    let dx2 = fdx - cx
                    // Original x scale: 1.03 + 0.03·(y / FXH).
                    let scaleX = 1.0075 + 0.00375 * (fdy + 1)
                    let sdx = cx + dx2 * scaleX
                    // Original y mapping: y·1.04, anchored at the top edge.
                    let sdy = -1 + (fdy + 1) * 1.01
                    out[o] = Float(sdx - fdx)
                    out[o + 1] = Float(sdy - fdy)
                    o += 2
                }
            }
        }
    }
}

/// Mode 37: Geiss mode 12, a non-linear horizontal splitter; no vertical motion and no rotation.
struct HorizontalSplitterKernel: WarpKernel {
    let cx: Double
    let sqrtConversion: Double
    let centerThreshold: Double
    let offset: Double

    func fill(rows: Range<Int>, into out: UnsafeMutableBufferPointer<Float>) {
        let size = WarpMapBuilder.size
        WarpMapBuilder.axis.withUnsafeBufferPointer { axis in
            var o = 0
            for _ in rows {
                for dx in 0..<size {
                    let fdx = axis[dx]
                    let dx2 = fdx - cx
                    let sourceX = dx2 < -centerThreshold
                        ? cx - (-dx2).squareRoot() * sqrtConversion + offset
                        : dx2 > centerThreshold
                            ? cx + dx2.squareRoot() * sqrtConversion - offset
                            : cx
                    out[o] = Float((sourceX - fdx) * 0.25)
                    out[o + 1] = 0
                    o += 2
                }
            }
        }
    }
}

extension WarpMapBuilder {
    /// The classic modes' centre: `cx = −0.1 + 0.2·r`, `cy = −0.1 + 0.2·r`, then AdjustCenter.
    static func classicCenter(_ bank: inout RandomBank, _ prefs: inout WarpPrefs) -> (cx: Double, cy: Double) {
        let cx = -0.1 + 0.2 * bank.next()
        let cy = -0.1 + 0.2 * bank.next()
        prefs.adjustCenter(cx, cy)
        return (cx, cy)
    }

    /// The classic modes' turn: `0.15 · (base + range·r) · (r < 0.5 ? 1 : −1)`.
    static func classicTurn(_ bank: inout RandomBank, base: Double, range: Double) -> Double {
        let magnitude = 0.15 * (base + range * bank.next())
        return magnitude * bank.pick(1, else: -1)
    }

    static func turnZoom<Rule: TurnScale>(_ center: (cx: Double, cy: Double), turn: Double, _ rule: Rule) -> any WarpKernel {
        TurnZoomKernel(cx: center.cx, cy: center.cy, c: cos(turn), s: sin(turn), rule: rule)
    }

    static func planGloriousRipples(_ bank: inout RandomBank, _ prefs: inout WarpPrefs) -> any WarpKernel {
        let center = classicCenter(&bank, &prefs)
        let u = bank.next()
        let f1 = 1.5 + 8 * pow(u, 6)
        let turn = 0.0075 * bank.next() * bank.pick(1, else: -1) * 0.5
        return turnZoom(center, turn: turn, GloriousRipplesScale(f1: f1))
    }

    static func planSphereZoom(_ bank: inout RandomBank, _ prefs: inout WarpPrefs) -> any WarpKernel {
        let center = classicCenter(&bank, &prefs)
        let turn = classicTurn(&bank, base: 0.007, range: 0.02)
        return turnZoom(center, turn: turn, SphereZoomScale())
    }

    static func planQuadraticZoom(_ bank: inout RandomBank, _ prefs: inout WarpPrefs) -> any WarpKernel {
        let center = classicCenter(&bank, &prefs)
        let turn = classicTurn(&bank, base: 0.007, range: 0.02)
        return turnZoom(center, turn: turn, QuadraticZoomScale())
    }

    static func planNoisyZoom(_ bank: inout RandomBank, _ prefs: inout WarpPrefs) -> any WarpKernel {
        let center = classicCenter(&bank, &prefs)
        let f1 = 0.98 + 0.02 * bank.next()
        let f2 = (0.0006 + 0.0005 * bank.next()) * 80
        let turn = classicTurn(&bank, base: 0.01, range: 0.01)
        return turnZoom(center, turn: turn, NoisyZoomScale(f1: f1, f2: f2, bank: bank.values, start: bank.index))
    }

    static func planReciprocalZoom(_ bank: inout RandomBank, _ prefs: inout WarpPrefs) -> any WarpKernel {
        let center = classicCenter(&bank, &prefs)
        let turn = classicTurn(&bank, base: 0.007, range: 0.02)
        return turnZoom(center, turn: turn, ReciprocalZoomScale())
    }

    static func planPerspectiveZoom(_ bank: inout RandomBank, _ prefs: inout WarpPrefs) -> any WarpKernel {
        let center = classicCenter(&bank, &prefs)
        // Both parts of the zoom reduced 4×.
        let a = 0.05 + 0.05 * bank.next()
        let f1 = (a + 0.07 * bank.next()) * 0.25
        let b = 0.9975 - 0.0025 * bank.next()
        let f2 = b - 0.005 * bank.next()
        let turn = classicTurn(&bank, base: 0.01, range: 0.03)
        return turnZoom(center, turn: turn, PerspectiveZoomScale(f1: f1, f2: f2))
    }

    static func planSquareChunkZoom(_ bank: inout RandomBank, _ prefs: inout WarpPrefs) -> any WarpKernel {
        let center = classicCenter(&bank, &prefs)
        let turn = classicTurn(&bank, base: 0.007, range: 0.02)
        return turnZoom(center, turn: turn, SquareChunkScale())
    }

    static func planRingZoom(_ bank: inout RandomBank, _ prefs: inout WarpPrefs) -> any WarpKernel {
        let center = classicCenter(&bank, &prefs)
        let turn = classicTurn(&bank, base: 0.007, range: 0.02)
        return turnZoom(center, turn: turn, RingScale())
    }

    static func planCyclingRingZoom(_ bank: inout RandomBank, _ prefs: inout WarpPrefs) -> any WarpKernel {
        let center = classicCenter(&bank, &prefs)
        let turn = classicTurn(&bank, base: 0.007, range: 0.02)
        return turnZoom(center, turn: turn, CyclingRingScale())
    }

    static func planCheckerRotation(_ bank: inout RandomBank, _ prefs: inout WarpPrefs) -> any WarpKernel {
        let center = classicCenter(&bank, &prefs)
        // Both transforms share the random scale and turn, then apply their own multipliers.
        let baseScale = 1.008 + 0.008 * bank.next()
        let scale1 = 1 + (baseScale * 0.99 - 1) * 0.25
        let scale2 = 1 + (baseScale * 1.01 - 1) * 0.25
        let baseTurn = classicTurn(&bank, base: 0.12, range: 0.06)
        let turn1 = baseTurn * -0.6
        let turn2 = baseTurn * 0.1
        return CheckerRotationKernel(cx: center.cx, cy: center.cy, scale1: scale1, scale2: scale2,
                                     c1: cos(turn1), s1: sin(turn1), c2: cos(turn2), s2: sin(turn2))
    }

    static func planBlackHoleZoom(_ bank: inout RandomBank, _ prefs: inout WarpPrefs) -> any WarpKernel {
        let center = classicCenter(&bank, &prefs)
        let f1 = 0.92 + 0.16 * bank.next()
        let turn = classicTurn(&bank, base: 0.007, range: 0.02)
        return turnZoom(center, turn: turn, BlackHoleZoomScale(f1: f1))
    }

    static func planBandedZoom(_ bank: inout RandomBank, _ prefs: inout WarpPrefs) -> any WarpKernel {
        let center = classicCenter(&bank, &prefs)
        let turn = classicTurn(&bank, base: 0.007, range: 0.02)
        return turnZoom(center, turn: turn, BandedZoomScale(bank: bank.values, start: bank.index))
    }

    static func planPetals(_ bank: inout RandomBank, _ prefs: inout WarpPrefs) -> any WarpKernel {
        let center = classicCenter(&bank, &prefs)
        let petals = 2 + (5 * bank.next()).rounded(.down)
        let f2 = 0.988 + 0.01 * bank.next()
        let f3 = (0.0125 + 0.0125 * bank.next()) * 0.25
        let a = 0.04 * bank.next()
        let turn = 0.15 * (a + 0.045 * bank.next()) * bank.pick(1, else: -1) * 0.5
        return turnZoom(center, turn: turn, PetalScale(petals: petals, f2: f2, f3: f3))
    }

    static func planHorizontalTunnel(_ bank: inout RandomBank, _ prefs: inout WarpPrefs) -> any WarpKernel {
        let center = classicCenter(&bank, &prefs)
        let turn = classicTurn(&bank, base: 0.007, range: 0.02)
        return turnZoom(center, turn: turn, HorizontalTunnelScale())
    }

    static func planVerticalTunnel(_ bank: inout RandomBank, _ prefs: inout WarpPrefs) -> any WarpKernel {
        let center = classicCenter(&bank, &prefs)
        let turn = classicTurn(&bank, base: 0.007, range: 0.02)
        return turnZoom(center, turn: turn, VerticalTunnelScale())
    }

    static func planVortexZoom(_ bank: inout RandomBank, _ prefs: inout WarpPrefs) -> any WarpKernel {
        let center = classicCenter(&bank, &prefs)
        let turn = classicTurn(&bank, base: 0.007, range: 0.02)
        return turnZoom(center, turn: turn, VortexZoomScale())
    }

    static func planCurvedPerspectiveZoom(_ bank: inout RandomBank, _ prefs: inout WarpPrefs) -> any WarpKernel {
        let center = classicCenter(&bank, &prefs)
        let turn = classicTurn(&bank, base: 0.007, range: 0.02)
        return turnZoom(center, turn: turn, CurvedPerspectiveScale())
    }

    static func planCheckerZoom(_ bank: inout RandomBank, _ prefs: inout WarpPrefs) -> any WarpKernel {
        let center = classicCenter(&bank, &prefs)
        // The other half of the pixels keeps the original's independently chosen scale.
        let scale2 = 0.95 + 0.0625 * bank.next()
        let f1 = 0.995 + 0.0025 * bank.next()
        let f2 = (0.0009 + 0.0012 * bank.next()) * 80
        let turn = classicTurn(&bank, base: 0.01, range: 0.03)
        return turnZoom(center, turn: turn, CheckerZoomScale(f1: f1, f2: f2, scale2: scale2))
    }

    static func planHorizontalContraction(_ bank: inout RandomBank, _ prefs: inout WarpPrefs) -> any WarpKernel {
        let cx = -0.1 + 0.2 * bank.next()
        let cy = 0.0
        prefs.adjustCenter(cx, cy)
        return HorizontalContractionKernel(cx: cx)
    }

    static func planHorizontalSplitter(_ bank: inout RandomBank, _ prefs: inout WarpPrefs) -> any WarpKernel {
        // Mode 12 also cut the old interpolation weights by 2%, an extra fade that belongs to the
        // feedback, not the motion map.
        let cx = -0.1 + 0.2 * bank.next()
        let cy = 0.0
        prefs.adjustCenter(cx, cy)
        prefs.flatAngleLo = 3.1415927 * 0.5 - 0.1
        prefs.flatAngleHi = 3.1415927 * 0.5 + 0.1
        prefs.flatIsStereoChance = 0.0
        return HorizontalSplitterKernel(cx: cx, sqrtConversion: 1 / Double(320).squareRoot(),
                                        centerThreshold: 0.5 / 320, offset: 0.9 / 320)
    }

    static func planYDependentZoom(_ bank: inout RandomBank, _ prefs: inout WarpPrefs) -> any WarpKernel {
        let center = classicCenter(&bank, &prefs)
        let turn = classicTurn(&bank, base: 0.01, range: 0.015)
        return turnZoom(center, turn: turn, YDependentScale())
    }
}
