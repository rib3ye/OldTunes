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
//  Changed for oldTunes, 2026: the warp-slot scheduling of engine.js (Geiss HDR v335), ported to
//  Swift: ActiveWarpMap2, GetWarpAtTime, GetWarpsAtTime, PickRandomWarpMap,
//  RandomizeNextWarpMapDurations and GetNextWarpMapGen.

/// `ActiveWarpMap2`: one map's turn in a slot. Its strength rises from 0 at t0 to its peak at t1,
/// holds until t2 and falls back to 0 at t3.
struct ActiveWarpMap: Sendable {
    let mode: Int
    let t0: Double
    let t1: Double
    let t2: Double
    let t3: Double
    let peakStrength: Double
    let map: WarpMap
}

/// What GetWarpAtTime returns: which map a slot plays at a time, and how strongly.
struct WarpAtTime: Sendable {
    var mode = -1
    /// [0 … 1], times the map's peak strength.
    var rawStrength = 0.0
    var peakStrength = 0.0
    var t0 = -1.0
    var t1 = -1.0
    var t2 = -1.0
    var t3 = -1.0
    var map: WarpMap?
    /// `bal_str`: the raw strength after motion-hogging maps take their share.
    var balancedStrength = 0.0
}

/// GetNextWarpMapGen's answer: the slot that runs out first, and the map to put there.
struct NextWarpGeneration: Sendable {
    /// −1 when every slot is still busy at the look-ahead time.
    let earliestDeadSlot: Int
    let earliestDeadTime: Double
    let mode: Int
    let t0: Double
    let t1: Double
    let t2: Double
    let t3: Double
}

/// `g_active_warp_maps`: four slots, each a history of maps that overlap only where one fades out
/// and the next fades in.
struct WarpSlots: Sendable {
    static let generalTransitionSpeed = 1.0
    static let durationMin = generalTransitionSpeed * 14.0
    static let durationMax = generalTransitionSpeed * 26.0
    static let fadeMin = generalTransitionSpeed * 3.0
    static let fadeMax = generalTransitionSpeed * 10.0

    var history: [[ActiveWarpMap]] = Array(repeating: [], count: VisualizerConstants.maxActiveWarps)

    /// Drawn ahead of time, only as needed, so GetNextWarpMapGen stays deterministic.
    var nextFadeInTime = 0.0
    var nextDuration = 0.0
    var nextFadeOutTime = 0.0

    /// `smootherstep(u)`: u³·(6u² − 15u + 10).
    static func smootherstep(_ u: Double) -> Double {
        u * u * u * (6 * u * u - 15 * u + 10)
    }

    /// `GetWarpAtTime(i, t)`: the map slot `i` plays at time `t`, and its strength. This is only the
    /// relative strength; the engine then scales it for the frame rate and the "breathing".
    func warp(slot i: Int, at t: Double) -> WarpAtTime {
        guard i >= 0, i < history.count else { return WarpAtTime() }
        let hist = history[i]
        let n = hist.count
        if n == 0 || t < hist[0].t0 || t > hist[n - 1].t3 {
            return WarpAtTime()
        }
        guard let entry = hist.last(where: { t >= $0.t0 && t <= $0.t3 }) else {
            // A gap between two maps; the original never makes one (it would throw here).
            return WarpAtTime()
        }
        var str: Double
        if t <= entry.t1 {
            // Fading in.
            str = jsMax(0.0, jsMin(1.0, (t - entry.t0) / (entry.t1 - entry.t0)))
        } else {
            // Fading out.
            str = 1.0 - jsMax(0.0, jsMin(1.0, (t - entry.t2) / (entry.t3 - entry.t2)))
        }
        str = Self.smootherstep(str)
        return WarpAtTime(mode: entry.mode, rawStrength: str * entry.peakStrength, peakStrength: entry.peakStrength,
                          t0: entry.t0, t1: entry.t1, t2: entry.t2, t3: entry.t3, map: entry.map)
    }

