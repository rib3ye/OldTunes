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
//  Changed for oldTunes, 2026: the engine part of main.js (Geiss HDR v335), ported to Swift: the
//  clocks and the frame-rate rule of render() and frame(), the palette blend, the band levels and the
//  beat detector, and the key commands as an enum. The song list, help screens, toasts' drawing and
//  palette editing are not ported. Space's "randomize everything" is the R command here. Motion speed
//  starts at 0.25x, a quarter of the original's 1x, and 0 resets it to that.

import Foundation

/// The visualizer's key commands (main.js's keydown handler), as oldTunes maps them. The view turns
/// keys into these; `VisualizerDriver.handle(_:)` carries them out.
public enum VisualizerCommand: Sendable, Equatable {
    /// p, ⇧P: a new palette; lock or unlock the palette.
    case randomizePalette, togglePaletteLock
    /// m, ⇧M: new motion; lock or unlock it.
    case randomizeMotion, toggleMotionLock
    /// w, ⇧W: a new waveform; lock or unlock it.
    case randomizeWave, toggleWaveLock
    /// L: lock everything, or unlock everything if all three are locked.
    case toggleLockAll
    /// R: palette, motion and waveform at once (Space in the original; Space stays Play/Pause).
    case randomizeAll
    /// e, ⇧E: brightness.
    case dimmer, brighter
    /// d, ⇧D: darkening.
    case lessDarkening, moreDarkening
    /// j, ⇧J: wave size.
    case smallerWave, biggerWave
    /// s, ⇧S: wave smoothing.
    case lessSmoothing, moreSmoothing
    /// [ and ]: transition speed.
    case slowerTransitions, fasterTransitions
    /// − and +: motion speed.
    case slowerMotion, fasterMotion
    /// q, ⇧Q: feedback-buffer resolution.
    case lowerResolution, higherResolution
    /// 0 resets the adjustable settings; 1–6 switch effects on and off (radial beat dots, random beat
    /// dots, grid dots, fading dots, chasers, the dotty chaser). With the debug keys on, two digits
    /// pick a motion mode.
    case digit(Int)
    /// ⌃H: HDR on or off (the palette's SDR remap).
    case toggleHDR
    /// ⇧F: freeze the image, or carry on.
    case toggleFreeze
    /// F8: the debug keys.
    case toggleDebugKeys
    /// Esc: unfreezes if frozen. Otherwise it's not used, and the window can take it.
    case escape
}

/// What a command did.
public struct CommandFeedback: Sendable, Equatable {
    /// A short message to show, like the original's toasts; nil for none.
    public var message: String?
    /// Whether the command was used. Only Esc reports false, when there was nothing to unfreeze.
    public var handled: Bool
    /// The feedback buffer's size changed: resize the renderer to `indexSize`.
    public var resolutionChanged: Bool

    public init(message: String?, handled: Bool = true, resolutionChanged: Bool = false) {
        self.message = message
        self.handled = handled
        self.resolutionChanged = resolutionChanged
    }
}

/// The engine part of main.js: everything `render()` does before and around `engine.render(…)`, plus
/// `frame()`'s rule for steps per display frame and the keys' effects. The app owns the display link,
/// the audio and the window; it calls `step` once per engine step.
///
/// Times are seconds on any steady clock (CACurrentMediaTime, a display link's timestamps); only
/// differences matter, and the engine sees them relative to when the driver was made.
@MainActor
public final class VisualizerDriver {
    /// The animation is tuned for this many steps a second.
    public static let targetFPS = 120.0
    static let masterTransitionSpeed = 0.9
    static let paletteHoldMin = WarpSlots.generalTransitionSpeed * 17
    static let paletteHoldMax = WarpSlots.generalTransitionSpeed * 32
    static let paletteBlendMin = WarpSlots.generalTransitionSpeed * 4
    static let paletteBlendMax = WarpSlots.generalTransitionSpeed * 8
    /// Motion speed at the start and after 0 (the original's is 1).
    static let defaultMotionScale = 0.25
    static let minMotionScale = pow(2.0, -10.0)
    static let maxMotionScale = pow(2.0, 4.0)
    static let maxTextureDimension = 8192.0
    static let maxOversample = 4.0
    static let minOversample = 0.25
    /// Indices 0 and 1 drive the beat detector; the last one normalizes.
    static let volumeHalfLives = [0.05, 0.15, 0.5, 30.0]
    static let bandCount = AudioFrame.bands.count
    static let minLevel = 0.00001
    /// Palette colours stop here even on HDR screens that could go brighter; more would hurt.
    static let enforcedMaxValue = 3.0

