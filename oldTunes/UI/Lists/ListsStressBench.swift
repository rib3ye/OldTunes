import AppKit

/// HARNESS ONLY (runs after the scenario bench under OLDTUNES_HARNESS=lists). Adversarial checks
/// for what a user hits and a scripted walk-through does not: small scrolls onto rows that were
/// prepared before their data landed, reload() racing a row fetch, a slow query that ignores
/// cancellation, edits made while a search is still debouncing, empty results, resizes, rapid
/// sorting, header clicks over a selection, persistence read back by a fresh controller, and
/// what a ⌘A drag of the whole library writes before it starts.
///
/// Every wait here is plain time passing, never `waitForRows()`, which fetches on its own and
/// so would hide a list that forgot to.
@MainActor
final class ListsStressBench {
    private(set) var passes = 0
    private(set) var failures: [String] = []
    private let outDir: URL
    private var window: NSWindow?
    private var lib: StressLibrary?
    private var tracks: TrackListViewController?
    private var source: SourceListViewController?
    /// Kept alive and on screen until the run ends: closing, releasing or even ordering out the
    /// last visible window quits the app (applicationShouldTerminateAfterLastWindowClosed).
    private var spareWindows: [NSWindow] = []

    private var selectionEvents = 0
    private var orderEvents: [[Track.ID]] = []
    private var activations = 0

    init(outDir: URL) { self.outDir = outDir }

    private func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if ok { passes += 1 } else { failures.append(name) }
        Log.info("lists-stress: \(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    }

    private func info(_ s: String) { Log.info("lists-stress: \(s)") }

    private static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    private func pause(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

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
        let base = ListsHarnessLibrary(index: await ListsHarnessLibrary.buildIndex(snap))
        let lib = StressLibrary(base: base)
        self.lib = lib
        buildWindow(library: lib)
        guard let tracks else { return }
        await emptyLibraryChecks()
        await tracks.waitForLoad()
        await pause(400)
        info("library \(snap.tracks.count) songs; list shows \(tracks.order.count) rows")

        await smallScrollsFillRows()
        await reloadDuringFetch()
        await staleSlowQuery()
        await sortDuringSearchDebounce()
        await emptyResult()
        await selectionCallbacks()
        await headerClickKeepsSelection()
        await browserDuringSearchDebounce()
        await browserScopeFallback(localCount: snap.tracks.filter { $0.fileURL != nil }.count)
        await browserSplitterDrag()
        await rapidSorts()
        await resizeFills()
        await selectAllResort()
        await dragWriterTiming()
        await nowPlayingFollowsSort()
        await columnLayoutRestores()
        await shownColumnScrollsIntoView()
        await focusSwitching()
        await contextMenuLook()
        await sourceReloadRace(snap: snap)
        await dataFacts(snap: snap)

        info("SUMMARY passed=\(passes) failed=\(failures.count)\(failures.isEmpty ? "" : " failures=\(failures)")")
    }

    // MARK: Window

    private func buildWindow(library: any LibraryReading) {
        let size = NSSize(width: 1000, height: 620)
        let window = StressWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "oldTunes — lists stress"
        window.isReleasedWhenClosed = false
        window.colorSpace = .sRGB
        let backdrop = StressBackdrop(frame: NSRect(origin: .zero, size: size))
        backdrop.autoresizingMask = [.width, .height]
        window.contentView = backdrop
        let source = SourceListViewController(library: library)
        let tracks = TrackListViewController(library: library)
        HarnessPanes.frame(source: source.view, tracks: tracks.view, in: backdrop)
        source.onScopeChange = { [weak tracks] scope in tracks?.query.scope = scope }
        tracks.onSelectionChange = { [weak self] _ in self?.selectionEvents += 1 }
        tracks.onOrderChange = { [weak self] order in self?.orderEvents.append(order) }
        tracks.onActivate = { [weak self] _, _ in self?.activations += 1 }
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(tracks.tableView)
        self.window = window
        self.tracks = tracks
        self.source = source
    }

    /// Visible rows whose Name cell has no text. Every visible row in these tests has a title.
    private func blankVisibleRows() -> [Int] {
        guard let tracks else { return [] }
        let table = tracks.tableView
        let nameCol = table.column(withIdentifier: TrackColumn.name.identifier)
        return tracks.visibleRows.filter { row in
            ((table.view(atColumn: nameCol, row: row, makeIfNecessary: false) as? TrackCellView)?.displayedText ?? "").isEmpty
        }
    }

    private func snapshot(_ name: String) {
        guard let window else { return }
        window.layoutIfNeeded()
        window.displayIfNeeded()
        let url = outDir.appendingPathComponent(name)
        if Snapshot.write(window, to: url) { info("snapshot \(url.path)") }
    }

    // MARK: Checks

    /// An empty library: nothing to show must not crash, and the panes still draw.
    private func emptyLibraryChecks() async {
        let window = StressWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 420),
                                  styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.colorSpace = .sRGB
        let backdrop = StressBackdrop(frame: NSRect(x: 0, y: 0, width: 700, height: 420))
        window.contentView = backdrop
        let source = SourceListViewController(library: EmptyLibrary())
        let tracks = TrackListViewController(library: EmptyLibrary())
        HarnessPanes.frame(source: source.view, tracks: tracks.view, in: backdrop)
        window.orderFront(nil)
        await source.reload()
        tracks.isBrowserVisible = true
        await tracks.waitForLoad()
        await pause(200)
        tracks.reveal(42)
        tracks.setNowPlaying(42, isPlaying: true)
        tracks.query.search = "anything"
        await tracks.waitForLoad()
        await tracks.reload()
        await pause(100)
        window.layoutIfNeeded()
        window.displayIfNeeded()
        let url = outDir.appendingPathComponent("S0_empty_library.png")
        Snapshot.write(window, to: url)
        info("snapshot \(url.path)")
        var shown: [String] = []
        for field in BrowserField.allCases {
            guard let pane = tracks.columnBrowser.pane(field) else { continue }
            let cell = pane.table.view(atColumn: 0, row: 0, makeIfNecessary: false) as? BrowserCellView
            shown.append(cell?.displayedText ?? "nothing")
            info("empty \(field.rawValue) pane: rows=\(pane.table.numberOfRows) table=\(pane.table.frame) "
                 + "column=\(pane.table.tableColumns.first?.width ?? -1) clip=\(pane.scrollView.contentView.bounds) "
                 + "selected=\(pane.table.selectedRow)")
        }
        check("an empty library shows empty lists without crashing", tracks.order.isEmpty && source.rowTitles == ["Library", "On This Mac"]
              && shown == ["All (0 Genres)", "All (0 Artists)", "All (0 Albums)"],
              "rows \(tracks.order.count), sources \(source.rowTitles), browser panes show \(shown)")
        tracks.isBrowserVisible = false
        spareWindows.append(window)
        self.window?.orderFront(nil)
    }

