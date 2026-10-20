import AppKit

/// Independent checks added in verification: the places the first harness drove through hooks
/// (performClick, selectTab, onAdd) are driven here with mouse events through NSApp.sendEvent,
/// so the window's own hit-testing — including the transparent system titlebar over the
/// hand-drawn one — decides who gets the click. Also the races a person can hit: pressing OK
/// twice while a save waits on a sheet or on Music, and typing before a slow read finishes.
///
/// OLDTUNES_METADATA_STEPS=verify runs only this (it reuses fixtures from an earlier run).
@MainActor
enum HarnessVerify {
    static func run(fixturesDir: URL, evidence: URL, tally: HarnessTally) async {
        NSApp.activate()
        let anchor = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: .borderless,
                              backing: .buffered, defer: false)
        anchor.alphaValue = 0
        anchor.ignoresMouseEvents = true
        anchor.isReleasedWhenClosed = false
        anchor.orderBack(nil)
        defer { anchor.orderOut(nil) }
        let savedSuppress = UserDefaults.standard.object(forKey: GetInfoPrompts.suppressFileWarningKey)
        // The §6.6 sheet is covered by HarnessGetInfo; here it would only get in the way.
        UserDefaults.standard.set(true, forKey: GetInfoPrompts.suppressFileWarningKey)
        defer {
            if let savedSuppress { UserDefaults.standard.set(savedSuppress, forKey: GetInfoPrompts.suppressFileWarningKey) }
            else { UserDefaults.standard.removeObject(forKey: GetInfoPrompts.suppressFileWarningKey) }
        }

        unitChecks(tally: tally)
        await fileEdges(fixturesDir: fixturesDir, tally: tally)

        let source = fixturesDir.appendingPathComponent("gen-aac.m4a")
        let fileURL = fixturesDir.appendingPathComponent("verify-file.m4a")
        try? FileManager.default.removeItem(at: fileURL)
        guard (try? FileManager.default.copyItem(at: source, to: fileURL)) != nil else {
            tally.check(false, "verify: fixture gen-aac.m4a exists (run the full harness once first)")
            return
        }
        var fileTrack = HarnessFixtures.folderTrack(id: 701, url: fileURL)
        fileTrack.title = "Verify File"
        var cloud = Track.blank(id: 702)
        cloud.persistentID = 0x1234_5678_9ABC_DEF0
        cloud.title = "Verify Cloud"
        cloud.artist = "Library Artist"
        cloud.isCloud = true
        var cloud2 = cloud
        cloud2.id = 703
        cloud2.persistentID = 0x0FED_CBA9_8765_4321
        cloud2.title = "Verify Cloud Two"

