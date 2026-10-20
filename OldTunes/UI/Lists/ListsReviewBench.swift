import AppKit

/// HARNESS ONLY (OLDTUNES_HARNESS=lists; OLDTUNES_LISTS_MODE=review runs it alone). Regression
/// checks for the review findings fixed in the lists module: 4 (playlist order), 8 and 13 (a
/// library change blanking the list; cancelled loads logged as errors), 18 (table style padding),
/// 19 (pane borders drawn twice), 22 (pane header weight) and 23 (the per-song checkbox).
///
/// The panes sit inside the chrome module's ChromePaneFrameView at MetalContentView's geometry,
/// so the borders and offsets checked here are the ones the app shows.
@MainActor
final class ListsReviewBench {
    private(set) var passes = 0
    private(set) var failures: [String] = []
    private let outDir: URL
    private var window: NSWindow?
    private var backdrop: NSView?
    private var lib: StressLibrary?
    private var base: ListsHarnessLibrary?
    private var snap: ListsHarnessLibrary.Snapshot?
    private var source: SourceListViewController?
    private var tracks: TrackListViewController?
    private var sourceFrame: ChromePaneFrameView?
    private var trackFrame: ChromePaneFrameView?
    private var activations: [(id: Track.ID, order: [Track.ID])] = []

    init(outDir: URL) { self.outDir = outDir }

    // MARK: Reporting

