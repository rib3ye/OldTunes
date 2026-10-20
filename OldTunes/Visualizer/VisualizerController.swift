import AppKit
import QuartzCore
import VisualizerCore

/// The visualizer as a whole: on and off, inline in the track pane or full screen, its ears (the tap
/// and the silence watchdog) and its picture (VisualizerRenderLoop: engine, renderer, display link).
/// AppController owns one and wires it to the button, the Visualizer menu and the Space bar.
///
/// It needs macOS 14.2 for the process tap; below that `isSupported` is false and AppController
/// leaves the button dimmed and the menu out. Off at every launch, so no permission prompt appears
/// until the user asks for the visualizer. The tap exists only while it is on; the renderer is made the
/// first time and kept, so turning it on again doesn't recompile the shaders.
@MainActor
final class VisualizerController: NSObject {
    static var isSupported: Bool {
        if #available(macOS 14.2, *) { return true } else { return false }
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

    let ring = SampleRing()
    private let player: PlaybackCoordinator
    private let inlineHost: NSView
    private let listView: NSView
    private(set) var view: VisualizerView?
    private(set) var renderLoop: VisualizerRenderLoop?
    private var fullScreenWindow: VisualizerFullScreenWindow?
    /// The tap and the watchdog (VisualizerAudio), which exist only on macOS 14.2 and later.
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
    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.charactersIgnoringModifiers?.lowercased() == "h", modifiers.subtracting(.shift).isEmpty {
            view?.toggleKeyList()
            return true
        }
        guard let renderLoop, let command = VisualizerCommand(event: event) else { return false }
        let feedback = renderLoop.handle(command)
        if let message = feedback.message { view?.showToast(message) }
        return feedback.handled
    }

    // MARK: - Ears

    private func startAudio() {
        guard #available(macOS 14.2, *) else { return }
        let audio = (self.audio as? VisualizerAudio) ?? VisualizerAudio(ring: ring, player: player, muted: tapMuted) { [weak self] hint in
            self?.view?.showHint(hint)
        }
        self.audio = audio
        audio.start()
    }

    private func stopAudio() {
        guard #available(macOS 14.2, *), let audio = audio as? VisualizerAudio else { return }
        audio.stop()
        view?.showHint(nil)
    }

    /// What the AudioFeed multiplies by: OldTunes' own volume for local files is applied before the tap
    /// hears them, so it is undone; cloud volume is the output device's, applied after.
    var feedGain: Float {
        player.local.isPlaying ? 1 / max(player.local.volume, 0.05) : 1
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

/// The tap and its watchdog, kept together because both need macOS 14.2.
@available(macOS 14.2, *)
@MainActor
final class VisualizerAudio {
    let tap: MusicAudioTap
    let watchdog: TapWatchdog
    /// Building the tap waits (off the main thread, and for the permission prompt the first time), so
    /// it runs in a task. `stop()` cancels it: turned off before the task got going, nothing starts.
    private var starting: Task<Void, Never>?

    init(ring: SampleRing, player: PlaybackControlling, muted: Bool, onHint: @escaping (SilenceWatchdog.Hint?) -> Void) {
        tap = MusicAudioTap(ring: ring, muted: muted)
        watchdog = TapWatchdog(tap: tap, player: player)
        watchdog.onHint = onHint
    }

    func start() {
        starting?.cancel()
        starting = Task { [tap, watchdog] in
            guard !Task.isCancelled else { return }
            await tap.start()
            guard !Task.isCancelled else { return }
            watchdog.start()
        }
    }

    func stop() {
        starting?.cancel()
        starting = nil
        watchdog.stop()
        tap.stop()
    }
}