    public let engine: WarpEngine
    private let renderer: any WarpRendering
    private var random: RandomSource
    private let timeOrigin: Double

    // Clocks, in seconds since the driver was made.
    public private(set) var time = 0.0
    private var prevTime = -1.0 / 90.0
    public private(set) var paletteTime = 0.0
    public private(set) var motionTime = 0.0
    public private(set) var waveTime = 0.0
    public private(set) var shiftTime = 0.0
    public private(set) var frame = 0

    // Steps per second, from the last 180 steps' dt.
    private var frameDtBuffer = [Float](repeating: Float(1.0 / VisualizerDriver.targetFPS), count: 180)
    private var frameDtBufferPos = 0
    public private(set) var rendersPerSecond = VisualizerDriver.targetFPS

    // The display's frame rate, from the last 120 frames.
    public private(set) var displayHz = 0.0
    private var lastDisplayTime = -1.0
    private var displayCalls = 0
    private var displayDtBuffer = [Float](repeating: Float(1.0 / VisualizerDriver.targetFPS), count: 120)
    private var displayDtBufferPos = 0

    // How long a step takes, from the last 120 steps.
    private var stepDurationBuffer = [Float](repeating: Float(1.0 / VisualizerDriver.targetFPS), count: 120)
    private var stepDurationBufferPos = 0
    public private(set) var averageStepSeconds = 1.0 / VisualizerDriver.targetFPS

    // Palettes.
    public private(set) var palette1: Palette
    public private(set) var palette2: Palette?
    private var paletteFadeT0: Double
    private var paletteFadeT1: Double
    /// The 256 RGBA entries last uploaded (after the SDR remap, NaN made 0).
    public private(set) var paletteRGBA = [Float](repeating: 0, count: 256 * 4)

    // Locks and one-step requests.
    public private(set) var paletteLocked = false
    public private(set) var motionLocked = false
    public private(set) var waveLocked = false
    private var randomizeMotionNext = false
    private var randomizeWaveNext = false
    private var toggleGridDotsNext = false
    private var toggleFadingDotsNext = false
    private var toggleChasersNext = false
    private var toggleDottyChaserNext = false
    private var toggleRandomBeatDotsNext = false
    private var toggleRadialBeatDotsNext = false

    // What the keys adjust.
    public private(set) var brightness = 1.0
    public private(set) var darkening = 0.0
    /// Multiply the wave by this when making the AudioFrame (`getFrame({ waveScale })`).
    public private(set) var waveScale = 1.0
    public private(set) var waveSmoothing = 2
    public private(set) var motionScale = VisualizerDriver.defaultMotionScale
    public private(set) var transitionSpeed = 1.0
    /// The feedback buffer is the view's size in points times this (`indexSize`).
    public private(set) var oversample = 1.0
    public private(set) var frozen = false
    public private(set) var debugKeys = false
    public private(set) var alignFraction = 0.6
    private let wavePointSize = -1.0
    private let xyOscilloscopeGap = 96
    private var numbersTyped = -1

    // Band levels and beats.
    private var volImm = [Float](repeating: Float(VisualizerDriver.minLevel * 20), count: VisualizerDriver.bandCount)
    private var volDamped = [[Float]](repeating: [Float](repeating: Float(VisualizerDriver.minLevel * 20), count: VisualizerDriver.bandCount),
                                      count: VisualizerDriver.volumeHalfLives.count)
    private var timeSinceBeat = [Float](repeating: 0, count: VisualizerDriver.bandCount)
    /// The last step's beat, 0 … 1.
    public private(set) var beat = 0.0

