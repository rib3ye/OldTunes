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
//  Changed for OldTunes, 2026: the swirling and rotating modes of buildWarpMap in motion.js
//  (Geiss HDR v335), ported to Swift: 3–8, 16, 20 and 30.

import Foundation

/// `smoothstep(x)`: x·x·(3 − 2x).
@inline(__always)
func smoothstep(_ x: Double) -> Double {
    x * x * (3 - 2 * x)
}

/// `lerp(a, b, t)`: a·(1 − t) + b·t.
@inline(__always)
func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
    a * (1.0 - t) + b * t
}

// MARK: - Modes 4 and 7: overlapping swirls

/// One swirl of mode 4 or 7, and the pixel box it covers.
struct Swirl: Sendable {
    let cx: Double
    let cy: Double
    let rad: Double
    let str: Double
    let dx0: Int
    let dy0: Int
    let dx1: Int
    let dy1: Int

    init(cx: Double, cy: Double, rad: Double, str: Double) {
        self.cx = cx
        self.cy = cy
        self.rad = rad
        self.str = str
        let size = Double(WarpMapBuilder.size)
        let frame = WarpMapBuilder.frame
        func edge(_ v: Double) -> Int { toInt32(jsMax(0, jsMin(size, (v * frame.invX0x1 + 0.5) * size))) }
        dx0 = edge(cx - rad)
        dy0 = toInt32(jsMax(0, jsMin(size, ((cy - rad) * frame.invY0y1 + 0.5) * size)))
        dx1 = edge(cx + rad)
        dy1 = toInt32(jsMax(0, jsMin(size, ((cy + rad) * frame.invY0y1 + 0.5) * size)))
    }
}

/// Modes 4 and 7: start from no motion and add each swirl inside its circle, in order. The sums land
/// in Float32 storage after every swirl, as in the original, so each pixel sees the swirls in the
/// same order whichever band it's in.
struct SwirlsKernel: WarpKernel {
    let swirls: [Swirl]

    func fill(rows: Range<Int>, into out: UnsafeMutableBufferPointer<Float>) {
        out.update(repeating: 0)
        let size = WarpMapBuilder.size
        WarpMapBuilder.axis.withUnsafeBufferPointer { axis in
            for swirl in swirls {
                let y0 = max(swirl.dy0, rows.lowerBound)
                let y1 = min(swirl.dy1, rows.upperBound)
                guard y0 < y1, swirl.dx0 < swirl.dx1 else { continue }
                let cx = swirl.cx
                let cy = swirl.cy
                let str = swirl.str
                let invRadSq = 1.0 / (swirl.rad * swirl.rad)
                for dy in y0..<y1 {
                    let fdy = axis[dy]
                    var o = ((dy - rows.lowerBound) * size + swirl.dx0) * 2
                    for dx in swirl.dx0..<swirl.dx1 {
                        let fdx = axis[dx]
                        let radSq = ((fdx - cx) * (fdx - cx) + (fdy - cy) * (fdy - cy)) * invRadSq
                        if radSq < 1 {
                            var r = pow(radSq, 0.333)
                            r = smoothstep(r)
                            let zx = fdx - cx
                            let zy = fdy - cy
                            let rot = (1.0 - r) * str
                            let cosRot = cos(rot)
                            let sinRot = sin(rot)
                            let zx2 = (zx * cosRot - zy * sinRot)
                            let zy2 = (zx * sinRot + zy * cosRot)
                            let sdx = cx + zx2
                            let sdy = cy + zy2
                            out[o] = Float(Double(out[o]) + (sdx - fdx))
                            out[o + 1] = Float(Double(out[o + 1]) + (sdy - fdy))
                        }
                        o += 2
                    }
                }
            }
        }
    }
}

// MARK: - Mode 3: low-frequency sine waves

/// Mode 3: the field is made at a quarter of the resolution (`temp`, 129 × 129) and upsampled here.
struct LowFrequencyWavesKernel: WarpKernel {
    let tempX: [Float]
    let tempY: [Float]
    let w2: Int
    let h2: Int

