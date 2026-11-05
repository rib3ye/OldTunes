import AppKit

/// The chrome harness's edge cases: the ones a user hits that the happy path does not cover.
/// A rich paste into search, a programmatic search change while typing, very long and non-Latin
/// LCD text, the song changing under a scrubber drag, a stale thumb after a seek, glyphs stuck on
/// after the window moves away from the mouse, and integration taking over the window delegate.
extension ChromeHarness {
    private typealias Probe = ChromeHarnessProbe

    static func edgeChecks(_ controller: MetalWindowController, _ window: MetalWindow, out: URL) async {
        _ = await makeKey(window)
        await searchEdgeChecks(controller, window, out: out)
        await lcdEdgeChecks(controller, window, out: out)
        await windowEdgeChecks(controller, window, out: out)
    }

    // MARK: - Search

    private static func searchEdgeChecks(_ controller: MetalWindowController, _ window: MetalWindow,
                                         out: URL) async {
        let bar = controller.controlBar
        var changes: [String] = []
        bar.onSearchTextChange = { changes.append($0) }

        // Clicks: on the text, and in the capsule just above it (outside the text field), both
        // focus the field rather than dragging the window.
        let capsule = bar.convert(bar.searchCapsuleFrame, to: nil)
        let capsuleTop = window.frame.height - capsule.maxY
        var focusedBy: [String: Bool] = [:]
        window.makeFirstResponder(nil)
        Probe.click(window, at: NSPoint(x: capsule.midX, y: capsuleTop + 2.5))
        focusedBy["capsule edge"] = bar.search.isFocused
        window.makeFirstResponder(nil)
        // The field editor tracks a click on the text in its own loop that reads the mouse-up
        // from the event queue, so that mouse-up is queued first and the mouse-down sent after.
        // The window then gets a mouse-up of its own too: the queued one never passes through
        // window.sendEvent, and without it AppKit keeps the click half-open and swallows the
        // next synthetic events.
        let onText = NSPoint(x: capsule.midX, y: capsuleTop + capsule.height / 2)
        if let up = mouseEvent(.leftMouseUp, window, onText), let down = mouseEvent(.leftMouseDown, window, onText),
           let windowUp = mouseEvent(.leftMouseUp, window, onText) {
            NSApp.postEvent(up, atStart: false)
            window.sendEvent(down)
            window.sendEvent(windowUp)
        }
        focusedBy["text"] = bar.search.isFocused
        check("[edge] clicking the capsule focuses search", focusedBy.values.allSatisfy { $0 }, "\(focusedBy)")

        bar.focusSearch()
        guard let editor = bar.search.textField.currentEditor() as? NSTextView else {
            check("[edge] search field editor", false, "no editor after focusSearch")
            return
        }
        check("[edge] search editor is plain text with undo", !editor.isRichText && !editor.importsGraphics
              && editor.allowsUndo && editor.isFieldEditor,
              "rich \(editor.isRichText), graphics \(editor.importsGraphics), undo \(editor.allowsUndo)")

        // A rich paste (bold red Helvetica 24) must arrive as plain text in the capsule's font.
        let rich = NSAttributedString(string: "Oasis", attributes: [
            .font: NSFont(name: "Helvetica-Bold", size: 24) ?? NSFont.boldSystemFont(ofSize: 24),
            .foregroundColor: NSColor.red])
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.noahtsutsui.oldtunes.harness.edges"))
        pasteboard.clearContents()
        pasteboard.writeObjects([rich])
        editor.selectAll(nil)
        _ = editor.readSelection(from: pasteboard)
        pasteboard.releaseGlobally()
        let storage = editor.textStorage
        let font = storage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let color = storage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        check("[edge] rich paste lands as plain text", bar.searchText == "Oasis" && font?.pointSize == Theme.font.pointSize
              && color?.usingColorSpace(.sRGB) != NSColor.red.usingColorSpace(.sRGB),
              "text '\(bar.searchText)', font \(font?.fontName ?? "nil") \(font?.pointSize ?? 0), callbacks \(changes)")

        // Integration may set searchText while the user is typing (e.g. clearing on scope change).
        changes.removeAll()
        Probe.type(window, "abc")
        bar.searchText = "xyz"
        let current = bar.search.textField.currentEditor() as? NSTextView
        check("[edge] searchText set while typing keeps focus", bar.search.isFocused && current?.string == "xyz"
              && bar.searchText == "xyz",
              "focused \(bar.search.isFocused), editor '\(current?.string ?? "nil")', callbacks \(changes)")
        Probe.type(window, "!")
        check("[edge] typing continues after a programmatic set", bar.searchText.hasSuffix("!")
              && changes.last == bar.searchText, "text '\(bar.searchText)', last callback '\(changes.last ?? "")'")

        // Escape on an empty field does nothing at all.
        bar.searchText = ""
        changes.removeAll()
        if let escape = Probe.key(window, "\u{1b}", keyCode: 53) { window.sendEvent(escape) }
        check("[edge] Escape on empty search", changes.isEmpty && bar.search.isFocused, "callbacks \(changes)")

        // A long query scrolls inside the capsule instead of spilling over its end.
        let long = "Jack Johnson Brushfire Fairytales Flake Bubble Toes Sitting Waiting Wishing Taylor"
        bar.searchText = long
        bar.focusSearch()
        (bar.search.textField.currentEditor() as? NSTextView)?.moveToEndOfDocument(nil)
        await Probe.pause(0.2)
        if let px = snapshot(window, "chrome_search_long.png", out: out) {
            let capsule = bar.convert(bar.searchCapsuleFrame, to: nil)
            let top = window.frame.height - capsule.maxY
            // Columns just inside the capsule's right end hold only white fill and the border ramp.
            let inkRight = (0..<Int(capsule.height * px.scale)).contains { dy in
                let c = px.rgb(pixelX: Int((capsule.maxX - 6) * px.scale), pixelY: Int(top * px.scale) + dy)
                return c.r < 0x60 && abs(c.r - c.b) < 30
            }
            let inkLeft = (0..<Int(capsule.height * px.scale)).contains { dy in
                let c = px.rgb(pixelX: Int((capsule.minX + 23) * px.scale), pixelY: Int(top * px.scale) + dy)
                return c.r < 0x60
            }
            check("[edge] long search text stays inside the capsule", !inkRight && !inkLeft,
                  "ink in the right end \(inkRight), over the magnifier gap \(inkLeft)")
        }
        bar.searchText = ""
        window.makeFirstResponder(nil)
        bar.onSearchTextChange = nil
    }

