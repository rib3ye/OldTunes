import AppKit
import GRDB

/// Offline checks: invented songs only. No event built here is sent to Music.
extension ListsPlaylistBench {
    func removalChecks(_ source: SourceListViewController, tracks: TrackListViewController,
                       index: LibraryIndex, in window: NSWindow) async {
        let table = tracks.tableView
        let clear = MainMenu.make().items.first { $0.submenu?.title == "Edit" }?.submenu?.items.first { $0.title == "Clear" }
        check("Edit contains a responder-chain Clear command", clear?.action == #selector(NSText.delete(_:)) && clear?.target == nil)
        for scope in [LibraryScope.library, .onThisMac, .playlist(601), .playlist(501)] {
            tracks.query = TrackQuery(scope: scope)
            await tracks.waitForLoad()
            select(table, [0])
            check("Clear is unavailable in \(scope)", !tracks.canRemoveSelection)
        }
        tracks.query = TrackQuery(scope: .playlist(702), sort: TrackSort(field: .name, ascending: false))
        check("Clear cannot target the new playlist while old rows are still shown", !tracks.canRemoveSelection)
        await tracks.waitForLoad()
        await tracks.waitForRows()
        select(table, [0, 2])
        let selected = tracks.selectedIDs
        var menu = rightClick(table, row: 2, in: window)
        perform(menu, "Clear")
        check("right-click Clear keeps a multiple selection in display order and captures its playlist",
              removeAsks.last.map { $0.ids == selected && $0.playlist == 702 } == true && selected.count == 2)
        window.makeFirstResponder(table)
        for (code, chars) in [(UInt16(51), "\u{7F}"), (UInt16(117), "\u{F728}")] {
            let before = removeAsks.count
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, characters: chars,
                                           charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                table.keyDown(with: event)
            }
            check("key \(code) clears the selected playlist songs", removeAsks.count == before + 1 && removeAsks.last?.ids == selected)
        }
        if let clear {
            let before = removeAsks.count
            check("Clear validates against the focused track table", (table as? RetroTableView)?.validateMenuItem(clear) == true)
            // macOS may keep this harness in the background, with NSApp.keyWindow nil. Start
            // at the window's actual first responder, as an active app's nil-target menu does.
            let handled = window.firstResponder?.tryToPerform(clear.action!, with: clear) == true
            check("Edit Clear follows the track responder chain", handled && removeAsks.count == before + 1 && removeAsks.last?.ids == selected)
        }
        menu = rightClick(table, row: 1, in: window)
        perform(menu, "Clear")
        check("right-click an unselected song clears only that song", removeAsks.last?.ids == [tracks.order[1]])
        table.deselectAll(nil)
        menu = rightClick(table, row: nil, in: window)
        check("Clear is disabled for an empty selection", menu?.items.first { $0.title == "Clear" }?.isEnabled == false)

        tracks.query.search = "Song 4"
        await tracks.waitForLoad()
        select(table, [0])
        perform(rightClick(table, row: 0, in: window), "Clear")
        check("a filtered Clear requests only the visible selected song",
              tracks.order.count == 1 && removeAsks.last?.ids == tracks.order && removeAsks.last?.playlist == 702)
        let callback = tracks.onRemoveFromPlaylist
        tracks.onRemoveFromPlaylist = nil
        check("Clear is disabled without a removal handler", !tracks.canRemoveSelection)
        tracks.onRemoveFromPlaylist = callback

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
        window.contentView?.addSubview(field)
        field.stringValue = "Keep typing"
        window.makeFirstResponder(field)
        if let editor = field.currentEditor(), let clear {
            editor.selectAll(nil)
            let before = removeAsks.count
            _ = window.firstResponder?.tryToPerform(clear.action!, with: clear)
            check("Edit Clear in a text field edits text, never the playlist", editor.string.isEmpty && removeAsks.count == before)
        } else { check("Edit Clear in a text field gets a field editor", false) }
        window.makeFirstResponder(table)
        field.removeFromSuperview()
        tracks.query = TrackQuery()
        await tracks.waitForLoad()

        let question = AppController.removeSongsQuestion(count: 2, from: "Lakeside")
        check("removal confirmation names the playlist and explains what stays",
              question.message == "Are you sure you want to remove the 2 selected songs from “Lakeside”?"
              && question.informative.contains("stay in your library and other playlists"))
        check("single-song confirmation is singular",
              AppController.removeSongsQuestion(count: 1, from: "Lakeside").message.contains("the selected song from"))
        removalEventChecks()
        await removalIndexChecks()
    }

