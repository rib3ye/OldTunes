import AppKit
import SFBAudioEngine

/// Requirement (e): Get Info for a cloud song, a file song and a three-song selection, each tab
/// photographed, plus the save flows driven by real key events — Tab, Return, Escape — and the
/// three sheets photographed while they are up.
@MainActor
enum HarnessGetInfo {
    private static var shots: [String] = []

    static func run(sample: HarnessLibrarySample, fixturesDir: URL, evidence: URL, tally: HarnessTally) async {
        NSApp.activate()
        // AppDelegate quits when the last window closes; an invisible anchor window keeps the
        // harness alive while Get Info windows open and close.
        let anchor = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: .borderless,
                              backing: .buffered, defer: false)
        anchor.alphaValue = 0
        anchor.ignoresMouseEvents = true
        anchor.isReleasedWhenClosed = false
        anchor.orderBack(nil)
        defer { anchor.orderOut(nil) }
        let savedSuppress = UserDefaults.standard.object(forKey: GetInfoPrompts.suppressFileWarningKey)
        UserDefaults.standard.removeObject(forKey: GetInfoPrompts.suppressFileWarningKey)
        GetInfoPrompts.resetFileWarningForThisLaunch()
        defer {
            if let savedSuppress { UserDefaults.standard.set(savedSuppress, forKey: GetInfoPrompts.suppressFileWarningKey) }
            else { UserDefaults.standard.removeObject(forKey: GetInfoPrompts.suppressFileWarningKey) }
        }

        let notifications = NotificationCounter()

        // --- Tracks -----------------------------------------------------------------------
        let clouds = sample.cloudSamples.prefix(3).enumerated().map { n, item in
            HarnessLibrarySample.track(from: item, id: Track.ID(501 + n))
        }
        var artworkByID: [Track.ID: Data] = [:]
        for (n, item) in sample.cloudSamples.prefix(3).enumerated() { artworkByID[Track.ID(501 + n)] = item.artwork }

