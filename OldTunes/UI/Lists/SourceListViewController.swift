import AppKit

/// The left-hand "Source" pane: Library, On This Mac, then the user's playlists in their
/// Music.app order, with folders that open and close (RESEARCH.md §7.4).
///
/// A flat table over a flattened tree rather than NSOutlineView: the outline view's disclosure
/// button is a stock control that renders in the macOS 27 style, so the triangles are drawn and
/// hit-tested here instead.
///
/// Right-clicking offers the playlist commands (New Playlist, New Playlist Folder, Rename,
/// Duplicate, Download, Delete); Return renames the selected playlist and Delete deletes it.
/// Songs dragged from the track list drop onto plain playlists (RESEARCH.md §6.10). The source
/// list only asks for each one: AppController makes the change through Music. → and ← open and
/// close folders, as in a Finder list.
@MainActor
final class SourceListViewController: NSViewController {

    // MARK: Public API

    var onScopeChange: ((LibraryScope) -> Void)?
    private(set) var scope: LibraryScope = .library

    /// A new playlist or folder (`isFolder`), inside the folder `parent` (nil: the top level).
    var onNewPlaylist: ((_ isFolder: Bool, _ parent: Int64?) -> Void)?
    /// A name typed over a playlist's old one, already trimmed and different from it.
    var onRenamePlaylist: ((PlaylistInfo, String) -> Void)?
    var onDuplicatePlaylist: ((PlaylistInfo) -> Void)?
    /// Asks; the caller confirms with the user before deleting anything.
    var onDeletePlaylist: ((PlaylistInfo) -> Void)?
    /// Songs dropped on a plain playlist other than the one shown, in the order they were dragged.
    /// A drop never changes the selection. Nil refuses every drop.
    var onAddSongs: ((_ ids: [Track.ID], _ playlist: PlaylistInfo) -> Void)?
    /// Download on a plain or smart playlist's menu: the caller downloads its cloud-only songs.
    var onDownloadPlaylist: ((PlaylistInfo) -> Void)?

    init(library: any LibraryReading) {
        self.library = library
        expanded = Set((UserDefaults.standard.array(forKey: Self.expandedKey) as? [NSNumber] ?? []).map(\.int64Value))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Re-reads playlists (after `.libraryDidChange`). Keeps the selection when the playlist
    /// still exists; otherwise falls back to Library and reports the change.
    /// Two quick `.libraryDidChange` posts start two reads; only the newest one is applied, so
    /// an older read that lands late never brings back a deleted or renamed playlist. An older
    /// call returns once the newest read is shown, so a caller that reloads and then selects a
    /// new playlist always finds its row. The table is rebuilt only when a row would show
    /// something else (`refreshRows`): songs going into a playlist change only its count, which
    /// no row shows, so each chunk of an add leaves the list, its selection and a name box be.
    func reload() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        var read = false
        do {
            let lists = try await library.playlists()
            if generation == reloadGeneration {
                playlists = lists
                read = true
            }
        } catch {
            if generation == reloadGeneration { Log.error("sourcelist: playlists() failed: \(error)") }
        }
        guard generation == reloadGeneration else {
            let newest = reloadGeneration
            if shownGeneration < newest {
                await withCheckedContinuation { reloadWaiters.append((newest, $0)) }
            }
            return
        }
        // Only a read that worked (`loadIfNeeded`).
        if read { loadedOnce = true }
        refreshRows()
        shownGeneration = generation
        let done = reloadWaiters.filter { $0.generation <= generation }
        reloadWaiters.removeAll { $0.generation <= generation }
        for waiter in done { waiter.continuation.resume() }
    }

    /// Reads the playlists now, unless a read of them has worked already. For `unusedName` right
    /// after launch (⌘N in the first moments): over a list not read yet it would pick a name
    /// Music may have already, and a new playlist's name is what proves Music's answer leads to
    /// the playlist it made (MusicPlaylistEditor.confirm). A read that failed doesn't count, so
    /// the next call tries again.
    func loadIfNeeded() async {
        if !loadedOnce { await reload() }
    }