    private func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if ok { passes += 1 } else { failures.append(name) }
        Log.info("lists-review: \(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    }

    private func info(_ s: String) { Log.info("lists-review: \(s)") }
    private func pause(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
    private static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    // MARK: Run

    func run() async {
        // ListsHarness.run() puts the user's own values back at the end.
        for key in ListsHarness.layoutKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        let snap: ListsHarnessLibrary.Snapshot
        do { snap = try await ListsHarnessLibrary.readITLibrary() } catch {
            check("read ITLibrary", false, "\(error)")
            return
        }
        self.snap = snap
        let base = ListsHarnessLibrary(index: await ListsHarnessLibrary.buildIndex(snap))
        let lib = StressLibrary(base: base)
        self.base = base
        self.lib = lib
        buildWindow(library: lib)
        guard let tracks, let source else { return }
        await source.reload()
        await tracks.waitForLoad()
        await settle()
        info("library \(snap.tracks.count) songs; list shows \(tracks.order.count) rows")

        await borderChecks()
        await geometryChecks()
        await paneHeaderFontChecks()
        await reloadKeepsRows()
        await cancelledLoadIsNotAnError()
        await playlistOrderChecks()
        await checkboxChecks()

        info("SUMMARY passed=\(passes) failed=\(failures.count)\(failures.isEmpty ? "" : " failures=\(failures)")")
    }

    // MARK: Window

    /// MetalContentView's layout: source content at x 17, 158 wide; track content from x 186 to
    /// 16 pt short of the right edge; each inside its own one-device-pixel chrome frame.
    private func buildWindow(library: any LibraryReading) {
        let size = NSSize(width: 1000, height: 620)
        let window = ReviewWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "OldTunes — lists review checks"
        window.isReleasedWhenClosed = false
        window.colorSpace = .sRGB
        let backdrop = ReviewBackdrop(frame: NSRect(origin: .zero, size: size))
        window.contentView = backdrop

        let source = SourceListViewController(library: library)
        let tracks = TrackListViewController(library: library)
        let (sourceFrame, trackFrame) = HarnessPanes.frame(source: source.view, tracks: tracks.view, in: backdrop)
        source.onScopeChange = { [weak tracks] scope in tracks?.query.scope = scope }
        tracks.onActivate = { [weak self] id, order in self?.activations.append((id, order)) }

        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(tracks.tableView)
        self.window = window
        self.backdrop = backdrop
        self.source = source
        self.tracks = tracks
        self.sourceFrame = sourceFrame
        self.trackFrame = trackFrame
    }

    private func settle() async {
        guard let tracks else { return }
        await tracks.waitForLoad()
        await tracks.waitForRows()
        await pause(60)
        window?.layoutIfNeeded()
        window?.displayIfNeeded()
    }

    /// Without real activation AppKit draws every table unfocused; give the focused table's rows
    /// the emphasis a key window would.
    private func applyFocusLook() {
        guard let window else { return }
        let focused = window.firstResponder as? NSTableView
        for table in [tracks?.tableView, source?.tableView].compactMap({ $0 }) {
            let on = table === focused
            table.enumerateAvailableRowViews { rowView, _ in rowView.isEmphasized = on }
        }
    }

    @discardableResult
    private func snapshot(_ name: String) -> NSBitmapImageRep? {
        guard let window else { return nil }
        applyFocusLook()
        window.layoutIfNeeded()
        window.displayIfNeeded()
        let url = outDir.appendingPathComponent(name)
        guard Snapshot.write(window, to: url), let data = try? Data(contentsOf: url),
              let rep = NSBitmapImageRep(data: data) else {
            check("snapshot \(name)", false, "write failed")
            return nil
        }
        info("snapshot \(url.path) (\(rep.pixelsWide)x\(rep.pixelsHigh) px)")
        return rep
    }

    // MARK: Pixels (device pixels, top-left origin, raw sRGB bytes)

    private struct RGB: CustomStringConvertible {
        var r: Int, g: Int, b: Int
        var maxChannel: Int { max(r, g, b) }
        var minChannel: Int { min(r, g, b) }
        var description: String { String(format: "#%02X%02X%02X", r, g, b) }
        @MainActor func near(_ c: NSColor, _ tolerance: Int = 4) -> Bool {
            guard let s = ListsHarness.srgb(c) else { return false }
            return abs(r - Int((s.redComponent * 255).rounded())) <= tolerance
                && abs(g - Int((s.greenComponent * 255).rounded())) <= tolerance
                && abs(b - Int((s.blueComponent * 255).rounded())) <= tolerance
        }
    }

    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    private func rgb(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> RGB? {
        guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh, rep.samplesPerPixel >= 3 else { return nil }
        var raw = [Int](repeating: 0, count: max(rep.samplesPerPixel, 4))
        rep.getPixel(&raw, atX: x, y: y)
        return RGB(r: raw[0], g: raw[1], b: raw[2])
    }

    /// A view's bounds in device pixels: first pixel inside at the top-left, first pixel past it
    /// at the bottom-right. Converts the rectangle, so flipped and unflipped views both work.
    private func deviceRect(_ view: NSView) -> (minX: Int, minY: Int, maxX: Int, maxY: Int) {
        guard let backdrop else { return (0, 0, 0, 0) }
        let r = backdrop.convert(view.bounds, from: view)
        return (Int((r.minX * scale).rounded()), Int((r.minY * scale).rounded()),
                Int((r.maxX * scale).rounded()), Int((r.maxY * scale).rounded()))
    }

    /// The device pixel holding point `p` of `view`.
    private func devicePixel(_ view: NSView, _ p: NSPoint) -> (x: Int, y: Int) {
        guard let backdrop else { return (0, 0) }
        let c = backdrop.convert(p, from: view)
        return (Int((c.x * scale).rounded(.down)), Int((c.y * scale).rounded(.down)))
    }

    private func color(_ rep: NSBitmapImageRep, in view: NSView, at p: NSPoint) -> RGB? {
        let d = devicePixel(view, p)
        return rgb(rep, d.x, d.y)
    }

    /// The frame line and anything else as dark as it (#666 is 102; list content, header
    /// gradients, scroller troughs and metal are all well above 150).
    private static func isDark(_ c: RGB?) -> Bool { (c?.maxChannel ?? 255) < 150 }

    /// Dark device pixels on a line through an edge, from `from` to `to` inclusive (either order).
    private func darkRun(_ rep: NSBitmapImageRep, horizontal: Bool, fixed: Int, from: Int, to: Int) -> [Int] {
        stride(from: min(from, to), through: max(from, to), by: 1).filter { v in
            Self.isDark(horizontal ? rgb(rep, v, fixed) : rgb(rep, fixed, v))
        }
    }

    // MARK: 19 — every pane edge is one device pixel, drawn once (by the chrome frame)

    private func borderChecks() async {
        guard let tracks, let source, let sourceFrame, let trackFrame else { return }
        tracks.isBrowserVisible = false
        source.select(.library)
        tracks.tableView.deselectAll(nil)
        await settle()
        guard let rep = snapshot("R1_borders_single.png") else { return }
        // Each edge: the content rectangle's first device pixel and the 6 on either side of it.
        func edges(_ frame: ChromePaneFrameView, _ name: String) -> [String] {
            let d = deviceRect(frame.content)
            let tl = (x: d.minX, y: d.minY), br = (x: d.maxX, y: d.maxY)
            let midY = (tl.y + br.y) / 2, midX = (tl.x + br.x) / 2
            var problems: [String] = []
            func one(_ edge: String, _ run: [Int], expect: Int, insideColor: RGB?) {
                let ok = run == [expect]
                if !ok { problems.append("\(name) \(edge): dark px \(run), want only [\(expect)]") }
                info("\(name) \(edge): dark px \(run) (frame line expected at \(expect)); first inside \(insideColor.map(\.description) ?? "nil")")
            }
            one("left", darkRun(rep, horizontal: true, fixed: midY, from: tl.x - 6, to: tl.x + 6), expect: tl.x - 1,
                insideColor: rgb(rep, tl.x, midY))
            one("right", darkRun(rep, horizontal: true, fixed: midY, from: br.x - 6, to: br.x + 6), expect: br.x,
                insideColor: rgb(rep, br.x - 1, midY))
            one("top", darkRun(rep, horizontal: false, fixed: midX, from: tl.y - 6, to: tl.y + 6), expect: tl.y - 1,
                insideColor: rgb(rep, midX, tl.y))
            one("bottom", darkRun(rep, horizontal: false, fixed: midX, from: br.y - 6, to: br.y + 6), expect: br.y,
                insideColor: rgb(rep, midX, br.y - 1))
            return problems
        }
        let s = edges(sourceFrame, "source"), t = edges(trackFrame, "track")
        check("every pane edge is a single device-pixel line (chrome frame only)", s.isEmpty && t.isEmpty,
              (s + t).isEmpty ? "8 edges, one dark device pixel each" : "\(s + t)")
        // The first content pixel inside the left edges is list or header, never the frame or metal.
        let srcRect = deviceRect(sourceFrame.content), trkRect = deviceRect(trackFrame.content)
        let srcIn = rgb(rep, srcRect.minX, (srcRect.minY + srcRect.maxY) / 2)
        let trkIn = rgb(rep, trkRect.minX, (trkRect.minY + trkRect.maxY) / 2)
        check("the first pixel inside each pane is list content", (srcIn?.minChannel ?? 0) >= 0xE0 && (trkIn?.minChannel ?? 0) >= 0xE0,
              "source \(srcIn.map(\.description) ?? "nil"), track \(trkIn.map(\.description) ?? "nil")")

        // With the browser open: one line under the browser, one over the list, metal between.
        tracks.isBrowserVisible = true
        await settle()
        for _ in 0..<100 where (tracks.columnBrowser.pane(.genre)?.values.isEmpty ?? true) { await pause(20) }
        await settle()
        guard let rep2 = snapshot("R1b_borders_browser.png") else { return }
        let browser = deviceRect(tracks.columnBrowser)
        let bTop = browser.minY, bBottom = browser.maxY
        let x = deviceRect(trackFrame.content).minX + Int(60 * scale)
        let listTop = deviceRect(tracks.listScrollView).minY
        let between = darkRun(rep2, horizontal: false, fixed: x, from: bBottom - 6, to: listTop + 6)
        info("browser: content y px \(bTop)..\(bBottom), list scroll view top px \(listTop); dark px between \(between)")
        let topRun = darkRun(rep2, horizontal: false, fixed: x, from: bTop - 6, to: bTop + 6)
        check("browser and list each have one rule facing the splitter, nothing doubled",
              between.count == 2 && (between.last ?? 0) - (between.first ?? 0) > 4 && topRun.count == 1,
              "dark px across the splitter \(between); at the pane top \(topRun)")
        tracks.isBrowserVisible = false
        await settle()
    }

    // MARK: 18 — no first/last-column padding; 18 pt indicator; source offsets as §7.2

    private func geometryChecks() async {
        guard let tracks, let source, let window, let sourceFrame, let trackFrame else { return }
        let table = tracks.tableView
        let col0 = table.rect(ofColumn: 0)
        let s = source.tableView
        let sCell = s.frameOfCell(atColumn: 0, row: 1)
        info("track style \(table.style.rawValue) effective \(table.effectiveStyle.rawValue); indicator column rect \(col0); "
             + "source cell \(sCell) in table width \(s.bounds.width)")
        check("tables use .plain (no padding before the first or after the last column)",
              table.style == .plain && table.effectiveStyle == .plain && s.style == .plain
              && (tracks.columnBrowser.pane(.genre)?.table.style == .plain),
              "track \(table.style.rawValue)/\(table.effectiveStyle.rawValue), source \(s.style.rawValue)")
        check("indicator column is 18 pt wide (first separator 18 pt in, as x 186..203)", col0.minX == 0 && col0.width == 18,
              "rect \(col0)")
        check("source cells start at the pane's left edge and span it", sCell.minX == 0 && sCell.width == s.bounds.width,
              "cell \(sCell), table width \(s.bounds.width)")
        if let pane = tracks.columnBrowser.pane(.genre) {
            let b = pane.table.frameOfCell(atColumn: 0, row: 0)
            check("browser cells start at the pane's left edge", b.minX == 0 && b.width == pane.table.bounds.width,
                  "cell \(b), table width \(pane.table.bounds.width)")
        }

        // Pixels: the header separator and the row column line 17 pt into the track content, the
        // icon 14 pt and the text 33 pt into the source content (window x 31 and 50 at §7.2's size).
        source.select(.library)
        table.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        table.scrollRowToVisible(0)
        window.makeFirstResponder(table)
        await settle()
        guard let rep = snapshot("R2_indicator_18pt_and_offsets.png") else { return }
        let edge = deviceRect(trackFrame.content).minX
        if let header = table.headerView {
            let y = devicePixel(header, NSPoint(x: 0, y: 7)).y
            let seps = stride(from: edge, through: edge + 70, by: 1).filter { rgb(rep, $0, y)?.near(Theme.colSep, 6) == true }
            info("header separators (px from track content edge): \(seps.map { $0 - edge })")
            check("first header separator 17 pt into the track pane (pixels 34–35 at 2x)",
                  seps.first.map { $0 - edge } == Int(17 * scale), "separator px \(seps.map { $0 - edge })")
        }
        let rowY = devicePixel(table, NSPoint(x: 0, y: table.rect(ofRow: 0).midY)).y
        let lines = stride(from: edge, through: edge + 70, by: 1).filter { rgb(rep, $0, rowY)?.near(ListsPalette.rowColumnLine, 4) == true }
        check("first row column line under it", lines.first.map { $0 - edge } == Int(17 * scale),
              "column-line px \(lines.map { $0 - edge })")

        // Source list: "On This Mac" (row 1, unselected). Columns of device pixels with any ink:
        // the first run is the icon, the next run after a gap is the text.
        let sEdge = deviceRect(sourceFrame.content).minX
        let r = s.rect(ofRow: 1)
        let rowTop = devicePixel(s, NSPoint(x: 0, y: r.minY + 1)).y, rowBottom = devicePixel(s, NSPoint(x: 0, y: r.maxY - 1)).y
        let inked = (0..<Int(60 * scale)).map { dx in
            (rowTop...rowBottom).contains { py in (rgb(rep, sEdge + dx, py)?.minChannel ?? 255) < 0xE6 }
        }
        let iconInk = inked.firstIndex(of: true) ?? -1
        let iconEnd = inked[max(iconInk, 0)...].firstIndex(of: false) ?? inked.count
        let textInk = inked[min(iconEnd, inked.count)...].firstIndex(of: true) ?? -1
        let iconPt = CGFloat(iconInk) / scale, textPt = CGFloat(textInk) / scale
        check("source icon starts 14 pt into the pane (x 31 at §7.2's size)", abs(iconPt - 14) <= 0.5,
              "first icon ink \(iconPt) pt from the content edge")
        check("source text starts 33 pt into the pane (x 50 at §7.2's size)", textPt >= 33 && textPt <= 34.5,
              "first text ink \(textPt) pt from the content edge")

        // The selection is still full-bleed and square: no modern inset or rounding at either end.
        let sel = table.rect(ofRow: 3)
        let leftCorner = color(rep, in: table, at: NSPoint(x: 0.25, y: sel.minY + 0.25))
        let leftMid = color(rep, in: table, at: NSPoint(x: 0.25, y: sel.midY))
        let visibleRight = tracks.listScrollView.unobscuredDocumentRect.maxX
        let rightCorner = color(rep, in: table, at: NSPoint(x: visibleRight - 0.25, y: sel.minY + 0.25))
        check("track selection fills to both ends with square corners",
              leftCorner?.near(Theme.trkSel) == true && leftMid?.near(Theme.trkSel) == true && rightCorner?.near(Theme.trkSel) == true,
              "left corner \(leftCorner.map(\.description) ?? "nil"), left mid \(leftMid.map(\.description) ?? "nil"), "
              + "right corner \(rightCorner.map(\.description) ?? "nil")")
        let sSel = s.rect(ofRow: 0)
        let sCorner = color(rep, in: s, at: NSPoint(x: 0.25, y: sSel.minY + 0.25))
        let sRight = color(rep, in: s, at: NSPoint(x: s.bounds.width - 0.25, y: sSel.minY + 0.25))
        let sMid = color(rep, in: s, at: NSPoint(x: 0.25, y: sSel.midY))
        let grayOrBlue = { (c: RGB?) -> Bool in (c?.maxChannel ?? 255) < 0xD0 }
        check("source selection fills to both ends with square corners",
              grayOrBlue(sCorner) && grayOrBlue(sRight) && grayOrBlue(sMid),
              "corner \(sCorner.map(\.description) ?? "nil"), right \(sRight.map(\.description) ?? "nil"), mid \(sMid.map(\.description) ?? "nil")")
        table.deselectAll(nil)
    }

    // MARK: 22 — Source / Genre / Artist / Album in regular Lucida Grande 11

    private func paneHeaderFontChecks() async {
        guard let tracks, let source, let backdrop else { return }
        tracks.isBrowserVisible = true
        await settle()
        var headers: [PaneHeaderView] = []
        func collect(_ v: NSView) {
            if let h = v as? PaneHeaderView { headers.append(h) }
            v.subviews.forEach(collect)
        }
        collect(source.view)
        for field in BrowserField.allCases { if let h = tracks.columnBrowser.pane(field)?.header { headers.append(h) } }
        var results: [String] = []
        var allRegular = headers.count == 4
        for header in headers {
            let actual = render(header)
            func reference(_ font: NSFont) -> NSBitmapImageRep? {
                let ref = ReferencePaneHeader(title: header.title, font: font)
                ref.frame = backdrop.convert(header.bounds, from: header)
                backdrop.addSubview(ref)
                defer { ref.removeFromSuperview() }
                return render(ref)
            }
            let regular = Self.differingBytes(actual, reference(Theme.paneHeaderFont))
            let bold = Self.differingBytes(actual, reference(Theme.boldFont))
            results.append("\(header.title): \(regular) bytes differ from regular, \(bold) from bold")
            if regular != 0 || bold == 0 { allRegular = false }
        }
        check("pane headers draw in regular Lucida Grande 11 (Theme.paneHeaderFont)", allRegular, results.joined(separator: "; "))
        tracks.isBrowserVisible = false
        await settle()
    }

    private func render(_ view: NSView) -> NSBitmapImageRep? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private static func differingBytes(_ a: NSBitmapImageRep?, _ b: NSBitmapImageRep?) -> Int {
        guard let a, let b, let pa = a.bitmapData, let pb = b.bitmapData,
              a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh, a.bytesPerRow == b.bytesPerRow else { return -1 }
        var diff = 0
        for i in 0..<(a.bytesPerRow * a.pixelsHigh) where pa[i] != pb[i] { diff += 1 }
        return diff
    }

    // MARK: 8 and 13 — a library change keeps the rows on screen until fresh ones land

    /// Visible rows whose Name cell has no text. `make` asks the table for any cell it has not
    /// built yet, through the same delegate call a draw makes: after reloadData NSTableView builds
    /// its row views on the next layout, which an occluded window may not get, and a missing
    /// view would otherwise count as blank.
    private func nameCellsBlank(make: Bool = false) -> (blank: Int, of: Int) {
        guard let tracks else { return (0, 0) }
        let table = tracks.tableView
        let nameCol = table.column(withIdentifier: TrackColumn.name.identifier)
        let rows = tracks.visibleRows
        let blank = rows.filter { row in
            ((table.view(atColumn: nameCol, row: row, makeIfNecessary: make) as? TrackCellView)?.displayedText ?? "").isEmpty
        }.count
        return (blank, rows.count)
    }

    /// Visible rows whose Name cell has dark text pixels in a snapshot.
    private func rowsWithInk(_ rep: NSBitmapImageRep) -> (inked: Int, of: Int) {
        guard let tracks else { return (0, 0) }
        let table = tracks.tableView
        let nameCol = table.column(withIdentifier: TrackColumn.name.identifier)
        var inked = 0
        let rows = tracks.visibleRows
        for row in rows {
            let cell = table.frameOfCell(atColumn: nameCol, row: row)
            var found = false
            for x in stride(from: cell.minX + 16, to: cell.minX + 90, by: 0.5) where !found {
                for y in stride(from: cell.minY + 4, to: cell.maxY - 3, by: 0.5) {
                    if (color(rep, in: table, at: NSPoint(x: x, y: y))?.maxChannel ?? 255) < 0x70 { found = true; break }
                }
            }
            if found { inked += 1 }
        }
        return (inked, rows.count)
    }

    private func reloadKeepsRows() async {
        guard let tracks, let lib, let base else { return }
        tracks.query.sort = TrackSort(field: .name, ascending: true)
        await tracks.waitForLoad()
        tracks.tableView.scrollRowToVisible(3_000)
        tracks.tableView.deselectAll(nil)
        await settle()
        let before = nameCellsBlank()
        // A slow row read, so any blank state lasts long enough to see.
        await lib.setTracksLatency(.milliseconds(400))
        let calls0 = await lib.tracksCalls
        let t0 = ContinuousClock.now
        await tracks.reload()
        let built = nameCellsBlank()
        let applied = nameCellsBlank(make: true)
        window?.displayIfNeeded()
        let rep = snapshot("R3_reload_in_flight.png")
        let ink: (inked: Int, of: Int) = rep.map(rowsWithInk) ?? (0, 0)
        let onScreen = window?.occlusionState.contains(.visible) ?? false
        info("reload applied after \(Self.f(Self.ms(ContinuousClock.now - t0))) ms (window on screen: \(onScreen)); blank name cells "
             + "before \(before.blank)/\(before.of), right after apply \(applied.blank)/\(applied.of) "
             + "(\(built.blank) of them not built yet by the table); rows with text in the mid-flight snapshot \(ink.inked)/\(ink.of)")
        check("a library change keeps every visible row drawn while fresh rows load (findings 8, 13)",
              applied.blank == 0 && applied.of > 10 && ink.inked == ink.of,
              "\(applied.blank) of \(applied.of) Name cells blank after reload's reloadData; \(ink.inked) of \(ink.of) rows show text in the snapshot")

        // The refetch really happens and its content replaces the old rows.
        let target = tracks.order[tracks.visibleRows.lowerBound + 2]
        await base.markMissing([target])
        await tracks.reload()
        await pause(900)
        let calls1 = await lib.tracksCalls
        let table = tracks.tableView
        let nameCol = table.column(withIdentifier: TrackColumn.name.identifier)
        let row = tracks.order.firstIndex(of: target) ?? -1
        let dimmed = (table.view(atColumn: nameCol, row: row, makeIfNecessary: false) as? TrackCellView)?.isDimmed ?? false
        let after = nameCellsBlank()
        check("the fresh rows replace the kept ones once they land",
              calls1 > calls0 && dimmed && after.blank == 0 && !tracks.isShowingKeptRows,
              "\(calls1 - calls0) row fetches; changed row \(row) dimmed=\(dimmed); \(after.blank) blank; "
              + "old copies dropped: \(!tracks.isShowingKeptRows)")
        await base.markMissing([])
        await lib.setTracksLatency(.zero)
        await tracks.reload()
        await settle()
        await reloadThatMovesRows()
    }

    /// The Name text each visible row should show, from the library.
    private func expectedNames() async -> [Int: String] {
        guard let tracks, let base else { return [:] }
        let rows = Array(tracks.visibleRows)
        let fresh = (try? await base.tracks(ids: rows.map { tracks.order[$0] })) ?? []
        let byID = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [Int: String] = [:]
        for row in rows { if let t = byID[tracks.order[row]] { out[row] = TrackCellView.text(for: .name, of: t) } }
        return out
    }

    /// Visible rows whose Name cell does not show `expected` (a missing cell counts).
    private func mismatchedRows(_ expected: [Int: String]) -> [Int] {
        guard let tracks else { return [] }
        let table = tracks.tableView
        let nameCol = table.column(withIdentifier: TrackColumn.name.identifier)
        return expected.keys.sorted().filter { row in
            (table.view(atColumn: nameCol, row: row, makeIfNecessary: false) as? TrackCellView)?.displayedText != expected[row]
        }
    }

    /// A library change that moves one visible song and removes another. The table must keep its
    /// row views the whole time (reloadData took them all down until the next layout, so a frame
    /// committed in between showed an empty list), and every visible row must show its own song,
    /// from the kept copy while the fresh rows load.
    private func reloadThatMovesRows() async {
        guard let tracks, let lib else { return }
        let top = tracks.visibleRows.lowerBound
        let moved = tracks.order[top + 6], removed = tracks.order[top + 9]
        let target = top + 1
        await lib.setOrderEdit { ids in
            var ids = ids.filter { $0 != removed }
            if let i = ids.firstIndex(of: moved) { ids.remove(at: i); ids.insert(moved, at: min(target, ids.count)) }
            return ids
        }
        await lib.setTracksLatency(.milliseconds(400))
        let watcher = CommitWatcher(tracks: tracks)
        watcher.start()
        let countBefore = tracks.order.count
        // Inside apply(), before the run loop can lay the table out again: how many row views are
        // still standing. reloadData() takes them all down at once.
        let savedOrderChange = tracks.onOrderChange
        var standing: Int?
        tracks.onOrderChange = { [weak tracks] order in
            savedOrderChange?(order)
            guard let tracks else { return }
            let visible = tracks.listScrollView.unobscuredDocumentRect
            standing = tracks.tableView.subviews.compactMap { $0 as? NSTableRowView }.filter { !$0.isHidden && $0.frame.intersects(visible) }.count
        }
        await tracks.reload()
        tracks.onOrderChange = savedOrderChange
        let expected = await expectedNames()
        let inFlight = mismatchedRows(expected)
        await tracks.waitForRows()
        await pause(100)
        watcher.stop()
        let landed = mismatchedRows(await expectedNames())
        let movedRow = tracks.order.firstIndex(of: moved) ?? -1
        info("moving reload: \(watcher.commits) commits watched, \(watcher.withoutRowViews) without the row views, "
             + "\(watcher.withBlankNames) with blank Name cells; moved song now row \(movedRow) (want \(target)); "
             + "rows \(countBefore) → \(tracks.order.count); row views standing when the new order applied "
             + "\(standing.map(String.init) ?? "?") of \(tracks.visibleRows.count); mismatched rows in flight \(inFlight), after landing \(landed)")
        check("a library change that moves and removes rows refills them in place, never showing an empty list",
              (standing ?? 0) >= tracks.visibleRows.count
              && watcher.commits > 0 && watcher.withoutRowViews == 0 && watcher.withBlankNames == 0 && inFlight.isEmpty && landed.isEmpty
              && movedRow == target && tracks.order.count == countBefore - 1 && !tracks.order.contains(removed),
              "row views standing at apply \(standing.map(String.init) ?? "?") of \(tracks.visibleRows.count); "
              + "\(watcher.withoutRowViews) of \(watcher.commits) commits without row views, \(watcher.withBlankNames) with blank names; "
              + "wrong rows in flight \(inFlight.count), after \(landed.count)")
        await lib.setOrderEdit(nil)
        await lib.setTracksLatency(.zero)
        await tracks.reload()
        await settle()
    }

    private static func f(_ v: Double) -> String { String(format: "%.1f", v) }

    // MARK: 8 — a cancelled load is not an error

    private func cancelledLoadIsNotAnError() async {
        guard let tracks, let lib else { return }
        let nonce = UUID().uuidString
        await lib.setInterruptible((.milliseconds(300), nonce))
        tracks.query.sort = TrackSort(field: .album, ascending: true)
        await pause(60)                               // the album load is inside ids(for:)
        tracks.query.sort = TrackSort(field: .time, ascending: true)   // cancels it
        await tracks.waitForLoad()
        await pause(100)
        await lib.setInterruptible(nil)
        Log.flush()
        let logged = Self.logLines(containing: nonce)
        let errors = logged.filter { $0.contains(" ERROR ") }
        check("an interrupted, cancelled load is not logged as ERROR", errors.isEmpty && tracks.query.sort.field == .time,
              errors.isEmpty ? "no log line mentions the interrupted query" : "\(errors.count) line(s): \(errors.first ?? "")")
    }

    /// Lines of the app log (shared by every OldTunes process) that contain `needle`.
    private static func logLines(containing needle: String) -> [String] {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/OldTunes/oldtunes.log")
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > 4_000_000 ? end - 4_000_000 : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init).filter { $0.contains(needle) }
    }

    // MARK: 4 — a playlist shows and plays in its own order

    private func playlistOrderChecks() async {
        guard let tracks, let source, let base, let lib, let snap, let window else { return }
        // A regular playlist whose own order is not its artist order (most hand-made ones).
        var chosen: (PlaylistInfo, [Int64])?
        for p in snap.playlists where p.kind == .regular && p.trackCount >= 6 {
            let own = await base.playlistOrder(p.id)
            var q = TrackQuery(); q.scope = .playlist(p.id)
            let artist = (try? await base.ids(for: q)) ?? []
            if own.count >= 6 && own != artist && Set(own) == Set(artist) { chosen = (p, own); break }
        }
        guard let (playlist, own) = chosen else {
            check("a hand-ordered playlist to test", false, "none found")
            return
        }
        // Library sorted by Album first, so the switch is visible. Set in code, so it is not saved:
        // leaving the playlist below must not come back to it.
        source.select(.library)
        tracks.query.sort = TrackSort(field: .album, ascending: true)
        await tracks.waitForLoad()
        // The sort switches inside the same assignment, so the switch costs one load, not two (a
        // second assignment from a helper re-entered `query`'s didSet and started a load that the
        // next line cancelled).
        let loadsBeforeEntering = await lib.idsCalls
        source.select(.playlist(playlist.id))
        await tracks.waitForLoad()
        let enteringLoads = await lib.idsCalls - loadsBeforeEntering
        await settle()
        let sortedCells = tracks.tableView.tableColumns.compactMap { ($0.headerCell as? TrackHeaderCell)?.sortAscending }
        info("\"\(playlist.name)\": own order starts \(own.prefix(4)); list shows \(tracks.order.prefix(4)); sort \(tracks.query.sort)")
        check("selecting a playlist shows it in its own order", tracks.query.sort == TrackSort(field: .playlistOrder, ascending: true)
              && tracks.order == own, "\"\(playlist.name)\" \(own.count) songs; sort \(tracks.query.sort.field.rawValue); "
              + "first rows match: \(Array(tracks.order.prefix(5)) == Array(own.prefix(5)))")
        check("in playlist order no column header shows a sort", sortedCells.isEmpty, "\(sortedCells.count) sorted header(s)")
        snapshot("R4_playlist_in_own_order.png")

        // Double-click the first row: the queue is the playlist's order, so Next plays its #2.
        activations.removeAll()
        let table = tracks.tableView
        let r0 = table.rect(ofRow: 0)
        click(table, at: NSPoint(x: r0.minX + 120, y: r0.midY), in: window, clickCount: 2)
        check("playing from a playlist queues it in its own order", activations.first?.id == own[0] && activations.first?.order == own,
              "activated \(activations.first.map { "\($0.id)" } ?? "nothing"); queue #2 \(activations.first?.order.dropFirst().first.map { "\($0)" } ?? "-") "
              + "vs playlist #2 \(own[1])")

        // Sort by Name with a header click, then the leftmost header brings the playlist order back.
        guard let header = table.headerView else { return }
        let nameRect = header.headerRect(ofColumn: table.column(withIdentifier: TrackColumn.name.identifier))
        click(header, at: NSPoint(x: nameRect.midX, y: nameRect.midY), in: window)
        await tracks.waitForLoad()
        let byName = tracks.query.sort
        try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.15))
        let indicatorRect = header.headerRect(ofColumn: 0)
        click(header, at: NSPoint(x: indicatorRect.midX, y: indicatorRect.midY), in: window)
        await tracks.waitForLoad()
        check("clicking the leftmost header restores the playlist order",
              byName.field == .name && tracks.query.sort == TrackSort(field: .playlistOrder, ascending: true) && tracks.order == own,
              "after Name click \(byName.field.rawValue); after leftmost click \(tracks.query.sort.field.rawValue)")
        try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.15))
        click(header, at: NSPoint(x: indicatorRect.midX, y: indicatorRect.midY), in: window)
        await tracks.waitForLoad()
        check("a second leftmost click keeps the playlist order", tracks.query.sort == TrackSort(field: .playlistOrder, ascending: true)
              && tracks.order == own, "sort \(tracks.query.sort.field.rawValue) asc=\(tracks.query.sort.ascending)")

        // Leaving the playlist while in its order goes back to the last header sort: the Name click
        // above, not the Library's Album (set in code) and not Artist.
        let loadsBeforeLeaving = await lib.idsCalls
        source.select(.library)
        await tracks.waitForLoad()
        let leavingLoads = await lib.idsCalls - loadsBeforeLeaving
        check("entering and leaving a playlist each start one load", enteringLoads == 1 && leavingLoads == 1,
              "ids(for:) calls: entering \(enteringLoads), leaving \(leavingLoads)")
        var nameQuery = TrackQuery(); nameQuery.sort = byName
        let nameOrder = (try? await base.ids(for: nameQuery)) ?? []
        check("leaving a playlist in its own order goes back to the last header sort",
              byName == TrackSort(field: .name, ascending: true) && tracks.query.sort == byName && tracks.order == nameOrder,
              "Library sort \(tracks.query.sort.field.rawValue) asc=\(tracks.query.sort.ascending)")
        try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.15))
        click(header, at: NSPoint(x: indicatorRect.midX, y: indicatorRect.midY), in: window)
        await tracks.waitForLoad()
        check("outside a playlist the leftmost header does nothing", tracks.query.sort == byName,
              "sort \(tracks.query.sort.field.rawValue)")

        // A sort remembered per source (integration's choice) wins over the playlist default, even
        // when it equals the sort already showing.
        let showing = tracks.query.sort
        let idsBefore = await lib.idsCalls
        tracks.setScope(.playlist(playlist.id), sort: showing)
        await tracks.waitForLoad()
        let explicitOK = tracks.query.scope == .playlist(playlist.id) && tracks.query.sort == showing
        let oneLoad = await lib.idsCalls - idsBefore
        tracks.setScope(.library, sort: nil)
        await tracks.waitForLoad()
        tracks.setScope(.playlist(playlist.id), sort: nil)
        await tracks.waitForLoad()
        let defaultOK = tracks.query.sort.field == .playlistOrder && tracks.order == own
        tracks.setScope(.onThisMac, sort: TrackSort(field: .playlistOrder, ascending: true))
        await tracks.waitForLoad()
        check("setScope(_:sort:) applies a remembered sort in one load; nil picks the playlist order",
              explicitOK && oneLoad == 1 && defaultOK && tracks.query.sort == byName,
              "explicit \(showing.field.rawValue) kept \(explicitOK) in \(oneLoad) load(s); nil → \(defaultOK ? "own order" : "other"); "
              + ".playlistOrder outside a playlist → \(tracks.query.sort.field.rawValue) (the last header sort)")
        // setScope went around the source list, which still has Library selected.
        tracks.setScope(.library, sort: nil)
        await tracks.waitForLoad()
        check("back in Library with every song", tracks.query.scope == .library && tracks.order.count == snap.tracks.count,
              "\(tracks.order.count) rows")
    }

    // MARK: 23 — the per-song checkbox

    private func checkboxChecks() async {
        guard let tracks, let window else { return }
        let table = tracks.tableView
        tracks.query.sort = TrackSort(field: .artist, ascending: true)
        await tracks.waitForLoad()
        table.scrollRowToVisible(0)
        table.deselectAll(nil)
        window.makeFirstResponder(table)
        await settle()
        guard let rep = snapshot("R5_checkbox_column.png") else { return }
        let nameCol = table.column(withIdentifier: TrackColumn.name.identifier)
        let cell = table.frameOfCell(atColumn: nameCol, row: 1)
        // Clear of the tick: the gel's lower band, a quarter of the way across the box.
        let mid = color(rep, in: table, at: NSPoint(x: cell.minX + 5.5, y: cell.minY + 12))
        let blue = (mid?.b ?? 0) - (mid?.r ?? 0)
        check("each Name cell starts with a blue Aqua checkbox", blue > 50, "box interior \(mid.map(\.description) ?? "nil")")

        // Every visible Name cell draws a gel now; a full repaint must still fit in a frame.
        // cacheDisplay draws every row and cell synchronously (displayIfNeeded only marks layers).
        var worstDraw = 0.0, cellsDrawn = 0
        table.enumerateAvailableRowViews { rowView, _ in
            for case let cell as TrackCellView in rowView.subviews where cell.checkboxState != nil { cellsDrawn += 1 }
        }
        // Best of five, so other work on the Mac does not decide the result.
        let visible = tracks.listScrollView.unobscuredDocumentRect
        var bestDraw = Double.infinity
        for _ in 0..<5 {
            guard let bitmap = table.bitmapImageRepForCachingDisplay(in: visible) else { break }
            let t = ContinuousClock.now
            table.cacheDisplay(in: visible, to: bitmap)
            let ms = Self.ms(ContinuousClock.now - t)
            worstDraw = max(worstDraw, ms)
            bestDraw = min(bestDraw, ms)
        }
        // What the boxes alone add: a screenful of them drawn at 2x.
        var bestBoxes = Double.infinity
        if let bits = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0),
           let context = NSGraphicsContext(bitmapImageRep: bits) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.scaleBy(x: 2, y: 2)
            for _ in 0..<5 {
                let t = ContinuousClock.now
                for i in 0..<cellsDrawn {
                    TrackCellView.drawCheckbox(in: NSRect(x: 2.5, y: 2, width: 12, height: 12), checked: i % 7 != 0)
                }
                context.flushGraphics()
                bestBoxes = min(bestBoxes, Self.ms(ContinuousClock.now - t))
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        check("repainting a screenful of rows with their checkboxes fits in a frame",
              bestDraw < 16.7 && bestBoxes < 4 && cellsDrawn > 20,
              "whole visible list best \(Self.f(bestDraw)) ms (worst \(Self.f(worstDraw))); the \(cellsDrawn) boxes alone "
              + "\(String(format: "%.2f", bestBoxes)) ms (Debug build)")
        await checkboxBehaviour()
    }

    private func checkboxCell(_ row: Int) -> TrackCellView? {
        guard let table = tracks?.tableView else { return nil }
        let nameCol = table.column(withIdentifier: TrackColumn.name.identifier)
        return table.view(atColumn: nameCol, row: row, makeIfNecessary: false) as? TrackCellView
    }

    /// The checkbox's centre in table coordinates.
    private func boxCenter(_ row: Int) -> NSPoint {
        guard let table = tracks?.tableView else { return .zero }
        let cell = table.frameOfCell(atColumn: table.column(withIdentifier: TrackColumn.name.identifier), row: row)
        let box = TrackCellView.checkboxRect(cellHeight: cell.height)
        return NSPoint(x: cell.minX + box.midX, y: cell.minY + box.midY)
    }

    private func checkboxBehaviour() async {
        guard let tracks, let base, let window, let backdrop, let snap else { return }
        let table = tracks.tableView
        let nameCol = table.column(withIdentifier: TrackColumn.name.identifier)
        let unchecked = snap.tracks.filter { !$0.isChecked }.count
        info("Music library: \(unchecked) of \(snap.tracks.count) songs unchecked (isUserDisabled)")
        // Integration's wiring, minus the database: setChecked, then the .libraryDidChange reload.
        let probe = ToggleProbe()
        tracks.onToggleChecked = { [weak tracks] ids, checked in
            probe.toggles.append((ids, checked))
            guard !probe.writeFails else { return }
            Task {
                await base.setChecked(ids, checked)
                await tracks?.reload()
                await tracks?.waitForRows()
                probe.repainted = .now
            }
        }

        // 1. A click on the box toggles that song only and leaves the selection alone.
        table.selectRowIndexes(IndexSet([5, 6]), byExtendingSelection: false)
        let selected = tracks.selectedIDs
        let id2 = tracks.order[2]
        let before = checkboxCell(2)?.checkboxState
        activations.removeAll()
        let t0 = ContinuousClock.now
        click(table, at: boxCenter(2), in: window)
        let immediate = checkboxCell(2)?.checkboxState
        for _ in 0..<100 where probe.repainted == nil { await pause(10) }
        let latency = probe.repainted.map { Self.ms($0 - t0) } ?? -1
        await settle()
        let afterReload = checkboxCell(2)?.checkboxState
        let stored = (try? await base.tracks(ids: [id2]))?.first?.isChecked
        check("clicking a checkbox toggles that song through onToggleChecked",
              before == true && probe.toggles.count == 1 && probe.toggles.first?.ids == [id2] && probe.toggles.first?.checked == false
              && immediate == false && afterReload == false && stored == false,
              "box \(String(describing: before)) → \(String(describing: immediate)) at once → \(String(describing: afterReload)) "
              + "after the reload; library now \(String(describing: stored)); click → repainted from fresh rows in \(Self.f(latency)) ms")
        check("a checkbox click keeps the selection and plays nothing", tracks.selectedIDs == selected && activations.isEmpty,
              "selection \(tracks.selectedIDs == selected ? "unchanged" : "changed to \(tracks.selectedIDs)")")
        table.deselectAll(nil)
        await settle()
        guard let rep = snapshot("R6_checkbox_ticked_and_unticked.png") else { return }
        let c2 = table.frameOfCell(atColumn: nameCol, row: 2)
        let white = color(rep, in: table, at: NSPoint(x: c2.minX + 5.5, y: c2.minY + 12))
        var darkest = 255
        for x in stride(from: c2.minX + TrackCellView.nameTextLeft + 1, to: c2.minX + 120, by: 0.5) {
            for y in stride(from: c2.minY + 4, to: c2.maxY - 3, by: 0.5) {
                darkest = min(darkest, color(rep, in: table, at: NSPoint(x: x, y: y))?.maxChannel ?? 255)
            }
        }
        check("an unchecked box is the white gel, and its row is not dimmed",
              (white?.minChannel ?? 0) > 0xD8 && checkboxCell(2)?.isDimmed == false && darkest < 0x40,
              "box interior \(white.map(\.description) ?? "nil"), darkest title pixel \(darkest)")

        // 2. Drawn like Get Info's small checkbox, pixel for pixel inside the rim.
        var sameAsGetInfo: [String] = []
        for (row, on) in [(1, true), (2, false)] {
            let rowCell = table.frameOfCell(atColumn: nameCol, row: row)
            let box = TrackCellView.checkboxRect(cellHeight: rowCell.height).offsetBy(dx: rowCell.minX, dy: rowCell.minY)
            let ref = AquaCheckbox(title: "", size: .small)
            ref.isOn = on
            // AquaCheckbox draws its box at (0.5, 1) in a 14 × 14 frame; land it on whole points.
            ref.frame = NSRect(x: 3.5, y: backdrop.bounds.maxY - 30, width: 14, height: 14)
            backdrop.addSubview(ref)
            window.displayIfNeeded()
            guard let refRep = snapshot("R6b_getinfo_reference_\(on ? "on" : "off").png") else { ref.removeFromSuperview(); continue }
            ref.removeFromSuperview()
            var worst = 0
            let inset = Int(2 * scale), side = Int(12 * scale)
            let mine = devicePixel(table, box.origin)
            let theirs = devicePixel(backdrop, NSPoint(x: 4, y: backdrop.bounds.maxY - 29))
            for dy in inset..<(side - inset) {
                for dx in inset..<(side - inset) {
                    guard let a = rgb(refRep, mine.x + dx, mine.y + dy), let b = rgb(refRep, theirs.x + dx, theirs.y + dy) else { continue }
                    worst = max(worst, abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b))
                }
            }
            sameAsGetInfo.append("\(on ? "ticked" : "unticked") worst channel difference \(worst)")
            if worst > 3 { sameAsGetInfo.append("MISMATCH") }
        }
        check("the box matches Get Info's small Aqua checkbox", !sameAsGetInfo.contains("MISMATCH") && sameAsGetInfo.count == 2,
              sameAsGetInfo.joined(separator: "; "))

        // 3. Clicking the title text selects as usual; a double-click on the box toggles twice
        // and never plays the song.
        probe.toggles.removeAll()
        let r3 = table.rect(ofRow: 3)
        click(table, at: NSPoint(x: c2.minX + 60, y: r3.midY), in: window)
        let titleClick = probe.toggles.isEmpty && tracks.selectedIDs == [tracks.order[3]]
        activations.removeAll()
        probe.repainted = nil
        click(table, at: boxCenter(2), in: window)
        click(table, at: boxCenter(2), in: window, clickCount: 2)
        for _ in 0..<100 where probe.repainted == nil { await pause(10) }
        await settle()
        check("a title click selects; a double-click on the box toggles twice and plays nothing",
              titleClick && probe.toggles.count == 2 && probe.toggles.map(\.checked) == [true, false] && activations.isEmpty,
              "title click selected row 3: \(titleClick); box toggles \(probe.toggles.map(\.checked)); activations \(activations.count)")
        // Back to checked.
        probe.repainted = nil
        click(table, at: boxCenter(2), in: window)
        for _ in 0..<100 where probe.repainted == nil { await pause(10) }
        await settle()

        // 4. ⌘-click sets every song in the current list (here a search) to the new state.
        tracks.query.search = "oasis"
        await tracks.waitForLoad()
        await settle()
        let listed = tracks.order
        probe.toggles.removeAll()
        probe.repainted = nil
        click(table, at: boxCenter(0), in: window, modifiers: .command)
        for _ in 0..<200 where probe.repainted == nil { await pause(10) }
        await settle()
        let shownStates = Set(tracks.visibleRows.compactMap { checkboxCell($0)?.checkboxState })
        let storedAll = Set(((try? await base.tracks(ids: listed)) ?? []).map(\.isChecked))
        check("⌘-click sets every song in the current list to the clicked box's new state",
              probe.toggles.count == 1 && probe.toggles.first?.ids == listed && probe.toggles.first?.checked == false
              && shownStates == [false] && storedAll == [false] && listed.count < snap.tracks.count,
              "\(probe.toggles.first?.ids.count ?? 0) ids (list has \(listed.count) of \(snap.tracks.count)); boxes now \(shownStates); library \(storedAll)")
        snapshot("R6c_command_click_all_unticked.png")
        probe.repainted = nil
        click(table, at: boxCenter(0), in: window, modifiers: .command)
        for _ in 0..<200 where probe.repainted == nil { await pause(10) }
        await settle()
        let restored = Set(tracks.visibleRows.compactMap { checkboxCell($0)?.checkboxState })
        check("a second ⌘-click turns them all back on", restored == [true] && probe.toggles.last?.checked == true, "boxes \(restored)")
        tracks.query.search = ""
        await tracks.waitForLoad()
        await settle()

        // 5. The boxes repaint from the Track rows after a library change (nothing cached apart).
        let id4 = tracks.order[4]
        await base.setChecked([id4], false)
        await tracks.reload()
        await tracks.waitForRows()
        await pause(100)
        let external = checkboxCell(4)?.checkboxState
        await base.setChecked([id4], true)
        await tracks.reload()
        await tracks.waitForRows()
        await pause(100)
        check("boxes repaint from the library's rows after a change made elsewhere",
              external == false && checkboxCell(4)?.checkboxState == true,
              "unchecked in the library → box \(String(describing: external)); checked again → \(String(describing: checkboxCell(4)?.checkboxState))")

        // 6. A write that fails (no reload follows): the box goes back to what the library holds.
        probe.writeFails = true
        click(table, at: boxCenter(3), in: window)
        let optimistic = checkboxCell(3)?.checkboxState
        await pause(2_600)
        await tracks.waitForRows()
        await pause(100)
        check("if the write fails, the box returns to the library's state", optimistic == false && checkboxCell(3)?.checkboxState == true,
              "shown \(String(describing: optimistic)) at once, \(String(describing: checkboxCell(3)?.checkboxState)) 2.6 s later")
        probe.writeFails = false
        tracks.onToggleChecked = nil
        await base.clearCheckedOverrides()
    }

    // MARK: Synthetic mouse

    private func mouse(_ type: NSEvent.EventType, at p: NSPoint, in window: NSWindow, clickCount: Int = 1,
                       modifiers: NSEvent.ModifierFlags = []) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount,
                           pressure: type == .leftMouseUp ? 0 : 1)
    }

    private func click(_ view: NSView, at local: NSPoint, in window: NSWindow, clickCount: Int = 1,
                       modifiers: NSEvent.ModifierFlags = []) {
        let p = view.convert(local, to: nil)
        guard let down = mouse(.leftMouseDown, at: p, in: window, clickCount: clickCount, modifiers: modifiers),
              let up = mouse(.leftMouseUp, at: p, in: window, clickCount: clickCount, modifiers: modifiers) else { return }
        NSApp.postEvent(up, atStart: false)
        view.mouseDown(with: down)
    }
}

