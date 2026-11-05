import Accelerate
import Foundation
import VisualizerCore

/// OLDTUNES_VIS_MODE=parity — the ported engine (VisualizerCore/Engine) against what the original
/// JavaScript computed (VisualizerFixtures+Engine.swift, made in the browser by
/// tools/visualizer-fixtures.js), then robustness, speed and a smoke run of the driver against a
/// stand-in renderer. No window, no audio; a few seconds.
extension VisualizerHarness {
    static func parity(_ bench: VisualizerBench) async {
        let maps = parityWarpModes(bench)
        parityStreamChecks(bench)
        parityParallelBuild(bench)
        parityPalettes(bench)
        parityAligner(bench)
        parityAdvect(bench, maps: maps)
        parityEngine(bench)
        paritySeeds(bench)
        parityMapSpeed(bench)
        await parityDriver(bench)
    }

    /// "Within 1e-5 relative" for every compared number.
    private static let tolerance = 1e-5

    /// |a − b| relative to |b|. NaN only matches NaN; exact zeros must match exactly.
    private static func relativeError(_ a: Double, _ b: Double) -> Double {
        if a.isNaN || b.isNaN { return a.isNaN && b.isNaN ? 0 : .infinity }
        if a == b { return 0 }
        return abs(a - b) / max(abs(b), 1e-300)
    }

    private static func sci(_ x: Double) -> String { String(format: "%.1e", x) }
    private static func ms(_ seconds: Double) -> String { String(format: "%.2f ms", seconds * 1000) }

    /// Σ dxy[i] for i = 0, 997, 1994, …
    private static func checksum997(_ dxy: [Float]) -> Double {
        var sum = 0.0
        for i in stride(from: 0, to: dxy.count, by: 997) { sum += Double(dxy[i]) }
        return sum
    }

    /// Σ v[i]·((i mod 7) + 1), the fixture tool's checksum.
    private static func checksum(_ values: [Float]) -> Double {
        var sum = 0.0
        for (i, v) in values.enumerated() { sum += Double(v) * Double((i % 7) + 1) }
        return sum
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
    }

    /// warp_prefs fields by their names in motion.js.
    private static func prefsFields() -> [(name: String, field: KeyPath<WarpPrefs, Double>)] {
        [("wave_prefs_weight", \.wavePrefsWeight), ("hog_motion_weight", \.hogMotionWeight),
         ("flat_angle_lo", \.flatAngleLo), ("flat_angle_hi", \.flatAngleHi),
         ("flat_angle_bias_toward_horizontal_angles", \.flatAngleBiasTowardHorizontalAngles),
         ("flat_scale", \.flatScale), ("flat_is_stereo_chance", \.flatIsStereoChance),
         ("flat_stereo_sep_lo", \.flatStereoSepLo), ("flat_stereo_sep_hi", \.flatStereoSepHi),
         ("flat_stereo_amplitude_scale", \.flatStereoAmplitudeScale),
         ("flat_cx_lo", \.flatCxLo), ("flat_cx_hi", \.flatCxHi), ("flat_cy_lo", \.flatCyLo), ("flat_cy_hi", \.flatCyHi),
         ("circ_rad_lo", \.circRadLo), ("circ_rad_hi", \.circRadHi), ("circ_scale", \.circScale),
         ("circ_cx_lo", \.circCxLo), ("circ_cx_hi", \.circCxHi), ("circ_cy_lo", \.circCyLo), ("circ_cy_hi", \.circCyHi),
         ("motion_cx", \.motionCx), ("motion_cy", \.motionCy),
         ("use_motion_center_as_wave_center_prob", \.useMotionCenterAsWaveCenterProb),
         ("use_motion_center_as_wave_center_power", \.useMotionCenterAsWaveCenterPower),
         ("radial_beat_dots_prob", \.radialBeatDotsProb), ("random_beat_dots_prob", \.randomBeatDotsProb),
         ("fading_dots_prob", \.fadingDotsProb), ("grid_dots_prob", \.gridDotsProb),
         ("chaser_prob", \.chaserProb), ("dotty_chaser_prob", \.dottyChaserProb),
         ("net_motion", \.netMotion), ("net_zoom_motion", \.netZoomMotion), ("in_or_out_motion", \.inOrOutMotion),
         ("net_clockwise_motion", \.netClockwiseMotion), ("cw_or_ccw_motion", \.cwOrCcwMotion),
         ("angular_motion_mag", \.angularMotionMag), ("radial_motion_mag", \.radialMotionMag),
         ("abs_radial_motion_mag", \.absRadialMotionMag), ("abs_angular_motion_mag", \.absAngularMotionMag)]
    }

    /// Never declared by the original: modes 0 and 1 multiply it by 1.4 anyway (making it NaN), and
    /// nothing reads it, so the port doesn't keep it.
    private static let undeclaredPrefs: Set<String> = ["type_flat_plus_circ"]

    // MARK: - motion.js

