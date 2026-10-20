import AppKit
import GRDB

/// HARNESS ONLY (runs after the review bench under OLDTUNES_HARNESS=lists, or alone with
/// OLDTUNES_LISTS_MODE=playlists). The source list's right-click playlist commands, on an
/// invented library in a scratch index next to the evidence: what the menu offers for each kind
/// of row, Return and Delete, renaming in place, and the index edits AppController makes once
/// Music has made a change (Music itself is the `musicplaylists` live check's job). Invented
/// names only, so the snapshots can be shared.
@MainActor
final class ListsPlaylistBench {
    private(set) var passes = 0
    private(set) var failures: [String] = []
    private let outDir: URL
    private var window: NSWindow?

    private var scopes: [LibraryScope] = []
    private var newAsks: [(isFolder: Bool, parent: Int64?)] = []
    private var renames: [(id: Int64, old: String, new: String)] = []
    private var duplicates: [Int64] = []
    private var deletes: [Int64] = []

    init(outDir: URL) { self.outDir = outDir }

    private func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if ok { passes += 1 } else { failures.append(name) }
        Log.info("lists-playlists: \(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    }

    private func info(_ s: String) { Log.info("lists-playlists: \(s)") }

    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
    }

    // MARK: Run

    func run() async {
        // ListsHarness.run() puts the user's own open folders back at the end.
        UserDefaults.standard.removeObject(forKey: "OldTunes.SourceList.expandedFolders")
        let dbURL = outDir.appendingPathComponent("playlist-bench.sqlite")
        removeIndex(at: dbURL)
        defer { removeIndex(at: dbURL) }
        let index: LibraryIndex
        do {
            index = try LibraryIndex(path: dbURL)
            _ = try await index.replaceMusicLibrary(Self.songs, playlists: Self.playlists)
        } catch {
            check("scratch index with an invented library", false, "\(error)")
            return
        }
        guard let source = await buildWindow(index: index), let window else { return }

        check("rows start in Music's order", source.rowTitles == ["Library", "On This Mac", "Road Mixes", "Fresh Picks",
                                                                  "Top Rated", "Lakeside", "Workout"], "\(source.rowTitles)")
        await realRightClick(source, row: 5)
        menuChecks(source, in: window)
        await renameChecks(source, in: window)
        keyChecks(source, in: window)
        questionChecks()
        await indexChecks(source, index: index)
        info("SUMMARY passed=\(passes) failed=\(failures.count)\(failures.isEmpty ? "" : " failures=\(failures)")")
    }

    private func removeIndex(at url: URL) {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }

    // MARK: Library

    /// Six invented songs. Music's own order for the lists: the folder, smart lists by name,
    /// then plain lists by name; a folder's playlists can sit anywhere.
    private static let songs: [SongRecord] = (1...6).map { n in
        var r = SongRecord(origin: .musicLibrary)
        r.persistentID = 1000 + Int64(n)
        r.title = "Invented Song \(n)"
        r.artist = "Invented Artist"
        r.album = "Invented Album"
        r.titleSortSource = r.title
        r.artistSortSource = r.artist
        r.albumSortSource = r.album
        r.contentHash = r.computeContentHash()
        return r
    }

    private static let playlists: [PlaylistRecord] = {
        func list(_ id: Int64, _ name: String, _ kind: PlaylistInfo.Kind, parent: Int64? = nil,
                  _ members: [Int64] = []) -> (PlaylistInfo, [Int64]) {
            (PlaylistInfo(id: id, name: name, kind: kind, parentID: parent, trackCount: members.count), members)
        }
        let lists = [
            list(501, "Road Mixes", .folder),
            list(511, "Drive Home", .regular, parent: 501, [1001, 1002]),
            list(512, "Late Shift", .regular, parent: 501, [1003]),
            list(601, "Fresh Picks", .smart, [1006, 1005]),
            list(602, "Top Rated", .smart, [1004]),
            list(701, "Lakeside", .regular, [1001, 1003, 1001]),
            list(702, "Workout", .regular, [1002, 1004, 1006]),
        ]
        return lists.enumerated().map { PlaylistRecord(info: $1.0, sortIndex: $0, memberPIDs: $1.1) }
    }()

    // MARK: Window

