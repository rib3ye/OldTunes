import AppKit

/// OLDTUNES_HARNESS=chrome — test bench for the brushed-metal window chrome.
///
/// Shows the real MetalWindowController with placeholder panes and a fake "Brushfire Fairytales"
/// state, writes snapshots (756×500, 1200×800, toggled, volume greyed out, hover, inactive, minimum size, full
/// screen), pixel-checks them against RESEARCH.md §7, drives every control with synthetic events
/// through real AppKit dispatch, and logs one PASS/FAIL line per check before quitting. The edge
/// cases (rich paste, CJK, mid-drag song changes, foreign delegates…) are in ChromeHarnessEdges;
/// the LCD's states (time, loading, errors, end buttons) and the title's weight in ChromeHarnessLCD.
///
/// Snapshots go to $OLDTUNES_CHROME_OUT (default: $TMPDIR/oldtunes-chrome).
/// $OLDTUNES_CHROME_ONLY (comma-separated section names) runs a subset.
@MainActor
enum ChromeHarness {
    private typealias Probe = ChromeHarnessProbe
    private static var passed = 0
    private static var failed = 0
    private static var skipped = 0

    static func run() async {
        let out = outputDirectory()
        Log.info("chrome harness: writing to \(out.path)")
        let savedWidth = UserDefaults.standard.object(forKey: MetalContentView.sourceWidthDefaultsKey)
        UserDefaults.standard.removeObject(forKey: MetalContentView.sourceWidthDefaultsKey)

        let controller = MetalWindowController()
        installPlaceholders(in: controller)
        controller.controlBar.update(sampleState())
        controller.bottomBar.setSummary("15,900 songs, 46.2 days, 102.4 GB")
        controller.controlBar.setIdleText("oldTunes", "15,900 songs")
        controller.showWindow(nil)
        NSApp.activate()
        let key = await Probe.wait(upTo: 4) { controller.window?.isKeyWindow ?? false }
        // macOS may refuse activation while the user works in another app; the inactive look is
        // then what the first snapshots show, and full screen (which activates) is re-checked later.
        Log.info("chrome harness: app active \(NSApp.isActive), window key \(key)")
        await Probe.pause(0.8)
        guard let window = controller.metalWindow else {
            Log.error("chrome harness: no window")
            return finish(savedWidth: savedWidth)
        }

        await checkWindowSetup(controller, window)
        // With no initialFirstResponder AppKit focuses the first key view, the search field;
        // MetalWindow clears that once so the window opens with nothing being typed into.
        check("window opens with search unfocused", !controller.controlBar.search.isFocused || !key,
              "first responder \(window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"), key \(key)")
        window.makeFirstResponder(nil)
        // OLDTUNES_CHROME_ONLY=search,buttons runs just those sections, for quick iteration.
        let only = Set((ProcessInfo.processInfo.environment["OLDTUNES_CHROME_ONLY"] ?? "")
            .split(separator: ",").map(String.init))
        let runs: (String) -> Bool = { only.isEmpty || only.contains($0) }
        let reference = runs("snapshots") ? await snapshotChecks(controller, window, out: out) : nil
        if runs("interaction") { await interactionChecks(controller, window) }
        if runs("search") { await searchChecks(controller, window) }
        if runs("states") { await stateSnapshots(controller, window, out: out) }
        if runs("lcd") { await lcdStateChecks(controller, window, out: out) }
        if runs("resize") { await resizeChecks(controller, window, out: out) }
        if runs("edges") { await edgeChecks(controller, window, out: out) }
        if runs("fullscreen") { await fullScreenChecks(controller, window, out: out, reference: reference) }
        if runs("buttons") { await windowButtonChecks(out: out) }

        finish(savedWidth: savedWidth)
    }

    // MARK: - Setup