    /// Every mode the original has, built from mulberry32(12345): the checksum, 16 vectors and the
    /// prefs (the five metadata values and every field the mode changes).
    private static func parityWarpModes(_ bench: VisualizerBench) -> [Int: WarpMap] {
        let fields = prefsFields()
        let defaults = WarpPrefs()

        // The port's starting values are the original's.
        var defaultsWorst = 0.0
        var unknown: [String] = []
        for (name, expected) in EngineFixtures.defaultPrefs {
            guard let field = fields.first(where: { $0.name == name })?.field else {
                unknown.append(name)
                continue
            }
            defaultsWorst = max(defaultsWorst, relativeError(defaults[keyPath: field], expected))
        }
        bench.check("warp prefs defaults", unknown.isEmpty && defaultsWorst <= tolerance
                        && EngineFixtures.defaultPrefs.count == fields.count,
                    "\(EngineFixtures.defaultPrefs.count) fields, worst \(sci(defaultsWorst))"
                        + (unknown.isEmpty ? "" : ", unknown \(unknown)"))

        var maps: [Int: WarpMap] = [:]
        for fixture in EngineFixtures.warpModes {
            var random = RandomSource.mulberry32(seed: EngineFixtures.seed)
            let map = WarpMapBuilder.build(mode: fixture.mode, random: &random, id: UInt64(fixture.mode + 1))
            maps[fixture.mode] = map

            let sumError = relativeError(checksum997(map.field.dxy), fixture.checksum)
            var vectorError = 0.0
            for (k, pixel) in EngineFixtures.vectorPixels.enumerated() {
                vectorError = max(vectorError, relativeError(Double(map.field.dxy[pixel * 2]), Double(Float(fixture.vectors[k * 2]))))
                vectorError = max(vectorError, relativeError(Double(map.field.dxy[pixel * 2 + 1]), Double(Float(fixture.vectors[k * 2 + 1]))))
            }
            var prefsError = 0.0
            var problems: [String] = []
            for (name, field) in fields {
                let expected = fixture.prefs[name] ?? EngineFixtures.defaultPrefs[name] ?? .nan
                let error = relativeError(map.prefs[keyPath: field], expected)
                if error > tolerance { problems.append("\(name) \(map.prefs[keyPath: field]) vs \(expected)") }
                prefsError = max(prefsError, error)
            }
            for (name, value) in fixture.prefs where !fields.contains(where: { $0.name == name }) {
                if !(undeclaredPrefs.contains(name) && value.isNaN) { problems.append("unknown \(name)") }
            }
            let worst = max(sumError, vectorError, prefsError)
            bench.check("mode \(fixture.mode)", worst <= tolerance && problems.isEmpty,
                        "checksum \(String(format: "%.6f", checksum997(map.field.dxy))) (\(sci(sumError))), "
                            + "16 vectors \(sci(vectorError)), \(fields.count) prefs \(sci(prefsError))"
                            + (problems.isEmpty ? "" : "; " + problems.joined(separator: ", ")))
        }
        return maps
    }

    /// The brief's check values: maps built back to back from one mulberry32(12345) stream.
    private static func parityStreamChecks(_ bench: VisualizerBench) {
        for check in EngineFixtures.streamChecks {
            var random = RandomSource.mulberry32(seed: EngineFixtures.seed)
            for _ in 0..<(check.mapsBefore * 1280) { _ = random.next() }
            let map = WarpMapBuilder.build(mode: check.mode, random: &random, id: 1)
            let sum = checksum997(map.field.dxy)
            let worst = max(relativeError(sum, check.checksum), relativeError(map.prefs.netZoomMotion, check.netZoomMotion))
            bench.check("stream check mode \(check.mode)", worst <= tolerance,
                        "map #\(check.mapsBefore + 1) of the stream: sum \(String(format: "%.6f", sum)), "
                            + "net_zoom \(String(format: "%.5f", map.prefs.netZoomMotion)) (\(sci(worst)))")
        }
    }

    /// Bands on all cores give the same map as one thread, bit for bit.
    private static func parityParallelBuild(_ bench: VisualizerBench) {
        var differing: [Int] = []
        let modes = [3, 4, 7, 14, 18, 22, 28]
        for mode in modes {
            var a = RandomSource.mulberry32(seed: 777)
            var b = RandomSource.mulberry32(seed: 777)
            let serial = WarpMapBuilder.build(mode: mode, random: &a, id: 1, parallel: false)
            let parallel = WarpMapBuilder.build(mode: mode, random: &b, id: 1, parallel: true)
            if serial.field.dxy != parallel.field.dxy || serial.prefs.netMotion != parallel.prefs.netMotion {
                differing.append(mode)
            }
        }
        bench.check("parallel build matches serial", differing.isEmpty,
                    "modes \(modes.map(String.init).joined(separator: ", "))"
                        + (differing.isEmpty ? " identical" : "; differ: \(differing)"))
    }

    // MARK: - palette.js