        let library = MetadataHarnessLibrary([fileTrack, cloud, cloud2])
        await pointer(fileTrack: fileTrack, cloud: cloud, library: library, evidence: evidence, tally: tally)
        await doubleSave(cloud: cloud, library: library, tally: tally)
        await earlyTyping(cloud: cloud, cloud2: cloud2, library: library, tally: tally)
        await tabLoop(cloud: cloud, library: library, tally: tally)
        await longText(library: library, evidence: evidence, tally: tally)
        await pulseTimers(library: library, cloud: cloud, tally: tally)
    }

    /// Every window and sheet has a pulsing default button; opening and closing a dozen Get Info
    /// windows must not leave a dozen 30 Hz timers behind.
    private static func pulseTimers(library: MetadataHarnessLibrary, cloud: Track, tally: HarnessTally) async {
        await settle(0.3)
        let baseline = AquaButton.livePulseTimers
        var peak = baseline
        for _ in 0..<12 {
            let c = GetInfoWindowController(tracks: [cloud], visibleOrder: [cloud.id],
                                            editor: TagEditor(cloud: RecordingCloudWriter(answers: [.granted])),
                                            library: library, artwork: { _ in nil })
            c.showWindow(nil)
            await settle(0.05)
            peak = max(peak, AquaButton.livePulseTimers)
            c.close()
        }
        await settle(0.5)
        let after = AquaButton.livePulseTimers
        Log.info("pulse timers: baseline \(baseline), peak while open \(peak), after closing \(after)")
        tally.check(peak > baseline && after <= baseline, "closed Get Info windows stop their pulse timers",
                    detail: "live timers \(baseline) -> peak \(peak) -> \(after)")
    }

    // MARK: - Pure checks

    private static func unitChecks(tally: HarnessTally) {
        // Where: shortened from the middle, never past its box, file name kept.
        let long = "/Users/noah/Music/Music/Media.localized/Music/" + String(repeating: "Very Long Folder Name/", count: 20) + "Song.m4a"
        let cut = GetInfoFormat.middleTruncated(long, columns: 120)
        tally.check(cut.count <= 120 && cut.hasSuffix("Name/Song.m4a") && cut.hasPrefix("/Users/noah/") && cut.contains("…"),
                    "Where path shortened from the middle keeps the file name", detail: cut)
        let short = "/Users/noah/Music/x.mp3"
        tally.check(GetInfoFormat.middleTruncated(short, columns: 120) == short, "a short Where path is left alone")
        let wide = "/Users/noah/" + String(repeating: "ＳＴＵＤＹ", count: 30) + ".m4a"
        let wideCut = GetInfoFormat.middleTruncated(wide, columns: 60)
        let wideCols = wideCut.reduce(0) { $0 + ($1.unicodeScalars.contains { $0.value >= 0x1100 } ? 2 : 1) }
        tally.check(wideCols <= 60 && wideCut.hasSuffix(".m4a"), "full-width characters count as two columns",
                    detail: "\(wideCols) columns: \(wideCut)")

        // ScriptingBridge error replies become sentences, never exceptions.
        func sbError(_ n: Int) -> NSError {
            NSError(domain: "NSOSStatusErrorDomain", code: n,
                    userInfo: ["ErrorNumber": NSNumber(value: n), "ErrorString": "Music got an error."])
        }
        tally.check(MusicScriptingSession.describe(sbError(-1743), what: "x") == MusicAutomation.deniedReason,
                    "SB -1743 maps to the where-to-enable reason")
        tally.check(MusicScriptingSession.describe(sbError(-1712), what: "Save").contains("didn’t answer in time"),
                    "SB timeout maps to a retry message")
        let other = MusicScriptingSession.describe(sbError(-10003), what: "Music didn’t accept the change to year")
        tally.check(other.contains("Music got an error.") && other.contains("-10003"),
                    "other SB errors keep Music's text and number", detail: other)
    }

    // MARK: - Files at the edges

    private static func fileEdges(fixturesDir: URL, tally: HarnessTally) async {
        let fm = FileManager.default
        let editor = TagEditor(cloud: RecordingCloudWriter(answers: [.denied]))
        for name in ["gen.mp3", "gen-aac.m4a", "gen.flac"] {
            let src = fixturesDir.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else { continue }
            let url = fixturesDir.appendingPathComponent("edge-\(name)")
            try? fm.removeItem(at: url)
            guard (try? fm.copyItem(at: src, to: url)) != nil else { continue }
            let t = HarnessFixtures.folderTrack(id: 750, url: url)

            // Huge and unusual text.
            var p = TagPatch()
            p.comments = String(repeating: "Long comment line ✓ ", count: 3_000)
            p.title = "Emoji 🎸🥁 · עברית · e\u{301}te\u{301} · 日本語"
            p.artist = "  leading and trailing spaces  "
            let r = await editor.apply(p, to: [t])
            let back = try? await editor.readFields(of: t)
            tally.check(r.failed.isEmpty && back?.comments == p.comments && back?.title == p.title && back?.artist == p.artist,
                        "[\(name)] 60,000-character comment, emoji, RTL, combining marks and spaces round-trip",
                        detail: "failed=\(r.failed.map(\.reason)) title=\(back?.title ?? "nil") commentLen=\(back?.comments.count ?? -1)")

            // Nothing to change: the file is not rewritten at all.
            let before = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? nil
            try? await Task.sleep(for: .milliseconds(1100))
            let empty = await editor.apply(TagPatch(), to: [t])
            let after = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? nil
            tally.check(empty.succeeded == [t.id] && before == after, "[\(name)] an empty patch leaves the file untouched")

            // Five saves racing to one file: all succeed, one wins whole, nothing left behind.
            let titles = (1...5).map { "Race \($0)" }
            let target = t
            let results = await withTaskGroup(of: TagApplyResult.self) { group in
                for title in titles {
                    group.addTask { @Sendable in
                        var rp = TagPatch()
                        rp.title = title
                        rp.genre = "Genre for \(title)"
                        return await editor.apply(rp, to: [target])
                    }
                }
                var all: [TagApplyResult] = []
                for await r in group { all.append(r) }
                return all
            }
            let final = try? await editor.readFields(of: t)
            let consistent = final.map { titles.contains($0.title) && $0.genre == "Genre for \($0.title)" } ?? false
            tally.check(results.allSatisfy { $0.failed.isEmpty } && consistent
                        && HarnessRoundTrip.leftovers(near: url).isEmpty && final?.comments == p.comments,
                        "[\(name)] five concurrent saves: all succeed, one wins whole, no temp left",
                        detail: "title=\(final?.title ?? "nil") genre=\(final?.genre ?? "nil")")
        }
    }

    // MARK: - Mouse

    private static func pointer(fileTrack: Track, cloud: Track, library: MetadataHarnessLibrary, evidence: URL, tally: HarnessTally) async {
        let editor = TagEditor(cloud: RecordingCloudWriter(answers: [.granted]))
        let c = GetInfoWindowController(tracks: [fileTrack], visibleOrder: [fileTrack.id], editor: editor,
                                        library: library, artwork: { _ in nil })
        c.permissionChecker = RecordingCloudWriter(answers: [.granted])
        c.showWindow(nil)
        await settle(0.6)
        guard let window = c.window, let info = c.infoPane else { return }
        // A click on an inactive app's window only activates it. Other OldTunes runs (or anything
        // else) can hold the focus for a moment, so ask again until this window is key.
        _ = await waitFor(5) {
            if NSApp.isActive && window.isKeyWindow { return true }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return false
        }
        let titlebar = window.frame.height - window.contentLayoutRect.height
        Log.info("verify: system titlebar \(titlebar) pt over a \(AquaStyle.titleBarHeight) pt painted one; app active=\(NSApp.isActive) key=\(window.isKeyWindow)")

        // Tabs: the strip is at y 34…55 in the window's flipped face.
        let strip = tabStripFrame(in: window)
        click(window, at: NSPoint(x: strip.maxX - 30, y: strip.midY))
        await settle(0.2)
        tally.check(c.selectedTab == 2, "click on the Artwork tab selects it", detail: "tab=\(c.selectedTab)")
        click(window, at: NSPoint(x: strip.midX, y: strip.midY))
        await settle(0.2)
        tally.check(c.selectedTab == 1, "click on the Info tab selects it", detail: "tab=\(c.selectedTab)")

        // A click in the Artist box edits it.
        click(window, at: center(of: info.artist, in: window))
        await settle(0.2)
        tally.check(editingField(window) === info.artist.field, "click in Artist puts the caret there")

        // The hand-drawn compilation checkbox toggles under the pointer.
        let wasOn = info.compilation.isOn
        click(window, at: NSPoint(x: frame(of: info.compilation, in: window).minX + 7, y: frame(of: info.compilation, in: window).midY))
        await settle(0.2)
        tally.check(info.compilation.isOn != wasOn && c.currentPatch().isCompilation == !wasOn,
                    "click toggles 'Part of a compilation' and it reaches the patch")
        snap(window, "verify-pointer-info", evidence)

        // Cancel under the pointer closes without saving.
        let before = await library.updateCount()
        if let cancel = button(titled: "Cancel", in: window) {
            click(window, at: center(of: cancel, in: window))
        }
        let closed = await waitFor(3) { !window.isVisible }
        let after = await library.updateCount()
        tally.check(closed && after == before, "click on Cancel closes without saving")

        // The close orb sits under the system's transparent titlebar.
        let c2 = GetInfoWindowController(tracks: [cloud], visibleOrder: [cloud.id], editor: editor,
                                         library: library, artwork: { _ in nil })
        c2.permissionChecker = RecordingCloudWriter(answers: [.granted])
        c2.showWindow(nil)
        await settle(0.6)
        if let w2 = c2.window {
            click(w2, at: NSPoint(x: 15, y: 11))
            let orbClosed = await waitFor(3) { !w2.isVisible }
            tally.check(orbClosed, "click on the red close orb closes the window")
            if w2.isVisible { c2.close() }
        }

        // Multiple: the apply boxes and the compilation pop-up.
        var other = cloud
        other.id = 799
        other.persistentID = 42
        await library.add(other)
        let c3 = GetInfoWindowController(tracks: [cloud, other], visibleOrder: [cloud.id, other.id], editor: editor,
                                         library: library, artwork: { _ in nil })
        c3.permissionChecker = RecordingCloudWriter(answers: [.granted])
        c3.showWindow(nil)
        await settle(0.6)
        if let w3 = c3.window, let pane = c3.multiplePane, let yearBox = pane.checkboxes[.year] {
            click(w3, at: center(of: yearBox, in: w3))
            await settle(0.2)
            tally.check(yearBox.isOn, "click ticks the Year apply box in Multiple Song Information")
            pane.compilation.choose(1)
            await settle(0.1)
            let patch = c3.currentPatch()
            tally.check(pane.checkboxes[.compilation]?.isOn == true && patch.isCompilation == true && patch.year == 0,
                        "choosing Yes in the compilation pop-up ticks its apply box and sets the patch",
                        detail: "\(patch.changedFieldNames)")
            snap(w3, "verify-multi-popup", evidence)
            c3.close()
        }
    }

    // MARK: - Pressing OK twice

    /// A cloud save waits on the Automation check (here a slow one) before anything is written;
    /// Return pressed again in that window must not start a second save.
    private static func doubleSave(cloud: Track, library: MetadataHarnessLibrary, tally: HarnessTally) async {
        let writer = RecordingCloudWriter(answers: [.granted])
        let c = GetInfoWindowController(tracks: [cloud], visibleOrder: [cloud.id], editor: TagEditor(cloud: writer),
                                        library: library, artwork: { _ in nil })
        c.permissionChecker = SlowPermission(delay: 1.0)
        c.showWindow(nil)
        await settle(0.5)
        guard let window = c.window, let info = c.infoPane else { return }
        c.selectTab(1)
        window.makeFirstResponder(info.name.field)
        replaceText(in: window, with: "Saved once")
        let before = await library.updateCount()
        key(window, code: 36, chars: "\r")
        await settle(0.2)
        key(window, code: 36, chars: "\r")
        await settle(0.2)
        key(window, code: 36, chars: "\r")
        _ = await waitFor(5) { !window.isVisible }
        await settle(0.3)
        let writes = await writer.recordedWrites()
        let after = await library.updateCount()
        tally.check(writes.count == 1 && after == before + 1, "Return pressed three times during a save writes once",
                    detail: "writes=\(writes.count) library updates=\(after - before)")
        if window.isVisible { c.close() }
    }

    // MARK: - Typing before the read finishes

    private static func earlyTyping(cloud: Track, cloud2: Track, library: MetadataHarnessLibrary, tally: HarnessTally) async {
        // The "file" says something different from the library, and takes a while to say it.
        var fromFile = TagFields(track: cloud)
        fromFile.comments = "From the file"
        fromFile.artist = "File Artist"
        let slow = SlowEditor(delay: 1.0, fields: [cloud.id: fromFile])
        let c = GetInfoWindowController(tracks: [cloud], visibleOrder: [cloud.id], editor: slow,
                                        library: library, artwork: { _ in nil })
        c.permissionChecker = RecordingCloudWriter(answers: [.granted])
        c.showWindow(nil)
        c.selectTab(1)
        await settle(0.1)
        guard let window = c.window, let info = c.infoPane else { return }
        window.makeFirstResponder(info.name.field)
        replaceText(in: window, with: "Typed early")
        await settle(1.5)
        let patch = c.currentPatch()
        tally.check(info.name.stringValue == "Typed early" && info.comments.stringValue == "From the file"
                    && info.artist.stringValue == "File Artist" && patch.changedFieldNames == ["title"],
                    "a name typed before the read finished survives it, and only the name is saved",
                    detail: "name=\(info.name.stringValue) comments=\(info.comments.stringValue) patch=\(patch.changedFieldNames)")
        c.close()

        // Multiple: ticked boxes and their values survive the second load.
        var f1 = TagFields(track: cloud); f1.genre = "Same"
        var f2 = TagFields(track: cloud2); f2.genre = "Same"
        // Reads are sequential, so the second load lands after 2 × 0.6 s.
        let slowMulti = SlowEditor(delay: 0.6, fields: [cloud.id: f1, cloud2.id: f2])
        let m = GetInfoWindowController(tracks: [cloud, cloud2], visibleOrder: [], editor: slowMulti,
                                        library: library, artwork: { _ in nil })
        m.permissionChecker = RecordingCloudWriter(answers: [.granted])
        m.showWindow(nil)
        await settle(0.1)
        guard let mw = m.window, let pane = m.multiplePane, let composer = pane.fields[.composer] else { return }
        mw.makeFirstResponder(composer.field)
        replaceText(in: mw, with: "Typed early")
        await settle(2.2)
        let mp = m.currentPatch()
        tally.check(pane.checkboxes[.composer]?.isOn == true && composer.stringValue == "Typed early"
                    && pane.fields[.genre]?.stringValue == "Same" && mp.changedFieldNames == ["composer"],
                    "multi: an edit made before the files were read survives, and the shared value still fills in",
                    detail: "box=\(pane.checkboxes[.composer]?.isOn ?? false) composer=\(composer.stringValue) genre=\(pane.fields[.genre]?.stringValue ?? "") patch=\(mp.changedFieldNames)")
        m.close()
    }

    // MARK: - Tab order

    private static func tabLoop(cloud: Track, library: MetadataHarnessLibrary, tally: HarnessTally) async {
        let c = GetInfoWindowController(tracks: [cloud], visibleOrder: [cloud.id],
                                        editor: TagEditor(cloud: RecordingCloudWriter(answers: [.granted])),
                                        library: library, artwork: { _ in nil })
        c.permissionChecker = RecordingCloudWriter(answers: [.granted])
        c.showWindow(nil)
        await settle(0.4)
        c.selectTab(1)
        guard let window = c.window, let info = c.infoPane else { return }
        let expected: [(String, NSView)] = [
            ("Name", info.name.field), ("Artist", info.artist.field), ("Year", info.year.field),
            ("Album Artist", info.albumArtist.field), ("BPM", info.bpm.field), ("Album", info.album.field),
            ("Track", info.trackNumber.field), ("of", info.trackCount.field), ("Grouping", info.grouping.field),
            ("Disc", info.discNumber.field), ("of", info.discCount.field), ("Composer", info.composer.field),
            ("Comments", info.comments.textView), ("Genre", info.genre.field), ("Name", info.name.field),
        ]
        var seen: [String] = []
        var ok = true
        for (n, (label, view)) in expected.enumerated() {
            let focused: NSView? = editingField(window) ?? (window.firstResponder as? NSView)
            let what = focused.map { ($0.identifier?.rawValue ?? "") + "<\(type(of: $0))>" } ?? "nil"
            seen.append(focused === view ? label : "≠\(label)(got \(what))")
            if focused !== view { ok = false }
            if n < expected.count - 1 { key(window, code: 48, chars: "\t") }
            await settle(0.05)
        }
        tally.check(ok, "Tab walks every Info field in reading order and wraps", detail: seen.joined(separator: " → "))
        c.close()
    }

    // MARK: - Long text

    private static func longText(library: MetadataHarnessLibrary, evidence: URL, tally: HarnessTally) async {
        var t = Track.blank(id: 720)
        t.title = "A Very Long Song Title That Goes On And On (Extended Club Remix featuring Everyone) [Remastered 2005 Deluxe Edition]"
        t.artist = String(repeating: "Artist ", count: 30)
        t.album = "Album"
        t.fileURL = URL(fileURLWithPath: "/Users/noah/Music/Music/Media.localized/Music/_S p a c e d N a m e °/Unknown Album/"
                        + String(repeating: "ＷＩＤＥＲ  ＴＨＡＮ   ＢＯＸ ", count: 6) + "[1234567890].m4a")
        t.bucket = .missing
        await library.add(t)
        let c = GetInfoWindowController(tracks: [t], visibleOrder: [t.id],
                                        editor: TagEditor(cloud: RecordingCloudWriter(answers: [.granted])),
                                        library: library, artwork: { _ in nil })
        c.permissionChecker = RecordingCloudWriter(answers: [.granted])
        c.showWindow(nil)
        c.selectTab(0)
        await settle(0.5)
        snap(c.window, "verify-long-summary", evidence)
        c.selectTab(1)
        await settle(0.2)
        snap(c.window, "verify-long-info", evidence)
        tally.check(c.window?.title == t.title, "long title kept whole in the window title (drawn truncated)")
        c.close()
    }

    // MARK: - Driving

    private static func settle(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    private static func waitFor(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    /// A left click at a point in the window's flipped face, delivered the way AppKit delivers a
    /// real one: mouse-down through NSApp.sendEvent (so the window hit-tests, titlebar included),
    /// with the mouse-up already queued for any tracking loop.
    private static func click(_ window: NSWindow, at flipped: NSPoint) {
        guard let face = window.contentView else { return }
        let location = face.convert(flipped, to: nil)
        let t = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: t,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                                            clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: t + 0.05,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 2,
                                          clickCount: 1, pressure: 0) else { return }
        NSApp.postEvent(up, atStart: false)
        NSApp.sendEvent(down)
    }

    private static func key(_ window: NSWindow, code: UInt16, chars: String) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: chars, charactersIgnoringModifiers: chars,
                                           isARepeat: false, keyCode: code) else { return }
        NSApp.sendEvent(event)
    }

    private static func replaceText(in window: NSWindow, with text: String) {
        guard let editor = window.firstResponder as? NSTextView else { return }
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    private static func editingField(_ window: NSWindow) -> NSView? {
        (window.firstResponder as? NSTextView)?.delegate as? NSTextField
    }

    private static func frame(of view: NSView, in window: NSWindow) -> NSRect {
        guard let face = window.contentView else { return .zero }
        return view.convert(view.bounds, to: face)
    }

    private static func center(of view: NSView, in window: NSWindow) -> NSPoint {
        let f = frame(of: view, in: window)
        return NSPoint(x: f.midX, y: f.midY)
    }

    private static func tabStripFrame(in window: NSWindow) -> NSRect {
        guard let strip = window.contentView?.subviews.first(where: { $0 is AquaTabStrip }) else { return .zero }
        return frame(of: strip, in: window)
    }

    private static func button(titled title: String, in window: NSWindow) -> AquaButton? {
        window.contentView?.subviews.compactMap { $0 as? AquaButton }.first { $0.title == title }
    }

    private static func snap(_ window: NSWindow?, _ name: String, _ dir: URL) {
        guard let window else { return }
        window.displayIfNeeded()
        let url = dir.appendingPathComponent("\(name).png")
        if Snapshot.write(window, to: url) { Log.info("snapshot: \(url.path)") }
    }
}

/// A TagEditing stand-in whose reads are slow and differ from the library, for the
/// typed-before-the-read-finished checks. Saves succeed and are recorded.
actor SlowEditor: TagEditing {
    private let delay: Double
    private let fields: [Track.ID: TagFields]
    private(set) var applied: [TagPatch] = []

    init(delay: Double, fields: [Track.ID: TagFields]) {
        self.delay = delay
        self.fields = fields
    }

    func readFields(of track: Track) async throws -> TagFields {
        try? await Task.sleep(for: .seconds(delay))
        return fields[track.id] ?? TagFields(track: track)
    }

    func apply(_ patch: TagPatch, to tracks: [Track]) async -> TagApplyResult {
        applied.append(patch)
        return TagApplyResult(succeeded: tracks.map(\.id), failed: [])
    }
}

/// Answers "granted" after a delay, like launching Music hidden and asking TCC does.
struct SlowPermission: MusicPermissionChecking {
    var delay: Double
    func permission(askIfNeeded: Bool) async -> MusicAutomationStatus {
        try? await Task.sleep(for: .seconds(delay))
        return .granted
    }
}
