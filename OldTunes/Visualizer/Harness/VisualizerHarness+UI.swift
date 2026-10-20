import AppKit
import CoreAudio
import Metal
import MusicKit
import VisualizerCore

/// OLDTUNES_VIS_MODE=ui — the visualizer in the real app window:
///   the flower button swaps the track list for the visualizer and back, lit while on; ⌘T does the
///   same and the menu titles follow; H and Visualizer ▸ Show Visualizer Keys show the key list; the
///   watchdog's hint shows and clears; ⇧⌘F goes full screen and Esc comes back; Space plays and
///   pauses from the full-screen window; ⌃⌘F is left to the window; the Settings HDR box previews,
///   cancels and saves; turning the visualizer off removes its tap.
///
/// Builds the real AppController over a scratch library index: OLDTUNES_DB_PATH must point outside
/// the real one. The tap is muted unless OLDTUNES_VIS_AUDIBLE=1, and a cloud song is prepared first
/// so its RemotePlayerService is muted too when Space starts playback. Settings it may touch are put
/// back at the end. Takes no pictures: the window shows the user's library.
extension VisualizerHarness {
    private typealias Probe = ChromeHarnessProbe

    static func ui(_ bench: VisualizerBench) async {
        guard VisualizerController.isSupported else {
            bench.note("ui checks skipped: the visualizer needs macOS 14.2")
            return
        }
        let dbPath = ProcessInfo.processInfo.environment["OLDTUNES_DB_PATH"] ?? ""
        guard !dbPath.isEmpty, URL(fileURLWithPath: dbPath).standardized != LibraryIndex.defaultURL.standardized else {
            bench.check("scratch library index", false, "set OLDTUNES_DB_PATH to a scratch file; the ui bench never uses the real index")
            return
        }
        let defaults = UserDefaults.standard
        // Settings' OK saves the Appearance choice along with the HDR box, so it is put back too.
        let keys = ["NSWindow Frame OldTunesMainWindow", VisualizerPreference.hdrKey, SettingsWindowController.frameDefaultsKey,
                    AppearancePreference.defaultsKey,
                    TrackColumnLayout.defaultsKey, "OldTunes.TrackList.browserVisible", "OldTunes.TrackList.browserFraction",
                    "OldTunes.TrackList.sort", "OldTunes.SourceList.expandedFolders", MetalContentView.sourceWidthDefaultsKey]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }

        await runUIChecks(bench)

        for (key, value) in saved {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        let restored = saved.allSatisfy { key, value in (defaults.object(forKey: key) as? NSObject) == (value as? NSObject) }
        bench.check("settings put back", restored, "\(saved.filter { $0.1 != nil }.count) of \(keys.count) keys had values")
    }

    private static func runUIChecks(_ bench: VisualizerBench) async {
        let index: LibraryIndex
        do { index = try LibraryIndex() } catch {
            bench.check("scratch library index opens", false, "\(error)")
            return
        }
        let app = AppController(index: index)
        var ingested = false
        app.onFirstIngest = { _ in ingested = true }
        app.start()
        _ = await Probe.wait(upTo: 60) { ingested }
        bench.check("app starts over the scratch index", ingested, "first ingest \(ingested ? "done" : "not done in 60 s")")
        guard let window = app.windowController.window, let visualizer = app.visualizer else {
            bench.check("main window and visualizer exist", false, "missing")
            return
        }
        visualizer.tapMuted = !audible
        let bar = app.windowController.bottomBar
        let baselineTaps = AudioHAL.readIDs(AudioHAL.system, kAudioHardwarePropertyTapList).count

        // A cloud song's RemotePlayerService must exist before the tap is built, so a muted tap holds it.
        if let song = try? await withTimeout(30, { () -> Song? in
            var request = MusicLibraryRequest<Song>()
            request.limit = 1
            return try await request.response().items.first
        }) {
            let queue = ApplicationMusicPlayer.Queue(for: [song])
            if #available(macOS 26.4, *) { queue.affectsListeningHistory = false }
            ApplicationMusicPlayer.shared.queue = queue
            try? await withTimeout(20) { @MainActor in try await ApplicationMusicPlayer.shared.prepareToPlay() }
        }

        // The button.
        bench.check("button enabled, other right-hand buttons dimmed",
                    bar.visualizerButton.isEnabled && !bar.equalizerButton.isEnabled && !bar.ejectButton.isEnabled, "")
        click(bar.visualizerButton, in: window)
        _ = await Probe.wait(upTo: 3) { visualizer.view?.superview != nil }
        let shows = visualizer.isOn && visualizer.view?.isHidden == false && app.tracks.view.isHidden
        bench.check("the button swaps the track list for the visualizer", shows && bar.visualizerButton.isLit
                    && window.firstResponder === visualizer.view,
                    "on \(visualizer.isOn), list hidden \(app.tracks.view.isHidden), lit \(bar.visualizerButton.isLit), "
                    + "focus \(type(of: window.firstResponder as Any))")
        await Probe.pause(1.5)
        if #available(macOS 14.2, *), let audio = visualizer.audio as? VisualizerAudio {
            bench.check("its tap runs, ours and muted", audio.tap.status.isRunning && audio.tap.muted == !audible,
                        audio.tap.status.failure ?? "\(audio.tap.status.tapped)")
        }
        click(bar.visualizerButton, in: window)
        bench.check("the button swaps it back", !visualizer.isOn && !app.tracks.view.isHidden && !bar.visualizerButton.isLit
                    && visualizer.view?.superview == nil, "on \(visualizer.isOn)")

