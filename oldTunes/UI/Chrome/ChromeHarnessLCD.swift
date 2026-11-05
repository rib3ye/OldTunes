import AppKit

/// The chrome harness's LCD and title checks (review findings 20, 5 and 22).
///
/// Both iTunes 4.9 references show the song's time on line 2 while it plays: "Elapsed Time: 0:45"
/// in itunes_old_big.jpg and "Remaining Time: 26:32" (no minus sign) in vm_49.jpg. These checks
/// cover that default, the click cycle, the scrubber's plain interior (no fill for the played
/// part, as in both references), the "Loading…" cue while a cloud song is prepared, a new
/// playback error shown on line 2 for about four seconds, the snap-back end button's click and
/// pressed look, and the window title's weight. Every state is snapshotted as chrome_lcd_*.png so
/// it can be looked at next to the references.
extension ChromeHarness {
    private typealias Probe = ChromeHarnessProbe

    static func lcdStateChecks(_ controller: MetalWindowController, _ window: MetalWindow, out: URL) async {
        _ = await makeKey(window)
        let bar = controller.controlBar
        let lcd = bar.lcd
        bar.update(PlaybackState())
        bar.update(sampleState())

        // Finding 20: line 2 starts on the elapsed time, and remaining time has no minus sign.
        let fresh = ChromeLCDView()
        fresh.update(sampleState())
        check("[lcd] line 2 starts on elapsed time", fresh.lines.1 == "Elapsed Time: 0:45", "\(fresh.lines)")
        var cycle = [fresh.lines.1]
        for _ in 0..<3 {
            fresh.cycleDetailMode()
            cycle.append(fresh.lines.1)
        }
        check("[lcd] cycle elapsed → remaining (no minus) → artist — album → elapsed",
              cycle == ["Elapsed Time: 0:45", "Remaining Time: 3:05", "Jack Johnson — Brushfire Fairytales",
                        "Elapsed Time: 0:45"], "\(cycle)")

        // The window's own LCD, photographed in each mode; the drawn line 2 must be as wide as its text.
        for (mode, name) in [(0, "elapsed"), (1, "remaining"), (2, "artist")] {
            setMode(lcd, toLine2Matching: mode)
            await Probe.pause(0.15)
            if let px = snapshot(window, "chrome_lcd_\(name).png", out: out) {
                lineInkCheck(px, bar, window, label: name)
                if mode == 0 { scrubberInteriorCheck(px, bar, window) }
            }
        }
        setMode(lcd, toLine2Matching: 0)

        // Finding 5: "Loading…" instead of a clock stuck at 0:00, in every mode and when idle.
        var loading = sampleState()
        loading.isLoading = true
        loading.position = 0
        var seen: [String] = []
        for _ in 0..<3 {
            bar.update(loading)
            seen.append(lcd.lines.1)
            lcd.cycleDetailMode()
        }
        check("[lcd] loading shows Loading… in every mode", seen.allSatisfy { $0 == "Loading…" }, "\(seen)")
        _ = snapshot(window, "chrome_lcd_loading.png", out: out)
        var idleLoading = PlaybackState()
        idleLoading.isLoading = true
        bar.update(idleLoading)
        check("[lcd] loading with no song yet shows Loading…", lcd.lines == ("oldTunes", "Loading…"), "\(lcd.lines)")
        bar.update(sampleState())

        await errorChecks(controller, window, out: out)
        await endButtonChecks(controller, window, out: out)
        titleChecks(controller, window, out: out)
        bar.update(sampleState())
    }

    /// Cycles until line 2 is elapsed (0), remaining (1) or artist — album (2).
    private static func setMode(_ lcd: ChromeLCDView, toLine2Matching mode: Int) {
        let prefixes = ["Elapsed Time:", "Remaining Time:", "Jack Johnson"]
        for _ in 0..<3 where !lcd.lines.1.hasPrefix(prefixes[mode]) { lcd.cycleDetailMode() }
    }

