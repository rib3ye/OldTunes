import AppKit

/// Owns every long-lived object and wires the modules together. Modules never reference each
/// other; every connection between them is made here, so this file is the app's whole data flow:
///
///   source list ──scope──▶ track list ──activate──▶ player ──state──▶ control bar, track list
///   search field ──text──▶ track list          ingest ──.libraryDidChange──▶ lists, summary
@MainActor
final class AppController: NSObject {
    let index: LibraryIndex
    let ingest: LibraryIngest
    let player: PlaybackCoordinator
    let editor = TagEditor()
    let playlistEditor: any PlaylistEditing = MusicPlaylistEditor()

    let windowController = MetalWindowController()
    let sources: SourceListViewController
    let tracks: TrackListViewController
    /// The track pane's one subview: the track list, and the visualizer when it shows in its place.
    private let trackStack = NSView()
    /// The visualizer (bottom-bar flower, Visualizer menu). Made in start(), once the panes exist.
    private(set) var visualizer: VisualizerController?

    private(set) var infoWindows: [GetInfoWindowController] = []
    private var keyMonitor: Any?
    /// The scope playback started from. Re-sorting or searching that list re-orders the queue;
    /// browsing a different playlist while a song plays does not (iTunes behaved the same way).
    private var playingScope: LibraryScope?
    private var lastShownError: String?
    /// The Add Folder still running, if any; the next one waits for it.
    private var folderAdds: Task<Void, Never>?
    /// The playlist command still running, if any; the next one waits for it, so Music sees
    /// them in the order they were asked for.
    private var playlistWork: Task<Void, Never>?
    /// Sync Library, as the first ingest read it. Nil until then.
    private var cloudLibraryOn: Bool?

    /// True when the index was damaged and recreated empty at launch, or wasn't there at all;
    /// added folders get re-added.
    private let rebuiltIndex: Bool

    init(index: LibraryIndex, rebuiltIndex: Bool = false) {
        self.index = index
        self.rebuiltIndex = rebuiltIndex
        ingest = LibraryIngest(index: index)
        player = PlaybackCoordinator(library: index, cloud: ingest)
        // Debug and Bench builds: play as if System Audio Recording were off, without changing it in
        // System Settings. iCloud songs then play at their own level, and the visualizer listens
        // through SelfCapture (docs/VISUALIZER.md ▸ Without the permission).
        if LaunchEnvironment.value("OLDTUNES_SIMULATE_NO_SYSTEM_AUDIO") == "1" {
            player.cloud.simulatesMissingPermission = true
        }
        sources = SourceListViewController(library: index)
        tracks = TrackListViewController(library: index)
        super.init()
    }

    /// Runs once the first ingest finishes. Used by the smoke test.
    var onFirstIngest: ((IngestReport) -> Void)?

    func start() {
        embed(sources.view, in: windowController.sourcePane)
        embed(trackStack, in: windowController.trackPane)
        embed(tracks.view, in: trackStack)
        visualizer = VisualizerController(player: player, inlineHost: trackStack, listView: tracks.view)
        visualizer?.onStateChange = { [weak self] in self?.visualizerChanged() }
        tracks.restoreBrowserVisibility()
        windowController.controlBar.isBrowseOn = tracks.isBrowserVisible
        wireControlBar()
        wireBottomBar()
        wireLists()
        wirePlayback()
        installMenus()
        installSpaceBar()

        NotificationCenter.default.addObserver(forName: .libraryDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.libraryChanged() }
        }

        windowController.controlBar.setIdleText("OldTunes", "")
        configureWindow()
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
        windowController.window?.makeFirstResponder(tracks.tableView)
        NSApp.activate()