/// Counts, at each run-loop pass after Core Animation's commit (order 2,000,000), whether the track
/// table had a row view for every visible row and whether any visible Name cell was blank.
@MainActor
private final class CommitWatcher {
    private let tracks: TrackListViewController
    private var observer: CFRunLoopObserver?
    private(set) var commits = 0
    private(set) var withoutRowViews = 0
    private(set) var withBlankNames = 0

    init(tracks: TrackListViewController) { self.tracks = tracks }

    func start() {
        let obs = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 3_000_000) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
        observer = obs
    }

    func stop() {
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
    }

    private func sample() {
        let table = tracks.tableView
        let rows = tracks.visibleRows
        guard !rows.isEmpty else { return }
        commits += 1
        let visible = tracks.listScrollView.unobscuredDocumentRect
        let rowViews = table.subviews.compactMap { $0 as? NSTableRowView }.filter { !$0.isHidden && $0.frame.intersects(visible) }
        if rowViews.count < rows.count { withoutRowViews += 1 }
        let nameCol = table.column(withIdentifier: TrackColumn.name.identifier)
        if rows.contains(where: { ((table.view(atColumn: nameCol, row: $0, makeIfNecessary: false) as? TrackCellView)?.displayedText ?? "").isEmpty }) {
            withBlankNames += 1
        }
    }
}