    /// Ink on line 2 spans the width the text should take, centred on the LCD.
    private static func lineInkCheck(_ px: Probe.Pixels, _ bar: ControlBarView, _ window: NSWindow, label: String) {
        let lcd = bar.convert(bar.lcd.frame, to: nil)
        let top = window.frame.height - lcd.maxY
        let rows = (top + 19)...(top + 28)
        var columns: [CGFloat] = []
        for x in stride(from: lcd.minX + 26, through: lcd.maxX - 26, by: 0.5) {
            let inked = stride(from: rows.lowerBound, through: rows.upperBound, by: 0.5).contains { y in
                let c = px.rgb(x, y)
                return c.r < 0x80 && c.g < 0x80
            }
            if inked { columns.append(x) }
        }
        let text = bar.lcd.lines.1
        let want = ChromeDraw.textWidth(text)
        guard let first = columns.first, let last = columns.last else {
            return check("[lcd \(label)] line 2 drawn", false, "no ink on line 2 for '\(text)'")
        }
        let width = last + 0.5 - first, centre = (first + last + 0.5) / 2
        check("[lcd \(label)] line 2 drawn as '\(text)'", abs(width - want) <= 3 && abs(centre - lcd.midX) <= 2,
              String(format: "ink %.1f pt wide (text %.0f), centre %.1f (LCD %.1f)", width, want, centre, lcd.midX))
    }

    /// The scrubber's interior is the panel's lcdBG on both sides of the thumb (§7.4): iTunes 4.9
    /// drew no fill for the played part. itunes_old_big.jpg reads green 219 left and right of its
    /// thumb; an olive wash on the played part read 205 here.
    private static func scrubberInteriorCheck(_ px: Probe.Pixels, _ bar: ControlBarView, _ window: NSWindow) {
        let lcd = bar.lcd
        let scrub = lcd.convert(lcd.scrubberRect, to: nil)
        let fraction = lcd.displayedPosition / max(lcd.state.duration, 1)
        let thumbX = scrub.minX + 1 + CGFloat(fraction) * (scrub.width - 2)
        let y = window.frame.height - scrub.midY
        // 6 pt either side of the thumb is clear of the 7 pt diamond.
        let samples = [scrub.minX + 4, (scrub.minX + thumbX) / 2, thumbX - 6, thumbX + 6, scrub.maxX - 4]
            .map { px.rgb($0, y) }
        let ok = thumbX - scrub.minX > 20 && samples.allSatisfy { Probe.near($0, 0xD7DBC0, tolerance: 3) }
        check("[lcd] scrubber interior is lcdBG on both sides of the thumb (no played-part fill)", ok,
              "thumb at \(Int(thumbX - scrub.minX)) pt of \(Int(scrub.width)); left → right "
              + samples.map(Probe.hex).joined(separator: " "))
    }

    // MARK: - Errors (finding 5)

