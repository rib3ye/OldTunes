import AppKit
import GRDB

/// HARNESS ONLY: ListsPlaylistBench's checks for adding songs to playlists (RESEARCH.md §6.10).
/// The track pane's Add to Playlist ▸; what a drag puts on its pasteboard and the picture it
/// shows; drops through the source list's own data-source methods, with a stand-in for AppKit's
/// NSDraggingInfo and the bench's own named pasteboard (never a real drag session, never the
/// general pasteboard), and what makes AppKit send the list a real one; the drop outline in
/// pixels at 1x and 2x, by day and by night; `.songsAdded`, the library change it posts and the
/// re-ingest race on a scratch index of their own; and AppController's add plan, its chunks and
/// wording, with the editor's choice after a song fails. Invented songs and playlists only.
extension ListsPlaylistBench {

    // MARK: The track pane

    /// The track list on Library, by name, with every row loaded: the menus' "may have" rules
    /// only look at loaded rows. Returns the rows in the list's order, or nil (a failed check)
    /// when they aren't the invented ones: the two folder songs, then Invented Song 1…8.
    func showLibrary(_ tracks: TrackListViewController, index: LibraryIndex) async -> [Track]? {
        tracks.setScope(.library, sort: TrackSort(field: .name, ascending: true))
        await tracks.waitForLoad()
        await tracks.waitForRows()
        window?.layoutIfNeeded()
        window?.displayIfNeeded()
        let rows = (try? await index.tracks(ids: tracks.order)) ?? []
        let want = ["Invented Folder Song 1", "Invented Folder Song 2"] + (1...8).map { "Invented Song \($0)" }
        guard rows.map(\.title) == want else {
            check("the track pane lists the invented songs by name", false, "\(rows.map(\.title))")
            return nil
        }
        return rows
    }

    /// Only rows the table has: a row past its end would raise.
    func select(_ table: NSTableView, _ rows: [Int]) {
        table.selectRowIndexes(IndexSet(rows.filter { $0 >= 0 && $0 < table.numberOfRows }), byExtendingSelection: false)
    }

    // MARK: Add to Playlist ▸

    /// The row menu and its Add to Playlist ▸ submenu, built as a right-click builds them.
    func trackMenuChecks(_ source: SourceListViewController, tracks: TrackListViewController, index: LibraryIndex,
                         in window: NSWindow) async {
        let table = tracks.tableView
        guard let rows = await showLibrary(tracks, index: index) else { return }
        check("the track pane lists the invented songs by name", true, "\(rows.count) rows")
        func row(_ title: String) -> Int { rows.firstIndex { $0.title == title } ?? -1 }
        let cloud1 = row("Invented Song 1"), cloud3 = row("Invented Song 3")
        let folder1 = row("Invented Folder Song 1"), folder2 = row("Invented Folder Song 2")
        func submenu(_ menu: NSMenu?) -> NSMenu? { menu?.items.first { $0.title == "Add to Playlist" }?.submenu }

        select(table, [cloud1])
        var menu = rightClick(table, row: cloud1, in: window)
        check("a song's menu: Play, Get Info, —, Download, Add to Playlist ▸, —, Show in Finder",
              Self.describe(menu) == "Play, Get Info, —, Download, Add to Playlist▸, —, Show in Finder(off)", Self.describe(menu))
        let sub = submenu(menu)
        let folder = sub?.items.first { $0.title == "Road Mixes" }?.submenu
        check("Add to Playlist ▸: New Playlist, then the plain playlists, a folder as a submenu; smart ones left out",
              Self.describe(sub) == "New Playlist, —, Road Mixes▸, Lakeside, Workout" && Self.describe(folder) == "Drive Home, Late Shift",
              "\(Self.describe(sub)); Road Mixes ▸ \(Self.describe(folder))")
        let items = (sub?.items ?? []) + (folder?.items ?? [])
        check("…built whole when the row menu opens: no delegate and no automatic enabling on either, every item aimed at the list",
              sub?.delegate == nil && folder?.delegate == nil && sub?.autoenablesItems == false && folder?.autoenablesItems == false
              && items.allSatisfy { $0.isSeparatorItem || $0.target === tracks },
              "delegates \(String(describing: sub?.delegate)), \(String(describing: folder?.delegate))")

        select(table, [cloud3, cloud1])
        menu = rightClick(table, row: cloud3, in: window)
        perform(submenu(menu)?.items.first { $0.title == "Road Mixes" }?.submenu?.items.first { $0.title == "Drive Home" })
        let both = [rows[cloud1].id, rows[cloud3].id]
        check("choosing a playlist asks with the selection in row order and that playlist's id",
              addAsks.last.map { $0.ids == both && $0.playlist == 511 } == true, "\(addAsks)")
        perform(submenu(menu)?.items.first)
        check("…and its New Playlist asks for a new playlist with them", newPlaylistAsks.last == both, "\(newPlaylistAsks)")

        select(table, [folder1, folder2])
        menu = rightClick(table, row: folder1, in: window)
        let add = menu?.items.first { $0.title == "Add to Playlist" }
        check("songs only in OldTunes: Add to Playlist stays on (the add then explains), its New Playlist is off",
              add?.isEnabled == true && submenu(menu)?.items.first?.isEnabled == false && !tracks.selectionMayHaveMusicSongs,
              Self.describe(submenu(menu)))
        select(table, [folder1, cloud1])
        check("…a Music song among them turns New Playlist from Selection back on", tracks.selectionMayHaveMusicSongs)

        tracks.setScope(.playlist(702), sort: nil)
        await tracks.waitForLoad()
        await tracks.waitForRows()
        select(table, [0])
        let leftOut = submenu(rightClick(table, row: 0, in: window))
        tracks.setScope(.playlist(511), sort: nil)
        await tracks.waitForLoad()
        await tracks.waitForRows()
        select(table, [0])
        let inFolder = submenu(rightClick(table, row: 0, in: window))?.items.first { $0.title == "Road Mixes" }?.submenu
        check("the playlist being shown is left out, as a drop on it is refused, inside a folder too",
              Self.describe(leftOut) == "New Playlist, —, Road Mixes▸, Lakeside" && Self.describe(inFolder) == "Late Shift",
              "showing Workout: \(Self.describe(leftOut)); showing Drive Home: Road Mixes ▸ \(Self.describe(inFolder))")
        _ = await showLibrary(tracks, index: index)

        table.deselectAll(nil)
        menu = rightClick(table, row: nil, in: window)
        check("nothing selected (a right-click below the rows): every song command is off",
              Self.describe(menu) == "Play(off), Get Info(off), —, Download(off), Add to Playlist(off)▸, —, Show in Finder(off)",
              Self.describe(menu))

        // The list prunes what it is given again: what can't take songs never reaches the menu.
        tracks.playlistMenu = { Self.unprunedTree }
        select(table, [cloud1])
        let pruned = submenu(rightClick(table, row: cloud1, in: window))
        let nested = pruned?.items.first { $0.title == "Nested" }?.submenu
        let inner = nested?.items.first?.submenu
        check("smart and Genius playlists, and folders with no plain playlist in them, never reach the menu",
              Self.describe(pruned) == "New Playlist, —, Nested▸, Lakeside" && Self.describe(nested) == "Inner▸"
              && Self.describe(inner) == "Deep", "\(Self.describe(pruned)); Nested ▸ \(Self.describe(nested)) ▸ \(Self.describe(inner))")
        tracks.playlistMenu = { [] }
        let none = submenu(rightClick(table, row: cloud1, in: window))
        check("with no plain playlist at all, New Playlist alone, no separator", Self.describe(none) == "New Playlist", Self.describe(none))
        tracks.playlistMenu = { [weak source] in source?.playlistTree ?? [] }

        let asks = (tracks.onDownload, tracks.onAddToPlaylist, tracks.onNewPlaylistFromSelection)
        tracks.onDownload = nil
        tracks.onAddToPlaylist = nil
        tracks.onNewPlaylistFromSelection = nil
        menu = rightClick(table, row: cloud1, in: window)
        check("with nobody to ask, Download and Add to Playlist are off",
              menu?.items.first { $0.title == "Download" }?.isEnabled == false
              && menu?.items.first { $0.title == "Add to Playlist" }?.isEnabled == false, Self.describe(menu))
        (tracks.onDownload, tracks.onAddToPlaylist, tracks.onNewPlaylistFromSelection) = asks
    }

    /// What a source list could hand the track list if it didn't prune: a folder holding only a
    /// smart playlist, an empty folder, folders nested two deep, Genius and smart playlists.
    static let unprunedTree: [PlaylistMenuEntry] = {
        func entry(_ id: Int64, _ name: String, _ kind: PlaylistInfo.Kind, parent: Int64? = nil,
                   _ children: [PlaylistMenuEntry] = []) -> PlaylistMenuEntry {
            PlaylistMenuEntry(playlist: PlaylistInfo(id: id, name: name, kind: kind, parentID: parent, trackCount: 0), children: children)
        }
        return [
            entry(520, "Only Smart", .folder, [entry(521, "Smart Child", .smart, parent: 520)]),
            entry(530, "Empty Folder", .folder),
            entry(540, "Nested", .folder, [entry(541, "Inner", .folder, parent: 540, [entry(542, "Deep", .regular, parent: 541)])]),
            entry(601, "Fresh Picks", .smart),
            entry(650, "Genius Mix", .genius),
            entry(701, "Lakeside", .regular),
        ]
    }()

    // MARK: Dragging songs