    private static func parityPalettes(_ bench: VisualizerBench) {
        // GenerateRandomPalette, 100 times from one stream.
        var random = RandomSource.mulberry32(seed: EngineFixtures.paletteSeed)
        var drawn: [Palette] = []
        var drawProblems: [String] = []
        var drawWorst = 0.0
        var randomCount = 0
        for (i, fixture) in EngineFixtures.paletteDraws.enumerated() {
            let palette = Palettes.random(using: &random)
            drawn.append(palette)
            if palette.name != fixture.name || palette.entryCount != fixture.count {
                drawProblems.append("#\(i) \(palette.name)/\(palette.entryCount) vs \(fixture.name)/\(fixture.count)")
                continue
            }
            drawWorst = max(drawWorst, relativeError(checksum(palette.rgba), fixture.checksum))
            if let rgba = fixture.rgba {
                randomCount += 1
                for (j, v) in rgba.enumerated() where j < palette.rgba.count {
                    drawWorst = max(drawWorst, relativeError(Double(palette.rgba[j]), Double(Float(v))))
                }
            }
        }
        bench.check("GenerateRandomPalette", drawProblems.isEmpty && drawWorst <= tolerance,
                    "\(drawn.count) draws, \(randomCount) of them random palettes compared value by value, worst \(sci(drawWorst))"
                        + (drawProblems.isEmpty ? "" : "; " + drawProblems.prefix(3).joined(separator: ", ")))

        // SamplePalette.
        let firstRandom = drawn.first { $0.name == "Random palette" }?.rgba ?? []
        var sampleWorst = 0.0
        for (row, preset) in EngineFixtures.samplePresets.enumerated() {
            let palette = preset >= 0 ? Palettes.deserialize(Palettes.presets[preset]) : firstRandom
            for (k, t) in EngineFixtures.sampleT.enumerated() {
                let c = Palettes.sample(palette, at: t)
                let expected = EngineFixtures.samples[row]
                sampleWorst = max(sampleWorst, relativeError(c.r, expected[k * 3]),
                                  relativeError(c.g, expected[k * 3 + 1]), relativeError(c.b, expected[k * 3 + 2]))
            }
        }
        bench.check("SamplePalette", sampleWorst <= tolerance,
                    "\(EngineFixtures.samplePresets.count) palettes × \(EngineFixtures.sampleT.count) positions (NaN and out of range included), worst \(sci(sampleWorst))")

        // HdrToSdr.
        var hdrWorst = 0.0
        var nanCount = 0
        for (input, output) in EngineFixtures.hdrToSdr {
            let c = Palettes.hdrToSdr(t: input[0], r: input[1], g: input[2], b: input[3], maxRGBInPalette: input[4])
            for (i, v) in [c.x, c.y, c.z].enumerated() {
                if v.isNaN { nanCount += 1 }
                hdrWorst = max(hdrWorst, relativeError(Double(v), Double(Float(output[i]))))
            }
        }
        bench.check("HdrToSdr", hdrWorst <= tolerance,
                    "\(EngineFixtures.hdrToSdr.count) colours, worst \(sci(hdrWorst)); black gives NaN as in the original (\(nanCount) NaN channels)")

        // The preset table survived the copy: every entry parses to its count of colours.
        let broken = Palettes.presets.enumerated().filter { _, text in
            let rgba = Palettes.deserialize(text)
            return rgba.isEmpty || rgba.contains { $0.isNaN }
        }.map(\.offset)
        bench.check("palette table", Palettes.presets.count == 117 && broken.isEmpty,
                    "\(Palettes.presets.count) presets" + (broken.isEmpty ? ", all parse" : ", broken: \(broken)"))
    }

    // MARK: - wave_align.js, linearResampleF

    private static func parityAligner(_ bench: VisualizerBench) {
        var random = RandomSource.mulberry32(seed: EngineFixtures.waveSeed)
        var aligner = WaveAligner()
        var worst = 0.0
        var problems: [String] = []
        for (f, fixture) in EngineFixtures.alignFrames.enumerated() {
            let period = Double(160 + 20 * (f % 3))
            let phase = Double(f * 37)
            var wave = [Float](repeating: 0, count: 2048)
            for i in wave.indices {
                let x = (Double(i) + phase) / period
                let tri = 4 * abs(x - (x + 0.5).rounded(.down)) - 1
                wave[i] = Float(tri * 0.5 + (random.next() - 0.5) * 0.05)
            }
            let aligned = aligner.align(wave, alignFraction: EngineFixtures.alignFractions[f], sampleCount: wave.count)
            if aligned.count != fixture.count {
                problems.append("frame \(f): \(aligned.count) samples, want \(fixture.count)")
                continue
            }
            worst = max(worst, relativeError(checksum(aligned), fixture.checksum))
            for (k, probe) in EngineFixtures.alignProbes.enumerated() {
                let index = probe < 0 ? aligned.count + probe : probe
                worst = max(worst, relativeError(Double(aligned[index]), Double(Float(fixture.probes[k]))))
            }
            let blurred = WaveAligner.blur(aligned, radius: 2)
            worst = max(worst, relativeError(checksum(blurred), fixture.blurChecksum))
            for (k, length) in EngineFixtures.resampleLengths.enumerated() {
                let resampled = WarpEngine.linearResample(blurred, to: length < 0 ? blurred.count : length)
                let expected = fixture.resampled[k]
                if resampled.count != expected.count {
                    problems.append("frame \(f) resample \(length): \(resampled.count) samples, want \(expected.count)")
                }
                worst = max(worst, relativeError(checksum(resampled), expected.checksum))
            }
        }
        bench.check("WaveAligner, Blur, linearResampleF", problems.isEmpty && worst <= tolerance,
                    "\(EngineFixtures.alignFrames.count) frames (align_frac 0.6, then 0.55, then 0.6), "
                        + "\(EngineFixtures.resampleLengths.count) resamples each, worst \(sci(worst))"
                        + (problems.isEmpty ? "" : "; " + problems.prefix(3).joined(separator: ", ")))
    }

