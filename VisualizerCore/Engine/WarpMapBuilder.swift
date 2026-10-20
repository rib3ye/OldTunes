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
//  Changed for OldTunes, 2026: motion.js (Geiss HDR v335), ported to Swift. buildWarpMap's per-mode
//  loops are split into WarpModes+Zoom.swift, WarpModes+Swirl.swift and WarpModes+Other.swift, and
//  fill the map in row bands that can run in parallel.

import Foundation
import os

/// warp_prefs: what a warp map asks of the waveform and the dots drawn over it, plus metadata measured
/// from its motion. When several maps are active the engine blends these by the maps' strengths.
public struct WarpPrefs: Sendable {
    /// How much this map cares about choosing the wave. ≥ 0; higher wins more of the blend.
    public var wavePrefsWeight = 1.0
    /// How much this map dominates the others' motion. Above 1 it increasingly suppresses them,
    /// because it doesn't play well with others.
    public var hogMotionWeight = 1.0

    public var flatAngleLo = -3.141592
    public var flatAngleHi = 3.141592
    /// Since most people watch in widescreen. 0+.
    public var flatAngleBiasTowardHorizontalAngles = 1.7
    public var flatScale = 1.0
    public var flatIsStereoChance = 0.18
    public var flatStereoSepLo = 0.43
    public var flatStereoSepHi = 0.65
    public var flatStereoAmplitudeScale = 1.0
    public var flatCxLo = -0.12
    public var flatCxHi = 0.12
    public var flatCyLo = -0.12
    public var flatCyHi = 0.12

    public var circRadLo = 0.75
    public var circRadHi = 1.3
    public var circScale = 1.0
    public var circCxLo = -0.05
    public var circCxHi = 0.05
    public var circCyLo = -0.05
    public var circCyHi = 0.05

    public var motionCx = 0.0
    public var motionCy = 0.0

    /// Never read by the engine (v335); kept so the blend matches the original field for field.
    public var useMotionCenterAsWaveCenterProb = 0.93
    public var useMotionCenterAsWaveCenterPower = 0.4

    /// The actual probability seems lower because it's switched off at low net zoom.
    public var radialBeatDotsProb = 0.54
    public var randomBeatDotsProb = 0.01
    public var fadingDotsProb = 0.08
    public var gridDotsProb = 0.005
    /// The chance of any chasers (one or two).
    public var chaserProb = 0.45
    public var dottyChaserProb = 0.05

    /// Metadata measured from the finished map.
    public var netMotion = 0.0
    public var netZoomMotion = 0.0
    public var inOrOutMotion = 0.0
    public var netClockwiseMotion = 0.0
    public var cwOrCcwMotion = 0.0

    /// Declared by the original and never set or read; blended like the rest.
    public var angularMotionMag = 0.0
    public var radialMotionMag = 0.0
    public var absRadialMotionMag = 0.0
    public var absAngularMotionMag = 0.0

    public init() {}

    /// Every numeric field, in the original's declaration order: what `blendStructs` averages.
    /// (Modes 0 and 1 also set `type_flat_plus_circ`, a field the original never declared or reads.)
    static var blendedFields: [WritableKeyPath<WarpPrefs, Double>] { [
        \.wavePrefsWeight, \.hogMotionWeight,
        \.flatAngleLo, \.flatAngleHi, \.flatAngleBiasTowardHorizontalAngles, \.flatScale, \.flatIsStereoChance,
        \.flatStereoSepLo, \.flatStereoSepHi, \.flatStereoAmplitudeScale,
        \.flatCxLo, \.flatCxHi, \.flatCyLo, \.flatCyHi,
        \.circRadLo, \.circRadHi, \.circScale, \.circCxLo, \.circCxHi, \.circCyLo, \.circCyHi,
        \.motionCx, \.motionCy,
        \.useMotionCenterAsWaveCenterProb, \.useMotionCenterAsWaveCenterPower,
        \.radialBeatDotsProb, \.randomBeatDotsProb, \.fadingDotsProb, \.gridDotsProb, \.chaserProb, \.dottyChaserProb,
        \.netMotion, \.netZoomMotion, \.inOrOutMotion, \.netClockwiseMotion, \.cwOrCcwMotion,
        \.angularMotionMag, \.radialMotionMag, \.absRadialMotionMag, \.absAngularMotionMag,
    ] }