    func fill(rows: Range<Int>, into out: UnsafeMutableBufferPointer<Float>) {
        let size = WarpMapBuilder.size
        var o = 0
        for dy in rows {
            let fsy = Double(dy * (h2 - 1)) / Double(size)
            let sy = fsy.rounded(.down)
            let fy = fsy - sy
            for dx in 0..<size {
                let fsx = Double(dx * (w2 - 1)) / Double(size)
                let sx = fsx.rounded(.down)
                let fx = fsx - sx
                let isx = Int(sx)
                let isy = Int(sy)
                let o1 = (isy + 0) * w2 + (isx + 0)
                let o2 = (isy + 0) * w2 + (isx + 1)
                let o3 = (isy + 1) * w2 + (isx + 0)
                let o4 = (isy + 1) * w2 + (isx + 1)
                let w1 = (1 - fy) * (1 - fx)
                let w2 = (1 - fy) * (fx)
                let w3 = (fy) * (1 - fx)
                let w4 = (fy) * (fx)
                let vx = tempX.js(o1) * w1 + tempX.js(o2) * w2 + tempX.js(o3) * w3 + tempX.js(o4) * w4
                let vy = tempY.js(o1) * w1 + tempY.js(o2) * w2 + tempY.js(o3) * w3 + tempY.js(o4) * w4
                out[o] = Float(vx)
                out[o + 1] = Float(vy)
                o += 2
            }
        }
    }
}

// MARK: - Modes 5, 6: grids of swirls

/// Mode 5, SWIRLIE GRID 2. The grid is rotated by rot0 first, so the displacement is rotated back
/// at the end.
struct SwirlGrid2Kernel: WarpKernel {
    let n: Double
    let offsetX: Double
    let offsetY: Double
    let str: Double
    let cosRot0: Double
    let sinRot0: Double
    let cosMinusRot0: Double
    let sinMinusRot0: Double
    let variety: Bool
    let bank: [Float]

    func fill(rows: Range<Int>, into out: UnsafeMutableBufferPointer<Float>) {
        let size = WarpMapBuilder.size
        let mask = WarpMapBuilder.randomBankMask
        WarpMapBuilder.axis.withUnsafeBufferPointer { axis in
            var o = 0
            for dy in rows {
                var fdy = axis[dy]
                fdy += offsetY
                for dx in 0..<size {
                    var fdx = axis[dx]
                    fdx += offsetX

                    // ApplyRot2D(fdx, fdy, rot0)
                    let fx = fdx * cosRot0 - fdy * sinRot0
                    let fy = fdx * sinRot0 + fdy * cosRot0

                    let nx = (fx * n).rounded(.down)  // −N … N
                    let ny = (fy * n).rounded(.down)

                    let k = toInt32(nx * 3 + ny * 7)
                    let att = variety ? (bank.js(k & mask) * 2 - 1) : 1.0

                    let cx = (nx + 0.5) * (1.0 / n)  // −1 … 1
                    let cy = (ny + 0.5) * (1.0 / n)

                    let radSq = ((fx - cx) * (fx - cx) + (fy - cy) * (fy - cy)) * (n * n * 4)
                    var r = pow(radSq, 0.333)
                    var sdx = fx
                    var sdy = fy
                    if r < 1 {
                        r = smoothstep(r)
                        let zx = fx - cx
                        let zy = fy - cy
                        let rot = (1.0 - r) * str
                        let cosRot = cos(rot * att)
                        let sinRot = sin(rot * att)
                        let zx2 = (zx * cosRot - zy * sinRot)
                        let zy2 = (zx * sinRot + zy * cosRot)
                        sdx = cx + zx2
                        sdy = cy + zy2
                    }
                    sdx -= fx
                    sdy -= fy

                    // Rotate back, so the displacement is in the original basis.
                    let px = sdx * cosMinusRot0 - sdy * sinMinusRot0
                    let py = sdx * sinMinusRot0 + sdy * cosMinusRot0
                    out[o] = Float(px)
                    out[o + 1] = Float(py)
                    o += 2
                }
            }
        }
    }
}