    private static func errorChecks(_ controller: MetalWindowController, _ window: MetalWindow, out: URL) async {
        let bar = controller.controlBar
        let lcd = bar.lcd
        let message = "\u{201C}Night Ferry\u{201D} could not be played: iCloud couldn\u{2019}t prepare this song."

        // A new error while playing shows on line 2; the player's 10 Hz updates repeat it with the
        // position moving on, and must not restart the four seconds.
        var failing = sampleState()
        failing.lastError = message
        bar.update(failing)
        let shownAt = Date()
        check("[lcd] a new playback error shows on line 2, all of it in the tooltip",
              lcd.lines == ("Brushfire Fairytales", message) && lcd.toolTip == message,
              "\(lcd.lines), tooltip '\(lcd.toolTip ?? "nil")'")
        await Probe.pause(0.15)
        _ = snapshot(window, "chrome_lcd_error.png", out: out)
        var goneAfter: TimeInterval?
        while Date().timeIntervalSince(shownAt) < 5.2 {
            failing.position = 45 + Date().timeIntervalSince(shownAt)
            bar.update(failing)
            if goneAfter == nil, lcd.lines.1 != message { goneAfter = Date().timeIntervalSince(shownAt) }
            await Probe.pause(0.1)
        }
        check("[lcd] the error gives way after about 4 s, not restarted by repeated updates",
              (3.6...4.6).contains(goneAfter ?? -1) && lcd.lines.1.hasPrefix("Elapsed Time: 0:5") && lcd.toolTip == nil,
              String(format: "shown for %.2f s, then line 2 '%@', tooltip %@", goneAfter ?? -1, lcd.lines.1,
                     lcd.toolTip ?? "nil"))
        _ = snapshot(window, "chrome_lcd_error_expired.png", out: out)

        // Paused, so no updates arrive: the error still clears on time, and the LCD redraws for it.
        var paused = sampleState()
        paused.isPlaying = false
        paused.lastError = "\u{201C}Night Bus\u{201D} could not be played."
        bar.update(paused)
        let showing = lcd.lines.1 == paused.lastError
        await Probe.pause(3.5)
        window.displayIfNeeded()
        let drawsBefore = lcd.drawCount
        let stillShowing = lcd.lines.1 == paused.lastError
        await Probe.pause(0.9)
        // The run loop redraws the window by itself during the pause, so either the LCD has drawn
        // again or the redraw is still pending.
        let redrawn = lcd.drawCount > drawsBefore || window.viewsNeedDisplay
        await Probe.pause(0.1)
        _ = snapshot(window, "chrome_lcd_error_expired_paused.png", out: out)
        check("[lcd] the error clears by itself while paused, and redraws", showing && stillShowing && redrawn
              && lcd.message == nil && lcd.lines.1 == "Elapsed Time: 0:45",
              "shown \(showing), at 3.5 s \(stillShowing), LCD draws \(drawsBefore) → \(lcd.drawCount) by 4.4 s, "
              + "line 2 '\(lcd.lines.1)'")

        // A different error restarts the four seconds; the error going away clears it at once.
        paused.lastError = "First error"
        bar.update(paused)
        await Probe.pause(2.5)
        paused.lastError = "Second error"
        bar.update(paused)
        await Probe.pause(2.5)
        let restarted = lcd.lines.1 == "Second error"
        paused.lastError = nil
        bar.update(paused)
        check("[lcd] a different error restarts the time; a cleared error leaves at once",
              restarted && lcd.lines.1 == "Elapsed Time: 0:45", "second error still up at 2.5 s \(restarted), "
              + "after clearing '\(lcd.lines.1)'")

        // Clicking line 2 while an error shows dismisses it without changing the mode.
        paused.lastError = "Third error"
        bar.update(paused)
        let line2 = bar.lcd.convert(NSPoint(x: bar.lcd.bounds.midX, y: 25), to: nil)
        let before = lcd.detailMode
        Probe.click(window, at: NSPoint(x: line2.x, y: window.frame.height - line2.y))
        check("[lcd] clicking line 2 dismisses the error without cycling", lcd.lines.1 == "Elapsed Time: 0:45"
              && lcd.detailMode == before, "line 2 '\(lcd.lines.1)', mode \(before) → \(lcd.detailMode)")

        // Nothing playing (a chosen song that could not start): the reason stays as the idle line 2.
        var stopped = PlaybackState()
        stopped.lastError = message
        bar.update(stopped)
        await Probe.pause(0.15)
        _ = snapshot(window, "chrome_lcd_idle_error.png", out: out)
        check("[lcd] idle LCD shows the reason, all of it in the tooltip",
              lcd.lines == ("oldTunes", message) && lcd.toolTip == message,
              "\(lcd.lines), tooltip '\(lcd.toolTip ?? "nil")'")
        bar.update(sampleState())
    }

    // MARK: - End buttons