    /// The music is paused or stopped: the animation clocks stand still, as in the original's mp3 mode.
    public var musicPaused = false
    /// The renderer shows HDR (the screen can, and Settings allow it). When false the palette is
    /// squeezed into SDR.
    public var hdrOutput: Bool
    /// ⌃H turned HDR off for now.
    public var hdrDisabled = false
    /// The view's size in points, for the resolution keys.
    public var clientSize: (width: Double, height: Double)

    /// Makes the engine as the page does when it starts: the engine module loads, main.js picks its
    /// first palette, then the Engine constructor picks four warp maps. (The constructor's random fill of
    /// its CPU index buffers, unused since the GPU warp, is not ported.) `workerRandom` feeds the
    /// background map builder.
    public init(renderer: any WarpRendering, now: Double, clientSize: (width: Double, height: Double),
                hdrOutput: Bool, random: RandomSource = .fast(), workerRandom: RandomSource = .fast()) {
        var random = random
        self.renderer = renderer
        timeOrigin = now
        self.clientSize = clientSize
        self.hdrOutput = hdrOutput
        engine = WarpEngine(renderer: renderer, random: &random, workerRandom: workerRandom)
        palette1 = Palettes.random(using: &random)
        paletteFadeT0 = 0 + 10
        paletteFadeT1 = 0 + 20
        engine.randomizeActiveWarpMaps(motionTime: 0, random: &random)
        self.random = random
    }

    /// The feedback buffer's size for `clientSize` and `oversample`.
    public var indexSize: (width: Int, height: Int) {
        (toInt32(jsMax(1, (clientSize.width * oversample).rounded(.down))),
         toInt32(jsMax(1, (clientSize.height * oversample).rounded(.down))))
    }

    /// Whether the palette is squeezed into SDR.
    public var remapsToSDR: Bool { !hdrOutput || hdrDisabled }

    /// Palette swatches for the debug overlay: the root palette's entries while the debug keys are on.
    public var paletteSwatchCount: Int { debugKeys ? palette1.entryCount : 0 }

    // MARK: - frame()

    /// Call at the start of each display frame with its timestamp: `frame(t)` keeps the display's
    /// frame rate, for the rule in `extraStepTimes`.
    public func beginDisplayFrame(at timestamp: Double) {
        if lastDisplayTime < 0 {
            lastDisplayTime = timestamp
            return
        }
        let dt = timestamp - lastDisplayTime
        lastDisplayTime = timestamp
        // Ignore long pauses, such as switching windows.
        if dt < 0.1 {
            displayCalls += 1
            displayDtBuffer[displayDtBufferPos] = Float(dt)
            displayDtBufferPos = (displayDtBufferPos + 1) % displayDtBuffer.count
        }
        var sum = 0.0
        var count = 0
        for i in 0..<min(displayDtBuffer.count, displayCalls) {
            sum += Double(displayDtBuffer[i])
            count += 1
        }
        displayHz = 1.0 / (sum / Double(count))
    }

    /// After a display frame's first step: the times of the extra steps that keep the animation at
    /// 120 steps a second when the display is slower (2 steps per frame at 60 Hz). Empty when none are
    /// needed. The original spin-waits until each time; run each step with its time and its own audio.
    public func extraStepTimes(firstStepStartedAt start: Double) -> [Double] {
        let maxRenderHz = 1.0 / averageStepSeconds
        guard frame > 50, displayHz != 0.0, displayHz < Self.targetFPS * 0.65, maxRenderHz > displayHz * 2.5 else {
            return []
        }
        let rendersPerFrame = jsMin(10, jsRound(Self.targetFPS / displayHz - 0.25))
        guard rendersPerFrame > 1 else { return [] }
        let idealTimeBetweenRenders = 1.0 / (displayHz * rendersPerFrame)
        return (1..<Int(rendersPerFrame)).map { start + Double($0) * idealTimeBetweenRenders }
    }

    // MARK: - render()