    /// Rows prepared while their data was still being fetched (under the header, or in the
    /// table's overdraw) must fill in too: a one-line scroll should never uncover a blank row.
    private func smallScrollsFillRows() async {
        guard let tracks, let window, let scroller = tracks.listScrollView.verticalScroller as? AquaScroller else { return }
        let table = tracks.tableView
        var blanks: [String] = []
        for start in [6_000, 9_500, 13_000] {
            table.scrollRowToVisible(start)
            window.displayIfNeeded()
            await pause(400)                       // the fetch lands on its own
            for step in [-1, -1, -1, 1, 1, 1, 1, 1] {
                scroller.scrollLines(step)
                window.displayIfNeeded()
                await pause(120)
                let blank = blankVisibleRows()
                if !blank.isEmpty { blanks.append("from \(start) step \(step): rows \(blank)") }
            }
        }
        // And right after a sort, when every row on screen was fetched fresh.
        tracks.query.sort = TrackSort(field: .album, ascending: true)
        await tracks.waitForLoad()
        await pause(400)
        for step in [1, 1, -1, -1, -1] {
            scroller.scrollLines(step)
            window.displayIfNeeded()
            await pause(120)
            let blank = blankVisibleRows()
            if !blank.isEmpty { blanks.append("after sort step \(step): rows \(blank)") }
        }
        check("one-line scrolls never uncover a blank row", blanks.isEmpty,
              blanks.isEmpty ? "3 positions + after a sort, 8 + 5 line scrolls each" : "\(blanks.prefix(4))")
        snapshot("S1_after_line_scrolls.png")
    }

    /// reload() (after .libraryDidChange) while a row fetch is still running.
    private func reloadDuringFetch() async {
        guard let tracks, let lib, let window else { return }
        await lib.setTracksLatency(.milliseconds(500))
        tracks.tableView.scrollRowToVisible(2_500)
        window.displayIfNeeded()
        await pause(40)                           // the fetch for this screen is now in flight
        await tracks.reload()
        await pause(1_700)                        // both fetches have had time to land
        let blank = blankVisibleRows()
        check("reload() during a row fetch still fills every visible row", blank.isEmpty,
              "\(blank.count) of \(tracks.visibleRows.count) visible rows blank 1.7 s later")
        await lib.setTracksLatency(.zero)
        snapshot("S2_reload_during_fetch.png")
    }

    /// A slow query that ignores cancellation lands after a newer one: it must be dropped.
    private func staleSlowQuery() async {
        guard let tracks, let lib else { return }
        var oasisQuery = tracks.query
        oasisQuery.search = "oasis"
        let expected = (try? await lib.base.ids(for: oasisQuery)) ?? []
        await lib.setIDsLatency(["a": .milliseconds(800)])
        await lib.resetCounters()
        tracks.query.search = "a"
        await pause(220)                          // past the debounce: "a" is inside the library
        tracks.query.search = "oasis"
        await tracks.waitForLoad()
        await pause(900)                          // "a" comes back now
        let completed = await lib.completedSearches
        check("a slow query that ignores cancellation never replaces a newer result",
              tracks.order == expected && completed == ["oasis", "a"] && !expected.isEmpty,
              "returned in order \(completed); list \(tracks.order.count) rows, oasis \(expected.count)")
        await lib.setIDsLatency([:])
        tracks.query.search = ""
        await tracks.waitForLoad()
    }

