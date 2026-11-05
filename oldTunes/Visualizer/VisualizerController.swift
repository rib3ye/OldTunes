import AppKit
import QuartzCore
import VisualizerCore

/// The visualizer as a whole: on and off, inline in the track pane or full screen, its ears
/// (SelfCapture, and the silence watchdog: VisualizerAudio) and its picture (VisualizerRenderLoop:
/// engine, renderer, display link). AppController owns one and wires it to the button, the
/// Visualizer menu and the Space bar.
///
/// It needs macOS 14.4, the first that lets an app capture its own sound with no permission
/// (SelfCapture, which hears iCloud songs as well as files); below that `isSupported` is false and
/// AppController leaves the button dimmed and the menu out. oldTunes never uses System Audio
/// Recording, so there is no other way for it to listen. Off at every launch. The ears exist only
/// while it is on; the renderer is made the first time and kept, so turning it on again doesn't
/// recompile the shaders.
@MainActor
final class VisualizerController: NSObject {
    static var isSupported: Bool {
        if #available(macOS 14.4, *) { return true } else { return false }
    }

    private(set) var isOn = false
    var isFullScreen: Bool { fullScreenWindow != nil }
    /// Benches set this so the tap silences what it hears; the app never does.
    var tapMuted = false
    /// Called after the visualizer turns on or off, or enters or leaves full screen.
    var onStateChange: (() -> Void)?
    /// Called after every frame drawn, for benches.
    var onFrame: (() -> Void)? {
        didSet { renderLoop?.onFrame = onFrame }
    }
    /// A key the visualizer has no use for, such as an arrow: AppController plays the previous or
    /// next song, or changes the volume, as iTunes 4's visualizer did. Return true when used.
    var onUnusedKey: ((NSEvent) -> Bool)?

    let ring = SampleRing()
    private let player: PlaybackCoordinator
    private let inlineHost: NSView
    private let listView: NSView
    private(set) var view: VisualizerView?
    private(set) var renderLoop: VisualizerRenderLoop?
    private var fullScreenWindow: VisualizerFullScreenWindow?
    /// The ears and the watchdog (VisualizerAudio), which exist only on macOS 14.4 and later.
    private(set) var audio: AnyObject?
    private var observers: [NSObjectProtocol] = []

    /// `inlineHost` is the track pane's container; `listView` is the track list it holds, hidden while
    /// the visualizer shows in its place.
    init(player: PlaybackCoordinator, inlineHost: NSView, listView: NSView) {
        self.player = player
        self.inlineHost = inlineHost
        self.listView = listView
        super.init()
    }

    var fullScreenWindowForKeys: NSWindow? { fullScreenWindow }

    func toggle() { setOn(!isOn) }

    func setOn(_ on: Bool) {
        guard Self.isSupported, on != isOn else { return }
        isOn = on
        if on {
            let view = self.view ?? makeView()
            placeInline(view)
            startAudio()
            startPicture(in: view)
            Log.info("visualizer: on")
        } else {
            if let window = fullScreenWindow {
                window.onExit = nil
                window.leave()
                fullScreenWindow = nil
            }
            stopPicture()
            stopAudio()
            view?.removeFromSuperview()
            listView.isHidden = false
            Log.info("visualizer: off")
        }
        onStateChange?()
    }

    /// ⇧⌘F: full screen, turning the visualizer on first if needed; again, back to the window.
    func toggleFullScreen() {
        guard Self.isSupported else { return }
        if let window = fullScreenWindow {
            window.leave()
            return
        }
        if !isOn { setOn(true) }
        guard let view else { return }
        let window = VisualizerFullScreenWindow(on: inlineHost.window?.screen)
        window.onExit = { [weak self] in self?.fullScreenEnded() }
        fullScreenWindow = window
        view.removeFromSuperview()
        listView.isHidden = false
        window.present(view)
        Log.info("visualizer: full screen")
        onStateChange?()
    }

    func toggleKeyList() {
        view?.toggleKeyList()
    }

    // MARK: - The view

    private func makeView() -> VisualizerView {
        let view = VisualizerView(frame: inlineHost.bounds)
        view.autoresizingMask = [.width, .height]
        view.onEscape = { [weak self] in self?.fullScreenWindow?.leave() }
        view.onClick = { [weak self] in self?.fullScreenWindow?.leave() }
        view.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        view.onGeometryChange = { [weak self] in
            self?.renderLoop?.geometryChanged()
            self?.updatePause()
        }
        self.view = view
        return view
    }

