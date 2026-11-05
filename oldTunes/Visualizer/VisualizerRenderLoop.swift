import AppKit
import QuartzCore
import VisualizerCore

/// The visualizer's frame loop: the engine (VisualizerDriver, from main.js and engine.js), the Metal
/// renderer (Presenter) and the audio feed, run by a CAMetalDisplayLink on the main thread.
///
/// Each display refresh runs one engine step, or more when the screen is slower than 120 Hz (two at
/// 60 Hz, as the original renders twice per frame there), each with its own slice of audio, then
/// presents into the drawable the link hands over. A CAMetalDisplayLink rather than the view's display
/// link: it gives each update a free drawable, so the main thread never waits in `nextDrawable()`
/// (measured in the render bench: 1.3 ms a frame against 6.5 ms with the waits, in HDR).
@MainActor
final class VisualizerRenderLoop: NSObject {
    let presenter: Presenter
    let driver: VisualizerDriver
    let feed: AudioFeed
    /// The local-volume correction for the audio, read every step.
    var gain: () -> Float = { 1 }
    /// How far behind the present each step reads the audio, in seconds (VisualizerEars.readDelay).
    var audioDelay: () -> CFTimeInterval = { 0 }
    /// Whether the music is paused or stopped, which freezes the animation clocks.
    var musicPaused: () -> Bool = { false }
    /// Called after every frame, for benches.
    var onFrame: (() -> Void)?
    /// The refresh rate the display link asks for. Benches lower it to 60 to try the slower-screen path
    /// (two engine steps a frame) on a 120 Hz screen.
    var preferredFrameRate: Float = 120 {
        didSet { link?.preferredFrameRateRange = Self.frameRateRange(preferredFrameRate) }
    }

    private weak var view: VisualizerView?
    private var link: CAMetalDisplayLink?
    private var hdrAllowed: Bool

    init(view: VisualizerView, ring: SampleRing, hdrAllowed: Bool) throws {
        self.view = view
        self.hdrAllowed = hdrAllowed
        let size = view.bounds.size
        presenter = try Presenter(width: Int(size.width), height: Int(size.height))
        let hdr = hdrAllowed && Presenter.screenSupportsHDR(view.window?.screen)
        driver = VisualizerDriver(renderer: presenter, now: CACurrentMediaTime(),
                                  clientSize: (Double(size.width), Double(size.height)), hdrOutput: hdr)
        feed = AudioFeed(ring: ring)
        super.init()
        presenter.attach(view.metalLayer, hdr: hdr)
        Log.info("visualizer: renderer ready on \(presenter.device.name), \(hdr ? "HDR" : "SDR"), "
                 + "shaders compiled in \(String(format: "%.0f", presenter.shaderCompileSeconds * 1000)) ms")
    }

    var isRunning: Bool { link != nil }