    /// A sort change while a search is still debouncing applies both, with one query.
    private func sortDuringSearchDebounce() async {
        guard let tracks, let lib else { return }
        await lib.resetCounters()
        tracks.query.search = "nderw"
        tracks.query.sort = TrackSort(field: .time, ascending: false)
        await tracks.waitForLoad()
        await pause(250)
        let expected = (try? await lib.base.ids(for: tracks.query)) ?? []
        let calls = await lib.idsCalls
        check("a sort during the search debounce applies both in one query",
              tracks.order == expected && !expected.isEmpty && calls == 1,
              "\(tracks.order.count) rows, \(calls) ids(for:) call(s)")
        tracks.query.search = ""
        tracks.query.sort = .default
        await tracks.waitForLoad()
    }

    private func emptyResult() async {
        guard let tracks, let window else { return }
        tracks.tableView.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        orderEvents.removeAll()
        let selectionBefore = selectionEvents
        tracks.query.search = "qqzzxjv no such song"
        await tracks.waitForLoad()
        await pause(200)
        tracks.reveal(12345)
        tracks.setNowPlaying(12345, isPlaying: true)
        window.displayIfNeeded()
        let scroller = tracks.listScrollView.verticalScroller as? AquaScroller
        check("a search with no matches shows an empty list and no scroller", tracks.order.isEmpty && tracks.selectedIDs.isEmpty
              && orderEvents.last == [] && selectionEvents == selectionBefore + 1 && scroller?.knobRect == .zero
              && scroller?.isHidden == true,
              "rows \(tracks.order.count), onOrderChange \(orderEvents.map(\.count)), "
              + "selection events +\(selectionEvents - selectionBefore), knob \(scroller?.knobRect ?? .null), "
              + "scroller \(scroller?.isHidden == true ? "hidden" : "shown")")
        snapshot("S3_no_matches.png")
        tracks.setNowPlaying(nil, isPlaying: false)
        tracks.query.search = ""
        await tracks.waitForLoad()
        await pause(300)
        check("clearing it brings the rows, the scroller and its knob back", tracks.order.count > 15_000
              && scroller?.isHidden == false && scroller?.knobRect != .zero && blankVisibleRows().isEmpty,
              "\(tracks.order.count) rows")
    }

    /// A re-sort that keeps the same selected songs is not a selection change.
    private func selectionCallbacks() async {
        guard let tracks else { return }
        tracks.tableView.selectRowIndexes(IndexSet([3, 8, 20]), byExtendingSelection: false)
        let before = Set(tracks.selectedIDs)
        let events = selectionEvents
        tracks.query.sort = TrackSort(field: .name, ascending: false)
        await tracks.waitForLoad()
        tracks.query.sort = TrackSort(field: .dateAdded, ascending: false)
        await tracks.waitForLoad()
        check("re-sorting does not report an unchanged selection as changed",
              Set(tracks.selectedIDs) == before && selectionEvents == events,
              "\(selectionEvents - events) onSelectionChange call(s) for 2 re-sorts; rows now \(Array(tracks.tableView.selectedRowIndexes))")
    }

    /// A real click on a header sorts and leaves the row selection alone (no column selection).
    private func headerClickKeepsSelection() async {
        guard let tracks, let window, let header = tracks.tableView.headerView else { return }
        let table = tracks.tableView
        table.selectRowIndexes(IndexSet([2, 5]), byExtendingSelection: false)
        let before = Set(tracks.selectedIDs)
        let col = table.column(withIdentifier: TrackColumn.album.identifier)
        let rect = header.headerRect(ofColumn: col)
        click(header, at: NSPoint(x: rect.midX, y: rect.midY), in: window)
        await tracks.waitForLoad()
        await pause(150)
        check("a header click sorts and keeps the selected rows", tracks.query.sort.field == .album
              && Set(tracks.selectedIDs) == before && table.selectedColumnIndexes.isEmpty,
              "sort \(tracks.query.sort.field.rawValue); selected columns \(Array(table.selectedColumnIndexes)); "
              + "rows \(tracks.selectedIDs.count) of \(before.count); allowsColumnSelection=\(table.allowsColumnSelection)")
        snapshot("S4_header_click_keeps_selection.png")
    }

    /// Picking a genre while a search is still debouncing: every pane must end up showing the
    /// values for the final query, not the one before the search.
    private func browserDuringSearchDebounce() async {
        guard let tracks, let lib else { return }
        tracks.isBrowserVisible = true
        let browser = tracks.columnBrowser
        guard let genrePane = browser.pane(.genre) else { return }
        for _ in 0..<150 where genrePane.values.isEmpty { await pause(20) }
        var searched = tracks.query
        searched.search = "love"
        let genresForSearch = (try? await lib.base.browserValues(.genre, for: searched)) ?? []
        guard let genre = genresForSearch.first(where: { genrePane.values.contains($0) }),
              let row = genrePane.values.firstIndex(of: genre) else {
            check("browser during search debounce", false, "no shared genre")
            return
        }
        tracks.query.search = "love"            // debouncing
        genrePane.table.selectRowIndexes(IndexSet(integer: row + 1), byExtendingSelection: false)
        await tracks.waitForLoad()
        await pause(400)
        let mismatched = await paneMismatches()
        let expectedRows = (try? await lib.base.ids(for: tracks.query)) ?? []
        check("panes match the final query after a pick during the search debounce", mismatched.isEmpty
              && tracks.query.genre == genre && tracks.order == expectedRows,
              mismatched.isEmpty ? "genre \"\(genre)\" + search \"love\": \(tracks.order.count) rows" : "\(mismatched)")
        snapshot("S5_browser_search_and_genre.png")
        tracks.query.search = ""
        await tracks.waitForLoad()
        await pause(300)
    }