        let setupEditor = TagEditor(cloud: RecordingCloudWriter(answers: [.denied]))
        let genMP3 = fixturesDir.appendingPathComponent("gen.mp3")
        // Without lame there is no gen.mp3; use the first copied real MP3 (realN-<file name>.mp3).
        let realMP3 = (try? FileManager.default.contentsOfDirectory(at: fixturesDir, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasPrefix("real") && $0.pathExtension.lowercased() == "mp3" }
            .min { $0.lastPathComponent < $1.lastPathComponent }
        let mp3Source = FileManager.default.fileExists(atPath: genMP3.path) ? genMP3 : (realMP3 ?? genMP3)
        guard let fileTrack = await makeFileTrack(id: 601, from: fixturesDir.appendingPathComponent("gen-aac.m4a"),
                                                  copyName: "getinfo-file.m4a", title: "Say Fixture (2005 Mix)",
                                                  hue: 0.58, editor: setupEditor, tally: tally),
              let multiA = await makeFileTrack(id: 602, from: fixturesDir.appendingPathComponent("gen-alac.m4a"),
                                               copyName: "multi-a.m4a", title: "Multi A", hue: 0.3,
                                               editor: setupEditor, tally: tally),
              let multiB = await makeFileTrack(id: 603, from: mp3Source,
                                               copyName: "multi-b.mp3", title: "Multi B", hue: 0.08,
                                               editor: setupEditor, tally: tally),
              clouds.count == 3 else {
            tally.check(false, "Get Info harness has its tracks")
            return
        }
        var protectedTrack = HarnessFixtures.folderTrack(id: 604, url: fixturesDir.appendingPathComponent("protected.m4p"))
        protectedTrack.title = "Protected Song"
        protectedTrack.kind = "Protected AAC audio file"

        let library = MetadataHarnessLibrary(clouds + [fileTrack, multiA, multiB, protectedTrack])
        let artworkTable = artworkByID
        let artwork: @Sendable (Track) async -> Data? = { track in
            if let data = artworkTable[track.id] { return data }
            return track.fileURL.flatMap(FileTagIO.readArtwork(at:))
        }

        // Every controller below starts with a recording permission checker, so no path can reach
        // MusicAppTagWriter (which would launch Music); sections E and F install their own.
        func controller(_ tracks: [Track], order: [Track.ID], editor: TagEditor) -> GetInfoWindowController {
            let c = GetInfoWindowController(tracks: tracks, visibleOrder: order, editor: editor,
                                            library: library, artwork: artwork)
            c.permissionChecker = RecordingCloudWriter(answers: [.denied])
            return c
        }

        // --- A. Cloud song, every tab -----------------------------------------------------
        do {
            let editor = TagEditor(cloud: RecordingCloudWriter(answers: [.granted]))
            let c = controller([clouds[0]], order: clouds.map(\.id), editor: editor)
            c.showWindow(nil)
            await settle()
            tally.check(c.window?.title == clouds[0].displayTitle, "cloud window titled with the song name",
                        detail: c.window?.title ?? "nil")
            for (i, name) in ["summary", "info", "artwork"].enumerated() {
                c.selectTab(i)
                await settle(0.2)
                snap(c.window, "getinfo-cloud-\(name)", evidence)
            }
            c.selectTab(0)
            c.close()
        }

        // --- B. File song: every tab, then Tab / type / Return → warning sheet → save ------
        do {
            let editor = TagEditor(cloud: RecordingCloudWriter(answers: [.denied]))
            let c = controller([fileTrack], order: [fileTrack.id], editor: editor)
            c.showWindow(nil)
            await settle()
            for (i, name) in ["summary", "info", "artwork"].enumerated() {
                c.selectTab(i)
                await settle(0.2)
                snap(c.window, "getinfo-file-\(name)", evidence)
            }
            guard let window = c.window, let info = c.infoPane else { return }
            c.selectTab(1)
            tally.check(editingField(in: window) === info.name.field, "Info tab focuses Name")
            key(window, code: 48, chars: "\t")
            tally.check(editingField(in: window) === info.artist.field, "Tab moves Name -> Artist")
            key(window, code: 48, chars: "\t")
            tally.check(editingField(in: window) === info.year.field, "Tab moves Artist -> Year")
            window.makeFirstResponder(info.name.field)
            replaceText(in: window, with: "Edited by Get Info")
            await settle(0.1)
            snap(window, "getinfo-file-info-focused", evidence)

            let updatesBefore = await library.updateCount()
            let notesBefore = notifications.count
            key(window, code: 36, chars: "\r")                         // Return = OK
            let sheetUp = await waitFor { AquaSheet.presented != nil }
            tally.check(sheetUp, "first file edit shows the §6.6 warning sheet")
            if let sheet = AquaSheet.presented {
                await settle(0.3)
                snap(sheet.window, "sheet-file-warning", evidence)
                sheet.press(1)
            }
            let closed = await waitFor(8) { !window.isVisible }
            tally.check(closed, "Return saved and closed the window")
            let update = await library.lastUpdate()
            let updatesAfter = await library.updateCount()
            tally.check(updatesAfter == updatesBefore + 1 && update?.ids == [fileTrack.id] && update?.patch.title == "Edited by Get Info"
                        && update?.patch.changedFieldNames == ["title"],
                        "library.update called with the saved id and only the edited field",
                        detail: "\(update?.ids ?? []) \(update?.patch.changedFieldNames ?? [])")
            tally.check(notifications.count == notesBefore + 1 && notifications.allOnMain, ".libraryDidChange posted on main")
            let onDisk = try? FileTagIO.readFields(at: fileTrack.fileURL ?? URL(fileURLWithPath: "/"))
            tally.check(onDisk?.title == "Edited by Get Info" && onDisk?.artist == "oldTunes Harness",
                        "file on disk has the new title and kept the other tags", detail: onDisk?.title ?? "nil")
        }

        // --- C. Escape cancels without saving ---------------------------------------------
        do {
            let c = controller([fileTrack], order: [fileTrack.id],
                               editor: TagEditor(cloud: RecordingCloudWriter(answers: [.denied])))
            c.showWindow(nil)
            await settle()
            guard let window = c.window else { return }
            c.selectTab(1)
            replaceText(in: window, with: "Should not be saved")
            let before = await library.updateCount()
            key(window, code: 53, chars: "\u{1b}")                     // Escape = Cancel
            let closed = await waitFor(3) { !window.isVisible }
            let after = await library.updateCount()
            let onDisk = try? FileTagIO.readFields(at: fileTrack.fileURL ?? URL(fileURLWithPath: "/"))
            tally.check(closed && after == before && onDisk?.title == "Edited by Get Info", "Escape closes without saving")
        }

        // --- D. Previous / Next walk the visible order ------------------------------------
        do {
            let c = controller([clouds[1]], order: clouds.map(\.id),
                               editor: TagEditor(cloud: RecordingCloudWriter(answers: [.granted])))
            c.showWindow(nil)
            await settle()
            let updatesBeforeSteps = await library.updateCount()
            tally.check(c.canGoPrevious && c.canGoNext, "middle song: Previous and Next enabled")
            _ = await c.performStep(1)
            tally.check(c.current.id == clouds[2].id && c.window?.title == clouds[2].displayTitle && !c.canGoNext,
                        "Next shows the following song; Next disabled at the end", detail: c.window?.title ?? "")
            _ = await c.performStep(-1)
            _ = await c.performStep(-1)
            let updatesAfterSteps = await library.updateCount()
            tally.check(c.current.id == clouds[0].id && !c.canGoPrevious,
                        "Previous walks back to the first song; Previous disabled there")
            tally.check(updatesAfterSteps == updatesBeforeSteps, "stepping through unedited songs saves nothing")
            c.close()
        }

        // --- E. Cloud save: Automation undetermined → explanation sheet → ask → save -------
        do {
            let writer = RecordingCloudWriter(answers: [.granted])
            let checker = RecordingCloudWriter(answers: [.undetermined, .granted])
            let c = controller([clouds[0]], order: clouds.map(\.id), editor: TagEditor(cloud: writer))
            c.permissionChecker = checker
            c.showWindow(nil)
            await settle()
            guard let window = c.window, let info = c.infoPane else { return }
            c.selectTab(1)
            window.makeFirstResponder(info.comments.textView)
            info.comments.textView.selectAll(nil)
            info.comments.textView.insertText("Saved through Music by the harness",
                                              replacementRange: info.comments.textView.selectedRange())
            let saving = Task { await c.performOK() }
            let sheetUp = await waitFor { AquaSheet.presented != nil }
            tally.check(sheetUp, "first cloud save explains the Automation prompt first")
            if let sheet = AquaSheet.presented {
                await settle(0.3)
                snap(sheet.window, "sheet-automation", evidence)
                sheet.press(1)
            }
            let ok = await saving.value
            let asks = await checker.asks()
            let writes = await writer.recordedWrites()
            let update = await library.lastUpdate()
            tally.check(ok && asks == [false, true], "explain, then ask: permission checks \(asks)")
            tally.check(writes.count == 1 && writes.first?.patch.comments == "Saved through Music by the harness"
                        && writes.first?.hex == MusicPersistentID.hex(clouds[0].persistentID ?? 0),
                        "cloud edit sent to the Music writer (recorded, no Apple Event)")
            tally.check(update?.ids == [clouds[0].id] && update?.patch.changedFieldNames == ["comments"],
                        "cloud save updates the library row")
        }

        // --- F. Multiple Song Information ---------------------------------------------------
        do {
            let checker = RecordingCloudWriter(answers: [.granted])
            let writer = RecordingCloudWriter(answers: [.granted])
            // The cloud song shares the files' year but not their artist, so the page must show
            // 2005 and leave Artist blank.
            var cloudInMulti = clouds[1]
            cloudInMulti.year = 2005
            await library.add(cloudInMulti)
            let selection = [multiA, multiB, cloudInMulti]
            let c = controller(selection, order: selection.map(\.id), editor: TagEditor(cloud: writer))
            c.permissionChecker = checker
            c.showWindow(nil)
            await settle()
            guard let window = c.window, let pane = c.multiplePane, let genre = pane.fields[.genre],
                  let year = pane.fields[.year] else { return }
            tally.check(window.title == "Multiple Song Information", "multi window title")
            tally.check(year.stringValue == "2005" && pane.fields[.artist]?.stringValue == "",
                        "shared values shown, differing values blank",
                        detail: "year=\(year.stringValue) artist=\(pane.fields[.artist]?.stringValue ?? "")")
            snap(window, "getinfo-multi", evidence)
            window.makeFirstResponder(genre.field)
            replaceText(in: window, with: "Multi Genre")
            await settle(0.1)
            tally.check(pane.checkboxes[.genre]?.isOn == true && pane.checkboxes.filter { $0.value.isOn }.count == 1,
                        "editing Genre ticks only Genre's checkbox")
            let patch = c.currentPatch()
            tally.check(patch.changedFieldNames == ["genre"] && patch.genre == "Multi Genre",
                        "multi patch contains only the checked field", detail: "\(patch.changedFieldNames)")
            snap(window, "getinfo-multi-edited", evidence)
            let ok = await c.performOK()
            let update = await library.lastUpdate()
            let writes = await writer.recordedWrites()
            tally.check(ok && Set(update?.ids ?? []) == Set(selection.map(\.id)) && writes.count == 1,
                        "multi save: 2 files + 1 cloud song saved, library updated for all 3",
                        detail: "\(update?.ids ?? [])")
            let a = try? FileTagIO.readFields(at: multiA.fileURL ?? URL(fileURLWithPath: "/"))
            let b = try? FileTagIO.readFields(at: multiB.fileURL ?? URL(fileURLWithPath: "/"))
            tally.check(a?.genre == "Multi Genre" && b?.genre == "Multi Genre" && a?.title == "Multi A" && b?.title == "Multi B",
                        "multi edit changed genre in both files and nothing else")
        }

        // --- G. A failure is shown per song -------------------------------------------------
        do {
            let c = controller([protectedTrack], order: [protectedTrack.id],
                               editor: TagEditor(cloud: RecordingCloudWriter(answers: [.denied])))
            c.showWindow(nil)
            await settle()
            guard let window = c.window else { return }
            c.selectTab(1)
            replaceText(in: window, with: "Renamed")
            let before = await library.updateCount()
            let saving = Task { await c.performOK() }
            let sheetUp = await waitFor { AquaSheet.presented != nil }
            tally.check(sheetUp, "failed save shows the per-song failure sheet")
            if let sheet = AquaSheet.presented {
                await settle(0.3)
                snap(sheet.window, "sheet-failures", evidence)
                sheet.press(0)
            }
            let closed = await saving.value
            let after = await library.updateCount()
            tally.check(!closed && window.isVisible && after == before, "after a failure the window stays open, library untouched")
            c.close()
        }

        // --- H. Artwork tab: Add and Delete feed the patch ---------------------------------
        do {
            let c = controller([fileTrack], order: [fileTrack.id],
                               editor: TagEditor(cloud: RecordingCloudWriter(answers: [.denied])))
            c.showWindow(nil)
            await settle()
            c.selectTab(2)
            let png = HarnessFixtures.artworkPNG(label: "NEW", hue: 0.9)
            c.artworkPane?.onAdd?(png)
            await settle(0.1)
            snap(c.window, "getinfo-file-artwork-added", evidence)
            tally.check(c.currentPatch().artwork == png && !c.currentPatch().removeArtwork, "Add… puts the image in the patch")
            c.artworkPane?.onDelete?()
            tally.check(c.currentPatch().artwork == nil && c.currentPatch().removeArtwork, "Delete removes artwork in the patch")
            c.close()
        }

        notifications.stop()
        Log.info("Get Info snapshots: \(shots.joined(separator: " "))")
    }