        // ⌘T and the menu.
        let menu = NSApp.mainMenu?.items.first { $0.submenu?.title == "Visualizer" }?.submenu
        let toggleItem = menu?.items.first { $0.action == #selector(AppController.toggleVisualizer(_:)) }
        let fullItem = menu?.items.first { $0.action == #selector(AppController.toggleVisualizerFullScreen(_:)) }
        bench.check("Visualizer menu sits after Controls", NSApp.mainMenu?.items.map(\.title).firstIndex(of: "Visualizer")
                    == (NSApp.mainMenu?.items.map(\.title).firstIndex(of: "Controls")).map { $0 + 1 },
                    "\(NSApp.mainMenu?.items.map(\.title) ?? [])")
        bench.check("Turn On Visualizer is ⌘T, Full Screen is ⇧⌘F",
                    toggleItem?.keyEquivalent == "t" && toggleItem?.keyEquivalentModifierMask == .command
                    && fullItem?.keyEquivalent == "F" && fullItem?.keyEquivalentModifierMask == .command,
                    "\(toggleItem?.keyEquivalent ?? "?") \(fullItem?.keyEquivalent ?? "?")")
        let claimsControlCommandF = NSApp.mainMenu.map { allItems($0) }?.contains {
            $0.keyEquivalent.lowercased() == "f" && $0.keyEquivalentModifierMask == [.command, .control]
                && $0.action != #selector(NSWindow.toggleFullScreen(_:))
        } ?? false
        bench.check("⌃⌘F is left to the window's own full screen", !claimsControlCommandF, "")
        Probe.commandKey(window, "t", keyCode: 17)
        menu?.update()
        bench.check("⌘T turns it on and the menu says Turn Off", visualizer.isOn && toggleItem?.title == "Turn Off Visualizer",
                    "on \(visualizer.isOn), title \(toggleItem?.title ?? "?")")

        // The picture: frames drawn by the engine and the renderer.
        if let loop = visualizer.renderLoop {
            _ = loop.presenter.takeFrameStats()
            var frames = 0
            visualizer.onFrame = { frames += 1 }
            await Probe.pause(3)
            visualizer.onFrame = nil
            let stats = loop.presenter.takeFrameStats()
            let gpu = stats.gpuFrames.map(\.seconds).sorted()
            let gpuMedian = gpu.isEmpty ? 0 : gpu[gpu.count / 2] * 1000
            bench.check("the visualizer draws about 120 steps a second", frames >= 150 && stats.framesShown >= 150
                        && loop.driver.rendersPerSecond > 100,
                        "\(frames) frames in 3 s, \(stats.framesShown) shown, \(stats.framesSkipped) skipped, "
                        + "\(stats.framesMissingDrawable) without a drawable, \(String(format: "%.0f", loop.driver.rendersPerSecond)) steps/s, "
                        + "GPU median \(String(format: "%.2f", gpuMedian)) ms a frame, \(loop.presenter.usesHDR ? "HDR" : "SDR"), "
                        + "buffer \(loop.presenter.gpuWarp.width)×\(loop.presenter.gpuWarp.height)")
            if let view = visualizer.view, let r = Probe.key(window, "r", keyCode: 15) {
                let motionBefore = loop.driver.motionTime, paletteBefore = loop.driver.paletteTime
                view.keyDown(with: r)
                // The original jumps each clock to a random point in 0…10,000 s.
                bench.check("R randomizes everything (Space stays Play/Pause)",
                            abs(loop.driver.motionTime - motionBefore) > 1 && abs(loop.driver.paletteTime - paletteBefore) > 1,
                            String(format: "motion clock %.1f → %.1f s, palette clock %.1f → %.1f s",
                                   motionBefore, loop.driver.motionTime, paletteBefore, loop.driver.paletteTime))
            }

            // The slower-screen path: at 60 Hz each frame runs two engine steps, still 120 a second.
            loop.preferredFrameRate = 60
            // The driver adds steps once it has measured the display's new rate.
            _ = await Probe.wait(upTo: 3) { loop.driver.displayHz < 70 }
            await Probe.pause(0.5)
            var slowFrames = 0
            visualizer.onFrame = { slowFrames += 1 }
            let began = CACurrentMediaTime(), stepsBefore = loop.driver.frame
            await Probe.pause(3)
            visualizer.onFrame = nil
            let seconds = CACurrentMediaTime() - began
            let fps = Double(slowFrames) / seconds, stepsPerSecond = Double(loop.driver.frame - stepsBefore) / seconds
            loop.preferredFrameRate = 120
            bench.check("at 60 Hz each frame runs two steps, 120 a second", abs(fps - 60) < 5 && abs(stepsPerSecond - 120) < 5,
                        String(format: "%.1f frames/s, %.1f steps/s, display measured at %.1f Hz",
                               fps, stepsPerSecond, loop.driver.displayHz))
        } else {
            bench.check("the visualizer draws about 120 steps a second", false, "no renderer")
        }

        // Keys and overlays.
        if let view = visualizer.view, let h = Probe.key(window, "h", keyCode: 4) {
            window.sendEvent(h)
            bench.check("H shows the key list with the credit", view.isShowingKeyList
                        && VisualizerView.keyListText.hasPrefix("Visualizer — based on Geiss HDR by Ryan Geiss"), "")
            app.toggleVisualizerKeys(nil)
            bench.check("Show Visualizer Keys hides it again", !view.isShowingKeyList, "")
            view.showHint(.permission)
            bench.check("the permission hint shows", view.hint == .permission, "")
            view.showHint(nil)
            bench.check("and clears", view.hint == nil, "")
        }

        // Full screen and back.
        let shiftCommandF = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, characters: "F", charactersIgnoringModifiers: "F",
                                             isARepeat: false, keyCode: 3)
        // The way NSApplication routes a key equivalent: the key window first, then the menu bar.
        let routed = shiftCommandF.map { window.performKeyEquivalent(with: $0) || (NSApp.mainMenu?.performKeyEquivalent(with: $0) ?? false) }
        menu?.update()
        _ = await Probe.wait(upTo: 4) { visualizer.fullScreenWindowForKeys?.styleMask.contains(.fullScreen) == true }
        await Probe.pause(0.5)
        let full = visualizer.fullScreenWindowForKeys
        // The move re-checks HDR under the running display link, which once crashed here.
        let fullFrames = await frames(of: visualizer, in: 0.5)
        bench.check("⇧⌘F goes full screen with the visualizer alone", routed == true && visualizer.isFullScreen
                    && visualizer.view?.window === full && full?.styleMask.contains(.fullScreen) == true && fullFrames >= 20,
                    "routed \(routed.map(String.init) ?? "nil"), full screen \(full?.styleMask.contains(.fullScreen) ?? false), "
                    + "\(fullFrames) frames in 0.5 s")

        // Space from the full-screen window plays and pauses (muted).
        if let full, let space = Probe.key(full, " ", keyCode: 49) {
            let before = app.player.state.isPlaying
            NSApp.sendEvent(space)
            _ = await Probe.wait(upTo: 8) { app.player.state.isPlaying != before && !app.player.state.isLoading }
            let toggled = app.player.state.isPlaying != before
            if let again = Probe.key(full, " ", keyCode: 49) { NSApp.sendEvent(again) }
            _ = await Probe.wait(upTo: 3) { app.player.state.isPlaying == before }
            bench.check("Space plays and pauses from full screen", toggled && app.player.state.isPlaying == before,
                        "playing \(before) → \(toggled ? !before : before) → \(app.player.state.isPlaying)")
        }

        if let view = visualizer.view, let escape = Probe.key(full ?? window, "\u{1b}", keyCode: 53) {
            view.keyDown(with: escape)
        }
        _ = await Probe.wait(upTo: 4) { !visualizer.isFullScreen }
        await Probe.pause(0.5)
        let backFrames = await frames(of: visualizer, in: 0.5)
        bench.check("Esc comes back to the window", !visualizer.isFullScreen && visualizer.isOn
                    && visualizer.view?.window === window && app.tracks.view.isHidden && backFrames >= 20,
                    "full screen \(visualizer.isFullScreen), in main window \(visualizer.view?.window === window), "
                    + "\(backFrames) frames in 0.5 s")

        // Settings ▸ Visualizer ▸ HDR, while the visualizer draws.
        await settingsChecks(bench, visualizer: visualizer)

        // A choice made while the visualizer is off applies when it comes back on.
        visualizer.setOn(false)
        let offChoice = !VisualizerPreference.currentHDR
        VisualizerPreference.chooseHDR(offChoice, save: false)
        visualizer.setOn(true)
        let wantHDR = offChoice && Presenter.screenSupportsHDR(visualizer.view?.window?.screen)
        let shownHDR = visualizer.renderLoop?.presenter.usesHDR
        bench.check("a Settings choice made while it was off applies when it comes back on", shownHDR == wantHDR,
                    "\(wantHDR ? "HDR" : "SDR") wanted, \(shownHDR.map { $0 ? "HDR" : "SDR" } ?? "no renderer") shown")
        VisualizerPreference.chooseHDR(VisualizerPreference.savedHDR, save: false)

        // Off removes the tap.
        app.player.stop()
        visualizer.setOn(false)
        await Probe.pause(1)
        let taps = AudioHAL.readIDs(AudioHAL.system, kAudioHardwarePropertyTapList).count
        bench.check("turning the visualizer off removes its tap", taps == baselineTaps && !visualizer.isOn,
                    "taps \(baselineTaps) → \(taps)")
        window.orderOut(nil)
    }