    /// Switching scope to one without the picked genre falls back to All.
    private func browserScopeFallback(localCount: Int) async {
        guard let tracks, let source, let lib else { return }
        let browser = tracks.columnBrowser
        guard let genrePane = browser.pane(.genre) else { return }
        let localGenres = Set((try? await lib.base.browserValues(.genre, for: TrackQuery(scope: .onThisMac))) ?? [])
        if let row = genrePane.values.firstIndex(where: { !localGenres.contains($0) }) {
            genrePane.table.selectRowIndexes(IndexSet(integer: row + 1), byExtendingSelection: false)
            await tracks.waitForLoad()
        }
        let picked = tracks.query.genre
        source.select(.onThisMac)
        await tracks.waitForLoad()
        for _ in 0..<50 where tracks.query.genre != nil { await pause(20) }
        await tracks.waitForLoad()
        await pause(200)
        check("a scope without the picked genre falls back to All", picked != nil && tracks.query.genre == nil
              && tracks.order.count == localCount && genrePane.selectedValue == nil,
              "picked \(picked ?? "nil"); now genre \(tracks.query.genre ?? "All"), \(tracks.order.count) rows (local \(localCount))")
        source.select(.library)
        await tracks.waitForLoad()
        // Pane values load in their own tasks, after the list's ids; measure how long the panes
        // trail the list, and that they do catch up.
        let t0 = ContinuousClock.now
        var lag = await paneMismatches()
        while !lag.isEmpty && ContinuousClock.now - t0 < .seconds(2) {
            await pause(5)
            lag = await paneMismatches()
        }
        check("back in Library, every pane catches up with the list", lag.isEmpty,
              "panes matched the query \(String(format: "%.0f", Self.ms(ContinuousClock.now - t0))) ms after the list applied"
              + (lag.isEmpty ? "" : "; still \(lag)"))
    }

    /// Panes whose values differ from what the library says the current query should show.
    private func paneMismatches() async -> [String] {
        guard let tracks, let lib else { return ["no list"] }
        var out: [String] = []
        for field in BrowserField.allCases {
            guard let pane = tracks.columnBrowser.pane(field) else { continue }
            let want = (try? await lib.base.browserValues(field, for: tracks.query)) ?? []
            if pane.values != want { out.append("\(field.rawValue) shows \(pane.values.count), query has \(want.count)") }
        }
        return out
    }

    /// Dragging the splitter resizes the browser and remembers it.
    private func browserSplitterDrag() async {
        guard let tracks, let window,
              let splitter = tracks.view.subviews.first(where: { $0 is BrowserSplitterView }),
              let browserBox = tracks.view.subviews.first(where: { $0 is ColumnBrowserView }) else {
            check("splitter found", false)
            return
        }
        let h0 = browserBox.frame.height
        let start = splitter.convert(NSPoint(x: splitter.bounds.midX, y: splitter.bounds.midY), to: nil)
        let end = NSPoint(x: start.x, y: start.y - 50)   // window y grows upward: 50 pt down
        if let down = mouse(.leftMouseDown, at: start, in: window),
           let moved = mouse(.leftMouseDragged, at: end, in: window),
           let up = mouse(.leftMouseUp, at: end, in: window) {
            NSApp.postEvent(moved, atStart: false)
            NSApp.postEvent(up, atStart: false)
            splitter.mouseDown(with: down)
        }
        tracks.view.layoutSubtreeIfNeeded()
        let h1 = browserBox.frame.height
        let saved = UserDefaults.standard.double(forKey: "OldTunes.TrackList.browserFraction")
        check("dragging the browser splitter resizes and persists it", abs((h1 - h0) - 50) <= 1
              && abs(saved - Double(h1 / tracks.view.bounds.height)) < 0.01,
              "browser \(h0) → \(h1) pt, saved fraction \(String(format: "%.3f", saved))")
        snapshot("S6_splitter_dragged.png")
        tracks.isBrowserVisible = false
        await tracks.waitForLoad()
    }

    /// Twenty-five sort clicks with no pause: the list ends on the last one, correctly sorted.
    private func rapidSorts() async {
        guard let tracks, let lib else { return }
        let fields: [TrackSortField] = [.name, .artist, .album, .time, .genre, .dateAdded]
        var last = tracks.query.sort
        for i in 0..<25 {
            last = TrackSort(field: fields[i % fields.count], ascending: i % 3 != 0)
            tracks.query.sort = last
            if i % 5 == 4 { await pause(3) }
        }
        await tracks.waitForLoad()
        let expected = (try? await lib.base.ids(for: tracks.query)) ?? []
        let cell = tracks.tableView.tableColumns.compactMap { $0.headerCell as? TrackHeaderCell }.filter { $0.sortAscending != nil }
        check("25 rapid sorts end on the last one", tracks.query.sort == last && tracks.order == expected && cell.count == 1,
              "\(last.field.rawValue) \(last.ascending ? "asc" : "desc"), \(cell.count) header(s) marked sorted")
        tracks.query.sort = .default
        await tracks.waitForLoad()
    }