/// Mode 6, GRID OF SWIRLIES, with graded variety between cells.
struct SwirlGridKernel: WarpKernel {
    let n: Double
    let offsetX: Double
    let offsetY: Double
    let scale: Double
    let rot: Double
    let power: Double
    let variety: Double
    let cosRot0: Double
    let sinRot0: Double
    let cosMinusRot0: Double
    let sinMinusRot0: Double
    let bank: [Float]

    func fill(rows: Range<Int>, into out: UnsafeMutableBufferPointer<Float>) {
        let size = WarpMapBuilder.size
        let mask = WarpMapBuilder.randomBankMask
        WarpMapBuilder.axis.withUnsafeBufferPointer { axis in
            var o = 0
            for dy in rows {
                let origFdy = axis[dy]
                for dx in 0..<size {
                    let origFdx = axis[dx]

                    // ApplyRot2D(orig_fdx, orig_fdy, rot0)
                    var fdx = origFdx * cosRot0 - origFdy * sinRot0
                    var fdy = origFdx * sinRot0 + origFdy * cosRot0

                    fdx += offsetX
                    fdx = (fdx * n * 0.5)
                    let nx = fdx.rounded(.down)
                    fdx -= nx  // [0 … 1]
                    fdx = fdx * 2 - 1  // [−1 … 1]

                    fdy += offsetY
                    fdy = (fdy * n * 0.5)
                    let ny = fdy.rounded(.down)
                    fdy -= ny
                    fdy = fdy * 2 - 1

                    let k = toInt32(nx * 3 + ny * 7)
                    let tx = fdx
                    let ty = fdy
                    var rad = (tx * tx + ty * ty).squareRoot()
                    rad = pow(rad, power)
                    let rot2 = rot * jsMax(0.0, 1 - rad)
                    let rot3 = rot2 * lerp(1.0, bank.js(k & mask) * 2 - 1, variety)
                    let cosRot3 = cos(rot3)
                    let sinRot3 = sin(rot3)
                    var sdx = (fdx * cosRot3 - fdy * sinRot3) * scale
                    var sdy = (fdx * sinRot3 + fdy * cosRot3) * scale
                    sdx -= fdx
                    sdy -= fdy

                    let px = sdx * cosMinusRot0 - sdy * sinMinusRot0
                    let py = sdx * sinMinusRot0 + sdy * cosMinusRot0
                    out[o] = Float(px)
                    out[o + 1] = Float(py)
                    o += 2
                }
            }
        }
    }
}

// MARK: - Modes 8, 16, 20, 30: rotations

/// Mode 8, SWIRL: angular ripples around (cx, cy).
struct AngularRipplesKernel: WarpKernel {
    let cx: Double
    let cy: Double
    let radFreq: Double
    let rotStr: Double
    let rotBias: Double

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
                    let rot = (cos(rad * radFreq) + rotBias) * rotStr
                    let cosRot = cos(rot)
                    let sinRot = sin(rot)
                    let sdx = tx * cosRot - ty * sinRot + cx
                    let sdy = tx * sinRot + ty * cosRot + cy
                    out[o] = Float(sdx - fdx)
                    out[o + 1] = Float(sdy - fdy)
                    o += 2
                }
            }
        }
    }
}

/// Mode 16, ROTATE: rot1 at the centre, rot2 at the edge.
struct RotateKernel: WarpKernel {
    let rot1: Double
    let rot2: Double