    /// One engine step at time `now`, with the audio for that moment (made with `waveScale`).
    public func step(at now: Double, audio: AudioFrame) {
        let started = ContinuousClock.now

        prevTime = time
        time = now - timeOrigin
        if frame == 0 {
            // The first frame is slow with setting up; pretend it took a normal frame.
            prevTime = time - 1.0 / 60
        }
        let dt = jsMin(0.2, jsMax(0.001, time - prevTime))
        let freezeClocks = musicPaused || frozen
        if !paletteLocked && !freezeClocks {
            paletteTime += dt * transitionSpeed * Self.masterTransitionSpeed
        }
        if !motionLocked && !freezeClocks {
            motionTime += dt * transitionSpeed * Self.masterTransitionSpeed
        }
        if !waveLocked && !freezeClocks {
            waveTime += dt * transitionSpeed * Self.masterTransitionSpeed
        }
        // The drift may slow down, but not speed up.
        shiftTime += dt * jsMin(transitionSpeed * Self.masterTransitionSpeed, 1.0)

        // Steps per second, from a ring of dt values.
        do {
            frameDtBuffer[frameDtBufferPos] = Float(dt)
            frameDtBufferPos = (frameDtBufferPos + 1) % frameDtBuffer.count
            var dtSum = 0.0
            for v in frameDtBuffer { dtSum += Double(v) }
            let renders = 1.0 / (dtSum / Double(frameDtBuffer.count))
            rendersPerSecond = rendersPerSecond * 0.95 + 0.05 * renders
        }

        if frame == 0 {
            // The first palette.
            palette1 = Palettes.random(using: &random)
            palette2 = nil
            setPaletteBlendTimes()
        }

        updatePalette()

        // Levels, then beats.
        for b in 0..<Self.bandCount {
            // The spectrum was already made perceptually even.
            volImm[b] = Float(jsMax(Self.minLevel, audio.bandEnergy.js(b)))
        }
        updateDampedVolumes(dt: dt)
        beat = detectBeat(dt: dt)

        engine.update(dt: dt, audio: audio)
        var engineStep = EngineStep(timeNow: time, motionTime: motionTime, waveTime: waveTime, shiftTime: shiftTime,
                                    frame: frame, fps: rendersPerSecond, waveSmoothing: waveSmoothing, beat: beat,
                                    userMotionScale: motionScale, frozen: frozen, darkening: darkening,
                                    alignFraction: alignFraction)
        engineStep.randomizeMotion = randomizeMotionNext
        engineStep.randomizeWave = randomizeWaveNext
        engineStep.userWavePointSize = wavePointSize
        engineStep.xyOscilloscopeGap = xyOscilloscopeGap
        engineStep.toggleGridDots = toggleGridDotsNext
        engineStep.toggleFadingDots = toggleFadingDotsNext
        engineStep.toggleChasers = toggleChasersNext
        engineStep.toggleDottyChaser = toggleDottyChaserNext
        engineStep.toggleRandomBeatDots = toggleRandomBeatDotsNext
        engineStep.toggleRadialBeatDots = toggleRadialBeatDotsNext
        engine.render(engineStep, random: &random)
        randomizeMotionNext = false
        randomizeWaveNext = false
        toggleGridDotsNext = false
        toggleFadingDotsNext = false
        toggleRandomBeatDotsNext = false
        toggleRadialBeatDotsNext = false
        toggleChasersNext = false
        toggleDottyChaserNext = false

        frame += 1

        // How long steps take, for the extra-steps rule.
        let elapsed = ContinuousClock.now - started
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        stepDurationBuffer[stepDurationBufferPos] = Float(seconds)
        stepDurationBufferPos = (stepDurationBufferPos + 1) % stepDurationBuffer.count
        var sum = 0.0
        var count = 0
        for i in 0..<min(stepDurationBuffer.count, frame) {
            sum += Double(stepDurationBuffer[i])
            count += 1
        }
        averageStepSeconds = sum / Double(count)
    }

    // MARK: - Palette