    private static func outputDirectory() -> URL {
        let env = ProcessInfo.processInfo.environment["OLDTUNES_CHROME_OUT"] ?? ""
        let url = env.isEmpty ? FileManager.default.temporaryDirectory.appendingPathComponent("oldtunes-chrome")
                              : URL(fileURLWithPath: env)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func sampleState() -> PlaybackState {
        var track = Track.blank(id: 1)
        track.title = "Brushfire Fairytales"
        track.artist = "Jack Johnson"
        track.album = "Brushfire Fairytales"
        track.duration = 230
        var state = PlaybackState()
        state.nowPlaying = track
        state.isPlaying = true
        state.position = 45
        state.duration = 230
        state.volume = 0.6
        return state
    }

    private static func installPlaceholders(in controller: MetalWindowController) {
        for (pane, label) in [(controller.sourcePane, "Source pane"), (controller.trackPane, "Track pane")] {
            let placeholder = ChromeHarnessPlaceholder(label: label)
            placeholder.frame = pane.bounds
            placeholder.autoresizingMask = [.width, .height]
            pane.addSubview(placeholder)
        }
    }

    static func check(_ name: String, _ ok: Bool, _ detail: String) {
        if ok { passed += 1 } else { failed += 1 }
        let line = "\(ok ? "PASS" : "FAIL") \(name): \(detail)"
        if ok { Log.info(line) } else { Log.error(line) }
    }

    static func snapshot(_ window: NSWindow, _ name: String, out: URL) -> ChromeHarnessProbe.Pixels? {
        let url = out.appendingPathComponent(name)
        guard Snapshot.write(window, to: url) else {
            check("snapshot \(name)", false, "Snapshot.write failed")
            return nil
        }
        Log.info("snapshot written: \(url.path) (\(Int(window.frame.width))x\(Int(window.frame.height)) pt)")
        return ChromeHarnessProbe.Pixels(url: url, pointWidth: window.frame.width)
    }

    private static func finish(savedWidth: Any?) {
        if let savedWidth {
            UserDefaults.standard.set(savedWidth, forKey: MetalContentView.sourceWidthDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: MetalContentView.sourceWidthDefaultsKey)
        }
        Log.info("chrome harness: mouse events via window.sendEvent \(Probe.sentEvents), hand-delivered after hit-testing "
                 + "\(Probe.handDeliveredEvents) (only when macOS kept oldTunes in the background)")
        Log.info("chrome harness: \(passed) PASS, \(failed) FAIL, \(skipped) SKIP")
        Log.flush()
        NSApp.terminate(nil)
    }

    // MARK: - Window setup (§7.4, §8.1)

    private static func checkWindowSetup(_ controller: MetalWindowController, _ window: MetalWindow) async {
        let mask = window.styleMask
        let wanted: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        check("window style mask", mask.isSuperset(of: wanted), "raw \(mask.rawValue)")
        check("transparent title bar", window.titlebarAppearsTransparent && window.titleVisibility == .hidden
              && window.titlebarSeparatorStyle == .none, "transparent=\(window.titlebarAppearsTransparent)")
        check("movable by background", window.isMovableByWindowBackground, "\(window.isMovableByWindowBackground)")
        check("minimum size", window.minSize == Theme.Metrics.minimumWindow, "\(window.minSize)")
        check("initial size 756x500", window.frame.size == Theme.Metrics.referenceWindow, "\(window.frame.size)")
        if let screen = window.screen?.visibleFrame {
            let dx = abs(window.frame.midX - screen.midX)
            check("initial window centred horizontally", dx <= 1, "window midX \(window.frame.midX), screen midX \(screen.midX)")
        }
        check("real traffic lights hidden", window.standardButtonsHidden, "all three isHidden")
        check("content covers title bar", controller.metalView.frame.size == window.frame.size,
              "content \(controller.metalView.frame.size)")
        check("pane containers sized", controller.sourcePane.frame.size == NSSize(width: 158, height: 371)
              && controller.trackPane.frame.size == NSSize(width: 554, height: 371),
              "source \(controller.sourcePane.frame.size), track \(controller.trackPane.frame.size)")

        // Clicks on the drawn orbs must reach them, not the hidden title bar on top (§7.4).
        if let theme = window.contentView?.superview {
            for (i, x) in Theme.Metrics.trafficLightCentersX.enumerated() {
                let p = controller.metalView.convert(NSPoint(x: x, y: Theme.Metrics.trafficLightCenterY), to: nil)
                let hit = theme.hitTest(p)
                check("orb \(i) receives clicks", hit === controller.metalView.titleBar.trafficLights,
                      "hitTest → \(hit.map { String(describing: type(of: $0)) } ?? "nil")")
            }
        }

        // Dragging controls must never move the window; dragging metal must.
        let bar = controller.controlBar, bottom = controller.bottomBar
        let controls: [(String, NSView)] = [
            ("traffic lights", controller.metalView.titleBar.trafficLights), ("play", bar.playButton),
            ("back", bar.previousButton), ("volume", bar.volumeSlider), ("LCD", bar.lcd), ("search", bar.search),
            ("search text", bar.search.textField), ("browse", bar.browseButton), ("splitter", controller.metalView.splitter),
            ("shuffle", bottom.shuffleButton), ("grip", bottom.grip)]
        let movers = controls.filter { $0.1.mouseDownCanMoveWindow }.map(\.0)
        check("controls do not move window", movers.isEmpty, movers.isEmpty ? "all false" : "moves: \(movers)")
        // (The title bar moves the window itself with performDrag, so a double-click can reach it.)
        let backgrounds: [(String, NSView)] = [("metal", controller.metalView), ("control bar", bar),
                                               ("bottom bar", bottom)]
        let stuck = backgrounds.filter { !$0.1.mouseDownCanMoveWindow }.map(\.0)
        check("metal moves window", stuck.isEmpty, stuck.isEmpty ? "all true" : "stuck: \(stuck)")
    }

    // MARK: - Snapshots and pixels (§7.3, §9 milestone 2)

    @discardableResult
    private static func snapshotChecks(_ controller: MetalWindowController, _ window: MetalWindow,
                                       out: URL) async -> ChromeHarnessProbe.Pixels? {
        guard let px = snapshot(window, "chrome_756x500.png", out: out) else { return nil }
        check("snapshot is Retina 2x", px.scale == 2, "scale \(px.scale), \(px.rep.pixelsWide)x\(px.rep.pixelsHigh) px")
        metalChecks(px, width: 756, label: "756")
        hairlineChecks(px)
        lcdChecks(px, controller, width: 756, label: "756")
        searchWidthChecks(px, controller, width: 756, label: "756")

        window.setFrame(centred(NSSize(width: 1200, height: 800), around: window.frame), display: true)
        await Probe.pause(0.4)
        if let big = snapshot(window, "chrome_1200x800.png", out: out) {
            metalChecks(big, width: 1200, label: "1200")
            lcdChecks(big, controller, width: 1200, label: "1200")
            searchWidthChecks(big, controller, width: 1200, label: "1200")
        }
        window.setFrame(centred(Theme.Metrics.referenceWindow, around: window.frame), display: true)
        await Probe.pause(0.3)
        return px
    }

    private static func centred(_ size: NSSize, around frame: NSRect) -> NSRect {
        NSRect(x: (frame.midX - size.width / 2).rounded(), y: (frame.maxY - size.height).rounded(),
               width: size.width, height: size.height)
    }

    private static func metalChecks(_ px: ChromeHarnessProbe.Pixels, width: CGFloat, label: String) {
        // Title-bar row y 23 pt: below the title's descenders and the orbs, above the control bar.
        let expected: [(CGFloat, Int)] = [(0.1, 0xACACAC), (0.5, 0xCECECE), (0.9, 0xA8A8A8)]
        for (fraction, hex) in expected {
            let c = px.rgb(width * fraction, 23)
            check("[\(label)] title bar at \(Int(fraction * 100))% ≈ \(String(format: "#%06X", hex))",
                  Probe.near(c, hex, tolerance: 8), "read \(Probe.hex(c))")
        }
        // Grain is per device row, so averaging a column band shows the bare gradient.
        // 8-bit rounding makes the crest a plateau a few points wide; its middle is the peak.
        let profile = px.columnProfile(fromY: 84, toY: 88)
        if let top = profile.max(), let first = profile.firstIndex(where: { $0 >= top - 0.5 }),
           let last = profile.lastIndex(where: { $0 >= top - 0.5 }) {
            let peakPt = CGFloat(first + last + 1) / 2 / px.scale
            check("[\(label)] metal highlight tracks window centre", abs(peakPt - width / 2) <= 1,
                  String(format: "crest x %.1f…%.1f pt, middle %.1f, W/2 %.1f; crest %.1f, edges %.1f / %.1f",
                         CGFloat(first) / px.scale, CGFloat(last + 1) / px.scale, peakPt, width / 2,
                         top, profile[2], profile[profile.count - 3]))
        }
        // Left gutter at four heights: §7.3 says #A4–#A6 plus grain; allowed #9C–#AE.
        let ys: [CGFloat] = [120, 200, 300, 400]
        let reads = ys.map { px.rgb(8, $0) }
        let ok = reads.allSatisfy { (0x9C...0xAE).contains($0.r) && abs($0.r - $0.g) <= 2 && abs($0.g - $0.b) <= 2 }
        check("[\(label)] left gutter #9C–#AE at y \(ys.map { Int($0) })", ok, reads.map(Probe.hex).joined(separator: " "))
        // Grain: rows differ, columns within a row do not.
        let rowValues = (0..<40).map { px.rgb(pixelX: Int(8 * px.scale), pixelY: 240 + $0).r }
        let mean = Double(rowValues.reduce(0, +)) / Double(rowValues.count)
        let sd = (rowValues.map { pow(Double($0) - mean, 2) }.reduce(0, +) / Double(rowValues.count)).squareRoot()
        let sameRow = (0..<10).map { px.rgb(pixelX: Int(4 * px.scale) + $0, pixelY: 260).r }
        check("[\(label)] scanline grain", sd > 1.5 && sd < 4.5 && Set(sameRow).count <= 2,
              String(format: "row stdev %.2f levels; one row across 10 px: %@", sd, "\(sameRow)"))
    }

    /// The window frame, the top highlight and the pane borders are each ONE device pixel (§7.3).
    private static func hairlineChecks(_ px: ChromeHarnessProbe.Pixels) {
        let s = px.scale
        let y = Int(300 * s)
        let left = px.rgb(pixelX: 0, pixelY: y), right = px.rgb(pixelX: px.rep.pixelsWide - 1, pixelY: y)
        let inside = px.rgb(pixelX: 1, pixelY: y)
        check("window frame columns", Probe.near(left, 0x959595, tolerance: 2) && Probe.near(right, 0x999999, tolerance: 2)
              && inside.r > left.r, "left \(Probe.hex(left)), right \(Probe.hex(right)), next column \(Probe.hex(inside))")
        let rows = (0..<5).map { px.rgb(pixelX: Int(300 * s), pixelY: $0) }
        check("top highlight one device row at y 1 pt", Probe.near(rows[Int(s)], 0xF3F3F3, tolerance: 2)
              && rows[Int(s) + 1].r < 0xE0 && rows[Int(s) - 1].r < 0xE0, "rows 0–4: \(rows.map(Probe.hex))")
        // Source pane left border: content starts at x 17 pt; the border is the device pixel before it.
        let x = Int(17 * s)
        let run = (x - 3...x).map { px.rgb(pixelX: $0, pixelY: y) }
        check("pane border is one device pixel", Probe.near(run[2], 0x666666, tolerance: 3) && run[1].r > 0xD0
              && run[3].r > 0xF0 && run[0].r < 0xB4,
              "x \(x - 3)…\(x) px: metal \(Probe.hex(run[0])), lip \(Probe.hex(run[1])), border \(Probe.hex(run[2])), content \(Probe.hex(run[3]))")
        let topY = Int(93 * s)
        let column = (topY - 3...topY).map { px.rgb(pixelX: Int(80 * s), pixelY: $0) }
        check("pane top rule is one device pixel", Probe.near(column[2], 0x666666, tolerance: 3) && column[3].r > 0xF0
              && column[1].r < column[0].r, "rows \(topY - 3)…\(topY): \(column.map(Probe.hex))")
    }

    /// `lcdWidth` defaults to the width with room to spare: the reference screenshot's 414 px of
    /// 943, never under §7.2's 313.
    private static func lcdChecks(_ px: ChromeHarnessProbe.Pixels, _ controller: MetalWindowController,
                                  width: CGFloat, label: String, lcdWidth: CGFloat? = nil) {
        let lcdWidth = lcdWidth ?? max(313, (width * 414 / 943).rounded())
        let mid = width / 2
        let offset = min(120, lcdWidth / 2 - 30)
        for x in [mid - offset, mid + offset] {
            let c = px.rgb(x, 40)
            check("[\(label)] LCD background at x \(Int(x)) ≈ #D7DBC0", Probe.near(c, 0xD7DBC0, tolerance: 3),
                  "read \(Probe.hex(c))")
        }
        // The capsule's sage pixels on its middle row, scanned from both sides between the volume
        // glyph and the search field (the Browse eye's rainbow iris is sage-coloured too).
        let y = Int(52 * px.scale)
        let isSage: (Int) -> Bool = { x in
            let c = px.rgb(pixelX: x, pixelY: y)
            return c.g - c.b > 8 && abs(c.r - c.g) < 14
        }
        let columns = Array(Int(136 * px.scale)..<Int((width - 182) * px.scale))
        if let left = columns.first(where: isSage), let right = columns.last(where: isSage) {
            let centre = CGFloat(left + right + 1) / 2 / px.scale
            check("[\(label)] LCD centred at W/2", abs(centre - mid) <= 1,
                  String(format: "sage spans x %.1f…%.1f pt, centre %.1f, W/2 %.1f", CGFloat(left) / px.scale,
                         CGFloat(right + 1) / px.scale, centre, mid))
        } else {
            check("[\(label)] LCD centred at W/2", false, "no sage pixels on y 52")
        }
        let frame = controller.controlBar.lcd.frame
        check("[\(label)] LCD frame", abs(frame.midX - mid) < 0.01 && frame.width == lcdWidth,
              "x \(frame.minX)…\(frame.maxX), width \(frame.width) (want \(lcdWidth))")
    }

    /// The search capsule grows with the window like the LCD (the reference screenshot's 133 px of
    /// 943, never under §7.2's 103), its right end staying 79 pt from the window's. The drawn
    /// width is read from the pixels: the white fill on the capsule's middle row, which starts
    /// and ends 1 pt inside the border.
    private static func searchWidthChecks(_ px: ChromeHarnessProbe.Pixels, _ controller: MetalWindowController,
                                          width: CGFloat, label: String) {
        let want = max(103, (width * 133 / 943).rounded())
        let frame = controller.controlBar.searchCapsuleFrame
        check("[\(label)] search capsule frame", frame.width == want && frame.maxX == width - 79,
              "x \(frame.minX)…\(frame.maxX), width \(frame.width) (want \(want) ending at \(width - 79))")
        let y = Int(49 * px.scale)
        let isWhite: (Int) -> Bool = { x in
            let c = px.rgb(pixelX: x, pixelY: y)
            return min(c.r, c.g, c.b) >= 0xF6
        }
        let columns = Array(Int((frame.minX - 8) * px.scale)..<Int((frame.maxX + 8) * px.scale))
        if let left = columns.first(where: isWhite), let right = columns.last(where: isWhite) {
            let drawn = CGFloat(right + 1 - left) / px.scale + 2
            check("[\(label)] search capsule drawn \(Int(want)) wide", abs(drawn - want) <= 1,
                  String(format: "white fill spans x %.1f…%.1f pt, so the capsule is %.1f wide",
                         CGFloat(left) / px.scale, CGFloat(right + 1) / px.scale, drawn))
        } else {
            check("[\(label)] search capsule drawn \(Int(want)) wide", false, "no white on y 49")
        }
    }

    // MARK: - Interaction (synthetic events through window.sendEvent)

    private static func interactionChecks(_ controller: MetalWindowController, _ window: MetalWindow) async {
        _ = await makeKey(window)
        let bar = controller.controlBar, bottom = controller.bottomBar
        var log: [String] = []
        var volumes: [Float] = []
        var seeks: [TimeInterval] = []
        bar.onPlayPause = { log.append("playPause") }
        bar.onPrevious = { log.append("previous") }
        bar.onNext = { log.append("next") }
        bar.onVolumeChange = { volumes.append($0) }
        bar.onSeek = { seeks.append($0) }
        bar.onBrowseToggle = { log.append("browse") }
        bottom.onAddFolder = { log.append("add") }
        bottom.onShuffleToggle = { log.append("shuffle") }
        bottom.onRepeatCycle = { log.append("repeat") }
        bottom.onArtworkToggle = { log.append("artwork") }
        bottom.onVisualizerToggle = { log.append("visualizer") }

        let y = Theme.Metrics.transportCenterY
        Probe.click(window, at: NSPoint(x: 79, y: y))
        Probe.click(window, at: NSPoint(x: 42, y: y))
        Probe.click(window, at: NSPoint(x: 116, y: y))
        check("transport buttons", log == ["playPause", "previous", "next"], "callbacks \(log)")
        bar.update(sampleState())
        check("play/pause glyph swaps", bar.playButton.isPlaying, "isPlaying=\(bar.playButton.isPlaying) while playing")
        var paused = sampleState(); paused.isPlaying = false
        bar.update(paused)
        check("play glyph when paused", !bar.playButton.isPlaying, "isPlaying=\(bar.playButton.isPlaying)")
        bar.update(sampleState())

        // Volume: press on the groove at x 50, drag to x 100. Knob centre runs 45…111 (§7.2).
        Probe.drag(window, through: [NSPoint(x: 50, y: 75), NSPoint(x: 70, y: 75), NSPoint(x: 100, y: 75)])
        let expectedVolume = Float((100 - 45) / 66.0)
        check("volume click + drag", volumes.count >= 3 && abs((volumes.last ?? -1) - expectedVolume) < 0.02,
              "\(volumes.count) changes, first \(volumes.first ?? -1), last \(volumes.last ?? -1) (want \(expectedVolume))")
        var louder = sampleState(); louder.volume = 0.2
        bar.update(louder)
        check("volume follows state", abs(bar.volumeSlider.value - 0.2) < 0.001, "knob \(bar.volumeSlider.value)")
        bar.update(sampleState())

        // Greyed out, as during an iCloud song oldTunes can't set the level of: the slider ignores
        // a drag, a click on the small speaker and the scroll wheel, and still follows the state.
        let wheelUp = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 5, wheel2: 0, wheel3: 0)
            .flatMap { NSEvent(cgEvent: $0) }
        volumes.removeAll()
        if let wheelUp { bar.volumeSlider.scrollWheel(with: wheelUp) }
        let wheeled = volumes.count
        bar.update(sampleState())
        var greyed = sampleState(); greyed.isVolumeEnabled = false; greyed.volume = 0.3
        bar.update(greyed)
        volumes.removeAll()
        Probe.drag(window, through: [NSPoint(x: 50, y: 75), NSPoint(x: 70, y: 75), NSPoint(x: 100, y: 75)])
        Probe.click(window, at: NSPoint(x: 28, y: 75))
        if let wheelUp { bar.volumeSlider.scrollWheel(with: wheelUp) }
        check("greyed-out volume ignores drag, speaker click and wheel",
              wheeled > 0 && !bar.volumeSlider.isEnabled && volumes.isEmpty && abs(bar.volumeSlider.value - 0.3) < 0.001,
              "wheel moved it \(wheeled) times while enabled; greyed out: enabled \(bar.volumeSlider.isEnabled), "
              + "\(volumes.count) changes, knob \(bar.volumeSlider.value) (want 0.3)")
        bar.update(sampleState())
        check("volume enabled again with the state", bar.volumeSlider.isEnabled && abs(bar.volumeSlider.value - 0.6) < 0.001,
              "enabled \(bar.volumeSlider.isEnabled), knob \(bar.volumeSlider.value)")

        // Scrubber: press, drag, and while held feed a state that says 10 s; the thumb must ignore it.
        let scrub = bar.lcd.convert(bar.lcd.scrubberRect, to: nil)
        let sy = window.frame.height - scrub.midY
        let x0 = scrub.minX + 1 + 0.25 * (scrub.width - 2), x1 = scrub.minX + 1 + 0.5 * (scrub.width - 2)
        Probe.mouse(.leftMouseDown, window, at: NSPoint(x: x0, y: sy))
        Probe.mouse(.leftMouseDragged, window, at: NSPoint(x: x1, y: sy))
        var stale = sampleState(); stale.position = 10
        bar.update(stale)
        let held = bar.lcd.displayedPosition
        check("scrub drag suspends updates", bar.lcd.isScrubbing && abs(held - 115) < 1 && seeks.isEmpty,
              String(format: "while dragging: shows %.1f s (want 115), seeks so far %d", held, seeks.count))
        Probe.mouse(.leftMouseUp, window, at: NSPoint(x: x1, y: sy))
        check("seek fires once on mouse-up", seeks.count == 1 && abs((seeks.first ?? 0) - 115) < 1,
              "seeks \(seeks.map { String(format: "%.1f", $0) })")
        bar.update(stale)
        check("thumb holds seek target", abs(bar.lcd.displayedPosition - 115) < 1,
              String(format: "after a stale update shows %.1f s", bar.lcd.displayedPosition))
        var landed = sampleState(); landed.position = 115.4
        bar.update(landed)
        bar.update(sampleState())
        check("thumb follows state after seek lands", abs(bar.lcd.displayedPosition - 45) < 0.01,
              String(format: "shows %.1f s", bar.lcd.displayedPosition))

        // Line 2 starts on the elapsed time, as in both iTunes 4.9 references, and cycles
        // elapsed → remaining (no minus sign, per vm_49.jpg) → artist — album → back.
        var seen: [String] = [bar.lcd.lines.1]
        let line2 = bar.lcd.convert(NSPoint(x: bar.lcd.bounds.midX, y: 25), to: nil)
        for _ in 0..<3 {
            Probe.click(window, at: NSPoint(x: line2.x, y: window.frame.height - line2.y))
            seen.append(bar.lcd.lines.1)
        }
        check("line 2 cycles on click", seen == ["Elapsed Time: 0:45", "Remaining Time: 3:05",
                                                 "Jack Johnson — Brushfire Fairytales", "Elapsed Time: 0:45"],
              "\(seen)")
        bar.update(PlaybackState())
        check("idle text when nothing plays", bar.lcd.lines == ("oldTunes", "15,900 songs"), "\(bar.lcd.lines)")
        bar.update(sampleState())

        let browseX = window.frame.width - Theme.Metrics.browseButton.rightInsetToCenter
        Probe.click(window, at: NSPoint(x: browseX, y: y))
        check("browse toggles", bar.isBrowseOn && log.last == "browse", "isBrowseOn \(bar.isBrowseOn)")
        Probe.click(window, at: NSPoint(x: browseX, y: y))
        check("browse toggles back", !bar.isBrowseOn, "isBrowseOn \(bar.isBrowseOn)")

        // Bottom bar: + shuffle repeat×3 artwork, then the disabled right group.
        log.removeAll()
        let by = window.frame.height - 35 + 7 + 11
        for x in [37.5, 76.5, 115.5, 115.5, 115.5, 154.5] { Probe.click(window, at: NSPoint(x: x, y: by)) }
        check("bottom-left buttons", log == ["add", "shuffle", "repeat", "repeat", "repeat", "artwork"], "\(log)")
        check("shuffle lit after click", bottom.isShuffleOn && bottom.shuffleButton.isLit, "on=\(bottom.isShuffleOn)")
        check("repeat cycled off→all→one→off", bottom.repeatMode == .off, "mode \(bottom.repeatMode)")
        log.removeAll()
        for button in bottom.rightGroup {
            Probe.click(window, at: NSPoint(x: button.frame.midX, y: by))
        }
        // The visualizer button is live once the app enables it (macOS 14.2+); equalizer and eject stay dimmed.
        let liveRight = bottom.visualizerButton.isEnabled ? ["visualizer"] : []
        check("right group: only the visualizer answers", log == liveRight
              && !bottom.equalizerButton.isEnabled && !bottom.ejectButton.isEnabled, "callbacks \(log)")
        if bottom.isVisualizerOn { bottom.setVisualizerOn(false) }
        bottom.setShuffle(false)
        bottom.setArtworkVisible(false)

        // Splitter: drag 50 pt right, persisted on mouse-up; then the clamp at 400.
        let splitterX = controller.metalView.splitter.frame.midX
        Probe.drag(window, through: [NSPoint(x: splitterX, y: 300), NSPoint(x: splitterX + 20, y: 300),
                                     NSPoint(x: splitterX + 50, y: 300)])
        let stored = UserDefaults.standard.double(forKey: MetalContentView.sourceWidthDefaultsKey)
        check("splitter drag resizes and persists", controller.sourcePane.frame.width == 208 && stored == 208
              && controller.trackPane.frame.width == 504,
              "source \(controller.sourcePane.frame.width), track \(controller.trackPane.frame.width), stored \(stored)")
        let at = controller.metalView.splitter.frame.midX
        Probe.drag(window, through: [NSPoint(x: at, y: 300), NSPoint(x: at + 400, y: 300)])
        check("splitter clamps source width", controller.sourcePane.frame.width <= 400,
              "source \(controller.sourcePane.frame.width)")
        controller.metalView.setSourceWidth(Theme.Metrics.sourcePaneWidth, persist: true)

        bar.onPlayPause = nil; bar.onPrevious = nil; bar.onNext = nil; bar.onVolumeChange = nil
        bar.onSeek = nil; bar.onBrowseToggle = nil
        bottom.onAddFolder = nil; bottom.onShuffleToggle = nil; bottom.onRepeatCycle = nil; bottom.onArtworkToggle = nil
        bottom.onVisualizerToggle = nil
        bar.update(sampleState())
    }