    private func removalEventChecks() {
        let playlist = MusicScriptingSession.playlistReference(id: 321)
        let event = MusicScriptingSession.playlistRemovalEvent(Int64.min, from: playlist)
        let tracks = event.paramDescriptor(forKeyword: 0x2D2D_2D2D)?.coerce(toDescriptorType: 0x7265_636F)
        let parent = tracks?.forKeyword(0x6672_6F6D)?.coerce(toDescriptorType: 0x7265_636F)
        let source = parent?.forKeyword(0x6672_6F6D)?.coerce(toDescriptorType: 0x7265_636F)
        let comparison = tracks?.forKeyword(0x7365_6C64)?.coerce(toDescriptorType: 0x7265_636F)
        let property = comparison?.forKeyword(0x6F62_6A31)?.coerce(toDescriptorType: 0x7265_636F)
        check("delete event retains track → playlist ID → source scope, never a library track",
              event.eventClass == 0x636F_7265 && event.eventID == 0x6465_6C6F
              && tracks?.forKeyword(0x7761_6E74)?.typeCodeValue == 0x6354_726B
              && parent?.forKeyword(0x7761_6E74)?.typeCodeValue == 0x6350_6C79
              && parent?.forKeyword(0x666F_726D)?.enumCodeValue == 0x4944_2020
              && parent?.forKeyword(0x7365_6C64)?.int32Value == 321
              && source?.forKeyword(0x7761_6E74)?.typeCodeValue == 0x6353_7263)
        check("delete matches persistent ID atomically, including all occurrences and high-bit IDs",
              tracks?.forKeyword(0x666F_726D)?.enumCodeValue == 0x7465_7374
              && comparison?.forKeyword(0x7265_6C6F)?.enumCodeValue == 0x3D20_2020
              && comparison?.forKeyword(0x6F62_6A32)?.stringValue == "8000000000000000"
              && property?.forKeyword(0x7365_6C64)?.typeCodeValue == 0x7050_4953
              && property?.forKeyword(0x6672_6F6D)?.descriptorType == 0x6578_6D6E)
        check("a timeout reports an uncertain removal; a quit stops removal",
              MusicPlaylistEditor.removeStopReason(for: TagEditError(message: "timeout", code: -1712)).contains("may still be removed")
              && MusicPlaylistEditor.removeStopReason(for: TagEditError(message: "quit", code: -600)) == MusicPlaylistEditor.removeQuitReason)
    }

    private func removalIndexChecks() async {
        let path = outDir.appendingPathComponent("removal-bench.sqlite")
        removeIndex(at: path)
        defer { removeIndex(at: path) }
        do {
            let index = try LibraryIndex(path: path)
            let songs = (1...4).map { n -> SongRecord in
                var song = SongRecord(origin: .musicLibrary, persistentID: Int64(n))
                song.title = "Removal song \(n)"
                song.titleSortSource = song.title
                song.contentHash = song.computeContentHash()
                return song
            }
            func list(_ id: Int64, _ kind: PlaylistInfo.Kind, _ pids: [Int64]) -> PlaylistRecord {
                PlaylistRecord(info: PlaylistInfo(id: id, name: "Removal \(id)", kind: kind, parentID: nil, trackCount: pids.count),
                               sortIndex: Int(id), memberPIDs: pids)
            }
            let lists = [list(11, .regular, [1, 2, 1, 3]), list(12, .regular, [1, 4]), list(13, .smart, [1, 2])]
            _ = try await index.replaceMusicLibrary(songs, playlists: lists)
            let stamp = try await index.playlistEditStamp()
            let tracks = TrackListViewController(library: index)
            let (window, backdrop) = benchWindow(size: NSSize(width: 650, height: 300), title: "OldTunes — remove songs")
            backdrop.addSubview(tracks.view)
            tracks.view.frame = backdrop.bounds
            tracks.query = TrackQuery(scope: .playlist(11))
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            await tracks.waitForLoad()
            let before = tracks.order
            select(tracks.tableView, [0])
            try await index.apply(.songsRemoved(11, persistentIDs: [1, 999]))
            await tracks.reload()
            let count = try await index.count()
            let other = try await index.ids(for: TrackQuery(scope: .playlist(12)))
            let remaining = try await index.playlists().first { $0.id == 11 }?.trackCount
            check("removal deletes repeated membership, preserves library and other playlists, and updates count",
                  tracks.order == Array(before.dropFirst()) && count == 4 && other.count == 2 && remaining == 2)
            check("the next surviving row stays selected after removal", tracks.selectedIDs == [before[1]])
            let afterStamp = try await index.playlistEditStamp()
            check("removal invalidates stale ingest snapshots", afterStamp == stamp + 1)
            _ = try await index.replaceMusicLibrary(songs, playlists: lists, playlistStamp: stamp)
            let stillRemoved = try await index.ids(for: TrackQuery(scope: .playlist(11)))
            check("an ingest started before removal cannot restore removed songs", stillRemoved == tracks.order)
            try await index.apply(.songsRemoved(13, persistentIDs: [1]))
            let smart = try await index.ids(for: TrackQuery(scope: .playlist(13)))
            check("index removal refuses smart playlists too", smart.count == 2)
            select(tracks.tableView, [1])
            try await index.apply(.songsRemoved(11, persistentIDs: [3]))
            await tracks.reload()
            check("clearing the last row selects the previous row", tracks.selectedIDs == [before[1]])
            try await index.apply(.songsRemoved(11, persistentIDs: [2]))
            await tracks.reload()
            check("clearing every song leaves an empty playlist with no selection", tracks.order.isEmpty && tracks.selectedIDs.isEmpty)
        } catch { check("removal index checks", false, error.localizedDescription) }
    }
}
