import AppKit

/// OLDTUNES_HARNESS=lists — test bench for the source list, track list, and column browser.
///
/// Loads Noah's real library read-only through ITLibrary into ListsHarnessLibrary, shows both view
/// controllers in a plain window laid out like iTunes, drives them through sorting, search,
/// the browser, scopes and scrolling, writes snapshots, pixel-checks them, logs PASS/FAIL
/// lines, and quits.
///
/// Evidence goes to $OLDTUNES_EVIDENCE_DIR (default: a temp folder).
@MainActor
enum ListsHarness {
    /// The saved layout each bench clears so its persistence checks start from the defaults:
    /// columns, the sort, the browser and its height, open playlist folders. The harness runs with
    /// the app's own bundle id, so these are the user's settings; run() puts them back before quitting.
    static let layoutKeys = [TrackColumnLayout.defaultsKey, TrackListViewController.sortDefaultsKey,
                             "OldTunes.TrackList.browserVisible", "OldTunes.TrackList.browserFraction",
                             "OldTunes.SourceList.expandedFolders"]

    /// Runs `body` in the appearance the bench windows draw in (each inherits the app's), so the
    /// Theme colors it turns into numbers, and the gradients Theme picks by `Theme.isDark`, come
    /// out as drawn. Outside a drawing pass AppKit resolves a light/dark color for the thread's
    /// current drawing appearance, and in an app launched with `open` that stays the Mac's own
    /// after the bench switches the app to Light: on a Mac in Dark mode, `Theme.trkSel` read
    /// bare gives the dark #2C6BCB while the window drew #3C80DF.
    static func asDrawn<Value>(_ body: () -> Value) -> Value {
        var value: Value?
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance { value = body() }
        guard let value else { preconditionFailure("performAsCurrentDrawingAppearance runs its block") }
        return value
    }

    /// `color` in sRGB as the bench windows draw it.
    static func srgb(_ color: NSColor) -> NSColor? { asDrawn { color.usingColorSpace(.sRGB) } }

    /// OLDTUNES_LISTS_MODE=scenarios, =stress, =review or =playlists runs one bench alone; the
    /// default runs all four.
    static func run() async {
        let defaults = UserDefaults.standard
        let saved = layoutKeys.map { ($0, defaults.object(forKey: $0)) }
        let mode = ProcessInfo.processInfo.environment["OLDTUNES_LISTS_MODE"] ?? "all"
        var passed = 0, failed = 0
        let bench = ListsBench()
        if mode == "all" || mode == "scenarios" {
            await bench.run()
            passed += bench.passCount
            failed += bench.failCount
        }
        if (mode == "all" || mode == "stress") && !bench.isDebugRun {
            let stress = ListsStressBench(outDir: bench.evidenceDir)
            await stress.run()
            passed += stress.passes
            failed += stress.failures.count
        }
        if (mode == "all" || mode == "review") && !bench.isDebugRun {
            let review = ListsReviewBench(outDir: bench.evidenceDir)
            await review.run()
            passed += review.passes
            failed += review.failures.count
        }
        if (mode == "all" || mode == "playlists") && !bench.isDebugRun {
            let playlists = ListsPlaylistBench(outDir: bench.evidenceDir)
            await playlists.run()
            passed += playlists.passes
            failed += playlists.failures.count
        }

        // Every bench returns here, early returns included (a library that fails to load), so this
        // is the one place to put the layout back. Not in a defer: terminate() never returns.
        for (key, value) in saved {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        let restored = saved.allSatisfy { key, value in
            (defaults.object(forKey: key) as? NSObject) == (value as? NSObject)
        }
        if restored { passed += 1 } else { failed += 1 }
        Log.info("lists: \(restored ? "PASS" : "FAIL") saved layout put back — "
                 + "\(saved.filter { $0.1 != nil }.count) of \(saved.count) keys were set before the run")
        Log.info("lists: TOTAL passed=\(passed) failed=\(failed)")
        Log.info(failed == 0 ? "lists: EVERYTHING PASSED" : "lists: FAILURES")
        Log.flush()
        NSApp.terminate(nil)
    }
}

@MainActor
private final class ListsBench {
    private var passes = 0
    private var failures: [String] = []
    private let outDir: URL
    private var window: NSWindow?
    private var library: ListsHarnessLibrary?
    private var source: SourceListViewController?
    private var tracks: TrackListViewController?

    private var activations: [(Track.ID, Int)] = []
    private var selectionEvents = 0
    private var orderEvents = 0
    private var getInfoEvents: [[Track.ID]] = []
    private var scopeEvents: [LibraryScope] = []

    /// The mouse-up the press-and-hold timer posts.
    static var pendingMouseUp: NSEvent?

    var passCount: Int { passes }
    var failCount: Int { failures.count }
    var evidenceDir: URL { outDir }
    var isDebugRun: Bool { ProcessInfo.processInfo.environment["OLDTUNES_LISTS_DEBUG"] == "1" }