/// What the bench's stand-in for integration saw of checkbox clicks.
@MainActor
private final class ToggleProbe {
    var toggles: [(ids: [Track.ID], checked: Bool)] = []
    var writeFails = false
    var repainted: ContinuousClock.Instant?
}

/// Stand-in for the chrome's metal: the horizontal gradient only.
private final class ReviewBackdrop: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { Theme.metal.draw(in: bounds, angle: 0) }
}

/// Claims key so snapshots show focused selections without stealing focus from Noah's front app.
private final class ReviewWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}

/// PaneHeaderView's drawing with a chosen font, to tell which weight the real header used.
private final class ReferencePaneHeader: NSView {
    let title: String
    let font: NSFont
    init(title: String, font: NSFont) {
        self.title = title
        self.font = font
        super.init(frame: .zero)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let band = NSRect(x: 0, y: 0, width: bounds.width, height: Theme.Metrics.columnHeaderHeight)
        Theme.paneHeader.draw(in: band, angle: 90)
        ListsPalette.headerRule.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
        let attrs = Theme.textAttributes(font, color: ListsPalette.paneHeaderText, alignment: .center)
        (title as NSString).draw(in: NSRect(x: 2, y: 1, width: bounds.width - 4, height: 13), withAttributes: attrs)
    }
}

