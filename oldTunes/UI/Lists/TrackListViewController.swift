import AppKit

/// The track list — the heart of the app — with the optional Genre | Artist | Album browser
/// above it (RESEARCH.md §7.4, §8.2, §8.4).
///
/// The table is backed by an id array (`order`) fetched whole for each query; row details come
/// from `library.tracks(ids:)` only for the visible rows plus a margin, cached in a small LRU, so
/// drawing a screenful never touches all 15,900 rows. Everything proportional to the library
/// (the id→row map, selection restore, change detection) is computed off the main thread.
///
/// Songs drag from here onto the source list's playlists (SongDrag), and the right-click menu
/// can download them or add them to a playlist; the list only asks, through its closures.
@MainActor
final class TrackListViewController: NSViewController {

    // MARK: Public API

    var onActivate: ((_ id: Track.ID, _ order: [Track.ID]) -> Void)?
    var onSelectionChange: (([Track.ID]) -> Void)?
    var onOrderChange: (([Track.ID]) -> Void)?
    var onGetInfo: (([Track.ID]) -> Void)?
    /// A click on a song's checkbox: `ids` is that song, or with ⌘ every song in the current list,
    /// and `checked` is the state they should all take (the clicked box's new state). Integration
    /// writes it through `LibraryWriting.setChecked`, whose `.libraryDidChange` makes the list
    /// reload and repaint the boxes from the fresh Track rows. The clicked rows show the new state
    /// at once; if no reload follows within two seconds (the write failed) they are re-read from
    /// the library and show whatever it holds.
    var onToggleChecked: ((_ ids: [Track.ID], _ checked: Bool) -> Void)?
    /// Right-click ▸ Download: the selection, in row order. The menu sees only the rows it has
    /// loaded, so the caller keeps just the cloud-only Music songs, and there may be none.
    var onDownload: (([Track.ID]) -> Void)?
    /// Right-click ▸ Add to Playlist ▸ a playlist: the selection, in row order, and its id.
    var onAddToPlaylist: ((_ ids: [Track.ID], _ playlist: Int64) -> Void)?
    /// Right-click ▸ Add to Playlist ▸ New Playlist: a new playlist with the selection, in row order.
    var onNewPlaylistFromSelection: (([Track.ID]) -> Void)?
    var onRemoveFromPlaylist: ((_ ids: [Track.ID], _ playlist: Int64) -> Void)?
    var playlistInfo: ((Int64) -> PlaylistInfo?)?
    /// The playlists Add to Playlist ▸ offers: the source list's tree (`playlistTree`). Read each
    /// time the menu opens, which can't wait for the library.
    var playlistMenu: (() -> [PlaylistMenuEntry])?

    /// Setting it reloads. Search-only changes are debounced 140 ms; any newer query cancels the
    /// one in flight, and a result that lands late is dropped, never shown.
    ///
    /// Changing only the scope also picks the sort: a playlist opens in its own order
    /// (`.playlistOrder`), as iTunes 4.9 did, and leaving one that was in its own order goes back
    /// to the last sort picked from a column header (Artist until one is). That sort is saved, so
    /// the list also opens with it after a relaunch. To give a scope a sort of its own instead,
    /// use `setScope(_:sort:)`. `.playlistOrder` is never kept outside a playlist.
    var query = TrackQuery() {
        didSet {
            // Assigned here, in the observer itself, so it does not run didSet again. Assigning it
            // from a helper method would, and would start a second load for the same change.
            let sort = normalizedSort(from: oldValue)
            if sort != query.sort { query.sort = sort }
            queryDidChange(from: oldValue)
        }
    }

    /// Switches to `scope` with `sort` in one load. Nil picks the sort the way a plain scope change
    /// does (see `query`). For integration that remembers a sort per source.
    func setScope(_ scope: LibraryScope, sort: TrackSort?) {
        var q = query
        q.scope = scope
        if let sort { q.sort = sort }
        sortIsExplicit = sort != nil
        query = q
        sortIsExplicit = false
    }

    private(set) var order: [Track.ID] = []
    private var displayedScope: LibraryScope?

    var canRemoveSelection: Bool {
        removablePlaylist != nil && !table.selectedRowIndexes.isEmpty && onRemoveFromPlaylist != nil
    }

    private var removablePlaylist: Int64? {
        guard displayedScope == query.scope, case .playlist(let id) = query.scope,
              playlistInfo?(id)?.kind == .regular else { return nil }
        return id
    }

    @objc private func clearFromMenu(_ sender: Any?) {
        guard canRemoveSelection, let playlist = removablePlaylist else { NSSound.beep(); return }
        onRemoveFromPlaylist?(selectedIDs, playlist)
    }

    var selectedIDs: [Track.ID] {
        table.selectedRowIndexes.compactMap { $0 < order.count ? order[$0] : nil }
    }

    /// Whether the selection may hold a song Music can download, a cloud-only Music song; Download
    /// is on when it may. Only loaded rows can say no, and a selection over 50 isn't looked
    /// through, so this can be true for a selection with none; the caller then finds that out.
    var selectionMayHaveCloudSongs: Bool { selectionMayHave { $0.isCloudOnly && $0.origin == .musicLibrary } }
    /// Whether the selection may hold a song that can go in a Music playlist, one that isn't only
    /// in oldTunes; New Playlist from Selection is on when it may. The same "may" as above.
    var selectionMayHaveMusicSongs: Bool { selectionMayHave { $0.origin == .musicLibrary && $0.persistentID != nil } }

    /// The Genre | Artist | Album browser. Hiding it clears its filters, as iTunes did.
    var isBrowserVisible = false {
        didSet {
            guard isBrowserVisible != oldValue else { return }
            if isBrowserVisible {
                refreshBrowser(from: .genre)
            } else if query.genre != nil || query.artist != nil || query.album != nil {
                var q = query
                q.genre = nil; q.artist = nil; q.album = nil
                query = q
            }
            UserDefaults.standard.set(isBrowserVisible, forKey: Self.browserVisibleKey)
            rootView.needsLayout = true
        }
    }