    init() {
        let env = ProcessInfo.processInfo.environment["OLDTUNES_EVIDENCE_DIR"] ?? ""
        outDir = env.isEmpty
            ? FileManager.default.temporaryDirectory.appendingPathComponent("oldtunes-lists", isDirectory: true)
            : URL(fileURLWithPath: env, isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    }

    // MARK: Reporting

    private func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if ok { passes += 1 } else { failures.append(name) }
        Log.info("lists: \(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    }

    private func info(_ s: String) { Log.info("lists: \(s)") }

    private static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    private static func f(_ v: Double) -> String { String(format: "%.2f", v) }

    // MARK: Run

    func run() async {
        info("start; evidence → \(outDir.path)")
        // Each run starts from the defaults so persistence checks are meaningful.
        // ListsHarness.run() puts the user's own values back at the end.
        for key in ListsHarness.layoutKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }

        let snap: ListsHarnessLibrary.Snapshot
        do {
            snap = try await ListsHarnessLibrary.readITLibrary()
        } catch {
            check("read ITLibrary", false, "\(error)")
            return
        }
        let local = snap.tracks.filter { $0.bucket == .local }.count
        let cloud = snap.tracks.filter { $0.bucket == .cloud }.count
        let missing = snap.tracks.filter { $0.bucket == .missing }.count
        info("ITLibrary: items=\(snap.itemCount) songs=\(snap.tracks.count) local=\(local) cloud=\(cloud) "
             + "missing=\(missing) playlists=\(snap.playlists.count) readMs=\(Self.f(snap.loadMillis))")
        check("real library loaded", snap.tracks.count > 15_000, "\(snap.tracks.count) songs")

        let index = await ListsHarnessLibrary.buildIndex(snap)
        let library = ListsHarnessLibrary(index: index)
        self.library = library
        info("harness index built in \(Self.f(index.buildMillis)) ms (8 presorted orders, folded search text)")

        buildWindow(library: library)
        guard let window, let source, let tracks else { return }
        await source.reload()
        await settle()
        info("window key=\(window.isKeyWindow) scale=\(window.backingScaleFactor) app active=\(NSApp.isActive) "
             + "appearance=\(window.effectiveAppearance.name.rawValue) "
             + "(colors read outside drawing resolve for \(NSAppearance.currentDrawing().name.rawValue))")

        if ProcessInfo.processInfo.environment["OLDTUNES_LISTS_DEBUG"] == "1" {
            debugViews()
            snapshot("debug.png")
            return
        }
        await initialChecks(library: library, total: snap.tracks.count)
        await sortChecks(library: library)
        await snapshotArtistSort(library: library)
        await selectionPersistenceAndDateSort(library: library)
        await searchChecks(library: library, total: snap.tracks.count)
        await browserChecks(library: library, total: snap.tracks.count)
        await sourceChecks(snap: snap)
        await cloudAndDimmed(library: library, snap: snap)
        await scrollPerformance(library: library, total: snap.tracks.count)
        await scrollerArrowChecks()
        await headerAndColumnChecks()
        await keyboardAndMenuChecks()
        await revealAndNowPlaying()

        _ = tracks
        info("SUMMARY passed=\(passes) failed=\(failures.count)\(failures.isEmpty ? "" : " failures=\(failures)")")
        Log.info(failures.isEmpty ? "lists: ALL PASS" : "lists: SOME FAILED")
    }

    private func debugViews() {
        guard let window, let content = window.contentView else { return }
        func dump(_ v: NSView, _ depth: Int) {
            guard depth < 6 else { return }
            info(String(repeating: "  ", count: depth) + "\(type(of: v)) frame=\(v.frame) hidden=\(v.isHidden) layer=\(v.layer != nil) opaque=\(v.isOpaque)")
            for s in v.subviews { dump(s, depth + 1) }
        }
        dump(content, 0)
        if let tracks {
            let sv = tracks.listScrollView, clip = sv.contentView, table = tracks.tableView
            let lo = clip.constrainBoundsRect(NSRect(origin: NSPoint(x: 0, y: -1e9), size: clip.bounds.size)).origin
            info("geometry: clip insets=\(clip.contentInsets) sv insets=\(sv.contentInsets) scrollerInsets=\(sv.scrollerInsets) "
                 + "clip bounds=\(clip.bounds) docVisible=\(clip.documentVisibleRect) tableVisible=\(table.visibleRect) "
                 + "row0=\(table.rect(ofRow: 0)) minOrigin=\(lo) sv flipped=\(sv.isFlipped) clipsToBounds=\(sv.clipsToBounds)")
        }
        info("window frame \(window.frame) visible=\(window.isVisible) occlusion=\(window.occlusionState.rawValue) colorSpace=\(window.colorSpace?.localizedName ?? "nil")")
    }

    // MARK: Window

    private func buildWindow(library: ListsHarnessLibrary) {
        let size = NSSize(width: 1000, height: 620)
        let window = HarnessWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "OldTunes — lists harness"
        window.isReleasedWhenClosed = false
        // Render in sRGB, the space Theme's hex values are in, so the snapshot PNG's raw bytes
        // are directly comparable. Left to default, the window takes the display's profile and
        // Snapshot.write tags the PNG with it.
        window.colorSpace = .sRGB
        let backdrop = HarnessBackdrop(frame: NSRect(origin: .zero, size: size))
        window.contentView = backdrop

        let source = SourceListViewController(library: library)
        let tracks = TrackListViewController(library: library)
        // iTunes geometry inside the chrome's own pane frames: 15 pt metal gutter, a 1 px border,
        // the 158 pt source pane, splitter, the track pane to a 14 pt right gutter; a 46 pt band
        // for the bottom bar.
        HarnessPanes.frame(source: source.view, tracks: tracks.view, in: backdrop)

        source.onScopeChange = { [weak self, weak tracks] scope in
            self?.scopeEvents.append(scope)
            tracks?.query.scope = scope
        }
        tracks.onActivate = { [weak self] id, order in self?.activations.append((id, order.count)) }
        tracks.onSelectionChange = { [weak self] _ in self?.selectionEvents += 1 }
        tracks.onOrderChange = { [weak self] _ in self?.orderEvents += 1 }
        tracks.onGetInfo = { [weak self] ids in self?.getInfoEvents.append(ids) }

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        window.makeFirstResponder(tracks.tableView)
        self.window = window
        self.source = source
        self.tracks = tracks
    }

    /// Moves keyboard focus so the table recomputes which selection style to draw. Resigning
    /// first makes it deterministic even when the view already had focus.
    private func focus(_ view: NSView) {
        guard let window else { return }
        window.makeFirstResponder(nil)
        window.makeFirstResponder(view)
        // Tables recompute emphasis when their window becomes key; this window never really does
        // (the app is not frontmost), so say it did.
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    }

    /// `open` starts the harness behind whatever Noah has in front, and macOS 14+ will not let
    /// it take over, so AppKit draws every table unfocused. When the app is not active, give the
    /// row views the emphasis AppKit would give them in a key window — on for the table holding
    /// keyboard focus, off for the rest — so both selection styles can be verified.
    private func applyFocusLook() {
        guard let window, !NSApp.isActive else { return }
        let focused = window.firstResponder as? NSTableView
        for table in [tracks?.tableView, source?.tableView].compactMap({ $0 }) {
            let on = table === focused
            table.enumerateAvailableRowViews { rowView, _ in rowView.isEmphasized = on }
        }
    }

    /// Waits for the current load, the visible rows, and a display pass.
    private func settle() async {
        guard let tracks else { return }
        await tracks.waitForLoad()
        await tracks.waitForRows()
        try? await Task.sleep(for: .milliseconds(60))
        window?.layoutIfNeeded()
        window?.displayIfNeeded()
    }

    /// Writes the PNG with Snapshot.write and reads that same file back for pixel checks, so
    /// the checks verify the evidence itself.
    @discardableResult
    private func snapshot(_ name: String) -> NSBitmapImageRep? {
        guard let window else { return nil }
        applyFocusLook()
        window.displayIfNeeded()
        let url = outDir.appendingPathComponent(name)
        guard Snapshot.write(window, to: url), let data = try? Data(contentsOf: url),
              let rep = NSBitmapImageRep(data: data) else {
            check("snapshot \(name)", false, "write failed")
            return nil
        }
        info("snapshot \(url.path) (\(rep.pixelsWide)x\(rep.pixelsHigh) px, \(rep.colorSpace.localizedName ?? "?"))")
        return rep
    }

    // MARK: Pixels

    /// The color at a point in `view`'s coordinates, read from a snapshot of the window.
    /// Raw sample bytes, not `colorAt`: for a PNG read back, `colorAt` reports the bytes in
    /// Generic RGB (gamma 1.8), and converting that to sRGB lifts every value (#8E8E8E reads
    /// #9F9F9F). The window renders in sRGB, so the bytes are the sRGB values.
    private func pixel(_ rep: NSBitmapImageRep, in view: NSView, at p: NSPoint) -> NSColor? {
        guard let content = window?.contentView else { return nil }
        let c = content.convert(p, from: view)
        let scale = CGFloat(rep.pixelsWide) / content.bounds.width
        let y = content.isFlipped ? c.y : content.bounds.height - c.y
        let px = Int((c.x * scale).rounded(.down)), py = Int((y * scale).rounded(.down))
        guard px >= 0, py >= 0, px < rep.pixelsWide, py < rep.pixelsHigh, rep.samplesPerPixel >= 3 else { return nil }
        var raw = [Int](repeating: 0, count: max(rep.samplesPerPixel, 4))
        rep.getPixel(&raw, atX: px, y: py)
        let maxValue = CGFloat((1 << rep.bitsPerSample) - 1)
        return NSColor(srgbRed: CGFloat(raw[0]) / maxValue, green: CGFloat(raw[1]) / maxValue,
                       blue: CGFloat(raw[2]) / maxValue, alpha: 1)
    }

    private static func hex(_ c: NSColor?) -> String {
        guard let c else { return "nil" }
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }

    private static func close(_ a: NSColor?, _ b: NSColor, tolerance: CGFloat = 3) -> Bool {
        guard let a, let b = ListsHarness.srgb(b) else { return false }
        return abs(a.redComponent - b.redComponent) * 255 <= tolerance
            && abs(a.greenComponent - b.greenComponent) * 255 <= tolerance
            && abs(a.blueComponent - b.blueComponent) * 255 <= tolerance
    }

    /// Checks every visible, unselected row's background against its DISPLAY row parity,
    /// sampled at the left edge of the indicator column (clear of the speaker glyph and text).
    private func checkStripes(_ rep: NSBitmapImageRep, label: String) {
        guard let tracks else { return }
        let table = tracks.tableView
        let visible = tracks.visibleRows
        let onScreen = tracks.listScrollView.unobscuredDocumentRect
        var checked = 0, wrong: [String] = []
        for row in visible {
            guard !table.isRowSelected(row) else { continue }
            let r = table.rect(ofRow: row)
            guard onScreen.contains(NSPoint(x: 1.5, y: r.midY)) else { continue }
            let color = pixel(rep, in: table, at: NSPoint(x: 1.5, y: r.midY))
            let expected = row % 2 == 0 ? Theme.listBG : Theme.rowStripe
            checked += 1
            if !Self.close(color, expected) { wrong.append("row \(row)=\(Self.hex(color))") }
        }
        check("stripes by display row (\(label))", checked > 10 && wrong.isEmpty,
              "checked \(checked) rows from row \(visible.lowerBound); white #FFFFFF even, #ECF3FE odd"
              + (wrong.isEmpty ? "" : "; wrong: \(wrong.prefix(5))"))
    }

    // MARK: Scenarios

    private func initialChecks(library: ListsHarnessLibrary, total: Int) async {
        guard let tracks, let source else { return }
        check("track list shows the whole library", tracks.order.count == total, "\(tracks.order.count) of \(total) rows")
        let largest = await library.largestTracksRequest
        let served = await library.rowsServed
        check("row data fetched for the visible range only", largest < 400 && served < 1_000,
              "largest tracks(ids:) request \(largest) ids, \(served) rows served for the first screen")
        let table = tracks.tableView
        check("table style", table.style == .plain && table.rowHeight == 17 && table.intercellSpacing == NSSize(width: 3, height: 0)
              && table.gridStyleMask.isEmpty && !table.usesAlternatingRowBackgroundColors,
              "style=\(table.style.rawValue) rowHeight=\(table.rowHeight) intercell=\(table.intercellSpacing) grid=\(table.gridStyleMask.rawValue)")
        let header = table.headerView
        check("header is the custom 15 pt + 1 pt rule view", header is TrackHeaderView && header?.frame.height == 16,
              "height \(header?.frame.height ?? 0)")
        let scroller = tracks.listScrollView.verticalScroller
        check("vertical scroller is a 15 pt AquaScroller, legacy, always shown",
              scroller is AquaScroller && scroller?.frame.width == 15 && tracks.listScrollView.scrollerStyle == .legacy
              && tracks.listScrollView.hasVerticalScroller && !tracks.listScrollView.autohidesScrollers
              && scroller?.isHidden == false,
              "frame \(scroller?.frame ?? .zero) style=\(tracks.listScrollView.scrollerStyle.rawValue)")
        let hscroller = tracks.listScrollView.horizontalScroller
        check("horizontal scroller is a 15 pt AquaScroller", hscroller is AquaScroller && hscroller?.frame.height == 15,
              "frame \(hscroller?.frame ?? .zero)")
        if #available(macOS 27.0, *) {
            let radii = tracks.listScrollView.effectiveCornerRadii
            check("scroll view corners are square (cornerConfiguration nil)",
                  tracks.listScrollView.cornerConfiguration == nil && radii == nil,
                  "effectiveCornerRadii=\(String(describing: radii))")
        }
        let rows = source.rowTitles
        check("source list starts Library, On This Mac, then playlists",
              rows.count >= 2 && rows[0] == "Library" && rows[1] == "On This Mac",
              "\(rows.count) rows; first: \(rows.prefix(8))")
        check("source rows are 18 pt", source.tableView.rowHeight == 18)
    }

