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
//  Changed for OldTunes, 2026: engine.js (Geiss HDR v335), ported to Swift: the Engine class,
//  the wave parameters, the waveform, beat, fading, chaser and grid dots, and linearResampleF.
//  The background worker is a detached task. The song-title overlay and the CPU index buffers the
//  original no longer uses are not ported.

import Foundation

/// What `Engine.render(…)` takes besides the audio, minus the song title (not ported).
public struct EngineStep: Sendable {
    /// `time_now`: seconds of real time.
    public var timeNow: Double
    public var motionTime: Double
    public var waveTime: Double
    public var shiftTime: Double
    public var frame: Int
    public var randomizeMotion = false
    public var randomizeWave = false
    /// Steps per second, smoothed.
    public var fps: Double
    public var waveSmoothing: Int
    /// The original passes these and never reads them.
    public var userWavePointSize: Double = -1
    public var xyOscilloscopeGap: Int = 96
    /// 0 … 1 when a beat fired this step.
    public var beat: Double
    public var userMotionScale: Double
    public var frozen: Bool
    public var experiment = false
    public var darkening: Double
    public var alignFraction: Double
    public var toggleGridDots = false
    public var toggleFadingDots = false
    public var toggleChasers = false
    public var toggleDottyChaser = false
    public var toggleRandomBeatDots = false
    public var toggleRadialBeatDots = false

    public init(timeNow: Double, motionTime: Double, waveTime: Double, shiftTime: Double, frame: Int, fps: Double,
                waveSmoothing: Int, beat: Double, userMotionScale: Double, frozen: Bool, darkening: Double,
                alignFraction: Double) {
        self.timeNow = timeNow
        self.motionTime = motionTime
        self.waveTime = waveTime
        self.shiftTime = shiftTime
        self.frame = frame
        self.fps = fps
        self.waveSmoothing = waveSmoothing
        self.beat = beat
        self.userMotionScale = userMotionScale
        self.frozen = frozen
        self.darkening = darkening
        self.alignFraction = alignFraction
    }
}

/// A dot effect's switch in the wave parameters. The original stores a number until a key flips it:
/// `x = !x` leaves a boolean, which blendStructs then copies from the first struct instead of blending.
struct DotSwitch {
    var value: Double
    var isBoolean = false

    /// `!x`.
    var flipped: DotSwitch { DotSwitch(value: jsNot(value) ? 1 : 0, isBoolean: true) }
}

/// The wave parameters (`params`, g_wave0, g_wave1). A class, because the original shares these
/// objects between g_wave0 and g_wave1 and edits them in place.
final class WaveParams {
    var waveFlatStr = 0.0  // [0 … 1]
    var waveFlatAngle = 0.0  // [0 … 2π]
    var waveFlatScale = 1.0  // ~1
    var waveFlatIsStereo = 0.0  // [0 … 1]
    var waveFlatStereoSep = 0.6  // [0 … 1]
    var waveFlatStereoAmplitudeScale = 1.0  // ~1
    var waveFlatCx = 0.0  // [−1 … 1]
    var waveFlatCy = 0.0

    var waveCircStr = 0.0
    var waveCircRad = 1.0
    var waveCircScale = 1.0
    var waveCircAngle = 0.0
    var waveCircCx = 0.0
    var waveCircCy = 0.0

    var motionCx = 0.0
    var motionCy = 0.0

    /// Further reduced while the motion isn't zoomy.
    var radialBeatDots = DotSwitch(value: 0)
    var randomBeatDots = DotSwitch(value: 0)
    var fadingDots = DotSwitch(value: 0)
    var gridDots = DotSwitch(value: 0)
    var chaser1 = 0.0
    var chaser2 = 0.0
    var dottyChaser = 0.0

    static var numberFields: [ReferenceWritableKeyPath<WaveParams, Double>] { [
        \.waveFlatStr, \.waveFlatAngle, \.waveFlatScale, \.waveFlatIsStereo, \.waveFlatStereoSep,
        \.waveFlatStereoAmplitudeScale, \.waveFlatCx, \.waveFlatCy,
        \.waveCircStr, \.waveCircRad, \.waveCircScale, \.waveCircAngle, \.waveCircCx, \.waveCircCy,
        \.motionCx, \.motionCy, \.chaser1, \.chaser2, \.dottyChaser,
    ] }
    static var switchFields: [ReferenceWritableKeyPath<WaveParams, DotSwitch>] { [
        \.radialBeatDots, \.randomBeatDots, \.fadingDots, \.gridDots,
    ] }

    /// `blendStructs([a, b], [wa, wb])`: numbers are blended; a switch that is a boolean in both is
    /// copied from `a`; a number in only one of them counts only that one.
    static func blend(_ a: WaveParams, _ b: WaveParams, weights wa: Double, _ wb: Double) -> WaveParams {
        let wsum = 0 + wa + wb
        let out = WaveParams()
        for field in numberFields {
            var acc = 0.0
            acc += wa * a[keyPath: field]
            acc += wb * b[keyPath: field]
            out[keyPath: field] = acc / wsum
        }
        for field in switchFields {
            let x = a[keyPath: field]
            let y = b[keyPath: field]
            var acc = 0.0
            var sawNumber = false
            if !x.isBoolean {
                acc += wa * x.value
                sawNumber = true
            }
            if !y.isBoolean {
                acc += wb * y.value
                sawNumber = true
            }
            out[keyPath: field] = sawNumber ? DotSwitch(value: acc / wsum) : x
        }
        return out
    }
}

extension WarpPrefs {
    /// `blendStructs(prefs, weights)`: every field, weighted by `weights` (Float32 values in the original).
    static func blend(_ prefs: [WarpPrefs], weights: [Double]) -> WarpPrefs {
        let wsum = weights.reduce(0, +)
        var out = WarpPrefs()
        for field in blendedFields {
            var acc = 0.0
            for i in prefs.indices {
                acc += weights[i] * prefs[i][keyPath: field]
            }
            out[keyPath: field] = acc / wsum
        }
        return out
    }
}