    private static func endButtonChecks(_ controller: MetalWindowController, _ window: MetalWindow, out: URL) async {
        let bar = controller.controlBar
        let lcd = bar.lcd
        var reveals = 0
        bar.onRevealNowPlaying = { reveals += 1 }
        func windowPoint(left: Bool, dx: CGFloat = 0, dy: CGFloat = 0) -> NSPoint {
            let x = left ? ChromeLCDView.endButtonInset : lcd.bounds.width - ChromeLCDView.endButtonInset
            let p = lcd.convert(NSPoint(x: x + dx, y: lcd.panelRect.midY + dy), to: nil)
            return NSPoint(x: p.x, y: window.frame.height - p.y)
        }
        // A point on the button's face clear of its glyph (lower left), to read its shade.
        func shade(_ px: Probe.Pixels?, left: Bool) -> Int {
            let p = windowPoint(left: left, dx: -3, dy: 3)
            return px.map { $0.rgb(p.x, p.y).g } ?? -1
        }

        let snap = windowPoint(left: false)
        let idle = snapshot(window, "chrome_lcd_snapback.png", out: out)
        Probe.mouse(.leftMouseDown, window, at: snap)
        let firedOnDown = reveals
        let pressedOnDown = lcd.pressedButton
        await Probe.pause(0.1)
        let held = snapshot(window, "chrome_lcd_snapback_pressed.png", out: out)
        Probe.mouse(.leftMouseUp, window, at: snap)
        let pressedAfterUp = lcd.pressedButton
        await Probe.pause(0.1)
        let released = snapshot(window, "chrome_lcd_snapback_released.png", out: out)
        check("[lcd] snap-back button fires once, on release", firedOnDown == 0 && reveals == 1,
              "after mouse-down \(firedOnDown), after mouse-up \(reveals)")
        let (up, down, after) = (shade(idle, left: false), shade(held, left: false), shade(released, left: false))
        check("[lcd] snap-back button draws a pressed state", pressedOnDown == .right && pressedAfterUp == nil
              && down >= 0 && up - down >= 10 && abs(after - up) <= 2,
              "pressed \(String(describing: pressedOnDown)) → \(String(describing: pressedAfterUp)); "
              + "button face green \(up) → held \(down) → released \(after)")

        // Pressed, dragged off and released: nothing fires and the pressed look goes.
        Probe.mouse(.leftMouseDown, window, at: snap)
        Probe.mouse(.leftMouseDragged, window, at: NSPoint(x: snap.x - 40, y: snap.y))
        await Probe.pause(0.1)
        let off = snapshot(window, "chrome_lcd_snapback_dragged_off.png", out: out)
        Probe.mouse(.leftMouseUp, window, at: NSPoint(x: snap.x - 40, y: snap.y))
        check("[lcd] snap-back press dragged off fires nothing", reveals == 1 && abs(shade(off, left: false) - up) <= 2,
              "reveals \(reveals), face green while dragged off \(shade(off, left: false)) (unpressed \(up))")

        // The left button cycles line 2 on release, with the same pressed look.
        let cycler = windowPoint(left: true)
        let mode = lcd.detailMode
        Probe.mouse(.leftMouseDown, window, at: cycler)
        await Probe.pause(0.1)
        let leftHeld = snapshot(window, "chrome_lcd_left_pressed.png", out: out)
        let modeOnDown = lcd.detailMode
        Probe.mouse(.leftMouseUp, window, at: cycler)
        check("[lcd] left end button cycles line 2 on release, drawn pressed while held",
              modeOnDown == mode && lcd.detailMode != mode && shade(idle, left: true) - shade(leftHeld, left: true) >= 10,
              "mode \(mode) → on down \(modeOnDown) → on up \(lcd.detailMode); face green \(shade(idle, left: true)) → "
              + "held \(shade(leftHeld, left: true))")
        setMode(lcd, toLine2Matching: 0)
        bar.onRevealNowPlaying = nil
    }

    // MARK: - Title (finding 22)

    /// The title is drawn in regular weight: its ink weighs what a regular-weight rendering of the
    /// same text weighs, not a bold one. Then "iTunes" rendered at 1x is measured against the
    /// reference's ink box (itunes_old_big.jpg: 40 × 10 px, rows 8–17 there, which is one row lower
    /// than this window because the screenshot's window starts at y 1).
    private static func titleChecks(_ controller: MetalWindowController, _ window: MetalWindow, out: URL) {
        let titleBar = controller.metalView.titleBar
        let font = Theme.titleFont
        check("[title] title font is Lucida Grande regular", font.fontName == "LucidaGrande"
              && !font.fontDescriptor.symbolicTraits.contains(.bold), "\(font.fontName) \(font.pointSize)")
        guard let px = snapshot(window, "chrome_title.png", out: out) else { return }
        let title = titleBar.title
        let width = ChromeDraw.textWidth(title, font: font) + 4
        let region = NSRect(x: titleBar.bounds.midX - width / 2, y: ChromeTitleBarView.titleBaseline - 13,
                            width: width, height: 16)
        let drawn = inkMass(px, region)
        let regular = renderedInkMass(title, font: NSFont(name: "LucidaGrande", size: font.pointSize) ?? font)
        let bold = renderedInkMass(title, font: NSFont(name: "LucidaGrande-Bold", size: font.pointSize) ?? font)
        check("[title] title pixels weigh as regular weight, not bold", abs(drawn - regular) < abs(drawn - bold),
              String(format: "'%@' ink %.0f device px² (regular renders %.0f, bold %.0f)", title, drawn, regular, bold))

        // 1x, as the reference was taken.
        let saved = titleBar.title
        titleBar.title = "iTunes"
        if let box = inkBox1x(controller) {
            Log.info(String(format: "NOTE [title] 'iTunes' in %@ %.0f at 1x: ink %d × %d px, rows %d…%d. Reference "
                            + "itunes_old_big.jpg: 40 × 10 px, rows 8…17 (window rows 7…16). Rendered offline on flat gray, "
                            + "Lucida Grande regular 13 inks 40 × 10 px and regular 12 37 × 9 px.", font.fontName, font.pointSize,
                            box.width, box.height, box.top, box.bottom))
        }
        titleBar.title = saved
    }