    /// What a drag of songs carries, and the picture it shows. NSTableView asks the data source
    /// for one writer per dragged row and keeps them in row order on the drag pasteboard; the
    /// bench writes them to its own named one instead.
    func dragChecks(_ tracks: TrackListViewController, pasteboard: NSPasteboard, in window: NSWindow) async {
        let table = tracks.tableView
        let order = tracks.order
        guard let data = table.dataSource, order.count == 10 else {
            check("dragging: the track pane shows the ten invented songs", false, "\(order.count) rows")
            return
        }
        let writer = data.tableView?(table, pasteboardWriterForRow: 2) as? NSPasteboardItem
        check("a dragged row writes its song's id under OldTunes's own type, and nothing else: no file, no text",
              writer?.types == [.oldTunesSongs] && writer?.string(forType: .oldTunesSongs) == order.dropFirst(2).first.map { String($0) },
              "types \(writer?.types.map(\.rawValue) ?? [])")
        check("no writer past the last row", data.tableView?(table, pasteboardWriterForRow: order.count) == nil)
        check("a vertical drag still extends the selection; only a sideways one drags",
              table.verticalMotionCanBeginDrag == false)

        pasteboard.clearContents()
        pasteboard.writeObjects([4, 0, 8].compactMap { data.tableView?(table, pasteboardWriterForRow: $0) })
        let read = SongDrag.ids(on: pasteboard)
        check("the pasteboard gives back the dragged songs in the order the rows were written",
              read == [order[4], order[0], order[8]], "\(read)")
        let text = NSPasteboardItem()
        text.setString("not a song", forType: .string)
        pasteboard.clearContents()
        pasteboard.writeObjects([SongDrag.item(for: 7), text, SongDrag.item(for: 3), SongDrag.item(for: 7)])
        check("…repeats kept, and an item of some other kind skipped", SongDrag.ids(on: pasteboard) == [7, 3, 7],
              "\(SongDrag.ids(on: pasteboard))")

        // The picture: the dragged row is selected, and the selected look's white text would
        // vanish over the white lists, so it must be the unselected one.
        select(table, [2])
        let artist = table.column(withIdentifier: TrackColumn.artist.identifier)
        for (name, look) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: look)
            await settle()
            window.displayIfNeeded()
            let rect = table.rect(ofRow: 2)
            guard let picture = tracks.draggingImage(forRow: 2),
                  let rep = picture.image.representations.first as? NSBitmapImageRep else {
                check("\(name): a dragged row on screen has a picture", false)
                continue
            }
            // Its Artist text, which is all text: as dark as the list's text by day, as light by
            // night; never the selection's white.
            let text = resolved(Theme.textPrimary, in: window), background = resolved(Theme.listBG, in: window)
            let cell = table.frameOfCell(atColumn: artist, row: 2).offsetBy(dx: -picture.frame.minX, dy: -picture.frame.minY)
            let scale = CGFloat(rep.pixelsWide) / picture.image.size.width
            var strongest: PlaylistBenchPixel?, inked = 0, maxAlpha = 0.0
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    guard let p = sample(rep, x: x, y: y), p.a > 0 else { continue }
                    maxAlpha = max(maxAlpha, p.a)
                    guard cell.contains(NSPoint(x: (CGFloat(x) + 0.5) / scale, y: (CGFloat(y) + 0.5) / scale)), p.a > 0.5 else { continue }
                    if p.distance(to: background) >= 80 { inked += 1 }
                    if strongest.map({ p.distance(to: background) > $0.distance(to: background) }) ?? true { strongest = p }
                }
            }
            let miss = strongest.map { $0.distance(to: text) } ?? 999
            check("\(name): a dragged row's picture is its on-screen part, drawn unselected, at 75%",
                  picture.frame.minY == rect.minY && picture.frame.height == rect.height
                  && picture.image.size == picture.frame.size && abs(scale - window.backingScaleFactor) < 0.01
                  && inked >= 20 && miss <= 24 && (0.7...0.8).contains(maxAlpha),
                  "frame \(picture.frame) for row \(rect), \(rep.pixelsWide)×\(rep.pixelsHigh) px; Artist text "
                  + "\(strongest?.hex ?? "none") (the list's text is \(text.hex)), \(inked) inked pixels; most opaque \(String(format: "%.2f", maxAlpha))")
        }
        window.appearance = nil
        check("no picture for a row that isn't there",
              tracks.draggingImage(forRow: -1) == nil && tracks.draggingImage(forRow: order.count) == nil)
        // The bitmap itself, at both scales whatever the screen is.
        let sizes = [1, 2].compactMap { (scale: CGFloat) -> String? in
            let image = SongDrag.picture(size: NSSize(width: 120, height: 17), scale: scale, appearance: window.effectiveAppearance) {
                Theme.textPrimary.setFill()
                NSRect(x: 0, y: 0, width: 120, height: 17).fill()
            }
            guard let rep = image?.representations.first as? NSBitmapImageRep, let p = sample(rep, x: 3, y: 3) else { return nil }
            return "\(rep.pixelsWide)×\(rep.pixelsHigh)@\(String(format: "%.2f", p.a))"
        }
        check("SongDrag.picture draws at the scale asked for, clear behind, at 75%",
              sizes == ["120×17@0.75", "240×34@0.75"], "\(sizes)")
    }

    // MARK: Dropping songs on a playlist

    /// Drops as AppKit makes them: the source list's own validateDrop and acceptDrop, through
    /// its data source, with the pointer over a row in window coordinates.
    func dropChecks(_ source: SourceListViewController, tracks: TrackListViewController, pasteboard: NSPasteboard,
                    in window: NSWindow) async {
        let table = source.tableView
        guard let data = table.dataSource, tracks.order.count > 4 else { return }
        // The checks below hand their drags to the list's data source themselves. What makes
        // AppKit send it a real one: the list registered for OldTunes's songs, and the track
        // list's drags allowed inside OldTunes and nowhere else, as the tables have them now.
        let inside = dragMask(tracks.tableView, local: true), outside = dragMask(tracks.tableView, local: false)
        check("the source list takes OldTunes's songs, and the track list's drags copy them inside OldTunes and go nowhere else",
              table.registeredDraggedTypes.contains(.oldTunesSongs) && inside == .copy && outside == []
              && inside == TrackListViewController.songDragInside && outside == TrackListViewController.songDragOutside,
              "registered \(table.registeredDraggedTypes.map(\.rawValue)); masks \(inside?.rawValue ?? 999) inside, "
              + "\(outside?.rawValue ?? 999) outside")
        source.select(.library)
        await settle()
        // Row views exist only once the table is laid out after its last reload; the outline is
        // read from them.
        window.layoutIfNeeded()
        window.displayIfNeeded()
        table.layoutSubtreeIfNeeded()
        let ids = [tracks.order[4], tracks.order[2], tracks.order[3], tracks.order[2]]
        func write() {
            pasteboard.clearContents()
            pasteboard.writeObjects(ids.map(SongDrag.item(for:)))
        }
        write()
        func row(_ id: Int64) -> Int { source.rowScopes.firstIndex(of: .playlist(id)) ?? -1 }
        /// `row` nil: the empty space below the rows. `dy`: down from the row's middle.
        func over(_ row: Int?, dy: CGFloat = 0) -> PlaylistBenchDrag {
            let local: NSPoint
            if let row, row >= 0 {
                let r = table.rect(ofRow: row)
                local = NSPoint(x: r.midX, y: r.midY + dy)
            } else {
                local = NSPoint(x: 40, y: table.rect(ofRow: table.numberOfRows - 1).maxY + 30)
            }
            return PlaylistBenchDrag(pasteboard, at: table.convert(local, to: nil))
        }
        /// What AppKit proposes is a drop above the row nearest the pointer; the list goes by the
        /// pointer instead.
        func validate(_ row: Int?, dy: CGFloat = 0) -> NSDragOperation {
            let proposed = (row ?? table.numberOfRows) + (dy > 0 ? 1 : 0)
            return data.tableView?(table, validateDrop: over(row, dy: dy), proposedRow: max(proposed, 0),
                                   proposedDropOperation: .above) ?? []
        }
        func accept(_ row: Int) -> Bool {
            data.tableView?(table, acceptDrop: over(row), row: row, dropOperation: .on) ?? false
        }
        func outlined() -> [Int] {
            var found: [Int] = []
            table.enumerateAvailableRowViews { view, row in if (view as? SourceRowView)?.isDropTarget == true { found.append(row) } }
            return found
        }
        func target() -> String { source.dropTargetID.map(String.init) ?? "none" }

        let changes = scopeChanges
        var op = validate(row(702))
        check("songs over a plain playlist: a copy, outlined on that row only, and the selection stays put",
              op == .copy && source.dropTargetID == 702 && outlined() == [row(702)] && source.scope == .library,
              "operation \(op.rawValue), target \(target()), outlined rows \(outlined())")
        op = validate(row(702), dy: 8)
        check("…near its lower edge, where AppKit proposes a drop above the next row, still that playlist",
              op == .copy && source.dropTargetID == 702, "operation \(op.rawValue), target \(target())")
        for (name, r) in [("a smart playlist", row(602)), ("a folder", row(501)), ("Library", 0), ("On This Mac", 1),
                          ("the empty space below the rows", nil)] as [(String, Int?)] {
            op = validate(r)
            check("songs over \(name): refused, and no outline", op == [] && source.dropTargetID == nil && outlined().isEmpty,
                  "operation \(op.rawValue), target \(target()), outlined rows \(outlined())")
        }
        source.select(.playlist(701))
        op = validate(row(701))
        check("songs over the playlist being shown: refused (its songs are the ones in the list)",
              op == [] && source.dropTargetID == nil, "operation \(op.rawValue), target \(target())")
        source.select(.library)
        let selected = scopeChanges

        _ = validate(row(701))
        let accepted = accept(row(701))
        check("a drop hands over the songs in the order dragged, repeats kept, and the playlist as the list shows it",
              accepted && drops.last.map { $0.ids == ids && $0.playlist.id == 701 && $0.playlist.name == "Lakeside" } == true
              && source.dropTargetID == nil && outlined().isEmpty,
              "accepted \(accepted), last drop \(drops.last.map { "\($0.ids) on \($0.playlist.name)" } ?? "none")")
        check("…and drags never change which list is shown", scopeChanges == selected && changes + 2 == selected,
              "\(scopeChanges - selected) selection changes during drops")

        let handler = source.onAddSongs
        source.onAddSongs = nil
        op = validate(row(702))
        let unhandled = accept(row(702))
        source.onAddSongs = handler
        check("with nobody to hand the songs to, a drop is refused", op == [] && !unhandled && source.dropTargetID == nil,
              "operation \(op.rawValue)")
        pasteboard.clearContents()
        pasteboard.setString("not songs", forType: .string)
        op = validate(row(702))
        check("a drag without OldTunes's songs type is refused", op == [] && source.dropTargetID == nil, "operation \(op.rawValue)")
        write()

        // Rows rebuilt under the drag: Road Mixes opens, and the rows below it move down two.
        let before = row(702)
        _ = validate(before)
        source.setExpanded(501, true)
        // The table makes the moved rows' views in its next layout pass, which layoutIfNeeded,
        // displayIfNeeded and layoutSubtreeIfNeeded don't bring on; tile() and layout() do. The
        // list marks each one as it is made (rowViewForRow, didAdd), so they are read after.
        await settle()
        table.tile()
        table.layout()
        window.displayIfNeeded()
        let after = row(702)
        check("rows rebuilt during a drag: the outline stays on the same playlist, now two rows down",
              after == before + 2 && source.dropTargetID == 702 && outlined() == [after],
              "Workout row \(before) → \(after), target \(target()), outlined rows \(outlined())")
        let dropped = drops.count
        let movedOK = accept(before)   // AppKit hands back the row validateDrop set, stale now
        check("…and the drop still goes to that playlist, found again by its id",
              movedOK && drops.count == dropped + 1 && drops.last?.playlist.id == 702, "accepted \(movedOK)")
        source.setExpanded(501, false)

        _ = validate(row(701))
        source.showDeleted(701)
        let goneOK = accept(3)
        check("a playlist deleted since the drag reached it takes nothing",
              !goneOK && drops.count == dropped + 1 && source.dropTargetID == nil, "accepted \(goneOK)")
        await source.reload()

        _ = validate(row(702))
        table.draggingExited(nil)
        check("a drag that leaves the list takes the outline down", source.dropTargetID == nil && outlined().isEmpty,
              "target \(target()), outlined rows \(outlined())")
    }

    /// The drag operations `table` allows inside OldTunes (`local`) or outside it, as set with
    /// `setDraggingSourceOperationMask`, outside any drag. NSTableView answers them through
    /// `draggingSourceOperationMaskForLocal:`, whose Swift name is deprecated (it would warn), so
    /// by selector. Nil if the table doesn't answer it.
    private func dragMask(_ table: NSTableView, local: Bool) -> NSDragOperation? {
        let selector = NSSelectorFromString("draggingSourceOperationMaskForLocal:")
        guard table.responds(to: selector), let imp = table.method(for: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector, ObjCBool) -> UInt
        return NSDragOperation(rawValue: unsafeBitCast(imp, to: Getter.self)(table, selector, ObjCBool(local)))
    }

    // MARK: The drop outline, in pixels

    /// The outline round a playlist while songs are over it, rendered at 1x and 2x by day and by
    /// night. The pictures also hold the track pane's checked boxes and sorted Name header, the
    /// blues Noah judges a new blue beside (RESEARCH.md §7.7).
    func dropOutlineLooks(_ source: SourceListViewController, pasteboard: NSPasteboard, in window: NSWindow) async {
        let table = source.tableView
        guard let content = window.contentView, let data = table.dataSource else { return }
        source.select(.library)
        func row(_ id: Int64) -> Int { source.rowScopes.firstIndex(of: .playlist(id)) ?? -1 }
        let target = row(701), other = row(702)
        pasteboard.clearContents()
        pasteboard.writeObjects([SongDrag.item(for: 1)])
        let r = table.rect(ofRow: target)
        let drag = PlaylistBenchDrag(pasteboard, at: table.convert(NSPoint(x: r.midX, y: r.midY), to: nil))
        _ = data.tableView?(table, validateDrop: drag, proposedRow: target, proposedDropOperation: .on)
        for (name, look) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: look)
            await settle()
            window.layoutIfNeeded()
            window.displayIfNeeded()
            let outline = resolved(ListsPalette.sourceDropOutline, in: window), background = resolved(Theme.listBG, in: window)
            for scale in [1, 2] as [CGFloat] {
                guard let rep = render(content, scale: scale) else {
                    check("\(name) \(Int(scale))x: the window renders", false)
                    continue
                }
                let file = "P03_drop_outline_\(name)_\(Int(scale))x.png"
                save(rep, file)
                let t = table.rect(ofRow: target), o = table.rect(ofRow: other)
                // Right of the names, clear of the icon: only the outline's top and bottom pass here.
                let x = min(t.maxX, table.visibleRect.maxX) - 24
                func miss(_ ys: [CGFloat], _ want: PlaylistBenchPixel) -> Double {
                    ys.compactMap { pixel(rep, at: NSPoint(x: x, y: $0), in: table, of: content) }.map { $0.distance(to: want) }.min() ?? 999
                }
                let top = miss([t.minY + 0.5, t.minY + 1.5], outline), bottom = miss([t.maxY - 1.5, t.maxY - 0.5], outline)
                let plain = [o.minY + 0.5, o.minY + 1.5, o.maxY - 1.5, o.maxY - 0.5]
                    .compactMap { pixel(rep, at: NSPoint(x: x, y: $0), in: table, of: content) }.map { $0.distance(to: background) }
                check("\(name) \(Int(scale))x: the drop outline runs along the playlist's row in the accent blue, and nowhere else",
                      top <= 8 && bottom <= 8 && plain.count == 4 && (plain.max() ?? 999) <= 3,
                      "\(outline.hex) off by \(Int(top)) at the top, \(Int(bottom)) at the bottom; the next row's edges "
                      + "\(plain.map { Int($0) }) from the list's \(background.hex); \(file)")
            }
        }
        window.appearance = nil
        table.draggingExited(nil)
        await settle()
    }

    // MARK: Index edits on a scratch index of their own

    /// `.songsAdded`, and a re-ingest that read Music's playlists before an edit landed. The
    /// first fixture's index keeps its own state for indexChecks; this one is made and dropped here.
    func addIndexChecks() async {
        let url = outDir.appendingPathComponent("playlist-bench-adds.sqlite")
        removeIndex(at: url)
        defer { removeIndex(at: url) }
        do {
            let index = try LibraryIndex(path: url)
            _ = try await index.replaceMusicLibrary(Self.songsForAdds, playlists: Self.playlistsForAdds)

            // The tree the track list's Add to Playlist ▸ menu is built from.
            let side = SourceListViewController(library: index)
            _ = side.view
            await side.reload()
            check("Add to Playlist ▸'s tree: plain playlists inside the folders holding one, open or not; smart and Genius playlists and empty folders left out",
                  Self.flat(side.playlistTree) == "Road Mixes[Drive Home], Nested[Inner[Deep]], Lakeside, Workout",
                  Self.flat(side.playlistTree))

            func entries(_ playlist: Int64) async throws -> [(pid: Int64, position: Int)] {
                try await index.pool.read { db in
                    try Row.fetchAll(db, sql: """
                        SELECT s.persistent_id, pi.position FROM playlist_item pi JOIN song s ON s.id = pi.song_id
                        WHERE pi.playlist_id = ? ORDER BY pi.position
                        """, arguments: [playlist]).map { row -> (pid: Int64, position: Int) in (row[0], row[1]) }
                }
            }
            func number(_ sql: String) async throws -> Int {
                try await index.pool.read { try Int.fetchOne($0, sql: sql) } ?? -1
            }
            let idOf = try await index.pool.read { db in
                Dictionary(try Row.fetchAll(db, sql: "SELECT persistent_id, id FROM song").map { ($0[0] as Int64, $0[1] as Int64) },
                           uniquingKeysWith: { first, _ in first })
            }
            let hashSQL = "SELECT COUNT(*) FROM meta WHERE key = 'playlists_hash'"
            // What each edit's library change says (LibraryChange.songsAddedTo), for what
            // AppController reloads after it (`changeReload`).
            let posts = ChangeNotes()
            let watcher = NotificationCenter.default.addObserver(forName: .libraryDidChange, object: nil, queue: nil) { note in
                let filled = note.userInfo?[LibraryChange.songsAddedTo] as? Int64, said = note.userInfo != nil
                MainActor.assumeIsolated {
                    posts.seen.append(filled.map { "songs added to \($0)" } ?? (said ? "something else" : "nothing said"))
                }
            }
            defer { NotificationCenter.default.removeObserver(watcher) }

            let hashBefore = try await number(hashSQL)
            let stampBefore = try await index.playlistEditStamp()
            try await index.apply(.songsAdded(701, persistentIDs: [1004, 1001, 9999, 1004]))
            let lakeside = try await entries(701)
            let count = try await number("SELECT track_count FROM playlist WHERE id = 701")
            let hashAfter = try await number(hashSQL)
            let stampAfter = try await index.playlistEditStamp()
            let order = try await index.ids(for: TrackQuery(scope: .playlist(701), sort: TrackSort(field: .playlistOrder, ascending: true)))
            check(".songsAdded appends after the last entry in the order Music took them, repeats kept; an ID no song has leaves a gap",
                  lakeside.map(\.pid) == [1001, 1003, 1001, 1004, 1001, 1004] && lakeside.map(\.position) == [0, 1, 2, 3, 4, 6],
                  "\(lakeside.map { "\($0.pid)@\($0.position)" })")
            check("…track_count counts every entry, as ingest does; the next re-ingest will rewrite the playlists; the edit counts",
                  count == 6 && hashBefore == 1 && hashAfter == 0 && stampAfter == stampBefore + 1,
                  "track_count \(count), hash rows \(hashBefore) → \(hashAfter), stamp \(stampBefore) → \(stampAfter)")
            check("…and the playlist's own order lists each song once, at its first place",
                  order == [1001, 1003, 1004].compactMap { idOf[$0] }, "\(order)")
            // Each chunk of an add lands like this: a count changes, which no row of the source list shows.
            let rebuilds = side.rowRebuilds
            await side.reload()
            check("…its library change names the playlist, and the source list doesn't rebuild its rows for it, though it "
                  + "takes the new count",
                  posts.seen == ["songs added to 701"] && side.rowRebuilds == rebuilds && side.playlist(701)?.trackCount == 6,
                  "posted \(posts.seen); \(side.rowRebuilds - rebuilds) rebuilds; count \(side.playlist(701)?.trackCount ?? -1)")

            let smart = try await entries(601)
            try await index.apply(.songsAdded(601, persistentIDs: [1001]))
            try await index.apply(.songsAdded(9999, persistentIDs: [1001]))
            let smartAfter = try await entries(601), strays = try await number("SELECT COUNT(*) FROM playlist_item WHERE playlist_id = 9999")
            check(".songsAdded puts nothing in a smart playlist, nor anywhere for a playlist the index doesn't have",
                  smartAfter.map(\.pid) == smart.map(\.pid) && strays == 0, "smart \(smartAfter.map(\.pid)), \(strays) strays")

            let workout = try await entries(702).count
            try await index.apply(.songsAdded(702, persistentIDs: [Int64.max, Int64.min, Self.bigPID + 1]))
            let extremes = try await entries(702).dropFirst(workout).map(\.pid)
            check("persistent IDs stay exact through the JSON: the largest and smallest 64-bit IDs join; 2^53 + 1 doesn't match 2^53",
                  extremes == [Int64.max, Int64.min], "\(extremes)")

            // A re-ingest reads the stamp, then Music's playlists; an add lands before it writes.
            let read = try await index.playlistEditStamp()
            try await index.apply(.songsAdded(702, persistentIDs: [1003]))
            let applied = try await entries(702).map(\.pid)
            let stale = try await index.replaceMusicLibrary(Self.songsForAdds, playlists: Self.playlistsForAdds, playlistStamp: read)
            let kept = try await entries(702).map(\.pid), staleHash = try await number(hashSQL)
            check("a re-ingest whose snapshot may be older than an edit leaves the playlists as edited and stores no hash",
                  stale.playlistsStale && !stale.playlistsRewritten && kept == applied && staleHash == 0
                  && stale.unchanged == Self.songsForAdds.count,
                  "stale \(stale.playlistsStale), rewritten \(stale.playlistsRewritten), Workout \(kept.count) entries, hash rows \(staleHash)")
            let editedAt = try await index.pool.read { db in
                try Double.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'playlist_edited_at'") ?? 0
            }
            let afterEdit = try await index.playlistEditStamp()
            let lagging = try await index.replaceMusicLibrary(Self.songsForAdds, playlists: Self.playlistsForAdds,
                                                              playlistStamp: afterEdit,
                                                              playlistReadStarted: Date(timeIntervalSince1970: editedAt + 1))
            let keptAfterEdit = try await entries(702).map(\.pid)
            let laggingHash = try await number(hashSQL)
            check("a refresh that starts after an edit still keeps its songs while Music's snapshot settles",
                  lagging.playlistsStale && !lagging.playlistsRewritten && keptAfterEdit == applied && laggingHash == 0)
            // Even if the write happens well after the window, it is the read's start that matters.
            try await index.pool.write { db in
                try db.execute(sql: "UPDATE meta SET value = ? WHERE key = 'playlist_edited_at'", arguments: [editedAt - 60])
            }
            let slow = try await index.replaceMusicLibrary(Self.songsForAdds, playlists: Self.playlistsForAdds,
                                                           playlistStamp: afterEdit,
                                                           playlistReadStarted: Date(timeIntervalSince1970: editedAt - 51))
            check("a slow snapshot that began inside the settling window cannot overwrite the edit after the window ends",
                  slow.playlistsStale && !slow.playlistsRewritten)
            let fresh = try await index.replaceMusicLibrary(Self.songsForAdds, playlists: Self.playlistsForAdds,
                                                            playlistStamp: afterEdit,
                                                            playlistReadStarted: Date(timeIntervalSince1970: editedAt - 50))
            let lakesideAgain = try await entries(701).map(\.pid), workoutAgain = try await entries(702).map(\.pid)
            let freshHash = try await number(hashSQL)
            check("at the settling boundary, Music's snapshot wins even if it rolled back the edit; the hash is stored again",
                  fresh.playlistsRewritten && !fresh.playlistsStale && lakesideAgain == [1001, 1003, 1001]
                  && workoutAgain == [1002, 1004, 1006] && freshHash == 1,
                  "rewritten \(fresh.playlistsRewritten), Lakeside \(lakesideAgain), Workout \(workoutAgain), hash rows \(freshHash)")
            try await index.apply(.songsAdded(701, persistentIDs: [1002]))
            let unstamped = try await index.replaceMusicLibrary(Self.songsForAdds, playlists: Self.playlistsForAdds)
            let lakesideNow = try await entries(701).map(\.pid)
            check("without a stamp (the benches' calls), a re-ingest writes the playlists as it always has",
                  unstamped.playlistsRewritten && !unstamped.playlistsStale && lakesideNow == [1001, 1003, 1001],
                  "rewritten \(unstamped.playlistsRewritten), Lakeside \(lakesideNow)")

            // Any other edit: a change that says nothing (everything reloads), and a row that looks new.
            await side.reload()
            posts.seen.removeAll()
            let rebuildsBefore = side.rowRebuilds
            try await index.apply(.renamed(702, to: "Workout Again"))
            await side.reload()
            check("any other playlist edit posts a library change that says nothing, and the source list rebuilds the row "
                  + "that now shows something else",
                  posts.seen == ["nothing said"] && side.rowRebuilds == rebuildsBefore + 1 && side.rowTitles.contains("Workout Again"),
                  "posted \(posts.seen); \(side.rowRebuilds - rebuildsBefore) rebuilds; \(side.rowTitles)")

            // ⌘N, or ⇧⌘N, right after launch, before a list has read the playlists: the name it
            // picks must be one Music doesn't have yet, so the list reads them first, once.
            let unread = SourceListViewController(library: index)
            let early = unread.unusedName("Lakeside")
            await unread.loadIfNeeded()
            let named = unread.unusedName("Lakeside")
            try await index.apply(.added(PlaylistInfo(id: 990, name: "Lakeside 2", kind: .regular, parentID: nil, trackCount: 0),
                                         songsFrom: nil))
            await unread.loadIfNeeded()
            check("a list that hasn't read the playlists yet reads them before a new playlist's name is picked (loadIfNeeded), "
                  + "and only the first time",
                  early == "Lakeside" && named == "Lakeside 2" && unread.playlistCount == Self.playlistsForAdds.count
                  && unread.unusedName("Lakeside") == "Lakeside 2", "unread: “\(early)”, read: “\(named)”")
            await failedReadChecks(over: index, taken: "Lakeside")

            try await index.apply(.songsRemoved(701, persistentIDs: [1001]))
            try await index.apply(.deleted(501))
            // Reopening the same database must keep the window, including across app relaunch.
            let reopened = try LibraryIndex(path: index.url)
            let lastEdit = try await reopened.pool.read { db in
                try Double.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'playlist_edited_at'") ?? 0
            }
            var downloaded = Self.songsForAdds
            downloaded[0] = Self.downloaded(downloaded[0], as: .local)
            let held = try await reopened.replaceMusicLibrary(downloaded, playlists: Self.playlistsForAdds,
                                                              playlistStamp: try await reopened.playlistEditStamp(),
                                                              playlistReadStarted: Date(timeIntervalSince1970: lastEdit + 1))
            let heldLists = try await reopened.playlists()
            let heldEntries = try await entries(701).map(\.pid)
            check("settling survives reopening and protects renames, new playlists, removals and deleted folders",
                  held.playlistsStale && heldLists.contains { $0.id == 702 && $0.name == "Workout Again" }
                  && heldLists.contains { $0.id == 990 } && !heldLists.contains { $0.id == 501 || $0.parentID == 501 }
                  && heldEntries == [1003])
            check("playlist settling still ingests a completed download and supplies a bounded retry delay",
                  held.updated == 1 && held.changedIndex && held.playlistRetryAfter > 0
                  && held.playlistRetryAfter <= LibraryIndex.playlistSettleSeconds)
            let settled = try await reopened.replaceMusicLibrary(downloaded, playlists: Self.playlistsForAdds,
                                                                 playlistStamp: try await reopened.playlistEditStamp(),
                                                                 playlistReadStarted: Date(timeIntervalSince1970: lastEdit + 10))
            check("a read after settling reconciles all playlist edits without delaying song updates",
                  settled.playlistsRewritten && !settled.playlistsStale && settled.updated == 0)
        } catch {
            check("adds on a scratch index of their own", false, "\(error)")
        }
    }

    /// A list whose first read of the playlists failed, as a busy or damaged index's would: that
    /// read doesn't count, so the next loadIfNeeded reads them again, and a new playlist's name is
    /// picked over Music's names rather than over an empty list. `library` has one named `taken`.
    func failedReadChecks(over library: any LibraryReading, taken: String) async {
        let flaky = FlakyPlaylists(library, failing: 1)
        let list = SourceListViewController(library: flaky)
        info("the next “sourcelist: playlists() failed” line is this check's own")
        await list.loadIfNeeded()
        let unread = list.unusedName(taken)
        await list.loadIfNeeded()
        let named = list.unusedName(taken)
        await list.loadIfNeeded()
        let reads = await flaky.reads
        check("…and a first read that failed doesn't count: the next loadIfNeeded reads them again, so the name picked isn't "
              + "one Music has; after a read that worked, no more",
              unread == taken && named != taken && reads == 2, "“\(unread)”, then “\(named)”; \(reads) reads")
    }

    /// 2^53: the first integer a JSON reader working in doubles would get wrong one above.
    static let bigPID: Int64 = 1 << 53

    /// Six invented songs in iCloud, and three whose IDs sit at the edges of what JSON numbers
    /// carry: the largest and smallest 64-bit values, and 2^53.
    static let songsForAdds: [SongRecord] = ((1...6).map { 1000 + Int64($0) } + [Int64.max, Int64.min, bigPID]).enumerated().map { n, pid in
        var r = SongRecord(origin: .musicLibrary)
        r.persistentID = pid
        r.title = "Invented Song \(n + 1)"
        r.artist = "Invented Artist"
        r.album = "Invented Album"
        r.titleSortSource = r.title
        r.artistSortSource = r.artist
        r.albumSortSource = r.album
        r.contentHash = r.computeContentHash()
        return r
    }

    /// Music's order: folders, smart lists, then plain ones; each folder's own anywhere. A folder
    /// holding only a smart playlist, an empty folder, a folder nested in a folder, a Genius one.
    static let playlistsForAdds: [PlaylistRecord] = {
        func list(_ id: Int64, _ name: String, _ kind: PlaylistInfo.Kind, parent: Int64? = nil,
                  _ members: [Int64] = []) -> (PlaylistInfo, [Int64]) {
            (PlaylistInfo(id: id, name: name, kind: kind, parentID: parent, trackCount: members.count), members)
        }
        let lists = [
            list(501, "Road Mixes", .folder),
            list(511, "Drive Home", .regular, parent: 501, [1001, 1002]),
            list(513, "Smart Inside", .smart, parent: 501, [1003]),
            list(520, "Only Smart", .folder),
            list(521, "Smart Child", .smart, parent: 520, [1004]),
            list(530, "Empty Folder", .folder),
            list(540, "Nested", .folder),
            list(541, "Inner", .folder, parent: 540),
            list(542, "Deep", .regular, parent: 541, [1005]),
            list(601, "Fresh Picks", .smart, [1006, 1005]),
            list(650, "Genius Mix", .genius, [1001]),
            list(701, "Lakeside", .regular, [1001, 1003, 1001]),
            list(702, "Workout", .regular, [1002, 1004, 1006]),
        ]
        return lists.enumerated().map { PlaylistRecord(info: $1.0, sortIndex: $0, memberPIDs: $1.1) }
    }()

    // MARK: AppController's add, decided and worded

    /// The pure statics AppController adds songs with: which songs go to Music, the question
    /// before a big add, and the one alert after one.
    func addBuilderChecks() {
        typealias App = AppController
        func song(_ id: Track.ID, origin: Track.Origin = .musicLibrary) -> Track {
            var t = Track.blank(id: id)
            t.origin = origin
            t.persistentID = origin == .folder ? nil : 0x1000 + id
            t.title = "Invented Song \(id)"
            return t
        }
        let plan = App.addSongsPlan(rows: [song(1), song(2, origin: .folder), song(3), song(1), song(4)], members: [3])
        check("the add plan: Music's songs in the order given, once each, none the playlist has; OldTunes-only ones apart",
              plan.send == [0x1001, 0x1004] && plan.oldTunesOnly.map(\.id) == [2] && plan.alreadyThere == 2,
              "send \(plan.send), only in OldTunes \(plan.oldTunesOnly.map(\.id)), already there \(plan.alreadyThere)")
        let onlyOurs = App.addSongsPlan(rows: [song(5, origin: .folder), song(6, origin: .folder)], members: [])
        check("…songs only in OldTunes send nothing, so New Playlist from Selection makes nothing",
              onlyOurs.send.isEmpty && onlyOurs.oldTunesOnly.count == 2, "send \(onlyOurs.send)")

        let big = App.addSongsQuestion(count: 1_234, to: "Lakeside")
        check("an add of more than 500 songs asks first, and explains the wait",
              App.addSongsQuestion(count: 500, to: "Lakeside") == nil && big?.message == "Add 1,234 songs to “Lakeside”?"
              && big?.informative == "Adding this many songs may take a while. Other playlist changes wait until it finishes."
              && App.addSongsQuestion(count: 501, to: nil)?.message == "Add 501 songs to a new playlist?", "\(String(describing: big))")

        check("an add where every song went in (or was there already) says nothing",
              App.addSongsAlert(to: "Lakeside", asked: 9, refused: [], notSent: [], stopReason: nil, oldTunesOnly: []) == nil)
        let some = App.addSongsAlert(to: "Lakeside", asked: 9, refused: [], notSent: [], stopReason: nil, oldTunesOnly: ["F1", "F2"])
        check("OldTunes-only songs: named in the alert, with Add Folder's advice and the step after it",
              some?.message == "2 of the 9 songs weren’t added to “Lakeside”."
              && some?.informative == "2 of these songs are only in OldTunes, so they can’t go in a Music playlist. To give them "
                + "to Music, choose Add Folder to Library again with “Also add to the Music app” on, then add them to “Lakeside” "
                + "once they show up." && some?.details == "F1\nF2", "\(String(describing: some))")
        let one = App.addSongsAlert(to: "Lakeside", asked: 1, refused: [], notSent: [], stopReason: nil, oldTunesOnly: ["F1"])
        check("…one song, said for one",
              one?.message == "The song wasn’t added to “Lakeside”."
              && one?.informative.hasPrefix("This song is only in OldTunes, so it can’t go in a Music playlist. To give it to Music,") == true
              && one?.informative.hasSuffix("then add it to “Lakeside” once it shows up.") == true, "\(String(describing: one))")
        let none = App.addSongsAlert(to: nil, asked: 2, refused: [], notSent: [], stopReason: nil, oldTunesOnly: ["F1", "F2"])
        check("New Playlist from Selection with only OldTunes songs: no playlist made, and why",
              none?.message == "OldTunes couldn’t make a new playlist."
              && none?.informative.hasSuffix("then make the playlist once they show up.") == true, "\(String(describing: none))")
        let stopped = App.addSongsAlert(to: "Lakeside", asked: 9, refused: ["A — r"], notSent: ["B", "C"],
                                        stopReason: MusicPlaylistEditor.musicQuitReason, oldTunesOnly: [])
        check("Music stopping partway: why, what it refused, how to try again, and each list under its heading",
              stopped?.message == "3 of the 9 songs weren’t added to “Lakeside”."
              && stopped?.informative == "Music quit, so OldTunes stopped adding songs. Music didn’t accept one song. To try again, "
                + "add the songs to “Lakeside” again. Songs already in it aren’t added twice."
              && stopped?.details == "Music didn’t accept:\nA — r\n\nNot sent to Music:\nB\nC", "\(String(describing: stopped))")
        let refused = App.addSongsAlert(to: "Lakeside", asked: 2, refused: ["A — r", "B — r"], notSent: [], stopReason: nil, oldTunesOnly: [])
        check("every song refused: “The songs weren’t added”, Music's reasons in the details",
              refused?.message == "The songs weren’t added to “Lakeside”." && refused?.informative == "Music didn’t accept them."
              && refused?.details == "A — r\nB — r", "\(String(describing: refused))")

        // Stops that adding the songs again would only meet again (PlaylistAddReport.retryWontHelp):
        // no advice to try again. A quit, above, still has it. Three songs dropped on a playlist
        // Music takes none into: it turns the first down, and the add stops there (the editor's
        // first-song rule, below), so the other two aren't sent.
        let refusesAll = App.addSongsAlert(to: "Purchased", asked: 3, refused: ["A — Music’s reason."], notSent: ["B", "C"],
                                           stopReason: "\(MusicPlaylistEditor.refusesSongsReason) Music’s reason.",
                                           oldTunesOnly: [], retryWontHelp: true)
        check("a playlist Music takes no songs into: the alert names it in the first line, says “this playlist” after it, "
              + "lists the song Music turned down apart from the ones not sent, and gives no advice to try again",
              refusesAll?.message == "The songs weren’t added to “Purchased”."
              && refusesAll?.informative == "Music doesn’t let songs be added to this playlist. Music’s reason. "
                + "Music didn’t accept one song."
              && refusesAll?.details == "Music didn’t accept:\nA — Music’s reason.\n\nNot sent to Music:\nB\nC",
              "\(String(describing: refusesAll))")
        let withFolderSongs = App.addSongsAlert(to: "Purchased", asked: 5, refused: ["A — Music’s reason."], notSent: ["B", "C"],
                                                stopReason: "\(MusicPlaylistEditor.refusesSongsReason) Music’s reason.",
                                                oldTunesOnly: ["F1", "F2"], retryWontHelp: true)
        check("…and the songs only in OldTunes get Add Folder's advice, but not to add them to that playlist once they show up",
              withFolderSongs?.informative == "Music doesn’t let songs be added to this playlist. Music’s reason. Music didn’t "
                + "accept one song. 2 of these songs are only in OldTunes, so they can’t go in a Music playlist. To give them "
                + "to Music, choose Add Folder to Library again with “Also add to the Music app” on.",
              "\(String(describing: withFolderSongs?.informative))")
        let threeInARow = App.addSongsAlert(to: "Lakeside", asked: 9, refused: ["A — r", "B — r", "C — r"], notSent: ["D", "E"],
                                            stopReason: "\(MusicPlaylistEditor.threeInARowReason) r",
                                            oldTunesOnly: [], retryWontHelp: true)
        check("three refusals in a row: what Music turned down, and no advice to try again either",
              threeInARow?.message == "5 of the 9 songs weren’t added to “Lakeside”."
              && threeInARow?.informative == "Music turned down three songs in a row, so OldTunes stopped adding songs. r "
                + "Music didn’t accept 3 songs."
              && threeInARow?.details == "Music didn’t accept:\nA — r\nB — r\nC — r\n\nNot sent to Music:\nD\nE",
              "\(String(describing: threeInARow))")

        // The song whose `duplicate` Music didn't answer in time: it may still go in, so it isn't
        // missed, and until the next re-read the index can't tell whether it did.
        let late = App.addSongsAlert(to: "Lakeside", asked: 4, refused: [], notSent: ["C", "D"],
                                     stopReason: MusicPlaylistEditor.unansweredReason, oldTunesOnly: [], unanswered: "B")
        check("a song Music didn't answer about in time isn't counted as missed, is listed last under its own heading, "
              + "and the advice to try again promises nothing about repeats",
              late?.message == "2 of the 4 songs weren’t added to “Lakeside”."
              && late?.informative == "\(MusicPlaylistEditor.unansweredReason) To try again, add the songs to “Lakeside” again."
              && late?.details == "Not sent to Music:\nC\nD\n\nMusic didn’t answer in time; it may still go in:\nB",
              "\(String(describing: late))")
        check("…and when it was the add's last song, nothing is said, as for a Download",
              App.addSongsAlert(to: "Lakeside", asked: 4, refused: [], notSent: [], stopReason: MusicPlaylistEditor.unansweredReason,
                                oldTunesOnly: [], unanswered: "D") == nil)

        // Counts over 1,000 with separators, as the question before a big add has them.
        let many = App.addSongsAlert(to: "Lakeside", asked: 1_234, refused: [], notSent: Array(repeating: "N", count: 634),
                                     stopReason: MusicPlaylistEditor.musicQuitReason, oldTunesOnly: [])
        let ours = App.addSongsAlert(to: "Lakeside", asked: 2_000, refused: [], notSent: [], stopReason: nil,
                                     oldTunesOnly: Array(repeating: "F", count: 1_234))
        let turnedDown = App.addSongsAlert(to: "Lakeside", asked: 1_300, refused: Array(repeating: "A — r", count: 1_234),
                                           notSent: ["N"], stopReason: MusicPlaylistEditor.musicQuitReason, oldTunesOnly: [])
        check("an add of more than 1,000 songs counts with separators, as its question does",
              many?.message == "634 of the 1,234 songs weren’t added to “Lakeside”."
              && ours?.message == "1,234 of the 2,000 songs weren’t added to “Lakeside”."
              && ours?.informative.hasPrefix("1,234 of these songs are only in OldTunes,") == true
              && turnedDown?.informative.contains("Music didn’t accept 1,234 songs.") == true,
              "\(many?.message ?? "no alert") / \(ours?.message ?? "no alert") / \(turnedDown?.informative ?? "no alert")")

        // How the editor words a stop, and which stops a retry would only meet again.
        typealias Editor = MusicPlaylistEditor
        func failure(_ code: Int?, missing: Bool = false, _ message: String = "the session's words") -> TagEditError {
            TagEditError(message: message, code: code, missingCommand: missing)
        }
        check("the editor: Music gone once the add has begun (-600, -609) means it quit, a timeout is said plainly, "
              + "and anything else keeps the session's words (ready()'s own failures carry no code)",
              Editor.stopReason(for: failure(-600)) == Editor.musicQuitReason && Editor.stopReason(for: failure(-609)) == Editor.musicQuitReason
              && Editor.stopReason(for: failure(-1712)) == Editor.timeoutReason
              && [-10004, -1743, -1708].allSatisfy { Editor.stopReason(for: failure($0)) == "the session's words" }
              && Editor.stopReason(for: failure(nil)) == "the session's words")
        // The chunk's playlist lookup finding nothing: Music no longer has the playlist (-1728).
        let goneThrow = failure(-1728, "Music has no playlist with this ID (A1B2C3D4E5F60718). It may have been deleted already.")
        check("…a playlist gone from Music (-1728, from the chunk's playlist lookup) in plain words, naming no ID",
              Editor.stopReason(for: goneThrow) == "Music no longer has this playlist, so OldTunes stopped adding songs.",
              Editor.stopReason(for: goneThrow))
        check("…and only a playlist gone from Music, -1742 (nothing reaches Music), -10004 and a missing command are stops a "
              + "retry can't get past, never a quit, a timeout or the permission",
              [-1728, -1742, -10004].allSatisfy { Editor.retryWontHelp(after: failure($0)) }
              && Editor.retryWontHelp(after: failure(-1708, missing: true))
              && ![-600, -609, -1712, -1743, -1708].contains { Editor.retryWontHelp(after: failure($0)) }
              && !Editor.retryWontHelp(after: failure(nil)))

        // Which of Music's answers end an add, and which refuse only the one song.
        func stops(_ code: Int, missing: Bool = false) -> Bool {
            MusicScriptingSession.stopsBatch(TagEditError(message: "x", code: code, missingCommand: missing))
        }
        check("an add stops for -10004, a timeout, no permission or Music gone, and OldTunes's own missing command; "
              + "Music's own -1708 or a missing song refuses just that song",
              stops(-10004) && stops(-1712) && stops(-1743) && stops(-600) && stops(-609) && stops(-1708, missing: true)
              && !stops(-1708) && !stops(-1728) && !stops(-50))

        // What the editor's `send` does after a song fails, in its order (MusicPlaylistEditor.afterFailure),
        // from Music's answer alone. `send` only sends the events and applies this; its checks
        // that Music still runs are left to a hand check (RESEARCH.md §6.10). `run`: the refusals
        // in a row so far.
        var run: (code: Int?, count: Int) = (nil, 0)
        func after(_ error: TagEditError, sent: Bool, first: Bool = false, added: Int = 5) -> Editor.AfterFailure {
            Editor.afterFailure(error, duplicateSent: sent, firstChunk: first, addedSoFar: added, streak: &run)
        }
        let firstSong = after(failure(-50, "Music’s reason."), sent: true, first: true, added: 0)
        check("the editor: the first song of an add's first chunk turned down stops the add, and is listed as turned down, "
              + "saying “this playlist” and Music's reason, the playlist's name kept out of the stop, which also goes to the log; "
              + "no advice to try again; the refusals in a row are left alone",
              firstSong == .init(refused: true, stopReason: "Music doesn’t let songs be added to this playlist. Music’s reason.",
                                 retryWontHelp: true)
              && run.count == 0, "\(firstSong)")
        // Three songs dropped on Purchased, through the steps the app takes Music's answer about
        // the first with (`send`'s own `Editor.apply`, then `addChunkStep`).
        var sent = PlaylistAddReport()
        let stopsThere = Editor.apply(firstSong, to: 0x7101, failedWith: failure(-50, "Music’s reason."), in: &sent)
        var dropped = PlaylistAddReport()
        let firstStep = App.addChunkStep(sent, chunk: [0x7101, 0x7102, 0x7103], rest: [], into: &dropped)
        let droppedAlert = App.addSongsAlert(to: "Purchased", asked: 3,
                                             refused: dropped.refused.map { "Invented Song \($0.persistentID - 0x7100) — \($0.reason)" },
                                             notSent: (firstStep.notSent ?? []).map { "Invented Song \($0 - 0x7100)" },
                                             stopReason: dropped.stopReason, oldTunesOnly: [], retryWontHelp: dropped.retryWontHelp)
        check("…so that song shows under “Music didn’t accept:” with Music's reason, and only the songs after it as not sent: "
              + "Music was sent the first and turned it down",
              stopsThere && firstStep.notSent == [0x7102, 0x7103]
              && droppedAlert?.details == "Music didn’t accept:\nInvented Song 1 — Music’s reason.\n\nNot sent to Music:\n"
                + "Invented Song 2\nInvented Song 3"
              && droppedAlert?.informative == "Music doesn’t let songs be added to this playlist. Music’s reason. Music didn’t "
                + "accept one song.", "not sent \(firstStep.notSent ?? []); \(String(describing: droppedAlert))")
        let laterChunk = after(failure(-50), sent: true, first: false, added: 0), afterOne = after(failure(-50), sent: true, first: true, added: 1)
        check("…only in an add's first chunk, before a song has gone in: otherwise Music turned down that one song, and the add goes on",
              laterChunk == .init(refused: true) && afterOne == .init(refused: true), "\(laterChunk), \(afterOne)")
        let slowDuplicate = after(failure(-1712), sent: true, first: true, added: 0)
        check("…a `duplicate` Music didn't answer in time stops the add, ahead of that rule: the song may still go in, so it is "
              + "waited on, not turned down",
              slowDuplicate == .init(unanswered: true, stopReason: Editor.unansweredReason), "\(slowDuplicate)")
        let wall = after(failure(-10004), sent: true, first: true, added: 0), quit = after(failure(-609), sent: true)
        let noCommand = after(failure(-1708, missing: true), sent: true)
        check("…an answer that ends the add stops it, ahead of the first-song rule too: a quit with a retry still open; "
              + "-10004 and a missing `duplicate` in the session's words, with none",
              quit == .init(stopReason: Editor.musicQuitReason)
              && wall == .init(stopReason: "the session's words", retryWontHelp: true)
              && noCommand == .init(stopReason: "the session's words", retryWontHelp: true), "\(quit), \(wall), \(noCommand)")
        run = (-50, 2)
        let missingSong = after(failure(nil, "Music has no song with this ID (0000000000001001)."), sent: false, first: true, added: 0)
        let lookupTimeout = after(failure(-1712), sent: false)
        check("…a song not found turns down that song only, even first in an add, and leaves the refusals in a row as they "
              + "were; a lookup that times out stops, with nothing sent for that song",
              missingSong == .init(refused: true) && lookupTimeout == .init(stopReason: Editor.timeoutReason)
              && run.code == -50 && run.count == 2, "\(missingSong), \(lookupTimeout), run \(run)")
        // Music's code for an object that isn't there (-1728) at a song's own lookup, in an add:
        // the song is missing, not the playlist (MusicScriptingSession.track(persistentID:)), so
        // that song is turned down, with words about the song, and the add goes on. A playlist
        // command whose playlist is gone keeps the playlist's words.
        let noSuchObject = NSError(domain: NSOSStatusErrorDomain, code: -1728)
        let lookup = "Music couldn’t look up the song 0000000000001001"
        let songGone = MusicScriptingSession.describe(noSuchObject, what: lookup, purpose: .editingPlaylists,
                                                      missing: MusicScriptingSession.Purpose.songMissingReason)
        let playlistGone = MusicScriptingSession.describe(noSuchObject, what: "Music couldn’t rename the playlist",
                                                          purpose: .editingPlaylists)
        let otherPurposes = [MusicScriptingSession.Purpose.savingTags, .addingSongs, .downloadingSongs]
            .map { MusicScriptingSession.describe(noSuchObject, what: lookup, purpose: $0) }
        run = (nil, 0)
        check("…a song's lookup that finds nothing (-1728) says the song is missing, not the playlist, turns down that song "
              + "only, and the add goes on; a playlist that is gone keeps the playlist's words, and a tag save's or a "
              + "Download's lookup the song's, as before",
              songGone == "\(lookup): Music couldn’t find the song. It may have been removed from the library."
              && playlistGone == "Music couldn’t rename the playlist: Music couldn’t find the playlist. It may have been deleted already."
              && otherPurposes.allSatisfy { $0 == songGone }
              && after(failure(-1728, songGone), sent: false, first: true, added: 0) == .init(refused: true) && run.count == 0,
              "\(songGone) / \(playlistGone)")
        run = (nil, 0)
        let mixed = [-50, -51, -50, -1708].map { after(failure($0), sent: true) }
        run = (nil, 0)
        let streak = [after(failure(-50), sent: true), after(failure(-1728), sent: false), after(failure(-50), sent: true),
                      after(failure(nil), sent: false), after(failure(-50, "Music’s third reason."), sent: true)]
        check("…Music turning down three songs in a row with one code stops the add, with no advice to try again: that is about "
              + "the playlist; lookups turned down in between don't break the run, and different codes don't make one",
              mixed.allSatisfy { $0 == .init(refused: true) } && streak.prefix(4).allSatisfy { $0 == .init(refused: true) }
              && streak[4] == .init(refused: true, stopReason: "Music turned down three songs in a row, so OldTunes stopped "
                                    + "adding songs. Music’s third reason.", retryWontHelp: true),
              "\(mixed.map(\.refused)), \(streak.map { $0.stopReason ?? "goes on" })")

        // A playlist gone from Music while songs went in: nothing to add them to again, and the
        // list should let it go, so the add ends by re-reading the library.
        let gone = App.addSongsAlert(to: "Lakeside", asked: 400, refused: [], notSent: Array(repeating: "N", count: 300),
                                     stopReason: Editor.stopReason(for: goneThrow), oldTunesOnly: [],
                                     retryWontHelp: Editor.retryWontHelp(after: goneThrow))
        check("an add stopped because Music no longer has its playlist says so, with no advice to add the songs to it again, "
              + "and re-reads the library so the list lets the playlist go, as after a song Music may still add",
              gone?.message == "300 of the 400 songs weren’t added to “Lakeside”."
              && gone?.informative == "Music no longer has this playlist, so OldTunes stopped adding songs."
              && App.addRereadsLibrary(after: PlaylistAddReport(stopReason: Editor.stopReason(for: goneThrow), retryWontHelp: true))
              && App.addRereadsLibrary(after: PlaylistAddReport(stopReason: Editor.unansweredReason, unanswered: 5))
              && !App.addRereadsLibrary(after: PlaylistAddReport(stopReason: Editor.musicQuitReason))
              && !App.addRereadsLibrary(after: PlaylistAddReport(added: [1, 2])), "\(String(describing: gone))")

        // An add of 60 songs, as addInChunks takes it: three chunks of at most 25. In chunk 2 ten
        // go in, Music turns the eleventh down, doesn't answer about the twelfth in time, and the
        // chunk stops there, a stop no retry gets past.
        let sixty = (0..<60).map { Int64(0x5000 + $0) }
        let starts = Array(stride(from: 0, to: sixty.count, by: App.addChunkSize))
        check("an add of 60 songs goes in three chunks: a drop's first may start Music and the others go on from it; "
              + "New Playlist from Selection's never start it, since making its playlist just did",
              starts == [0, 25, 50] && starts.map { App.addChunkContinues(at: $0, firstChunkStartsMusic: true) } == [false, true, true]
              && starts.map { App.addChunkContinues(at: $0, firstChunkStartsMusic: false) } == [true, true, true], "\(starts)")
        var report = PlaylistAddReport()
        let chunk1 = Array(sixty[0..<25]), chunk2 = Array(sixty[25..<50])
        let step1 = App.addChunkStep(PlaylistAddReport(added: chunk1), chunk: chunk1, rest: sixty[25...], into: &report)
        let in2 = Array(chunk2[0..<10]), refusedSong = chunk2[10], unanswered = chunk2[11]
        let part2 = PlaylistAddReport(added: in2, refused: [.init(persistentID: refusedSong, reason: "r")],
                                      stopReason: "\(Editor.threeInARowReason) r", unanswered: unanswered, retryWontHelp: true)
        let step2 = App.addChunkStep(part2, chunk: chunk2, rest: sixty[50...], into: &report)
        check("…chunk 1 all in: its songs go into the index, and the add goes on; chunk 2 stops: only the ten Music took go in",
              step1.apply == chunk1 && step1.notSent == nil && step2.apply == in2,
              "\(step1.apply.count) then \(step2.apply.count) put in the index")
        let wantUnsent: [Int64] = Array(chunk2[12...]) + Array(sixty[50...])
        check("…not sent: chunk 2's songs after the stop, then all of chunk 3's; never the one turned down, nor the one Music "
              + "may still add",
              step2.notSent == wantUnsent, "\(step2.notSent?.count ?? 0) not sent")
        var titles: [Int64: String] = [:]
        for (n, pid) in sixty.enumerated() { titles[pid] = "Invented Song \(n + 1)" }
        let refusedLines: [String] = report.refused.map { "\(titles[$0.persistentID] ?? "?") — r" }
        let unsentTitles: [String] = (step2.notSent ?? []).compactMap { titles[$0] }
        let sixtyAlert = App.addSongsAlert(to: "Lakeside", asked: 60, refused: refusedLines, notSent: unsentTitles,
                                           stopReason: report.stopReason, oldTunesOnly: [],
                                           unanswered: report.unanswered.flatMap { titles[$0] }, retryWontHelp: report.retryWontHelp)
        let tallied = report.added == chunk1 + in2 && report.refused.map(\.persistentID) == [refusedSong]
            && report.unanswered == unanswered && report.stopReason == part2.stopReason && report.retryWontHelp
        let worded = sixtyAlert?.message == "24 of the 60 songs weren’t added to “Lakeside”."
            && sixtyAlert?.informative == "\(Editor.threeInARowReason) r Music didn’t accept one song."
            && sixtyAlert?.details.hasSuffix("Music didn’t answer in time; it may still go in:\nInvented Song 37") == true
        check("…and the add's report takes it all in: 35 in, one turned down, one unanswered, the stop with no advice to try "
              + "again; its alert reads 24 of the 60, the unanswered song listed last and not counted",
              tallied && worded,
              "\(report.added.count) in; \(String(describing: sixtyAlert?.message)) \(String(describing: sixtyAlert?.informative))")
        // The same add as Music really stops one there: the editor stops at a `duplicate` it got
        // no answer to in time, as unanswered, a stop trying again can get past, after turning the
        // song before it down (afterFailure, as `send` takes its answers).
        var slowRun: (code: Int?, count: Int) = (nil, 0)
        let elevenths = Editor.afterFailure(failure(-50, "r"), duplicateSent: true, firstChunk: false, addedSoFar: 10, streak: &slowRun)
        let twelfths = Editor.afterFailure(failure(-1712), duplicateSent: true, firstChunk: false, addedSoFar: 10, streak: &slowRun)
        var slowAdd = PlaylistAddReport()
        _ = App.addChunkStep(PlaylistAddReport(added: chunk1), chunk: chunk1, rest: sixty[25...], into: &slowAdd)
        var slowPart = PlaylistAddReport(added: in2)
        _ = Editor.apply(elevenths, to: refusedSong, failedWith: failure(-50, "r"), in: &slowPart)
        _ = Editor.apply(twelfths, to: unanswered, failedWith: failure(-1712), in: &slowPart)
        let slowStep = App.addChunkStep(slowPart, chunk: chunk2, rest: sixty[50...], into: &slowAdd)
        let slowAlert = App.addSongsAlert(to: "Lakeside", asked: 60, refused: slowAdd.refused.map { "\(titles[$0.persistentID] ?? "?") — r" },
                                          notSent: (slowStep.notSent ?? []).compactMap { titles[$0] }, stopReason: slowAdd.stopReason,
                                          oldTunesOnly: [], unanswered: slowAdd.unanswered.flatMap { titles[$0] },
                                          retryWontHelp: slowAdd.retryWontHelp)
        let slowDetails = "Music didn’t accept:\nInvented Song 36 — r\n\nNot sent to Music:\n"
            + (38...60).map { "Invented Song \($0)" }.joined(separator: "\n")
            + "\n\nMusic didn’t answer in time; it may still go in:\nInvented Song 37"
        check("…and as Music really stops one, at a `duplicate` it didn't answer in time: 24 of the 60 again, the song that "
              + "may still go in not counted and listed last under its own heading, and advice to try again that doesn't "
              + "promise songs already in aren't added twice",
              slowStep.notSent == wantUnsent && slowAdd.added == chunk1 + in2 && slowAdd.unanswered == unanswered
              && !slowAdd.retryWontHelp && slowAdd.stopReason == Editor.unansweredReason
              && slowAlert?.message == "24 of the 60 songs weren’t added to “Lakeside”."
              && slowAlert?.informative == "\(Editor.unansweredReason) Music didn’t accept one song. To try again, add the songs "
                + "to “Lakeside” again."
              && slowAlert?.details == slowDetails,
              "\(slowStep.notSent?.count ?? 0) not sent; \(String(describing: slowAlert?.message)) "
              + "\(String(describing: slowAlert?.informative))")

        // Each chunk's songs in the index post a library change naming the playlist: news only
        // to a track list showing it (AppController.libraryChanged), not to the Library a ⌘A drag
        // came from, nor to the source list.
        check("a library change reloads everything, but songs going into a playlist reload only a track list showing that "
              + "playlist, and nothing for a list showing anything else",
              App.changeReload(songsAddedTo: nil, showing: .library) == .everything
              && App.changeReload(songsAddedTo: nil, showing: .playlist(701)) == .everything
              && App.changeReload(songsAddedTo: 701, showing: .playlist(701)) == .trackList
              && App.changeReload(songsAddedTo: 701, showing: .library) == .nothing
              && App.changeReload(songsAddedTo: 701, showing: .onThisMac) == .nothing
              && App.changeReload(songsAddedTo: 701, showing: .playlist(702)) == .nothing)
    }

    // MARK: Pixels

    /// `view` drawn as its window shows it, into an sRGB bitmap of `scale` pixels to the point:
    /// 1x and 2x whatever the screen is, which Snapshot.write can't give.
    func render(_ view: NSView, scale: CGFloat) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((view.bounds.width * scale).rounded()),
                                         pixelsHigh: Int((view.bounds.height * scale).rounded()), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0)?.retagging(with: .sRGB) else { return nil }
        // Set before drawing, which then works in points.
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    func save(_ rep: NSBitmapImageRep, _ name: String) {
        let url = outDir.appendingPathComponent(name)
        do {
            guard let png = rep.representation(using: .png, properties: [:]) else { return }
            try png.write(to: url)
            info("snapshot \(url.path)")
        } catch {
            info("snapshot \(name) not written: \(error.localizedDescription)")
        }
    }

    /// The pixel under `point` (in `view`) of a rendering of `content`.
    func pixel(_ rep: NSBitmapImageRep, at point: NSPoint, in view: NSView, of content: NSView) -> PlaylistBenchPixel? {
        let p = content.convert(point, from: view)
        let scale = CGFloat(rep.pixelsWide) / content.bounds.width
        let y = content.isFlipped ? p.y : content.bounds.height - p.y
        return sample(rep, x: Int((p.x * scale).rounded(.down)), y: Int((y * scale).rounded(.down)))
    }

    /// Raw samples, not `colorAt`, which would convert them; unpremultiplied.
    func sample(_ rep: NSBitmapImageRep, x: Int, y: Int) -> PlaylistBenchPixel? {
        guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh else { return nil }
        var raw = [Int](repeating: 0, count: max(rep.samplesPerPixel, 4))
        rep.getPixel(&raw, atX: x, y: y)
        let top = Double((1 << rep.bitsPerSample) - 1)
        let first = rep.bitmapFormat.contains(.alphaFirst)
        let a = rep.hasAlpha ? Double(raw[first ? 0 : 3]) / top : 1
        let c = first ? Array(raw[1...3]) : Array(raw[0...2])
        let k = rep.bitmapFormat.contains(.alphaNonpremultiplied) || a == 0 ? 1 : 1 / a
        return PlaylistBenchPixel(r: Double(c[0]) * 255 / top * k, g: Double(c[1]) * 255 / top * k,
                                  b: Double(c[2]) * 255 / top * k, a: a)
    }

    /// `color` in sRGB as `window` draws it, by day or by night.
    func resolved(_ color: NSColor, in window: NSWindow) -> PlaylistBenchPixel {
        var srgb: NSColor?
        window.effectiveAppearance.performAsCurrentDrawingAppearance { srgb = color.usingColorSpace(.sRGB) }
        guard let srgb else { return PlaylistBenchPixel(r: -999, g: -999, b: -999, a: 1) }
        return PlaylistBenchPixel(r: srgb.redComponent * 255, g: srgb.greenComponent * 255, b: srgb.blueComponent * 255,
                                  a: srgb.alphaComponent)
    }
}