/// engine.js's Engine: schedules the warp maps, chooses and blends the waves, and each step hands the
/// renderer the four warp strengths, the drift and the dots to draw.
@MainActor
public final class WarpEngine {
    // engine.js constants.
    static let waveDurationMin = WarpSlots.generalTransitionSpeed * 13.0
    static let waveDurationMax = WarpSlots.generalTransitionSpeed * 24.0
    static let waveFadeMin = WarpSlots.generalTransitionSpeed * 5.0
    static let waveFadeMax = WarpSlots.generalTransitionSpeed * 8.0
    static let newWaveMotionTimeLookahead = waveFadeMin * 0.35 + 0.65 * waveFadeMax
    static let baseMotionScale = 109.0 * 0.9
    /// Flat wave only.
    static let waveStretch = 1.5
    /// All waves: about the colour intensity of the wave's points.
    static let waveMagScale = 1.1
    /// Above this visual energy the wave's amplitude is limited, so it doesn't spray all over the screen.
    static let maxVisualEnergy = 0.009
    static let shiftMagnitude = 0.95 * 0.65
    static let shiftFrequency = 0.7
    static let waveOpacityScale = 0.75
    /// With chasers on, how often there are two instead of one.
    static let twoChasersProbability = 0.3
    static let fadingDotCount = 1024

    private let renderer: any WarpRendering
    private var slots = WarpSlots()
    private var visualEnergyAtt = 0.0
    private var wave0: WaveParams?
    private var wave1: WaveParams?
    private var wave0StartFadeTime = 0.0
    private var wave0EndFadeTime = 0.1
    public private(set) var blendedNetMotion = 0.0
    public private(set) var blendedNetZoomMotion = 0.0
    public private(set) var blendedInOrOutMotion = 0.0
    public private(set) var blendedNetClockwiseMotion = 0.0
    public private(set) var blendedCwOrCcwMotion = 0.0
    /// Extra darkening when the motion is very zoomy and the wave a single flat line. It adds to the
    /// user's darkening; the renderer's auto-exposure is a third kind.
    public private(set) var autoDarkening = 0.0
    private var aligner = WaveAligner()
    private var fadingDots: [(x: Double, y: Double)]
    private var audio = AudioFrame.silent
    private var t = 0.0

    // The background worker: one map at a time, built off the main actor.
    private struct BackgroundMap {
        let slot: Int
        let mode: Int
        let t0: Double
        let t1: Double
        let t2: Double
        let t3: Double
        let map: WarpMap
    }
    private var backgroundInProgress = false
    private var backgroundMap: BackgroundMap?
    private var workerRandom: RandomSource
    private var nextMapID: UInt64 = 1

    /// Maps built on the spot, on the main actor, because the background one wasn't ready in time.
    public private(set) var onDemandBuilds = 0
    /// Maps built by the background task.
    public private(set) var backgroundBuilds = 0

    /// What engine.js does when it loads: places the 1,024 fading dots at random and draws the next
    /// map's durations. Call `randomizeActiveWarpMaps` next, as the Engine constructor does.
    /// `workerRandom` is the background builder's own stream, as a web worker has its own Math.random.
    public init(renderer: any WarpRendering, random: inout RandomSource, workerRandom: RandomSource = .fast()) {
        self.renderer = renderer
        var dots: [(x: Double, y: Double)] = []
        dots.reserveCapacity(Self.fadingDotCount)
        for _ in 0..<Self.fadingDotCount {
            let x = Double(toInt32(random.next() * 1024))
            let y = Double(toInt32(random.next() * 1024))
            dots.append((x, y))
        }
        fadingDots = dots
        self.workerRandom = workerRandom
        slots.randomizeNextDurations(random: &random)
    }

    /// The modes the slots are playing now, for tests and the debug overlay.
    public func activeModes(at motionTime: Double) -> [Int] {
        slots.warps(at: motionTime).map(\.mode)
    }

    private func takeMapID() -> UInt64 {
        defer { nextMapID += 1 }
        return nextMapID
    }

    /// `new ActiveWarpMap2(mode, t0, t1, t2, t3, peak_str)` with no map given: builds it here, now.
    private func buildNow(mode: Int, random: inout RandomSource) -> WarpMap {
        WarpMapBuilder.build(mode: mode, random: &random, id: takeMapID(), parallel: true)
    }

    /// `RandomizeActiveWarpMaps(motion_time)`: a hard cut to four new maps, built on the spot, with
    /// their schedules shifted back at random so they don't all fade out together.
    public func randomizeActiveWarpMaps(motionTime: Double, random: inout RandomSource) {
        var avoid: [Int] = []
        for i in 0..<VisualizerConstants.maxActiveWarps {
            let mode = WarpSlots.pickRandomMode(avoiding: avoid, random: &random)
            slots.history[i] = []
            let duration = WarpSlots.durationMin + (WarpSlots.durationMax - WarpSlots.durationMin) * random.next()
            let fadeTime = WarpSlots.fadeMin + (WarpSlots.fadeMax - WarpSlots.fadeMin) * random.next()
            let alreadyElapsed = duration * random.next() * 0.6
            let t0 = motionTime - alreadyElapsed - fadeTime
            let t1 = motionTime - alreadyElapsed
            let t2 = motionTime - alreadyElapsed + duration
            let t3 = motionTime - alreadyElapsed + duration + fadeTime
            let map = buildNow(mode: mode, random: &random)
            slots.history[i].append(ActiveWarpMap(mode: mode, t0: t0, t1: t1, t2: t2, t3: t3, peakStrength: 1.0, map: map))
            avoid.append(mode)
        }
    }

    /// `SetMotionModeDebug(mode, motion_time)`: every slot plays `mode`, all but the first at almost no
    /// strength. The debug keys' two-digit mode.
    public func setMotionModeDebug(_ mode: Int, motionTime: Double, random: inout RandomSource) {
        for i in 0..<VisualizerConstants.maxActiveWarps {
            let duration = WarpSlots.durationMin + (WarpSlots.durationMax - WarpSlots.durationMin) * random.next()
            let fadeTime = WarpSlots.fadeMin + (WarpSlots.fadeMax - WarpSlots.fadeMin) * random.next()
            let t0 = motionTime - fadeTime
            let t1 = motionTime
            let t2 = motionTime + duration
            let t3 = motionTime + duration + fadeTime
            let peak = (i == 0) ? 1.0 : 0.0000001
            let map = buildNow(mode: mode, random: &random)
            slots.history[i] = [ActiveWarpMap(mode: mode, t0: t0, t1: t1, t2: t2, t3: t3, peakStrength: peak, map: map)]
            backgroundMap = nil
        }
    }