    private func placeInline(_ view: VisualizerView) {
        view.frame = inlineHost.bounds
        inlineHost.addSubview(view)
        listView.isHidden = true
        inlineHost.window?.makeFirstResponder(view)
    }

    private func fullScreenEnded() {
        fullScreenWindow = nil
        Log.info("visualizer: back in the window")
        if isOn, let view {
            view.removeFromSuperview()
            placeInline(view)
            inlineHost.window?.makeKeyAndOrderFront(nil)
        }
        onStateChange?()
    }

    /// The visualizer's own keys: H for the key list here, the rest to the engine. Esc goes to the engine
    /// first (it unfreezes); when there is nothing to unfreeze, the view uses it to leave full screen.
    /// Keys the engine doesn't use go to `onUnusedKey`.
    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.charactersIgnoringModifiers?.lowercased() == "h", modifiers.subtracting(.shift).isEmpty {
            view?.toggleKeyList()
            return true
        }
        guard let renderLoop, let command = VisualizerCommand(event: event) else { return onUnusedKey?(event) ?? false }
        let feedback = renderLoop.handle(command)
        if let message = feedback.message { view?.showToast(message) }
        return feedback.handled
    }

    // MARK: - Ears

    private func startAudio() {
        guard #available(macOS 14.4, *) else { return }
        let audio = (self.audio as? VisualizerAudio)
            ?? VisualizerAudio(ring: ring, player: player, muted: tapMuted) { [weak self] hint in
                self?.view?.showHint(hint)
            }
        self.audio = audio
        audio.start()
    }

    private func stopAudio() {
        guard #available(macOS 14.4, *), let audio = audio as? VisualizerAudio else { return }
        audio.stop()
        view?.showHint(nil)
    }

    /// What the AudioFeed multiplies by: the ears hear a song after oldTunes's own volume (a file's in
    /// AVPlayer, an iCloud song's in RemotePlayerService: CloudVolume), so it is undone and the picture
    /// doesn't shrink with the slider. An iCloud song oldTunes can't set the level of plays at its own.
    /// The Mac's volume applies after the ears either way.
    var feedGain: Float {
        let followsSlider = player.local.isPlaying || (player.cloud.isPlaying && player.cloud.ownsVolume)
        return followsSlider ? 1 / max(player.appVolume, 0.05) : 1
    }

    /// How far behind the present the renderer reads the audio: the ears in use say.
    var audioDelay: TimeInterval {
        guard #available(macOS 14.4, *), let audio = audio as? VisualizerAudio else { return 0 }
        return audio.ears.readDelay
    }

    // MARK: - Picture

    private func startPicture(in view: VisualizerView) {
        if let renderLoop {
            // The observer below exists only while it is on, so Settings may have changed while it was off.
            renderLoop.setHDRAllowed(VisualizerPreference.currentHDR)
        } else {
            do {
                let loop = try VisualizerRenderLoop(view: view, ring: ring, hdrAllowed: VisualizerPreference.currentHDR)
                loop.gain = { [weak self] in self?.feedGain ?? 1 }
                loop.audioDelay = { [weak self] in self?.audioDelay ?? 0 }
                loop.musicPaused = { [weak self] in !(self?.player.state.isPlaying ?? false) }
                loop.onFrame = onFrame
                renderLoop = loop
            } catch {
                Log.error("visualizer: the renderer could not start: \(error)")
                view.showToast("The visualizer couldn't start: \(error)")
                return
            }
        }
        renderLoop?.start()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePause() }
            },
            center.addObserver(forName: VisualizerPreference.didChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.renderLoop?.setHDRAllowed(VisualizerPreference.currentHDR) }
            },
        ]
        updatePause()
    }

    private func stopPicture() {
        renderLoop?.stop()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    /// No frames while the window showing the visualizer is hidden, minimized or covered.
    private func updatePause() {
        let visible = view?.window?.occlusionState.contains(.visible) ?? false
        renderLoop?.setPaused(!visible)
    }
}