    // MARK: - warp.js

    private static func parityAdvect(_ bench: VisualizerBench, maps: [Int: WarpMap]) {
        let fields = EngineFixtures.advectModes.map { maps[$0]?.field.dxy ?? [] }
        let strengths = EngineFixtures.advectStrengths.map { Float($0) }
        let xform = TransformHelper(width: EngineFixtures.advectSize.width, height: EngineFixtures.advectSize.height)
        var worst = 0.0
        for c in EngineFixtures.advectCases {
            let moved = advectPoint(x: c.x, y: c.y, transform: xform, fields: fields, strengths: strengths,
                                    speedMultiplier: c.speed, shiftX: c.shiftX, shiftY: c.shiftY)
            worst = max(worst, relativeError(moved.x, c.outX), relativeError(moved.y, c.outY))
        }
        bench.check("AdvectPoint", worst <= tolerance,
                    "\(EngineFixtures.advectCases.count) points through modes \(EngineFixtures.advectModes), worst \(sci(worst))")
    }

    // MARK: - engine.js

    /// The engine itself, step by step against the original: same seed, same audio, same keys, and
    /// every 60th step's warp strengths, drift, darkening, dots and maps compared. Every map is built on
    /// the spot (nothing waits, so the background builder never delivers), as in the browser run.
    private static func parityEngine(_ bench: VisualizerBench) {
        var random = RandomSource.mulberry32(seed: EngineFixtures.engineSeed)
        let size = EngineFixtures.engineSize
        let renderer = RecordingWarpRenderer(width: size.width, height: size.height)
        let engine = WarpEngine(renderer: renderer, random: &random, workerRandom: .mulberry32(seed: 1))
        _ = random.next()  // the original constructor's random fill of its 1×1 CPU buffer
        engine.randomizeActiveWarpMaps(motionTime: 3, random: &random)

        // The audio: a triangle wave whose period and level change, plus seeded noise.
        var audioRandom = RandomSource.mulberry32(seed: EngineFixtures.engineAudioSeed)
        var samples = EngineFixtures.engineSamples[...]
        var worst = 0.0
        var compared = 0
        var problems: [String] = []
        for s in 0..<EngineFixtures.engineSteps {
            var wave = [Float](repeating: 0, count: AudioFrame.fftSize)
            let period = Double(90 + 30 * (s / 300))
            let level = 0.3 + 0.2 * (Double(s % 97) / 97)
            var sumSquares = 0.0
            var steps = 0.0
            for i in wave.indices {
                let x = (Double(i) + Double(s * 13)) / period
                let tri = 4 * abs(x - (x + 0.5).rounded(.down)) - 1
                wave[i] = Float(tri * level + (audioRandom.next() - 0.5) * 0.02)
                sumSquares += Double(wave[i]) * Double(wave[i])
                if i > 0 { steps += abs(Double(wave[i]) - Double(wave[i - 1])) }
            }
            let frame = AudioFrame(wave: wave, rms: (sumSquares / Double(wave.count)).squareRoot(),
                                   visualEnergy: steps / Double(wave.count - 1), spectrum: [], bandEnergy: [])
            engine.update(dt: 1.0 / 120, audio: frame)
            var step = EngineStep(timeNow: 10 + Double(s) / 120, motionTime: 3 + Double(s) * 0.9 / 120,
                                  waveTime: 5 + Double(s) * 0.9 / 120, shiftTime: 7 + Double(s) * 0.9 / 120, frame: s,
                                  fps: 120, waveSmoothing: 2, beat: s % 60 == 30 ? 0.75 : 0.0, userMotionScale: 1.0,
                                  frozen: false, darkening: 0.0, alignFraction: 0.6)
            step.randomizeMotion = s == 1000
            step.randomizeWave = s == 100
            step.toggleGridDots = s == 200
            step.toggleFadingDots = s == 400 || s == 1700
            step.toggleChasers = s == 500 || s == 520
            step.toggleDottyChaser = s == 600
            step.toggleRandomBeatDots = s == 800
            step.toggleRadialBeatDots = s == 900
            engine.render(step, random: &random)

            guard let expected = samples.first, expected.step == s else { continue }
            samples.removeFirst()
            compared += 1
            let w = renderer.weights
            var error = 0.0
            for i in 0..<4 { error = max(error, relativeError(Double(w[i]), Double(Float(expected.weights[i])))) }
            error = max(error, relativeError(Double(renderer.shift.x), Double(Float(expected.shiftX))),
                        relativeError(Double(renderer.shift.y), Double(Float(expected.shiftY))),
                        relativeError(Double(renderer.darkening), Double(Float(expected.darkening))),
                        relativeError(checksum(renderer.points), expected.dotChecksum))
            worst = max(worst, error)
            if renderer.points.count / 4 != expected.dotCount || renderer.slotOrdinals != expected.slots || error > tolerance {
                problems.append("step \(s): \(renderer.points.count / 4) dots (want \(expected.dotCount)), "
                                + "maps \(renderer.slotOrdinals) (want \(expected.slots)), error \(sci(error))")
            }
        }
        bench.check("engine, step by step", problems.isEmpty && compared == EngineFixtures.engineSamples.count,
                    "\(EngineFixtures.engineSteps) steps, \(compared) compared (strengths, drift, darkening, dots, maps), "
                        + "\(renderer.distinctMaps) maps, \(engine.onDemandBuilds) built on the spot, worst \(sci(worst))"
                        + (problems.isEmpty ? "" : "; first: " + problems.prefix(2).joined(separator: "; ")))
    }

