import AppKit
import QuartzCore
import VisualizerCore

/// The visualizer as a whole: on and off, inline in the track pane or full screen, its ears (a tap or
/// SelfCapture, and the silence watchdog: VisualizerAudio) and its picture (VisualizerRenderLoop:
/// engine, renderer, display link). AppController owns one and wires it to the button, the
/// Visualizer menu and the Space bar.
///
/// It needs macOS 14.2 for the process tap; below that `isSupported` is false and AppController
/// leaves the button dimmed and the menu out. On macOS 14.4 and later it can listen without System
/// Audio Recording too (SelfCapture, which hears iCloud songs as well as files; VisualizerAudio says
/// when each is used). Off at every launch. The ears exist only while it is on; the renderer is
/// made the first time and kept, so turning it on again doesn't recompile the shaders.
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
        let audio = (self.audio as? VisualizerAudio)
            ?? VisualizerAudio(ring: ring, player: player, muted: tapMuted,
                               cloudRouted: { [weak player] in player?.cloud.route?.mode == .routing },
                               permission: { [weak player] in
                                   guard let cloud = player?.cloud else { return nil }
                                   // OLDTUNES_SIMULATE_NO_SYSTEM_AUDIO: off from the start, whatever the last launch found.
                                   return cloud.simulatesMissingPermission ? cloud.permission ?? .denied : cloud.permission
                               }) { [weak self] hint in
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

    /// What the AudioFeed multiplies by: OldTunes's own volume is applied before the ears hear the
    /// song, for files and for cloud songs CloudAudioRoute plays out, so it is undone. A cloud song
    /// RemotePlayerService plays directly (no route) is heard before the Mac's volume, which applies after.
    var feedGain: Float {
        let routed = player.cloud.route?.mode == .routing
        return player.local.isPlaying || (player.cloud.isPlaying && routed) ? 1 / max(player.appVolume, 0.05) : 1
    }

    /// How far behind the present the renderer reads the audio: the ears in use say.
    var audioDelay: TimeInterval {
        guard #available(macOS 14.2, *), let audio = audio as? VisualizerAudio else { return 0 }
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

/// The visualizer's ears and their watchdog, kept together because both need macOS 14.2.
///
/// Two kinds of ears (VisualizerEars). The process tap (MusicAudioTap) needs System Audio Recording.
/// SelfCapture needs no permission, but macOS counts it as sharing the screen while it runs. So the
/// tap is used when OldTunes is known to have the permission: the cloud route is playing a song out
/// (which proves it), this launch's probe heard its tone, or, before this launch's first iCloud
/// song, the last launch's probe did. Benches always use the tap: only it can mute, and the tap
/// benches check it. Otherwise, on macOS 14.4 and later, SelfCapture. On 14.2 and 14.3 it is the tap,
/// as before, so there the visualizer can still raise the permission prompt; from 14.4 it makes a tap
/// only with the permission known granted, so it raises the prompt only if that answer is out of date.
///
/// Ears that have heard nothing since they started, while a song played for long enough (the
/// watchdog's permission hint), count as deaf and give way to the other kind, if that can hear: a
/// tap only with the permission. A silence after sound is the music's own and changes nothing. When
/// no other ears can take over, the permission hint shows, as it always did: the permission is what
/// makes a tap possible (after reopening OldTunes, at its first iCloud song). SelfCapture stopped
/// from the menu bar stays stopped: if no tap can take over, a hint says how to listen again. Every
/// new song, and every time the visualizer is turned on, the deaf ones get a fresh chance.
@available(macOS 14.2, *)
@MainActor
final class VisualizerAudio {
    enum Source: String {
        case tap = "process tap"
        case selfCapture = "self-capture"
    }

    let tap: MusicAudioTap
    let watchdog: TapWatchdog
    private(set) var source: Source = .tap
    /// SelfCapture, made the first time it is wanted. AnyObject because it needs macOS 14.4.
    private var selfCaptureObject: AnyObject?
    private let ring: SampleRing
    private let muted: Bool
    /// Starting the ears waits (off the main thread, and for the permission prompt the first time a
    /// tap is made), so it runs in a task. `stop()` cancels it: turned off before the task got going,
    /// nothing starts.
    private var starting: Task<Void, Never>?
    private let player: PlaybackControlling
    /// Whether CloudAudioRoute is playing cloud songs out from OldTunes (see
    /// MusicAudioTap.leavesOutRemotePlayer), asked again at every change of the player's state.
    private let cloudRouted: @MainActor () -> Bool
    /// This launch's System Audio Recording answer (CloudTransport.permission); nil until its first
    /// iCloud song. Asked again at every change of the player's state.
    private let permission: @MainActor () -> SystemAudioProbe.Answer?
    private let onHint: (SilenceWatchdog.Hint?) -> Void
    private var playerObserver: UUID?
    private var isOn = false
    /// The ears found deaf during this song.
    private var deaf: Set<Source> = []
    /// SelfCapture was stopped from the menu bar since the visualizer was turned on.
    private var stoppedFromMenuBar = false
    /// Songs this time on in which the tap heard nothing at all.
    private var tapDeafSongs = 0
    private var song: Track.ID?

    /// Debug and Bench builds: OLDTUNES_VIS_EARS=tap or self-capture picks the ears, whatever the
    /// permission (benches still always tap).
    private static let forcedSource = LaunchEnvironment.value("OLDTUNES_VIS_EARS").flatMap { value in
        value == "tap" ? Source.tap : value.replacingOccurrences(of: "-", with: "") == "selfcapture" ? Source.selfCapture : nil
    }

    init(ring: SampleRing, player: PlaybackControlling, muted: Bool, cloudRouted: @escaping @MainActor () -> Bool = { false },
         permission: @escaping @MainActor () -> SystemAudioProbe.Answer? = { nil },
         onHint: @escaping (SilenceWatchdog.Hint?) -> Void) {
        self.ring = ring
        self.muted = muted
        tap = MusicAudioTap(ring: ring, muted: muted)
        watchdog = TapWatchdog(tap: tap, player: player)
        self.player = player
        self.cloudRouted = cloudRouted
        self.permission = permission
        self.onHint = onHint
        watchdog.onHint = { [weak self] hint in self?.watchdogSays(hint) }
    }

    /// The ears in use.
    var ears: any VisualizerEars {
        if source == .selfCapture, #available(macOS 14.4, *) { return selfCapture }
        return tap
    }

    @available(macOS 14.4, *)
    private var selfCapture: SelfCapture {
        if let made = selfCaptureObject as? SelfCapture { return made }
        let made = SelfCapture(ring: ring)
        made.onStoppedByUser = { [weak self] in self?.selfCaptureStoppedByUser() }
        selfCaptureObject = made
        return made
    }

    /// Taps OldTunes alone while the route plays cloud songs out from it, and OldTunes plus its
    /// RemotePlayerService otherwise; rebuilds the tap when that changes.
    func followCloudRoute() {
        let routed = cloudRouted()
        guard tap.leavesOutRemotePlayer != routed else { return }
        tap.leavesOutRemotePlayer = routed
        Task { [tap] in
            await tap.rebuild(reason: routed ? "the cloud route plays cloud songs from OldTunes" : "the cloud route stopped routing")
        }
    }

    func start() {
        isOn = true
        deaf = []
        stoppedFromMenuBar = false
        tapDeafSongs = 0
        song = player.state.nowPlaying?.id
        followCloudRoute()
        if playerObserver == nil {
            playerObserver = player.addObserver { [weak self] state in self?.playerChanged(state) }
        }
        use(preferredSource(), reason: "the visualizer is on")
    }

    func stop() {
        isOn = false
        starting?.cancel()
        starting = nil
        if let playerObserver { player.removeObserver(playerObserver) }
        playerObserver = nil
        watchdog.stop()
        tap.stop()
        if #available(macOS 14.4, *), let made = selfCaptureObject as? SelfCapture { made.stop() }
    }

    // MARK: - Choosing the ears

    /// The permission as best known now: this launch's answer, else the last launch's.
    private var knownPermission: SystemAudioProbe.Answer? {
        if let answer = permission(), answer != .untested { return answer }
        return SystemAudioProbe.lastAnswer
    }

    private func preferredSource() -> Source {
        guard #available(macOS 14.4, *), !muted, LaunchEnvironment.bench == nil else { return .tap }
        if let forced = Self.forcedSource { return forced }
        // A route that is playing a song out proves the permission, and SelfCapture would hear that
        // song twice: from the route, and 25 ms earlier from RemotePlayerService, which it can't leave out.
        if cloudRouted() { return .tap }
        var deaf = deaf
        if stoppedFromMenuBar { deaf.insert(.selfCapture) }
        let choice = Self.choose(permission: knownPermission, deaf: deaf)
        // Stopped from the menu bar means stopped: never back to SelfCapture until turned on again.
        return stoppedFromMenuBar && choice == .selfCapture ? source : choice
    }

    /// The rule in the type's comment, apart from the macOS version, benches, the route and
    /// OLDTUNES_VIS_EARS; on its own for the selfcapture bench.
    nonisolated static func choose(permission: SystemAudioProbe.Answer?, deaf: Set<Source>) -> Source {
        switch (deaf.contains(.tap), deaf.contains(.selfCapture)) {
        // A tap only with the permission: without it a tap hears nothing, and on a Mac never asked it
        // would raise the prompt.
        case (false, _): return permission == .granted ? .tap : .selfCapture
        case (true, false): return .selfCapture
        // Only the permission can help now; the tap's hint says so, and its retries hear the music
        // once it's on.
        case (true, true): return .tap
        }
    }

    /// Stops the ears in use and starts `next`, which the watchdog watches from now on.
    private func use(_ next: Source, reason: String) {
        if next != source { ears.stop() }
        source = next
        Log.info("visualizer: hearing the music through the \(next.rawValue) (\(reason))")
        onHint(nil)
        watchdog.watch(ears)
        starting?.cancel()
        starting = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.ears.start()
            guard !Task.isCancelled else { return }
            self.watchdog.start()
        }
    }

    /// The probe may answer, the route start or stop, or the song change while the visualizer is on.
    private func playerChanged(_ state: PlaybackState) {
        followCloudRoute()
        guard isOn else { return }
        if state.nowPlaying?.id != song {
            song = state.nowPlaying?.id
            deaf = []
        }
        let next = preferredSource()
        guard next != source else { return }
        let answer = cloudRouted() ? "proven by the cloud route" : knownPermission?.rawValue ?? "unknown"
        use(next, reason: "System Audio Recording is \(answer)")
    }

    private func watchdogSays(_ hint: SilenceWatchdog.Hint?) {
        // Ears that heard something since they started aren't deaf: the music has gone quiet.
        if hint == .permission, !watchdog.hasHeard {
            deaf.insert(source)
            if source == .tap { tapDeafSongs += 1 }
            if source == .tap, tapDeafSongs >= 2, permission() == nil, SystemAudioProbe.lastAnswer == .granted {
                // The tap was chosen on the last launch's word and heard nothing in two songs: the
                // permission was taken away since. Forget it, or every new song would try the tap again.
                // One song could just have opened with a long silence.
                Log.info("visualizer: the last launch's System Audio Recording answer (granted) is out of date; forgetting it")
                SystemAudioProbe.lastAnswer = nil
            }
            let next = preferredSource()
            if next != source {
                use(next, reason: "the \(source.rawValue) heard nothing while a song played")
                return
            }
        }
        onHint(hint)
    }

    private func selfCaptureStoppedByUser() {
        stoppedFromMenuBar = true
        Log.info("visualizer: self-capture stopped from the menu bar; it stays off until the visualizer is turned on again")
        let next = preferredSource()
        if next != source {
            use(next, reason: "the self-capture was stopped from the menu bar")
            return
        }
        // Nothing else can listen without asking for the permission. Ears that are off aren't worth
        // watching, and their silence isn't the permission's doing.
        watchdog.stop()
        onHint(.stopped)
    }
}