    func fill(rows: Range<Int>, into out: UnsafeMutableBufferPointer<Float>) {
        let size = WarpMapBuilder.size
        WarpMapBuilder.axis.withUnsafeBufferPointer { axis in
            var o = 0
            for dy in rows {
                let fdy = axis[dy]
                for dx in 0..<size {
                    let fdx = axis[dx]
                    let rad = (fdx * fdx + fdy * fdy).squareRoot()
                    let rot = rot1 + (rot2 - rot1) * rad
                    let cosRot = cos(rot)
                    let sinRot = sin(rot)
                    let sdx = fdx * cosRot - fdy * sinRot
                    let sdy = fdx * sinRot + fdy * cosRot
                    out[o] = Float(sdx - fdx)
                    out[o + 1] = Float(sdy - fdy)
                    o += 2
                }
            }
        }
    }
}

/// Mode 20, ROUNDED SQUARE ROTATION.
struct RoundedSquareRotationKernel: WarpKernel {
    let speed: Double

    func fill(rows: Range<Int>, into out: UnsafeMutableBufferPointer<Float>) {
        let size = WarpMapBuilder.size
        WarpMapBuilder.axis.withUnsafeBufferPointer { axis in
            var o = 0
            for dy in rows {
                let fdy = axis[dy]
                for dx in 0..<size {
                    let fdx = axis[dx]
                    let rad = (fdx * fdx + fdy * fdy).squareRoot()
                    var nx = fdy
                    var ny = -fdx
                    let nxSign = (nx < 0) ? -1.0 : 1.0
                    let nySign = (ny < 0) ? -1.0 : 1.0
                    nx *= nx * nxSign
                    ny *= ny * nySign
                    let normScale = 1.0 / (nx * nx + ny * ny + 0.00001).squareRoot()
                    nx *= normScale
                    ny *= normScale
                    let sdx = fdx + nx * speed * rad
                    let sdy = fdy + ny * speed * rad
                    out[o] = Float(sdx - fdx)
                    out[o + 1] = Float(sdy - fdy)
                    o += 2
                }
            }
        }
    }
}

/// Mode 30, VORTEX: rotation increasing toward the edges.
struct VortexKernel: WarpKernel {
    let cx: Double
    let cy: Double
    let str: Double

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
                    let rot = rad * str
                    // ApplyRot2D(tx, ty, rot)
                    let cosRot = cos(rot)
                    let sinRot = sin(rot)
                    let rotatedX = tx * cosRot - ty * sinRot
                    let rotatedY = tx * sinRot + ty * cosRot
                    let sdx = cx + rotatedX
                    let sdy = cy + rotatedY
                    out[o] = Float(sdx - fdx)
                    out[o + 1] = Float(sdy - fdy)
                    o += 2
                }
            }
        }
    }
}

extension WarpMapBuilder {
    static func planRandomSwirls(_ bank: inout RandomBank, _ prefs: inout WarpPrefs) -> any WarpKernel {
        // While active, this mode slightly suppresses the motion of the others.
        prefs.hogMotionWeight *= 1.25

        // A few big swirls that can overlap.
        let count = toInt32(2 + 34 * bank.next())
        let n = Double(count)
        var swirls: [Swirl] = []
        for _ in 0..<max(0, count) {
            let cx = (bank.next() - 0.5) * frame.x0x1
            let cy = (bank.next() - 0.5) * frame.y0y1
            let rad = 0.3 + 0.5 * bank.next() * jsMin(1.0, 10.0 / n)
            let magnitude = (0.2 + 0.5 * bank.next())
            let sign: Double = bank.next() > 0.5 ? 1 : -1
            let str = magnitude * sign * 0.1 * pow(jsMin(1.0, (3.0 / n)), 0.7)
            swirls.append(Swirl(cx: cx, cy: cy, rad: rad, str: str))
        }
        return SwirlsKernel(swirls: swirls)
    }