    /// Opens a playlist's name for typing, over its row, as iTunes did for a new playlist.
    func beginRename(_ id: Int64) {
        // Typing over another row keeps what was typed there, as a click away would.
        endRenaming()
        select(.playlist(id))
        guard let playlist = self.playlist(id), let row = rows.firstIndex(where: { $0.scope == .playlist(id) }) else { return }
        let field = SourceRenameField(name: playlist.name)
        field.onEnd = { [weak self] name, byKey in self?.endRename(id, name, byKey: byKey) }
        renaming = (id, field)
        // Beside the table, not in it: the table adds row views over its other subviews as it
        // needs them. The clip view still scrolls the box with the rows.
        scrollView.contentView.addSubview(field, positioned: .above, relativeTo: nil)
        placeRenameField()
        table.scrollRowToVisible(row)
        // Closing that window ends the box (`windowWillClose`); hiding or minimizing it doesn't.
        watchForClose(of: view.window)
        // Taking focus starts editing with the whole name selected.
        view.window?.makeFirstResponder(field.field)
    }

    /// Ends the name being typed, if any, keeping what was typed, as a click elsewhere would: a
    /// new name is asked for (`onRenamePlaylist`) before this returns. For a command the user
    /// gives while typing one (⌘N, ⇧⌘N, New Playlist in a menu), whose own box then needn't wait
    /// for this one (`renamesEnded`), and whose name isn't typed into this one meanwhile.
    func endRenaming() {
        if renaming != nil { view.window?.makeFirstResponder(table) }
        // If that didn't close it, the box never had the keys (no window then): nothing typed is lost.
        cancelRename()
    }

    /// Takes a playlist Music has deleted (and everything in it) out of the list now, rather than
    /// when the index catches up. When it was selected, the row that takes its place is selected.
    func showDeleted(_ id: Int64) {
        let doomed = subtree(of: id)
        guard playlists.contains(where: { doomed.contains($0.id) }) else { return }
        if let renaming, doomed.contains(renaming.id) { cancelRename() }
        var selectionGoes = false
        if case .playlist(let selected) = scope { selectionGoes = doomed.contains(selected) }
        let selectedRow = table.selectedRow
        playlists.removeAll { doomed.contains($0.id) }
        for id in doomed { pendingNames[id] = nil }
        if !expanded.isDisjoint(with: doomed) {
            expanded.subtract(doomed)
            saveExpanded()
        }
        rebuildRows(replacingRow: selectionGoes ? selectedRow : nil)
    }