    private func sortChecks(library: ListsHarnessLibrary) async {
        guard let tracks else { return }
        let sorts: [TrackSort] = [
            .init(field: .name, ascending: true), .init(field: .name, ascending: false),
            .init(field: .time, ascending: true), .init(field: .album, ascending: true),
            .init(field: .genre, ascending: true), .init(field: .dateAdded, ascending: false),
            .init(field: .dateAdded, ascending: true), .init(field: .artist, ascending: false),
            .init(field: .year, ascending: true), .init(field: .playCount, ascending: false),
            .init(field: .artist, ascending: true),
        ]
        var worst = 0.0, worstMain = 0.0, worstOwn = 0.0
        for sort in sorts {
            let t0 = ContinuousClock.now
            tracks.query.sort = sort
            await tracks.waitForLoad()
            let dt = Self.ms(ContinuousClock.now - t0)
            worst = max(worst, dt)
            worstMain = max(worstMain, tracks.lastApplyMillis)
            worstOwn = max(worstOwn, tracks.lastLoadMillis - tracks.lastIDsMillis)
            info("sort \(sort.field.rawValue) \(sort.ascending ? "asc" : "desc"): set→reloadData done \(Self.f(dt)) ms "
                 + "(\(tracks.lastLoadBreakdown))")
        }
        check("the list's own share of a sort stays under 50 ms on \(tracks.order.count) rows", worstOwn < 50,
              "worst prepare(off-main)+apply \(Self.f(worstOwn)) ms; end-to-end worst \(Self.f(worst)) ms incl. the "
              + "harness library's ids(for:) in a Debug build")
        check("main-thread part of a sort fits in one frame", worstMain < 16.7,
              "worst reloadData+selection+scroll \(Self.f(worstMain)) ms")

        // The order really is sorted: first 300 rows of artist ascending by SortKey.
        let firstIDs = Array(tracks.order.prefix(300))
        let rows = (try? await library.tracks(ids: firstIDs)) ?? []
        let keys = rows.map { SortKey.make($0.artist) }
        check("artist sort order is non-decreasing by SortKey", keys.count == 300 && zip(keys, keys.dropFirst()).allSatisfy { $0 <= $1 },
              "first artists: \(rows.prefix(4).map(\.artist))")
    }

    private func snapshotArtistSort(library: ListsHarnessLibrary) async {
        guard let tracks, let window else { return }
        tracks.query.sort = TrackSort(field: .artist, ascending: true)
        await tracks.waitForLoad()
        let table = tracks.tableView
        table.scrollRowToVisible(0)
        table.selectRowIndexes(IndexSet(integer: 4), byExtendingSelection: false)
        let playingID = tracks.order[2]
        tracks.setNowPlaying(playingID, isPlaying: true)
        focus(table)
        await settle()
        guard let rep = snapshot("01_artist_sort_selection_nowplaying.png") else { return }

        checkStripes(rep, label: "artist sort")
        let sel = table.rect(ofRow: 4)
        let interior = pixel(rep, in: table, at: NSPoint(x: 1.5, y: sel.midY))
        let edge = pixel(rep, in: table, at: NSPoint(x: 1.5, y: sel.maxY - 0.5))
        check("focused track selection is flat #3C80DF", Self.close(interior, Theme.trkSel), "got \(Self.hex(interior))")
        check("track selection has its 1 px #7CADE7 bottom edge", Self.close(edge, Theme.trkSelEdge), "got \(Self.hex(edge))")
        let aboveEdge = pixel(rep, in: table, at: NSPoint(x: 1.5, y: sel.maxY - 1.5))
        check("selection is flat down to the edge", Self.close(aboveEdge, Theme.trkSel), "got \(Self.hex(aboveEdge))")

        // Scroller: 15 pt and a blue knob.
        if let scroller = tracks.listScrollView.verticalScroller as? AquaScroller {
            let knob = scroller.knobRect
            let knobMid = pixel(rep, in: scroller, at: NSPoint(x: knob.midX, y: knob.midY))
            let trough = pixel(rep, in: scroller, at: NSPoint(x: 11.5, y: scroller.slotRect.midY + 40))
            let rightEdge = pixel(rep, in: scroller, at: NSPoint(x: 14.5, y: scroller.slotRect.midY + 40))
            let beyond = pixel(rep, in: tracks.listScrollView, at: NSPoint(x: scroller.frame.minX - 0.5, y: scroller.frame.midY + 40))
            let blue = (knobMid?.blueComponent ?? 0) - (knobMid?.redComponent ?? 0)
            check("scroller knob is Aqua blue gel", blue > 0.25, "knob mid \(Self.hex(knobMid)) at \(knob)")
            check("scroller trough is the light inset gradient", (trough?.redComponent ?? 0) > 0.9,
                  "trough \(Self.hex(trough)), right edge \(Self.hex(rightEdge)), list beside it \(Self.hex(beyond))")
            check("scroller is 15 pt wide in pixels", scroller.frame.width == 15 && rep.pixelsWide == Int(window.contentView?.bounds.width ?? 0) * 2,
                  "frame width \(scroller.frame.width) pt = \(Int(scroller.frame.width * 2)) px at 2x")
        }

        // Header: the sorted column is blue, the others light.
        if let header = table.headerView {
            let artistCol = table.column(withIdentifier: TrackColumn.artist.identifier)
            let nameCol = table.column(withIdentifier: TrackColumn.name.identifier)
            let a = header.headerRect(ofColumn: artistCol), n = header.headerRect(ofColumn: nameCol)
            let sep = pixel(rep, in: header, at: NSPoint(x: n.maxX - 0.5, y: 4.5))
            let rule = pixel(rep, in: header, at: NSPoint(x: n.midX, y: 15.5))
            // Down the 15 pt band, each device-pixel row against the gradient at that height.
            var sortedLog: [String] = [], plainLog: [String] = []
            var sortedOK = true, plainOK = true
            for y in stride(from: CGFloat(0.25), to: 15, by: 2.5) {
                let location = y / 15
                let sorted = pixel(rep, in: header, at: NSPoint(x: a.midX - 20, y: y))
                let plain = pixel(rep, in: header, at: NSPoint(x: n.maxX - 20, y: y))
                // Theme picks each gradient by appearance: read them as the header drew them.
                let (sortedWant, plainWant) = ListsHarness.asDrawn {
                    (Theme.columnHeaderSorted.interpolatedColor(atLocation: location),
                     Theme.columnHeader.interpolatedColor(atLocation: location))
                }
                sortedOK = sortedOK && Self.close(sorted, sortedWant, tolerance: 4)
                plainOK = plainOK && Self.close(plain, plainWant, tolerance: 4)
                sortedLog.append(Self.hex(sorted))
                plainLog.append(Self.hex(plain))
            }
            check("sorted header column is the blue bright-dipped-bright gradient", sortedOK, "\(sortedLog)")
            check("plain header is the white bright-dipped-bright gradient", plainOK, "\(plainLog)")
            check("header separators #C0C0C0 and rule below", Self.close(sep, Theme.colSep, tolerance: 6)
                  && Self.close(rule, ListsPalette.headerRule, tolerance: 6), "sep \(Self.hex(sep)) rule \(Self.hex(rule))")
        }

        // Now playing: speaker on row 2, filled while playing.
        let indicatorCol = table.column(withIdentifier: TrackColumn.indicator.identifier)
        let cell = table.view(atColumn: indicatorCol, row: 2, makeIfNecessary: false) as? TrackCellView
        check("now-playing row shows the filled speaker", cell?.indicatorState == .playing)
        let other = table.view(atColumn: indicatorCol, row: 3, makeIfNecessary: false) as? TrackCellView
        check("other rows show no speaker", other?.indicatorState == TrackCellView.Indicator.none)
        tracks.setNowPlaying(playingID, isPlaying: false)
        await settle()
        let paused = table.view(atColumn: indicatorCol, row: 2, makeIfNecessary: false) as? TrackCellView
        check("paused shows the outlined speaker", paused?.indicatorState == .paused)
        snapshot("01b_nowplaying_paused.png")
        tracks.setNowPlaying(playingID, isPlaying: true)

        // Lucida Grande everywhere.
        check("list font is Lucida Grande 11", Theme.font.fontName == "LucidaGrande" && Theme.font.pointSize == 11, Theme.font.fontName)
    }