    static func planShrinkingSwirls(_ bank: inout RandomBank, _ prefs: inout WarpPrefs) -> any WarpKernel {
        // Like mode 4 with many more swirls, starting large and getting progressively smaller.
        prefs.hogMotionWeight *= 1.25

        let count = toInt32(2 + 240 * bank.next())
        let strBig = 0.03
        let strLil = 0.03 + 0.05 * bank.next()
        var swirls: [Swirl] = []
        for i in 0..<max(0, count) {
            let t = Double(i) / Double(count - 1)  // [0 … 1], big … little
            let cx = (bank.next() - 0.5) * frame.x0x1
            let cy = (bank.next() - 0.5) * frame.y0y1
            let rad = 0.8 - 0.75 * pow(t, 0.25)
            let magnitude = (0.2 + 0.3 * bank.next())
            let sign: Double = bank.next() > 0.5 ? 1 : -1
            let str = magnitude * sign * (strBig + (strLil - strBig) * t)
            swirls.append(Swirl(cx: cx, cy: cy, rad: rad, str: str))

            // Near the end of the bank, jump back to somewhere near its start.
            if bank.index > bank.values.count - 8 {
                bank.index = toInt32(bank.peek() * 43)
            }
        }
        return SwirlsKernel(swirls: swirls)
    }

    static func planLowFrequencyWaves(_ bank: inout RandomBank, _ prefs: inout WarpPrefs) -> any WarpKernel {
        prefs.wavePrefsWeight *= 0.1

        let n = 15
        let str = (0.4 + 0.6 * bank.next()) * 0.75

        // Float32Arrays in the original.
        var theta = [Float](repeating: 0, count: n)
        var cosTheta = [Float](repeating: 0, count: n)
        var sinTheta = [Float](repeating: 0, count: n)
        var freq = [Float](repeating: 0, count: n)
        var amp = [Float](repeating: 0, count: n)

        let baseTheta = bank.next()
        var thetaSum = 0.0
        for i in 0..<n {
            theta[i] = Float((baseTheta + Double(i) / Double(n)) * 6.28)
            cosTheta[i] = Float(cos(Double(theta[i])))
            sinTheta[i] = Float(sin(Double(theta[i])))
            amp[i] = Float(bank.next() * str * 0.002 * 0.5 * 1.3)
            freq[i] = Float(bank.next() * 12 * 2)
            thetaSum += Double(theta[i])
        }
        let cosUndo = cos(-thetaSum)
        let sinUndo = sin(-thetaSum)

        // Made at reduced resolution first, then upsampled.
        let scaleDown = 4
        let w2 = toInt32(Double(size) / Double(scaleDown) + 1)
        let h2 = toInt32(Double(size) / Double(scaleDown) + 1)
        var tempX = [Float](repeating: 0, count: w2 * h2)
        var tempY = [Float](repeating: 0, count: w2 * h2)
        for dy in 0..<h2 {
            let fdy = (Double(dy) * (2.0 / Double(h2)) - 1.0) * (frame.y0y1 * 0.5)
            for dx in 0..<w2 {
                let fdx = (Double(dx) * (2.0 / Double(w2)) - 1.0) * (frame.x0x1 * 0.5)
                var x = fdx
                var y = fdy
                for i in 0..<n {
                    let c = Double(cosTheta[i])
                    let s = Double(sinTheta[i])
                    let x2 = x * c - y * s
                    let y2 = x * s + y * c
                    x = x2
                    y = y2
                    x += cos(y * Double(freq[i])) * Double(amp[i])
                }
                let sdx = x * cosUndo - y * sinUndo
                let sdy = x * sinUndo + y * cosUndo
                tempX[dy * w2 + dx] = Float(sdx - fdx)
                tempY[dy * w2 + dx] = Float(sdy - fdy)
            }
        }
        return LowFrequencyWavesKernel(tempX: tempX, tempY: tempY, w2: w2, h2: h2)
    }

    static func planSwirlGrid2(_ bank: inout RandomBank, _ prefs: inout WarpPrefs) -> any WarpKernel {
        let n = 0.5 + bank.next() * 3.5
        let offsetX = bank.next() * (1.0 / n)
        let offsetY = bank.next() * (1.0 / n)
        let magnitude = 0.1 + 0.3 * bank.next() * bank.next()
        let sign: Double = bank.next() > 0.5 ? 1 : -1
        let str = magnitude * sign * 0.25
        let rot0 = bank.next() * 6.28
        let variety = bank.next() > 0.5
        return SwirlGrid2Kernel(n: n, offsetX: offsetX, offsetY: offsetY, str: str,
                                cosRot0: cos(rot0), sinRot0: sin(rot0), cosMinusRot0: cos(-rot0), sinMinusRot0: sin(-rot0),
                                variety: variety, bank: bank.values)
    }