    /// `AdjustCenter(cx, cy, warp_prefs)`: moves the wave centres with the motion centre.
    mutating func adjustCenter(_ cx: Double, _ cy: Double) {
        flatCxLo += cx
        flatCxHi += cx
        flatCyLo += cy
        flatCyHi += cy
        circCxLo += cx
        circCxHi += cx
        circCyLo += cy
        circCyHi += cy
        motionCx = cx
        motionCy = cy
    }
}

/// buildWarpMap's result: the mode, its prefs and its motion field.
public struct WarpMap: Sendable {
    public let mode: Int
    public let prefs: WarpPrefs
    public let field: WarpField

    public init(mode: Int, prefs: WarpPrefs, field: WarpField) {
        self.mode = mode
        self.prefs = prefs
        self.field = field
    }
}

/// Every random number one buildWarpMap call takes, in order: the 256-entry bank (stored in a
/// Float32Array, so rounded to Float), then the 1,024 `Math.random()` calls of the motion metadata.
/// The count never depends on the mode, so a caller can draw them up front, keep the order of its own
/// random calls, and build the map somewhere else.
public struct WarpMapRandoms: Sendable {
    public var bank: [Float]
    public var metadata: [Double]

    public init(bank: [Float], metadata: [Double]) {
        self.bank = bank
        self.metadata = metadata
    }

    public init(drawingFrom random: inout RandomSource) {
        bank = (0..<WarpMapBuilder.randomBankCount).map { _ in Float(random.next()) }
        metadata = (0..<WarpMapBuilder.metadataRandomCount).map { _ in random.next() }
    }
}

/// motion.js: builds the 512×512 warp maps.
public enum WarpMapBuilder {
    /// Must be a power of 2. All of a map's randomness comes from this bank (except the metadata
    /// samples), so the same mode and bank rebuild the same map.
    static let randomBankCount = 256
    static let randomBankMask = randomBankCount - 1
    /// The metadata step samples 256 pixels, two random numbers per coordinate.
    static let metadataSampleCount = 256
    static let metadataRandomCount = metadataSampleCount * 4

    static let size = VisualizerConstants.warpMapSize
    /// The warp map's own coordinate frame: square, so x0x1 = y0y1 = 2.
    static let frame = TransformHelper(width: Double(size), height: Double(size))
    /// `(d · (2.0 / W) − 1.0) · (x0x1 · 0.5)` for every column (the map is square, so rows match).
    static let axis: [Double] = (0..<size).map { d in
        (Double(d) * (2.0 / Double(size)) - 1.0) * (frame.x0x1 * 0.5)
    }

    public struct CatalogEntry: Sendable {
        public let mode: Int
        /// The relative chance of being picked.
        public let weight: Double
    }