    private static func settingsChecks(_ bench: VisualizerBench, visualizer: VisualizerController) async {
        let savedHDR = VisualizerPreference.savedHDR
        SettingsWindowController.show()
        await Probe.pause(0.5)
        guard let settings = SettingsWindowController.current, settings.window != nil else {
            bench.check("Settings opens", false, "no window")
            return
        }
        bench.check("Settings shows the saved HDR choice", settings.hdrCheckbox.isOn == savedHDR && settings.hdrCheckbox.superview != nil,
                    "box \(settings.hdrCheckbox.isOn), saved \(savedHDR)")
        toggle(settings.hdrCheckbox)
        bench.check("clicking the box previews without saving", VisualizerPreference.currentHDR == !savedHDR
                    && VisualizerPreference.savedHDR == savedHDR, "current \(VisualizerPreference.currentHDR)")
        // The preview reconfigures the layer under the running display link, which once crashed.
        if let loop = visualizer.renderLoop, let view = visualizer.view {
            let wantHDR = !savedHDR && Presenter.screenSupportsHDR(view.window?.screen)
            let drawn = await frames(of: visualizer, in: 0.5)
            let format = view.metalLayer.pixelFormat
            bench.check("the picture follows the box while it draws", loop.presenter.usesHDR == wantHDR
                        && format == (wantHDR ? .rgba16Float : .bgra8Unorm) && drawn >= 20,
                        "\(wantHDR ? "HDR" : "SDR") wanted, layer \(format == .rgba16Float ? "rgba16Float" : format == .bgra8Unorm ? "bgra8Unorm" : "\(format.rawValue)"), "
                        + "\(drawn) frames in 0.5 s")
        }
        settings.cancelButton.performClick(nil)
        await Probe.pause(0.3)
        bench.check("Cancel puts it back", VisualizerPreference.currentHDR == savedHDR && VisualizerPreference.savedHDR == savedHDR, "")
        SettingsWindowController.show()
        await Probe.pause(0.3)
        toggle(settings.hdrCheckbox)
        settings.okButton.performClick(nil)
        await Probe.pause(0.3)
        bench.check("OK saves it", VisualizerPreference.savedHDR == !savedHDR && VisualizerPreference.currentHDR == !savedHDR, "")
        VisualizerPreference.chooseHDR(savedHDR, save: true)
    }

    /// The frames the visualizer draws in the next `seconds`.
    private static func frames(of visualizer: VisualizerController, in seconds: Double) async -> Int {
        var count = 0
        visualizer.onFrame = { count += 1 }
        await Probe.pause(seconds)
        visualizer.onFrame = nil
        return count
    }

    /// Clicks the middle of `view` the way a user would.
    private static func click(_ view: NSView, in window: NSWindow) {
        let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        Probe.click(window, at: NSPoint(x: center.x, y: window.frame.height - center.y))
    }

    /// What a click on an Aqua checkbox does. A synthetic click can't be used: the box tracks the mouse
    /// in a loop that waits for a real mouse-up, which hung the first run of this bench.
    private static func toggle(_ box: AquaCheckbox) {
        box.isOn.toggle()
        box.onToggle?(box.isOn)
    }

    private static func allItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { [$0] + ($0.submenu.map(allItems) ?? []) }
    }
}