/// HARNESS ONLY. One pixel of a bench rendering, unpremultiplied: channels 0…255, alpha 0…1.
struct PlaylistBenchPixel {
    var r: Double, g: Double, b: Double, a: Double

    /// The largest difference in any one channel, in levels.
    func distance(to other: PlaylistBenchPixel) -> Double {
        max(abs(r - other.r), abs(g - other.g), abs(b - other.b))
    }

    var hex: String {
        String(format: "#%02X%02X%02X", Int(min(max(r, 0), 255).rounded()), Int(min(max(g, 0), 255).rounded()),
               Int(min(max(b, 0), 255).rounded()))
    }
}

/// HARNESS ONLY. What each `.libraryDidChange` said about its change, in order.
@MainActor
private final class ChangeNotes {
    var seen: [String] = []
}

/// HARNESS ONLY. `library`, but its first `failing` reads of the playlists fail, as a busy or
/// damaged index's would.
private actor FlakyPlaylists: LibraryReading {
    let library: any LibraryReading
    private var failing: Int
    private(set) var reads = 0

    init(_ library: any LibraryReading, failing: Int) {
        self.library = library
        self.failing = failing
    }

    func playlists() async throws -> [PlaylistInfo] {
        reads += 1
        guard failing == 0 else {
            failing -= 1
            throw CocoaError(.fileReadUnknown)
        }
        return try await library.playlists()
    }

    func ids(for query: TrackQuery) async throws -> [Track.ID] { try await library.ids(for: query) }
    func tracks(ids: [Track.ID]) async throws -> [Track] { try await library.tracks(ids: ids) }
    func summary(for ids: [Track.ID]) async throws -> LibrarySummary { try await library.summary(for: ids) }
    func browserValues(_ field: BrowserField, for query: TrackQuery) async throws -> [String] {
        try await library.browserValues(field, for: query)
    }
    func count() async throws -> Int { try await library.count() }
}

/// HARNESS ONLY. A drag over the source list as AppKit describes one to the list's data source:
/// where the pointer is, in window coordinates, and the pasteboard, the bench's own. No session.
@MainActor
private final class PlaylistBenchDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingLocation: NSPoint

    init(_ pasteboard: NSPasteboard, at location: NSPoint) {
        draggingPasteboard = pasteboard
        draggingLocation = location
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggedImageLocation: NSPoint { draggingLocation }
    // Deprecated, and with namesOfPromisedFilesDropped(atDestination:) (which NSObject already
    // has, from a deprecated category) the only member the SDK doesn't put on the main actor.
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