    /// Growing and shrinking the window fills the newly exposed rows.
    private func resizeFills() async {
        guard let tracks, let window else { return }
        tracks.tableView.scrollRowToVisible(7_000)
        await pause(400)
        var details: [String] = []
        var ok = true
        for size in [NSSize(width: 1200, height: 900), NSSize(width: 700, height: 440), NSSize(width: 1000, height: 620)] {
            window.setContentSize(size)
            window.layoutIfNeeded()
            window.displayIfNeeded()
            await pause(350)
            let blank = blankVisibleRows()
            ok = ok && blank.isEmpty
            details.append("\(Int(size.width))x\(Int(size.height)): \(tracks.visibleRows.count) rows, \(blank.count) blank")
            if size.width == 700 { snapshot("S7_small_window.png") }
        }
        check("resizing fills newly exposed rows", ok, details.joined(separator: "; "))
    }

    private func selectAllResort() async {
        guard let tracks else { return }
        tracks.tableView.selectAll(nil)
        let n = tracks.selectedIDs.count
        tracks.query.sort = TrackSort(field: .time, ascending: true)
        await tracks.waitForLoad()
        check("select-all survives a re-sort and stays cheap on the main thread",
              tracks.selectedIDs.count == n && n == tracks.order.count && tracks.lastApplyMillis < 16.7,
              "\(tracks.selectedIDs.count) of \(n) selected; main-thread apply \(String(format: "%.2f", tracks.lastApplyMillis)) ms")
        tracks.tableView.deselectAll(nil)
        tracks.query.sort = .default
        await tracks.waitForLoad()
    }

    /// What a ⌘A drag of the whole library writes before it can start: one pasteboard writer per
    /// row from the data source, all of them on the pasteboard, and SongDrag reading them back on
    /// the drop. Written to the bench's own named pasteboard, never the drag or general one. The
    /// drag images, made per item once the session starts, aren't in this: that needs a real drag,
    /// which is on Noah's hand-check list (a ⌘A drag of the library onto a playlist).
    private func dragWriterTiming() async {
        guard let tracks, let data = tracks.tableView.dataSource else { return }
        let table = tracks.tableView
        await tracks.waitForLoad()
        let rows = tracks.order.count
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.noahtsutsui.oldtunes.harness.stress-drag"))
        defer { pasteboard.releaseGlobally() }
        let t0 = ContinuousClock.now
        let writers = (0..<rows).compactMap { data.tableView?(table, pasteboardWriterForRow: $0) }
        let t1 = ContinuousClock.now
        pasteboard.clearContents()
        pasteboard.writeObjects(writers)
        let t2 = ContinuousClock.now
        let ids = SongDrag.ids(on: pasteboard)
        let t3 = ContinuousClock.now
        let total = Self.ms(t3 - t0)
        check("a ⌘A drag's pasteboard for every row is written and read back in under 2 s",
              writers.count == rows && ids == tracks.order && rows > 15_000 && total < 2_000,
              "\(rows) rows: writers \(String(format: "%.0f", Self.ms(t1 - t0))) ms, onto the pasteboard "
              + "\(String(format: "%.0f", Self.ms(t2 - t1))) ms, read back \(String(format: "%.0f", Self.ms(t3 - t2))) ms; "
              + "\(ids.count) ids, in order: \(ids == tracks.order)")
    }

    private func nowPlayingFollowsSort() async {
        guard let tracks else { return }
        let table = tracks.tableView
        let id = tracks.order[40]
        tracks.setNowPlaying(id, isPlaying: true)
        tracks.query.sort = TrackSort(field: .name, ascending: true)
        await tracks.waitForLoad()
        tracks.reveal(id)
        await pause(300)
        let row = table.selectedRow
        let indicator = table.column(withIdentifier: TrackColumn.indicator.identifier)
        let cell = table.view(atColumn: indicator, row: row, makeIfNecessary: false) as? TrackCellView
        let others = tracks.visibleRows.filter { $0 != row }.compactMap {
            (table.view(atColumn: indicator, row: $0, makeIfNecessary: false) as? TrackCellView)?.indicatorState
        }
        check("the speaker follows its song through a re-sort", tracks.order[row] == id && cell?.indicatorState == .playing
              && others.allSatisfy { $0 == .none }, "song now at row \(row)")
        tracks.setNowPlaying(nil, isPlaying: false)
        tracks.query.sort = .default
        await tracks.waitForLoad()
    }

    /// Order, widths and hidden columns written by one controller come back in a fresh one.
    private func columnLayoutRestores() async {
        guard let tracks, let lib else { return }
        let table = tracks.tableView
        let album = table.column(withIdentifier: TrackColumn.album.identifier)
        table.moveColumn(album, toColumn: 2)
        table.tableColumns.first { $0.identifier == TrackColumn.genre.identifier }?.isHidden = true
        table.tableColumns.first { $0.identifier == TrackColumn.time.identifier }?.width = 66
        TrackColumnLayout(table: table).save()   // what the hide/resize handlers do
        let fresh = TrackListViewController(library: lib)
        let restored = fresh.tableView.tableColumns.map { "\($0.identifier.rawValue)\($0.isHidden ? "(h)" : "")=\(Int($0.width))" }
        let live = table.tableColumns.map { "\($0.identifier.rawValue)\($0.isHidden ? "(h)" : "")=\(Int($0.width))" }
        let saved = TrackColumnLayout.load().entries.map(\.id)
        check("a fresh track list restores column order, widths and hidden columns", restored == live
              && saved[2] == TrackColumn.album.rawValue, "\(restored)")
        UserDefaults.standard.removeObject(forKey: TrackColumnLayout.defaultsKey)
        table.moveColumn(table.column(withIdentifier: TrackColumn.album.identifier), toColumn: 4)
        table.tableColumns.first { $0.identifier == TrackColumn.genre.identifier }?.isHidden = false
        table.tableColumns.first { $0.identifier == TrackColumn.time.identifier }?.width = TrackColumn.time.defaultWidth
    }