    /// `GetMotionDebugInfo(motion_time)`: the slots and the blended motion, for the debug overlay.
    public func motionDebugLines(motionTime: Double) -> [String] {
        func f2(_ x: Double) -> String { String(format: "%.2f", x) }
        var text: [String] = []
        for (i, w) in slots.warps(at: motionTime).enumerated() {
            let mode = String(w.mode)
            let padded = String(repeating: " ", count: max(0, 2 - mode.count)) + mode
            text.append("warp \(i):  mode \(padded)  raw_str \(f2(w.rawStrength))  bal_str \(f2(w.balancedStrength))")
        }
        text.append("g_blended_net_motion           \(f2(blendedNetMotion))")
        text.append("g_blended_net_zoom_motion      \(f2(blendedNetZoomMotion))")
        text.append("g_blended_in_or_out_motion     \(f2(blendedInOrOutMotion))")
        text.append("g_blended_net_clockwise_motion \(f2(blendedNetClockwiseMotion))")
        text.append("g_blended_cw_or_ccw_motion     \(f2(blendedCwOrCcwMotion))")
        text.append("g_auto_darkening               \(f2(autoDarkening))")
        return text
    }

    /// `update(dt, audioFrame)`.
    public func update(dt: Double, audio: AudioFrame) {
        t += dt
        self.audio = audio
    }

    // MARK: - The background worker

    /// `start_job(payload)`: builds the map off the main actor, with its own random numbers (a web
    /// worker has its own Math.random).
    private func startBackgroundJob(_ next: NextWarpGeneration) {
        backgroundMap = nil
        backgroundInProgress = true
        let randoms = WarpMapRandoms(drawingFrom: &workerRandom)
        let id = takeMapID()
        Task.detached(priority: .utility) { [weak self] in
            let map = WarpMapBuilder.build(mode: next.mode, randoms: randoms, id: id, parallel: true)
            await self?.finishBackgroundJob(next, map: map)
        }
    }

    private func finishBackgroundJob(_ next: NextWarpGeneration, map: WarpMap) {
        backgroundInProgress = false
        backgroundMap = BackgroundMap(slot: next.earliestDeadSlot, mode: next.mode,
                                      t0: next.t0, t1: next.t1, t2: next.t2, t3: next.t3, map: map)
        backgroundBuilds += 1
    }

    // MARK: - render()