    /// `base`, or `base 2`, `base 3`… whichever no playlist is called yet, as iTunes numbered
    /// its untitled playlists. A name typed over a playlist counts while Music saves it, and so
    /// does the name it replaces, which Music still has until then.
    func unusedName(_ base: String) -> String {
        let taken = Set((playlists.map(\.name) + pendingNames.values).map { $0.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    /// How many playlists and folders a folder holds, at any depth.
    func countInside(_ folderID: Int64) -> Int { subtree(of: folderID).count - 1 }

    /// Whether the list still has this playlist (folded away inside a folder counts).
    func hasPlaylist(_ id: Int64) -> Bool { playlists.contains { $0.id == id } }

    /// The playlist as the list shows it, with a name typed over it while Music saves that; nil
    /// when the list doesn't have it. For Add to Playlist ▸, which hands back only an id.
    func playlist(_ id: Int64) -> PlaylistInfo? { playlists.first { $0.id == id }.map(shown) }

    /// Every plain playlist in the list's order, inside the folders that hold one, open or not:
    /// the track list's Add to Playlist ▸ menu. Smart and Genius playlists take no songs, so
    /// they are left out, and so are folders with no plain playlist inside.
    var playlistTree: [PlaylistMenuEntry] {
        let children = playlistsByParent()
        var visited = Set<Int64>()
        func entries(_ parent: Int64?) -> [PlaylistMenuEntry] {
            var found: [PlaylistMenuEntry] = []
            for p in children[parent] ?? [] where visited.insert(p.id).inserted {
                switch p.kind {
                case .folder:
                    let inside = entries(p.id)
                    if !inside.isEmpty { found.append(PlaylistMenuEntry(playlist: p, children: inside)) }
                case .regular:
                    found.append(PlaylistMenuEntry(playlist: p, children: []))
                    // A playlist with playlists under it (libraries can be odd): those go beside it.
                    found += entries(p.id)
                case .smart, .genius:
                    found += entries(p.id)
                }
            }
            return found
        }
        return entries(nil)
    }

    /// The rename of `id` to `name` is over: the list stops showing that name over the index's,
    /// and redraws. Call it once the index has the name (after the `.renamed` edit and its
    /// reload), or the old name flashes back; or when Music refused it, which puts the old name
    /// back. A newer name typed since stays until its own rename ends.
    func endPendingRename(_ id: Int64, name: String) {
        guard pendingNames[id] == name else { return }
        pendingNames[id] = nil
        rebuildRows()
    }

    /// Returns once `id`'s name is no longer open for typing: at once when it isn't, otherwise
    /// when the box closes, however it closes (Return, Escape, a click elsewhere, the row going
    /// in a reload or a delete, the window closing). What was typed is then in `playlist(_:)`.
    /// For an alert, whose sheet would otherwise take the keys halfway through a name.
    func renameEnded(_ id: Int64) async {
        guard renaming?.id == id else { return }
        await withCheckedContinuation { renameWaiters[id, default: []].append($0) }
    }

    /// The playlist whose name is open for typing, if any.
    var renamingID: Int64? { renaming?.id }

    /// Returns once no playlist's name is open for typing, whichever playlist's it is: for the
    /// alerts after an add or a Download, and the queued playlist commands that ask first or open
    /// a name (AppController.enqueuePlaylistWork). Checked again after each box closes, since
    /// another can open in the same turn: Rename on another playlist closes the open box and opens
    /// its own. A ⌘N the user gives while typing ends the open box at once (`endRenaming`), and
    /// one that comes due later, queued behind other commands, waits here for a box opened since.
    func renamesEnded() async {
        while let open = renamingID { await renameEnded(open) }
    }

    // MARK: Harness access (module-internal)

    var tableView: NSTableView { table }
    var rowTitles: [String] { rows.map(\.title) }
    var rowScopes: [LibraryScope] { rows.map(\.scope) }
    var rowDepths: [Int] { rows.map(\.depth) }
    var playlistCount: Int { playlists.count }
    /// The name box while a playlist is being renamed.
    var renameField: NSTextField? { renaming?.field.field }
    /// The playlist the drop outline is on, while songs are dragged over one.
    var dropTargetID: Int64? { dropTarget }
    /// How many times the table has been rebuilt from the playlists (`rebuildRows`). A reload that
    /// changes nothing a row shows doesn't rebuild it.
    private(set) var rowRebuilds = 0

    /// Selects a scope as if clicked (expanding folders on the way), for tests and integration.
    func select(_ newScope: LibraryScope) {
        if case .playlist(let id) = newScope { expandAncestors(of: id) }
        guard let row = rows.firstIndex(where: { $0.scope == newScope }) else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    func setExpanded(_ folderID: Int64, _ open: Bool) {
        if open { expanded.insert(folderID) } else { expanded.remove(folderID) }
        saveExpanded()
        rebuildRows()
    }

    // MARK: - Private

    private struct Row {
        enum Kind { case library, onThisMac, playlist(PlaylistInfo) }
        var kind: Kind
        var depth: Int
        var hasChildren: Bool
        var isExpanded: Bool

        var title: String {
            switch kind {
            case .library: "Library"
            case .onThisMac: "On This Mac"
            case .playlist(let p): p.name
            }
        }

        var scope: LibraryScope {
            switch kind {
            case .library: .library
            case .onThisMac: .onThisMac
            case .playlist(let p): .playlist(p.id)
            }
        }

        var playlist: PlaylistInfo? {
            if case .playlist(let p) = kind { return p }
            return nil
        }

        @MainActor var icon: SourceIcon {
            switch kind {
            case .library: .library
            case .onThisMac: .onThisMac
            case .playlist(let p):
                switch p.kind {
                case .folder: .folder
                case .smart, .genius: .smartPlaylist
                case .regular: .playlist
                }
            }
        }

        var folderID: Int64? {
            if case .playlist(let p) = kind, p.kind == .folder { return p.id }
            return nil
        }

        /// Draws the same, for the same playlist: its name, icon, depth and triangle. A song count
        /// isn't drawn, so rows that differ only in one look alike.
        func looksLike(_ other: Row) -> Bool {
            scope == other.scope && title == other.title && playlist?.kind == other.playlist?.kind
                && depth == other.depth && hasChildren == other.hasChildren && isExpanded == other.isExpanded
        }
    }

    private let library: any LibraryReading
    private let table = RetroTableView(rowHeight: Theme.Metrics.sourceRowHeight)
    private let scrollView = RetroScrollView(lineHeight: Theme.Metrics.sourceRowHeight)
    private let header = PaneHeaderView(title: "Source")
    private var playlists: [PlaylistInfo] = []
    private var rows: [Row] = []
    private var expanded: Set<Int64>
    private var isRebuilding = false
    /// A read of the playlists has worked (`loadIfNeeded`).
    private var loadedOnce = false
    private var reloadGeneration = 0
    /// The newest read on screen, and the older `reload()` calls waiting for a newer one.
    private var shownGeneration = 0
    private var reloadWaiters: [(generation: Int, continuation: CheckedContinuation<Void, Never>)] = []
    /// The playlist whose name is open for typing, and the box over its row.
    private var renaming: (id: Int64, field: SourceRenameField)?
    /// Callers waiting for a playlist's box to close (`renameEnded`), each resumed once, when it
    /// does (`renameDidEnd`).
    private var renameWaiters: [Int64: [CheckedContinuation<Void, Never>]] = [:]
    /// Names typed over playlists, shown over the index's own until AppController ends each one
    /// (`endPendingRename`). Without it, any reload before Music has saved the name (another
    /// playlist edit, a re-ingest) would put the old name back for a while.
    private var pendingNames: [Int64: String] = [:]
    /// The plain playlist songs are being dragged over, outlined until the drag moves off it,
    /// leaves the list or drops. Its id, not its row: a reload during the drag rebuilds the rows,
    /// and the outline must stay on the same playlist.
    private var dropTarget: Int64? {
        didSet {
            guard dropTarget != oldValue else { return }
            table.enumerateAvailableRowViews { view, row in
                (view as? SourceRowView)?.isDropTarget = isDropTarget(row)
            }
        }
    }
    /// What the open right-click menu acts on: the playlist clicked, and where a new one goes.
    private var menuTarget: PlaylistInfo?
    private var menuParent: Int64?

    private static let expandedKey = "OldTunes.SourceList.expandedFolders"
    private static let rowID = NSUserInterfaceItemIdentifier("sourceRow")
    private static let cellID = NSUserInterfaceItemIdentifier("sourceCell")

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("source"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsEmptySelection = false
        table.allowsMultipleSelection = false
        table.dataSource = self
        table.delegate = self
        table.interceptMouseDown = { [weak self] event in self?.handleDisclosureClick(event) ?? false }
        table.onReturn = { [weak self] in self?.renameSelection() }
        table.onDelete = { [weak self] in self?.deleteSelection() }
        table.canDelete = { [weak self] in self?.selectedPlaylist != nil && self?.onDeletePlaylist != nil }
        table.onLeftRight = { [weak self] right, all in self?.folderArrow(right: right, all: all) ?? false }
        let menu = NSMenu(title: "Source")
        menu.delegate = self
        menu.autoenablesItems = false
        table.menu = menu
        // Songs from the track list drop onto playlists. The outline is drawn here
        // (SourceRowView.isDropTarget), never by AppKit, whose macOS 27 look is a selection.
        table.registerForDraggedTypes([.oldTunesSongs])
        table.draggingDestinationFeedbackStyle = .none
        table.onDragExit = { [weak self] in self?.dropTarget = nil }
        scrollView.documentView = table

        // No border of its own: the chrome frame around the source pane is the border.
        let inner = ListContainerView { [weak self] in self?.layoutInner() }
        inner.addSubview(header)
        inner.addSubview(scrollView)
        view = inner
        rebuildRows()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if !loadedOnce { Task { await reload() } }
    }

    private func layoutInner() {
        let b = view.bounds
        header.frame = NSRect(x: 0, y: 0, width: b.width, height: PaneHeaderView.height)
        scrollView.frame = NSRect(x: 0, y: PaneHeaderView.height, width: b.width,
                                  height: max(b.height - PaneHeaderView.height, 0))
        placeRenameField()
    }

    /// Library and On This Mac, then playlists depth-first in the order the library gave them,
    /// children under their folder.
    private func makeRows() -> [Row] {
        let children = playlistsByParent()
        var newRows: [Row] = [
            Row(kind: .library, depth: 0, hasChildren: false, isExpanded: false),
            Row(kind: .onThisMac, depth: 0, hasChildren: false, isExpanded: false),
        ]
        var visited = Set<Int64>()
        func walk(_ parent: Int64?, depth: Int) {
            for p in children[parent] ?? [] where visited.insert(p.id).inserted {
                let kids = !(children[p.id] ?? []).isEmpty
                let open = expanded.contains(p.id)
                newRows.append(Row(kind: .playlist(p), depth: depth, hasChildren: p.kind == .folder || kids, isExpanded: open))
                if open { walk(p.id, depth: depth + 1) }
            }
        }
        walk(nil, depth: 0)
        return newRows
    }

    /// After a reload: the table rebuilt only when a row would show something else. Otherwise
    /// the rows take the fresh copies of their playlists (a song count) and nothing is redrawn.
    private func refreshRows() {
        let fresh = makeRows()
        guard fresh.count == rows.count, zip(fresh, rows).allSatisfy({ $0.looksLike($1) }) else {
            rebuildRows()
            return
        }
        rows = fresh
    }

    /// The rows again (`makeRows`), the table reloaded and the selection kept. `replacingRow` is
    /// where a deleted selection was: the playlist row now there (or just above it) is selected
    /// instead.
    private func rebuildRows(replacingRow removedRow: Int? = nil) {
        let newRows = makeRows()
        rowRebuilds += 1
        isRebuilding = true
        rows = newRows
        table.reloadData()
        var target = rows.firstIndex { $0.scope == scope }
        if target == nil, let removedRow {
            target = [removedRow, removedRow - 1].first { $0 >= 0 && $0 < rows.count && rows[$0].playlist != nil }
        }
        if target == nil, case .playlist(let id) = scope, let ancestor = visibleAncestor(of: id) {
            target = rows.firstIndex { $0.scope == .playlist(ancestor) }
        }
        let row = target ?? 0
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        isRebuilding = false
        commitSelection()
        placeRenameField()
    }

    /// Each folder's playlists (the nil key: the top level's) in the order the library gave
    /// them, each as the list shows it. A playlist whose parent is missing goes at the top level
    /// rather than being lost.
    private func playlistsByParent() -> [Int64?: [PlaylistInfo]] {
        let known = Set(playlists.map(\.id))
        var children: [Int64?: [PlaylistInfo]] = [:]
        for p in playlists {
            let parent = p.parentID.flatMap { known.contains($0) && $0 != p.id ? $0 : nil }
            children[parent, default: []].append(shown(p))
        }
        return children
    }

    /// The playlist as the list shows it: with a name typed over it while Music saves that.
    private func shown(_ playlist: PlaylistInfo) -> PlaylistInfo {
        guard let name = pendingNames[playlist.id] else { return playlist }
        var shown = playlist
        shown.name = name
        return shown
    }

    /// The nearest folder above `id` that is currently a visible row.
    private func visibleAncestor(of id: Int64) -> Int64? {
        let byID = Dictionary(playlists.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var current = byID[id]?.parentID
        var guardCount = 0
        while let pid = current, guardCount < 64 {
            if rows.contains(where: { $0.scope == .playlist(pid) }) { return pid }
            current = byID[pid]?.parentID
            guardCount += 1
        }
        return nil
    }

    private func expandAncestors(of id: Int64) {
        let byID = Dictionary(playlists.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var current = byID[id]?.parentID
        var changed = false
        var guardCount = 0
        while let pid = current, guardCount < 64 {
            if expanded.insert(pid).inserted { changed = true }
            current = byID[pid]?.parentID
            guardCount += 1
        }
        if changed {
            saveExpanded()
            rebuildRows()
        }
    }

    /// `id` and every playlist inside it, at any depth.
    private func subtree(of id: Int64) -> Set<Int64> {
        var found: Set<Int64> = [id]
        var frontier = [id]
        while let parent = frontier.popLast() {
            for p in playlists where p.parentID == parent && found.insert(p.id).inserted {
                frontier.append(p.id)
            }
        }
        return found
    }

    private func saveExpanded() {
        UserDefaults.standard.set(expanded.map { NSNumber(value: $0) }, forKey: Self.expandedKey)
    }

    private func commitSelection() {
        let row = table.selectedRow
        guard row >= 0, row < rows.count else { return }
        let newScope = rows[row].scope
        guard newScope != scope else { return }
        scope = newScope
        onScopeChange?(newScope)
    }

    /// A click on a folder's triangle toggles it without moving the selection.
    private func handleDisclosureClick(_ event: NSEvent) -> Bool {
        let p = table.convert(event.locationInWindow, from: nil)
        let row = table.row(at: p)
        guard row >= 0, row < rows.count, rows[row].hasChildren, let id = rows[row].folderID ?? folderLikeID(row) else {
            return false
        }
        let rowRect = table.rect(ofRow: row)
        let hit = SourceCellView.disclosureRect(depth: rows[row].depth).insetBy(dx: -3, dy: -4)
        guard hit.contains(NSPoint(x: p.x - rowRect.minX, y: p.y - rowRect.minY)) else { return false }
        setExpanded(id, !rows[row].isExpanded)
        return true
    }

    /// A non-folder playlist that still has children (rare; libraries can be odd).
    private func folderLikeID(_ row: Int) -> Int64? {
        if case .playlist(let p) = rows[row].kind { return p.id }
        return nil
    }

    /// → opens the selected folder and ← closes it; with ⌥, every folder inside it too. ← on a
    /// playlist inside a folder selects the folder. A folder keeps both arrows even when there is
    /// nothing to open or close, so pressing one twice never skips the song playing. Any other row
    /// lets them go on to the window, which plays the previous or next song (or album), as iTunes
    /// 4.9's flat source list did.
    private func folderArrow(right: Bool, all: Bool) -> Bool {
        let row = table.selectedRow
        guard row >= 0, row < rows.count else { return false }
        let r = rows[row]
        if r.hasChildren, let id = r.folderID ?? folderLikeID(row) {
            if all {
                let folders = Set(playlists.filter { $0.kind == .folder }.map(\.id)).union(playlists.compactMap(\.parentID))
                let inside = subtree(of: id).intersection(folders)
                if right { expanded.formUnion(inside) } else { expanded.subtract(inside) }
                saveExpanded()
                rebuildRows()
            } else if r.isExpanded != right {
                setExpanded(id, right)
            }
            return true
        }
        guard !right, !all, r.depth > 0, let parent = r.playlist?.parentID,
              let parentRow = rows.firstIndex(where: { $0.scope == .playlist(parent) }) else { return false }
        table.selectRowIndexes(IndexSet(integer: parentRow), byExtendingSelection: false)
        table.scrollRowToVisible(parentRow)
        return true
    }

    // MARK: Playlist commands

    private var selectedPlaylist: PlaylistInfo? {
        let row = table.selectedRow
        return row >= 0 && row < rows.count ? rows[row].playlist : nil
    }

    /// New playlists go inside the folder pointed at, or beside the playlist pointed at.
    private func newItemParent(near target: PlaylistInfo?) -> Int64? {
        guard let target else { return nil }
        let parent = target.kind == .folder ? target.id : target.parentID
        return parent.flatMap { id in playlists.contains { $0.id == id && $0.kind == .folder } ? id : nil }
    }

    /// The playlist a drop on `row` adds songs to, if any (see `acceptsSongs`).
    private func songTarget(at row: Int) -> PlaylistInfo? {
        guard row >= 0, row < rows.count, let playlist = rows[row].playlist, acceptsSongs(playlist) else { return nil }
        return playlist
    }

    /// Only a plain playlist takes songs, and not the one being shown, whose songs are the ones
    /// in the track list: a drop there would only add them again. Library, On This Mac, folders,
    /// and smart and Genius playlists take none.
    private func acceptsSongs(_ playlist: PlaylistInfo) -> Bool {
        playlist.kind == .regular && scope != .playlist(playlist.id)
    }

    private func isDropTarget(_ row: Int) -> Bool {
        guard let dropTarget, row >= 0, row < rows.count else { return false }
        return rows[row].playlist?.id == dropTarget
    }

    /// Return on Library or On This Mac does nothing, as before playlists could be renamed.
    private func renameSelection() {
        guard let playlist = selectedPlaylist, onRenamePlaylist != nil else { return }
        beginRename(playlist.id)
    }

    private func deleteSelection() {
        guard let playlist = selectedPlaylist, let onDeletePlaylist else { NSSound.beep(); return }
        onDeletePlaylist(playlist)
    }

    @objc private func newPlaylistFromMenu(_ sender: Any?) { onNewPlaylist?(false, menuParent) }
    @objc private func newFolderFromMenu(_ sender: Any?) { onNewPlaylist?(true, menuParent) }
    @objc private func renameFromMenu(_ sender: Any?) { if let menuTarget { beginRename(menuTarget.id) } }
    @objc private func duplicateFromMenu(_ sender: Any?) { if let menuTarget { onDuplicatePlaylist?(menuTarget) } }
    @objc private func downloadFromMenu(_ sender: Any?) { if let menuTarget { onDownloadPlaylist?(menuTarget) } }
    @objc private func deleteFromMenu(_ sender: Any?) { if let menuTarget { onDeletePlaylist?(menuTarget) } }

    // MARK: Renaming in place

    /// Lines the box up so the name inside it sits where the row drew it. Ends the edit if the
    /// row is gone (deleted, or its folder closed).
    private func placeRenameField() {
        guard let renaming else { return }
        guard let row = rows.firstIndex(where: { $0.scope == .playlist(renaming.id) }) else {
            cancelRename()
            return
        }
        let rect = scrollView.contentView.convert(table.rect(ofRow: row), from: table)
        // The field's text sits 5 pt inside its outline (3 pt inset + the editor's 2 pt padding),
        // and the glow needs 3 pt at the right edge.
        let x = rect.minX + Theme.Metrics.sourceTextLeft + CGFloat(rows[row].depth) * SourceCellView.indentPerLevel - 5
        renaming.field.place(NSRect(x: x, y: rect.minY, width: max(rect.maxX - x - 4, 40), height: rect.height))
    }

    private func endRename(_ id: Int64, _ typed: String?, byKey: Bool) {
        guard let renaming, renaming.id == id else { return }
        self.renaming = nil
        // Last, so a name typed is shown by the time anyone waiting reads it.
        defer { renameDidEnd(id) }
        // Once AppKit has finished ending the edit: focus moved during it lands on the window.
        Task { @MainActor [weak self] in
            if byKey, let self { view.window?.makeFirstResponder(table) }
            renaming.field.removeFromSuperview()
        }
        guard let typed, let onRenamePlaylist, let old = playlist(id) else { return }
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != old.name else { return }
        // Shows the new name while Music saves it, through any reload until AppController ends
        // it. The rows are rebuilt later, not during this event: a click on another row ends
        // the edit from inside the table's own mouse handling.
        pendingNames[id] = name
        Task { @MainActor [weak self] in self?.rebuildRows() }
        onRenamePlaylist(old, name)
    }

    private func cancelRename() {
        guard let renaming else { return }
        self.renaming = nil
        renaming.field.onEnd = nil
        renaming.field.field.abortEditing()
        renaming.field.removeFromSuperview()
        renameDidEnd(renaming.id)
    }

    /// Every way a rename ends comes through `endRename` or `cancelRename`, each of which clears
    /// `renaming` first, so this runs once per rename.
    private func renameDidEnd(_ id: Int64) {
        for waiter in renameWaiters.removeValue(forKey: id) ?? [] { waiter.resume() }
    }

    /// Watches the window a name box opens in for closing (`windowWillClose`), and no other.
    private func watchForClose(of window: NSWindow?) {
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
        guard let window else { return }
        center.addObserver(self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification,
                           object: window)
    }

    /// The window closing keeps a name being typed, as a click elsewhere would, rather than leave
    /// the box open where nobody sees it. Only closing: hiding OldTunes (⌘H), minimizing and the
    /// window being ordered out (`viewWillDisappear` comes for each of them) keep the box open with
    /// what was typed, as AppKit does, and send nothing until the user comes back to it.
    @objc private func windowWillClose(_ notification: Notification) {
        guard renaming != nil else { return }
        view.window?.makeFirstResponder(table)
        cancelRename()   // a box that never had the keys: nothing typed to keep
    }
}

extension SourceListViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = tableView.makeView(withIdentifier: Self.rowID, owner: self) as? SourceRowView ?? SourceRowView()
        view.identifier = Self.rowID
        view.isDropTarget = isDropTarget(row)
        return view
    }

    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        (rowView as? SourceRowView)?.isDropTarget = isDropTarget(row)
    }

    /// Songs from the track list, onto a playlist that takes them (`acceptsSongs`). The row
    /// under the pointer decides, not AppKit's proposal, which between two rows is a drop above
    /// the lower one. Never touches the selection: that would switch the track list the songs
    /// are being dragged from.
    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        let hit = tableView.row(at: tableView.convert(info.draggingLocation, from: nil))
        guard onAddSongs != nil, info.draggingPasteboard.availableType(from: [.oldTunesSongs]) != nil,
              let target = songTarget(at: hit) else {
            dropTarget = nil
            return []
        }
        tableView.setDropRow(hit, dropOperation: .on)
        dropTarget = target.id
        return .copy
    }

    /// Hands the songs over and returns at once: AppController adds them later, on its playlist
    /// queue, so no alert or Apple Event runs inside the drag.
    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        let target = dropTarget
        dropTarget = nil
        // Found again by id: a reload since validateDrop may have moved or removed it.
        guard let target, let onAddSongs, let playlist = self.playlist(target), acceptsSongs(playlist) else { return false }
        let ids = SongDrag.ids(on: info.draggingPasteboard)
        guard !ids.isEmpty else { return false }
        onAddSongs(ids, playlist)
        return true
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < rows.count else { return nil }
        let cell = tableView.makeView(withIdentifier: Self.cellID, owner: self) as? SourceCellView ?? SourceCellView()
        cell.identifier = Self.cellID
        let r = rows[row]
        cell.configure(title: r.title, icon: r.icon, depth: r.depth, disclosure: r.hasChildren ? r.isExpanded : nil)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isRebuilding else { return }
        commitSelection()
    }
}

// MARK: - Right-click menu

extension SourceListViewController: NSMenuDelegate {
    /// Built when it opens, for the row the right-click selected. A right-click below the last
    /// row is about the list itself: only the New commands apply, at the top level.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menuTarget = table.menuRow >= 0 ? selectedPlaylist : nil
        menuParent = newItemParent(near: menuTarget)
        func add(_ title: String, _ action: Selector, enabled: Bool) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            menu.addItem(item)
        }
        add("New Playlist", #selector(newPlaylistFromMenu(_:)), enabled: onNewPlaylist != nil)
        add("New Playlist Folder", #selector(newFolderFromMenu(_:)), enabled: onNewPlaylist != nil)
        menu.addItem(.separator())
        add("Rename", #selector(renameFromMenu(_:)), enabled: menuTarget != nil && onRenamePlaylist != nil)
        // Only a plain playlist: copying a smart playlist's songs would lose its rules.
        add("Duplicate", #selector(duplicateFromMenu(_:)),
            enabled: menuTarget?.kind == .regular && onDuplicatePlaylist != nil)
        // A playlist's own songs, a smart one's included. Not a folder's: that would be every
        // playlist inside it.
        add("Download", #selector(downloadFromMenu(_:)),
            enabled: (menuTarget?.kind == .regular || menuTarget?.kind == .smart) && onDownloadPlaylist != nil)
        menu.addItem(.separator())
        add("Delete", #selector(deleteFromMenu(_:)), enabled: menuTarget != nil && onDeletePlaylist != nil)
    }
}
