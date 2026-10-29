import AppKit

/// The left-hand "Source" pane: Library, On This Mac, then the user's playlists in their
/// Music.app order, with folders that open and close (RESEARCH.md §7.4).
///
/// A flat table over a flattened tree rather than NSOutlineView: the outline view's disclosure
/// button is a stock control that renders in the macOS 27 style, so the triangles are drawn and
/// hit-tested here instead.
///
/// Right-clicking offers the playlist commands (New Playlist, New Playlist Folder, Rename,
/// Duplicate, Delete); Return renames the selected playlist and Delete deletes it. The source
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
    /// new playlist always finds its row.
    func reload() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        do {
            let lists = try await library.playlists()
            if generation == reloadGeneration { playlists = lists }
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
        loadedOnce = true
        rebuildRows()
        shownGeneration = generation
        let done = reloadWaiters.filter { $0.generation <= generation }
        reloadWaiters.removeAll { $0.generation <= generation }
        for waiter in done { waiter.continuation.resume() }
    }

    /// Opens a playlist's name for typing, over its row, as iTunes did for a new playlist.
    func beginRename(_ id: Int64) {
        // Typing over another row keeps what was typed there, as a click away would.
        if renaming != nil { view.window?.makeFirstResponder(table) }
        select(.playlist(id))
        guard let playlist = playlists.first(where: { $0.id == id }),
              let row = rows.firstIndex(where: { $0.scope == .playlist(id) }) else { return }
        let field = SourceRenameField(name: playlist.name)
        field.onEnd = { [weak self] name, byKey in self?.endRename(id, name, byKey: byKey) }
        renaming = (id, field)
        // Beside the table, not in it: the table adds row views over its other subviews as it
        // needs them. The clip view still scrolls the box with the rows.
        scrollView.contentView.addSubview(field, positioned: .above, relativeTo: nil)
        placeRenameField()
        table.scrollRowToVisible(row)
        // Taking focus starts editing with the whole name selected.
        view.window?.makeFirstResponder(field.field)
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
        if !expanded.isDisjoint(with: doomed) {
            expanded.subtract(doomed)
            saveExpanded()
        }
        rebuildRows(replacingRow: selectionGoes ? selectedRow : nil)
    }

    /// `base`, or `base 2`, `base 3`… whichever no playlist is called yet, as iTunes numbered
    /// its untitled playlists.
    func unusedName(_ base: String) -> String {
        let taken = Set(playlists.map { $0.name.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    /// How many playlists and folders a folder holds, at any depth.
    func countInside(_ folderID: Int64) -> Int { subtree(of: folderID).count - 1 }

    /// Whether the list still has this playlist (folded away inside a folder counts).
    func hasPlaylist(_ id: Int64) -> Bool { playlists.contains { $0.id == id } }

    // MARK: Harness access (module-internal)

    var tableView: NSTableView { table }
    var rowTitles: [String] { rows.map(\.title) }
    var rowScopes: [LibraryScope] { rows.map(\.scope) }
    var rowDepths: [Int] { rows.map(\.depth) }
    var playlistCount: Int { playlists.count }
    /// The name box while a playlist is being renamed.
    var renameField: NSTextField? { renaming?.field.field }

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
    }

    private let library: any LibraryReading
    private let table = RetroTableView(rowHeight: Theme.Metrics.sourceRowHeight)
    private let scrollView = RetroScrollView(lineHeight: Theme.Metrics.sourceRowHeight)
    private let header = PaneHeaderView(title: "Source")
    private var playlists: [PlaylistInfo] = []
    private var rows: [Row] = []
    private var expanded: Set<Int64>
    private var isRebuilding = false
    private var loadedOnce = false
    private var reloadGeneration = 0
    /// The newest read on screen, and the older `reload()` calls waiting for a newer one.
    private var shownGeneration = 0
    private var reloadWaiters: [(generation: Int, continuation: CheckedContinuation<Void, Never>)] = []
    /// The playlist whose name is open for typing, and the box over its row.
    private var renaming: (id: Int64, field: SourceRenameField)?
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
        table.onLeftRight = { [weak self] right, all in self?.folderArrow(right: right, all: all) ?? false }
        let menu = NSMenu(title: "Source")
        menu.delegate = self
        menu.autoenablesItems = false
        table.menu = menu
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
    /// children under their folder. A playlist whose parent is missing is shown at the top level
    /// rather than lost. `replacingRow` is where a deleted selection was: the playlist row now
    /// there (or just above it) is selected instead.
    private func rebuildRows(replacingRow removedRow: Int? = nil) {
        let known = Set(playlists.map(\.id))
        var children: [Int64?: [PlaylistInfo]] = [:]
        for p in playlists {
            let parent = p.parentID.flatMap { known.contains($0) && $0 != p.id ? $0 : nil }
            children[parent, default: []].append(p)
        }
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
        // Once AppKit has finished ending the edit: focus moved during it lands on the window.
        Task { @MainActor [weak self] in
            if byKey, let self { view.window?.makeFirstResponder(table) }
            renaming.field.removeFromSuperview()
        }
        guard let typed, let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let old = playlists[index]
        guard !name.isEmpty, name != old.name else { return }
        // Shows the new name while Music saves it. Not during this event: a click on another
        // row ends the edit from inside the table's own mouse handling.
        Task { @MainActor [weak self] in
            guard let self, let index = playlists.firstIndex(where: { $0.id == id }) else { return }
            playlists[index].name = name
            rebuildRows()
        }
        onRenamePlaylist?(old, name)
    }

    private func cancelRename() {
        guard let renaming else { return }
        self.renaming = nil
        renaming.field.onEnd = nil
        renaming.field.field.abortEditing()
        renaming.field.removeFromSuperview()
    }
}

extension SourceListViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = tableView.makeView(withIdentifier: Self.rowID, owner: self) as? SourceRowView ?? SourceRowView()
        view.identifier = Self.rowID
        return view
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
        menu.addItem(.separator())
        add("Delete", #selector(deleteFromMenu(_:)), enabled: menuTarget != nil && onDeletePlaylist != nil)
    }
}