    /// `SetPaletteBlendTimes()`: hold this palette 17–32 s, then blend to the next over 4–8 s.
    private func setPaletteBlendTimes() {
        let holdTime = Self.paletteHoldMin + (Self.paletteHoldMax - Self.paletteHoldMin) * random.next()
        let blendTime = Self.paletteBlendMin + (Self.paletteBlendMax - Self.paletteBlendMin) * random.next()
        paletteFadeT0 = paletteTime + holdTime
        paletteFadeT1 = paletteFadeT0 + blendTime
    }

    /// `GetCurrentPaletteBlend()`: how far into the blend to the next palette, smoothstepped.
    private func currentPaletteBlend() -> Double {
        let t = jsMax(0, jsMin(1, (paletteTime - paletteFadeT0) / (paletteFadeT1 - paletteFadeT0)))
        return smoothstep(t)
    }

    /// The animated blend between the two palettes, sampled into 256 entries, scaled by the
    /// brightness, held at 3, squeezed into SDR when needed, and uploaded.
    private func updatePalette() {
        var t = currentPaletteBlend()
        if t > 0.0 && palette2 == nil {
            palette2 = Palettes.random(using: &random)
        }
        if t >= 1.0, let next = palette2 {
            // Start blending to a new palette.
            palette1 = next
            palette2 = nil
            setPaletteBlendTimes()
            t = 0
        }

        var rgba = [Float](repeating: 0, count: 256 * 4)
        if t < 0.00001 || palette2 == nil {
            // Palette 1 only.
            for i in 0..<256 {
                let s = Double(i) * (1.0 / 255.0)
                let color = Palettes.sample(palette1.rgba, at: s)
                rgba[i * 4 + 0] = Float(color.r)
                rgba[i * 4 + 1] = Float(color.g)
                rgba[i * 4 + 2] = Float(color.b)
                rgba[i * 4 + 3] = 1.0
            }
        } else if let palette2 {
            // A blend of the two.
            for i in 0..<256 {
                let s = Double(i) * (1.0 / 255.0)
                let color1 = Palettes.sample(palette1.rgba, at: s)
                let color2 = Palettes.sample(palette2.rgba, at: s)
                rgba[i * 4 + 0] = Float(color1.r * (1 - t) + color2.r * t)
                rgba[i * 4 + 1] = Float(color1.g * (1 - t) + color2.g * t)
                rgba[i * 4 + 2] = Float(color1.b * (1 - t) + color2.b * t)
                rgba[i * 4 + 3] = 1.0
            }
        }

        // Brightness, the cap at 3, and the brightest value.
        var maxValue = 0.0
        for i in 0..<256 {
            var r = Double(rgba[i * 4 + 0]) * brightness
            var g = Double(rgba[i * 4 + 1]) * brightness
            var b = Double(rgba[i * 4 + 2]) * brightness
            r = jsMin(r, Self.enforcedMaxValue)
            g = jsMin(g, Self.enforcedMaxValue)
            b = jsMin(b, Self.enforcedMaxValue)
            rgba[i * 4 + 0] = Float(r)
            rgba[i * 4 + 1] = Float(g)
            rgba[i * 4 + 2] = Float(b)
            rgba[i * 4 + 3] = 1.0
            maxValue = jsMax(jsMax(r, g), jsMax(b, maxValue))
        }

        if remapsToSDR {
            for i in 0..<256 {
                let t = Double(i) * (1.0 / 255)
                let col = Palettes.hdrToSdr(t: t, r: Double(rgba[i * 4 + 0]), g: Double(rgba[i * 4 + 1]),
                                            b: Double(rgba[i * 4 + 2]), maxRGBInPalette: maxValue)
                rgba[i * 4 + 0] = col.x
                rgba[i * 4 + 1] = col.y
                rgba[i * 4 + 2] = col.z
            }
        }

        // HdrToSdr makes black NaN; the original's upload turns NaN into 0. Do that here, so the
        // renderer only ever sees numbers.
        for i in rgba.indices where rgba[i].isNaN {
            rgba[i] = 0
        }
        paletteRGBA = rgba
        renderer.uploadPalette(rgba)
    }