    // MARK: - Robustness and speed

    /// 1,000 maps from 1,000 seeds, every mode in turn (the debug-only 34–38, 98 and 99 too): no NaN,
    /// no infinity, no crash.
    private static func paritySeeds(_ bench: VisualizerBench) {
        let modes = Array(0...38) + [98, 99]
        var bad: [String] = []
        let started = ContinuousClock.now
        for seed in 1...1000 {
            let mode = modes[seed % modes.count]
            var random = RandomSource.mulberry32(seed: UInt32(seed))
            let map = WarpMapBuilder.build(mode: mode, random: &random, id: UInt64(seed))
            let p = map.prefs
            let metadata = [p.netMotion, p.netZoomMotion, p.inOrOutMotion, p.netClockwiseMotion, p.cwOrCcwMotion]
            // A sum is NaN or infinite if any value is; vDSP keeps this fast in the Debug app.
            if !vDSP.sum(map.field.dxy).isFinite || !metadata.allSatisfy(\.isFinite) {
                bad.append("seed \(seed) mode \(mode)")
            }
        }
        bench.check("1,000 random-seed maps", bad.isEmpty,
                    "seeds 1–1000 across \(modes.count) modes in \(String(format: "%.1f", seconds(ContinuousClock.now - started))) s: "
                        + (bad.isEmpty ? "all finite" : "\(bad.count) with NaN or infinity: \(bad.prefix(5))"))
    }

    /// How long one map takes in this (Debug) build, the way the app builds them (bands on all cores),
    /// best of three per mode. Single-threaded times are logged for reference.
    private static func parityMapSpeed(_ bench: VisualizerBench) {
        var times: [(mode: Int, parallel: Double, serial: Double)] = []
        for entry in WarpMapBuilder.catalog {
            var best = Double.infinity
            var bestSerial = Double.infinity
            for run in 0..<3 {
                var random = RandomSource.mulberry32(seed: UInt32(100 + run))
                let start = ContinuousClock.now
                _ = WarpMapBuilder.build(mode: entry.mode, random: &random, id: 1, parallel: true)
                best = min(best, seconds(ContinuousClock.now - start))
            }
            var random = RandomSource.mulberry32(seed: 100)
            let start = ContinuousClock.now
            _ = WarpMapBuilder.build(mode: entry.mode, random: &random, id: 1, parallel: false)
            bestSerial = min(bestSerial, seconds(ContinuousClock.now - start))
            times.append((entry.mode, best, bestSerial))
        }
        let slowest = times.max { $0.parallel < $1.parallel }!
        let slowestSerial = times.max { $0.serial < $1.serial }!
        let mean = times.map(\.parallel).reduce(0, +) / Double(times.count)
        let meanSerial = times.map(\.serial).reduce(0, +) / Double(times.count)
        bench.note("map build times, ms (all cores / one thread): "
                   + times.map { "\($0.mode): \(String(format: "%.1f/%.1f", $0.parallel * 1000, $0.serial * 1000))" }.joined(separator: ", "))
        bench.check("one map ≤ 30 ms", slowest.parallel <= 0.030,
                    "34 modes, mean \(ms(mean)), slowest mode \(slowest.mode) \(ms(slowest.parallel)); "
                        + "one thread: mean \(ms(meanSerial)), slowest mode \(slowestSerial.mode) \(ms(slowestSerial.serial))")
    }