    /// `GetWarpsAtTime(t)`: all four slots, with their strengths balanced for maps that hog the motion.
    func warps(at t: Double) -> [WarpAtTime] {
        var ret = (0..<VisualizerConstants.maxActiveWarps).map { warp(slot: $0, at: t) }
        func hogWeight(_ w: WarpAtTime) -> Double {
            w.map.map { $0.prefs.hogMotionWeight * w.rawStrength } ?? 0.0
        }
        var hogWeightSum = 0.0
        for w in ret {
            hogWeightSum += hogWeight(w)
        }
        for i in ret.indices {
            let t = hogWeight(ret[i]) * Double(VisualizerConstants.maxActiveWarps) / hogWeightSum
            ret[i].balancedStrength = ret[i].rawStrength * t
        }
        return ret
    }

    /// `PickRandomWarpMap(avoid_modes)`: a mode from the catalog by weight, skipping `avoiding`.
    static func pickRandomMode(avoiding: [Int], random: inout RandomSource) -> Int {
        let catalog = WarpMapBuilder.catalog
        // A Float32Array in the original; the sum is not.
        var adjusted = [Float](repeating: 0, count: catalog.count)
        var weightSum = 0.0
        for (i, entry) in catalog.enumerated() {
            var weight = entry.weight
            if avoiding.contains(entry.mode) {
                weight = 0
            }
            adjusted[i] = Float(weight)
            weightSum += weight
        }
        let target = random.next() * weightSum
        var sum = 0.0
        for (i, entry) in catalog.enumerated() {
            sum += Double(adjusted[i])
            if sum >= target {
                return entry.mode
            }
        }
        return catalog[catalog.count - 1].mode
    }

    /// `RandomizeNextWarpMapDurations()`.
    mutating func randomizeNextDurations(random: inout RandomSource) {
        nextFadeInTime = Self.fadeMin + (Self.fadeMax - Self.fadeMin) * random.next()
        nextDuration = Self.durationMin + (Self.durationMax - Self.durationMin) * random.next()
        nextFadeOutTime = Self.fadeMin + (Self.fadeMax - Self.fadeMin) * random.next()
    }

    /// `GetNextWarpMapGen(t, lookahead)`: which slot is empty or dead first at `t + lookahead`, and a
    /// new mode for it that none of the living slots is playing. Always takes one random number.
    func nextGeneration(time t: Double, lookahead: Double, random: inout RandomSource) -> NextWarpGeneration {
        let future = warps(at: t + lookahead)
        var earliestDeadSlot = -1
        var earliestDeadTime = 0.0
        var avoid: [Int] = []
        for i in 0..<VisualizerConstants.maxActiveWarps {
            if future[i].mode != -1 {
                // Alive at the look-ahead time.
                avoid.append(future[i].mode)
            } else if let last = history[i].last {
                // Dead at the look-ahead time: which dies first?
                if earliestDeadSlot == -1 || last.t3 < earliestDeadTime {
                    earliestDeadSlot = i
                    earliestDeadTime = last.t3
                }
            } else {
                // An empty slot needs filling now.
                if earliestDeadSlot == -1 || t < earliestDeadTime {
                    earliestDeadSlot = i
                    earliestDeadTime = t - nextFadeInTime
                }
            }
        }
        let mode = Self.pickRandomMode(avoiding: avoid, random: &random)
        let t0 = (earliestDeadSlot >= 0) ? earliestDeadTime : (t - nextFadeInTime)
        let t1 = t0 + nextFadeInTime
        let t2 = t1 + nextDuration
        let t3 = t2 + nextFadeOutTime
        return NextWarpGeneration(earliestDeadSlot: earliestDeadSlot, earliestDeadTime: earliestDeadTime, mode: mode,
                                  t0: t0, t1: t1, t2: t2, t3: t3)
    }

    /// The end of render(): forget maps that have finished, to free memory.
    mutating func prune(motionTime: Double) {
        for i in history.indices {
            history[i].removeAll { !(motionTime <= $0.t3) }
        }
    }
}