    /// `GetCurrentPaletteDesc()`.
    public var paletteDescription: String {
        let t = currentPaletteBlend()
        if t > 0.0001, let palette2 {
            let percent = toInt32(t * 100 + 0.5)
            return "Blend of \(palette1.name) (\(100 - percent)%) and \(palette2.name) (\(percent)%)"
        }
        return palette1.name
    }

    /// The debug overlay's lines: the slots, the blended motion and the palette.
    public func debugLines() -> [String] {
        engine.motionDebugLines(motionTime: motionTime) + [paletteDescription]
    }

    // MARK: - Levels and beats

    /// `UpdateDampedVolumes(frame_number, dt)`: four smoothed copies of each band level, with half-lives
    /// of 0.05, 0.15, 0.5 and 30 s; plain averages for the first two seconds.
    private func updateDampedVolumes(dt: Double) {
        let fps = 1.0 / dt
        for v in 0..<Self.volumeHalfLives.count {
            let halfLife = Self.volumeHalfLives[v]
            let initFrameCount = fps * 2.0
            for b in 0..<Self.bandCount {
                var updateStrength = 1.0
                if Double(frame) < initFrameCount {
                    // An average over the first frames.
                    updateStrength = 1.0 / jsMax(1, Double(frame + 1))
                } else {
                    // Exactly the half-life at this frame rate.
                    updateStrength = 1.0 - pow(0.5, dt / halfLife)
                }
                volDamped[v][b] = Float(updateStrength * Double(volImm[b]) + (1.0 - updateStrength) * Double(volDamped[v][b]))
            }
        }
    }

    /// The beat detector, over the bass, mid and high bands: a beat is the fast level jumping above
    /// the slower one, relative to the half-second level (or a tenth of the 30-second one), at most
    /// every 0.1 s per band.
    private func detectBeat(dt: Double) -> Double {
        var beat = 0.0
        for b in 0..<3 {
            timeSinceBeat[b] = Float(Double(timeSinceBeat[b]) + dt)
            let vol005 = Double(volDamped[0][b])
            let vol015 = Double(volDamped[1][b])
            let vol050 = Double(volDamped[2][b])
            let vol30 = Double(volDamped[Self.volumeHalfLives.count - 1][b])
            let baseline = jsMax(jsMax(vol050, 0.1 * vol30), Self.minLevel)
            let onset = jsMax(0, vol005 - vol015) / baseline
            let triggerThreshold = 0.5
            let suppressSeconds = 0.1
            if onset > triggerThreshold && Double(timeSinceBeat[b]) > suppressSeconds {
                beat = jsMax(beat, jsMin(1.0, (onset / triggerThreshold) - 1.0))
                timeSinceBeat[b] = 0.0
            }
        }
        return beat
    }

    // MARK: - Keys