    // MARK: - LCD

    private static func lcdEdgeChecks(_ controller: MetalWindowController, _ window: MetalWindow, out: URL) async {
        let bar = controller.controlBar
        var seeks: [TimeInterval] = []
        bar.onSeek = { seeks.append($0) }

        // Non-Latin and very long text: drawn, centred, and truncated before the end buttons.
        var state = sampleState()
        state.nowPlaying?.title = "群青日和 (Live at 武道館) 🎸 — " + String(repeating: "Very Long Title ", count: 8)
        state.nowPlaying?.artist = "東京事変"
        state.nowPlaying?.album = "Discovery"
        bar.update(state)
        await Probe.pause(0.2)
        if let px = snapshot(window, "chrome_lcd_unicode.png", out: out) {
            let lcd = bar.convert(bar.lcd.frame, to: nil)
            let lcdTop = window.frame.height - lcd.maxY
            func ink(rows: ClosedRange<CGFloat>, columns: ClosedRange<CGFloat>) -> Int {
                var count = 0
                for y in stride(from: rows.lowerBound, through: rows.upperBound, by: 0.5) {
                    for x in stride(from: columns.lowerBound, through: columns.upperBound, by: 0.5) {
                        let c = px.rgb(lcd.minX + x, lcdTop + y)
                        if c.r < 0x70 && c.g < 0x70 { count += 1 }
                    }
                }
                return count
            }
            let line1 = ink(rows: 5...16, columns: 26...(lcd.width - 26))
            let line2 = ink(rows: 18...29, columns: 26...(lcd.width - 26))
            // Between each end button (ends at 16 pt) and the text inset (26 pt): never ink.
            let spill = ink(rows: 5...29, columns: 18...24) + ink(rows: 5...29, columns: (lcd.width - 24)...(lcd.width - 18))
            check("[edge] LCD draws CJK, emoji and long text inside its margins", line1 > 40 && line2 > 20 && spill == 0,
                  "ink line 1 \(line1), line 2 \(line2), in the end-button margins \(spill)")
        }
        bar.update(sampleState())

        // The song changes during a scrub drag: no seek into the new song.
        let scrub = bar.lcd.convert(bar.lcd.scrubberRect, to: nil)
        let sy = window.frame.height - scrub.midY
        let x0 = scrub.minX + 0.3 * scrub.width, x1 = scrub.minX + 0.7 * scrub.width
        Probe.mouse(.leftMouseDown, window, at: NSPoint(x: x0, y: sy))
        Probe.mouse(.leftMouseDragged, window, at: NSPoint(x: x1, y: sy))
        var nextSong = sampleState()
        nextSong.nowPlaying?.id = 2
        nextSong.nowPlaying?.title = "Flake"
        nextSong.position = 1
        bar.update(nextSong)
        Probe.mouse(.leftMouseUp, window, at: NSPoint(x: x1, y: sy))
        check("[edge] song change mid-scrub drops the seek", seeks.isEmpty && !bar.lcd.isScrubbing
              && abs(bar.lcd.displayedPosition - 1) < 0.01,
              "seeks \(seeks), shows \(bar.lcd.displayedPosition) s")

        // Playback stops during a drag: no seek, no crash, idle text back.
        Probe.mouse(.leftMouseDown, window, at: NSPoint(x: x0, y: sy))
        bar.update(PlaybackState())
        Probe.mouse(.leftMouseUp, window, at: NSPoint(x: x1, y: sy))
        check("[edge] playback stopping mid-scrub drops the seek", seeks.isEmpty && !bar.lcd.isScrubbing,
              "seeks \(seeks), lines \(bar.lcd.lines)")
        bar.update(sampleState())

        // After a seek whose result never arrives, the thumb returns to the player's position and
        // the LCD redraws even though the state did not change.
        Probe.click(window, at: NSPoint(x: x1, y: sy))
        let target = seeks.last ?? -1
        await Probe.pause(1.6)
        // NSView.needsDisplay reads back false on macOS 27 even right after it is set, so the
        // window's flag is the observable one.
        window.displayIfNeeded()
        let cleanBefore = !window.viewsNeedDisplay
        bar.update(sampleState())
        let dirtied = window.viewsNeedDisplay
        check("[edge] stale seek target expires and redraws", seeks.count == 1 && cleanBefore && dirtied
              && abs(bar.lcd.displayedPosition - 45) < 0.01,
              String(format: "seek %.1f s, then shows %.1f s; window clean before %@, needs display after %@",
                     target, bar.lcd.displayedPosition, "\(cleanBefore)", "\(dirtied)"))
        bar.onSeek = nil
    }