    /// `render(…)`: one simulation step.
    public func render(_ step: EngineStep, random: inout RandomSource) {
        let w = renderer.indexWidth
        let h = renderer.indexHeight
        let diagonal = toInt32((Double(w * w + h * h)).squareRoot())
        let motionTime = step.motionTime
        let waveTime = step.waveTime

        if step.randomizeMotion {
            randomizeActiveWarpMaps(motionTime: motionTime, random: &random)
        }

        // Start building a map in the background, if one will be needed.
        let backgroundLookahead = Self.newWaveMotionTimeLookahead + 4.0
        if !backgroundInProgress && backgroundMap == nil {
            let next = slots.nextGeneration(time: motionTime, lookahead: backgroundLookahead, random: &random)
            if next.earliestDeadSlot >= 0 {
                startBackgroundJob(next)
            }
        }

        // Use the background map, if it's ready and its slot still needs one at the look-ahead time.
        if let ready = backgroundMap {
            let future = slots.warp(slot: ready.slot, at: motionTime + backgroundLookahead)
            if future.mode == -1, ready.slot >= 0, ready.slot < slots.history.count {
                slots.history[ready.slot].append(ActiveWarpMap(mode: ready.mode, t0: ready.t0, t1: ready.t1, t2: ready.t2,
                                                               t3: ready.t3, peakStrength: 1.0, map: ready.map))
                backgroundMap = nil
                slots.randomizeNextDurations(random: &random)
            } else {
                // Something else filled the slot meanwhile.
                backgroundMap = nil
            }
        }

        // A new waveform?
        let setWave0 = step.randomizeWave || wave0 == nil
        let setWave1 = waveTime > wave0StartFadeTime && wave1 == nil

        // Build maps on the spot if the background one wasn't ready in time.
        let lookahead = Self.newWaveMotionTimeLookahead
        var next = slots.nextGeneration(time: motionTime, lookahead: lookahead, random: &random)
        while next.earliestDeadSlot >= 0 {
            let map = buildNow(mode: next.mode, random: &random)
            onDemandBuilds += 1
            slots.history[next.earliestDeadSlot].append(ActiveWarpMap(mode: next.mode, t0: next.t0, t1: next.t1,
                                                                      t2: next.t2, t3: next.t3, peakStrength: 1.0, map: map))
            slots.randomizeNextDurations(random: &random)
            next = slots.nextGeneration(time: motionTime, lookahead: lookahead, random: &random)
        }

        // Re-blend the motion metadata of the active maps; cheap, so every step.
        do {
            let warps = slots.warps(at: motionTime)
            let balanced = warps.map { Double(Float(jsMax(0.00001, $0.balancedStrength))) }
            let prefs = warps.map { $0.map?.prefs ?? WarpPrefs() }
            blendedNetMotion = 0.0
            blendedNetZoomMotion = 0.0
            blendedInOrOutMotion = 0.0
            blendedNetClockwiseMotion = 0.0
            blendedCwOrCcwMotion = 0.0
            for i in 0..<VisualizerConstants.maxActiveWarps {
                blendedNetMotion += prefs[i].netMotion * balanced[i]
                blendedNetZoomMotion += prefs[i].netZoomMotion * balanced[i]
                blendedInOrOutMotion += prefs[i].inOrOutMotion * balanced[i]
                blendedNetClockwiseMotion += prefs[i].netClockwiseMotion * balanced[i]
                blendedCwOrCcwMotion += prefs[i].cwOrCcwMotion * balanced[i]
            }
        }

        if setWave0 || setWave1 {
            chooseWave(setWave0: setWave0, setWave1: setWave1, motionTime: motionTime, waveTime: waveTime, random: &random)
        }

        applyToggles(step, waveTime: waveTime)

        // Blend between g_wave0 and g_wave1.
        guard var params = wave0 else { return }
        if waveTime > wave0StartFadeTime {
            if waveTime < wave0EndFadeTime, let wave1 {
                var t = jsMax(0.0, jsMin(1.0, (waveTime - wave0StartFadeTime) / (wave0EndFadeTime - wave0StartFadeTime)))
                t = smoothstep(t)
                params = WaveParams.blend(params, wave1, weights: 1.0 - t, t)
            } else if let wave1 {
                // The blend is done.
                wave0 = wave1
                self.wave1 = nil
                wave0StartFadeTime = waveTime + randBetween(Self.waveDurationMin, Self.waveDurationMax, &random)
                wave0EndFadeTime = wave0StartFadeTime + randBetween(Self.waveFadeMin, Self.waveFadeMax, &random)
                params = wave1
            }
        }

        // The four warp strengths, adjusted for the frame rate, and breathing.
        let warps = slots.warps(at: motionTime)
        var finalWarpStrength = [Float](repeating: 0, count: VisualizerConstants.maxActiveWarps)
        for i in 0..<VisualizerConstants.maxActiveWarps {
            finalWarpStrength[i] = Float(warps[i].balancedStrength * Self.baseMotionScale * step.userMotionScale / step.fps)
            let breathingStrength = 0.2
            let breathing = 1.0 + breathingStrength
                * cos(step.shiftTime * 0.7 + Double(i) * 6.28 / Double(VisualizerConstants.maxActiveWarps))
            finalWarpStrength[i] = Float(Double(finalWarpStrength[i]) * breathing)
            if let map = warps[i].map {
                renderer.setWarpMap(slot: i, field: map.field)
            }
        }

        // The slow drift of the whole image, in pixels.
        var shiftX = 0.0
        var shiftY = 0.0
        do {
            let shiftMag = Self.baseMotionScale * step.userMotionScale * Double(diagonal) / step.fps * 0.000121 * Self.shiftMagnitude
            let speed = Self.shiftFrequency
            let t = step.shiftTime * 60
            shiftX = shiftMag * (cos(t * 0.01171 * speed + 0) * 2 + cos(t * 0.00111 * speed + 3) * 2)
            shiftY = shiftMag * (cos(t * 0.00874 * speed + 1) * 1.3 + cos(t * 0.00351 * speed + 2) * 1.3)
            // The original stops the drift for modes 98 and 99 by reading `.mode` of slot 0's history
            // list, which is undefined, so it never does. Kept that way.
        }

        // Up to this diagonal, dots are 1 × 1; beyond it they grow, anti-aliased. Below it the wave needs
        // no adjustment: extra samples aren't drawn denser, the wave is just cropped.
        let diag1 = Self.diagonal(2060, 1430)
        let wavePointSize = jsMax(1.0, Double(diagonal) / Double(diag1))

        var waveAmplitudeScale = 1.0
        do {
            let visualEnergyNow = audio.visualEnergy
            let guardedFPS = jsMax(5.0, jsMin(120, step.fps))
            let updateRate = (visualEnergyNow > visualEnergyAtt) ? 0.7 : 0.1
            let t = 1.0 - pow(1.0 - updateRate, 1.0 / guardedFPS)
            visualEnergyAtt = visualEnergyAtt * (1.0 - t) + t * visualEnergyNow
            if visualEnergyAtt > Self.maxVisualEnergy {
                waveAmplitudeScale = Self.maxVisualEnergy / visualEnergyAtt
            } else {
                waveAmplitudeScale = 1.0
            }
        }

        var dots = waveformPoints(params, pointSize: wavePointSize, waveSmoothing: step.waveSmoothing,
                                  opacityScale: Self.waveOpacityScale, amplitudeScale: waveAmplitudeScale,
                                  alignFraction: step.alignFraction, width: w, height: h)

        let xform = TransformHelper(width: Double(w), height: Double(h))
        if step.beat > 0.0001 {
            beatDots(&dots, params: params, beat: step.beat, diagonal: diagonal, xform: xform, width: w, height: h, random: &random)
        }

        if params.fadingDots.value > 0.001 {
            let fields = slots.warps(at: motionTime).map { $0.map?.field.dxy ?? [] }
            let fadeSpeed = 6.5  // how fast they fade in and out
            for i in 0..<fadingDots.count {
                let phase = Double(i) * Double.pi * 2 / Double(fadingDots.count)
                let str = jsMax(0.0, jsMin(1.0, 0.5 + 0.6 * cos(step.timeNow * fadeSpeed + phase)))
                    * params.fadingDots.value * 0.6 * 0.5
                if str < 0.0001 {
                    // Move it while it's hidden.
                    fadingDots[i].x = random.next() * Double(w)
                    fadingDots[i].y = random.next() * Double(h)
                } else {
                    let speedMultiplier = 1.0
                    let moved = advectPoint(x: fadingDots[i].x, y: fadingDots[i].y, transform: xform, fields: fields,
                                            strengths: finalWarpStrength, speedMultiplier: speedMultiplier,
                                            shiftX: shiftX, shiftY: shiftY)
                    fadingDots[i] = moved
                    dots.appendDot(Float(toInt32(moved.x)), Float(toInt32(moved.y)), Float(wavePointSize), Float(str))
                }
            }
        }

        chasers(&dots, params: params, timeNow: step.timeNow, pointSize: wavePointSize, xform: xform)

        if params.gridDots.value > 0.001 {
            gridDots(&dots, params: params, timeNow: step.timeNow, pointSize: wavePointSize, width: w, height: h)
        }

        // More darkening when there's a lot of zoom and a single flat wave (presumably lined up with the
        // centre of the zoom).
        let zoomForNormalDarkening = 1.0
        let zoomForExtraDarkening = 2.0
        let maxExtraDarkening = 0.25
        autoDarkening = jsMax(0.0, jsMin(1.0, (blendedNetZoomMotion - zoomForNormalDarkening)
                                            / (zoomForExtraDarkening - zoomForNormalDarkening)))
            * maxExtraDarkening
            * params.waveFlatStr
            * (1.0 - params.waveFlatIsStereo)

        // The warp on the GPU, then the dots drawn into it.
        if !step.frozen {
            renderer.warpAndDrawWaveform(weights: SIMD4(finalWarpStrength[0], finalWarpStrength[1], finalWarpStrength[2], finalWarpStrength[3]),
                                         shift: SIMD2(Float(shiftX), Float(shiftY)), points: dots,
                                         darkening: Float(step.darkening + autoDarkening), time: Float(step.timeNow))
        }

        // Forget maps that have finished.
        slots.prune(motionTime: motionTime)
    }

    // MARK: - Choosing the wave