    // MARK: - The driver

    /// 1,200 steps at 120 a second, with synthetic music and the keys pressed along the way, against a
    /// stand-in renderer that checks everything it's handed. Then the step time.
    private static func parityDriver(_ bench: VisualizerBench) async {
        let renderer = MockWarpRenderer(width: 1512, height: 982)
        var now = 1000.0
        let driver = VisualizerDriver(renderer: renderer, now: now, clientSize: (1512, 982), hdrOutput: true,
                                      random: .mulberry32(seed: 2026))
        bench.check("driver starts with four maps", renderer.fieldSlots.count == 0 && driver.engine.activeModes(at: 0).allSatisfy { $0 >= 0 },
                    "slots play modes \(driver.engine.activeModes(at: 0))")

        let audio = SyntheticMusic(seed: 7)
        var frozenDraws = 0
        var pausedMotionTimes: [Double] = []
        var debugModeOK = false
        var hdrRemapOK = false
        var resolutionOK = false
        let steps = 1200
        for i in 0..<steps {
            now += 1.0 / 120
            // The keys, along the way.
            switch i {
            case 100: _ = driver.handle(.randomizeAll)
            case 150...155: _ = driver.handle(.digit(i - 149))  // effects 1–6
            case 200: _ = driver.handle(.toggleFreeze)
            case 260: _ = driver.handle(.escape)
            case 300:
                _ = driver.handle(.toggleDebugKeys)
                _ = driver.handle(.digit(1))
                _ = driver.handle(.digit(4))
            case 301: debugModeOK = driver.engine.activeModes(at: driver.motionTime).first == 14
            case 320: _ = driver.handle(.toggleDebugKeys)
            case 400: _ = driver.handle(.toggleHDR)
            case 401: hdrRemapOK = driver.remapsToSDR && driver.paletteRGBA.allSatisfy { $0 <= 1.0 }
            case 402: _ = driver.handle(.toggleHDR)
            case 500:
                let lower = driver.handle(.lowerResolution)
                if lower.resolutionChanged { renderer.resize(driver.indexSize) }
                let size = driver.indexSize
                resolutionOK = lower.resolutionChanged && size.width < 1512 && size.height < 982
                    && renderer.indexWidth == size.width && renderer.indexHeight == size.height
            case 600:
                let reset = driver.handle(.digit(0))
                if reset.resolutionChanged { renderer.resize(driver.indexSize) }
                resolutionOK = resolutionOK && reset.resolutionChanged && renderer.indexWidth == 1512
            case 700:
                for command in [VisualizerCommand.brighter, .moreDarkening, .biggerWave, .moreSmoothing,
                                .fasterTransitions, .fasterMotion, .togglePaletteLock, .toggleMotionLock,
                                .toggleWaveLock, .randomizePalette, .toggleLockAll, .toggleLockAll, .toggleLockAll,
                                .randomizeMotion, .randomizeWave] {
                    _ = driver.handle(command)
                }
            case 800: driver.musicPaused = true
            case 900: driver.musicPaused = false
            default: break
            }

            let drawsBefore = renderer.steps
            driver.step(at: now, audio: audio.frame(at: now, waveScale: driver.waveScale))
            if driver.frozen && renderer.steps != drawsBefore { frozenDraws += 1 }
            if (801...899).contains(i) { pausedMotionTimes.append(driver.motionTime) }
            // Let background maps arrive, as they would between display frames.
            await Task.yield()
        }

        bench.check("smoke run: every step reached the renderer", renderer.steps >= steps - 60 && renderer.problems.isEmpty,
                    "\(renderer.steps) steps drawn of \(steps) (60 frozen), \(renderer.pointsDrawn / 4) dots, "
                        + "\(renderer.paletteUploads) palette uploads"
                        + (renderer.problems.isEmpty ? "; weights, drift, dots and palettes all finite" : "; " + renderer.problems.prefix(4).joined(separator: "; ")))
        bench.check("smoke run: dots inside the buffer", renderer.stepsWithoutDotsInside == 0,
                    "every drawn step had dots inside \(renderer.indexWidth)×\(renderer.indexHeight); "
                        + "\(String(format: "%.0f", renderer.insideFraction * 100))% of all dots inside")
        bench.check("smoke run: warp maps set", renderer.fieldSlots == [0, 1, 2, 3] && renderer.badFields == 0,
                    "slots \(renderer.fieldSlots.sorted()), \(renderer.distinctFields) distinct maps; "
                        + "background builds \(driver.engine.backgroundBuilds), on-demand \(driver.engine.onDemandBuilds)")
        bench.check("keys: freeze, debug mode, HDR, resolution", frozenDraws == 0 && debugModeOK && hdrRemapOK && resolutionOK,
                    "frozen draws \(frozenDraws), F8 1 4 → mode 14 \(debugModeOK), ⌃H remaps to SDR \(hdrRemapOK), "
                        + "q and 0 resize \(resolutionOK)")
        bench.check("paused music stops the clocks", Set(pausedMotionTimes).count == 1,
                    "motion clock over 99 paused steps: \(Set(pausedMotionTimes).count) value(s)")

        // The 120 Hz rule: a 60 Hz display gets two steps per frame once 50 frames have run.
        let plan = VisualizerDriver(renderer: MockWarpRenderer(width: 640, height: 400), now: 0, clientSize: (640, 400),
                                    hdrOutput: false, random: .mulberry32(seed: 3))
        var t = 0.0
        var extra: [Double] = []
        for _ in 0..<80 {
            t += 1.0 / 60
            plan.beginDisplayFrame(at: t)
            plan.step(at: t, audio: .silent)
            extra = plan.extraStepTimes(firstStepStartedAt: t)
            for time in extra { plan.step(at: time, audio: .silent) }
        }
        bench.check("60 Hz display: two steps per frame", extra.count == 1 && abs((extra.first ?? 0) - t - 1.0 / 120) < 1e-6,
                    "display \(String(format: "%.1f", plan.displayHz)) Hz, extra step at +\(String(format: "%.2f", ((extra.first ?? t) - t) * 1000)) ms, "
                        + "steps/s \(String(format: "%.1f", plan.rendersPerSecond))")

        await parityStepSpeed(bench)
    }