    private func selectionPersistenceAndDateSort(library: ListsHarnessLibrary) async {
        guard let tracks else { return }
        let table = tracks.tableView
        table.selectRowIndexes(IndexSet([4, 9]), byExtendingSelection: false)
        let before = Set(tracks.selectedIDs)
        let ordersBefore = orderEvents
        tracks.query.sort = TrackSort(field: .name, ascending: true)
        await tracks.waitForLoad()
        let afterName = Set(tracks.selectedIDs)
        check("selection persists across a re-sort by id", before == afterName && before.count == 2,
              "ids \(before.sorted()) → rows \(Array(table.selectedRowIndexes))")
        check("onOrderChange fired for the new order", orderEvents == ordersBefore + 1, "\(orderEvents - ordersBefore) event(s)")

        tracks.query.sort = TrackSort(field: .dateAdded, ascending: false)
        await tracks.waitForLoad()
        check("selection persists across a second re-sort", Set(tracks.selectedIDs) == before)
        table.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        table.scrollRowToVisible(0)
        focus(table)
        await settle()
        guard let rep = snapshot("02_date_added_newest_first.png") else { return }
        checkStripes(rep, label: "date added, newest first")

        let firstIDs = Array(tracks.order.prefix(400))
        let rows = (try? await library.tracks(ids: firstIDs)) ?? []
        let dates = rows.map { $0.dateAdded ?? .distantPast }
        let fmt = ListsPalette.shortDate
        check("date added newest first is non-increasing", dates.count == 400 && zip(dates, dates.dropFirst()).allSatisfy { $0 >= $1 },
              "top: \(rows.prefix(3).map { "\($0.title) \($0.dateAdded.map { fmt.string(from: $0) } ?? "-")" })")
        let dateCol = table.column(withIdentifier: TrackColumn.dateAdded.identifier)
        let cell = table.view(atColumn: dateCol, row: 0, makeIfNecessary: false) as? TrackCellView
        let expected = rows.first?.dateAdded.map { fmt.string(from: $0) } ?? ""
        check("Date Added column shows the short date", cell?.displayedText == expected && !expected.isEmpty,
              "row 0 \"\(cell?.displayedText ?? "nil")\"")
        let timeCol = table.column(withIdentifier: TrackColumn.time.identifier)
        let tcell = table.view(atColumn: timeCol, row: 0, makeIfNecessary: false) as? TrackCellView
        check("Time column is m:ss, right-aligned", tcell?.displayedText == ListsPalette.time(rows.first?.duration ?? 0)
              && table.tableColumns[timeCol].headerCell.alignment == .right,
              "row 0 \"\(tcell?.displayedText ?? "nil")\"; 3725 s → \(ListsPalette.time(3725))")
    }

    private func searchChecks(library: ListsHarnessLibrary, total: Int) async {
        guard let tracks else { return }
        tracks.query.sort = TrackSort(field: .artist, ascending: true)
        await tracks.waitForLoad()

        // Typing burst: five keystrokes 30 ms apart must cost exactly one query.
        await library.resetCounters()
        for text in ["o", "oa", "oas", "oasi", "oasis"] {
            tracks.query.search = text
            try? await Task.sleep(for: .milliseconds(30))
        }
        let t0 = ContinuousClock.now
        await tracks.waitForLoad()
        let lastKeyToApplied = Self.ms(ContinuousClock.now - t0) + 30
        let calls = await library.idsCalls
        let seen = await library.searchesSeen
        check("search is debounced: 5 keystrokes → 1 query", calls == 1 && seen == ["oasis"],
              "ids(for:) calls \(calls) \(seen); last keystroke → list \(Self.f(lastKeyToApplied)) ms (140 ms debounce + \(tracks.lastLoadBreakdown))")
        let oasisIDs = tracks.order
        let oasisRows = (try? await library.tracks(ids: oasisIDs)) ?? []
        let allMatch = oasisRows.allSatisfy { t in
            ListsHarnessLibrary.fold([t.title, t.artist, t.album, t.albumArtist, t.composer].joined(separator: " ")).contains("oasis")
        }
        check("search \"oasis\" returns only matching rows", !oasisIDs.isEmpty && allMatch,
              "\(oasisIDs.count) rows: \(oasisRows.prefix(4).map { "\($0.artist) — \($0.title)" })")
        await settle()
        snapshot("03_search_oasis.png")

        tracks.query.search = "nderw"
        await tracks.waitForLoad()
        let nderw = (try? await library.tracks(ids: tracks.order)) ?? []
        let midWord = nderw.first { t in
            [t.title, t.artist, t.album].contains { field in
                let folded = ListsHarnessLibrary.fold(field)
                guard let r = folded.range(of: "nderw") else { return false }
                return r.lowerBound != folded.startIndex && folded[folded.index(before: r.lowerBound)].isLetter
            }
        }
        check("\"nderw\" matches mid-word", !nderw.isEmpty && midWord != nil,
              "\(nderw.count) rows, e.g. \(midWord.map { "\($0.artist) — \($0.title) [\($0.album)]" } ?? "none")")
        await settle()
        snapshot("03b_search_nderw.png")

        // Stale results: a slow query for "a" is overtaken by "oasis"; "a" must never show.
        await library.setSearchLatency(["a": .milliseconds(700)])
        await library.resetCounters()
        tracks.query.search = "a"
        try? await Task.sleep(for: .milliseconds(260))   // debounce fired; "a" is in flight
        tracks.query.search = "oasis"
        await tracks.waitForLoad()
        try? await Task.sleep(for: .milliseconds(700))   // let the slow "a" land
        let staleSeen = await library.searchesSeen
        check("a late result never overwrites a newer one", tracks.order == oasisIDs,
              "queries issued \(staleSeen); list shows \(tracks.order.count) rows (oasis = \(oasisIDs.count))")
        await library.setSearchLatency([:])

        let t1 = ContinuousClock.now
        tracks.query.search = ""
        await tracks.waitForLoad()
        check("clearing the search restores every row", tracks.order.count == total,
              "\(tracks.order.count) rows in \(Self.f(Self.ms(ContinuousClock.now - t1))) ms incl. debounce")
        let top = tracks.listScrollView.unobscuredDocumentRect
        check("a new search result starts with row 0 just under the header", tracks.visibleRows.lowerBound == 0
              && tracks.tableView.rect(ofRow: 0).minY >= top.minY, "first on-screen row \(tracks.visibleRows.lowerBound), top \(top.minY)")
    }