    /// Blends the wave preferences of the four maps (now, or at the look-ahead time for g_wave1) and
    /// picks the next wave: flat, circular or both, where and how big, and which dots go with it.
    private func chooseWave(setWave0: Bool, setWave1: Bool, motionTime: Double, waveTime: Double, random: inout RandomSource) {
        let time = setWave1 ? (motionTime + Self.newWaveMotionTimeLookahead) : motionTime
        let warps = slots.warps(at: time)
        var balanced = [Double](repeating: 0, count: VisualizerConstants.maxActiveWarps)
        var prefs = [WarpPrefs](repeating: WarpPrefs(), count: VisualizerConstants.maxActiveWarps)
        var weights = [Double](repeating: 0, count: VisualizerConstants.maxActiveWarps)
        for i in 0..<VisualizerConstants.maxActiveWarps {
            balanced[i] = Double(Float(jsMax(0.00001, warps[i].balancedStrength)))
            prefs[i] = warps[i].map?.prefs ?? WarpPrefs()
            weights[i] = Double(Float(balanced[i] * prefs[i].wavePrefsWeight))
        }

        // The motion metadata again, at `time`.
        var blendedNetZoomMotion = 0.0
        var blendedInOrOutMotion = 0.0
        for i in 0..<VisualizerConstants.maxActiveWarps {
            blendedNetZoomMotion += prefs[i].netZoomMotion * balanced[i]
            blendedInOrOutMotion += prefs[i].inOrOutMotion * balanced[i]
        }

        var p = WarpPrefs.blend(prefs, weights: weights)

        // The centres again, weighted also by how much each map hogs the motion.
        do {
            var weights2 = [Double](repeating: 0, count: VisualizerConstants.maxActiveWarps)
            for i in 0..<VisualizerConstants.maxActiveWarps {
                let weightScale = warps[i].map?.prefs.hogMotionWeight ?? 0
                weights2[i] = Double(Float(weights[i] * weightScale))
            }
            let p2 = WarpPrefs.blend(prefs, weights: weights2)
            p.flatCxLo = p2.flatCxLo
            p.flatCxHi = p2.flatCxHi
            p.flatCyLo = p2.flatCyLo
            p.flatCyHi = p2.flatCyHi
            p.circCxLo = p2.circCxLo
            p.circCxHi = p2.circCxHi
            p.circCyLo = p2.circCyLo
            p.circCyHi = p2.circCyHi
            p.motionCx = p2.motionCx
            p.motionCy = p2.motionCy
        }

        let params = WaveParams()

        // The net motion decides between a flat and a circular wave.
        let flatWeight = 1.0
        var circWeight = 0.25
        var bothWeight = 0.01
        do {
            let zoomThresholdScale = 1.8

            // No circular wave unless there's a lot of motion in or out.
            do {
                let lo = zoomThresholdScale * 0.2
                let hi = zoomThresholdScale * 0.35
                let t = jsMax(0.0, jsMin(1.0, (blendedInOrOutMotion - lo) / (hi - lo)))
                circWeight *= t
                bothWeight *= t
            }
            // No radial beat dots when there's very little motion in or out.
            do {
                let lo = zoomThresholdScale * 0.15
                let hi = zoomThresholdScale * 0.50
                let t = jsMax(0.0, jsMin(1.0, (blendedInOrOutMotion - lo) / (hi - lo)))
                p.radialBeatDotsProb *= t
            }
            // Very zoomy: sometimes narrow the stereo separation.
            do {
                let lo = zoomThresholdScale * 0.25
                let hi = zoomThresholdScale * 0.35
                var t = jsMax(0.0, jsMin(1.0, (blendedNetZoomMotion - lo) / (hi - lo)))
                t = 1 - 0.5 * t * random.next()
                p.flatStereoSepLo *= t
                p.flatStereoSepHi *= t
            }
            // Very, very zoomy: sometimes shrink the circle.
            do {
                let lo = zoomThresholdScale * 0.3
                let hi = zoomThresholdScale * 0.5
                var t = jsMax(0.0, jsMin(1.0, (blendedNetZoomMotion - lo) / (hi - lo)))
                t = 1 - 0.5 * t * random.next()
                p.circRadLo *= t
                p.circRadHi *= t
            }
        }

        // Flat, circular or both.
        let pick = random.next() * (flatWeight + circWeight + bothWeight)
        if pick < flatWeight {
            params.waveFlatStr = 1.0
        } else if pick < flatWeight + circWeight {
            params.waveCircStr = 1.0
        } else {
            params.waveFlatStr = 1.0
            params.waveCircStr = 1.0
        }

        if params.waveFlatStr > 0.0001 {
            params.waveFlatAngle = Self.biasTowardHorizontal(randBetween(p.flatAngleLo, p.flatAngleHi, &random),
                                                             iterations: p.flatAngleBiasTowardHorizontalAngles)
            params.waveFlatScale = p.flatScale
            params.waveFlatIsStereo = (random.next() < p.flatIsStereoChance) ? 1 : 0
            params.waveFlatStereoSep = randBetween(p.flatStereoSepLo, p.flatStereoSepHi, &random)
            params.waveFlatStereoAmplitudeScale = p.flatStereoAmplitudeScale
            params.waveFlatCx = randBetween(p.flatCxLo, p.flatCxHi, &random)
            params.waveFlatCy = randBetween(p.flatCyLo, p.flatCyHi, &random)
        }

        if params.waveCircStr > 0.0001 {
            params.waveCircRad = randBetween(p.circRadLo, p.circRadHi, &random)
            params.waveCircScale = p.circScale
            params.waveCircAngle = random.next() * 6.28
            params.waveCircCx = randBetween(p.circCxLo, p.circCxHi, &random)
            params.waveCircCy = randBetween(p.circCyLo, p.circCyHi, &random)
        }

        // Wrap the flat angle, even when this wave has no flat part.
        if setWave1, let wave0 {
            if wave0.waveFlatStr > 0.0001 {
                if params.waveFlatStr > 0.0001 {
                    // Flat to flat: wrap the angle.
                    params.waveFlatAngle = Self.wrapAngleNear(wave0.waveFlatAngle, params.waveFlatAngle)
                } else {
                    // Flat to circular: keep the angle, so the fading flat wave doesn't turn.
                    params.waveFlatAngle = wave0.waveFlatAngle
                }
            } else if params.waveFlatStr > 0.0001 {
                // Circular to flat: give the old one the new angle, so the flat wave doesn't turn.
                wave0.waveFlatAngle = params.waveFlatAngle
            }
        }

        params.motionCx = p.motionCx
        params.motionCy = p.motionCy

        params.radialBeatDots = DotSwitch(value: (random.next() < p.radialBeatDotsProb) ? 1.0 : 0.0)
        params.randomBeatDots = DotSwitch(value: (random.next() < p.randomBeatDotsProb) ? 1.0 : 0.0)
        params.fadingDots = DotSwitch(value: (random.next() < p.fadingDotsProb) ? 1.0 : 0.0)
        params.gridDots = DotSwitch(value: (random.next() < p.gridDotsProb) ? 1.0 : 0.0)
        let useChasers = random.next() < p.chaserProb
        params.chaser1 = useChasers ? 1.0 : 0.0
        params.chaser2 = (useChasers && random.next() < Self.twoChasersProbability) ? 1.0 : 0.0
        params.dottyChaser = (random.next() < p.dottyChaserProb) ? 1.0 : 0.0

        if setWave0 {
            wave0 = params
            // The next wave is chosen at the last possible moment.
            wave1 = nil
            wave0StartFadeTime = waveTime + randBetween(Self.waveDurationMin, Self.waveDurationMax, &random)
            wave0EndFadeTime = wave0StartFadeTime + randBetween(Self.waveFadeMin, Self.waveFadeMax, &random)
        }
        if setWave1 {
            wave1 = params
        }
    }