    /// One step's time, against a renderer that does nothing (the checking one runs unoptimized in
    /// this Debug app and would be most of what's measured): 1,200 steps of the synthetic music at 120
    /// a second, leaving out the steps that built a map on the spot.
    private static func parityStepSpeed(_ bench: VisualizerBench) async {
        let renderer = NullWarpRenderer(width: 1512, height: 982)
        var now = 5000.0
        let driver = VisualizerDriver(renderer: renderer, now: now, clientSize: (1512, 982), hdrOutput: true,
                                      random: .mulberry32(seed: 99))
        let audio = SyntheticMusic(seed: 11)
        var stepTimes: [Double] = []
        for i in 0..<1200 {
            now += 1.0 / 120
            if i == 600 { _ = driver.handle(.digit(4)) }  // fading dots on: 1,024 advected points a step
            let frame = audio.frame(at: now, waveScale: driver.waveScale)
            let builds = driver.engine.onDemandBuilds
            let start = ContinuousClock.now
            driver.step(at: now, audio: frame)
            let elapsed = seconds(ContinuousClock.now - start)
            if driver.engine.onDemandBuilds == builds { stepTimes.append(elapsed) }
            await Task.yield()
        }
        stepTimes.sort()
        let mean = stepTimes.reduce(0, +) / Double(max(1, stepTimes.count))
        let median = stepTimes.isEmpty ? 0 : stepTimes[stepTimes.count / 2]
        let p95 = stepTimes.isEmpty ? 0 : stepTimes[stepTimes.count * 95 / 100]
        bench.check("one engine step ≤ 0.5 ms", mean <= 0.0005,
                    "driver step at 1512×982: mean \(ms(mean)), median \(ms(median)), 95th percentile \(ms(p95)) "
                        + "over \(stepTimes.count) steps without a map build; \(renderer.dots / max(1, renderer.steps)) dots a step")
    }
}

/// A WarpRendering that keeps the last step it was handed, and numbers the maps in order of first
/// appearance, as the fixture tool's presenter does.
@MainActor
private final class RecordingWarpRenderer: WarpRendering {
    let indexWidth: Int
    let indexHeight: Int
    private(set) var weights = SIMD4<Float>()
    private(set) var shift = SIMD2<Float>()
    private(set) var points: [Float] = []
    private(set) var darkening: Float = 0
    private(set) var slotOrdinals = [-1, -1, -1, -1]
    private var ordinals: [UInt64: Int] = [:]

    init(width: Int, height: Int) {
        indexWidth = width
        indexHeight = height
    }

    var distinctMaps: Int { ordinals.count }

    func setWarpMap(slot: Int, field: WarpField) {
        if ordinals[field.id] == nil { ordinals[field.id] = ordinals.count }
        if (0..<4).contains(slot) { slotOrdinals[slot] = ordinals[field.id] ?? -1 }
    }

    func warpAndDrawWaveform(weights: SIMD4<Float>, shift: SIMD2<Float>, points: [Float], darkening: Float, time: Float) {
        self.weights = weights
        self.shift = shift
        self.points = points
        self.darkening = darkening
    }

    func uploadPalette(_ rgba: [Float]) {}
}

/// A WarpRendering that does nothing, for timing.
@MainActor
private final class NullWarpRenderer: WarpRendering {
    let indexWidth: Int
    let indexHeight: Int
    private(set) var steps = 0
    private(set) var dots = 0

    init(width: Int, height: Int) {
        indexWidth = width
        indexHeight = height
    }

    func setWarpMap(slot: Int, field: WarpField) {}