    /// Moving keyboard focus between the tables flips which selection is blue, through AppKit's
    /// own emphasis (nothing here sets isEmphasized), and both styles draw their Theme colors.
    /// With the app in the background AppKit draws both gray, as iTunes did; that branch is
    /// checked instead when activation is refused, and the log says which one ran.
    private func focusSwitching() async {
        guard let tracks, let source, let window else { return }
        source.select(.playlist(source.rowScopes.compactMap { scope -> Int64? in
            if case .playlist(let id) = scope { return id } else { return nil }
        }.first ?? 0))
        await tracks.waitForLoad()
        NSApp.activate()
        await pause(300)
        let sTable = source.tableView, tTable = tracks.tableView
        tTable.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        let sRow = sTable.selectedRow
        let r = sTable.rect(ofRow: sRow), t = tTable.rect(ofRow: 2)
        let x: CGFloat = 4.25

        window.makeFirstResponder(sTable)
        await pause(150)
        let active1 = NSApp.isActive
        let sourceFocused = (sTable.rowView(atRow: sRow, makeIfNecessary: false)?.isEmphasized,
                             tTable.rowView(atRow: 2, makeIfNecessary: false)?.isEmphasized)
        let rep1 = snapshotRep("S8_source_focused.png")
        window.makeFirstResponder(tTable)
        await pause(150)
        let active2 = NSApp.isActive
        let tracksFocused = (sTable.rowView(atRow: sRow, makeIfNecessary: false)?.isEmphasized,
                             tTable.rowView(atRow: 2, makeIfNecessary: false)?.isEmphasized)
        let rep2 = snapshotRep("S9_tracks_focused.png")
        guard let rep1, let rep2 else { return }
        let state = "source focused → (\(String(describing: sourceFocused.0)), \(String(describing: sourceFocused.1))); "
            + "tracks focused → (\(String(describing: tracksFocused.0)), \(String(describing: tracksFocused.1)))"

        guard active1 && active2 else {
            info("focus: the app is in the background (activation refused), so the focused branch was not exercised this run")
            let sGray = pixel(rep1, in: sTable, at: NSPoint(x: x, y: r.midY))
            let tGray = pixel(rep2, in: tTable, at: NSPoint(x: 1.5, y: t.midY))
            let neutral = { (c: NSColor?) in c.map { abs($0.redComponent - $0.blueComponent) < 0.02 } ?? false }
            check("in the background both selections are gray whichever table has focus",
                  sourceFocused == (false, false) && tracksFocused == (false, false) && neutral(sGray) && close(tGray, Theme.trkSelOff),
                  "\(state); source \(hex(sGray)), track \(hex(tGray))")
            source.select(.library)
            await tracks.waitForLoad()
            return
        }
        check("focus moves the blue selection between the tables (AppKit's own emphasis)",
              sourceFocused == (true, false) && tracksFocused == (false, true), state + "; app active")

        let edgeTop = pixel(rep1, in: sTable, at: NSPoint(x: x, y: r.minY + 0.25))
        let gradTop = pixel(rep1, in: sTable, at: NSPoint(x: x, y: r.minY + 1.25))
        let gradBottom = pixel(rep1, in: sTable, at: NSPoint(x: x, y: r.maxY - 1.25))
        let edgeBottom = pixel(rep1, in: sTable, at: NSPoint(x: x, y: r.maxY - 0.25))
        let trackOff = pixel(rep1, in: tTable, at: NSPoint(x: 1.5, y: t.midY))
        check("focused source selection: #5D8DC6 top edge, #69A7EE→#2972D8, #3A6EBD bottom edge; track row gray",
              close(edgeTop, Theme.srcSelEdgeTop) && close(gradTop, Theme.srcSelTop, 8) && close(gradBottom, Theme.srcSelBottom, 8)
              && close(edgeBottom, Theme.srcSelEdgeBottom) && close(trackOff, Theme.trkSelOff),
              "edges \(hex(edgeTop)) / \(hex(edgeBottom)), gradient \(hex(gradTop)) → \(hex(gradBottom)), track \(hex(trackOff))")
        let offMid = pixel(rep2, in: sTable, at: NSPoint(x: x, y: r.midY))
        let trackOn = pixel(rep2, in: tTable, at: NSPoint(x: 1.5, y: t.midY))
        let trackEdge = pixel(rep2, in: tTable, at: NSPoint(x: 1.5, y: t.maxY - 0.25))
        let gray = offMid.map { abs($0.redComponent - $0.blueComponent) < 0.02 } ?? false
        check("focused track selection #3C80DF with #7CADE7 edge; source selection gray",
              close(trackOn, Theme.trkSel) && close(trackEdge, Theme.trkSelEdge) && gray,
              "track \(hex(trackOn)) edge \(hex(trackEdge)), source \(hex(offMid))")
        source.select(.library)
        await tracks.waitForLoad()
    }