    /// Keys 1–6 flip the dot effects. Mid-fade, both waves change; the original's assignment order is
    /// kept, quirks included ([sic] in engine.js).
    private func applyToggles(_ step: EngineStep, waveTime: Double) {
        let midFade = (wave0StartFadeTime + wave0EndFadeTime) * 0.5
        func flip(_ field: ReferenceWritableKeyPath<WaveParams, DotSwitch>) {
            guard let wave0 else { return }
            if waveTime < wave0StartFadeTime {
                wave0[keyPath: field] = wave0[keyPath: field].flipped
            } else if waveTime < midFade {
                wave0[keyPath: field] = wave0[keyPath: field].flipped
                wave1?[keyPath: field] = wave0[keyPath: field]
            } else if let wave1 {
                wave1[keyPath: field] = wave1[keyPath: field].flipped
                wave0[keyPath: field] = wave1[keyPath: field]
            }
        }
        if step.toggleGridDots { flip(\.gridDots) }
        if step.toggleFadingDots { flip(\.fadingDots) }
        if step.toggleChasers, let wave0 {
            let useWave0 = waveTime < midFade
            let current = useWave0 ? wave0 : (wave1 ?? wave0)
            let chaser1Active = current.chaser1 > 0.001
            let chaser2Active = current.chaser2 > 0.001
            let oldCount = (chaser1Active ? 1 : 0) + (chaser2Active ? 1 : 0)
            let newCount = (oldCount + 1) % 3
            wave0.chaser1 = (newCount > 0) ? 1.0 : 0.0
            wave1?.chaser1 = (newCount > 0) ? 1.0 : 0.0
            wave0.chaser2 = (newCount > 1) ? 1.0 : 0.0
            wave1?.chaser2 = (newCount > 1) ? 1.0 : 0.0
        }
        if step.toggleDottyChaser, let wave0 {
            let useWave0 = waveTime < midFade
            let current = useWave0 ? wave0 : (wave1 ?? wave0)
            let newValue = (current.dottyChaser > 0.001) ? 0.0 : 1.0
            wave0.dottyChaser = newValue
            wave1?.dottyChaser = newValue
        }
        if step.toggleRandomBeatDots { flip(\.randomBeatDots) }
        if step.toggleRadialBeatDots { flip(\.radialBeatDots) }
    }

    // MARK: - Dots