    private func browserChecks(library: ListsHarnessLibrary, total: Int) async {
        guard let tracks else { return }
        tracks.isBrowserVisible = true
        await settle()
        let browser = tracks.columnBrowser
        guard let genrePane = browser.pane(.genre), let artistPane = browser.pane(.artist), let albumPane = browser.pane(.album) else {
            check("browser panes exist", false)
            return
        }
        for _ in 0..<100 where genrePane.values.isEmpty || artistPane.values.isEmpty {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let allArtists = artistPane.values.count
        info("browser: \(genrePane.values.count) genres, \(allArtists) artists, \(albumPane.values.count) albums; "
             + "first row \"\(genrePane.allRowTitle)\"")
        check("browser shows three panes with All rows", !genrePane.values.isEmpty && !artistPane.values.isEmpty
              && genrePane.allRowTitle.hasPrefix("All (") && genrePane.allRowTitle.hasSuffix("Genres)"),
              genrePane.allRowTitle)
        let fraction = browser.frame.height / max(tracks.view.bounds.height, 1)
        check("browser defaults to ~40% of the pane", abs(fraction - 0.4) < 0.03, "fraction \(Self.f(Double(fraction)))")

        // Pick the genre with the most songs, as a user clicking it would.
        let counts = await genreCounts(library: library)
        let genre = genrePane.values.max { (counts[$0] ?? 0) < (counts[$1] ?? 0) } ?? genrePane.values[0]
        guard let row = genrePane.values.firstIndex(of: genre) else { return }
        genrePane.table.scrollRowToVisible(row + 1)   // a user only clicks what is on screen
        genrePane.table.selectRowIndexes(IndexSet(integer: row + 1), byExtendingSelection: false)
        await tracks.waitForLoad()
        for _ in 0..<100 where artistPane.values.count == allArtists {
            try? await Task.sleep(for: .milliseconds(20))
        }
        await settle()
        let rows = (try? await library.tracks(ids: tracks.order)) ?? []
        check("picking a genre filters the list", tracks.query.genre == genre && !rows.isEmpty && rows.count < total
              && rows.allSatisfy { $0.genre == genre }, "\"\(genre)\": \(rows.count) rows")
        check("picking a genre narrows the Artist pane", artistPane.values.count < allArtists && artistPane.selectedValue == nil,
              "\(allArtists) → \(artistPane.values.count) artists; \"\(artistPane.allRowTitle)\"")
        snapshot("04_browser_genre_selected.png")

        // Then an artist narrows albums and the list further.
        if let artist = artistPane.values.first {
            let albumsBefore = albumPane.values.count
            artistPane.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            await tracks.waitForLoad()
            for _ in 0..<100 where albumPane.values.count == albumsBefore {
                try? await Task.sleep(for: .milliseconds(20))
            }
            let narrowed = (try? await library.tracks(ids: tracks.order)) ?? []
            check("picking an artist narrows albums and rows", narrowed.allSatisfy { $0.artist == artist && $0.genre == genre }
                  && albumPane.values.count <= albumsBefore && !narrowed.isEmpty,
                  "\"\(artist)\": \(narrowed.count) rows, \(albumPane.values.count) albums")
            artistPane.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            await tracks.waitForLoad()
        }

        tracks.isBrowserVisible = false
        await tracks.waitForLoad()
        check("hiding the browser clears its filters", tracks.query.genre == nil && tracks.order.count == total,
              "\(tracks.order.count) rows")
    }

    private func genreCounts(library: ListsHarnessLibrary) async -> [String: Int] {
        guard let tracks else { return [:] }
        let all = (try? await library.tracks(ids: tracks.order)) ?? []
        var counts: [String: Int] = [:]
        for t in all { counts[t.genre, default: 0] += 1 }
        return counts
    }

    private func sourceChecks(snap: ListsHarnessLibrary.Snapshot) async {
        guard let tracks, let source else { return }
        let regular = snap.playlists.filter { $0.kind == .regular && $0.trackCount >= 12 && $0.parentID == nil }
        let smart = snap.playlists.filter { $0.kind == .smart }
        let folders = snap.playlists.filter { $0.kind == .folder }
        info("playlists: \(snap.playlists.count) (\(regular.count) top-level regular ≥12 songs, \(smart.count) smart, \(folders.count) folders)")
        info("source rows: \(source.rowTitles.prefix(30))")
        guard let playlist = regular.first ?? snap.playlists.first(where: { $0.trackCount > 0 }) else {
            check("a playlist to select", false, "library has no playlists with songs")
            return
        }
        source.select(.playlist(playlist.id))
        await tracks.waitForLoad()
        check("selecting a playlist scopes the track list", tracks.query.scope == .playlist(playlist.id)
              && tracks.order.count == playlist.trackCount && scopeEvents.last == .playlist(playlist.id),
              "\"\(playlist.name)\": \(tracks.order.count) rows (playlist has \(playlist.trackCount) songs)")
        tracks.tableView.selectRowIndexes(IndexSet([1, 2]), byExtendingSelection: false)
        focus(tracks.tableView)
        await settle()
        guard let rep = snapshot("05_source_playlist_tracks_focused.png") else { return }

        let sTable = source.tableView
        let sRow = sTable.selectedRow
        let sRect = sTable.rect(ofRow: sRow)
        let sMid = pixel(rep, in: sTable, at: NSPoint(x: 3.5, y: sRect.midY))
        let sTop = pixel(rep, in: sTable, at: NSPoint(x: 3.5, y: sRect.minY + 1.5))
        let sBottom = pixel(rep, in: sTable, at: NSPoint(x: 3.5, y: sRect.maxY - 1.5))
        let gray = { (c: NSColor?) -> Bool in
            guard let c else { return false }
            return abs(c.redComponent - c.blueComponent) < 0.03 && c.redComponent > 0.35 && c.redComponent < 0.65
        }
        check("unfocused source selection is the gray gradient", gray(sMid)
              && (sTop?.redComponent ?? 0) > (sBottom?.redComponent ?? 1),
              "top \(Self.hex(sTop)) mid \(Self.hex(sMid)) bottom \(Self.hex(sBottom))")
        let tRect = tracks.tableView.rect(ofRow: 1)
        let tSel = pixel(rep, in: tracks.tableView, at: NSPoint(x: 1.5, y: tRect.midY))
        check("focused track selection stays blue beside it", Self.close(tSel, Theme.trkSel), "got \(Self.hex(tSel))")

        focus(sTable)
        await settle()
        guard let rep2 = snapshot("05b_source_focused.png") else { return }
        let fTop = pixel(rep2, in: sTable, at: NSPoint(x: 3.5, y: sRect.minY + 1.5))
        let fBottom = pixel(rep2, in: sTable, at: NSPoint(x: 3.5, y: sRect.maxY - 1.5))
        let fEdge = pixel(rep2, in: sTable, at: NSPoint(x: 3.5, y: sRect.minY + 0.5))
        check("focused source selection is the #69A7EE→#2972D8 gradient",
              Self.close(fTop, Theme.srcSelTop, tolerance: 10) && Self.close(fBottom, Theme.srcSelBottom, tolerance: 10)
              && Self.close(fEdge, Theme.srcSelEdgeTop, tolerance: 4),
              "top \(Self.hex(fTop)) bottom \(Self.hex(fBottom)) edge \(Self.hex(fEdge))")
        let tOff = pixel(rep2, in: tracks.tableView, at: NSPoint(x: 1.5, y: tRect.midY))
        check("unfocused track selection turns gray #8E8E8E", Self.close(tOff, Theme.trkSelOff), "got \(Self.hex(tOff))")
        check("source and track rows differ in height (18 vs 17)", sTable.rect(ofRow: 0).height == 18 && tracks.tableView.rect(ofRow: 0).height == 17)

        let scopeBefore = source.scope
        await source.reload()
        check("source reload() keeps the selected playlist", source.scope == scopeBefore && source.tableView.selectedRow >= 0,
              "scope \(source.scope)")

        if folders.isEmpty {
            info("no playlist folders in this library; checking folders with fixture folders around real playlists")
        }
        await folderChecks(snap: snap)

        source.select(.onThisMac)
        await tracks.waitForLoad()
        let localCount = snap.tracks.filter { $0.fileURL != nil }.count
        check("On This Mac shows the local files", tracks.query.scope == .onThisMac && tracks.order.count == localCount,
              "\(tracks.order.count) rows, \(localCount) local files")
        focus(tracks.tableView)
        await settle()
        snapshot("07_on_this_mac.png")

        source.select(.library)
        await tracks.waitForLoad()
    }

    /// Folders, disclosure and indentation, on a second source list whose library wraps the real
    /// one and files real playlists into two fixture folders (one nested), since Noah's library
    /// has no folders to show.
    private func folderChecks(snap: ListsHarnessLibrary.Snapshot) async {
        guard let library else { return }
        let real = snap.playlists.filter { $0.kind != .folder && $0.parentID == nil }
        guard real.count >= 4 else { return }
        let outer = PlaylistInfo(id: -9_001, name: "Old Mixes (fixture folder)", kind: .folder, parentID: nil, trackCount: 0)
        let inner = PlaylistInfo(id: -9_002, name: "Nested (fixture)", kind: .folder, parentID: outer.id, trackCount: 0)
        var lists = snap.playlists.filter { !$0.name.isEmpty }
        // File the last two regular playlists under the outer folder, one more under the nested one.
        let regular = lists.indices.filter { lists[$0].kind == .regular && lists[$0].parentID == nil }
        guard regular.count >= 3 else { return }
        lists[regular[regular.count - 1]].parentID = outer.id
        lists[regular[regular.count - 2]].parentID = outer.id
        lists[regular[regular.count - 3]].parentID = inner.id
        // Capture by id before the folders are inserted (inserting shifts every index).
        let outerChild = lists[regular[regular.count - 1]]
        let nested = lists[regular[regular.count - 3]]
        let firstRegular = lists.firstIndex { $0.kind == .regular } ?? lists.count
        lists.insert(contentsOf: [outer, inner], at: firstRegular)
        let fixture = FolderFixtureLibrary(base: library, playlists: lists)

        let panel = HarnessWindow(contentRect: NSRect(x: 0, y: 0, width: 190, height: 460),
                                  styleMask: [.titled], backing: .buffered, defer: false)
        panel.colorSpace = .sRGB
        panel.isReleasedWhenClosed = false
        let backdrop = HarnessBackdrop(frame: NSRect(x: 0, y: 0, width: 190, height: 460))
        panel.contentView = backdrop
        let folderList = SourceListViewController(library: fixture)
        HarnessPanes.frame(source: folderList.view, tracks: nil, in: backdrop, top: 12, bottom: 12)
        panel.orderFront(nil)
        await folderList.reload()
        let collapsed = folderList.rowScopes
        folderList.setExpanded(outer.id, true)
        folderList.setExpanded(inner.id, true)
        let expanded = folderList.rowScopes
        let depthOfNested = expanded.firstIndex(of: .playlist(nested.id)).map { folderList.rowDepths[$0] }
        folderList.select(.playlist(nested.id))
        panel.makeFirstResponder(folderList.tableView)
        panel.displayIfNeeded()
        let url = outDir.appendingPathComponent("12_source_folders_fixture.png")
        Snapshot.write(panel, to: url)
        info("snapshot \(url.path)")
        check("folders show their playlists only when open, nested inside each other",
              !collapsed.contains(.playlist(outerChild.id)) && !collapsed.contains(.playlist(nested.id))
              && expanded.contains(.playlist(outerChild.id)) && depthOfNested == 2
              && expanded.count == collapsed.count + 4 && folderList.scope == .playlist(nested.id),
              "\(collapsed.count) rows closed → \(expanded.count) open; \"\(nested.name)\" at depth \(depthOfNested ?? -1)")
        folderList.setExpanded(outer.id, false)
        check("closing a folder over the selection selects the folder", folderList.scope == .playlist(outer.id),
              "scope \(folderList.scope), selected \"\(folderList.rowTitles[max(folderList.tableView.selectedRow, 0)])\"")
        panel.orderOut(nil)
    }

    private func cloudAndDimmed(library: ListsHarnessLibrary, snap: ListsHarnessLibrary.Snapshot) async {
        guard let tracks else { return }
        tracks.query.sort = TrackSort(field: .name, ascending: true)
        await tracks.waitForLoad()
        let localIDs = snap.tracks.filter { $0.bucket == .local }.map(\.id)
        let realMissing = snap.tracks.filter { $0.bucket == .missing }.map(\.id)
        guard let anchor = localIDs.first.flatMap({ id in tracks.order.firstIndex(of: id) }) ?? Optional(200) else { return }
        if realMissing.isEmpty {
            // No unplayable rows in this library: flag two real rows near the anchor as
            // .missing in the harness library only, then go through reload() like a
            // .libraryDidChange would.
            let fake = Set([tracks.order[max(anchor - 2, 0)], tracks.order[min(anchor + 3, tracks.order.count - 1)]])
            await library.markMissing(fake)
            info("no real .missing rows; marked 2 rows missing in the harness library for the dimmed-row check")
        } else {
            info("\(realMissing.count) real .missing rows")
        }
        tracks.reveal(tracks.order[anchor])
        focus(tracks.tableView)
        await settle()
        let topBefore = tracks.visibleRows.lowerBound
        let selBefore = tracks.selectedIDs
        await tracks.reload()
        await settle()
        let topAfter = tracks.visibleRows.lowerBound
        check("reload() keeps selection and scroll position", tracks.selectedIDs == selBefore && topAfter == topBefore,
              "top row \(topBefore) → \(topAfter), selection \(selBefore)")
        guard let rep = snapshot("06_cloud_and_dimmed_rows.png") else { return }
        _ = rep

        let table = tracks.tableView
        let nameCol = table.column(withIdentifier: TrackColumn.name.identifier)
        var cloudRows = 0, dimRows = 0, localRows = 0
        let visible = tracks.visibleRows
        for row in visible {
            guard let cell = table.view(atColumn: nameCol, row: row, makeIfNecessary: false) as? TrackCellView else { continue }
            if cell.showsCloudBadge { cloudRows += 1 }
            if cell.isDimmed { dimRows += 1 }
            if !cell.showsCloudBadge && !cell.isDimmed && !cell.displayedText.isEmpty { localRows += 1 }
        }
        check("cloud-only rows show the cloud badge, dimmed rows are dimmed", cloudRows > 0 && dimRows > 0,
              "visible: \(cloudRows) cloud, \(dimRows) dimmed, \(localRows) plain (local)")
        // Pixel: a dimmed row's text is #999999-ish, never #1A1A1A.
        if let dimRow = visible.first(where: { row in
            (table.view(atColumn: nameCol, row: row, makeIfNecessary: false) as? TrackCellView)?.isDimmed == true
            && !table.isRowSelected(row)
        }) {
            let rect = table.frameOfCell(atColumn: nameCol, row: dimRow)
            var darkest: CGFloat = 1
            // The title only, right of the checkbox.
            for dx in stride(from: TrackCellView.nameTextLeft + 1, to: min(rect.width, 120), by: 0.5) {
                for dy in stride(from: CGFloat(4), to: 14, by: 0.5) {
                    if let c = pixel(rep, in: table, at: NSPoint(x: rect.minX + dx, y: rect.minY + dy)) {
                        darkest = min(darkest, c.redComponent)
                    }
                }
            }
            check("dimmed row text is gray, not black", darkest > 0.45 && darkest < 0.75,
                  "darkest text pixel \(Int(darkest * 255)) (#99 = 153)")
        }
        await library.markMissing([])
    }

    private func scrollPerformance(library: ListsHarnessLibrary, total: Int) async {
        guard let tracks, let window else { return }
        tracks.query.sort = TrackSort(field: .name, ascending: true)
        await tracks.waitForLoad()
        let table = tracks.tableView
        table.scrollRowToVisible(0)
        await settle()
        await library.resetCounters()
        let requests0 = tracks.cellRequests, created0 = tracks.cellsCreated
        var steps = 0
        var worst = 0.0
        let t0 = ContinuousClock.now
        for row in Array(stride(from: 0, to: total, by: 250)) + [total - 1] {
            let s = ContinuousClock.now
            table.scrollRowToVisible(row)
            window.contentView?.displayIfNeeded()
            worst = max(worst, Self.ms(ContinuousClock.now - s))
            steps += 1
        }
        let elapsed = Self.ms(ContinuousClock.now - t0)
        let requests = tracks.cellRequests - requests0, created = tracks.cellsCreated - created0
        await tracks.waitForRows()
        let served = await library.rowsServed, calls = await library.tracksCalls, largest = await library.largestTracksRequest
        info("scroll \(total) rows in \(steps) steps: \(Self.f(elapsed)) ms total, worst step \(Self.f(worst)) ms, "
             + "\(requests) viewFor calls, \(created) cells created, \(calls) fetches / \(served) rows served "
             + "(largest \(largest)), cache \(tracks.cachedRowCount)/\(tracks.cacheCapacity)")
        check("scrolling 15,900 rows never stalls a frame", worst < 16.7 && elapsed / Double(steps) < 8,
              "worst step \(Self.f(worst)) ms, mean \(Self.f(elapsed / Double(steps))) ms")
        check("cells are reused while scrolling", created < 200 && requests > created * 10,
              "\(created) created for \(requests) requests")
        check("row cache stays bounded", tracks.cachedRowCount <= tracks.cacheCapacity + tracks.cacheCapacity / 4,
              "\(tracks.cachedRowCount) cached rows")
        await settle()
        let nameCol = table.column(withIdentifier: TrackColumn.name.identifier)
        let shown = tracks.visibleRows
        let filled = shown.filter { row in
            !((table.view(atColumn: nameCol, row: row, makeIfNecessary: false) as? TrackCellView)?.displayedText ?? "").isEmpty
        }.count
        check("rows fill in after the fetch lands", filled == shown.count && filled > 0,
              "\(filled) of \(shown.count) visible rows have text at the bottom of the list")
        await settle()
        snapshot("08_scrolled_to_bottom.png")

        // A slower pass that lets every fetch land, as a reader scrolling would: the cache must
        // fill, evict, and stay bounded, and no screenful may be left blank.
        await library.resetCounters()
        let evictions0 = tracks.cacheEvictions
        var blankScreens = 0, steps2 = 0
        let t1 = ContinuousClock.now
        for row in stride(from: total - 1, through: 0, by: -180) {
            table.scrollRowToVisible(row)
            await tracks.waitForRows()
            steps2 += 1
            let rows = tracks.visibleRows
            let blank = rows.contains { r in
                ((table.view(atColumn: nameCol, row: r, makeIfNecessary: false) as? TrackCellView)?.displayedText ?? "").isEmpty
            }
            if blank { blankScreens += 1 }
        }
        let calls2 = await library.tracksCalls, served2 = await library.rowsServed, largest2 = await library.largestTracksRequest
        info("reader-paced scroll: \(steps2) screens in \(Self.f(Self.ms(ContinuousClock.now - t1))) ms, \(calls2) fetches, "
             + "\(served2) rows served (largest \(largest2)), cache \(tracks.cachedRowCount), evictions \(tracks.cacheEvictions - evictions0)")
        check("the row cache evicts and stays within a few thousand rows",
              tracks.cacheEvictions > evictions0 && tracks.cachedRowCount <= tracks.cacheCapacity + tracks.cacheCapacity / 4,
              "\(tracks.cachedRowCount) cached after \(served2) rows fetched, \(tracks.cacheEvictions - evictions0) evicted")
        check("every screenful fills once its fetch lands", blankScreens == 0 && largest2 < 400,
              "\(blankScreens) of \(steps2) screens had a blank row; largest fetch \(largest2) ids")
        table.scrollRowToVisible(0)
        await settle()
    }

    private func scrollerArrowChecks() async {
        guard let tracks, let window else { return }
        guard let scroller = tracks.listScrollView.verticalScroller as? AquaScroller else { return }
        let clip = tracks.listScrollView.contentView
        tracks.tableView.scrollRowToVisible(0)
        await settle()
        let y0 = clip.bounds.origin.y

        check("arrows hit-test at the bottom of the scroller",
              scroller.region(atLocal: NSPoint(x: 7, y: scroller.bounds.height - 24)) == .arrowBack
              && scroller.region(atLocal: NSPoint(x: 7, y: scroller.bounds.height - 8)) == .arrowForward
              && scroller.incrementArrowRect.height == 16,
              "pair rects \(scroller.decrementArrowRect) \(scroller.incrementArrowRect)")

        click(scroller, at: NSPoint(x: 7, y: scroller.bounds.height - 8), in: window)
        let y1 = clip.bounds.origin.y
        check("one click on the down arrow scrolls one 17 pt row", y1 - y0 == 17, "Δy \(y1 - y0)")
        click(scroller, at: NSPoint(x: 7, y: scroller.bounds.height - 24), in: window)
        let y2 = clip.bounds.origin.y
        check("one click on the up arrow scrolls back one row", y2 == y0, "Δy \(y2 - y1)")

        click(scroller, at: NSPoint(x: 7, y: scroller.bounds.height - 8), in: window, holdFor: 1.0)
        let held = clip.bounds.origin.y - y2
        let rows = held / 17
        check("press-and-hold repeats", held > 17 * 5 && held.truncatingRemainder(dividingBy: 17) == 0,
              "held 1.0 s → \(Int(rows)) rows (Δy \(held))")

        // Paging: a click in the trough below the knob moves a screenful less one row.
        let knob = scroller.knobRect
        let pageY = knob.maxY + 20
        let before = clip.bounds.origin.y
        if pageY < scroller.slotRect.maxY {
            click(scroller, at: NSPoint(x: 7, y: pageY), in: window)
            let paged = clip.bounds.origin.y - before
            let page = clip.bounds.height - clip.contentInsets.top - clip.contentInsets.bottom
            check("a click in the trough pages down a screenful less one row", abs(paged - (page - 17)) < 1,
                  "Δy \(paged), unobscured page \(page)")
        }

        // Dragging the knob 40 pt moves proportionally.
        let knob2 = scroller.knobRect
        let start = NSPoint(x: knob2.midX, y: knob2.midY)
        let v0 = scroller.doubleValue
        drag(scroller, from: start, by: 40, in: window)
        let travel = scroller.slotRect.height - 2 - knob2.height
        let expected = 40 / travel
        check("dragging the knob scrolls proportionally", abs((scroller.doubleValue - v0) - Double(expected)) < 0.01,
              "value \(Self.f(v0)) → \(Self.f(scroller.doubleValue)), expected +\(Self.f(Double(expected)))")
        tracks.tableView.scrollRowToVisible(0)
        await settle()
    }

    private func headerAndColumnChecks() async {
        guard let tracks, let window, let library else { return }
        let table = tracks.tableView
        guard let header = table.headerView else { return }

        // A real click on the Time header (AppKit's own header tracking, synthetic events).
        let timeCol = table.column(withIdentifier: TrackColumn.time.identifier)
        let rect = header.headerRect(ofColumn: timeCol)
        click(header, at: NSPoint(x: rect.midX, y: rect.midY), in: window)
        await tracks.waitForLoad()
        let first = tracks.query.sort
        // A second click inside the double-click interval is a double-click; wait it out.
        try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.15))
        click(header, at: NSPoint(x: rect.midX, y: rect.midY), in: window)
        await tracks.waitForLoad()
        let second = tracks.query.sort
        check("clicking a header sorts by it; clicking again reverses",
              first == TrackSort(field: .time, ascending: true) && second == TrackSort(field: .time, ascending: false),
              "first \(first.field.rawValue)/\(first.ascending), second \(second.field.rawValue)/\(second.ascending)")
        let cell = table.tableColumns[timeCol].headerCell as? TrackHeaderCell
        check("sort triangle follows the sorted column", cell?.sortAscending == false)
        await settle()
        snapshot("09_sorted_by_time_desc.png")