    func start() {
        guard link == nil, let view else { return }
        geometryChanged()
        let link = CAMetalDisplayLink(metalLayer: view.metalLayer)
        link.delegate = self
        link.preferredFrameLatency = 2
        link.preferredFrameRateRange = Self.frameRateRange(preferredFrameRate)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// 120 Hz where the screen can (80 at the least); otherwise exactly the rate asked for.
    private static func frameRateRange(_ rate: Float) -> CAFrameRateRange {
        rate >= 120 ? CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
                    : CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    /// While the window showing the visualizer is covered or minimized, no frames.
    func setPaused(_ paused: Bool) {
        link?.isPaused = paused
    }

    /// The view changed size or screen: the feedback buffer follows the size in points, and HDR the screen.
    /// Nothing while the view is out of a window (turned off, or on its way to or from full screen): it
    /// has no screen then, and would switch to SDR and straight back.
    func geometryChanged() {
        guard let view, view.window != nil else { return }
        let size = view.bounds.size
        driver.clientSize = (Double(size.width), Double(size.height))
        if presenter.presentWidth != Int(size.width) || presenter.presentHeight != Int(size.height)
            || presenter.oversample != driver.oversample {
            presenter.resize(width: Int(size.width), height: Int(size.height), oversample: driver.oversample)
        }
        applyHDR()
    }

    /// Settings ▸ Visualizer ▸ HDR changed.
    func setHDRAllowed(_ allowed: Bool) {
        hdrAllowed = allowed
        applyHDR()
    }

    /// Out of a window, the choice waits for the next `geometryChanged()`; `start()` makes one.
    private func applyHDR() {
        guard let view, let window = view.window else { return }
        let hdr = hdrAllowed && Presenter.screenSupportsHDR(window.screen)
        guard hdr != presenter.usesHDR || presenter.layer == nil else { return }
        presenter.attach(view.metalLayer, hdr: hdr)
        driver.hdrOutput = hdr
        Log.info("visualizer: \(hdr ? "HDR" : "SDR") output")
    }

    /// A key command. Returns what the driver says, after resizing the renderer if the resolution changed.
    func handle(_ command: VisualizerCommand) -> CommandFeedback {
        let feedback = driver.handle(command)
        if feedback.resolutionChanged, let view {
            presenter.resize(width: Int(view.bounds.width), height: Int(view.bounds.height), oversample: driver.oversample)
        }
        return feedback
    }

    // MARK: - Frames

    fileprivate func update(_ update: CAMetalDisplayLink.Update) {
        driver.beginDisplayFrame(at: update.targetPresentationTimestamp)
        driver.musicPaused = musicPaused()
        let start = CACurrentMediaTime()
        driver.step(at: start, audio: audio(endingAt: start))
        let extra = driver.extraStepTimes(firstStepStartedAt: start)
        // The original spin-waits before each extra step and so hears newer audio each time. Here the
        // steps run back to back, so each takes the audio a step-length earlier than the next, ending
        // with the newest.
        for (i, time) in extra.enumerated() {
            let audioTime = start - Double(extra.count - 1 - i) / VisualizerDriver.targetFPS
            driver.step(at: time, audio: audio(endingAt: audioTime))
        }
        presenter.draw(to: update.drawable, paletteSwatchCount: driver.paletteSwatchCount)
        onFrame?()
    }

    private func audio(endingAt seconds: CFTimeInterval) -> AudioFrame {
        feed.frame(endingAt: HostClock.ticks(seconds: seconds - audioDelay()), gain: gain(), waveScale: driver.waveScale)
    }
}

/// CAMetalDisplayLink calls its delegate on the run loop it was added to: the main one.
extension VisualizerRenderLoop: @preconcurrency CAMetalDisplayLinkDelegate {
    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        self.update(update)
    }
}

extension VisualizerCommand {
    /// The visualizer's keys (Geiss HDR's, with R in place of Space, which stays Play/Pause).
    /// Nil for keys it doesn't use, which then go on to oldTunes.
    init?(event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) || modifiers.contains(.option) { return nil }
        if event.keyCode == 100 { self = .toggleDebugKeys; return }   // F8
        if event.keyCode == 53 { self = .escape; return }             // Esc
        guard let key = event.charactersIgnoringModifiers, key.count == 1 else { return nil }
        if modifiers.contains(.control) {
            guard key.lowercased() == "h" else { return nil }
            self = .toggleHDR
            return
        }
        switch key {
        case "p": self = .randomizePalette
        case "P": self = .togglePaletteLock
        case "m": self = .randomizeMotion
        case "M": self = .toggleMotionLock
        case "w": self = .randomizeWave
        case "W": self = .toggleWaveLock
        case "l", "L": self = .toggleLockAll
        case "r", "R": self = .randomizeAll
        case "e": self = .dimmer
        case "E": self = .brighter
        case "d": self = .lessDarkening
        case "D": self = .moreDarkening
        case "j": self = .smallerWave
        case "J": self = .biggerWave
        case "s": self = .lessSmoothing
        case "S": self = .moreSmoothing
        case "[": self = .slowerTransitions
        case "]": self = .fasterTransitions
        case "-", "_": self = .slowerMotion
        case "+", "=": self = .fasterMotion
        case "q": self = .lowerResolution
        case "Q": self = .higherResolution
        case "F": self = .toggleFreeze
        default:
            guard let digit = key.first?.wholeNumberValue else { return nil }
            self = .digit(digit)
        }
    }
}