    // MARK: - Search field

    private static func searchChecks(_ controller: MetalWindowController, _ window: MetalWindow) async {
        _ = await makeKey(window)
        let bar = controller.controlBar
        var changes: [String] = []
        bar.onSearchTextChange = { changes.append($0) }
        let field = bar.search.textField
        check("search field has no stock bezel", !field.isBezeled && !field.isBordered && !field.drawsBackground
              && field.focusRingType == .none, "bezeled \(field.isBezeled), bordered \(field.isBordered)")

        window.makeFirstResponder(nil)
        let focused = Probe.commandKey(window, "f", keyCode: 3)
        check("⌘F focuses search", focused && bar.search.isFocused, "handled \(focused), focused \(bar.search.isFocused)")
        let editor = field.currentEditor() as? NSTextView
        let shared = window.fieldEditor(false, for: nil)
        check("search uses its own black-caret field editor", editor != nil && editor !== shared
              && editor?.insertionPointColor == Theme.textPrimary,
              "private editor \(editor !== shared), caret \(editor?.insertionPointColor.description ?? "nil")")

        Probe.type(window, "oasis")
        check("typing reaches the field", bar.searchText == "oasis" && changes == ["o", "oa", "oas", "oasi", "oasis"],
              "text '\(bar.searchText)', callbacks \(changes)")

        if let editor = field.currentEditor() as? NSTextView {
            editor.setSelectedRange(NSRange(location: 1, length: 3))
            let selection = NSStringFromRange(editor.selectedRange())
            let writable = editor.writablePasteboardTypes.map(\.rawValue)
            // The same calls copy: and paste: make, aimed at a private pasteboard so Noah's
            // clipboard is never touched.
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.noahtsutsui.oldtunes.harness"))
            pasteboard.clearContents()
            let copied = editor.writeSelection(to: pasteboard, types: editor.writablePasteboardTypes)
            let clip = pasteboard.string(forType: .string) ?? ""
            editor.setSelectedRange(NSRange(location: 5, length: 0))
            let pasted = editor.readSelection(from: pasteboard)
            check("selection, copy and paste", copied && clip == "asi" && pasted && bar.searchText == "oasisasi",
                  "wrote \(copied) '\(clip)', read \(pasted), text after paste '\(bar.searchText)' (private pasteboard; "
                  + "editor string '\(editor.string)', selection \(selection), writable \(writable))")
            pasteboard.releaseGlobally()
        } else {
            check("selection, copy and paste", false, "no field editor")
        }

        changes.removeAll()
        if let escape = Probe.key(window, "\u{1b}", keyCode: 53) { window.sendEvent(escape) }
        check("Escape clears", bar.searchText.isEmpty && changes == [""] && bar.search.isFocused,
              "text '\(bar.searchText)', callbacks \(changes), still focused \(bar.search.isFocused)")

        bar.searchText = "jack"
        check("searchText setter", field.stringValue == "jack" && changes == [""], "field '\(field.stringValue)'")
        bar.searchText = ""
        bar.onSearchTextChange = nil
        window.makeFirstResponder(nil)
        check("focus leaves search", !bar.search.isFocused, "focused \(bar.search.isFocused)")
    }