        // The sort is saved, and a new track list (what the next launch builds) opens with it:
        // same order, same triangle.
        let savedSort = UserDefaults.standard.dictionary(forKey: TrackListViewController.sortDefaultsKey)
        check("a header click saves the sort for the next launch",
              savedSort?["field"] as? String == "time" && savedSort?["ascending"] as? Bool == false,
              "saved \(savedSort ?? [:])")
        let fresh = TrackListViewController(library: library)
        _ = fresh.view
        await fresh.waitForLoad()
        let timeOrder = (try? await library.ids(for: TrackQuery(sort: second))) ?? []
        let freshCell = fresh.tableView.tableColumns.first { $0.identifier == TrackColumn.time.identifier }?.headerCell
        check("a new track list opens with the saved sort", fresh.query.sort == second && !timeOrder.isEmpty
              && fresh.order == timeOrder && (freshCell as? TrackHeaderCell)?.sortAscending == false,
              "sort \(fresh.query.sort.field.rawValue) asc=\(fresh.query.sort.ascending); \(fresh.order.count) rows, "
              + "same as the Time order: \(fresh.order == timeOrder)")

        // Header menu: show/hide columns, Name always on, Year and Plays offered.
        guard let menu = header.menu, let delegate = menu.delegate else { return }
        delegate.menuNeedsUpdate?(menu)
        let titles = menu.items.map(\.title)
        let name = menu.items.first { $0.title == "Name" }
        let year = menu.items.first { $0.title == "Year" }
        check("header menu lists columns with Year and Plays", titles.contains("Year") && titles.contains("Plays")
              && name?.isEnabled == false && year?.state == .off, "\(titles)")
        if let genreItem = menu.items.first(where: { $0.title == "Genre" }), let action = genreItem.action {
            NSApp.sendAction(action, to: genreItem.target, from: genreItem)
            let saved = TrackColumnLayout.load().entries.first { $0.id == "genre" }
            let col = table.tableColumns.first { $0.identifier.rawValue == "genre" }
            check("hiding a column persists in UserDefaults", col?.isHidden == true && saved?.hidden == true)
            NSApp.sendAction(action, to: genreItem.target, from: genreItem)
        }
        if let yearItem = year, let action = yearItem.action {
            NSApp.sendAction(action, to: yearItem.target, from: yearItem)
            check("Year can be shown", table.tableColumns.first { $0.identifier.rawValue == "year" }?.isHidden == false)
            await settle()
            snapshot("10_year_column_shown.png")
            NSApp.sendAction(action, to: yearItem.target, from: yearItem)
        }
        if let artist = table.tableColumns.first(where: { $0.identifier.rawValue == "artist" }) {
            let old = artist.width
            artist.width = 177
            let saved = TrackColumnLayout.load().entries.first { $0.id == "artist" }
            check("column width persists in UserDefaults", saved?.width == 177, "saved \(saved?.width ?? -1)")
            artist.width = old
        }
        tracks.query.sort = TrackSort(field: .artist, ascending: true)
        await tracks.waitForLoad()
        // Only a header click saves: the benches and the smoke test set sorts in code all the time.
        let afterCode = UserDefaults.standard.dictionary(forKey: TrackListViewController.sortDefaultsKey)
        check("a sort set in code is not saved", afterCode?["field"] as? String == "time", "saved \(afterCode ?? [:])")
    }