/// The visualizer's ears and their watchdog, kept together.
///
/// The app listens through SelfCapture: ScreenCaptureKit capturing oldTunes itself, which hears its
/// files and its iCloud songs (the RemotePlayerService that plays them counts as part of oldTunes)
/// and needs no permission. macOS counts it as sharing the screen while it runs, so the menu bar may
/// show its screen-sharing icon. The test benches listen through a process tap (MusicAudioTap)
/// instead, because only a tap can mute what it hears. A tap needs System Audio Recording, which the
/// app never uses, and the build that ships leaves MusicAudioTap out (project.yml). Debug builds can
/// pick either with OLDTUNES_VIS_EARS.
///
/// Ears that hear only zeros while a song plays are rebuilt, then the watchdog's can't-hear hint
/// shows, and they are rebuilt every 30 s while it does. SelfCapture stopped with the menu bar's Stop
/// button stays stopped until the visualizer is turned on again, and a hint says so.
@available(macOS 14.4, *)
@MainActor
final class VisualizerAudio {
    enum Source: String {
        case tap = "process tap"
        case selfCapture = "self-capture"
    }

    let watchdog: TapWatchdog
    let source: Source
    let selfCapture: SelfCapture
    #if BENCHES
    /// The benches' ears, made only when they are the ones used.
    private(set) var tap: MusicAudioTap?

    /// Debug and Bench builds: OLDTUNES_VIS_EARS=tap or self-capture picks the ears outside the
    /// benches (benches always tap).
    private static let forcedSource = LaunchEnvironment.value("OLDTUNES_VIS_EARS").flatMap { value in
        value == "tap" ? Source.tap : value.replacingOccurrences(of: "-", with: "") == "selfcapture" ? Source.selfCapture : nil
    }
    #endif
    /// Starting the ears waits (off the main thread, and for a tap's permission prompt the first time
    /// one is made), so it runs in a task. `stop()` cancels it: turned off before the task got going,
    /// nothing starts.
    private var starting: Task<Void, Never>?
    private let onHint: (SilenceWatchdog.Hint?) -> Void

    /// `muted`: benches only; the tap then silences what it hears. The app never mutes.
    init(ring: SampleRing, player: PlaybackControlling, muted: Bool, onHint: @escaping (SilenceWatchdog.Hint?) -> Void) {
        let selfCapture = SelfCapture(ring: ring)
        self.selfCapture = selfCapture
        #if BENCHES
        let source = Self.choose(bench: LaunchEnvironment.bench != nil, muted: muted, forced: Self.forcedSource)
        let tap = source == .tap ? MusicAudioTap(ring: ring, muted: muted) : nil
        self.source = source
        self.tap = tap
        let ears: any VisualizerEars
        if let tap { ears = tap } else { ears = selfCapture }
        watchdog = TapWatchdog(tap: ears, player: player)
        #else
        source = .selfCapture
        watchdog = TapWatchdog(tap: selfCapture, player: player)
        #endif
        self.onHint = onHint
        selfCapture.onStoppedByUser = { [weak self] in self?.selfCaptureStoppedByUser() }
        watchdog.onHint = { [weak self] hint in self?.onHint(hint) }
    }

    /// The rule in the type's comment, apart from the build: the benches and muted ears tap; otherwise
    /// OLDTUNES_VIS_EARS says, else SelfCapture. On its own for the selfcapture bench.
    nonisolated static func choose(bench: Bool, muted: Bool, forced: Source?) -> Source {
        bench || muted ? .tap : forced ?? .selfCapture
    }

    /// The ears in use.
    var ears: any VisualizerEars {
        #if BENCHES
        if let tap { return tap }
        #endif
        return selfCapture
    }

    func start() {
        onHint(nil)
        watchdog.watch(ears)
        Log.info("visualizer: hearing the music through the \(source.rawValue)")
        starting?.cancel()
        starting = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.ears.start()
            guard !Task.isCancelled else { return }
            self.watchdog.start()
        }
    }

    func stop() {
        starting?.cancel()
        starting = nil
        watchdog.stop()
        ears.stop()
    }

    /// Nothing else can listen without System Audio Recording, so the hint says how to listen again.
    /// Ears that are off aren't worth watching.
    private func selfCaptureStoppedByUser() {
        Log.info("visualizer: self-capture stopped from the menu bar; it stays off until the visualizer is turned on again")
        watchdog.stop()
        onHint(.stopped)
    }
}