    init(library: any LibraryReading) {
        self.library = library
        // Set in init, so neither didSet runs: nothing is re-saved, and the first load waits for
        // viewDidLoad as before.
        let sort = Self.loadSavedSort()
        savedSort = sort
        query = TrackQuery(sort: sort)
        super.init(nibName: nil, bundle: nil)
        configureTable()
        browserFraction = Self.savedBrowserFraction()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Speaker glyph in the indicator column: filled while playing, outlined while paused.
    func setNowPlaying(_ id: Track.ID?, isPlaying: Bool) {
        let old = nowPlayingID
        nowPlayingID = id
        nowPlayingIsPlaying = isPlaying
        let indicator = table.column(withIdentifier: TrackColumn.indicator.identifier)
        let rows = IndexSet([old, id].compactMap { $0 }.compactMap { indexOfID[$0] })
        guard indicator >= 0, !rows.isEmpty else { return }
        table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: indicator))
    }

    /// The blue cloud on the songs Music has been asked to download (RESEARCH.md §6.9), until
    /// the caller sees each one's file and drops it from the set. Kept here, not on the cached
    /// rows, which every reload replaces. Redraws only the Name cells of the songs that changed.
    func setDownloading(_ ids: Set<Track.ID>) {
        let changed = downloadingIDs.symmetricDifference(ids)
        downloadingIDs = ids
        let name = table.column(withIdentifier: TrackColumn.name.identifier)
        let rows = IndexSet(changed.compactMap { indexOfID[$0] })
        guard name >= 0, !rows.isEmpty else { return }
        table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: name))
    }

    /// After `.libraryDidChange`: refetch everything, keeping the selection and scroll position.
    ///
    /// The rows on screen stay drawn from their old copies until the fresh ones land (review
    /// findings 8 and 13: emptying the cache first drew the whole list blank for a frame or more
    /// on every library change). Each old copy still counts as missing, so every row is refetched.
    func reload() async {
        // A fetch still out belongs to the old generation and will be dropped when it lands, so
        // its ids must not count as in flight, or the new fetch would skip them and leave the
        // screen blank.
        cacheGeneration += 1
        if var kept = staleCache {
            // A second reload before the first one's rows landed: keep both, the newer on top.
            kept.insert(cache.tracks)
            staleCache = kept
        } else {
            staleCache = cache
        }
        cache.removeAll()
        unavailable.removeAll()
        inFlight.removeAll()
        startLoad(debounce: false, scroll: .keepTopRow, refreshBrowserFrom: .genre, inPlace: true)
        await waitForLoad()
    }

    /// Select one track and scroll it to the middle of the list.
    func reveal(_ id: Track.ID) {
        guard let row = indexOfID[id] else {
            Log.info("tracklist: reveal \(id) is not in the current list")
            return
        }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        scrollToCenter(row: row)
    }

    // MARK: Harness and diagnostics (module-internal)

    /// The table, for tests that drive scrolling and read cells.
    var tableView: NSTableView { table }
    /// Rows actually on screen (not under the header or scrollers).
    var visibleRows: Range<Int> { visibleRowRange(margin: 0) }
    var listScrollView: RetroScrollView { scrollView }
    var columnBrowser: ColumnBrowserView { browser }
    /// Milliseconds from the start of the last (post-debounce) load to reloadData and selection done.
    private(set) var lastLoadMillis: Double = 0
    /// The main-thread part of the last load: reloadData, selection restore, scroll.
    private(set) var lastApplyMillis: Double = 0
    /// The library's part of the last load: `ids(for:)`.
    private(set) var lastIDsMillis: Double = 0
    private(set) var lastLoadBreakdown = ""
    /// Cells built from scratch vs. calls to viewFor; reuse keeps the first near a screenful.
    private(set) var cellsCreated = 0
    private(set) var cellRequests = 0
    private(set) var rowsFetched = 0
    private(set) var fetchBatches = 0
    var cachedRowCount: Int { cache.count }
    /// True while rows from before the last reload() are still being drawn.
    var isShowingKeptRows: Bool { staleCache != nil }
    var cacheEvictions: Int { cache.evictions }
    var cacheCapacity: Int { cache.capacity }

    /// Waits for the current (possibly debounced) load to apply or be cancelled.
    func waitForLoad() async {
        while let task = loadTask {
            await task.value
            if loadTask == task || loadTask == nil { break }
        }
    }

    /// Waits until no row fetch is in flight and nothing visible is still blank.
    func waitForRows(timeout: Duration = .seconds(5)) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            fetchVisibleRows()
            if activeFetches == 0 && !visibleRowsMissing() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: Dragging (module-internal, so the benches can look at the picture)

    /// What a drag of songs offers inside oldTunes: a copy, onto a playlist. The table has no
    /// getter for its masks outside a drag, so the playlists bench reads these.
    static let songDragInside: NSDragOperation = .copy
    /// And outside it, nothing: what a drag carries means nothing to Finder or another app
    /// (SongDrag).
    static let songDragOutside: NSDragOperation = []

    /// What a drag of `row` shows: the part of the row on screen, in table coordinates, and a
    /// picture of its cells as an unselected row draws them. Nil when the row is off screen or
    /// still loading. Not the row as it looks while dragged: it is selected, and the selection's
    /// white text would vanish over the white lists.
    func draggingImage(forRow row: Int) -> (frame: NSRect, image: NSImage)? {
        guard row >= 0, row < order.count else { return nil }
        let visible = table.rect(ofRow: row).intersection(scrollView.unobscuredDocumentRect)
        guard !visible.isEmpty, let track = shownRow(order[row]) else { return nil }
        let frame = NSIntegralRect(visible)
        let picture = SongDrag.picture(size: frame.size, scale: table.window?.backingScaleFactor ?? 2,
                                       appearance: table.effectiveAppearance) {
            guard let cg = NSGraphicsContext.current?.cgContext else { return }
            for (index, column) in table.tableColumns.enumerated() where !column.isHidden {
                guard let kind = TrackColumn(column) else { continue }
                let cellFrame = table.frameOfCell(atColumn: index, row: row)
                guard cellFrame.intersects(frame) else { continue }
                // A cell of its own, so the one on screen keeps its selected look.
                let cell = TrackCellView(column: kind)
                cell.frame = NSRect(origin: .zero, size: cellFrame.size)
                cell.configure(track: track, indicator: indicator(for: kind, of: track.id),
                               downloading: downloadingIDs.contains(track.id))
                cg.saveGState()
                cg.translateBy(x: cellFrame.minX - frame.minX, y: cellFrame.minY - frame.minY)
                cell.draw(cell.bounds)
                cg.restoreGState()
            }
        }
        return picture.map { (frame, $0) }
    }

    // MARK: - Private state

    private let library: any LibraryReading
    private let table = RetroTableView(rowHeight: Theme.Metrics.trackRowHeight)
    private let scrollView = RetroScrollView(lineHeight: Theme.Metrics.trackRowHeight, horizontal: true)
    private let browser = ColumnBrowserView()
    private let splitter = BrowserSplitterView()
    private lazy var rootView = ListContainerView { [weak self] in self?.layoutPanes() }

    private var indexOfID: [Track.ID: Int] = [:]
    private var cache = TrackRowCache(capacity: 3_000)
    /// Ids the library did not return; never re-requested until the next reload.
    private var unavailable = Set<Track.ID>()
    private var inFlight = Set<Track.ID>()
    private var activeFetches = 0
    private var fetchScheduled = false
    private var cacheGeneration = 0
    /// The rows cached before the last reload(), drawn until their fresh copies land.
    private var staleCache: TrackRowCache?
    /// Set while `setScope(_:sort:)` assigns a sort the caller chose.
    private var sortIsExplicit = false
    /// The sort last picked from a column header (Artist until one is), saved on every change so
    /// a relaunch opens with it. Leaving a playlist in its own order goes back to it. Never
    /// `.playlistOrder`.
    private var savedSort: TrackSort {
        didSet {
            let value: [String: Any] = ["field": savedSort.field.rawValue, "ascending": savedSort.ascending]
            UserDefaults.standard.set(value, forKey: Self.sortDefaultsKey)
        }
    }
    /// Rows fetched above and below the visible range, so a scroll usually lands on cached rows.
    private let fetchMargin = 60

    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var isRestoringSelection = false
    private var nowPlayingID: Track.ID?
    private var nowPlayingIsPlaying = false
    /// Songs Music has been asked to download, drawn with the blue cloud (`setDownloading`).
    private var downloadingIDs = Set<Track.ID>()

    private var browserGenerations: [BrowserField: Int] = [:]
    /// The leftmost browser pane a load still owes a refresh. Accumulated across loads, because
    /// a newer load cancels an older one before it runs: a search still debouncing when a genre
    /// is picked must still refresh the Genre pane.
    private var pendingBrowserRefresh: BrowserField?
    private var browserFraction = Theme.Metrics.browserDefaultFraction

    /// `savedSort`, as ["field": TrackSortField raw value, "ascending": Bool].
    static let sortDefaultsKey = "OldTunes.TrackList.sort"
    private static let browserVisibleKey = "OldTunes.TrackList.browserVisible"
    private static let browserFractionKey = "OldTunes.TrackList.browserFraction"
    private static let rowViewID = NSUserInterfaceItemIdentifier("trackRow")

    private enum ScrollPolicy { case top, keepTopRow, revealSelection }

    // MARK: - View

    /// The chrome frame around the track pane is the outer border; the splitter draws the two
    /// rules between the browser and the list.
    override func loadView() {
        rootView.addSubview(browser)
        rootView.addSubview(splitter)
        rootView.addSubview(scrollView)
        splitter.onDrag = { [weak self] dy in self?.dragSplitter(by: dy) }
        browser.onSelect = { [weak self] field, value in self?.browserPicked(field, value) }
        view = rootView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if loadTask == nil && order.isEmpty {
            startLoad(debounce: false, scroll: .top, refreshBrowserFrom: nil)
        }
    }

    private func layoutPanes() {
        let b = rootView.bounds
        browser.isHidden = !isBrowserVisible
        splitter.isHidden = !isBrowserVisible
        guard isBrowserVisible else {
            scrollView.frame = b
            return
        }
        let splitH = Theme.Metrics.browserSplitterHeight
        let minPane: CGFloat = 60
        let maxBrowser = max(b.height - splitH - minPane, minPane)
        let h = min(max((b.height * browserFraction).rounded(), minPane), maxBrowser)
        browser.frame = NSRect(x: 0, y: 0, width: b.width, height: h)
        splitter.frame = NSRect(x: 0, y: h, width: b.width, height: splitH)
        scrollView.frame = NSRect(x: 0, y: h + splitH, width: b.width, height: max(b.height - h - splitH, 0))
    }

    private func dragSplitter(by dy: CGFloat) {
        let total = rootView.bounds.height
        guard total > 0 else { return }
        browserFraction = min(max((browser.frame.height + dy) / total, 0.1), 0.85)
        UserDefaults.standard.set(Double(browserFraction), forKey: Self.browserFractionKey)
        rootView.needsLayout = true
    }

    private static func savedBrowserFraction() -> CGFloat {
        let saved = UserDefaults.standard.double(forKey: browserFractionKey)
        return saved > 0.05 && saved < 0.95 ? CGFloat(saved) : Theme.Metrics.browserDefaultFraction
    }

    /// The sort the last header click saved, or Artist when none was saved or it can't be read.
    private static func loadSavedSort() -> TrackSort {
        let saved = UserDefaults.standard.dictionary(forKey: sortDefaultsKey)
        guard let raw = saved?["field"] as? String, let field = TrackSortField(rawValue: raw), field != .playlistOrder,
              let ascending = saved?["ascending"] as? Bool else { return .default }
        return TrackSort(field: field, ascending: ascending)
    }

    /// Restores whether the browser was showing last time. Call once after setup.
    func restoreBrowserVisibility() {
        isBrowserVisible = UserDefaults.standard.bool(forKey: Self.browserVisibleKey)
    }

    // MARK: - Table setup

    private func configureTable() {
        let header = TrackHeaderView(frame: NSRect(x: 0, y: 0, width: 400, height: TrackHeaderView.height))
        table.headerView = header
        table.cornerView = HeaderCornerView(frame: NSRect(x: 0, y: 0, width: Theme.Metrics.scrollerWidth,
                                                          height: TrackHeaderView.height))
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.stripesBeyondLastRow = true
        table.columnLinesBeyondLastRow = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked(_:))
        table.onReturn = { [weak self] in self?.activateSelection() }
        table.onCommandI = { [weak self] in self?.getInfo(nil) }
        table.onDelete = { [weak self] in self?.clearFromMenu(nil) }
        table.canDelete = { [weak self] in self?.canRemoveSelection ?? false }
        table.interceptMouseDown = { [weak self] event in self?.handleCheckboxClick(event) ?? false }
        // Songs drag onto the source list's playlists, and only inside oldTunes. A drag starts
        // sideways, toward the source list; a vertical drag still extends the selection, as it
        // always has.
        table.setDraggingSourceOperationMask(Self.songDragInside, forLocal: true)
        table.setDraggingSourceOperationMask(Self.songDragOutside, forLocal: false)
        table.verticalMotionCanBeginDrag = false

        for entry in TrackColumnLayout.load().entries {
            guard let kind = TrackColumn(rawValue: entry.id) else { continue }
            table.addTableColumn(makeColumn(kind, width: CGFloat(entry.width), hidden: entry.hidden))
        }
        updateSortIndicators()

        let columnsMenu = NSMenu(title: "Columns")
        columnsMenu.delegate = self
        header.menu = columnsMenu

        let rowMenu = NSMenu(title: "Track")
        rowMenu.delegate = self
        rowMenu.autoenablesItems = false
        table.menu = rowMenu

        scrollView.documentView = table
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged(_:)),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
    }

    private func makeColumn(_ kind: TrackColumn, width: CGFloat, hidden: Bool) -> NSTableColumn {
        let column = NSTableColumn(identifier: kind.identifier)
        let cell = TrackHeaderCell(textCell: kind.title)
        cell.alignment = kind.alignment
        column.headerCell = cell
        column.minWidth = kind.minWidth
        if kind == .indicator {
            column.width = kind.defaultWidth
            column.maxWidth = kind.defaultWidth
            column.resizingMask = []
        } else {
            column.width = max(width, kind.minWidth)
            column.maxWidth = 2_000
            column.resizingMask = .userResizingMask
        }
        column.isHidden = kind.isHideable ? hidden : false
        return column
    }

    private func updateSortIndicators() {
        for column in table.tableColumns {
            guard let kind = TrackColumn(column), let cell = column.headerCell as? TrackHeaderCell else { continue }
            cell.sortAscending = kind.sortField == query.sort.field ? query.sort.ascending : nil
        }
        table.headerView?.needsDisplay = true
    }

    private func saveColumnLayout() {
        TrackColumnLayout(table: table).save()
    }

    @objc private func clipBoundsChanged(_ note: Notification) {
        requestVisibleRows()
    }

    // MARK: - Loading the order

    /// The sort `query` should have after changing from `old`. `query`'s didSet applies it before
    /// the load, so one assignment makes one load.
    private func normalizedSort(from old: TrackQuery) -> TrackSort {
        let inPlaylist: Bool
        if case .playlist = query.scope { inPlaylist = true } else { inPlaylist = false }
        if query.scope != old.scope && query.sort == old.sort && !sortIsExplicit {
            if inPlaylist { return TrackSort(field: .playlistOrder, ascending: true) }
            if query.sort.field == .playlistOrder { return savedSort }
        }
        if !inPlaylist && query.sort.field == .playlistOrder { return savedSort }
        return query.sort
    }

    private func queryDidChange(from old: TrackQuery) {
        guard query != old else { return }
        if query.sort != old.sort { updateSortIndicators() }

        var searchOnly = old
        searchOnly.search = query.search
        let debounce = old.search != query.search && searchOnly == query

        let browserFrom: BrowserField?
        if old.scope != query.scope || old.search != query.search {
            browserFrom = .genre
        } else if old.genre != query.genre {
            browserFrom = .artist
        } else if old.artist != query.artist {
            browserFrom = .album
        } else {
            browserFrom = nil
        }
        let policy: ScrollPolicy = (old.scope == query.scope && old.search == query.search
            && old.genre == query.genre && old.artist == query.artist && old.album == query.album)
            ? .revealSelection : .top
        startLoad(debounce: debounce, scroll: policy, refreshBrowserFrom: browserFrom)
    }

    /// `inPlace`: the load comes from reload() (a library change), so apply it without taking the
    /// row views down; see `apply`.
    private func startLoad(debounce: Bool, scroll: ScrollPolicy, refreshBrowserFrom: BrowserField?, inPlace: Bool = false) {
        if let field = refreshBrowserFrom {
            pendingBrowserRefresh = pendingBrowserRefresh.map { Self.leftmost($0, field) } ?? field
        }
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        let library = self.library
        loadTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(for: .milliseconds(140))
                guard !Task.isCancelled else { return }
            }
            guard let self else { return }
            if let field = self.pendingBrowserRefresh {
                self.pendingBrowserRefresh = nil
                self.refreshBrowser(from: field)
            }
            let query = self.query
            let started = ContinuousClock.now
            let ids: [Track.ID]
            do {
                ids = try await library.ids(for: query)
            } catch is CancellationError {
                return
            } catch {
                // A newer load cancelled this one. SQLite reports that as an interrupt
                // (SQLITE_INTERRUPT), not as CancellationError, and it is not a failure.
                if Task.isCancelled || generation != self.loadGeneration { return }
                Log.error("tracklist: ids(for:) failed: \(error)")
                return
            }
            let fetched = ContinuousClock.now
            guard !Task.isCancelled, generation == self.loadGeneration else { return }

            let selected = self.selectedIDs
            let anchor = self.topVisibleAnchor()
            let oldOrder = self.order
            let prepared = await Task.detached(priority: .userInitiated) {
                PreparedOrder(ids: ids, oldOrder: oldOrder, selected: selected, anchorID: anchor?.id)
            }.value
            let preparedAt = ContinuousClock.now
            guard !Task.isCancelled, generation == self.loadGeneration else { return }

            self.apply(prepared, selectedBefore: selected, scroll: scroll, anchorOffset: anchor?.offset, inPlace: inPlace)
            self.displayedScope = query.scope
            let done = ContinuousClock.now
            self.lastLoadMillis = Self.ms(done - started)
            self.lastApplyMillis = Self.ms(done - preparedAt)
            self.lastIDsMillis = Self.ms(fetched - started)
            self.lastLoadBreakdown = "ids=\(String(format: "%.2f", Self.ms(fetched - started)))ms "
                + "prepare=\(String(format: "%.2f", Self.ms(preparedAt - fetched)))ms "
                + "apply=\(String(format: "%.2f", Self.ms(done - preparedAt)))ms rows=\(ids.count)"
        }
    }

    private static func leftmost(_ a: BrowserField, _ b: BrowserField) -> BrowserField {
        let fields = BrowserField.allCases
        return (fields.firstIndex(of: a) ?? 0) <= (fields.firstIndex(of: b) ?? 0) ? a : b
    }

    private static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    private func apply(_ prepared: PreparedOrder, selectedBefore: [Track.ID], scroll: ScrollPolicy, anchorOffset: CGFloat?,
                       inPlace: Bool = false) {
        // A click made while the order was being prepared off the main thread wins over the
        // selection captured before it. Both lists are in the old order's row order.
        let selectedNow = selectedIDs
        var selection = selectedNow == selectedBefore
            ? prepared.selection
            : IndexSet(selectedNow.compactMap { prepared.index[$0] })
        // After Clear, keep the next row selected (or the last row when clearing the end).
        if inPlace, displayedScope == query.scope, case .playlist = query.scope,
           selection.isEmpty, !selectedNow.isEmpty, !prepared.ids.isEmpty,
           let row = table.selectedRowIndexes.first {
            selection.insert(min(row, prepared.ids.count - 1))
        }
        let oldCount = order.count
        order = prepared.ids
        indexOfID = prepared.index
        isRestoringSelection = true
        if inPlace {
            // A library change keeps every row view and refills its cells where they stand, from
            // the kept rows until the fresh ones land. reloadData() takes all row views down until
            // the table's next layout, and a frame committed in between shows an empty list
            // (findings 8 and 13). When nothing moved there is nothing to refill yet: the refetch
            // redraws each row as it lands.
            if prepared.ids.count != oldCount { table.noteNumberOfRowsChanged() }
            if prepared.changed { redrawAllPreparedRows() }
        } else {
            table.reloadData()
        }
        table.selectRowIndexes(selection, byExtendingSelection: false)
        isRestoringSelection = false

        switch scroll {
        case .top:
            scrollTo(y: 0)
        case .keepTopRow:
            if let row = prepared.anchorRow, let offset = anchorOffset {
                scrollTo(y: table.rect(ofRow: row).minY - offset)
            }
        case .revealSelection:
            if let first = selection.first { scrollToCenter(row: first) } else { scrollTo(y: 0) }
        }

        if prepared.changed { onOrderChange?(order) }
        // A re-sort moves the same songs to new rows, which is not a change. Ids are unique, so
        // the same songs are still selected exactly when every one of them was found again.
        if table.selectedRowIndexes.count != selectedNow.count { onSelectionChange?(selectedIDs) }
        requestVisibleRows()
    }

    /// The first row on screen (below the header) and how far its top sits from the visible top.
    private func topVisibleAnchor() -> (id: Track.ID, offset: CGFloat)? {
        let visible = scrollView.unobscuredDocumentRect
        let row = table.row(at: NSPoint(x: visible.minX, y: visible.minY))
        guard row >= 0, row < order.count else { return nil }
        return (order[row], table.rect(ofRow: row).minY - visible.minY)
    }

    /// Scrolls so document y `y` sits at the top of the unobscured area, just under the header.
    private func scrollTo(y: CGFloat) {
        let clip = scrollView.contentView
        let origin = NSPoint(x: clip.bounds.minX, y: y - clip.contentInsets.top)
        let target = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size))
        clip.scroll(to: target.origin)
        scrollView.reflectScrolledClipView(clip)
    }

    private func scrollToCenter(row: Int) {
        let rect = table.rect(ofRow: row)
        let visible = scrollView.unobscuredDocumentRect
        if visible.contains(rect) { return }
        scrollTo(y: rect.midY - visible.height / 2)
    }

    // MARK: - Fetching rows for the visible range

    private func requestVisibleRows() {
        guard !fetchScheduled else { return }
        fetchScheduled = true
        Task { [weak self] in
            guard let self else { return }
            self.fetchScheduled = false
            self.fetchVisibleRows()
        }
    }

    private func visibleRowRange(margin: Int) -> Range<Int> {
        guard !order.isEmpty else { return 0..<0 }
        let visible = table.rows(in: scrollView.unobscuredDocumentRect)
        let lo = max(0, visible.location - margin)
        let hi = min(order.count, visible.location + max(visible.length, 1) + margin)
        return lo < hi ? lo..<hi : 0..<0
    }

    private func visibleRowsMissing() -> Bool {
        visibleRowRange(margin: 0).contains { row in
            let id = order[row]
            return !cache.contains(id) && !unavailable.contains(id)
        }
    }

    private func fetchVisibleRows() {
        var missing: [Track.ID] = []
        for row in visibleRowRange(margin: fetchMargin) {
            let id = order[row]
            if !cache.contains(id) && !inFlight.contains(id) && !unavailable.contains(id) { missing.append(id) }
        }
        guard !missing.isEmpty else { return }
        inFlight.formUnion(missing)
        activeFetches += 1
        fetchBatches += 1
        let generation = cacheGeneration
        let library = self.library
        Task { [weak self] in
            let rows: [Track]
            do {
                rows = try await library.tracks(ids: missing)
            } catch {
                Log.error("tracklist: tracks(ids:) failed for \(missing.count) ids: \(error)")
                rows = []
            }
            guard let self else { return }
            self.activeFetches -= 1
            // reload() cleared inFlight and refetched these under the new generation.
            guard generation == self.cacheGeneration else { return }
            self.inFlight.subtract(missing)
            self.cache.insert(rows)
            self.rowsFetched += rows.count
            let returned = Set(rows.map(\.id))
            if returned.count < missing.count {
                self.unavailable.formUnion(missing.filter { !returned.contains($0) })
            }
            var redraw = Set(missing)
            if self.staleCache != nil && !self.visibleRowsMissing() {
                // Every visible row has its fresh copy. Rows still drawn from an old one (outside
                // this fetch, or gone from the library) redraw from what is cached now.
                self.staleCache = nil
                redraw.formUnion(self.preparedRowIDs().filter { !self.cache.contains($0) })
            }
            self.redrawPreparedRows(with: redraw)
        }
    }

    /// The row as drawn: the fresh copy, or the one kept from before a reload. Not a cache use.
    private func shownRow(_ id: Track.ID) -> Track? {
        cache.peek(id) ?? staleCache?.peek(id)
    }

    /// Whether any selected row may pass `test`. A row not loaded yet may. So may a selection of
    /// over 50: like Show in Finder, a menu looks at 50 rows at most.
    private func selectionMayHave(_ test: (Track) -> Bool) -> Bool {
        let rows = table.selectedRowIndexes
        if rows.count > 50 { return true }
        return rows.contains { $0 < order.count && (shownRow(order[$0]).map(test) ?? true) }
    }

    /// The ids of every row that has a view.
    private func preparedRowIDs() -> [Track.ID] {
        let order = self.order
        var ids: [Track.ID] = []
        table.enumerateAvailableRowViews { _, row in
            if row >= 0, row < order.count { ids.append(order[row]) }
        }
        return ids
    }

    /// Reconfigures the cells of every row that has a view, keeping the row views themselves.
    private func redrawAllPreparedRows() {
        let count = order.count
        var rows = IndexSet()
        table.enumerateAvailableRowViews { _, row in
            if row >= 0, row < count { rows.insert(row) }
        }
        guard !rows.isEmpty else { return }
        table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
    }

    /// Reconfigures every row that has a view, not just the unobscured ones. Rows under the
    /// header and in the table's overdraw were configured blank too, and a later one-line
    /// scroll uncovers them without asking the delegate again.
    private func redrawPreparedRows(with ids: Set<Track.ID>) {
        let order = self.order
        var rows = IndexSet()
        table.enumerateAvailableRowViews { _, row in
            if row >= 0, row < order.count, ids.contains(order[row]) { rows.insert(row) }
        }
        guard !rows.isEmpty else { return }
        table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
    }

    // MARK: - Column browser

    private func refreshBrowser(from field: BrowserField) {
        guard isBrowserVisible else { return }
        for f in BrowserField.allCases.drop(while: { $0 != field }) { refreshPane(f) }
    }

    private func refreshPane(_ field: BrowserField) {
        let generation = (browserGenerations[field] ?? 0) + 1
        browserGenerations[field] = generation
        let query = self.query
        let library = self.library
        Task { [weak self] in
            let values: [String]
            do {
                values = try await library.browserValues(field, for: query)
            } catch {
                Log.error("tracklist: browserValues(\(field)) failed: \(error)")
                return
            }
            guard let self, self.browserGenerations[field] == generation, let pane = self.browser.pane(field) else { return }
            let wanted = self.query.browserValue(field)
            let selected = pane.setValues(values, selecting: wanted)
            if wanted != nil && selected == nil {
                // The filtered value is gone (scope or search changed): fall back to All.
                self.browserPicked(field, nil)
            }
        }
    }

    private func browserPicked(_ field: BrowserField, _ value: String?) {
        var q = query
        switch field {
        case .genre: q.genre = value; q.artist = nil; q.album = nil
        case .artist: q.artist = value; q.album = nil
        case .album: q.album = value
        }
        query = q
    }

    // MARK: - Actions

    @objc private func doubleClicked(_ sender: Any?) {
        activate(row: table.clickedRow)
    }

    private func activateSelection() {
        guard let row = table.selectedRowIndexes.first else { return }
        activate(row: row)
    }

    private func activate(row: Int) {
        guard row >= 0, row < order.count else { return }
        onActivate?(order[row], order)
    }

    /// ⌘I and the context menu; also reachable through the responder chain from a menu item.
    @objc func getInfo(_ sender: Any?) {
        let ids = selectedIDs
        guard !ids.isEmpty else { return }
        onGetInfo?(ids)
    }

    /// A click in a Name cell left of the title toggles that song's checkbox without touching the
    /// selection; with ⌘ it sets every song in the current list to the clicked box's new state.
    private func handleCheckboxClick(_ event: NSEvent) -> Bool {
        guard let onToggleChecked else { return false }
        let p = table.convert(event.locationInWindow, from: nil)
        let row = table.row(at: p), column = table.column(at: p)
        guard row >= 0, row < order.count, column >= 0, TrackColumn(table.tableColumns[column]) == .name else { return false }
        let cell = table.frameOfCell(atColumn: column, row: row)
        let local = NSPoint(x: p.x - cell.minX, y: p.y - cell.minY)
        guard TrackCellView.checkboxHitRect(cellHeight: cell.height).contains(local) else { return false }
        // A row still loading draws no box, so there is nothing to toggle yet.
        guard let track = shownRow(order[row]) else { return true }
        let checked = !track.isChecked
        let ids = event.modifierFlags.contains(.command) ? order : [track.id]
        showChecked(ids, checked)
        onToggleChecked(ids, checked)
        return true
    }

    /// Shows the clicked state at once, in the Track rows themselves, so a quick second click reads
    /// what the first one did. The `.libraryDidChange` reload then repaints every box from the
    /// library; if none comes (the write failed), the rows are re-read so they show the truth.
    private func showChecked(_ ids: [Track.ID], _ checked: Bool) {
        cache.modify(ids) { $0.isChecked = checked }
        staleCache?.modify(ids) { $0.isChecked = checked }
        let changed = Set(ids)
        redrawPreparedRows(with: changed)
        let generation = cacheGeneration
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.cacheGeneration == generation else { return }
            // Refetch them, drawing the current copies until the library's land.
            var kept = self.staleCache ?? TrackRowCache(capacity: self.cache.capacity)
            kept.insert(changed.compactMap { self.cache.peek($0) })
            self.staleCache = kept
            self.cache.remove(changed)
            self.fetchVisibleRows()
        }
    }

    @objc private func playFromMenu(_ sender: Any?) { activateSelection() }

    @objc private func showInFinder(_ sender: Any?) {
        let urls = selectedIDs.prefix(50).compactMap { shownRow($0)?.fileURL }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(Array(urls))
    }

    @objc private func downloadFromMenu(_ sender: Any?) {
        let ids = selectedIDs
        if !ids.isEmpty { onDownload?(ids) }
    }

    @objc private func addToPlaylistFromMenu(_ sender: NSMenuItem) {
        let ids = selectedIDs
        guard let playlist = (sender.representedObject as? NSNumber)?.int64Value, !ids.isEmpty else { return }
        onAddToPlaylist?(ids, playlist)
    }

    @objc private func newPlaylistFromMenu(_ sender: Any?) {
        let ids = selectedIDs
        if !ids.isEmpty { onNewPlaylistFromSelection?(ids) }
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let column = table.tableColumns.first(where: { $0.identifier.rawValue == id }),
              let kind = TrackColumn(column), kind.isHideable else { return }
        column.isHidden.toggle()
        saveColumnLayout()
        table.headerView?.needsDisplay = true
        // Year and Plays join at the right end, usually past the edge: show what was asked for.
        // tile() first, or the document is still its old width and there is nowhere to scroll.
        if !column.isHidden {
            table.tile()
            table.scrollColumnToVisible(table.column(withIdentifier: column.identifier))
        }
    }
}