    private func keyboardAndMenuChecks() async {
        guard let tracks, let window else { return }
        let table = tracks.tableView
        focus(table)
        table.selectRowIndexes(IndexSet(integer: 5), byExtendingSelection: false)
        let id = tracks.order[5]
        activations.removeAll()
        if let ret = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, characters: "\r",
                                      charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
            table.keyDown(with: ret)
        }
        check("Return activates the selected row with the current order",
              activations.first?.0 == id && activations.first?.1 == tracks.order.count, "\(activations.map(\.0))")

        getInfoEvents.removeAll()
        if let cmdI = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, characters: "i",
                                       charactersIgnoringModifiers: "i", isARepeat: false, keyCode: 34) {
            _ = table.performKeyEquivalent(with: cmdI)
        }
        check("⌘I asks for Get Info on the selection", getInfoEvents.first == [id])

        activations.removeAll()
        let rowRect = table.rect(ofRow: 7)
        click(table, at: NSPoint(x: rowRect.midX, y: rowRect.midY), in: window, clickCount: 2)
        check("double-click activates the clicked row", activations.first?.0 == tracks.order[7],
              "\(activations.map(\.0)) vs \(tracks.order[7])")
        table.selectRowIndexes(IndexSet(integer: 5), byExtendingSelection: false)

        guard let menu = table.menu, let delegate = menu.delegate else { return }
        delegate.menuNeedsUpdate?(menu)
        let titles = menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
        check("row menu has Play, Get Info, Show in Finder", titles == ["Play", "Get Info", "—", "Show in Finder"], "\(titles)")
        let finderEnabled = menu.items.last?.isEnabled
        check("Show in Finder is off for a cloud-only row", finderEnabled == false)
        activations.removeAll()
        if let play = menu.items.first, let action = play.action { NSApp.sendAction(action, to: play.target, from: play) }
        getInfoEvents.removeAll()
        if let get = menu.items.dropFirst().first, let action = get.action { NSApp.sendAction(action, to: get.target, from: get) }
        check("menu Play and Get Info call back", activations.first?.0 == id && getInfoEvents.first == [id])
    }

    private func revealAndNowPlaying() async {
        guard let tracks else { return }
        let table = tracks.tableView
        let target = tracks.order[min(9_000, tracks.order.count - 1)]
        tracks.reveal(target)
        await settle()
        let row = table.selectedRow
        let visible = tracks.visibleRows
        check("reveal selects and scrolls to the row", tracks.selectedIDs == [target] && visible.contains(row),
              "row \(row) in visible \(visible)")
        tracks.setNowPlaying(target, isPlaying: true)
        await settle()
        snapshot("11_revealed_row_9000.png")
    }

    // MARK: Synthetic mouse

    private func mouse(_ type: NSEvent.EventType, at p: NSPoint, in window: NSWindow, clickCount: Int = 1) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount,
                           pressure: type == .leftMouseUp ? 0 : 1)
    }

    /// A click (mouse-up already queued) or a press held for `holdFor` seconds.
    private func click(_ view: NSView, at local: NSPoint, in window: NSWindow, holdFor: TimeInterval? = nil,
                       clickCount: Int = 1) {
        let p = view.convert(local, to: nil)
        guard let down = mouse(.leftMouseDown, at: p, in: window, clickCount: clickCount),
              let up = mouse(.leftMouseUp, at: p, in: window, clickCount: clickCount) else { return }
        if let holdFor {
            Self.pendingMouseUp = up
            let timer = Timer(timeInterval: holdFor, repeats: false) { _ in
                MainActor.assumeIsolated {
                    if let e = ListsBench.pendingMouseUp { NSApp.postEvent(e, atStart: false) }
                    ListsBench.pendingMouseUp = nil
                }
            }
            RunLoop.main.add(timer, forMode: .common)
        } else {
            NSApp.postEvent(up, atStart: false)
        }
        view.mouseDown(with: down)
    }

    private func drag(_ view: NSView, from local: NSPoint, by dy: CGFloat, in window: NSWindow) {
        let start = view.convert(local, to: nil)
        // View coordinates are flipped (down = +y); window coordinates grow upward.
        let end = view.convert(NSPoint(x: local.x, y: local.y + dy), to: nil)
        guard let down = mouse(.leftMouseDown, at: start, in: window),
              let moved = mouse(.leftMouseDragged, at: end, in: window),
              let up = mouse(.leftMouseUp, at: end, in: window) else { return }
        NSApp.postEvent(moved, atStart: false)
        NSApp.postEvent(up, atStart: false)
        view.mouseDown(with: down)
    }
}