    /// `g_warp_maps`: the modes the engine picks from, with their weights.
    public static let catalog: [CatalogEntry] = [
        CatalogEntry(mode: 0, weight: 0.35),   // flat zoom (boring)
        CatalogEntry(mode: 1, weight: 1.95),   // power zoom
        CatalogEntry(mode: 2, weight: 0.53),   // ~zooming over terrain
        // Swirlies:
        CatalogEntry(mode: 3, weight: 1.30),   // low-frequency sine waves
        CatalogEntry(mode: 4, weight: 0.70),   // N randomly placed swirls; can overlap
        CatalogEntry(mode: 5, weight: 0.50),   // swirlie grid 2
        CatalogEntry(mode: 6, weight: 0.50),   // swirlie grid
        CatalogEntry(mode: 7, weight: 1.10),   // N randomly placed swirls, progressively smaller; can overlap
        // Radial/angular ripples:
        CatalogEntry(mode: 8, weight: 1.50),   // angular ripples (sonic)
        CatalogEntry(mode: 9, weight: 0.95),   // radial ripples (pond splash)
        CatalogEntry(mode: 10, weight: 0.15),  // starfish
        CatalogEntry(mode: 11, weight: 1.40),  // glorious ripples
        // Eggs & spheres:
        CatalogEntry(mode: 12, weight: 0.02),  // sphere (was: egg)
        CatalogEntry(mode: 13, weight: 0.20),  // sphere 1
        CatalogEntry(mode: 14, weight: 0.90),  // sphere 2 - the classic look
        CatalogEntry(mode: 15, weight: 0.05),  // black hole (−)
        CatalogEntry(mode: 16, weight: 2.00),  // heavy rotate
        CatalogEntry(mode: 17, weight: 2.25),  // 1/Z zoom
        CatalogEntry(mode: 18, weight: 0.75),  // motion-blur-esque zoom (via noisy 'scale') and rotate
        CatalogEntry(mode: 19, weight: 0.20),  // radial zoom w/ strong accel
        CatalogEntry(mode: 20, weight: 0.06),  // rounded square rotation
        CatalogEntry(mode: 21, weight: 0.40),  // faster zoom, with medium accel as f(rad)
        CatalogEntry(mode: 22, weight: 0.10),  // fissure; it hogs the motion when active, so less common
        CatalogEntry(mode: 23, weight: 0.35),  // glitchy: super speedy chunky zoom (square chunks)
        CatalogEntry(mode: 24, weight: 0.10),  // glitchy: super speedy chunky zoom (radial chunks)
        CatalogEntry(mode: 25, weight: 0.05),  // glitchy: chunky ripple zoom
        CatalogEntry(mode: 26, weight: 0.15),  // feathered inward rotation
        CatalogEntry(mode: 27, weight: 0.30),  // split zoom (in/out), mild rotation
        CatalogEntry(mode: 28, weight: 0.15),  // split zoom (in/out), mild rotation, sucked in at sides
        CatalogEntry(mode: 29, weight: 0.15),  // flower petals / starfish
        CatalogEntry(mode: 30, weight: 0.30),  // rotation, increasing at the edges (vortex)
        CatalogEntry(mode: 31, weight: 0.15),  // horizontal U zoom
        CatalogEntry(mode: 32, weight: 0.15),  // vertical U zoom
        CatalogEntry(mode: 33, weight: 0.25),  // split zoom (in/out)
    ]

    /// buildWarpMap(mode), with the random numbers drawn from `random` in the original's order.
    public static func build(mode: Int, random: inout RandomSource, id: UInt64, parallel: Bool = true) -> WarpMap {
        build(mode: mode, randoms: WarpMapRandoms(drawingFrom: &random), id: id, parallel: parallel)
    }

    /// buildWarpMap(mode) from numbers drawn earlier. `parallel` fills the rows on all cores; the result
    /// is the same either way.
    public static func build(mode: Int, randoms: WarpMapRandoms, id: UInt64, parallel: Bool = true) -> WarpMap {
        var prefs = WarpPrefs()
        var bank = RandomBank(values: randoms.bank)
        let kernel = plan(mode: mode, bank: &bank, prefs: &prefs)
        // The original throws here if a mode used more than the bank holds; none can.
        let dxy = fill(kernel, parallel: parallel)
        measureMotion(dxy, randoms: randoms.metadata, into: &prefs)
        return WarpMap(mode: mode, prefs: prefs, field: WarpField(id: id, size: size, dxy: dxy))
    }