    /// A real right-click: the menu opens over the row, and the row must not get macOS's modern
    /// rounded context-menu outline (iTunes simply selected the row). Snapshots are taken with
    /// the menu open and after it closes; any difference around the row is that outline. The
    /// open menu is read 0.4 s after its tracking begins, by when the track list has built it (in
    /// menuNeedsUpdate) and AppKit drawn its look; a timer closes it after 2.5 s if it never opens.
    private func contextMenuLook() async {
        guard let tracks, let window else { return }
        let table = tracks.tableView
        window.makeFirstResponder(table)
        table.deselectAll(nil)
        NSApp.activate()
        await pause(300)
        let row = tracks.visibleRows.lowerBound + 4
        let rect = table.rect(ofRow: row)
        let probe = MenuProbe()
        let point = table.convert(NSPoint(x: 260, y: rect.midY), to: nil)
        guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: 1) else { return }
        // Posted for AppKit's own menu around a context menu, not the table's, and before the
        // table's is built: so any menu's, while this right-click's is the only one open (see
        // ListsPlaylistBench's realRightClick).
        let began = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil,
                                                           queue: nil) { [weak self] _ in
            MainActor.assumeIsolated {
                probe.opened = true
                let read = Timer(timeInterval: 0.4, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        probe.during = self?.snapshotRep("S10_context_menu_open.png")
                        probe.titles = table.menu?.items.map { $0.isSeparatorItem ? "—" : $0.title } ?? []
                        probe.clickedRow = table.clickedRow
                        table.menu?.cancelTracking()
                    }
                }
                RunLoop.main.add(read, forMode: .common)
            }
        }
        let giveUp = Timer(timeInterval: 2.5, repeats: false) { _ in
            MainActor.assumeIsolated { table.menu?.cancelTracking() }
        }
        RunLoop.main.add(giveUp, forMode: .common)
        table.rightMouseDown(with: event)     // runs the menu's tracking loop until cancelled
        giveUp.invalidate()
        NotificationCenter.default.removeObserver(began)
        await pause(300)
        let after = snapshotRep("S11_context_menu_closed.png")
        var differing = 0, sampled = 0
        if let during = probe.during, let after {
            let area = rect.insetBy(dx: 0, dy: -4)
            var y = area.minY + 0.25
            while y < area.maxY {
                var x = rect.minX + 0.25
                while x < min(rect.maxX, 700) {
                    sampled += 1
                    if let a = pixel(during, in: table, at: NSPoint(x: x, y: y)), let b = pixel(after, in: table, at: NSPoint(x: x, y: y)),
                       !close(a, b, 6) { differing += 1 }
                    x += 1
                }
                y += 0.5
            }
        }
        check("a right-click selects the row and opens Play / Get Info / Download / Add to Playlist / Show in Finder "
              + "without a modern outline",
              probe.opened && probe.titles == ["Play", "Get Info", "—", "Download", "Add to Playlist", "—", "Show in Finder"]
              && table.selectedRow == row && differing == 0,
              (probe.opened ? "menu \(probe.titles)" : "the menu never opened (app active \(NSApp.isActive))")
              + ", clicked row \(probe.clickedRow) (want \(row)), selected \(table.selectedRow); "
              + "\(differing) of \(sampled) pixels around the row differ with the menu open")
    }

    /// Turning Year on from the header menu brings it on screen; it joins past Date Added.
    private func shownColumnScrollsIntoView() async {
        guard let tracks, let header = tracks.tableView.headerView, let menu = header.menu,
              let delegate = menu.delegate else { return }
        let table = tracks.tableView
        delegate.menuNeedsUpdate?(menu)
        guard let year = menu.items.first(where: { $0.title == "Year" }), let action = year.action else { return }
        NSApp.sendAction(action, to: year.target, from: year)
        await pause(100)
        let col = table.column(withIdentifier: TrackColumn.year.identifier)
        let visible = tracks.listScrollView.unobscuredDocumentRect
        let rect = table.rect(ofColumn: col)
        let probeRow = tracks.visibleRows.lowerBound + 2
        func rowState() -> String {
            let rv = table.rowView(atRow: probeRow, makeIfNecessary: false)
            let cell = table.view(atColumn: col, row: probeRow, makeIfNecessary: false) as? TrackCellView
            return "rowView width \(Int(rv?.frame.width ?? -1)) of table \(Int(table.frame.width)), year cell \(cell == nil ? "missing" : "\"\(cell?.displayedText ?? "")\"")"
        }
        let early = rowState()
        let t0 = ContinuousClock.now
        while (table.rowView(atRow: probeRow, makeIfNecessary: false)?.frame.width ?? 0) < table.frame.width,
              ContinuousClock.now - t0 < .seconds(2) {
            await pause(10)
        }
        info("year column probe: after 0.1 s \(early); row views caught up \(String(format: "%.0f", Self.ms(ContinuousClock.now - t0) + 100)) ms after the toggle: \(rowState())")
        snapshot("S12_year_column_shown.png")
        check("a column turned on from the header menu scrolls into view",
              col >= 0 && !table.tableColumns[col].isHidden && visible.minX <= rect.minX && rect.maxX <= visible.maxX + 1,
              "Year at x \(Int(rect.minX))…\(Int(rect.maxX)), visible x \(Int(visible.minX))…\(Int(visible.maxX))")
        delegate.menuNeedsUpdate?(menu)
        if let again = menu.items.first(where: { $0.title == "Year" }), let off = again.action {
            NSApp.sendAction(off, to: again.target, from: again)
        }
        table.scroll(NSPoint(x: 0, y: table.visibleRect.minY))
    }

    /// Two playlist reloads whose answers come back out of order: the newer one wins.
    private func sourceReloadRace(snap: ListsHarnessLibrary.Snapshot) async {
        guard let source, let lib, snap.playlists.count >= 2 else { return }
        let older = snap.playlists
        let newer = Array(snap.playlists.dropLast())
        await lib.setPlaylistScript([(latency: .milliseconds(500), list: older), (latency: .zero, list: newer)])
        async let first: Void = source.reload()
        try? await Task.sleep(for: .milliseconds(30))
        async let second: Void = source.reload()
        _ = await (first, second)
        await pause(100)
        check("an older playlist read never replaces a newer one", source.playlistCount == newer.count,
              "\(source.playlistCount) playlists shown; newer read had \(newer.count), older \(older.count)")
        await lib.setPlaylistScript([])
        await source.reload()
    }

    /// Facts about the real data that explain what the snapshots show.
    private func dataFacts(snap: ListsHarnessLibrary.Snapshot) async {
        let undated = snap.tracks.filter { $0.dateAdded == nil }.count
        var lines: [String] = []
        for list in snap.playlists where list.trackCount > 0 {
            let ids = (try? await lib?.base.ids(for: TrackQuery(scope: .playlist(list.id)))) ?? []
            let rows = (try? await lib?.base.tracks(ids: ids)) ?? []
            let missingDate = rows.filter { $0.dateAdded == nil }.count
            if missingDate > 0 { lines.append("\(list.name): \(missingDate)/\(rows.count) undated") }
        }
        info("data: \(undated) songs have no Date Added; playlists with undated songs: \(lines)")
    }

    // MARK: Pixels

    private func snapshotRep(_ name: String) -> NSBitmapImageRep? {
        snapshot(name)
        guard let data = try? Data(contentsOf: outDir.appendingPathComponent(name)) else { return nil }
        return NSBitmapImageRep(data: data)
    }

    /// Raw sample bytes (the window renders in sRGB); `colorAt` would reinterpret them.
    private func pixel(_ rep: NSBitmapImageRep, in view: NSView, at p: NSPoint) -> NSColor? {
        guard let content = window?.contentView else { return nil }
        let c = content.convert(p, from: view)
        let scale = CGFloat(rep.pixelsWide) / content.bounds.width
        let y = content.isFlipped ? c.y : content.bounds.height - c.y
        let px = Int((c.x * scale).rounded(.down)), py = Int((y * scale).rounded(.down))
        guard px >= 0, py >= 0, px < rep.pixelsWide, py < rep.pixelsHigh else { return nil }
        var raw = [Int](repeating: 0, count: max(rep.samplesPerPixel, 4))
        rep.getPixel(&raw, atX: px, y: py)
        let maxValue = CGFloat((1 << rep.bitsPerSample) - 1)
        return NSColor(srgbRed: CGFloat(raw[0]) / maxValue, green: CGFloat(raw[1]) / maxValue,
                       blue: CGFloat(raw[2]) / maxValue, alpha: 1)
    }

    private func close(_ a: NSColor?, _ b: NSColor, _ tolerance: CGFloat = 3) -> Bool {
        guard let a, let b = ListsHarness.srgb(b) else { return false }
        return abs(a.redComponent - b.redComponent) * 255 <= tolerance
            && abs(a.greenComponent - b.greenComponent) * 255 <= tolerance
            && abs(a.blueComponent - b.blueComponent) * 255 <= tolerance
    }

    private func hex(_ c: NSColor?) -> String {
        guard let c else { return "nil" }
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }

    // MARK: Synthetic mouse

    private func mouse(_ type: NSEvent.EventType, at p: NSPoint, in window: NSWindow, clickCount: Int = 1) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount,
                           pressure: type == .leftMouseUp ? 0 : 1)
    }

    private func click(_ view: NSView, at local: NSPoint, in window: NSWindow) {
        let p = view.convert(local, to: nil)
        guard let down = mouse(.leftMouseDown, at: p, in: window),
              let up = mouse(.leftMouseUp, at: p, in: window) else { return }
        NSApp.postEvent(up, atStart: false)
        view.mouseDown(with: down)
    }
}

/// Whether the right-click's menu opened, and what the bench saw while it was open.
@MainActor
private final class MenuProbe {
    var opened = false
    var during: NSBitmapImageRep?
    var titles: [String] = []
    var clickedRow = -2
}

private final class StressBackdrop: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { Theme.metal.draw(in: bounds, angle: 0) }
}

/// Claims key status so tables draw their focused selection when the harness runs in the background.
private final class StressWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}