    /// `generateWaveformPoints(…)`: the aligned, smoothed wave as dots, flat (once, or twice for stereo)
    /// and/or around a circle.
    private func waveformPoints(_ params: WaveParams, pointSize: Double, waveSmoothing: Int, opacityScale: Double,
                                amplitudeScale: Double, alignFraction: Double, width w: Int, height h: Int) -> [Float] {
        var buf: [Float] = []
        let wave = audio.wave
        let rms = audio.rms
        // The most samples needed grows with the image's diagonal.
        let diagonal = Double(toInt32((Double(w * w + h * h)).squareRoot()))
        let xform = TransformHelper(width: Double(w), height: Double(h))

        // The part of the wave that best lines up with the last one, smoothed.
        var waveform: [Float] = []
        if params.waveFlatStr > 0 || params.waveCircStr > 0 {
            let aligned = aligner.align(wave, alignFraction: alignFraction, sampleCount: wave.count)
            waveform = WaveAligner.blur(aligned, radius: waveSmoothing)
        }

        if params.waveFlatStr > 0 {
            let cosx = cos(params.waveFlatAngle)
            let sinx = sin(params.waveFlatAngle)

            // Upsample if there aren't enough samples to fill the screen.
            let targetSampleCount = toInt32(diagonal * Self.waveStretch * (alignFraction / 0.55) / pointSize)
            var resampled = waveform
            if resampled.count != targetSampleCount {
                resampled = Self.linearResample(resampled, to: targetSampleCount)
            }
            let n = resampled.count

            let sep = params.waveFlatIsStereo * params.waveFlatStereoSep
            // Shrink quickly while the stereo separation is on.
            let amplitude = 2.0 * 0.7 * params.waveFlatScale * amplitudeScale * (1.0 - 0.7 * sep.squareRoot())

            // Opacity.
            let mag0 = jsMin(255, (jsMin(255, rms * 20000 + 16) * params.waveFlatStr)) * opacityScale * Self.waveMagScale

            var cx = params.waveFlatCx
            var cy = params.waveFlatCy
            // Slide the wave, if needed, so the whole of it shows.
            do {
                let t = cx * cosx + cy * sinx
                cx -= cosx * t
                cy -= sinx * t
            }
            let midX = xform.normToScreenX(cx)
            let midY = xform.normToScreenY(cy)

            // Just the middle of the aligned part.
            let sample0 = jsMax(0, Double(n - targetSampleCount)) / 2
            let sampleCount = min(targetSampleCount, n)
            let secondChannelOpacity = jsMax(0.0, params.waveFlatIsStereo * 2 - 1)

            for pass in 0..<2 {
                if pass == 1 && (params.waveFlatIsStereo < 0.0001 || params.waveFlatStereoSep < 0.0001) {
                    break
                }
                var mag = mag0
                if pass == 1 {
                    // The second wave fades in late and out early.
                    mag = Double(toInt32(mag * secondChannelOpacity))
                }
                let stereoOffset = ((-0.5 + Double(pass)) * sep)
                let amplitude2 = amplitude
                    * (secondChannelOpacity * params.waveFlatStereoAmplitudeScale + (1.0 - secondChannelOpacity) * 1.0)
                mag = jsMin(mag * (1.0 / 255), 1.0)

                buf.reserveCapacity(buf.count + max(0, sampleCount) * 4)
                for k in 0..<max(0, sampleCount) {
                    let i = toInt32(Double(k) + sample0)
                    let v = resampled.js(i) * amplitude2  // −1 … 1
                    // The un-rotated point, in pixels from the centre.
                    let x0 = (Double(k) - Double(sampleCount) * 0.5) * pointSize
                    let y0 = (v + stereoOffset) * (diagonal * 0.3)
                    // Rotated by the angle.
                    let fx = x0 * cosx - y0 * sinx
                    let fy = x0 * sinx + y0 * cosx
                    buf.append(Float(midX + fx))
                    buf.append(Float(midY + fy))
                    buf.append(Float(pointSize))
                    buf.append(Float(mag))
                }
            }
        }

        if params.waveCircStr > 0 {
            let circRad = params.waveCircRad * 1.15  // 0.8 … 1.5
            let circAmplitudeScale = params.waveCircScale * 0.85  // 0.5 … 1.2

            // Half as many samples as a flat wave; more look cluttered.
            let targetSampleCount = toInt32(diagonal * 0.45)
            var resampled = waveform
            if resampled.count != targetSampleCount {
                resampled = Self.linearResample(resampled, to: targetSampleCount)
            }
            let n = resampled.count

            let amplitude = 2.2 * params.waveCircScale * params.waveCircRad * amplitudeScale

            // Opacity.
            var mag = Double(toInt32(jsMin(255, (jsMin(255, rms * 20000 * 0.16 + 12) * 0.6) * params.waveCircStr)))
            mag = jsMin(mag * (1.0 / 255), 1.0) * opacityScale

            let midX = xform.normToScreenX(params.waveCircCx)
            let midY = xform.normToScreenY(params.waveCircCy)

            let sample0 = toInt32(jsMax(0, Double(n - targetSampleCount)) / 2)
            let sampleCount = min(targetSampleCount, n)
            let overlap = toInt32(Double(sampleCount) / 8)

            buf.reserveCapacity(buf.count + max(0, sampleCount - overlap) * 4)
            for k in 0..<max(0, sampleCount - overlap) {
                let i = k + sample0
                var v = resampled.js(i) * amplitude
                if k < overlap {
                    let t = Double(k) * (1.0 / Double(overlap))
                    let i2 = k + sample0 + sampleCount - overlap
                    let v2 = resampled.js(i2) * amplitude
                    v = v2 * (1 - t) + v * (t)
                }
                var fx = Double(k) - Double(sampleCount) * 0.5
                var fy = v * (diagonal * 0.3)
                // Around the circle.
                do {
                    let t = Double(k) * (1.0 / Double(sampleCount - overlap))  // [0 … 1]
                    let r = diagonal * (0.1 * circRad) + fy * (0.2 * circAmplitudeScale)
                    fx = r * cos(t * (3.1415927 * 2) + params.waveCircAngle)
                    fy = r * sin(t * (3.1415927 * 2) + params.waveCircAngle)
                }
                buf.append(Float(midX + fx))
                buf.append(Float(midY + fy))
                buf.append(Float(pointSize))
                buf.append(Float(mag))
            }
        }
        // (The original's XY oscilloscope is switched off with `if (0)`; not ported.)
        return buf
    }

    /// On a beat: a ring of dots around the motion centre, and/or dots scattered at random.
    private func beatDots(_ dots: inout [Float], params: WaveParams, beat: Double, diagonal: Int, xform: TransformHelper,
                          width w: Int, height h: Int, random: inout RandomSource) {
        var dotRad = 0.0025 + random.next() * 0.0025 * 10
        var dotCount = pow(2.0, 4 + 3 * random.next())
        var dotIntensity = 32 + random.next() * 128
        let intensity = dotRad * dotRad * dotCount * dotIntensity * (beat + 1)
        let targetIntensity = (0.08 + 0.08 * random.next()) * 1.5
        let adj = pow(targetIntensity / intensity, 0.25)
        dotRad *= adj * adj * 0.44
        dotCount *= adj * 0.5
        dotIntensity *= adj

        let r = Double(toInt32(dotRad * Double(diagonal)))
        _ = random.next() < 0.25  // `flat_shading`: drawn and never used.

        if params.radialBeatDots.value > 0.001 {
            let v = Double(toInt32(dotIntensity * params.radialBeatDots.value))
            let circRad = 0.1 + 0.2 * random.next()
            let count = toInt32(dotCount / 2)
            for i in 0..<max(0, count) {
                let theta = Double(i) * Double.pi * 2 / Double(count)
                let fcx = cos(theta) * circRad + params.motionCx
                let fcy = sin(theta) * circRad + params.motionCy
                let cx = toInt32(xform.normToScreenX(fcx))
                let cy = toInt32(xform.normToScreenY(fcy))
                dots.appendDot(Float(cx), Float(cy), Float(r * 2), Float(v * (1.0 / 255)))
            }
        }

        if params.randomBeatDots.value > 0.001 {
            let v = Double(toInt32(dotIntensity * params.randomBeatDots.value))
            var i = 0.0
            while i < dotCount {
                let cx = toInt32(random.next() * Double(w - 1))
                let cy = toInt32(random.next() * Double(h - 1))
                dots.appendDot(Float(cx), Float(cy), Float(r * 1.3), Float(v * (1.0 / 255)))
                i += 1
            }
        }
    }

    /// Chasers 1 and 2, and the dotty chaser: ten dots each, tracing Lissajous-like paths.
    private func chasers(_ dots: inout [Float], params: WaveParams, timeNow: Double, pointSize: Double,
                         xform: TransformHelper) {
        for k in 0..<3 {
            var str = 1.0
            var step = 0.003
            var phaseOffset = 0.0
            var timeScale = 1.0
            var radScale = 1.0
            if k == 0 {
                str = params.chaser1
            } else if k == 1 {
                str = params.chaser2
                phaseOffset = 371.0
            } else {
                str = params.dottyChaser
                step = 0.06  // about the distance between the dots
                timeScale = 0.75
                phaseOffset = 150.0
                radScale = 1.5
            }
            guard str > 0.001 else { continue }
            let speed = 2.5 * timeScale * 0.93
            for i in 0..<10 {
                let when = timeNow + Double(i) * step + phaseOffset
                var fx = cos(when * 1.732 * speed + 1) * 0.15
                var fy = cos(when * 1.332 * speed + 3) * 0.15
                fx += cos(when * 1.592 * speed + 2) * 0.2
                fy += cos(when * 2.188 * speed + 0) * 0.2
                fx *= radScale
                fy *= radScale
                dots.appendDot(Float(xform.normToScreenX(fx)), Float(xform.normToScreenY(fy)), Float(pointSize * 2), Float(str))
            }
        }
    }