    private func buildWindow(index: LibraryIndex) async -> SourceListViewController? {
        let size = NSSize(width: 230, height: 420)
        let window = PlaylistBenchWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
                                         backing: .buffered, defer: false)
        window.title = "OldTunes — playlist commands"
        window.isReleasedWhenClosed = false
        window.colorSpace = .sRGB
        let backdrop = PlaylistBenchBackdrop(frame: NSRect(origin: .zero, size: size))
        window.contentView = backdrop
        let source = SourceListViewController(library: index)
        HarnessPanes.frame(source: source.view, tracks: nil, in: backdrop, top: 12, bottom: 12)
        source.onScopeChange = { [weak self] in self?.scopes.append($0) }
        source.onNewPlaylist = { [weak self] in self?.newAsks.append(($0, $1)) }
        source.onRenamePlaylist = { [weak self] in self?.renames.append(($0.id, $0.name, $1)) }
        source.onDuplicatePlaylist = { [weak self] in self?.duplicates.append($0.id) }
        source.onDeletePlaylist = { [weak self] in self?.deletes.append($0.id) }
        window.center()
        window.makeKeyAndOrderFront(nil)
        await source.reload()
        window.makeFirstResponder(source.tableView)
        self.window = window
        return source
    }

    /// After a pass of the run loop: the table makes its row views in the display pass that
    /// follows a reload, and the checks here run between passes, as no user can.
    private func snapshot(_ name: String, of source: SourceListViewController) async {
        guard let window else { return }
        await settle()
        window.layoutIfNeeded()
        window.displayIfNeeded()
        var drawn = 0
        source.tableView.enumerateAvailableRowViews { _, _ in drawn += 1 }
        check("\(name) shows every row", drawn == source.rowTitles.count, "\(drawn) of \(source.rowTitles.count) rows drawn")
        let url = outDir.appendingPathComponent(name)
        if Snapshot.write(window, to: url) { info("snapshot \(url.path)") }
    }

    // MARK: Menu

    /// Through AppKit's own path: rightMouseDown runs the menu until the timer closes it.
    private func realRightClick(_ source: SourceListViewController, row: Int) async {
        guard let window else { return }
        let table = source.tableView
        let rect = table.rect(ofRow: row)
        let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: 1) else { return }
        let seen = MenuSeen()
        let timer = Timer(timeInterval: 0.4, repeats: false) { _ in
            MainActor.assumeIsolated {
                seen.text = Self.describe(table.menu)
                table.menu?.cancelTracking()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        table.rightMouseDown(with: event)
        await settle()
        check("a right-click on a playlist opens the playlist commands, Delete included",
              seen.text == "New Playlist, New Playlist Folder, —, Rename, Duplicate, —, Delete" && table.selectedRow == row,
              "menu \(seen.text), selected row \(table.selectedRow) (want \(row))")
    }

    private func menuChecks(_ source: SourceListViewController, in window: NSWindow) {
        let table = source.tableView
        let noDuplicate = "New Playlist, New Playlist Folder, —, Rename, Duplicate(off), —, Delete"
        let newOnly = "New Playlist, New Playlist Folder, —, Rename(off), Duplicate(off), —, Delete(off)"

        var menu = rightClick(table, row: 4, in: window)
        check("smart playlist: everything but Duplicate", Self.describe(menu) == noDuplicate, Self.describe(menu))
        menu = rightClick(table, row: 2, in: window)
        check("folder: everything but Duplicate", Self.describe(menu) == noDuplicate, Self.describe(menu))
        perform(menu, "New Playlist")
        check("New Playlist on a folder makes it inside the folder", newAsks.last.map { !$0.isFolder && $0.parent == 501 } == true,
              "\(newAsks)")
        menu = rightClick(table, row: 0, in: window)
        check("Library: only the New commands", Self.describe(menu) == newOnly, Self.describe(menu))
        perform(menu, "New Playlist Folder")
        check("New Playlist Folder on Library goes at the top level", newAsks.last.map { $0.isFolder && $0.parent == nil } == true,
              "\(newAsks)")

        source.select(.playlist(702))
        menu = rightClick(table, row: nil, in: window)
        check("a right-click below the rows offers only the New commands and keeps the selection",
              Self.describe(menu) == newOnly && source.scope == .playlist(702), Self.describe(menu))
        perform(menu, "New Playlist")
        check("…and New Playlist there goes at the top level", newAsks.last.map { !$0.isFolder && $0.parent == nil } == true,
              "\(newAsks)")

        source.setExpanded(501, true)
        let row = source.rowScopes.firstIndex(of: .playlist(511)) ?? -1
        menu = rightClick(table, row: row, in: window)
        perform(menu, "New Playlist")
        check("New Playlist on a playlist in a folder goes in that folder", newAsks.last?.parent == 501, "\(newAsks)")
        perform(menu, "Duplicate")
        perform(menu, "Delete")
        check("Duplicate and Delete ask about the playlist clicked", duplicates == [511] && deletes == [511],
              "duplicates \(duplicates), deletes \(deletes)")
        source.setExpanded(501, false)
        duplicates.removeAll()
        deletes.removeAll()
    }

    /// A right-click without the menu's tracking loop: `menu(for:)` as AppKit calls it, then the
    /// delegate's build. `row` nil clicks the empty space below the rows.
    private func rightClick(_ table: NSTableView, row: Int?, in window: NSWindow) -> NSMenu? {
        let local: NSPoint
        if let row {
            let r = table.rect(ofRow: row)
            local = NSPoint(x: r.midX, y: r.midY)
        } else {
            local = NSPoint(x: 40, y: table.rect(ofRow: table.numberOfRows - 1).maxY + 30)
        }
        guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: table.convert(local, to: nil), modifierFlags: [],
                                             timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: 1),
              let menu = table.menu(for: event) else { return nil }
        menu.delegate?.menuNeedsUpdate?(menu)
        return menu
    }

    private static func describe(_ menu: NSMenu?) -> String {
        (menu?.items ?? []).map { $0.isSeparatorItem ? "—" : "\($0.title)\($0.isEnabled ? "" : "(off)")" }
            .joined(separator: ", ")
    }

    private func perform(_ menu: NSMenu?, _ title: String) {
        guard let item = menu?.items.first(where: { $0.title == title }), let action = item.action else { return }
        NSApp.sendAction(action, to: item.target, from: item)
    }

    // MARK: Renaming in place

    private func renameChecks(_ source: SourceListViewController, in window: NSWindow) async {
        let table = source.tableView
        source.select(.playlist(702))
        let row = table.selectedRow
        press(table, keyCode: 36, "\r", in: window)
        let field = source.renameField
        check("Return opens the selected playlist's name, all of it selected",
              field?.stringValue == "Workout" && (window.firstResponder as? NSTextView)?.delegate === field
              && (window.firstResponder as? NSTextView)?.selectedRange() == NSRange(location: 0, length: 7),
              "field \(field?.stringValue ?? "none")")
        if let box = field?.superview, let clip = box.superview {
            let rowRect = clip.convert(table.rect(ofRow: row), from: table)
            check("the name box sits over the row's name, above the rows",
                  clip.subviews.last === box && abs(box.frame.midY - rowRect.midY) < 0.5
                  && box.frame.minX > Theme.Metrics.sourceTextLeft - 12 && box.frame.maxX <= rowRect.maxX + 4,
                  "box \(box.frame), row \(rowRect)")
        }
        await snapshot("P01_rename_in_place.png", of: source)
        type("Gym", into: field)
        (field?.currentEditor() as? NSTextView)?.insertNewline(nil)
        await settle()
        check("Return keeps the typed name and asks for the rename", renames.last.map { $0 == (702, "Workout", "Gym") } == true,
              "\(renames)")
        check("the row shows the new name at once, and focus goes back to the list",
              source.rowTitles[row] == "Gym" && window.firstResponder === table && source.renameField == nil,
              "\(source.rowTitles), first responder \(String(describing: window.firstResponder))")

        source.select(.playlist(701))
        press(table, keyCode: 36, "\r", in: window)
        type("Sand", into: source.renameField)
        (source.renameField?.currentEditor() as? NSTextView)?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        await settle()
        check("Escape puts the old name back and asks nothing", renames.count == 1 && source.rowTitles.contains("Lakeside")
              && source.renameField == nil && window.firstResponder === table, "\(renames.count) renames")

        let elsewhere = NSTextField(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        window.contentView?.addSubview(elsewhere)
        source.beginRename(602)
        type("Keepers", into: source.renameField)
        window.makeFirstResponder(elsewhere)
        await settle()
        check("clicking away keeps the typed name and leaves focus where it went",
              renames.last.map { $0 == (602, "Top Rated", "Keepers") } == true && window.firstResponder !== table
              && source.renameField == nil, "\(renames)")
        elsewhere.removeFromSuperview()
        window.makeFirstResponder(table)

        let before = renames.count
        source.beginRename(701)
        type("   ", into: source.renameField)
        (source.renameField?.currentEditor() as? NSTextView)?.insertNewline(nil)
        source.beginRename(701)
        (source.renameField?.currentEditor() as? NSTextView)?.insertNewline(nil)
        await settle()
        check("a blank or unchanged name asks nothing", renames.count == before, "\(renames.count - before) asked")
    }

    private func type(_ text: String, into field: NSTextField?) {
        guard let editor = field?.currentEditor() as? NSTextView else { return }
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    private func press(_ table: NSTableView, keyCode: UInt16, _ chars: String, in window: NSWindow) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, characters: chars,
                                           charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode) else { return }
        table.keyDown(with: event)
    }

    // MARK: Keys and the question

    private func keyChecks(_ source: SourceListViewController, in window: NSWindow) {
        deletes.removeAll()
        source.select(.playlist(701))
        press(source.tableView, keyCode: 51, "\u{7F}", in: window)
        press(source.tableView, keyCode: 117, "\u{F728}", in: window)
        check("Delete and Forward Delete ask to delete the selected playlist", deletes == [701, 701], "\(deletes)")
        // Delete with Library selected beeps; not pressed, so the bench makes no sound.
    }

    private func questionChecks() {
        let lakeside = PlaylistInfo(id: 701, name: "Lakeside", kind: .regular, parentID: nil, trackCount: 3)
        let q = AppController.deleteQuestion(for: lakeside, inside: 0, cloudLibraryOn: true)
        check("the delete question names the playlist and says what goes with it",
              q.message == "Are you sure you want to delete the playlist “Lakeside”?"
              && q.informative == "It’s deleted from the Music app too, and from your iCloud Music Library on all your devices. "
              + "The songs in it stay in your library. You can’t undo this.", "\(q)")
        let folder = PlaylistInfo(id: 501, name: "Road Mixes", kind: .folder, parentID: nil, trackCount: 0)
        let f = AppController.deleteQuestion(for: folder, inside: 3, cloudLibraryOn: false)
        let empty = AppController.deleteQuestion(for: folder, inside: 0, cloudLibraryOn: nil)
        check("a folder's question counts its playlists; iCloud is named only when Sync Library may be on",
              f.message == "Are you sure you want to delete the folder “Road Mixes” and the 3 playlists in it?"
              && f.informative == "They’re deleted from the Music app too. The songs in them stay in your library. You can’t undo this."
              && empty.message == "Are you sure you want to delete the folder “Road Mixes”?"
              && empty.informative.hasPrefix("It’s deleted from the Music app too, and from your iCloud"), "\(f) / \(empty)")
    }

    // MARK: Index edits

    /// What AppController does once Music has made each change: the index edit, then a reload.
    private func indexChecks(_ source: SourceListViewController, index: LibraryIndex) async {
        let table = source.tableView
        await source.reload()   // the renames above were never saved anywhere
        check("names nobody saved are gone after a reload", source.rowTitles.contains("Workout") && source.rowTitles.contains("Top Rated"))
        check("unusedName numbers a taken name", source.unusedName("lakeside") == "lakeside 2" && source.unusedName("Camping") == "Camping")
        do {
            let hashBefore = try await index.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM meta WHERE key = 'playlists_hash'") }
            try await index.apply(.added(PlaylistInfo(id: 801, name: "Camping", kind: .regular, parentID: nil, trackCount: 0), songsFrom: nil))
            await source.reload()
            let hashAfter = try await index.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM meta WHERE key = 'playlists_hash'") }
            check("a new playlist lands among the plain ones by name, and the next re-ingest will rewrite the playlists",
                  source.rowTitles.suffix(3) == ["Camping", "Lakeside", "Workout"] && hashBefore == 1 && hashAfter == 0,
                  "\(source.rowTitles), hash rows \(hashBefore ?? -1) → \(hashAfter ?? -1)")
            source.beginRename(801)
            check("a new playlist's name opens for typing", source.renameField?.stringValue == "Camping")
            (source.renameField?.currentEditor() as? NSTextView)?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))

            try await index.apply(.renamed(801, to: "Zydeco"))
            await source.reload()
            check("a renamed playlist moves to its new place and stays selected",
                  source.rowTitles.suffix(3) == ["Lakeside", "Workout", "Zydeco"] && source.scope == .playlist(801), "\(source.rowTitles)")

            try await index.apply(.added(PlaylistInfo(id: 802, name: "Lakeside copy", kind: .regular, parentID: nil, trackCount: 3),
                                         songsFrom: 701))
            await source.reload()
            let order = TrackSort(field: .playlistOrder, ascending: true)
            let original = try await index.ids(for: TrackQuery(scope: .playlist(701), sort: order))
            let copy = try await index.ids(for: TrackQuery(scope: .playlist(802), sort: order))
            let items = try await index.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM playlist_item WHERE playlist_id = 802") }
            check("a duplicate has the original's songs, in order, repeats kept, right after the original",
                  !original.isEmpty && copy == original && items == 3
                  && source.rowTitles.firstIndex(of: "Lakeside copy") == source.rowTitles.firstIndex(of: "Lakeside").map { $0 + 1 },
                  "original \(original), copy \(copy), \(items ?? -1) items, \(source.rowTitles)")

            try await index.apply(.added(PlaylistInfo(id: 803, name: "untitled folder", kind: .folder, parentID: 501, trackCount: 0),
                                         songsFrom: nil))
            try await index.apply(.added(PlaylistInfo(id: 804, name: "untitled playlist", kind: .regular, parentID: 501, trackCount: 0),
                                         songsFrom: nil))
            await source.reload()
            source.setExpanded(501, true)
            let start = (source.rowTitles.firstIndex(of: "Road Mixes") ?? 0) + 1
            check("new things in a folder: folders first, then by name; countInside counts them",
                  Array(source.rowTitles[start..<min(start + 4, source.rowTitles.count)])
                  == ["untitled folder", "Drive Home", "Late Shift", "untitled playlist"]
                  && source.rowDepths[start] == 1 && source.countInside(501) == 4, "\(source.rowTitles)")

            scopes.removeAll()
            source.select(.playlist(701))
            let lakesideRow = table.selectedRow
            source.showDeleted(701)
            check("deleting the selected playlist selects the row that takes its place",
                  table.selectedRow == lakesideRow && source.rowTitles[lakesideRow] == "Lakeside copy" && scopes.last == .playlist(802),
                  "row \(table.selectedRow), scopes \(scopes)")
            try await index.apply(.deleted(701))
            await source.reload()
            let lakesideItems = try await index.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM playlist_item WHERE playlist_id = 701") }
            check("the index drops it and its song list", !source.rowTitles.contains("Lakeside") && lakesideItems == 0
                  && source.scope == .playlist(802), "\(source.rowTitles)")

            source.select(.playlist(501))
            let folderRow = table.selectedRow
            source.showDeleted(501)
            let gone: [Int64] = [501, 511, 512, 803, 804]
            await snapshot("P02_folder_deleted.png", of: source)
            try await index.apply(.deleted(501))
            let left = try await index.playlists().map(\.id)
            let orphans = try await index.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM playlist_item WHERE playlist_id IN (511, 512)") }
            let open = UserDefaults.standard.array(forKey: "OldTunes.SourceList.expandedFolders") as? [NSNumber] ?? []
            check("deleting a folder takes everything in it, selects the next row, and forgets the folder was open",
                  table.selectedRow == folderRow && source.scope == .playlist(601) && Set(left).isDisjoint(with: gone)
                  && left.count == 5 && orphans == 0 && !open.contains(NSNumber(value: Int64(501))),
                  "left \(left), scope \(source.scope), open \(open)")

            await source.reload()
            source.select(.playlist(801))
            let lastRow = table.selectedRow
            source.showDeleted(801)
            check("deleting the last row selects the one above", lastRow == source.rowTitles.count && table.selectedRow == lastRow - 1,
                  "was \(lastRow), now \(table.selectedRow)")
            source.beginRename(702)
            source.showDeleted(702)
            check("deleting a playlist mid-rename closes its name box", source.renameField == nil)
        } catch {
            check("index edits", false, "\(error)")
        }
    }
}

/// What the open menu showed, read from inside its tracking loop.
@MainActor
private final class MenuSeen {
    var text = ""
}

/// Claims to be key, so the field editor and the focused look work while the bench runs behind
/// whatever Noah has in front (see HarnessWindow in ListsHarness.swift).
private final class PlaylistBenchWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}

private final class PlaylistBenchBackdrop: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        Theme.metal.draw(in: bounds, angle: 0)
    }
}