    static func planSwirlGrid(_ bank: inout RandomBank, _ prefs: inout WarpPrefs) -> any WarpKernel {
        let n = (2 + bank.next() * 8)
        let offsetX = bank.next() * (1.0 / n)
        let offsetY = bank.next() * (1.0 / n)
        let scale = 1.0
        let magnitude = (0.002 + 0.028 * bank.next())
        let rot = magnitude * bank.pick(1, else: -1) * jsMin(1.0, 4.0 / n)
        let power = 0.25 + 0.25 * bank.next()
        let variety = jsMax(0.0, jsMin(1.0, bank.next() * 3 - 1))  // [0 … 1]
        let rot0 = bank.next() * 6.28
        return SwirlGridKernel(n: n, offsetX: offsetX, offsetY: offsetY, scale: scale, rot: rot, power: power,
                               variety: variety, cosRot0: cos(rot0), sinRot0: sin(rot0),
                               cosMinusRot0: cos(-rot0), sinMinusRot0: sin(-rot0), bank: bank.values)
    }

    static func planAngularRipples(_ bank: inout RandomBank, _ prefs: inout WarpPrefs) -> any WarpKernel {
        prefs.circScale = 4.0
        let cx = (bank.next() * 2 - 1) * 0.45
        let cy = (bank.next() * 2 - 1) * 0.45
        // No AdjustCenter: the ripples' centre can be far out, and since this mode doesn't zoom, the
        // wave needn't follow it. But radial beat dots should.
        prefs.motionCx = cx
        prefs.motionCy = cy

        let radFreq = 5 + 19 * bank.next()
        let a = 0.001 + 0.004 * bank.next() * bank.next()
        // Partly compensates for the frequency.
        let rotStr = a * bank.pick(-1.0, else: 1.0) * 0.21 * pow(13 / radFreq, 0.6) * 4
        let rotBias = bank.peek() * 2 - 1
        return AngularRipplesKernel(cx: cx, cy: cy, radFreq: radFreq, rotStr: rotStr, rotBias: rotBias)
    }

    static func planRotate(_ bank: inout RandomBank, _ prefs: inout WarpPrefs) -> any WarpKernel {
        prefs.wavePrefsWeight *= 0.01
        var rot1 = 0.002 + 0.008 * bank.next()  // centre
        if bank.next() < 0.5 { rot1 *= -1 }
        var rot2 = rot1  // edge
        if bank.next() < 0.3 {
            rot2 = rot1 * bank.next() * 2
            if bank.next() < 0.5 { rot2 *= -1 }
        }
        return RotateKernel(rot1: rot1, rot2: rot2)
    }

    static func planRoundedSquareRotation(_ bank: inout RandomBank, _ prefs: inout WarpPrefs) -> any WarpKernel {
        prefs.wavePrefsWeight *= 10
        let magnitude = linearInterp(0.003, 0.01, bank.next())
        let sign = bank.next() > 0.5 ? 1.0 : -1.0
        return RoundedSquareRotationKernel(speed: magnitude * sign)
    }

    static func planVortex(_ bank: inout RandomBank, _ prefs: inout WarpPrefs) -> any WarpKernel {
        let cx = (bank.next() * 2 - 1) * 0.08
        let cy = (bank.next() * 2 - 1) * 0.08
        prefs.adjustCenter(cx, cy)
        let magnitude = linearInterp(0.003, 0.010, bank.next())
        let sign: Double = bank.next() > 0.5 ? 1 : -1
        return VortexKernel(cx: cx, cy: cy, str: magnitude * sign)
    }
}