/// Stand-in for the chrome module's brushed metal: the horizontal gradient only, no grain.
private final class HarnessBackdrop: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        Theme.metal.draw(in: bounds, angle: 0)
    }
}

/// Claims to be key so the snapshots show the focused (blue) selection without the harness
/// stealing focus from whatever Noah has in front: `open` launches it in the background and
/// macOS 14+ cooperative activation will not let it take over. First-responder changes still
/// decide which table looks focused, which is the behaviour under test.
private final class HarnessWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}

/// HARNESS ONLY: forwards to the real-library stand-in but reports a fixed playlist list, so
/// folder behaviour can be shown with Noah's real playlists filed into fixture folders.
private struct FolderFixtureLibrary: LibraryReading {
    let base: ListsHarnessLibrary
    let playlists: [PlaylistInfo]

    func ids(for query: TrackQuery) async throws -> [Track.ID] { try await base.ids(for: query) }
    func tracks(ids: [Track.ID]) async throws -> [Track] { try await base.tracks(ids: ids) }
    func summary(for ids: [Track.ID]) async throws -> LibrarySummary { try await base.summary(for: ids) }
    func playlists() async throws -> [PlaylistInfo] { playlists }
    func browserValues(_ field: BrowserField, for query: TrackQuery) async throws -> [String] {
        try await base.browserValues(field, for: query)
    }
    func count() async throws -> Int { try await base.count() }
}