    /// Carries out a key command, as main.js's keydown handler does.
    public func handle(_ command: VisualizerCommand) -> CommandFeedback {
        switch command {
        case .randomizePalette:
            let message = paletteLocked ? "Can't randomize palette; press ⇧P to unlock first" : nil
            randomizePalette()
            return CommandFeedback(message: message)
        case .togglePaletteLock:
            paletteLocked.toggle()
            return CommandFeedback(message: paletteLocked ? "Palette locked" : "Palette unlocked")
        case .randomizeMotion:
            let message = motionLocked ? "Can't randomize motion; press ⇧M to unlock first" : nil
            randomizeMotion()
            return CommandFeedback(message: message)
        case .toggleMotionLock:
            motionLocked.toggle()
            return CommandFeedback(message: motionLocked ? "Motion locked" : "Motion unlocked")
        case .randomizeWave:
            let message = waveLocked ? "Can't randomize waveform; press ⇧W to unlock first" : nil
            randomizeWave()
            return CommandFeedback(message: message)
        case .toggleWaveLock:
            waveLocked.toggle()
            return CommandFeedback(message: waveLocked ? "Waveform locked" : "Waveform unlocked")
        case .toggleLockAll:
            if paletteLocked && waveLocked && motionLocked {
                paletteLocked = false
                waveLocked = false
                motionLocked = false
                return CommandFeedback(message: "Everything unlocked")
            }
            paletteLocked = true
            waveLocked = true
            motionLocked = true
            return CommandFeedback(message: "Everything locked")
        case .randomizeAll:
            let message = (paletteLocked && waveLocked && motionLocked) ? "Can't randomize anything; press L to unlock first" : nil
            randomizePalette()
            randomizeMotion()
            randomizeWave()
            return CommandFeedback(message: message)
        case .dimmer, .brighter:
            brightness *= pow(2.0, command == .dimmer ? -0.1 : 0.1)
            return CommandFeedback(message: "Brightness adjusted to \(Self.fixed(brightness, 2))x")
        case .lessDarkening, .moreDarkening:
            darkening += command == .lessDarkening ? -0.1 : 0.1
            darkening = jsMax(-1.0, jsMin(1.0, darkening))
            return CommandFeedback(message: "Darkening adjusted to \(Self.fixed(darkening, 1))x")
        case .smallerWave, .biggerWave:
            waveScale *= pow(2.0, (command == .smallerWave ? -1.0 : 1.0) / 3)
            return CommandFeedback(message: "Wave scale set to \(Self.fixed(waveScale, 3))")
        case .lessSmoothing:
            waveSmoothing = max(0, waveSmoothing - 1)
            return CommandFeedback(message: "Wave smoothing adjusted to \(waveSmoothing)")
        case .moreSmoothing:
            waveSmoothing = min(32, waveSmoothing + 1)
            return CommandFeedback(message: "Wave smoothing adjusted to \(waveSmoothing)")
        case .slowerTransitions:
            transitionSpeed *= pow(2.0, -0.5)
            transitionSpeed = jsMax(transitionSpeed, pow(2.0, -17))
            return CommandFeedback(message: transitionSpeedMessage("adjusted"))
        case .fasterTransitions:
            transitionSpeed *= pow(2.0, 0.5)
            transitionSpeed = jsMin(transitionSpeed, 16.0)
            return CommandFeedback(message: transitionSpeedMessage("adjusted"))
        case .slowerMotion, .fasterMotion:
            motionScale *= pow(2.0, command == .slowerMotion ? -0.25 : 0.25)
            motionScale = jsMax(Self.minMotionScale, jsMin(Self.maxMotionScale, motionScale))
            return CommandFeedback(message: "Motion speed adjusted to \(Self.fixed(motionScale, 3))x")
        case .lowerResolution:
            guard oversample > Self.minOversample else { return CommandFeedback(message: nil) }
            let old = oversample
            if oversample > 1.99 {
                oversample -= 1.0
            } else {
                var scale = 1.0 / oversample
                scale += 0.5
                oversample = jsMax(Self.minOversample, 1.0 / scale)
            }
            return oversample != old ? newOversample(from: old) : CommandFeedback(message: nil)
        case .higherResolution:
            let maxOversample = jsMin(Self.maxOversample, (Self.maxTextureDimension / clientSize.width).rounded(.down))
            guard oversample < maxOversample else { return CommandFeedback(message: nil) }
            let old = oversample
            if oversample > 0.99 {
                oversample += 1.0
            } else {
                var scale = 1.0 / oversample
                scale -= 0.5
                oversample = jsMin(maxOversample, 1.0 / scale)
            }
            return oversample != old ? newOversample(from: old) : CommandFeedback(message: nil)
        case .digit(let number):
            return digit(number)
        case .toggleHDR:
            guard hdrOutput else { return CommandFeedback(message: "This screen can't show HDR") }
            hdrDisabled.toggle()
            return CommandFeedback(message: hdrDisabled ? "HDR disabled" : "HDR enabled")
        case .toggleFreeze:
            frozen.toggle()
            return CommandFeedback(message: frozen ? "Image frozen for study" : "Animation resumed")
        case .toggleDebugKeys:
            debugKeys.toggle()
            return CommandFeedback(message: debugKeys ? "Debugging keys enabled" : "Debugging keys disabled")
        case .escape:
            guard frozen else { return CommandFeedback(message: nil, handled: false) }
            frozen = false
            return CommandFeedback(message: "Animation resumed")
        }
    }