/// HARNESS ONLY. Puts the lists into the chrome module's pane frames at MetalContentView's
/// geometry (source content from x 17, 158 wide; a 9 pt splitter plus borders; track content to
/// 16 pt short of the right edge), so every bench sees the borders and offsets the app shows. The
/// lists draw no outer border of their own; without a frame they would sit borderless on metal.
@MainActor
enum HarnessPanes {
    static let sourceLeft: CGFloat = 17
    static let trackLeft: CGFloat = 17 + Theme.Metrics.sourcePaneWidth + 11

    /// Either list may be nil. The frames follow the backdrop when the window resizes.
    @discardableResult
    static func frame(source: NSView?, tracks: NSView?, in backdrop: NSView, top: CGFloat = 12,
                      bottom: CGFloat = 46) -> (source: ChromePaneFrameView, track: ChromePaneFrameView) {
        let size = backdrop.bounds.size
        let sourceFrame = ChromePaneFrameView(style: .source)
        let trackFrame = ChromePaneFrameView(style: .track)
        let height = size.height - top - bottom
        sourceFrame.contentRect = NSRect(x: sourceLeft, y: top, width: Theme.Metrics.sourcePaneWidth, height: height)
        trackFrame.contentRect = NSRect(x: trackLeft, y: top, width: max(size.width - 16 - trackLeft, 0), height: height)
        sourceFrame.autoresizingMask = [.height]
        trackFrame.autoresizingMask = [.width, .height]
        for (child, frame) in [(source, sourceFrame), (tracks, trackFrame)] {
            frame.content.autoresizingMask = [.width, .height]
            backdrop.addSubview(frame)
            guard let child else { continue }
            child.frame = frame.content.bounds
            child.autoresizingMask = [.width, .height]
            frame.content.addSubview(child)
        }
        return (sourceFrame, trackFrame)
    }
}