    func warpAndDrawWaveform(weights: SIMD4<Float>, shift: SIMD2<Float>, points: [Float], darkening: Float, time: Float) {
        steps += 1
        dots += points.count / 4
    }

    func uploadPalette(_ rgba: [Float]) {}
}

/// A WarpRendering that draws nothing and checks everything it's handed.
@MainActor
private final class MockWarpRenderer: WarpRendering {
    private(set) var indexWidth: Int
    private(set) var indexHeight: Int
    private(set) var steps = 0
    private(set) var pointsDrawn = 0
    private(set) var paletteUploads = 0
    private(set) var stepsWithoutDotsInside = 0
    private(set) var fieldSlots: Set<Int> = []
    private(set) var badFields = 0
    private(set) var problems: [String] = []
    private var fieldIDs: Set<UInt64> = []
    private var dotsInside = 0
    private var dotsTotal = 0

    init(width: Int, height: Int) {
        indexWidth = width
        indexHeight = height
    }

    var distinctFields: Int { fieldIDs.count }
    var insideFraction: Double { dotsTotal == 0 ? 0 : Double(dotsInside) / Double(dotsTotal) }

    func resize(_ size: (width: Int, height: Int)) {
        indexWidth = size.width
        indexHeight = size.height
    }

    private func problem(_ text: String) {
        if problems.count < 20 { problems.append(text) }
    }

    func setWarpMap(slot: Int, field: WarpField) {
        fieldSlots.insert(slot)
        fieldIDs.insert(field.id)
        if field.size != VisualizerConstants.warpMapSize || field.dxy.count != field.size * field.size * 2 || !(0...3).contains(slot) {
            badFields += 1
        }
    }

    func warpAndDrawWaveform(weights: SIMD4<Float>, shift: SIMD2<Float>, points: [Float], darkening: Float, time: Float) {
        steps += 1
        let w = [weights.x, weights.y, weights.z, weights.w]
        if !w.allSatisfy(\.isFinite) { problem("step \(steps): weights \(w)") }
        if !shift.x.isFinite || !shift.y.isFinite { problem("step \(steps): shift \(shift)") }
        if !darkening.isFinite || !time.isFinite { problem("step \(steps): darkening \(darkening), time \(time)") }
        if points.count % 4 != 0 { problem("step \(steps): \(points.count) point values") }
        var inside = 0
        var i = 0
        while i + 3 < points.count {
            let x = points[i], y = points[i + 1], size = points[i + 2], alpha = points[i + 3]
            if !(x.isFinite && y.isFinite && size.isFinite && alpha.isFinite) || size <= 0 || alpha < 0 {
                problem("step \(steps): dot (\(x), \(y), \(size), \(alpha))")
            }
            if x >= 0 && x < Float(indexWidth) && y >= 0 && y < Float(indexHeight) { inside += 1 }
            i += 4
        }
        pointsDrawn += points.count
        dotsInside += inside
        dotsTotal += points.count / 4
        if inside == 0 { stepsWithoutDotsInside += 1 }
    }

    func uploadPalette(_ rgba: [Float]) {
        paletteUploads += 1
        if rgba.count != 256 * 4 || !rgba.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 3 }) {
            problem("palette upload \(paletteUploads): \(rgba.count) values, range \(rgba.min() ?? .nan)…\(rgba.max() ?? .nan)")
        }
    }
}

/// Stand-in music for the smoke run: a bass line and a melody, with a kick every half second that the
/// band levels see as a beat. Shaped like AudioFrameBuilder's output, without an FFT.
private struct SyntheticMusic {
    let seed: UInt64

    func frame(at time: Double, waveScale: Double) -> AudioFrame {
        let n = AudioFrame.fftSize
        let sampleRate = 48_000.0
        let beatPhase = time.truncatingRemainder(dividingBy: 0.5)
        let kick = exp(-beatPhase * 18)
        var wave = [Float](repeating: 0, count: n)
        var sumSquares = 0.0
        var steps = 0.0
        var previous = 0.0
        for i in 0..<n {
            let t = time - Double(n - i) / sampleRate
            let v = (0.35 * sin(2 * .pi * 55 * t) + 0.15 * sin(2 * .pi * 440 * t + sin(t)) + 0.4 * kick * sin(2 * .pi * 70 * t)) * waveScale
            wave[i] = Float(v)
            sumSquares += v * v
            if i > 0 { steps += abs(v - previous) }
            previous = v
        }
        let bass = Float(0.0004 + 0.004 * kick)
        let mid = Float(0.0006 + 0.0002 * sin(time * 3))
        let high = Float(0.0002 + 0.0001 * sin(time * 7))
        return AudioFrame(wave: wave, rms: (sumSquares / Double(n)).squareRoot(), visualEnergy: steps / Double(n - 1) / waveScale,
                          spectrum: [Float](repeating: 0, count: AudioFrame.binCount),
                          bandEnergy: [bass, mid, high, (bass + mid + high) / 3])
    }
}