    // MARK: - Fixtures for the windows

    private static func makeFileTrack(id: Track.ID, from source: URL, copyName: String, title: String, hue: CGFloat,
                                      editor: TagEditor, tally: HarnessTally) async -> Track? {
        let fm = FileManager.default
        let url = source.deletingLastPathComponent().appendingPathComponent(copyName)
        try? fm.removeItem(at: url)
        do { try fm.copyItem(at: source, to: url) } catch {
            tally.check(false, "copy \(copyName)", detail: error.localizedDescription)
            return nil
        }
        var t = HarnessFixtures.folderTrack(id: id, url: url)
        var p = TagPatch()
        p.title = title; p.artist = "oldTunes Harness"; p.album = "Fixtures of 2005"; p.albumArtist = "oldTunes"
        p.genre = "Test"; p.year = 2005; p.trackNumber = Int(id % 10); p.trackCount = 9; p.discNumber = 1; p.discCount = 1
        p.composer = "say(1)"; p.grouping = "Fixtures"; p.comments = "Generated by the metadata harness."
        p.bpm = 0; p.isCompilation = false
        p.artwork = HarnessFixtures.artworkPNG(label: copyName.split(separator: ".").first.map(String.init) ?? "", hue: hue)
        let r = await editor.apply(p, to: [t])
        guard r.failed.isEmpty else {
            tally.check(false, "prepare \(copyName)", detail: r.failed.map(\.reason).joined())
            return nil
        }
        t.title = title; t.artist = "oldTunes Harness"; t.album = "Fixtures of 2005"; t.albumArtist = "oldTunes"
        t.genre = "Test"; t.year = 2005; t.trackCount = 9; t.trackNumber = Int(id % 10); t.discNumber = 1; t.discCount = 1
        if let file = try? AudioFile(readingPropertiesAndMetadataFrom: url) {
            t.duration = file.properties.duration ?? 0
            t.bitRate = Int((file.properties.bitrate ?? 0).rounded())
            t.sampleRate = Int((file.properties.sampleRate ?? 0).rounded())
        }
        t.fileSize = Int64((try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
        t.kind = GetInfoFormat.kind(t)
        t.dateAdded = Date(timeIntervalSince1970: 1_120_000_000)   // 2005-06-28
        t.playCount = 7
        t.hasArtwork = true
        return t
    }

    // MARK: - Driving the window

    private static func settle(_ seconds: Double = 0.8) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private static func waitFor(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private static func snap(_ window: NSWindow?, _ name: String, _ dir: URL) {
        guard let window else { return }
        window.displayIfNeeded()
        let url = dir.appendingPathComponent("\(name).png")
        if Snapshot.write(window, to: url) {
            shots.append(url.lastPathComponent)
            Log.info("snapshot: \(url.path)")
        } else {
            Log.error("snapshot failed: \(name)")
        }
    }

    /// The text field currently being edited (the field editor's delegate).
    private static func editingField(in window: NSWindow) -> NSTextField? {
        (window.firstResponder as? NSTextView)?.delegate as? NSTextField
    }

    /// A real key-down through the window, so the field editor, key-view loop and command
    /// routing all run as they would for a person typing.
    private static func key(_ window: NSWindow, code: UInt16, chars: String) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: chars, charactersIgnoringModifiers: chars,
                                           isARepeat: false, keyCode: code) else { return }
        window.sendEvent(event)
    }

    /// Replaces the focused field's text through the field editor, which fires the same
    /// change notifications as typing.
    private static func replaceText(in window: NSWindow, with text: String) {
        guard let editor = window.firstResponder as? NSTextView else { return }
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
    }
}

/// Counts `.libraryDidChange` posts and whether each arrived on the main thread.
@MainActor
final class NotificationCounter {
    private(set) var count = 0
    private(set) var allOnMain = true
    private var token: NSObjectProtocol?

    init() {
        // queue: nil runs the block on the posting thread, which is what is being checked.
        token = NotificationCenter.default.addObserver(forName: .libraryDidChange, object: nil, queue: nil) { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.record(onMain: true) }
            } else {
                Task { @MainActor in self?.record(onMain: false) }
            }
        }
    }

    private func record(onMain: Bool) {
        count += 1
        if !onMain { allOnMain = false }
    }

    func stop() {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
    }
}