// MARK: - NSTableViewDataSource, NSTableViewDelegate

extension TrackListViewController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { order.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = tableView.makeView(withIdentifier: Self.rowViewID, owner: self) as? TrackRowView ?? TrackRowView()
        view.identifier = Self.rowViewID
        view.displayRow = row
        return view
    }

    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        (rowView as? TrackRowView)?.displayRow = row
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let kind = TrackColumn(tableColumn), row >= 0, row < order.count else { return nil }
        cellRequests += 1
        let id = order[row]
        let fresh = cache.track(id)
        // Until a reload's fresh rows land, draw the old copy; it still counts as missing.
        let track = fresh ?? staleCache?.peek(id)
        if fresh == nil && !unavailable.contains(id) { requestVisibleRows() }
        let cell: TrackCellView
        if let reused = tableView.makeView(withIdentifier: kind.identifier, owner: self) as? TrackCellView {
            cell = reused
        } else {
            cell = TrackCellView(column: kind)
            cellsCreated += 1
        }
        cell.configure(track: track, indicator: indicator(for: kind, of: id),
                       downloading: kind == .name && downloadingIDs.contains(id))
        return cell
    }

    private func indicator(for kind: TrackColumn, of id: Track.ID) -> TrackCellView.Indicator {
        kind == .indicator && id == nowPlayingID ? (nowPlayingIsPlaying ? .playing : .paused) : .none
    }

    /// One item per dragged row, from its id alone, so rows not loaded yet drag too.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard row >= 0, row < order.count else { return nil }
        return SongDrag.item(for: order[row])
    }

    /// Pictures for the dragged rows on screen; the rest drag along unseen, so a ⌘A drag of the
    /// whole library doesn't draw a picture for every one of its rows. The items come in
    /// `rowIndexes` order (NSTableView.h).
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        let rows = Array(rowIndexes)
        session.enumerateDraggingItems(options: [], for: tableView, classes: [NSPasteboardItem.self],
                                       searchOptions: [:]) { item, index, _ in
            if index < rows.count, let picture = draggingImage(forRow: rows[index]) {
                item.setDraggingFrame(picture.frame, contents: picture.image)
            } else {
                item.setDraggingFrame(item.draggingFrame, contents: nil)
            }
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isRestoringSelection else { return }
        onSelectionChange?(selectedIDs)
    }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard let kind = TrackColumn(tableColumn) else { return }
        if kind == .indicator {
            // iTunes: the unlabeled leftmost header puts a playlist back in its own order. No
            // header shows a sort while it is (there is no column for it), and outside a
            // playlist there is no such order, so the click does nothing there.
            if case .playlist = query.scope { query.sort = TrackSort(field: .playlistOrder, ascending: true) }
            return
        }
        guard let field = kind.sortField else { return }
        var sort = query.sort
        if sort.field == field {
            sort.ascending.toggle()
        } else {
            sort = TrackSort(field: field, ascending: kind.defaultAscending)
        }
        savedSort = sort
        query.sort = sort
    }

    func tableView(_ tableView: NSTableView, shouldReorderColumn columnIndex: Int, toColumn newColumnIndex: Int) -> Bool {
        // The indicator column stays pinned at the left edge.
        columnIndex != 0 && newColumnIndex != 0
    }

    func tableViewColumnDidMove(_ notification: Notification) {
        saveColumnLayout()
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        saveColumnLayout()
        table.enumerateAvailableRowViews { rowView, _ in rowView.needsDisplay = true }
    }
}