    // MARK: - State snapshots

    private static func stateSnapshots(_ controller: MetalWindowController, _ window: MetalWindow, out: URL) async {
        let bar = controller.controlBar, bottom = controller.bottomBar
        bar.isBrowseOn = true
        bottom.setShuffle(true)
        bottom.setRepeat(.one)
        bottom.setArtworkVisible(true)
        bar.searchText = "jack johnson"
        bar.focusSearch()
        bar.lcd.cycleDetailMode()
        await Probe.pause(0.3)
        _ = snapshot(window, "chrome_toggled.png", out: out)
        check("toggled state", bar.isBrowseOn && bottom.isShuffleOn && bottom.repeatMode == .one
              && bottom.repeatButton.glyph == .repeatOne && bar.search.isFocused,
              "browse \(bar.isBrowseOn), shuffle \(bottom.isShuffleOn), repeat \(bottom.repeatMode)")

        bar.isBrowseOn = false
        bottom.setShuffle(false)
        bottom.setRepeat(.off)
        bottom.setArtworkVisible(false)
        bar.searchText = ""
        window.makeFirstResponder(nil)
        bar.lcd.cycleDetailMode(); bar.lcd.cycleDetailMode()

        // Greyed out, the volume slider fades as one piece: its small speaker glyph stands out from
        // the metal under the slider about half as much (alpha 0.55), and still shows.
        bar.update(sampleState())
        await Probe.pause(0.1)
        let litSlider = snapshot(window, "chrome_volume_enabled.png", out: out)
        var greyed = sampleState(); greyed.isVolumeEnabled = false
        bar.update(greyed)
        await Probe.pause(0.1)
        if let lit = litSlider, let dim = snapshot(window, "chrome_volume_greyed.png", out: out) {
            func contrast(_ px: ChromeHarnessProbe.Pixels) -> Int {
                let glyph = px.rgb(27.5, 75), metal = px.rgb(27.5, 87)
                return abs(glyph.r - metal.r) + abs(glyph.g - metal.g) + abs(glyph.b - metal.b)
            }
            let before = contrast(lit), after = contrast(dim)
            check("greyed-out volume draws dimmed", before > 60 && Double(after) < 0.75 * Double(before) && Double(after) > 0.3 * Double(before),
                  "speaker glyph against the metal: \(before) enabled, \(after) greyed out (sum of RGB differences)")
        }
        bar.update(sampleState())

        let lights = controller.metalView.titleBar.trafficLights
        lights.isHovering = true
        _ = snapshot(window, "chrome_hover.png", out: out)
        lights.isHovering = false

        // Another window takes key: the orbs go gray and the title dims, as in Aqua.
        let other = NSWindow(contentRect: NSRect(x: window.frame.minX + 40, y: window.frame.minY - 60, width: 200, height: 80),
                             styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.makeKeyAndOrderFront(nil)
        _ = await Probe.wait(upTo: 2) { !window.isKeyWindow }
        await Probe.pause(0.2)
        if let px = snapshot(window, "chrome_inactive.png", out: out) {
            let orb = px.rgb(16.5, 14)
            check("inactive orbs gray", abs(orb.r - orb.g) < 10 && abs(orb.g - orb.b) < 10, "close orb reads \(Probe.hex(orb))")
        }
        other.close()
        window.makeKeyAndOrderFront(nil)
        _ = await Probe.wait(upTo: 2) { window.isKeyWindow }
        await Probe.pause(0.2)
        if let px = snapshot(window, "chrome_active_check.png", out: out) {
            let orb = px.rgb(16.5, 14)
            let red = orb.r > orb.g + 60 && orb.r > orb.b + 60
            check("close orb follows window state", window.isKeyWindow ? red : !red,
                  "key \(window.isKeyWindow), close orb reads \(Probe.hex(orb))")
        }
    }

    // MARK: - Resize (§7.3 cache, §10 R12 live resize)

    private static func resizeChecks(_ controller: MetalWindowController, _ window: MetalWindow, out: URL) async {
        let view = controller.metalView
        let before = view.metalBuildCount
        for _ in 0..<5 { view.display() }
        check("metal cached across redraws", view.metalBuildCount == before, "builds \(before) → \(view.metalBuildCount) after 5 redraws")

        // Step the window through 24 sizes, redrawing each, as a live resize would.
        let start = window.frame
        var slowest = 0.0
        var centred = true
        for step in 1...24 {
            let t = CGFloat(step) / 24
            let size = NSSize(width: (756 + 444 * t).rounded(), height: (500 + 300 * t).rounded())
            window.setFrame(NSRect(x: start.minX, y: start.maxY - size.height, width: size.width, height: size.height),
                            display: true)
            view.display()
            slowest = max(slowest, view.lastMetalBuildSeconds)
            centred = centred && abs(controller.controlBar.lcd.frame.midX - size.width / 2) < 0.01
        }
        let builds = view.metalBuildCount - before
        check("metal rebuilt once per size", builds == 24, "\(builds) builds for 24 sizes")
        check("metal rebuild fast enough for live resize", slowest < 0.03,
              String(format: "slowest rebuild %.1f ms at up to 1200x800", slowest * 1000))
        check("LCD centred at every step", centred, "24 steps")

        window.setFrame(NSRect(x: start.minX, y: start.maxY - 400, width: 640, height: 400), display: true)
        await Probe.pause(0.2)
        if let px = snapshot(window, "chrome_640x400.png", out: out) {
            // At 640 the LCD narrows to stay centred between the volume glyph and the search field.
            lcdChecks(px, controller, width: 640, label: "640", lcdWidth: 256)
            searchWidthChecks(px, controller, width: 640, label: "640")
        }
        let lcd = controller.controlBar.lcd.frame, search = controller.controlBar.searchCapsuleFrame
        check("[640] LCD clears search and volume", lcd.maxX < search.minX && lcd.minX > 132,
              "LCD \(lcd.minX)…\(lcd.maxX), search starts \(search.minX)")

        // The grip resizes the window with the top-left corner fixed. macOS 27 keeps the outer
        // corner (about 16 pt along the diagonal, and the last 2 pt of each edge) as its own
        // resize region, which resizes the same way; the grab point here is inside the part the
        // theme frame hands to the grip, so the check exercises the grip's own code.
        _ = await makeKey(window)
        let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        let grab = NSPoint(x: 620, y: 382)
        let grabHit = window.contentView?.superview?.hitTest(Probe.windowPoint(window, grab))
        Probe.drag(window, through: [grab, NSPoint(x: 670, y: 412), NSPoint(x: 736, y: 482)])
        check("resize grip", grabHit === controller.bottomBar.grip && window.frame.size == NSSize(width: 756, height: 500)
              && NSPoint(x: window.frame.minX, y: window.frame.maxY) == topLeft,
              "grab point hit-tests to \(grabHit.map { String(describing: type(of: $0)) } ?? "nil"), "
              + "size \(window.frame.size), top-left kept \(NSPoint(x: window.frame.minX, y: window.frame.maxY) == topLeft)")
        window.setFrame(start, display: true)
        await Probe.pause(0.2)
    }

    // MARK: - Full screen (§10 R12)

    private static func fullScreenChecks(_ controller: MetalWindowController, _ window: MetalWindow, out: URL,
                                         reference: ChromeHarnessProbe.Pixels?) async {
        _ = await makeKey(window)
        let preFrame = window.frame
        check("756x500 before full screen", preFrame.size == Theme.Metrics.referenceWindow, "frame \(preFrame)")
        window.toggleFullScreen(nil)
        let entered = await Probe.wait(upTo: 6) { window.styleMask.contains(.fullScreen) }
        await Probe.pause(1.2)
        check("entered full screen", entered, "styleMask fullScreen \(window.styleMask.contains(.fullScreen))")
        if entered {
            // The biggest bitmap the metal ever needs: how long a rebuild takes and what it holds.
            let view = controller.metalView
            let scale = window.backingScaleFactor
            let bytes = Int(view.bounds.width * scale) * Int(view.bounds.height * scale) * 4
            check("[full screen] metal rebuild time", view.lastMetalBuildSeconds < 0.1,
                  String(format: "%.1f ms for %.0fx%.0f pt, bitmap %.1f MB", view.lastMetalBuildSeconds * 1000,
                         view.bounds.width, view.bounds.height, Double(bytes) / 1_048_576))
        }
        if entered, let px = snapshot(window, "chrome_fullscreen.png", out: out) {
            check("[full screen] real traffic lights still hidden", window.standardButtonsHidden, "isHidden all")
            check("[full screen] resize grip hidden", controller.bottomBar.grip.isHidden,
                  "isHidden \(controller.bottomBar.grip.isHidden)")
            lcdChecks(px, controller, width: window.frame.width, label: "full screen \(Int(window.frame.width))")
            searchWidthChecks(px, controller, width: window.frame.width, label: "full screen \(Int(window.frame.width))")
            metalChecks(px, width: window.frame.width, label: "full screen")
            let orb = px.rgb(16.5, 14)
            check("[full screen] drawn orbs in place", orb.r > orb.g + 60 || abs(orb.r - orb.g) < 10,
                  "close orb reads \(Probe.hex(orb)) (key \(window.isKeyWindow))")
        }
        window.toggleFullScreen(nil)
        let left = await Probe.wait(upTo: 6) { !window.styleMask.contains(.fullScreen) }
        await Probe.pause(1.2)
        check("left full screen to the same frame", left && window.frame == preFrame,
              "frame \(window.frame), before \(preFrame)")
        check("[after full screen] real traffic lights hidden", window.standardButtonsHidden, "isHidden all")
        check("[after full screen] resize grip back", !controller.bottomBar.grip.isHidden,
              "isHidden \(controller.bottomBar.grip.isHidden)")
        if let after = snapshot(window, "chrome_after_fullscreen.png", out: out) {
            // Below the title bar nothing may change. The title bar itself legitimately changes if
            // full screen made the app active (orbs gray → coloured), so it is checked separately.
            if let reference {
                let diff = after.differingPixels(from: reference, tolerance: 2, fromY: 28)
                check("chrome below title bar identical after full screen", diff == 0,
                      "\(diff.map(String.init) ?? "size mismatch") px differ (y ≥ 28 pt)")
            }
            let active = window.isKeyWindow
            let orb = after.rgb(16.5, 14)
            check("orbs match window state after full screen", active ? orb.r > orb.g + 60 : abs(orb.r - orb.g) < 10,
                  "key window \(active), close orb reads \(Probe.hex(orb))")
            if active {
                Log.info("app is active now: re-running the pixel checks on the active-window snapshot")
                metalChecks(after, width: 756, label: "756 active")
                lcdChecks(after, controller, width: 756, label: "756 active")
                searchWidthChecks(after, controller, width: 756, label: "756 active")
            }
        }
    }

    // MARK: - Orbs and window keys on throwaway windows

    /// Two separate questions per orb: did the click reach the orb and fire its action (always
    /// checkable), and did AppKit then zoom/minimise/close (only checkable while oldTunes is the
    /// active app: macOS ignores window actions from an app the user has moved away from, and
    /// synthetic events cannot activate it).
    private static func windowButtonChecks(out: URL) async {
        let spare = MetalWindowController()
        spare.titleText = "Spare"
        spare.showWindow(nil)
        guard let window = spare.metalWindow else { return }
        let lights = spare.metalView.titleBar.trafficLights
        window.setFrameOrigin(NSPoint(x: window.frame.minX + 60, y: window.frame.minY - 40))
        check("title text", spare.metalView.titleBar.title == "Spare" && window.title == "Spare", "'\(window.title)'")

        var key = await makeKey(window)
        let before = window.frame
        Probe.click(window, at: NSPoint(x: 58.5, y: 12.5))
        check("green orb click fires zoom", lights.lastPerformed == .zoom, "fired \(String(describing: lights.lastPerformed))")
        _ = await Probe.wait(upTo: 2) { window.frame != before }
        await Probe.pause(0.4)
        let zoomed = window.frame
        effect("green orb zooms", key: key, ok: zoomed != before, "\(before.size) → \(zoomed.size)")
        Probe.click(window, at: NSPoint(x: 58.5, y: 12.5))
        _ = await Probe.wait(upTo: 2) { window.frame == before }
        await Probe.pause(0.4)
        effect("green orb unzooms", key: key, ok: window.frame == before, "back to \(window.frame.size)")
        window.setFrame(before, display: true)

        // Double-clicking the title bar follows the user's "double-click a window's title bar" setting.
        key = await makeKey(window)
        let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
        let title = NSPoint(x: 300, y: 10)
        let titleHit = window.contentView?.superview?.hitTest(Probe.windowPoint(window, title))
        Log.info("chrome harness: title bar point hit-tests to "
                 + "\(titleHit.map { String(describing: type(of: $0)) } ?? "nil"), key \(key)")
        // A real double-click is two clicks. AppKit drops a lone clickCount-2 mouse-down in the
        // title bar before any view sees it, so the first click must be sent too.
        Probe.mouse(.leftMouseDown, window, at: title, clicks: 1)
        Probe.mouse(.leftMouseUp, window, at: title, clicks: 1)
        Probe.mouse(.leftMouseDown, window, at: title, clicks: 2)
        Probe.mouse(.leftMouseUp, window, at: title, clicks: 2)
        _ = await Probe.wait(upTo: 2) { window.frame != before || window.isMiniaturized }
        await Probe.pause(0.4)
        let reacted = action == "None" ? window.frame == before
            : action == "Minimize" ? window.isMiniaturized : window.frame != before
        effect("title bar double-click (\(action))", key: key, ok: reacted,
               "frame \(window.frame.size), minimised \(window.isMiniaturized)")
        if window.isMiniaturized { window.deminiaturize(nil) }
        _ = await Probe.wait(upTo: 3) { !window.isMiniaturized }
        window.setFrame(before, display: true)
        await Probe.pause(0.3)

        key = await makeKey(window)
        Probe.click(window, at: NSPoint(x: 37.5, y: 12.5))
        check("yellow orb click fires minimise", lights.lastPerformed == .minimize,
              "fired \(String(describing: lights.lastPerformed))")
        let minimized = await Probe.wait(upTo: 3) { window.isMiniaturized }
        effect("yellow orb minimises", key: key, ok: minimized, "isMiniaturized \(window.isMiniaturized)")
        window.deminiaturize(nil)
        _ = await Probe.wait(upTo: 3) { !window.isMiniaturized }
        await Probe.pause(0.5)

        key = await makeKey(window)
        let m = Probe.commandKey(window, "m", keyCode: 46)
        check("⌘M reaches Window ▸ Minimize", m, "handled \(m)")
        let minimizedByKey = await Probe.wait(upTo: 3) { window.isMiniaturized }
        effect("⌘M minimises", key: key, ok: minimizedByKey, "isMiniaturized \(window.isMiniaturized)")
        window.deminiaturize(nil)
        _ = await Probe.wait(upTo: 3) { !window.isMiniaturized }
        await Probe.pause(0.5)

        key = await makeKey(window)
        let w = Probe.commandKey(window, "w", keyCode: 13)
        check("⌘W reaches the close fallback", w, "handled \(w)")
        let closedByKey = await Probe.wait(upTo: 2) { !window.isVisible }
        effect("⌘W closes", key: key, ok: closedByKey, "visible \(window.isVisible)")

        let third = MetalWindowController()
        third.showWindow(nil)
        guard let w3 = third.metalWindow else { return }
        key = await makeKey(w3)
        Probe.click(w3, at: NSPoint(x: 16.5, y: 12.5))
        check("red orb click fires close", third.metalView.titleBar.trafficLights.lastPerformed == .close,
              "fired \(String(describing: third.metalView.titleBar.trafficLights.lastPerformed))")
        let closed = await Probe.wait(upTo: 2) { !w3.isVisible }
        effect("red orb closes", key: key, ok: closed, "visible \(w3.isVisible)")
    }

    static func makeKey(_ window: NSWindow) async -> Bool {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        let key = await Probe.wait(upTo: 3) { window.isKeyWindow }
        await Probe.pause(0.3)
        return key
    }

    /// A window-action result that AppKit only delivers to the active app: checked when the window
    /// was key, logged as SKIP (not PASS) when macOS kept oldTunes in the background.
    private static func effect(_ name: String, key: Bool, ok: Bool, _ detail: String) {
        if key || ok {
            check(name, ok, detail)
        } else {
            skipped += 1
            Log.info("SKIP \(name): \(detail); oldTunes was not the active app, so macOS ignored the window action")
        }
    }
}

/// A white pane with a centred label, standing in for the lists until integration.
@MainActor
private final class ChromeHarnessPlaceholder: NSView {
    private let label: String

    init(label: String) {
        self.label = label
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Theme.listBG.setFill()
        dirtyRect.fill()
        ChromeDraw.text(label, centerX: bounds.midX, baseline: bounds.midY + 4, maxWidth: bounds.width - 8,
                        color: Theme.textDimmed)
    }

    override var isFlipped: Bool { true }
}