    /// Picks the mode's loop and sets up its parameters, taking random numbers from the bank in the
    /// original order. Unknown modes (and negative ones) give a map with no motion.
    static func plan(mode: Int, bank: inout RandomBank, prefs: inout WarpPrefs) -> any WarpKernel {
        switch mode {
        case 0: return planSimpleZoom(&bank, &prefs)
        case 1: return planPowerZoom(&bank, &prefs)
        case 2: return planLanding(&bank, &prefs)
        case 3: return planLowFrequencyWaves(&bank, &prefs)
        case 4: return planRandomSwirls(&bank, &prefs)
        case 5: return planSwirlGrid2(&bank, &prefs)
        case 6: return planSwirlGrid(&bank, &prefs)
        case 7: return planShrinkingSwirls(&bank, &prefs)
        case 8: return planAngularRipples(&bank, &prefs)
        case 9: return planRadialRipples(&bank, &prefs)
        case 10: return planStarfish(&bank, &prefs)
        case 11: return planGloriousRipples(&bank, &prefs)
        case 12: return planSphere(&bank, &prefs)
        case 13: return planSphereZoom(&bank, &prefs)
        case 14: return planQuadraticZoom(&bank, &prefs)
        case 15: return planBlackHole(&bank, &prefs)
        case 16: return planRotate(&bank, &prefs)
        case 17: return planInverseZoom(&bank, &prefs)
        case 18: return planNoisyZoom(&bank, &prefs)
        case 19: return planReciprocalZoom(&bank, &prefs)
        case 20: return planRoundedSquareRotation(&bank, &prefs)
        case 21: return planPerspectiveZoom(&bank, &prefs)
        case 22: return planFissure(&bank, &prefs)
        case 23: return planSquareChunkZoom(&bank, &prefs)
        case 24: return planRingZoom(&bank, &prefs)
        case 25: return planCyclingRingZoom(&bank, &prefs)
        case 26: return planCheckerRotation(&bank, &prefs)
        case 27: return planBlackHoleZoom(&bank, &prefs)
        case 28: return planBandedZoom(&bank, &prefs)
        case 29: return planPetals(&bank, &prefs)
        case 30: return planVortex(&bank, &prefs)
        case 31: return planHorizontalTunnel(&bank, &prefs)
        case 32: return planVerticalTunnel(&bank, &prefs)
        case 33: return planVortexZoom(&bank, &prefs)
        case 34: return planCurvedPerspectiveZoom(&bank, &prefs)
        case 35: return planCheckerZoom(&bank, &prefs)
        case 36: return planHorizontalContraction(&bank, &prefs)
        case 37: return planHorizontalSplitter(&bank, &prefs)
        case 38: return planYDependentZoom(&bank, &prefs)
        case 98, 99: return planNoMotion(&prefs)
        default: return StillKernel()
        }
    }

    /// Runs the kernel over every row: serially, or in 16 bands of 32 rows on all cores. Each band
    /// writes only its own rows and visits its pixels in the same order, so the result is identical.
    static func fill(_ kernel: any WarpKernel, parallel: Bool) -> [Float] {
        let rowFloats = size * 2
        guard parallel else {
            var dxy = [Float](repeating: 0, count: size * rowFloats)
            dxy.withUnsafeMutableBufferPointer { kernel.fill(rows: 0..<size, into: $0) }
            return dxy
        }
        let bandRows = 32
        let bandCount = size / bandRows
        let bands = OSAllocatedUnfairLock(initialState: [[Float]](repeating: [], count: bandCount))
        DispatchQueue.concurrentPerform(iterations: bandCount) { band in
            let rows = band * bandRows ..< (band + 1) * bandRows
            var values = [Float](repeating: 0, count: bandRows * rowFloats)
            values.withUnsafeMutableBufferPointer { kernel.fill(rows: rows, into: $0) }
            let finished = values
            bands.withLock { $0[band] = finished }
        }
        return bands.withLock { bands in
            var dxy = [Float]()
            dxy.reserveCapacity(size * rowFloats)
            for band in bands { dxy.append(contentsOf: band) }
            return dxy
        }
    }