        Task {
            // Show whatever the index already holds right away, then refresh behind it.
            await reloadLists()
            // Before the ingest rescans the added folders.
            await FolderAccess.openKept()
            let report = await ingest.refresh()
            Log.info("ingest: \(report.status) songs=\(report.musicLibrarySongs) local=\(report.localFiles) " +
                     "cloud=\(report.cloudOnly) joined=\(report.joined) folder=\(report.folderTracks) " +
                     "in \(String(format: "%.2f", report.seconds)) s")
            cloudLibraryOn = report.subscription?.hasCloudLibraryEnabled
            handleIngestStatus(report.status)
            if rebuiltIndex { await readdRememberedFolders() }
            await ingest.startWatchingForChanges()
            if !rebuiltIndex, await AppAssembly.checkIntegrityInBackground(index) == false {
                showError("OldTunes found damage in its library index.",
                          "Quit and reopen OldTunes to rebuild it. Your music and playlists are not affected.")
            }
            onFirstIngest?(report)
            if !isTestBench { await askForFolderAccess() }
        }
    }

    /// 756x500 is the size of the 2005 reference screenshot, which is cramped on a modern display
    /// and hides the Genre and Date Added columns. Open larger the first time, then remember.
    private func configureWindow() {
        guard let window = windowController.window else { return }
        window.initialFirstResponder = tracks.tableView
        if !window.setFrameUsingName(Self.frameName) {
            let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
            let size = NSSize(width: min(1120, visible.width - 40), height: min(720, visible.height - 40))
            window.setContentSize(size)
            window.center()
        }
        window.setFrameAutosaveName(Self.frameName)
    }

    private static let frameName = "OldTunesMainWindow"

    // MARK: - Wiring

    private func wireControlBar() {
        let bar = windowController.controlBar
        bar.onPlayPause = { [weak self] in self?.playPause() }
        bar.onPrevious = { [weak self] in self?.player.previous() }
        bar.onNext = { [weak self] in self?.player.next() }
        bar.onVolumeChange = { [weak self] in self?.setVolume($0) }
        bar.onSeek = { [weak self] in self?.player.seek(to: $0) }
        bar.onSearchTextChange = { [weak self] text in self?.tracks.query.search = text }
        bar.onBrowseToggle = { [weak self] in self?.toggleBrowser(nil) }
        bar.onRevealNowPlaying = { [weak self] in self?.revealNowPlaying() }
    }

    private func wireBottomBar() {
        let bar = windowController.bottomBar
        bar.onAddFolder = { [weak self] in self?.addFolder(nil) }
        bar.onShuffleToggle = { [weak self] in self?.toggleShuffle(nil) }
        bar.onRepeatCycle = { [weak self] in self?.cycleRepeat(nil) }
        bar.onArtworkToggle = { Log.info("artwork pane: not built yet") }
        bar.setArtworkVisible(false)
        bar.visualizerButton.isEnabled = VisualizerController.isSupported
        bar.onVisualizerToggle = { [weak self] in self?.toggleVisualizer(nil) }
    }

    private func wireLists() {
        sources.onScopeChange = { [weak self] scope in self?.tracks.query.scope = scope }
        sources.onNewPlaylist = { [weak self] isFolder, parent in self?.newPlaylist(isFolder: isFolder, in: parent) }
        sources.onRenamePlaylist = { [weak self] playlist, name in self?.renamePlaylist(playlist, to: name) }
        sources.onDuplicatePlaylist = { [weak self] playlist in self?.duplicatePlaylist(playlist) }
        sources.onDeletePlaylist = { [weak self] playlist in self?.deletePlaylist(playlist) }
        tracks.onActivate = { [weak self] id, order in
            guard let self else { return }
            playingScope = tracks.query.scope
            player.play(queue: order, startAt: id)
        }
        tracks.onOrderChange = { [weak self] order in
            guard let self else { return }
            if playingScope == tracks.query.scope, player.state.nowPlaying != nil {
                player.replaceQueue(order)
            }
            updateSummary(order)
        }
        tracks.onGetInfo = { [weak self] ids in self?.showInfo(for: ids) }
        tracks.onToggleChecked = { [weak self] ids, checked in
            guard let index = self?.index else { return }
            Task {
                do { try await index.setChecked(ids: ids, checked: checked) }
                catch { Log.error("setChecked failed for \(ids.count) songs: \(error)") }
            }
        }
    }

    private func wirePlayback() {
        _ = player.addObserver { [weak self] state in
            guard let self else { return }
            windowController.controlBar.update(state)
            tracks.setNowPlaying(state.nowPlaying?.id, isPlaying: state.isPlaying)
            windowController.bottomBar.setShuffle(state.isShuffling)
            windowController.bottomBar.setRepeat(state.repeatMode)
            if let error = state.lastError, error != lastShownError {
                Log.error("playback: \(error)")
            }
            lastShownError = state.lastError
        }
        if UserDefaults.standard.object(forKey: Self.volumeKey) != nil {
            player.setVolume(UserDefaults.standard.float(forKey: Self.volumeKey))
        }
        // Settings ▸ Sound Check, including its preview before OK.
        player.setSoundCheck(SoundCheckPreference.current)
        NotificationCenter.default.addObserver(forName: .soundCheckDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.player.setSoundCheck(SoundCheckPreference.current) }
        }
    }

    // MARK: - Actions

    func playPause() {
        if player.state.nowPlaying != nil { player.playPause(); return }
        // Nothing loaded yet: play the selection, or the top of the list, like iTunes.
        let order = tracks.order
        guard !order.isEmpty else { return }
        playingScope = tracks.query.scope
        // Nothing selected: a nil start lets the coordinator take the first checked, playable song,
        // or a random one under Shuffle. Passing order.first would force that row even if unchecked.
        player.play(queue: order, startAt: tracks.selectedIDs.first)
    }

    /// The LCD's snap-back arrow: show the playing song in the list it was started from.
    func revealNowPlaying() {
        guard let id = player.state.nowPlaying?.id else { NSSound.beep(); return }
        visualizer?.setOn(false)
        Task { @MainActor in
            if let scope = playingScope, scope != tracks.query.scope {
                sources.select(scope)
                // A playlist deleted since playback started has no row to select; fall back to setting
                // the scope directly so the reveal still lands somewhere sensible.
                if tracks.query.scope != scope { tracks.query.scope = scope }
                await tracks.waitForLoad()
            }
            // A search or browser filter can hide the playing song; clear them, as iTunes did.
            if !tracks.order.contains(id) {
                windowController.controlBar.searchText = ""
                var query = tracks.query
                query.search = ""
                query.genre = nil; query.artist = nil; query.album = nil
                tracks.query = query
                await tracks.waitForLoad()
            }
            tracks.reveal(id)
            windowController.window?.makeFirstResponder(tracks.tableView)
        }
    }

    /// Dock click, Window ▸ OldTunes (⌘1), or anything that needs the main window back after a close.
    @objc func showMainWindow(_ sender: Any?) {
        guard let window = windowController.window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        windowController.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc func playPauseAction(_ sender: Any?) { playPause() }
    @objc func nextAction(_ sender: Any?) { player.next() }
    @objc func previousAction(_ sender: Any?) { player.previous() }
    /// The Dock menu's Previous Song: back a song even past 3 s, where previousAction restarts it.
    @objc func previousSongAction(_ sender: Any?) { player.previousSong() }
    @objc func volumeUp(_ sender: Any?) { setVolume(min(1, player.state.volume + 0.1)) }
    @objc func volumeDown(_ sender: Any?) { setVolume(max(0, player.state.volume - 0.1)) }

    /// OldTunes's own volume, as the user last left it.
    static let volumeKey = "OldTunes.volume"

    /// The slider and ⌘↑/⌘↓. OldTunes's own volume is kept between launches, as iTunes kept its
    /// own. Both grey out during an iCloud song OldTunes can't set the level of.
    private func setVolume(_ volume: Float) {
        player.setVolume(volume)
        UserDefaults.standard.set(player.appVolume, forKey: Self.volumeKey)
    }

    @objc func toggleShuffle(_ sender: Any?) { player.setShuffle(!player.state.isShuffling) }

    @objc func cycleRepeat(_ sender: Any?) {
        switch player.state.repeatMode {
        case .off: player.setRepeat(.all)
        case .all: player.setRepeat(.one)
        case .one: player.setRepeat(.off)
        }
    }

    /// The Dock menu's Repeat ▸ Off / All / One. Each item carries its mode.
    @objc func chooseRepeat(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? RepeatMode else { return }
        player.setRepeat(mode)
    }

    @objc func toggleBrowser(_ sender: Any?) {
        tracks.isBrowserVisible.toggle()
        windowController.controlBar.isBrowseOn = tracks.isBrowserVisible
    }

    @objc func focusSearch(_ sender: Any?) { windowController.controlBar.focusSearch() }

    // MARK: - Visualizer

    /// Visualizer ▸ Turn On/Off Visualizer (⌘T, as in iTunes 4.9), and the bottom-bar flower.
    @objc func toggleVisualizer(_ sender: Any?) { visualizer?.toggle() }

    /// Visualizer ▸ Full Screen (⇧⌘F; ⌘F is Search here, and ⌃⌘F stays the window's full screen).
    @objc func toggleVisualizerFullScreen(_ sender: Any?) { visualizer?.toggleFullScreen() }

    /// Visualizer ▸ Show Visualizer Keys, the same list as H.
    @objc func toggleVisualizerKeys(_ sender: Any?) { visualizer?.toggleKeyList() }

    private func visualizerChanged() {
        let on = visualizer?.isOn ?? false
        windowController.bottomBar.setVisualizerOn(on)
        if !on, windowController.window?.firstResponder == nil || !(windowController.window?.firstResponder is NSText) {
            windowController.window?.makeFirstResponder(tracks.tableView)
        }
    }

    @objc func getInfo(_ sender: Any?) { showInfo(for: tracks.selectedIDs) }

    @objc func addFolder(_ sender: Any?) {
        showMainWindow(nil)
        let (panel, alsoAddToMusic) = makeAddFolderPanel()
        guard let window = windowController.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            let handOff = alsoAddToMusic.state == .on
            UserDefaults.standard.set(handOff, forKey: Self.alsoAddToMusicKey)
            self?.enqueueFolderAdd(urls, handingOffToMusic: handOff)
        }
    }

    /// The Add panel, with its one option: also hand the songs to Music, whose Sync Library puts
    /// them in iCloud Music Library. The box starts as the user left it last time; off at first.
    func makeAddFolderPanel() -> (panel: NSOpenPanel, alsoAddToMusic: NSButton) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders of music to add to your OldTunes library."
        // Promise the upload only when Sync Library isn't known to be off.
        let title = cloudLibraryOn == false ? "Also add to the Music app"
            : "Also add to the Music app (uploads to your iCloud Music Library)"
        let box = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        box.state = UserDefaults.standard.bool(forKey: Self.alsoAddToMusicKey) ? .on : .off
        box.sizeToFit()
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: box.frame.width + 40, height: box.frame.height + 24))
        box.setFrameOrigin(NSPoint(x: 20, y: 12))
        accessory.addSubview(box)
        panel.accessoryView = accessory
        panel.isAccessoryViewDisclosed = true
        return (panel, box)
    }

    /// Adds run one after another, so two adds of the same folder never offer Music a file twice
    /// and each hand-off ends with its own alert.
    private func enqueueFolderAdd(_ urls: [URL], handingOffToMusic handOff: Bool) {
        let previous = folderAdds
        folderAdds = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            if handOff {
                await addFoldersHandingOffToMusic(urls)
            } else {
                await addFolders(urls)
            }
        }
    }

    private func addFolders(_ urls: [URL]) async {
        for url in urls {
            // Kept before the scan, so a quit during a long one still finds the folder next launch.
            FolderAccess.remember(url)
            do {
                let added = try await ingest.addFolder(url)
                Log.info("add folder: \(url.path) → \(added) tracks")
                Self.rememberFolder(url)
            } catch {
                Log.error("add folder failed: \(url.path): \(error)")
                showError("Couldn't add “\(url.lastPathComponent)”.", error.localizedDescription)
            }
        }
    }

    /// "Also add to the Music app" on: each folder's files go to Music first, then the folder is
    /// added like any other. Songs Music took show up once Music's change notification brings
    /// them in (about 5 s after its last add). One alert at the end names every file that stayed
    /// OldTunes-only; when Music took everything there is nothing to say.
    private func addFoldersHandingOffToMusic(_ urls: [URL]) async {
        let music = MusicAppLibraryAdder()
        var reports: [MusicHandoffReport] = []
        for url in urls {
            FolderAccess.remember(url)
            do {
                let report = try await ingest.addFolder(url, handingOffTo: music)
                Log.info("add folder with Music: \(url.path) → \(report.handedOff.count) to Music, " +
                         "\(report.refused.count) refused, \(report.notSent.count) not sent, " +
                         "\(report.alreadyInMusic) already in Music, \(report.folderTracks) OldTunes-only tracks")
                Self.rememberFolder(url)
                Self.rememberHandoffs(report.handedOff)
                reports.append(report)
            } catch {
                Log.error("add folder failed: \(url.path): \(error)")
                showError("Couldn't add “\(url.lastPathComponent)”.", error.localizedDescription)
            }
        }
        guard let alert = MusicHandoffReport.alert(for: reports) else { return }
        Log.info("add folder with Music: \(alert.message) \(alert.informative)")
        await RetroAlert.show(alert.message, informative: alert.informative, details: alert.details,
                              on: windowController.window)
    }

    func showInfo(for ids: [Track.ID]) {
        guard !ids.isEmpty else { return }
        Task { [weak self] in
            guard let self, let selection = try? await index.tracks(ids: ids), !selection.isEmpty else { return }
            let ingest = self.ingest
            let info = GetInfoWindowController(
                tracks: selection, visibleOrder: self.tracks.order, editor: self.editor, library: self.index,
                artwork: { track in await ingest.artworkData(for: track) })
            self.infoWindows.append(info)
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: info.window,
                                                   queue: .main) { [weak self, weak info] _ in
                MainActor.assumeIsolated { self?.infoWindows.removeAll { $0 === info } }
            }
            info.showWindow(nil)
        }
    }

    // MARK: - Added folders

    private static let foldersKey = "OldTunes.folderRoots"
    /// The Add panel's "Also add to the Music app" box, as the user last left it.
    static let alsoAddToMusicKey = "OldTunes.AddFolder.alsoAddToMusic"
    /// Every file handed to Music; a copy of the index's record, for a rebuilt index.
    private static let handoffsKey = "OldTunes.musicHandoffs"

    private static func rememberFolder(_ url: URL) {
        var roots = UserDefaults.standard.stringArray(forKey: foldersKey) ?? []
        if !roots.contains(url.path) { roots.append(url.path) }
        UserDefaults.standard.set(roots, forKey: foldersKey)
    }

    private static func rememberHandoffs(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        var all = UserDefaults.standard.stringArray(forKey: handoffsKey) ?? []
        let known = Set(all)
        all += paths.filter { !known.contains($0) }
        UserDefaults.standard.set(all, forKey: handoffsKey)
    }

    /// A test bench runs by itself, so it never stops for a question no one will answer.
    private var isTestBench: Bool { LaunchEnvironment.bench != nil }

    /// Added folders the sandbox keeps shut, most likely added before OldTunes was sandboxed.
    /// Outside ~/Music their songs show as missing; inside it they play, but Get Info can't save
    /// their tags. Asked once per launch, after the first ingest, until every folder is open.
    private func askForFolderAccess() async {
        let shut = await FolderAccess.shut(among: UserDefaults.standard.stringArray(forKey: Self.foldersKey) ?? [])
        let all = shut.all
        guard !all.isEmpty else { return }
        Log.info("folder access: \(shut.unreadable.count) added folder(s) shut, \(shut.readOnly.count) read-only: " +
                 all.joined(separator: ", "))
        let names = all.map { "“\(($0 as NSString).lastPathComponent)”" }.formatted(.list(type: .and))
        let one = all.count == 1
        let consequence = shut.unreadable.isEmpty
            ? "Until then \(one ? "its" : "their") songs play, but changes in Get Info can't be saved."
            : shut.readOnly.isEmpty ? "Until then \(one ? "its" : "their") songs show as missing."
            : "Until then some of their songs show as missing, and changes to the others in Get Info can't be saved."
        let pressed = await RetroAlert.show(
            one ? "OldTunes needs your OK to open a folder you added." : "OldTunes needs your OK to open \(all.count) folders you added.",
            informative: "macOS lets OldTunes open only the folders you choose for it. Choose \(names) again, " +
                "and OldTunes can play \(one ? "its" : "their") songs and save their tags. " + consequence,
            details: all.joined(separator: "\n"),
            buttons: ["Not Now", one ? "Choose Folder…" : "Choose Folders…"], cancelIndex: 0, on: windowController.window)
        guard pressed == 1 else { return }
        var left = all
        while let path = left.first {
            left.removeFirst()
            // An earlier choice may have opened this one too: a folder around both.
            guard await !FolderAccess.shut(among: [path]).all.isEmpty else { continue }
            let opened = await chooseAgain(path, alsoInside: left)
            left.removeAll { opened.contains($0) }
        }
    }

    /// An open panel showing the folder, whose Allow button gives it back to OldTunes. Picking a
    /// folder around it works too, and then also opens any of `others` inside the chosen one.
    /// Returns the folders opened.
    private func chooseAgain(_ path: String, alsoInside others: [String]) async -> [String] {
        guard let window = windowController.window else { return [] }
        let name = (path as NSString).lastPathComponent
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        panel.prompt = "Allow"
        panel.message = "Click Allow to let OldTunes open “\(name)” again."
        guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return [] }
        let chosen = url.standardizedFileURL.path
        let prefix = chosen.hasSuffix("/") ? chosen : chosen + "/"
        guard path == chosen || path.hasPrefix(prefix) else {
            Log.info("folder access: chose \(chosen) for \(path), which isn't it or around it")
            await RetroAlert.show("That isn't the folder “\(name)”.",
                                  informative: "Its songs stay as they are until you choose it, or a folder it is in.",
                                  on: window)
            return []
        }
        let opened = [path] + others.filter { $0 == chosen || $0.hasPrefix(prefix) }
        for folder in opened {
            FolderAccess.remember(url, as: folder)
            do {
                let found = try await ingest.addFolder(URL(fileURLWithPath: folder))
                Log.info("folder access: \(folder) open again → \(found) tracks added or updated")
            } catch {
                Log.error("folder access: rescanning \(folder) failed: \(error)")
            }
        }
        return opened
    }

    private func readdRememberedFolders() async {
        // First, so the scans below keep the songs handed to Music out of the folder rows.
        if let handoffs = UserDefaults.standard.stringArray(forKey: Self.handoffsKey), !handoffs.isEmpty {
            await ingest.restoreHandoffs(handoffs)
        }
        for path in UserDefaults.standard.stringArray(forKey: Self.foldersKey) ?? [] {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let added = (try? await ingest.addFolder(url)) ?? 0
            Log.info("index rebuild: re-added \(path) → \(added) tracks")
        }
    }

    // MARK: - Playlists

    /// The source list's right-click commands. Each one goes to Music first, and only a change
    /// Music has made reaches the index, so a refusal never leaves a playlist on screen that
    /// Music doesn't have. Names are picked when the command runs, after the ones before it.
    /// A command about a playlist an earlier one deleted (Delete pressed twice) does nothing.
    private func enqueuePlaylistWork(about playlist: Int64? = nil, _ work: @escaping @MainActor (AppController) async -> Void) {
        let previous = playlistWork
        playlistWork = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, playlist.map(sources.hasPlaylist) != false else { return }
            await work(self)
        }
    }

    /// iTunes made an "untitled playlist" and opened its name for typing.
    private func newPlaylist(isFolder: Bool, in parent: Int64?) {
        let what = isFolder ? "folder" : "playlist"
        enqueuePlaylistWork { app in
            let name = app.sources.unusedName(isFolder ? "untitled folder" : "untitled playlist")
            do {
                let made = try await app.playlistEditor.makePlaylist(named: name, isFolder: isFolder, in: parent)
                Log.info("playlists: Music made \(what) \(MusicPersistentID.hex(made.id))")
                await app.showPlaylistEdit(.added(made, songsFrom: nil))
                app.sources.beginRename(made.id)
            } catch {
                app.showError("OldTunes couldn’t make a new \(what).", error.localizedDescription)
            }
        }
    }

    private func renamePlaylist(_ playlist: PlaylistInfo, to name: String) {
        enqueuePlaylistWork(about: playlist.id) { app in
            do {
                try await app.playlistEditor.renamePlaylist(playlist.id, to: name)
                Log.info("playlists: Music renamed \(MusicPersistentID.hex(playlist.id))")
                await app.showPlaylistEdit(.renamed(playlist.id, to: name))
            } catch {
                await app.sources.reload()   // puts the old name back
                app.showError("OldTunes couldn’t rename “\(playlist.name)”.", error.localizedDescription)
            }
        }
    }

    private func duplicatePlaylist(_ playlist: PlaylistInfo) {
        enqueuePlaylistWork(about: playlist.id) { app in
            let name = app.sources.unusedName("\(playlist.name) copy")
            do {
                let copy = try await app.playlistEditor.duplicatePlaylist(playlist, named: name)
                Log.info("playlists: Music duplicated \(MusicPersistentID.hex(playlist.id)) as \(MusicPersistentID.hex(copy.id))")
                await app.showPlaylistEdit(.added(copy, songsFrom: playlist.id))
                app.sources.select(.playlist(copy.id))
            } catch {
                app.showError("OldTunes couldn’t duplicate “\(playlist.name)”.", error.localizedDescription)
            }
        }
    }

    /// Asks first, as iTunes did: OldTunes can't undo it, and Sync Library deletes the playlist
    /// on the user's other devices too.
    private func deletePlaylist(_ playlist: PlaylistInfo) {
        enqueuePlaylistWork(about: playlist.id) { app in
            let inside = playlist.kind == .folder ? app.sources.countInside(playlist.id) : 0
            let question = Self.deleteQuestion(for: playlist, inside: inside, cloudLibraryOn: app.cloudLibraryOn)
            let choice = await RetroAlert.show(question.message, informative: question.informative,
                                               buttons: ["Cancel", "Delete"], cancelIndex: 0,
                                               on: app.windowController.window)
            guard choice == 1 else { return }
            do {
                try await app.playlistEditor.deletePlaylist(playlist.id)
            } catch {
                app.showError("OldTunes couldn’t delete “\(playlist.name)”.", error.localizedDescription)
                return
            }
            Log.info("playlists: Music deleted \(MusicPersistentID.hex(playlist.id))")
            app.sources.showDeleted(playlist.id)
            await app.showPlaylistEdit(.deleted(playlist.id))
        }
    }

    /// `inside`: how many playlists a folder holds. `cloudLibraryOn`: Sync Library, nil if unknown.
    static func deleteQuestion(for playlist: PlaylistInfo, inside: Int,
                               cloudLibraryOn: Bool?) -> (message: String, informative: String) {
        let message = switch playlist.kind {
        case .folder where inside == 1:
            "Are you sure you want to delete the folder “\(playlist.name)” and the playlist in it?"
        case .folder where inside > 1:
            "Are you sure you want to delete the folder “\(playlist.name)” and the \(inside) playlists in it?"
        case .folder: "Are you sure you want to delete the folder “\(playlist.name)”?"
        case .smart: "Are you sure you want to delete the smart playlist “\(playlist.name)”?"
        case .regular, .genius: "Are you sure you want to delete the playlist “\(playlist.name)”?"
        }
        let subject = inside > 0 ? "They’re" : "It’s"
        // Promise the other devices only when Sync Library isn't known to be off.
        let gone = cloudLibraryOn == false ? "\(subject) deleted from the Music app too."
            : "\(subject) deleted from the Music app too, and from your iCloud Music Library on all your devices."
        let songs = switch playlist.kind {
        case .folder where inside == 0: ""
        case .folder: " The songs in them stay in your library."
        default: " The songs in it stay in your library."
        }
        return (message, "\(gone)\(songs) You can’t undo this.")
    }

    /// Puts a change Music has made into the index, then waits for the source list to show it.
    private func showPlaylistEdit(_ edit: PlaylistEdit) async {
        do {
            try await index.apply(edit)
        } catch {
            // Music has it either way; the re-ingest after Music's change notification brings it.
            Log.error("playlists: index update failed: \(error)")
        }
        await sources.reload()
    }

    // MARK: - Library

    private func libraryChanged() {
        Task { await reloadLists() }
    }

    private func reloadLists() async {
        await sources.reload()
        await tracks.reload()
        updateSummary(tracks.order)
    }

    private func updateSummary(_ order: [Track.ID]) {
        Task {
            let summary = (try? await index.summary(for: order)) ?? .empty
            windowController.bottomBar.setSummary(SummaryFormatter.string(for: summary))
        }
    }

    private func handleIngestStatus(_ status: IngestReport.Status) {
        switch status {
        case .ok:
            break
        case .notAuthorized(let message):
            // TCC never asks twice, and a new grant only takes effect after relaunch (RESEARCH.md §3.6).
            let info = message.contains("reopen") ? message : message + "\n\nTurn on OldTunes in System " +
                "Settings ▸ Privacy & Security ▸ Media & Apple Music, then quit and reopen OldTunes."
            Task {
                let choice = await RetroAlert.show("OldTunes can't see your music library.", informative: info,
                                                   buttons: ["Not Now", "Open System Settings"], cancelIndex: 0,
                                                   on: windowController.window)
                guard choice == 1 else { return }
                let pane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Media")
                if pane.map({ NSWorkspace.shared.open($0) }) != true {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
                }
            }
        case .failed(let message):
            showError("OldTunes couldn't read your music library.", message)
        }
    }

    private func showError(_ title: String, _ detail: String) {
        Log.error("\(title) \(detail)")
        Task { await RetroAlert.show(title, informative: detail, on: windowController.window) }
    }

    // MARK: - Menus and keys

    private func installMenus() {
        guard let main = NSApp.mainMenu else { return }

        let file = NSMenu(title: "File")
        file.addItem(item("Add Folder to Library…", #selector(addFolder(_:)), "o"))
        file.addItem(.separator())
        file.addItem(item("Get Info", #selector(getInfo(_:)), "i"))
        file.addItem(.separator())
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let appIndex = 1 // after the app menu
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileItem.submenu = file
        main.insertItem(fileItem, at: min(appIndex, main.items.count))

        if let edit = main.items.first(where: { $0.submenu?.title == "Edit" })?.submenu {
            edit.addItem(.separator())
            edit.addItem(item("Find", #selector(focusSearch(_:)), "f"))
        }

        let controls = NSMenu(title: "Controls")
        controls.addItem(item("Play/Pause", #selector(playPauseAction(_:)), ""))
        controls.addItem(item("Next Song", #selector(nextAction(_:)), String(UnicodeScalar(NSRightArrowFunctionKey)!)))
        controls.addItem(item("Previous Song", #selector(previousAction(_:)), String(UnicodeScalar(NSLeftArrowFunctionKey)!)))
        controls.addItem(.separator())
        controls.addItem(item("Shuffle", #selector(toggleShuffle(_:)), ""))
        controls.addItem(item("Repeat", #selector(cycleRepeat(_:)), ""))
        controls.addItem(.separator())
        controls.addItem(item("Volume Up", #selector(volumeUp(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!)))
        controls.addItem(item("Volume Down", #selector(volumeDown(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!)))
        MainMenu.insert(controls, into: main)

        if let window = NSApp.windowsMenu {
            window.insertItem(item("OldTunes", #selector(showMainWindow(_:)), "1"), at: 0)
            window.insertItem(.separator(), at: 1)
        }

        // iTunes 4.9 kept its visualizer in a menu of its own, between Controls and Advanced.
        if VisualizerController.isSupported {
            let visualizerMenu = NSMenu(title: "Visualizer")
            visualizerMenu.addItem(item("Turn On Visualizer", #selector(toggleVisualizer(_:)), "t"))
            visualizerMenu.addItem(.separator())
            // Uppercase F is ⇧⌘F: NSMenu matches a shifted equivalent by its uppercase letter (measured).
            visualizerMenu.addItem(item("Full Screen", #selector(toggleVisualizerFullScreen(_:)), "F"))
            visualizerMenu.addItem(.separator())
            visualizerMenu.addItem(item("Show Visualizer Keys", #selector(toggleVisualizerKeys(_:)), ""))
            MainMenu.insert(visualizerMenu, into: main)
        }

        let view = NSMenu(title: "View")
        view.addItem(item("Show Browser", #selector(toggleBrowser(_:)), "b"))
        MainMenu.insert(view, into: main)
    }

    /// The Dock icon's right-click menu. AppDelegate asks for a new one each time it opens.
    func dockMenu() -> NSMenu { DockMenu.make(for: player.state, target: self) }

    private func item(_ title: String, _ action: Selector, _ key: String,
                      _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }

    /// Space plays/pauses unless the user is typing (search field, Get Info). A bare-space menu key
    /// equivalent would steal the space bar from text fields, so this is an event monitor instead.
    private func installSpaceBar() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 49,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                  !(event.window?.firstResponder is NSText),
                  let window = event.window,
                  window === self?.windowController.window || window === self?.visualizer?.fullScreenWindowForKeys
            else { return event }
            self?.playPause()
            return nil
        }
    }

    private func embed(_ child: NSView, in container: NSView) {
        child.frame = container.bounds
        child.autoresizingMask = [.width, .height]
        container.addSubview(child)
    }
}

extension AppController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(getInfo(_:)):
            return !tracks.selectedIDs.isEmpty
        case #selector(toggleShuffle(_:)):
            menuItem.state = player.state.isShuffling ? .on : .off
        case #selector(cycleRepeat(_:)):
            menuItem.title = switch player.state.repeatMode {
            case .off: "Repeat Off"
            case .all: "Repeat All"
            case .one: "Repeat One"
            }
        case #selector(toggleBrowser(_:)):
            menuItem.title = tracks.isBrowserVisible ? "Hide Browser" : "Show Browser"
        case #selector(playPauseAction(_:)):
            menuItem.title = player.state.isPlaying ? "Pause" : "Play"
        case #selector(volumeUp(_:)), #selector(volumeDown(_:)):
            return player.state.isVolumeEnabled
        case #selector(toggleVisualizer(_:)):
            menuItem.title = visualizer?.isOn == true ? "Turn Off Visualizer" : "Turn On Visualizer"
        case #selector(toggleVisualizerFullScreen(_:)):
            menuItem.state = visualizer?.isFullScreen == true ? .on : .off
        case #selector(toggleVisualizerKeys(_:)):
            menuItem.title = visualizer?.view?.isShowingKeyList == true ? "Hide Visualizer Keys" : "Show Visualizer Keys"
            return visualizer?.isOn == true
        default:
            break
        }
        return true
    }
}
