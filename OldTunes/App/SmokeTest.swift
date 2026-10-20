import AppKit

/// OLDTUNES_HARNESS=smoke — drives the fully wired app the way a user's clicks would, through the
/// same callbacks and selection paths the views use, and logs PASS/FAIL plus snapshots. It only observes and calls;
/// it never replaces a callback, so what it tests is what ships. Never touches the volume (during
/// cloud songs that is the Mac's system volume).
///
///   open -n -W --env OLDTUNES_HARNESS=smoke --env OLDTUNES_SMOKE_DIR=/abs/dir build/dd/.../OldTunes.app
@MainActor
struct SmokeTest {
    let app: AppController
    private let dir: URL
    private static var passed = 0, failed = 0

    init(app: AppController) {
        self.app = app
        let path = ProcessInfo.processInfo.environment["OLDTUNES_SMOKE_DIR"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("oldtunes-smoke").path
        dir = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func run(_ report: IngestReport) async {
        Log.info("smoke: start")
        check("ingest ok", report.status == .ok, "\(report.status)")
        check("15,900 songs ingested", report.musicLibrarySongs == 15_900, "\(report.musicLibrarySongs)")
        await settle()
        check("library shows every song", app.tracks.order.count == report.musicLibrarySongs + report.folderTracks,
              "\(app.tracks.order.count) rows")
        shot("01-library")

        // The four sorts the user asked for, through the same query the header click sets. The list
        // opens with the user's saved sort, so start from Artist to make the first one a change.
        app.tracks.query.sort = .default
        await app.tracks.waitForLoad()
        for (field, ascending) in [(TrackSortField.name, true), (.artist, true), (.album, true), (.dateAdded, false)] {
            let before = app.tracks.order
            let start = Date()
            app.tracks.query.sort = TrackSort(field: field, ascending: ascending)
            let changed = await waitFor(2) { app.tracks.order != before }
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            let top = (try? await app.index.tracks(ids: Array(app.tracks.order.prefix(3)))) ?? []
            let names = top.map { field == .dateAdded ? "\($0.title) (\($0.dateAdded.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "?"))"
                                                      : field == .artist ? $0.artist : field == .album ? $0.album : $0.title }
            check("sort \(field.rawValue) \(ascending ? "asc" : "desc")", changed && app.tracks.order.count >= 15_900,
                  "\(ms) ms to new order; top: \(names.joined(separator: " | "))")
        }
        shot("02-date-added-newest")

        // Search through the control bar's callback, like typing in the capsule.
        for (text, expectAtLeast) in [("beatles", 1), ("nderw", 1), ("oasis", 1), ("o", 1000)] {
            app.windowController.controlBar.searchText = text
            let start = Date()
            app.windowController.controlBar.onSearchTextChange?(text)
            let settled = await waitFor(2) { app.tracks.order.count < 15_900 && app.tracks.order.count > 0 }
            await settle()
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            check("search '\(text)'", settled && app.tracks.order.count >= expectAtLeast,
                  "\(app.tracks.order.count) rows in \(ms) ms (includes the 140 ms debounce)")
            if text == "beatles" { shot("03-search-beatles") }
        }
        app.windowController.controlBar.searchText = ""
        app.windowController.controlBar.onSearchTextChange?("")
        check("clearing search restores the library", await waitFor(2) { app.tracks.order.count >= 15_900 },
              "\(app.tracks.order.count) rows")

        // Double-click a cloud-only song.
        app.tracks.query.sort = TrackSort(field: .artist, ascending: true)
        await settle()
        let page = (try? await app.index.tracks(ids: Array(app.tracks.order.prefix(200)))) ?? []
        if let cloud = page.first(where: { $0.isCloudOnly && $0.duration > 60 }) {
            app.tracks.reveal(cloud.id)
            app.tracks.onActivate?(cloud.id, app.tracks.order)
            let playing = await waitFor(12) { app.player.state.position > 1.5 && app.player.state.nowPlaying?.id == cloud.id }
            check("cloud song streams", playing,
                  "“\(cloud.title)” by \(cloud.artist): position \(fmt(app.player.state.position)) s, loading=\(app.player.state.isLoading)")
            shot("04-playing-cloud")

            let first = app.player.state.nowPlaying?.id
            app.player.next()
            let advanced = await waitFor(12) {
                app.player.state.nowPlaying?.id != first && app.player.state.position > 1
            }
            check("next plays the following song", advanced,
                  "now “\(app.player.state.nowPlaying?.title ?? "nil")” at \(fmt(app.player.state.position)) s")
        } else {
            check("found a cloud-only song to play", false, "none in the first 200 rows")
        }

        // Switch to On This Mac (the local-file songs) through the source list's callback and play one.
        app.sources.select(.onThisMac)
        _ = await waitFor(2) { app.tracks.order.count < 100 }
        await settle()
        check("On This Mac lists the local files", (1..<100).contains(app.tracks.order.count), "\(app.tracks.order.count) rows")
        if let local = app.tracks.order.first {
            app.tracks.onActivate?(local, app.tracks.order)
            let playing = await waitFor(8) { app.player.state.nowPlaying?.id == local && app.player.state.position > 1.5 }
            let t = app.player.state.nowPlaying
            check("local file plays", playing && t?.isLocal == true,
                  "“\(t?.title ?? "nil")” \(t?.fileURL?.pathExtension ?? "") at \(fmt(app.player.state.position)) s")
            shot("05-playing-local")
        }

        // Shuffle across the whole library.
        app.sources.select(.library)
        _ = await waitFor(2) { app.tracks.order.count >= 15_900 }
        app.player.setShuffle(true)
        check("shuffle turns on", app.player.state.isShuffling, "")
        let beforeShuffleNext = app.player.state.nowPlaying?.id
        app.player.next()
        let shuffled = await waitFor(12) { app.player.state.nowPlaying?.id != beforeShuffleNext && app.player.state.position > 1 }
        check("shuffle next plays something else", shuffled, "“\(app.player.state.nowPlaying?.title ?? "nil")”")
        app.player.setShuffle(false)

        // Snap-back: start a song from Library, browse to another list, and the LCD arrow returns
        // to the playing song's list and row.
        app.sources.select(.library)
        _ = await waitFor(2) { app.tracks.order.count >= 15_900 }
        if let target = app.tracks.order.dropFirst(40).first {
            app.tracks.onActivate?(target, app.tracks.order)
            _ = await waitFor(8) { app.player.state.nowPlaying?.id == target }
        }
        if let playing = app.player.state.nowPlaying?.id {
            app.sources.select(.onThisMac)
            _ = await waitFor(2) { app.tracks.order.count < 100 }
            app.windowController.controlBar.onRevealNowPlaying?()
            let revealed = await waitFor(3) { app.tracks.query.scope == .library && app.tracks.selectedIDs.first == playing }
            check("LCD snap-back reveals the playing song", revealed,
                  "scope=\(app.tracks.query.scope) selected=\(app.tracks.selectedIDs.first.map(String.init) ?? "none")")
        }

        // Closing the main window keeps the music going (iTunes did); the Dock brings it back.
        if let window = app.windowController.window {
            window.performClose(nil)
            try? await Task.sleep(for: .seconds(2))
            check("closing the window keeps playing", !window.isVisible && app.player.state.isPlaying,
                  "visible=\(window.isVisible) playing=\(app.player.state.isPlaying)")
            _ = NSApp.delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false)
            check("Dock click reopens the window", await waitFor(2) { window.isVisible }, "")
        }

        app.playPause()
        let paused = await waitFor(3) { !app.player.state.isPlaying }
        check("play/pause pauses", paused, "isPlaying=\(app.player.state.isPlaying)")
        app.player.stop()

        // Shuffle with nothing selected: Play must not always start at the top row. Read the queue
        // head right after play() and stop at once, so this makes no sound worth hearing.
        app.sources.select(.library)
        _ = await waitFor(2) { app.tracks.order.count >= 15_900 }
        app.tracks.tableView.deselectAll(nil)
        app.player.setShuffle(true)
        var starts: [Track.ID] = []
        for _ in 0..<3 {
            app.playPause()
            if let first = app.player.queue.first { starts.append(first) }
            app.player.stop()
        }
        app.player.setShuffle(false)
        check("shuffle Play starts somewhere random", starts.count == 3 && Set(starts).count == 3
              && !starts.contains(app.tracks.order.first ?? -1),
              "starts=\(starts) top=\(app.tracks.order.first.map(String.init) ?? "nil") of \(app.tracks.order.count)")

        // Playlists open in their own order (the playlist's "#" order, not artist order).
        if let playlist = (try? await app.index.playlists())?.first(where: { $0.kind == .regular && $0.trackCount > 3 }) {
            app.sources.select(.playlist(playlist.id))
            _ = await waitFor(3) { app.tracks.query.scope == .playlist(playlist.id) }
            await app.tracks.waitForLoad()
            var q = TrackQuery(); q.scope = .playlist(playlist.id); q.sort = TrackSort(field: .playlistOrder, ascending: true)
            let expected = (try? await app.index.ids(for: q)) ?? []
            check("playlist opens in its own order", app.tracks.query.sort.field == .playlistOrder
                  && app.tracks.order == expected && !expected.isEmpty,
                  "“\(playlist.name)”: sort=\(app.tracks.query.sort.field.rawValue) rows=\(app.tracks.order.count)")
            shot("08-playlist-order")
            app.sources.select(.library)
            _ = await waitFor(3) { app.tracks.order.count >= 15_900 }
            await app.tracks.waitForLoad()
        }

        // Checkbox: an unchecked song is skipped by Next. Restores the box afterwards.
        app.tracks.query.sort = TrackSort(field: .artist, ascending: true)
        await app.tracks.waitForLoad()
        let trio = Array(app.tracks.order.dropFirst(60).prefix(3))
        if trio.count == 3 {
            app.tracks.onToggleChecked?([trio[1]], false)
            try? await Task.sleep(for: .milliseconds(600))
            let middle = (try? await app.index.tracks(ids: [trio[1]]))?.first
            check("checkbox click unchecks the song", middle?.isChecked == false, "id \(trio[1]) isChecked=\(String(describing: middle?.isChecked))")
            app.tracks.onActivate?(trio[0], app.tracks.order)
            _ = await waitFor(10) { app.player.state.nowPlaying?.id == trio[0] }
            app.player.next()
            let skipped = await waitFor(10) { app.player.state.nowPlaying?.id == trio[2] }
            check("Next skips the unchecked song", skipped,
                  "expected \(trio[2]), now \(app.player.state.nowPlaying.map { String($0.id) } ?? "nil")")
            app.player.stop()
            app.tracks.onToggleChecked?([trio[1]], true)
            try? await Task.sleep(for: .milliseconds(600))
            let restored = (try? await app.index.tracks(ids: [trio[1]]))?.first
            check("checkbox restored", restored?.isChecked == true, "")
            shot("09-checkboxes")
        }

        // Get Info reads the compilation flag the index now carries.
        let sample = (try? await app.index.tracks(ids: Array(app.tracks.order.prefix(3000)))) ?? []
        if let compilation = sample.first(where: { $0.isCompilation && $0.isCloudOnly }) {
            let fields = try? await app.editor.readFields(of: compilation)
            check("Get Info shows a compilation as one", fields?.isCompilation == true, "“\(compilation.title)”")
        } else {
            check("found a cloud compilation to read", false, "none in the first 3,000 rows")
        }

        // Column browser.
        app.toggleBrowser(nil)
        await settle(0.8)
        check("browser opens", app.tracks.isBrowserVisible, "")
        shot("06-browser")
        app.toggleBrowser(nil)

        // Get Info on a cloud song.
        if let id = app.tracks.order.first {
            app.tracks.reveal(id)
            app.showInfo(for: [id])
            let opened = await waitFor(4) { app.infoWindows.last?.window?.isVisible == true }
            await settle(0.8)
            if let info = app.infoWindows.last?.window {
                Snapshot.write(info, to: dir.appendingPathComponent("07-get-info.png"))
                info.close()
            }
            check("Get Info opens", opened, "")
        }

        // File ▸ Add Folder's panel, built by the code the menu item uses but never shown: it offers
        // "Also add to the Music app" as the user last left it, and promises the upload only while
        // Sync Library is on.
        let (panel, alsoAddToMusic) = app.makeAddFolderPanel()
        let saved = UserDefaults.standard.bool(forKey: AppController.alsoAddToMusicKey)
        let syncLibrary = report.subscription?.hasCloudLibraryEnabled == true
        check("Add Folder panel offers “Also add to the Music app”, \(saved ? "on" : "off") as last left",
              alsoAddToMusic.title.hasPrefix("Also add to the Music app") && (alsoAddToMusic.state == .on) == saved
                  && alsoAddToMusic.title.contains("iCloud Music Library") == syncLibrary
                  && panel.isAccessoryViewDisclosed && panel.accessoryView.map { alsoAddToMusic.isDescendant(of: $0) } == true,
              "“\(alsoAddToMusic.title)”, Sync Library \(syncLibrary ? "on" : "off")")

        Log.info("smoke: SUMMARY \(Self.passed) passed, \(Self.failed) failed; snapshots in \(dir.path)")
        Log.flush()
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    private func check(_ name: String, _ ok: Bool, _ detail: String) {
        if ok { Self.passed += 1 } else { Self.failed += 1 }
        Log.info("smoke: \(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    }

    private func shot(_ name: String) {
        guard let window = app.windowController.window else { return }
        window.displayIfNeeded()
        Snapshot.write(window, to: dir.appendingPathComponent("\(name).png"))
    }

    /// Lets queued reloads and row fetches land before a snapshot or count.
    private func settle(_ seconds: Double = 0.4) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func waitFor(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private func fmt(_ t: TimeInterval) -> String { String(format: "%.1f", t) }
}