    /// `OnNumberKey(number)`.
    private func digit(_ number: Int) -> CommandFeedback {
        if debugKeys {
            if numbersTyped == -1 {
                numbersTyped = number
                return CommandFeedback(message: nil)
            }
            let mode = numbersTyped * 10 + number
            numbersTyped = -1
            engine.setMotionModeDebug(mode, motionTime: motionTime, random: &random)
            return CommandFeedback(message: "Set motion mode to \(mode)")
        }
        switch number {
        case 0: return resetAdjustableParameters()
        case 1: toggleRadialBeatDotsNext = true
        case 2: toggleRandomBeatDotsNext = true
        case 3: toggleGridDotsNext = true
        case 4: toggleFadingDotsNext = true
        case 5: toggleChasersNext = true
        case 6: toggleDottyChaserNext = true
        default: break
        }
        return CommandFeedback(message: nil)
    }

    /// `ResetAdjustableParameters()`: the 0 key.
    private func resetAdjustableParameters() -> CommandFeedback {
        var messages: [String] = []
        var resolutionChanged = false
        if abs(darkening - 0.0) > 0.0001 {
            darkening = 0.0
            messages.append("Darkening reset to \(Self.fixed(darkening, 1))x")
        }
        if abs(transitionSpeed - 1.0) > 0.0001 {
            transitionSpeed = 1.0
            messages.append(transitionSpeedMessage("reset"))
        }
        if abs(motionScale - Self.defaultMotionScale) > 0.0001 {
            motionScale = Self.defaultMotionScale
            messages.append("Motion speed reset to \(Self.fixed(motionScale, 3))x")
        }
        if abs(brightness - 1.0) > 0.0001 {
            brightness = 1.0
            messages.append("Brightness reset to \(Self.fixed(brightness, 2))x")
        }
        if abs(waveScale - 1.0) > 0.0001 {
            waveScale = 1.0
            messages.append("Wave scale reset to \(Self.fixed(waveScale, 3))")
        }
        if abs(oversample - 1.0) > 0.0001 {
            let old = oversample
            oversample = 1.0
            resolutionChanged = true
            if let message = newOversample(from: old).message { messages.append(message) }
        }
        if messages.isEmpty {
            return CommandFeedback(message: "(Nothing more to reset)")
        }
        return CommandFeedback(message: messages.joined(separator: "\n"), resolutionChanged: resolutionChanged)
    }

    /// `OnNewOversample(old, new)`: the app resizes the renderer to `indexSize`.
    private func newOversample(from old: Double) -> CommandFeedback {
        let size = indexSize
        let verb = oversample > old ? "increased" : "decreased"
        return CommandFeedback(message: "Resolution \(verb) to \(size.width) x \(size.height) (\(Self.fixed(oversample, 2))x)",
                               resolutionChanged: true)
    }

    private func transitionSpeedMessage(_ verb: String) -> String {
        "Transition speed \(verb) to \(Self.fixed(transitionSpeed, transitionSpeed < 1.0 ? 5 : 1))x"
    }

    /// `RandomizePalette()`.
    private func randomizePalette() {
        guard !paletteLocked else { return }
        paletteTime = random.next() * 10000
        palette1 = Palettes.random(using: &random)
        palette2 = nil
        setPaletteBlendTimes()
    }

    /// `RandomizeMotion()`: jumps the motion clock; the next step cuts to four new maps.
    private func randomizeMotion() {
        guard !motionLocked else { return }
        motionTime = random.next() * 10000
        randomizeMotionNext = true
    }

    /// `RandomizeWave()`.
    private func randomizeWave() {
        guard !waveLocked else { return }
        waveTime = random.next() * 10000
        randomizeWaveNext = true
    }

    /// `x.toFixed(digits)`.
    static func fixed(_ x: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", x)
    }
}