    /// Total darkness below the region's median, in units of one fully inked device pixel.
    private static func inkMass(_ px: Probe.Pixels, _ region: NSRect) -> Double {
        var values: [Int] = []
        for y in Int(region.minY * px.scale)..<Int(region.maxY * px.scale) {
            for x in Int(region.minX * px.scale)..<Int(region.maxX * px.scale) {
                values.append(px.rgb(pixelX: x, pixelY: y).g)
            }
        }
        guard let darkest = values.min() else { return 0 }
        let bg = values.sorted()[values.count / 2]
        let span = Double(max(bg - darkest, 1))
        return values.reduce(0) { $0 + (bg - $1 > 8 ? Double(bg - $1) / span : 0) }
    }

    /// The same measure for `text` drawn at 2x on a flat field.
    private static func renderedInkMass(_ text: String, font: NSFont) -> Double {
        let size = NSSize(width: ChromeDraw.textWidth(text, font: font) + 8, height: 20)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                                         pixelsHigh: Int(size.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return 0 }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: 0.8, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        // In the window's appearance (it inherits the app's). Drawn outside any view, the ink would
        // resolve for the thread's current drawing appearance, which a launch with `open` leaves at
        // the Mac's own: on a Mac in Dark mode that is light ink on this gray, and every mass is 0.
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            (text as NSString).draw(at: NSPoint(x: 4, y: 3), withAttributes: [.font: font, .foregroundColor: Theme.textPrimary])
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.bitmapData else { return 0 }
        var values: [Int] = []
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide { values.append(Int(data[y * rep.bytesPerRow + x * 4 + 1])) }
        }
        guard let darkest = values.min() else { return 0 }
        let bg = values.sorted()[values.count / 2]
        let span = Double(max(bg - darkest, 1))
        return values.reduce(0) { $0 + (bg - $1 > 8 ? Double(bg - $1) / span : 0) }
    }

    /// The window's top 24 pt (metal, orbs and title) drawn at 1x: the title ink's bounding box in
    /// pixels, ink being 40 levels darker than the metal's median.
    private static func inkBox1x(_ controller: MetalWindowController) -> (width: Int, height: Int, top: Int, bottom: Int)? {
        let view = controller.metalView
        let rect = NSRect(x: 0, y: 0, width: view.bounds.width, height: 24)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(rect.width), pixelsHigh: Int(rect.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = rect.size
        view.cacheDisplay(in: rect, to: rep)
        guard let data = rep.bitmapData else { return nil }
        let centre = Int(rect.midX)
        let columns = (centre - 40)..<(centre + 40)
        let green = { (x: Int, y: Int) in Int(data[y * rep.bytesPerRow + x * 4 + 1]) }
        let all = (0..<rep.pixelsHigh).flatMap { y in columns.map { green($0, y) } }.sorted()
        let bg = all[all.count / 2]
        var xs: [Int] = [], ys: [Int] = []
        for y in 0..<rep.pixelsHigh {
            for x in columns where bg - green(x, y) > 40 {
                xs.append(x)
                ys.append(y)
            }
        }
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return nil }
        return (x1 - x0 + 1, y1 - y0 + 1, y0, y1)
    }
}