    // MARK: - Window

    private static func windowEdgeChecks(_ controller: MetalWindowController, _ window: MetalWindow, out: URL) async {
        let titleBar = controller.metalView.titleBar
        check("[edge] title bar drags an inactive window on the first click", titleBar.acceptsFirstMouse(for: nil),
              "acceptsFirstMouse \(titleBar.acceptsFirstMouse(for: nil))")

        // Glyphs forced on (as after clicking an orb that moved the window away) clear on the next
        // activity change unless the mouse really is over the group.
        let lights = titleBar.trafficLights
        lights.isHovering = true
        titleBar.windowActivityChanged()
        let mouse = lights.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        check("[edge] orb glyphs follow the real mouse", lights.isHovering == lights.bounds.contains(mouse),
              "hovering \(lights.isHovering), mouse over group \(lights.bounds.contains(mouse))")

        // Pressed looks: the zoom orb, play and shuffle held down at once (each view gets its own
        // mouse-down directly), photographed, then dragged off and released so nothing fires.
        let held: [(NSView, NSPoint)] = [
            (lights, NSPoint(x: 58.5, y: 12.5)),
            (controller.controlBar.playButton,
             NSPoint(x: Theme.Metrics.playButton.centerX, y: Theme.Metrics.transportCenterY)),
            (controller.bottomBar.shuffleButton, NSPoint(x: 76.5, y: window.frame.height - 17))]
        let frameBefore = window.frame
        var fired: [String] = []
        controller.controlBar.onPlayPause = { fired.append("playPause") }
        controller.bottomBar.onShuffleToggle = { fired.append("shuffle") }
        let lastOrb = lights.lastPerformed
        for (view, p) in held {
            if let e = mouseEvent(.leftMouseDown, window, p) { view.mouseDown(with: e) }
        }
        _ = snapshot(window, "chrome_pressed.png", out: out)
        for (view, _) in held {
            if let e = mouseEvent(.leftMouseDragged, window, NSPoint(x: 300, y: 300)) { view.mouseDragged(with: e) }
            if let e = mouseEvent(.leftMouseUp, window, NSPoint(x: 300, y: 300)) { view.mouseUp(with: e) }
        }
        check("[edge] press, drag off and release fires nothing", fired.isEmpty && lights.lastPerformed == lastOrb
              && window.frame == frameBefore, "fired \(fired), frame kept \(window.frame == frameBefore)")
        controller.controlBar.onPlayPause = nil
        controller.bottomBar.onShuffleToggle = nil

        // Integration sets its own window delegate: the chrome must keep working.
        let delegate = ChromeHarnessDelegate()
        window.delegate = delegate
        controller.controlBar.focusSearch()
        let editor = controller.controlBar.search.textField.currentEditor() as? NSTextView
        check("[edge] private search editor survives a foreign delegate", editor != nil
              && editor !== window.fieldEditor(false, for: nil) && editor?.insertionPointColor == Theme.textPrimary,
              "editor \(editor.map { String(describing: type(of: $0)) } ?? "nil")")
        window.makeFirstResponder(nil)
        let otherFrame = NSRect(x: window.frame.minX + 40, y: window.frame.minY - 60, width: 200, height: 80)
        let other = NSWindow(contentRect: otherFrame,
                             styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.makeKeyAndOrderFront(nil)
        let resigned = await Probe.wait(upTo: 2) { !window.isKeyWindow && !window.isMainWindow }
        await Probe.pause(0.2)
        if let px = snapshot(window, "chrome_inactive_foreign_delegate.png", out: out) {
            let orb = px.rgb(16.5, 14)
            let gray = abs(orb.r - orb.g) < 10 && abs(orb.g - orb.b) < 10
            check("[edge] orbs go gray with a foreign delegate", resigned && gray,
                  "window resigned \(resigned), close orb reads \(Probe.hex(orb))")
        }
        other.close()
        _ = await makeKey(window)
        if let px = snapshot(window, "chrome_active_foreign_delegate.png", out: out) {
            let orb = px.rgb(16.5, 14)
            check("[edge] orbs light up again with a foreign delegate", !window.isKeyWindow || orb.r > orb.g + 60,
                  "key \(window.isKeyWindow), close orb reads \(Probe.hex(orb))")
        }
        window.delegate = nil
        _ = delegate

        // A window that never received any state: idle LCD, no scrubber, no field focused.
        let fresh = MetalWindowController()
        fresh.showWindow(nil)
        if let w = fresh.metalWindow {
            w.setFrameOrigin(NSPoint(x: window.frame.minX + 30, y: window.frame.minY - 30))
            let freshKey = await makeKey(w)
            check("[edge] fresh window opens with search unfocused", !fresh.controlBar.search.isFocused || !freshKey,
                  "key \(freshKey), first responder \(w.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")")
            if let px = snapshot(w, "chrome_fresh.png", out: out) {
                let scrub = fresh.controlBar.lcd.convert(fresh.controlBar.lcd.scrubberRect, to: nil)
                let c = px.rgb(scrub.midX, w.frame.height - scrub.minY - 0.25)
                check("[edge] fresh window: idle LCD without a scrubber", fresh.controlBar.lcd.lines == ("oldTunes", "")
                      && Probe.near(c, 0xD7DBC0, tolerance: 4),
                      "lines \(fresh.controlBar.lcd.lines), scrubber outline row reads \(Probe.hex(c))")
            }
            w.close()
        }

        // When integration names an initial responder, the window leaves AppKit's choice alone.
        let named = MetalWindowController()
        named.window?.initialFirstResponder = named.controlBar.search.textField
        named.showWindow(nil)
        if let w = named.metalWindow {
            let namedKey = await makeKey(w)
            check("[edge] an initialFirstResponder from integration is respected",
                  named.controlBar.search.isFocused || !namedKey,
                  "key \(namedKey), search focused \(named.controlBar.search.isFocused)")
            w.close()
        }
        _ = await makeKey(window)
    }
}

/// A mouse event at a top-left-origin window point, for handing straight to one view.
@MainActor
private func mouseEvent(_ type: NSEvent.EventType, _ window: NSWindow, _ p: NSPoint) -> NSEvent? {
    NSEvent.mouseEvent(with: type, location: ChromeHarnessProbe.windowPoint(window, p), modifierFlags: [],
                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
}

/// Stands in for whatever delegate integration installs.
@MainActor
private final class ChromeHarnessDelegate: NSObject, NSWindowDelegate {}