    /// "Populate motion metadata by sampling some of the motion": 256 pixels, biased toward the centre,
    /// measuring how much the motion zooms and how much it turns.
    static func measureMotion(_ dxy: [Float], randoms: [Double], into prefs: inout WarpPrefs) {
        let w = Double(size)
        let h = Double(size)
        let diagonal = (w * w + h * h).squareRoot()
        let sampleCount = metadataSampleCount
        let scale = 100.0 / diagonal
        let cx = w / 2
        let cy = h / 2
        var netMotion = 0.0
        var netZoomMotion = 0.0
        var inOrOutMotion = 0.0
        var netClockwiseMotion = 0.0
        var cwOrCcwMotion = 0.0
        var r = 0
        func random() -> Double {
            defer { r += 1 }
            return r < randoms.count ? randoms[r] : .nan
        }
        for _ in 0..<sampleCount {
            // A random pixel on the (square) map, biased toward the centre (pyramid-shaped).
            let fx = (random() + random()) * 0.5
            let fy = (random() + random()) * 0.5
            let dx = Double(toInt32(fx * (w - 1)))
            let dy = Double(toInt32(fy * (h - 1)))
            let readOffset = (toInt32(dy) * size + toInt32(dx)) * 2
            let sx = dx + dxy.js(readOffset + 0) * (0.5 * w)
            let sy = dy + dxy.js(readOffset + 1) * (0.5 * h)

            // r: unit vector from the centre to the destination. Dot with it for radial motion.
            var rx = dx - cx
            var ry = dy - cy
            let rNormScale = 1.0 / (rx * rx + ry * ry + 0.00001).squareRoot()
            rx *= rNormScale
            ry *= rNormScale
            // t: unit tangent. Dot with it for angular motion.
            let tx = -ry
            let ty = rx
            // v: from the source point to the destination: the direction of motion here.
            let vx = (dx - sx) * scale
            let vy = (dy - sy) * scale

            let outward = rx * vx + ry * vy
            let clockwise = tx * vx + ty * vy
            netMotion += (vx * vx + vy * vy).squareRoot()
            netZoomMotion += outward
            inOrOutMotion += abs(outward)
            netClockwiseMotion += clockwise
            cwOrCcwMotion += abs(clockwise)
        }
        prefs.netMotion = netMotion / Double(sampleCount)
        prefs.netZoomMotion = netZoomMotion / Double(sampleCount)
        prefs.inOrOutMotion = inOrOutMotion / Double(sampleCount)
        prefs.netClockwiseMotion = netClockwiseMotion / Double(sampleCount)
        prefs.cwOrCcwMotion = cwOrCcwMotion / Double(sampleCount)
    }
}

/// One mode's per-pixel loop. `out` holds `rows` and nothing else: out[0] is (dx, dy) of the first
/// row's first pixel. Kernels are value types holding their parameters, so bands can run in parallel.
protocol WarpKernel: Sendable {
    func fill(rows: Range<Int>, into out: UnsafeMutableBufferPointer<Float>)
}

/// `randoms[rand_idx++]` over the map's Float32Array bank. Past the end the original reads
/// `undefined`, which arithmetic makes NaN; so does this.
struct RandomBank: Sendable {
    let values: [Float]
    var index = 0

    /// `randoms[rand_idx++]`.
    mutating func next() -> Double {
        defer { index += 1 }
        return values.js(index)
    }

    /// `randoms[rand_idx]`, without moving on.
    func peek() -> Double {
        values.js(index)
    }

    /// `randoms[i]`.
    func at(_ i: Int) -> Double {
        values.js(i)
    }

    /// `(randoms[rand_idx++] < 0.5) ? a : b`, the sign pick most modes make.
    mutating func pick(_ below: Double, else above: Double) -> Double {
        next() < 0.5 ? below : above
    }
}

/// No motion: negative modes ("a quick dummy map"), modes the original doesn't have, and 98/99.
struct StillKernel: WarpKernel {
    func fill(rows: Range<Int>, into out: UnsafeMutableBufferPointer<Float>) {
        out.update(repeating: 0)
    }
}

extension WarpMapBuilder {
    /// Modes 98 and 99: no motion, and a wave that stays put.
    static func planNoMotion(_ prefs: inout WarpPrefs) -> any WarpKernel {
        prefs.wavePrefsWeight = 100.0
        prefs.hogMotionWeight = 100.0
        prefs.flatAngleLo = 0.0
        prefs.flatAngleHi = 0.0
        prefs.flatIsStereoChance = 0.0
        prefs.flatCxLo = -0.1
        prefs.flatCxHi = 0.1
        prefs.flatCyLo = -0.2
        prefs.flatCyHi = 0.2
        prefs.useMotionCenterAsWaveCenterProb = 0.0
        return StillKernel()
    }
}