    /// A drifting grid of dots, 24 to the diagonal.
    private func gridDots(_ dots: inout [Float], params: WaveParams, timeNow: Double, pointSize: Double,
                          width w: Int, height h: Int) {
        let diagonal = Double(toInt32((Double(w * w + h * h)).squareRoot()))
        let pointsAlongDiagonal = 24.0
        let v = Double(toInt32(96 * params.gridDots.value))
        let step = toInt32(diagonal / pointsAlongDiagonal)
        // With no step the original's start is NaN and draws nothing.
        guard step > 0 else { return }
        let time = timeNow * 0.55
        let fx = (cos(time * 0.537 + 1) + cos(time * 0.359 + 2)) * 0.5
        let fy = (cos(time * 0.611 + 3) + cos(time * 0.429 + 5)) * 0.4
        let startX = toInt32((fx + 1) * Double(step) * 3) % step
        let startY = toInt32((fy + 1) * Double(step) * 3) % step
        var y = startY
        while y < h {
            var x = startX
            while x < w {
                dots.appendDot(Float(x), Float(y), Float(pointSize), Float(v * (1.0 / 255)))
                x += step
            }
            y += step
        }
    }

    // MARK: - Helpers

    /// `GetDiag(w, h)`.
    static func diagonal(_ w: Int, _ h: Int) -> Int {
        toInt32((Double(w * w + h * h)).squareRoot())
    }

    /// `RandBetween(lo, hi)`.
    private func randBetween(_ lo: Double, _ hi: Double, _ random: inout RandomSource) -> Double {
        lo + (hi - lo) * random.next()
    }

    /// `WrapAngleNear(A, B)`: B plus the multiple of 2π that brings it within ±π of A.
    static func wrapAngleNear(_ a: Double, _ b: Double) -> Double {
        let twoPi = Double.pi * 2
        return b + twoPi * jsRound((a - b) / twoPi)
    }

    /// `BiasTowardHorizontal(theta, iters)`: pulls the angle toward the nearest multiple of π with
    /// smoothstep, `iterations` times (0 … 10, fractions allowed).
    static func biasTowardHorizontal(_ theta: Double, iterations: Double) -> Double {
        var iters = jsMax(0.0, jsMin(10.0, iterations))
        let t = theta / Double.pi
        let base = t.rounded(.down)
        var dt = t - base
        while iters > 0.0 {
            let dt2 = smoothstep(dt)
            let writeFraction = jsMin(iters, 1.0)
            dt = dt2 * writeFraction + (1.0 - writeFraction) * dt
            iters -= 1.0
        }
        return (base + dt) * Double.pi
    }

    /// `linearResampleF(input, outLen)`: a Float32 wave resampled to any length. Upsampling interpolates
    /// at points; downsampling averages the piecewise-linear signal over each output bin. The ends are
    /// kept exactly when there are at least two outputs. The original throws for a negative length;
    /// this returns no samples.
    public static func linearResample(_ input: [Float], to outLen: Int) -> [Float] {
        let inLen = input.count
        if outLen < 0 { return [] }
        if outLen == inLen { return input }
        if outLen == 0 || inLen == 0 { return [] }
        if inLen == 1 { return [Float](repeating: input[0], count: outLen) }
        if outLen == 1 {
            // The average of the whole piecewise-linear signal, over [0 … inLen − 1].
            let l = inLen - 1
            var area = 0.0
            for i in 0..<l { area += 0.5 * (Double(input[i]) + Double(input[i + 1])) }
            return [Float(area / Double(l))]
        }

        var out = [Float](repeating: 0, count: outLen)
        let l = inLen - 1

        if outLen > inLen {
            // Upsampling: point-sampled linear interpolation, ends aligned.
            let scale = Double(l) / Double(outLen - 1)
            for i in 0..<outLen {
                let pos = Double(i) * scale
                let idx = toInt32(pos)
                if idx >= l {
                    out[i] = input[l]
                } else {
                    let frac = pos - Double(idx)
                    let a = Double(input[idx])
                    let b = Double(input[idx + 1])
                    out[i] = Float(a + (b - a) * frac)
                }
            }
            return out
        }

        // Downsampling: integrate the piecewise-linear signal. Output i sits at p[i] = i·L / (outLen − 1);
        // its bin runs between the midpoints to its neighbours, from 0 to L.
        // Prefix areas: a[k] = ∫₀ᵏ, a Float32Array.
        var prefix = [Float](repeating: 0, count: inLen)
        for i in 0..<l {
            prefix[i + 1] = Float(Double(prefix[i]) + 0.5 * (Double(input[i]) + Double(input[i + 1])))
        }
        func antiderivative(_ x: Double) -> Double {
            if x <= 0 { return 0.0 }
            if x >= Double(l) { return Double(prefix[l]) }
            let i = toInt32(x)  // floor
            let t = x - Double(i)  // [0, 1)
            let y0 = Double(input[i])
            let y1 = Double(input[i + 1])
            let dy = y1 - y0
            // ∫ from i to i + t of y0 + dy·s = y0·t + 0.5·dy·t².
            return Double(prefix[i]) + (y0 * t) + (0.5 * dy * t * t)
        }
        let positionScale = Double(l) / Double(outLen - 1)
        var left = 0.0
        for i in 0..<outLen {
            let p = Double(i) * positionScale
            let right: Double
            if i == outLen - 1 {
                right = Double(l)
            } else {
                let nextP = Double(i + 1) * positionScale
                right = 0.5 * (p + nextP)
            }
            let width = right - left
            if width <= 0 {
                // Shouldn't happen; avoids dividing by zero.
                out[i] = Float(input.js(toInt32(p + 0.5)))
            } else {
                out[i] = Float((antiderivative(right) - antiderivative(left)) / width)
            }
            left = right
        }
        return out
    }
}

extension Array where Element == Float {
    /// One dot for the renderer: (x, y, size in pixels, alpha), as the original pushes them.
    @inline(__always)
    mutating func appendDot(_ x: Float, _ y: Float, _ size: Float, _ alpha: Float) {
        append(x)
        append(y)
        append(size)
        append(alpha)
    }
}