// MARK: - Menus

extension TrackListViewController: NSMenuDelegate {
    /// The header's Columns menu, or the row menu: Play, Get Info, Download, Add to Playlist ▸ and
    /// Show in Finder, each acting on the selection (a right-click has already selected its row).
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === table.headerView?.menu {
            for column in table.tableColumns {
                guard let kind = TrackColumn(column), kind != .indicator else { continue }
                let item = NSMenuItem(title: kind.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = kind.rawValue
                item.state = column.isHidden ? .off : .on
                item.isEnabled = kind.isHideable
                menu.addItem(item)
            }
            return
        }
        let ids = selectedIDs
        let play = NSMenuItem(title: "Play", action: #selector(playFromMenu(_:)), keyEquivalent: "")
        play.target = self
        play.isEnabled = !ids.isEmpty
        menu.addItem(play)
        let info = NSMenuItem(title: "Get Info", action: #selector(getInfo(_:)), keyEquivalent: "i")
        info.target = self
        info.isEnabled = !ids.isEmpty
        menu.addItem(info)
        menu.addItem(.separator())
        let download = NSMenuItem(title: "Download", action: #selector(downloadFromMenu(_:)), keyEquivalent: "")
        download.target = self
        download.isEnabled = onDownload != nil && selectionMayHaveCloudSongs
        menu.addItem(download)
        let add = NSMenuItem(title: "Add to Playlist", action: nil, keyEquivalent: "")
        add.target = self
        add.submenu = addToPlaylistMenu(hasSelection: !ids.isEmpty)
        add.isEnabled = !ids.isEmpty && (onAddToPlaylist != nil || onNewPlaylistFromSelection != nil)
        menu.addItem(add)
        if removablePlaylist != nil {
            let clear = NSMenuItem(title: "Clear", action: #selector(clearFromMenu(_:)), keyEquivalent: "")
            clear.target = self
            clear.isEnabled = canRemoveSelection
            menu.addItem(clear)
        }
        menu.addItem(.separator())
        let finder = NSMenuItem(title: "Show in Finder", action: #selector(showInFinder(_:)), keyEquivalent: "")
        finder.target = self
        finder.isEnabled = ids.prefix(50).contains { shownRow($0)?.fileURL != nil }
        menu.addItem(finder)
    }

    /// Add to Playlist ▸: New Playlist, then the source list's plain playlists, folders as
    /// submenus. Built whole here, and no submenu gets a delegate: menuNeedsUpdate would rebuild
    /// any menu it was handed as the row menu. The playlist being shown is left out, as a drop
    /// on it is refused, and so is a folder left with nothing in it.
    private func addToPlaylistMenu(hasSelection: Bool) -> NSMenu {
        let menu = NSMenu(title: "Add to Playlist")
        menu.autoenablesItems = false
        let new = NSMenuItem(title: "New Playlist", action: #selector(newPlaylistFromMenu(_:)), keyEquivalent: "")
        new.target = self
        // Off when every song it can see is only in oldTunes: the playlist would stay empty.
        new.isEnabled = onNewPlaylistFromSelection != nil && selectionMayHaveMusicSongs
        menu.addItem(new)
        var shown: Int64?
        if case .playlist(let id) = query.scope { shown = id }
        let tree = Self.addable(playlistMenu?() ?? [], leavingOut: shown)
        guard !tree.isEmpty else { return menu }
        menu.addItem(.separator())
        addPlaylistItems(tree, to: menu, enabled: onAddToPlaylist != nil && hasSelection)
        return menu
    }

    private func addPlaylistItems(_ entries: [PlaylistMenuEntry], to menu: NSMenu, enabled: Bool) {
        for entry in entries {
            let item = NSMenuItem(title: entry.playlist.name, action: nil, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            if entry.playlist.kind == .folder {
                let folder = NSMenu(title: entry.playlist.name)
                folder.autoenablesItems = false
                addPlaylistItems(entry.children, to: folder, enabled: enabled)
                item.submenu = folder
            } else {
                item.action = #selector(addToPlaylistFromMenu(_:))
                item.representedObject = NSNumber(value: entry.playlist.id)
            }
            menu.addItem(item)
        }
    }

    /// Only what can take songs: plain playlists other than `shown`, and the folders still
    /// holding one of them.
    private static func addable(_ entries: [PlaylistMenuEntry], leavingOut shown: Int64?) -> [PlaylistMenuEntry] {
        entries.compactMap { entry in
            switch entry.playlist.kind {
            case .regular:
                return entry.playlist.id == shown ? nil : PlaylistMenuEntry(playlist: entry.playlist, children: [])
            case .folder:
                let inside = addable(entry.children, leavingOut: shown)
                return inside.isEmpty ? nil : PlaylistMenuEntry(playlist: entry.playlist, children: inside)
            case .smart, .genius:
                return nil
            }
        }
    }
}

// MARK: - Supporting types

/// The off-main half of applying a new order: everything proportional to the library size.
struct PreparedOrder: Sendable {
    let ids: [Track.ID]
    let index: [Track.ID: Int]
    let selection: IndexSet
    let changed: Bool
    let anchorRow: Int?

    nonisolated init(ids: [Track.ID], oldOrder: [Track.ID], selected: [Track.ID], anchorID: Track.ID?) {
        var index = [Track.ID: Int](minimumCapacity: ids.count)
        for (row, id) in ids.enumerated() { index[id] = row }
        var selection = IndexSet()
        for id in selected { if let row = index[id] { selection.insert(row) } }
        self.ids = ids
        self.index = index
        self.selection = selection
        self.changed = ids != oldOrder
        self.anchorRow = anchorID.flatMap { index[$0] }
    }
}

extension TrackQuery {
    func browserValue(_ field: BrowserField) -> String? {
        switch field {
        case .genre: genre
        case .artist: artist
        case .album: album
        }
    }
}

/// A flipped container that hands layout to its controller.
final class ListContainerView: NSView {
    private let onLayout: () -> Void

    init(onLayout: @escaping () -> Void) {
        self.onLayout = onLayout
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        onLayout()
    }
}
