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
    let downloader: any SongDownloading = MusicSongDownloader()

    let windowController = MetalWindowController()
    let sources: SourceListViewController
    let tracks: TrackListViewController
    /// The track pane's one subview: the track list, and the visualizer when it shows in its place.
    private let trackStack = NSView()
    /// The visualizer (bottom-bar flower, Visualizer menu). Made in start(), once the panes exist.
    private(set) var visualizer: VisualizerController?

    private(set) var infoWindows: [GetInfoWindowController] = []
    private var keyMonitor: Any?
    /// The volume Mute (⌥⌘↓) took away, while muted.
    private var volumeBeforeMute: Float?
    /// The scope playback started from. Re-sorting or searching that list re-orders the queue;
    /// browsing a different playlist while a song plays does not (iTunes behaved the same way).
    private var playingScope: LibraryScope?
    private var lastShownError: String?
    /// The Add Folder still running, if any; the next one waits for it.
    private var folderAdds: Task<Void, Never>?
    /// The playlist command still running, if any; the next one waits for it, so Music sees
    /// them in the order they were asked for.
    private var playlistWork: Task<Void, Never>?
    /// The newest name typed over each playlist that Music hasn't been sent yet, with the number
    /// of the rename that asked for it (`renamePlaylist`). An add sends the one over the playlist
    /// it is filling between two chunks (`addInChunks`), rather than after the whole add.
    private var namesToSend: [Int64: (name: String, rename: Int)] = [:]
    private var renames = 0
    /// The songs on their way down from iCloud, drawn with the blue cloud (RESEARCH.md §6.9).
    private let downloads = DownloadWatch()
    /// The Download still asking Music for its songs, if any; the next one waits for it.
    private var downloadWork: Task<Void, Never>?
    /// True while a Download asks Music for its songs, one by one.
    private var isSendingDownloads = false
    /// Settles and ticks `downloads` every 30 s while it watches anything.
    private var downloadTicks: Task<Void, Never>?
    /// A tick asked for a re-read that was already running or waiting, and the log has said so:
    /// once for a run of ticks that asked (`tickDownloads`).
    private var skippedReReadLogged = false
    /// The same for a re-read that failed: said once for a run of ticks that asked.
    private var failedReReadLogged = false
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
        installArrowKeys()

        NotificationCenter.default.addObserver(forName: .libraryDidChange, object: nil, queue: .main) { [weak self] note in
            let filled = note.userInfo?[LibraryChange.songsAddedTo] as? Int64
            MainActor.assumeIsolated { self?.libraryChanged(songsAddedTo: filled) }
        }
        // Quitting Music is how a user stops a long download: nothing more comes down after it.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == MusicAutomation.bundleID else { return }
            MainActor.assumeIsolated { self?.musicQuit() }
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
        sources.onAddSongs = { [weak self] ids, playlist in self?.addSongs(ids, to: playlist) }
        sources.onDownloadPlaylist = { [weak self] playlist in self?.downloadPlaylist(playlist) }
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
        tracks.onDownload = { [weak self] ids in self?.download(ids) }
        tracks.onAddToPlaylist = { [weak self] ids, id in
            // The playlist as the source list shows it, a name typed over it included, for the alerts.
            guard let self, let playlist = sources.playlist(id) else { return }
            addSongs(ids, to: playlist)
        }
        tracks.onNewPlaylistFromSelection = { [weak self] ids in self?.newPlaylistFromSelection(ids) }
        tracks.playlistMenu = { [weak self] in self?.sources.playlistTree ?? [] }
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

    /// Controls ▸ Mute (⌥⌘↓), as in iTunes: the slider drops to the bottom, and Mute again puts it
    /// back. Moving the volume any other way ends the mute, from the bottom.
    @objc func toggleMute(_ sender: Any?) {
        if let level = volumeBeforeMute {
            setVolume(level)
        } else {
            volumeBeforeMute = player.state.volume
            // Not saved, so a relaunch comes back at the level from before the mute.
            player.setVolume(0)
        }
    }

    /// OldTunes's own volume, as the user last left it.
    static let volumeKey = "OldTunes.volume"

    /// The slider and ⌘↑/⌘↓. OldTunes's own volume is kept between launches, as iTunes kept its
    /// own. Both grey out during an iCloud song OldTunes can't set the level of.
    private func setVolume(_ volume: Float) {
        volumeBeforeMute = nil
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

    /// File ▸ New Playlist (⌘N): an untitled playlist at the top level, as iTunes 4.9 made one.
    /// The main window comes forward first, as for Add Folder: the name opens for typing there,
    /// and a Get Info window in front would take the keystrokes.
    @objc func newPlaylistAction(_ sender: Any?) {
        showMainWindow(nil)
        newPlaylist(isFolder: false, in: nil)
    }

    /// File ▸ New Playlist from Selection (⇧⌘N).
    @objc func newPlaylistFromSelectionAction(_ sender: Any?) {
        showMainWindow(nil)
        newPlaylistFromSelection(tracks.selectedIDs)
    }

    /// File ▸ Download, which reads Stop Downloading while OldTunes is still asking Music for
    /// songs: a big Download takes minutes to ask for, and stopping it is the only undo. The
    /// title clicked counts (`downloadClickStops`): the last song can be asked for while the menu
    /// is open, and Stop Downloading must never start a Download of whatever is selected.
    @objc func downloadAction(_ sender: Any?) {
        if Self.downloadClickStops(isAsking: downloads.isAsking, clickedTitle: (sender as? NSMenuItem)?.title) {
            stopDownloading()
            return
        }
        showMainWindow(nil)
        download(tracks.selectedIDs)
    }

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
    ///
    /// A command can run minutes after it was asked for, the moment a long add ahead of it ends,
    /// while the user is typing a playlist's name. So one that asks first (a big add, a delete)
    /// or opens a name box (⌘N, ⇧⌘N) waits until that name is done (`renamesEnded`): the Return
    /// that ends the name would otherwise answer its question, and opening its box would close
    /// the user's, sending a half-typed name to Music. A name being typed when the user gives ⌘N
    /// or ⇧⌘N ends right then, as in iTunes (`newPlaylist`), so their boxes wait only for one
    /// opened since. The wait always ends, since every way a name box ends happens off this queue.
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
        // A name the user is typing ends now, keeping what was typed, as a click elsewhere would.
        // Its rename is queued first, so Music gets that name first, and the keys typed next go to
        // the new playlist's box, never into the old one.
        sources.endRenaming()
        let what = isFolder ? "folder" : "playlist"
        enqueuePlaylistWork { app in
            // ⌘N can come before the list has first read the playlists.
            await app.sources.loadIfNeeded()
            let name = app.sources.unusedName(isFolder ? "untitled folder" : "untitled playlist")
            do {
                let made = try await app.playlistEditor.makePlaylist(named: name, isFolder: isFolder, in: parent)
                Log.info("playlists: Music made \(what) \(MusicPersistentID.hex(made.id))")
                await app.showPlaylistEdit(.added(made, songsFrom: nil))
                // Not over a name opened since this was asked for (`enqueuePlaylistWork`).
                await app.sources.renamesEnded()
                app.sources.beginRename(made.id)
            } catch {
                app.showError("OldTunes couldn’t make a new \(what).", error.localizedDescription)
            }
        }
    }

    /// The source list shows the typed name from the moment it is typed, through any reload,
    /// until this ends it (`endPendingRename`): once the index has it, or Music refused it.
    /// A name typed over the playlist an add is filling goes to Music before the add's next chunk
    /// (`addInChunks`) rather than after the whole add, so quitting OldTunes after that doesn't
    /// lose it, and this then has nothing left to send. One typed during the add's last chunk
    /// (all of an add of 25 songs or fewer) goes from here, as soon as the add ends. Nor has this
    /// anything to send when a newer name was typed since: that rename sends it.
    private func renamePlaylist(_ playlist: PlaylistInfo, to name: String) {
        renames += 1
        let rename = renames
        namesToSend[playlist.id] = (name, rename)
        enqueuePlaylistWork { app in
            guard app.namesToSend[playlist.id]?.rename == rename else {
                app.sources.endPendingRename(playlist.id, name: name)
                return
            }
            app.namesToSend[playlist.id] = nil
            // Deleted since, by an earlier command or in Music: nothing to rename.
            guard app.sources.hasPlaylist(playlist.id) else {
                app.sources.endPendingRename(playlist.id, name: name)
                return
            }
            do {
                try await app.playlistEditor.renamePlaylist(playlist.id, to: name)
                Log.info("playlists: Music renamed \(MusicPersistentID.hex(playlist.id))")
                await app.showPlaylistEdit(.renamed(playlist.id, to: name))
                app.sources.endPendingRename(playlist.id, name: name)
            } catch {
                app.sources.endPendingRename(playlist.id, name: name)   // puts the old name back
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
            // Not over a name being typed (`enqueuePlaylistWork`). Then the playlist as the list
            // shows it: the box that just closed may have renamed it, or a reload taken it away.
            await app.sources.renamesEnded()
            guard let playlist = app.sources.playlist(playlist.id) else { return }
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

    /// Songs dropped on a playlist, or Add to Playlist ▸ (RESEARCH.md §6.10), queued behind the
    /// playlist commands asked for before them. A song already in the playlist is left out
    /// without a word: OldTunes shows each song once per playlist, so a second copy would be real
    /// in Music and on every device but never seen here.
    private func addSongs(_ ids: [Track.ID], to playlist: PlaylistInfo) {
        enqueuePlaylistWork(about: playlist.id) { app in
            // OldTunes can't take them back out, and a big add holds up every playlist command.
            guard let add = await app.confirmAdd(ids, to: playlist) else { return }
            if add.plan.alreadyThere > 0 {
                Log.info("playlists: \(add.plan.alreadyThere) songs left out, already in \(MusicPersistentID.hex(playlist.id))")
            }
            await app.addInChunks(add.plan, from: add.rows, to: playlist, firstChunkStartsMusic: true)
        }
    }

    /// An add's songs as the index has them now: their rows, and what goes to Music
    /// (`addSongsPlan`), leaving out the songs `playlist` has already (nil: a new playlist, which
    /// has none). Nil when the index couldn't be read, which the user is told.
    private func readAdd(_ ids: [Track.ID], to playlist: PlaylistInfo?) async -> (rows: [Track], plan: AddSongsPlan)? {
        do {
            let rows = try await index.tracks(ids: ids)
            var members = Set<Track.ID>()
            if let playlist { members = Set(try await index.ids(for: TrackQuery(scope: .playlist(playlist.id)))) }
            return (rows, Self.addSongsPlan(rows: rows, members: members))
        } catch {
            showError(playlist.map { "OldTunes couldn’t add songs to “\($0.name)”." } ?? "OldTunes couldn’t make a new playlist.",
                      error.localizedDescription)
            return nil
        }
    }

    /// An add's songs (`readAdd`), asked about first when the add is big (`addSongsQuestion`):
    /// nil to send none, when the user says Cancel, a read fails, or the playlist has gone.
    /// `playlist` nil: a new playlist, not made yet.
    ///
    /// The question waits for any name being typed (`enqueuePlaylistWork`), for minutes perhaps,
    /// so after a wait the songs are read again: its count and the songs sent are then the
    /// playlist's as it is, and it names the playlist as the list shows it (the box that just
    /// closed may have been this playlist's). A playlist the list no longer has (Music deleted it,
    /// and a re-ingest took it away) gets no question, and nothing goes to Music: the add's own
    /// alert says so, with every song not sent.
    private func confirmAdd(_ ids: [Track.ID], to playlist: PlaylistInfo?) async -> (rows: [Track], plan: AddSongsPlan)? {
        guard var add = await readAdd(ids, to: playlist) else { return nil }
        // Whether it asks depends only on the count.
        guard Self.addSongsQuestion(count: add.plan.send.count, to: playlist?.name) != nil else { return add }
        // Looked at again after each read, so nothing that waits comes between the last look and
        // the question: a box can open while the songs are read.
        while sources.renamingID != nil {
            await sources.renamesEnded()
            guard let again = await readAdd(ids, to: playlist) else { return nil }
            add = again
        }
        var name: String?
        if let playlist {
            guard let shown = sources.playlist(playlist.id) else {
                Log.info("playlists: \(MusicPersistentID.hex(playlist.id)) left the list before a big add’s question, " +
                         "so none of its \(add.plan.send.count) songs went to Music")
                showAddSongsAlert(add.plan, from: add.rows, to: playlist,
                                  report: PlaylistAddReport(stopReason: MusicPlaylistEditor.playlistGoneReason, retryWontHelp: true),
                                  notSent: add.plan.send)
                return nil
            }
            name = shown.name
        }
        guard let question = Self.addSongsQuestion(count: add.plan.send.count, to: name) else { return add }
        let choice = await RetroAlert.show(question.message, informative: question.informative,
                                           buttons: ["Cancel", "Add"], cancelIndex: 0, on: windowController.window)
        return choice == 1 ? add : nil
    }

    /// File ▸ New Playlist from Selection (⇧⌘N), and Add to Playlist ▸ New Playlist: an
    /// untitled playlist with the songs, as iTunes made one. Its name opens for typing as soon
    /// as Music has made it, and the songs follow as Music adds them. When none of the songs can
    /// go in a Music playlist, nothing is made: an empty playlist would only reach every device.
    private func newPlaylistFromSelection(_ ids: [Track.ID]) {
        guard !ids.isEmpty else { return }
        // A name the user is typing ends now, as for ⌘N (`newPlaylist`).
        sources.endRenaming()
        enqueuePlaylistWork { app in
            guard let add = await app.confirmAdd(ids, to: nil) else { return }
            let (rows, plan) = add
            guard !plan.send.isEmpty else {
                app.showAddSongsAlert(plan, from: rows, to: nil, report: PlaylistAddReport(), notSent: [])
                return
            }
            let made: PlaylistInfo
            do {
                // ⇧⌘N can come before the source list has first read the playlists.
                await app.sources.loadIfNeeded()
                // At the top level: iTunes 4.9 had no folders.
                made = try await app.playlistEditor.makePlaylist(named: app.sources.unusedName("untitled playlist"),
                                                                 isFolder: false, in: nil)
            } catch {
                app.showError("OldTunes couldn’t make a new playlist.", error.localizedDescription)
                return
            }
            Log.info("playlists: Music made playlist \(MusicPersistentID.hex(made.id)) for \(plan.send.count) songs")
            await app.showPlaylistEdit(.added(made, songsFrom: nil))
            // Not over a name opened since this was asked for (`enqueuePlaylistWork`); the songs
            // go in once this playlist's own box is open.
            await app.sources.renamesEnded()
            // What is typed shows at once. It goes to Music before the add's next chunk, or, when
            // typed during the last one, as soon as the add ends (`renamePlaylist`).
            app.sources.beginRename(made.id)
            // Making it has just started Music and checked the permission, so no chunk needs to.
            // Quitting Music still stops the add: if Music quit while this waited for another
            // name above, the first chunk stops before any song goes in, as a later one would,
            // and the playlist stays, empty. And a playlist Music has just made takes songs: a
            // refusal of the first one is about that song, not about the playlist.
            await app.addInChunks(plan, from: rows, to: made, firstChunkStartsMusic: false)
        }
    }

    /// Sends the plan's songs to Music `addChunkSize` at a time, each chunk into the index as it
    /// goes in, so the playlist fills as Music adds them. Stops where Music stopped, and ends with
    /// one alert if any song didn't go in. `firstChunkStartsMusic`: the first chunk may start
    /// Music and ask for permission, as every playlist command does; later ones never do. What
    /// each chunk means for the add is `addChunkContinues` and `addChunkStep`'s to say.
    private func addInChunks(_ plan: AddSongsPlan, from rows: [Track], to playlist: PlaylistInfo,
                             firstChunkStartsMusic: Bool) async {
        let started = Date()
        var report = PlaylistAddReport()
        var notSent: [Int64] = []
        var next = 0
        // A rename whose name Music turned down between two chunks: its own queued rename tries again.
        var renameRefused: Int?
        while next < plan.send.count {
            let continuing = Self.addChunkContinues(at: next, firstChunkStartsMusic: firstChunkStartsMusic)
            // Quitting Music is how a user stops a long add. The editor checks too, on the
            // scripting queue just before the chunk's first event (finding the playlist, which
            // would start Music again), since a chunk can wait its turn there behind a download.
            if continuing, !MusicAutomation.isMusicRunning {
                report.stopReason = MusicPlaylistEditor.musicQuitReason
                notSent = Array(plan.send[next...])
                break
            }
            // A name typed over this playlist while it fills (New Playlist from Selection's) goes
            // to Music now, rather than after the whole add (`renamePlaylist`), and as this chunk
            // goes: only the first may start Music, and a quit since the check above fails it.
            if let typed = namesToSend[playlist.id], typed.rename != renameRefused,
               await !sendTypedName(typed.name, of: playlist.id, rename: typed.rename, continuing: continuing) {
                renameRefused = typed.rename
            }
            let chunk = Array(plan.send[next..<min(next + Self.addChunkSize, plan.send.count)])
            let part = await playlistEditor.addSongs(chunk, to: playlist.id, continuing: continuing)
            next += chunk.count
            let step = Self.addChunkStep(part, chunk: chunk, rest: plan.send[next...], into: &report)
            if !step.apply.isEmpty {
                await showPlaylistEdit(.songsAdded(playlist.id, persistentIDs: step.apply))
            }
            if let unsent = step.notSent {
                notSent = unsent
                break
            }
        }
        if Self.addRereadsLibrary(after: report) {
            // Asked for now, rather than left to Music's next change notification, and run after any
            // re-read already going, which may have read the library before this add's last songs
            // went in and would read it again only after its back-off (`LibraryIngest.refreshSoon`).
            Task { [ingest] in _ = await ingest.refreshSoon() }
        }
        if !plan.send.isEmpty {
            Log.info("playlists: added \(report.added.count) of \(plan.send.count) songs to \(MusicPersistentID.hex(playlist.id)) " +
                     "in \(String(format: "%.1f", Date().timeIntervalSince(started))) s, \(report.refused.count) refused, " +
                     "\(report.unanswered == nil ? 0 : 1) unanswered, \(notSent.count) not sent, " +
                     "\(plan.oldTunesOnly.count) only in OldTunes" + (report.stopReason.map { "; stopped: \($0)" } ?? ""))
        }
        showAddSongsAlert(plan, from: rows, to: playlist, report: report, notSent: notSent)
    }

    /// A name typed over the playlist an add is filling, sent between two of the add's chunks as
    /// `renamePlaylist` would send it after the whole add. `continuing`: the next chunk's
    /// (`addChunkContinues`), so the name never starts Music where that chunk may not; if Music
    /// has quit, it doesn't go (-600), and the chunk's own check then stops the add. False when
    /// it didn't go, Music having quit or turned it down: the name stays queued, and the rename
    /// queued for it tries again after the add and says why.
    private func sendTypedName(_ name: String, of id: Int64, rename: Int, continuing: Bool) async -> Bool {
        do {
            try await playlistEditor.renamePlaylist(id, to: name, continuing: continuing)
        } catch {
            // By code only: the error's text quotes the name.
            Log.error("playlists: renaming \(MusicPersistentID.hex(id)) between two chunks of an add failed" +
                      ((error as? TagEditError)?.code.map { " (error \($0))" } ?? "") + "; it is tried again after the add")
            return false
        }
        Log.info("playlists: Music renamed \(MusicPersistentID.hex(id)), between two chunks of an add")
        // A newer name typed meanwhile still goes.
        if namesToSend[id]?.rename == rename { namesToSend[id] = nil }
        await showPlaylistEdit(.renamed(id, to: name))
        sources.endPendingRename(id, name: name)
        return true
    }

    /// The one alert after an add, when a song didn't go in. Not waited for: it shows while the
    /// next playlist command goes ahead. `playlist` nil: New Playlist from Selection made none.
    /// While any playlist's name is open for typing (New Playlist from Selection opens one, and
    /// ⌘N or Rename may open another), the alert waits, so its sheet never takes the keys halfway
    /// through a name, and then it shows the name typed.
    private func showAddSongsAlert(_ plan: AddSongsPlan, from rows: [Track], to playlist: PlaylistInfo?,
                                   report: PlaylistAddReport, notSent: [Int64]) {
        let titles = Dictionary(rows.compactMap { row in row.persistentID.map { ($0, row.displayTitle) } },
                                uniquingKeysWith: { first, _ in first })
        let title = { (pid: Int64) in titles[pid] ?? "Song \(MusicPersistentID.hex(pid))" }
        let refused = report.refused.map { "\(title($0.persistentID)) — \($0.reason)" }
        let unsent = notSent.map(title), unanswered = report.unanswered.map(title)
        let oldTunesOnly = plan.oldTunesOnly.map(\.displayTitle)
        func alert(named name: String?) -> (message: String, informative: String, details: String)? {
            Self.addSongsAlert(to: name, asked: rows.count, refused: refused, notSent: unsent,
                               stopReason: report.stopReason, oldTunesOnly: oldTunesOnly,
                               unanswered: unanswered, retryWontHelp: report.retryWontHelp)
        }
        // Whether there is anything to say doesn't depend on the name.
        guard alert(named: playlist?.name) != nil else { return }
        // By ID: the alert's text names the playlist.
        Log.info("playlists: add to \(playlist.map { MusicPersistentID.hex($0.id) } ?? "a new playlist") ended with " +
                 "\(report.refused.count) refused, \(report.unanswered == nil ? 0 : 1) unanswered, " +
                 "\(notSent.count) not sent, \(plan.oldTunesOnly.count) only in OldTunes")
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Here, not on the playlist queue, so the commands after the add aren't held while
            // its sheet is up.
            await sources.renamesEnded()
            // As the list shows it now: a name may have been typed over an untitled playlist meanwhile.
            let name = playlist.map { sources.playlist($0.id)?.name ?? $0.name }
            guard let shown = alert(named: name) else { return }
            await RetroAlert.show(shown.message, informative: shown.informative, details: shown.details,
                                  on: windowController.window)
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

    // MARK: Adds and downloads, decided and worded (pure, so the playlists bench checks them)

    /// How many songs one `addSongs(_:to:continuing:)` call carries: one conversation with
    /// Music each, so a tag save, a download request or an Add Folder hand-off never waits long
    /// behind a big add. Other playlist commands wait for the whole add on `playlistWork`; only a
    /// name typed over the playlist being filled goes to Music between two chunks.
    static let addChunkSize = 25
    /// An add of more songs than this asks first: OldTunes can't take them back out.
    static let bigAddSongs = 500
    /// A Download of more songs, or more bytes, than this asks first: the files take up the
    /// disk, and only Music can remove them again.
    static let bigDownloadSongs = 100
    static let bigDownloadBytes: Int64 = 2_000_000_000

    /// What an add sends Music and what it leaves out (`addSongsPlan`).
    struct AddSongsPlan: Sendable, Equatable {
        /// Persistent IDs, in the order the songs were given.
        var send: [Int64] = []
        /// Songs only in OldTunes (added folders): Music can't be told which song they are.
        var oldTunesOnly: [Track] = []
        /// Songs the playlist has already, or that came earlier in the same list.
        var alreadyThere = 0
    }

    /// Splits the songs of an add: Music's own songs go in, in their order, once each and only if
    /// the playlist (`members`, its Track.IDs) doesn't have them yet.
    static func addSongsPlan(rows: [Track], members: Set<Track.ID>) -> AddSongsPlan {
        var plan = AddSongsPlan()
        var going = Set<Track.ID>()
        for row in rows {
            guard row.origin == .musicLibrary, let pid = row.persistentID else {
                plan.oldTunesOnly.append(row)
                continue
            }
            if members.contains(row.id) || !going.insert(row.id).inserted {
                plan.alreadyThere += 1
            } else {
                plan.send.append(pid)
            }
        }
        return plan
    }

    /// Whether the add's chunk starting at song `next` goes on from one before it (`addSongs`'s
    /// `continuing`), and so never starts Music: every chunk but the first, and the first too
    /// when the add needn't start Music (New Playlist from Selection: making its playlist just
    /// did). Quitting Music is how a user stops a long add, so a continuing chunk stops instead.
    static func addChunkContinues(at next: Int, firstChunkStartsMusic: Bool) -> Bool {
        next > 0 || !firstChunkStartsMusic
    }

    /// One chunk's report (`part`), taken into the add's (`report`): returns the songs to put in
    /// the index now, in the order Music added them, and nil `notSent` to go on to the next chunk.
    /// When Music stopped, `notSent` is the chunk's songs from the one the add stopped at, then
    /// `rest`, the later chunks'. The song it stopped at is left out when Music took it, turned it
    /// down (it is among `refused`), or may still add it (`unanswered`: Music didn't answer its
    /// `duplicate` in time). Any chunk's `retryWontHelp` holds for the add.
    static func addChunkStep(_ part: PlaylistAddReport, chunk: [Int64], rest: some Collection<Int64>,
                             into report: inout PlaylistAddReport) -> (apply: [Int64], notSent: [Int64]?) {
        report.added += part.added
        report.refused += part.refused
        report.unanswered = report.unanswered ?? part.unanswered
        report.retryWontHelp = report.retryWontHelp || part.retryWontHelp
        guard let reason = part.stopReason else { return (part.added, nil) }
        report.stopReason = reason
        var answered = Set(part.added).union(part.refused.map(\.persistentID))
        if let unanswered = part.unanswered { answered.insert(unanswered) }
        return (part.added, chunk.filter { !answered.contains($0) } + rest)
    }

    /// Whether an add ends by re-reading the library (`LibraryIngest.refreshSoon`) rather than
    /// waiting for Music to say it changed: Music may still put in the song whose `duplicate` it
    /// didn't answer in time, and the next add's plan reads the playlist's songs from the index;
    /// or the playlist is gone from Music, and the source list should let it go too.
    static func addRereadsLibrary(after report: PlaylistAddReport) -> Bool {
        report.unanswered != nil || report.stopReason == MusicPlaylistEditor.playlistGoneReason
    }

    /// Nil unless the add is big. `playlist` nil: a new playlist, not made yet.
    static func addSongsQuestion(count: Int, to playlist: String?) -> (message: String, informative: String)? {
        guard count > bigAddSongs else { return nil }
        return ("Add \(count.formatted()) songs to \(playlist.map { "“\($0)”" } ?? "a new playlist")?",
                "OldTunes can’t take songs back out of a playlist; the Music app can.")
    }

    /// The one alert after an add, nil when every song went in (or was there already), worded
    /// like Add Folder's hand-off alert. `asked`: every song the add was about. `refused`: one
    /// line per song, “Title — Music's reason”. `playlist` nil: New Playlist from Selection,
    /// which made nothing because every song was only in OldTunes. `unanswered`: the song whose
    /// `duplicate` Music didn't answer in time; it may still go in, so it isn't counted as not
    /// added, and nothing promises a retry won't add it twice. `retryWontHelp`: the stop is one
    /// adding the songs again would only meet again (PlaylistAddReport), so the alert neither
    /// says to try again nor to add the songs only in OldTunes to that playlist later.
    static func addSongsAlert(to playlist: String?, asked: Int, refused: [String], notSent: [String],
                              stopReason: String?, oldTunesOnly: [String], unanswered: String? = nil,
                              retryWontHelp: Bool = false) -> (message: String, informative: String, details: String)? {
        let missed = refused.count + notSent.count + oldTunesOnly.count
        guard missed > 0 else { return nil }
        let asked = max(asked, missed)
        let only = oldTunesOnly.count, one = only == 1
        // Add Folder's own advice, and the step after it, if there is one.
        func handOff(then: String?) -> String {
            "To give \(one ? "it" : "them") to Music, choose Add Folder to Library again with “Also add to the Music app” on"
                + (then.map { ", then \($0) once \(one ? "it shows" : "they show") up." } ?? ".")
        }
        guard let playlist else {
            guard only > 0 else { return nil }
            return ("OldTunes couldn’t make a new playlist.",
                    "\(one ? "This song is" : "These songs are") only in OldTunes, so \(one ? "it" : "they") can’t go in a "
                        + "Music playlist. \(handOff(then: "make the playlist"))",
                    oldTunesOnly.joined(separator: "\n"))
        }
        let name = "“\(playlist)”"
        let message = missed == asked
            ? (asked == 1 ? "The song wasn’t added to \(name)." : "The songs weren’t added to \(name).")
            : "\(missed.formatted()) of the \(asked.formatted()) songs \(missed == 1 ? "wasn’t" : "weren’t") added to \(name)."
        var sentences: [String] = []
        if let stopReason { sentences.append(stopReason) }
        if !refused.isEmpty { sentences.append("Music didn’t accept \(which(refused.count, of: missed)).") }
        if !notSent.isEmpty, !retryWontHelp {
            // The index learns of a song Music put in late only at the next re-read, so a retry
            // before then could send that one again.
            sentences.append("To try again, add the songs to \(name) again."
                             + (unanswered == nil ? " Songs already in it aren’t added twice." : ""))
        }
        if only > 0 {
            let subject = only == asked ? (one ? "This song is" : "These songs are")
                : (one ? "One of these songs is" : "\(only.formatted()) of these songs are")
            // After a stop no retry gets past, adding them to this playlist later would stop the same way.
            sentences.append("\(subject) only in OldTunes, so \(one ? "it" : "they") can’t go in a Music playlist. "
                             + handOff(then: retryWontHelp ? nil : "add \(one ? "it" : "them") to \(name)"))
        }
        let details = detailsList([("Music didn’t accept:", refused), ("Not sent to Music:", notSent),
                                   ("Only in OldTunes:", oldTunesOnly),
                                   ("Music didn’t answer in time; it may still go in:", unanswered.map { [$0] } ?? [])])
        return (message, sentences.joined(separator: " "), details)
    }

    /// The songs among `rows` that Download asks Music for: the Music library's songs that are
    /// only in iCloud, once each. Folder songs and files on this Mac have nothing to download,
    /// and Music's download doesn't bring back a missing file (RESEARCH.md §6.9).
    static func downloadCandidates(_ rows: [Track]) -> [Track] {
        var seen = Set<Track.ID>()
        return rows.filter { $0.origin == .musicLibrary && $0.persistentID != nil && $0.isCloudOnly && seen.insert($0.id).inserted }
    }

    /// Nil unless the Download is big. `bytes`: the songs' size as the library records it;
    /// `freeBytes`: the home volume's free space, nil if unknown.
    static func downloadQuestion(count: Int, bytes: Int64, freeBytes: Int64?) -> (message: String, informative: String)? {
        guard count > bigDownloadSongs || bytes > bigDownloadBytes else { return nil }
        let one = count == 1
        let size = diskSize(bytes), free = freeBytes.map(diskSize)
        var sentences: [String] = []
        if let freeBytes, let free, bytes > freeBytes {
            sentences.append("\(one ? "This song needs" : "These songs need") about \(size), but this Mac has only \(free) free.")
        } else if bytes > 0 {
            sentences.append("\(one ? "It uses" : "They use") about \(size)" + (free.map { ", and this Mac has \($0) free." } ?? "."))
        } else if let free {
            sentences.append("This Mac has \(free) free.")
        }
        sentences.append("The Music app downloads \(one ? "it" : "them") in the background, and only the Music app can "
                         + "remove \(one ? "it" : "them") again.")
        return (one ? "Download this song to this Mac?" : "Download \(count.formatted()) songs to this Mac?",
                sentences.joined(separator: " "))
    }

    /// File ▸ Download's two titles.
    static let downloadTitle = "Download"
    static let stopDownloadingTitle = "Stop Downloading"

    /// File ▸ Download as `validateMenuItem` shows it: Stop Downloading, on, while songs are still
    /// waiting to be asked for, whatever is selected; otherwise Download, on when the selection
    /// may hold an iCloud song.
    static func downloadMenuItem(isAsking: Bool, mayHaveCloudSongs: Bool) -> (title: String, enabled: Bool) {
        isAsking ? (stopDownloadingTitle, true) : (downloadTitle, mayHaveCloudSongs)
    }

    /// Whether a click on File ▸ Download stops asking Music for songs (`downloadAction`) rather
    /// than downloads the selection: while songs are waiting to be asked for, and whenever the
    /// item clicked read Stop Downloading, even if the last of them was asked for while the menu
    /// was open.
    static func downloadClickStops(isAsking: Bool, clickedTitle: String?) -> Bool {
        isAsking || clickedTitle == stopDownloadingTitle
    }

    /// What a Download left undone, for its one alert (`downloadAlert`). Songs by title.
    struct DownloadTrouble: Sendable, Equatable {
        /// Every song the alert is about: the 12 in “3 of the 12 songs”.
        var total = 0
        /// Songs Music turned down, one line each: “Title — Music's reason”.
        var refused: [String] = []
        /// Songs never asked for: Music stopped answering, or wasn't ready.
        var notSent: [String] = []
        /// Why they weren't. User-facing.
        var stopReason: String?
        /// Songs Music didn't answer about in time. It may still download them, so they stay
        /// blue and aren't counted as not downloaded.
        var unanswered: [String] = []
        /// Songs Music took and never brought down: nothing came down for a quarter of an hour,
        /// or Music quit.
        var unfinished: [String] = []
        /// Music quitting is why `unfinished` isn't empty.
        var musicQuit = false
        /// The stop is one choosing Download again would only meet again: three refusals in a
        /// row, or a stop `MusicDownloadOutcome.stopped` marks so (the sandbox doesn't let the
        /// request through, or Music has no `download`). The alert then gives no advice to try
        /// again, unless songs Music took didn't finish: those can be tried again.
        var retryWontHelp = false

        /// `total` for a Download's own alert: the songs its requests went out for, `requested`
        /// of them taken by Music, and the ones it reports on (the song a stop came at is among
        /// `notSent`). Songs Stop Downloading took before they were asked for aren't counted,
        /// as the watch's own count leaves them out too (`DownloadWatch.end`).
        func batchTotal(requested: Int) -> Int {
            requested + refused.count + unanswered.count + notSent.count
        }
    }

    /// One Download's answers from Music, tallied for its alert (`sendDownloads`): how many songs
    /// Music took, the refusal streak, and what went wrong. Pure, so the playlists bench runs a
    /// batch's answers without Music; `sendDownloads` asks Music, keeps the watch and draws.
    struct DownloadBatch: Sendable, Equatable {
        /// The batch's songs by ID, for the alert's lines.
        let titles: [Track.ID: String]
        /// Songs Music took.
        private(set) var requested = 0
        private(set) var trouble = DownloadTrouble()
        /// Music's reason for the first refusal, for the log, which names no song.
        private(set) var firstRefusal: String?
        private var refusals = DownloadWatch.RefusalStreak()

        init(titles: [Track.ID: String]) { self.titles = titles }

        /// Whether Music's answer means it quit: the downloader found it gone, or it stopped
        /// answering and isn't running. Checked before anything else is done with the answer:
        /// every song still watched is then given up on (`musicQuit()`), its quit notification
        /// may not have come yet, and one quit ends in one alert.
        static func musicQuit(_ outcome: MusicDownloadOutcome, musicRunning: @autoclosure () -> Bool) -> Bool {
            guard case .stopped(let why, _) = outcome else { return false }
            return why == MusicSongDownloader.musicQuitReason || !musicRunning()
        }

        /// Music wasn't ready (`prepare()`): nothing was asked for. `unsent`: the songs taken off
        /// the watch.
        mutating func notReady(_ reason: String, unsent: [Track.ID]) {
            trouble.notSent = unsent.compactMap { titles[$0] }
            trouble.stopReason = reason
        }

        /// Music's answer about the song titled `title`, once the watch has taken it in: `step` is
        /// what `DownloadWatch.answer` gave back. `waiting` reads the batch's songs still waiting
        /// to be asked for; it is called only when three refusals in a row stop the batch, and
        /// the caller takes `unsent` off the watch. Returns whether to ask about the next song.
        mutating func record(_ outcome: MusicDownloadOutcome, title: String, step: (dropped: [Track.ID], goOn: Bool),
                             waiting: () -> [Track.ID]) -> (goOn: Bool, unsent: [Track.ID]) {
            switch outcome {
            case .requested:
                requested += 1
            case .refused(let why, _):
                trouble.refused.append("\(title) — \(why)")
                if firstRefusal == nil { firstRefusal = why }
            case .unanswered(let why):
                trouble.unanswered.append(title)
                trouble.stopReason = why
                trouble.notSent = step.dropped.compactMap { titles[$0] }
            case .stopped(let why, let retryWontHelp):
                trouble.stopReason = why
                trouble.notSent = step.dropped.compactMap { titles[$0] }
                trouble.retryWontHelp = retryWontHelp
            }
            guard let stop = refusals.note(outcome) else { return (step.goOn, []) }
            // Music turns these songs down one by one; the rest would only go the same way.
            let unsent = waiting()
            trouble.stopReason = stop
            trouble.notSent = unsent.compactMap { titles[$0] }
            trouble.retryWontHelp = true
            return (false, unsent)
        }

        /// What the batch left undone, for its alert, with its total (`batchTotal`).
        func finish() -> DownloadTrouble {
            var done = trouble
            done.total = trouble.batchTotal(requested: requested)
            return done
        }
    }

    /// The one alert about a Download, nil when nothing was missed, worded like Add Folder's
    /// hand-off alert. Shown when a Download's last request is answered, for what went wrong
    /// asking, and once no song is on its way any more, for the songs Music didn't finish.
    static func downloadAlert(_ trouble: DownloadTrouble) -> (message: String, informative: String, details: String)? {
        let unfinished = trouble.unfinished.count
        let missed = trouble.refused.count + trouble.notSent.count + unfinished
        guard missed > 0 else { return nil }
        let total = max(trouble.total, missed)
        let message = missed == total
            ? (total == 1 ? "The song wasn’t downloaded." : "The songs weren’t downloaded.")
            : "\(missed.formatted()) of the \(total.formatted()) songs \(missed == 1 ? "wasn’t" : "weren’t") downloaded."
        var sentences: [String] = []
        if let reason = trouble.stopReason, !trouble.notSent.isEmpty { sentences.append(reason) }
        if trouble.musicQuit, unfinished > 0 {
            sentences.append("The Music app quit before it finished.")
        } else if unfinished > 0 {
            sentences.append("The Music app didn’t finish \(which(unfinished, of: missed)).")
        }
        if !trouble.refused.isEmpty { sentences.append("Music didn’t accept \(which(trouble.refused.count, of: missed)).") }
        if unfinished > 0 { sentences.append(missed == 1 ? "It’s still in iCloud." : "They’re still in iCloud.") }
        if unfinished > 0 || (!trouble.notSent.isEmpty && !trouble.retryWontHelp) {
            sentences.append("To try again, choose Download again.")
        }
        let maybe = trouble.unanswered.count == 1 ? "it" : "them"
        let details = detailsList([("Music didn’t accept:", trouble.refused), ("Not sent to Music:", trouble.notSent),
                                   ("Music didn’t finish:", trouble.unfinished),
                                   ("Music didn’t answer in time; it may still download \(maybe):", trouble.unanswered)])
        return (message, sentences.joined(separator: " "), details)
    }

    /// The songs given up on (`ids`) that a Download's alert still names as not downloaded, by
    /// title, from their rows as read when it shows (`reportDownloads`). It can wait a long time
    /// for a name being typed, so a song done meanwhile by the watch's own rule
    /// (`DownloadWatch.settle`) is left out: one that is a file on this Mac now, and one with no
    /// row, which has left the library or came back as a new song. `rows` nil: the read failed,
    /// so nothing says any came down, and every song keeps a stand-in title.
    static func unfinishedTitles(_ ids: [Track.ID], rows: [Track]?) -> [String] {
        guard let rows else { return ids.map { "Song \($0)" } }
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { id in
            guard let row = byID[id], row.fileURL == nil else { return nil }
            return row.displayTitle
        }
    }

    /// “it” or “them” for every song an alert is about, “one song” or “2 songs” for some.
    private static func which(_ count: Int, of missed: Int) -> String {
        count == missed ? (count == 1 ? "it" : "them") : (count == 1 ? "one song" : "\(count.formatted()) songs")
    }

    /// One list, or headed lists when there are several, as the hand-off alert's details are.
    private static func detailsList(_ groups: [(heading: String, lines: [String])]) -> String {
        let shown = groups.filter { !$0.lines.isEmpty }
        if shown.count == 1 { return shown[0].lines.joined(separator: "\n") }
        return shown.map { ([$0.heading] + $0.lines).joined(separator: "\n") }.joined(separator: "\n\n")
    }

    /// “8.2 GB”, “640 MB”, “1.2 TB”: decimal units, as Finder counts free space.
    static func diskSize(_ bytes: Int64) -> String {
        if bytes >= 999_500_000_000 { return String(format: "%.1f TB", Double(bytes) / 1_000_000_000_000) }
        return bytes >= 999_500_000 ? String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
            : String(format: "%.0f MB", max(1, Double(bytes) / 1_000_000))
    }

    /// What a library change reloads (`libraryChanged`).
    enum ChangeReload: Sendable, Equatable { case everything, trackList, nothing }

    /// Songs added to one playlist (`LibraryChange.songsAddedTo`, each chunk of an add) are news
    /// only to a track list showing that playlist: no song changed, nor any other list, nor
    /// anything the source list shows. Any other change reloads everything. `scope`: what the
    /// track list shows.
    static func changeReload(songsAddedTo playlist: Int64?, showing scope: LibraryScope) -> ChangeReload {
        guard let playlist else { return .everything }
        return scope == .playlist(playlist) ? .trackList : .nothing
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

    // MARK: - Downloads

    /// Right-click ▸ Download, File ▸ Download and a playlist's Download (RESEARCH.md §6.9):
    /// asks Music to download the cloud-only songs among `ids`, and beeps when there are none. A
    /// big one asks first. The songs turn blue at once, then each one's file comes down in the
    /// background, and Music never says when: `downloads` watches the library for it.
    private func download(_ ids: [Track.ID]) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let songs: [Track]
            do {
                // A song already on its way is asked for once.
                songs = Self.downloadCandidates(try await index.tracks(ids: ids)).filter { downloads.pending[$0.id] == nil }
            } catch {
                showError("OldTunes couldn’t download songs.", error.localizedDescription)
                return
            }
            guard !songs.isEmpty else {
                NSSound.beep()
                return
            }
            let bytes = (try? await index.summary(for: songs.map(\.id)))?.totalBytes ?? 0
            if let question = Self.downloadQuestion(count: songs.count, bytes: bytes, freeBytes: Self.freeSpace()) {
                let choice = await RetroAlert.show(question.message, informative: question.informative,
                                                   buttons: ["Cancel", "Download"], cancelIndex: 0,
                                                   on: windowController.window)
                guard choice == 1 else { return }
            }
            // Another Download may have taken some of them while the question was up.
            let added = downloads.add(songs.map(\.id), now: Date())
            let batch = songs.filter { added.contains($0.id) }
            guard !batch.isEmpty else { return }
            showDownloading()
            startDownloadTicks()
            let previous = downloadWork
            downloadWork = Task { @MainActor [weak self] in
                await previous?.value
                await self?.sendDownloads(batch)
            }
        }
    }

    /// A playlist's right-click ▸ Download: its cloud-only songs, in its own order.
    private func downloadPlaylist(_ playlist: PlaylistInfo) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let query = TrackQuery(scope: .playlist(playlist.id), sort: TrackSort(field: .playlistOrder, ascending: true))
            do {
                download(try await index.ids(for: query))
            } catch {
                showError("OldTunes couldn’t download “\(playlist.name)”.", error.localizedDescription)
            }
        }
    }

    /// One Download's requests, a song at a time, each in a conversation of its own so a tag
    /// save never waits behind the batch. Music's answers decide which songs stay blue
    /// (`DownloadWatch.reduce`), and what they mean for the batch and its alert is
    /// `DownloadBatch`'s to say: three refusals in a row before Music takes any song stop it, a
    /// quit gives up on everything. One alert at the end says what didn't go through.
    private func sendDownloads(_ batch: [Track]) async {
        // Stop Downloading, or Music quitting, took every one of them while it waited its turn.
        guard batch.contains(where: { downloads.queued.contains($0.id) }) else { return }
        isSendingDownloads = true
        let started = Date()
        var tally = DownloadBatch(titles: Dictionary(batch.map { ($0.id, $0.displayTitle) },
                                                     uniquingKeysWith: { first, _ in first }))
        if let reason = await downloader.prepare() {
            let unsent = batch.map(\.id).filter(downloads.queued.contains)
            downloads.remove(unsent)
            tally.notReady(reason, unsent: unsent)
        } else {
            for (n, song) in batch.enumerated() {
                guard downloads.take(song.id), let pid = song.persistentID else { continue }
                let outcome = await downloader.download(pid)
                if DownloadBatch.musicQuit(outcome, musicRunning: MusicAutomation.isMusicRunning) {
                    // Its quit notification may not have come yet; when it does, it finds nothing
                    // left to give up on, so one quit ends in one alert.
                    musicQuit()
                    break
                }
                // Only an answer that ends the batch needs the songs after this one.
                let rest: [Track.ID]
                switch outcome {
                case .requested, .refused: rest = []
                case .unanswered, .stopped: rest = batch[(n + 1)...].map(\.id)
                }
                let step = downloads.answer(outcome, for: song.id, rest: rest, now: Date())
                let next = tally.record(outcome, title: song.displayTitle, step: step) {
                    batch[(n + 1)...].map(\.id).filter(downloads.queued.contains)
                }
                downloads.remove(next.unsent)
                if !step.dropped.isEmpty || !next.unsent.isEmpty { showDownloading() }
                guard next.goOn else { break }
            }
        }
        isSendingDownloads = false
        let trouble = tally.finish()
        Log.info("downloads: Music took \(tally.requested) of \(batch.count) requests in " +
                 "\(String(format: "%.1f", Date().timeIntervalSince(started))) s, \(trouble.refused.count) refused, " +
                 "\(trouble.unanswered.count) unanswered, \(trouble.notSent.count) not sent" +
                 (trouble.stopReason.map { "; stopped: \($0)" } ?? "") +
                 (tally.firstRefusal.map { "; first refusal: \($0)" } ?? ""))
        showDownloading()
        reportDownloads(trouble)
    }

    /// File ▸ Stop Downloading: OldTunes asks Music for no more songs. Those Music was already
    /// asked for keep coming, and stay blue until they arrive.
    private func stopDownloading() {
        let dropped = downloads.stopAsking()
        guard !dropped.isEmpty else { return }
        Log.info("downloads: stopped; \(dropped.count) songs not asked for")
        showDownloading()
        reportDownloads()
    }

    /// Music quit (its quit notification, or a request that found it gone). Asking it for the
    /// next song would start it again, and nothing it was fetching comes down now, so every song
    /// still watched is given up on, and the alert says Music quit.
    private func musicQuit() {
        let expired = downloads.expireAll(musicQuit: true)
        guard !expired.isEmpty else { return }
        Log.info("downloads: Music quit; \(expired.count) songs it hadn’t brought down no longer show as downloading")
        showDownloading()
        reportDownloads()
    }

    /// The one alert about downloads, when something went wrong: what a Download's requests left
    /// undone (`batch`, once its last request is answered), and, once no song is on its way any
    /// more, the ones Music didn't finish. While a Download is still asking, the second waits for
    /// it, so a Music quit halfway through ends in one alert, not two. It can come at any time, so
    /// while a playlist's name is open for typing it waits too, as an add's alert does, and only
    /// then reads the songs it names: a name stays open for as long as OldTunes is hidden, and a
    /// song that came down or left the library meanwhile isn't named (`unfinishedTitles`). It
    /// looks again after that read, and waits again if a box opened while it read (a queued ⌘N
    /// that was waiting for the same name), so it shows only while no name is open. With nothing
    /// left to say, nothing shows.
    private func reportDownloads(_ batch: DownloadTrouble = DownloadTrouble()) {
        var trouble = batch
        var unfinished: [Track.ID] = []
        if !isSendingDownloads, let ending = downloads.end() {
            unfinished = ending.unfinished
            // Each of the batch's songs was dropped (refused, not sent) or watched to the end.
            trouble.total = ending.watched + batch.refused.count + batch.notSent.count
            trouble.musicQuit = ending.musicQuit
            // Those are among the unfinished now, or came down.
            trouble.unanswered = []
        }
        guard !trouble.refused.isEmpty || !trouble.notSent.isEmpty || !unfinished.isEmpty else { return }
        let known = trouble, unfinishedIDs = unfinished
        Task { @MainActor [weak self] in
            guard let self else { return }
            // First, so the alert says only what is still true when it shows; then looked at
            // again after each read, so nothing that waits comes between the last look and the
            // alert. Nil rows: the read failed.
            var rows: [Track]? = []
            repeat {
                await sources.renamesEnded()
                if !unfinishedIDs.isEmpty { rows = try? await index.tracks(ids: unfinishedIDs) }
            } while sources.renamingID != nil
            var trouble = known
            trouble.unfinished = Self.unfinishedTitles(unfinishedIDs, rows: rows)
            guard let alert = Self.downloadAlert(trouble) else { return }
            Log.info("downloads: \(alert.message) \(alert.informative)")
            await RetroAlert.show(alert.message, informative: alert.informative, details: alert.details,
                                  on: windowController.window)
        }
    }

    /// Takes the songs whose file has come down, or that left the library, off the watch. After
    /// every library change, and every 30 s while anything is watched.
    private func settleDownloads() async {
        guard !downloads.isEmpty else { return }
        let ids = downloads.ids
        // A failed read says nothing about the songs; the next one will.
        guard let rows = try? await index.tracks(ids: Array(ids)) else { return }
        let asked = downloads.pending
        let done = downloads.settle(rows: rows, requested: ids, now: Date())
        guard !done.isEmpty else { return }
        let slowest = done.compactMap { asked[$0] }.map { Date().timeIntervalSince($0) }.max() ?? 0
        Log.info("downloads: \(done.count) came down or left the library, the slowest after \(Int(slowest)) s; " +
                 "\(downloads.pending.count) still coming")
        showDownloading()
        reportDownloads()
    }

    /// The 30 s check (`DownloadWatch.tick`): settles, gives up on what Music has stopped
    /// fetching, and re-reads the library when the watch asks, unless a re-read is already
    /// running or coming. Only a re-read that worked counts as the library read
    /// (`LibraryIngest.lastWrittenRefreshStarted`): one that failed read nothing in, so the watch
    /// asks again, and gives up on no song before the library has been read. The log says what
    /// happened: a re-read that worked; or, once for a run of ticks that asked, one that failed
    /// and why, or that one was running or waiting already. While Music keeps posting, the
    /// re-read asked for gives way to the one waiting for Music to go quiet, up to 5 minutes
    /// (`LibraryIngest.refreshIfIdle`, `changeWait`).
    private func tickDownloads() async {
        guard !downloads.isEmpty else { return }
        // Read before the rows, so a re-ingest the watch takes as finished is in them.
        let lastRefresh = await ingest.lastWrittenRefreshStarted
        await settleDownloads()
        let tick = downloads.tick(now: Date(), lastRefresh: lastRefresh)
        if !tick.expired.isEmpty {
            Log.info("downloads: nothing came down for \(Int(DownloadWatch.quietLimit / 60)) minutes; " +
                     "\(tick.expired.count) songs no longer show as downloading")
            showDownloading()
            reportDownloads()
        }
        guard tick.refreshDue else {
            (skippedReReadLogged, failedReReadLogged) = (false, false)
            return
        }
        // One that failed is tried again at the watch's own pace, not every tick: each try reads
        // the whole library, and the reason may last (a disk the Download itself filled).
        if let tried = await ingest.lastRefreshStarted, tried > lastRefresh ?? .distantPast,
           Date().timeIntervalSince(tried) < DownloadWatch.refreshInterval { return }
        switch await ingest.refreshIfIdle()?.status {
        case .ok?:
            (skippedReReadLogged, failedReReadLogged) = (false, false)
            Log.info("downloads: re-read the library, in case Music didn’t say a song came down")
        case let failed?:
            if !failedReReadLogged {
                failedReReadLogged = true
                Log.info("downloads: a re-read failed: \(failed)")
            }
        case nil:
            if !skippedReReadLogged {
                skippedReReadLogged = true
                Log.info("downloads: a re-read is already running or waiting for Music to go quiet")
            }
        }
    }

    /// Runs `tickDownloads` every 30 s until nothing is watched. A Task loop rather than a Timer,
    /// whose block would need `MainActor.assumeIsolated` and the common run-loop mode to keep
    /// going while a menu is open (PlaybackClock does that, for a clock that must tick smoothly).
    /// The log says when a loop starts and when it ends, in counts only.
    private func startDownloadTicks() {
        guard downloadTicks == nil else { return }
        (skippedReReadLogged, failedReReadLogged) = (false, false)
        let every = DownloadWatch.tickInterval.components.seconds
        Log.info("downloads: \(downloads.pending.count) songs watched, so the \(every) s checks start")
        downloadTicks = Task { @MainActor [weak self] in
            var ticks = 0
            while true {
                do {
                    try await Task.sleep(for: DownloadWatch.tickInterval)
                } catch {
                    self?.downloadTicks = nil
                    return
                }
                guard let self else { return }
                await self.tickDownloads()
                ticks += 1
                // With nothing in between that waits, so a Download that comes along now either
                // finds this loop still going or starts the next one.
                if self.downloads.isEmpty {
                    self.downloadTicks = nil
                    Log.info("downloads: nothing left to watch, so the \(every) s checks stop (\(ticks) ran)")
                    return
                }
            }
        }
    }

    private func showDownloading() { tracks.setDownloading(downloads.ids) }

    /// Free space on the home volume, where Music keeps its files unless they were moved: what
    /// Finder shows as available. Nil if unknown.
    private static func freeSpace() -> Int64? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    // MARK: - Library

    /// After `.libraryDidChange`. Each chunk of an add posts one (`songsAddedTo`, its playlist):
    /// that reloads the track list only while it shows the playlist (`changeReload`). Otherwise a
    /// ⌘A add from the 15,900-song Library would reload it, its summary and every watched
    /// download's row, and rebuild the source list, 25 songs at a time.
    private func libraryChanged(songsAddedTo playlist: Int64?) {
        switch Self.changeReload(songsAddedTo: playlist, showing: tracks.query.scope) {
        case .everything: Task { await reloadLists() }
        case .trackList: Task { await tracks.reload() }   // its order changing updates the summary
        case .nothing: break
        }
    }

    private func reloadLists() async {
        await sources.reload()
        await tracks.reload()
        // A song Music was downloading may be a file now.
        await settleDownloads()
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
        // iTunes 4.9's keys. Uppercase N is ⇧⌘N, as for the visualizer's ⇧⌘F below.
        file.addItem(item("New Playlist", #selector(newPlaylistAction(_:)), "n"))
        file.addItem(item("New Playlist from Selection", #selector(newPlaylistFromSelectionAction(_:)), "N"))
        file.addItem(.separator())
        file.addItem(item("Add Folder to Library…", #selector(addFolder(_:)), "o"))
        file.addItem(.separator())
        file.addItem(item("Get Info", #selector(getInfo(_:)), "i"))
        file.addItem(item(Self.downloadTitle, #selector(downloadAction(_:)), ""))
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
        controls.addItem(item("Mute", #selector(toggleMute(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!),
                              [.command, .option]))
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

    /// iTunes's arrow keys (ArrowCommand), for the arrows the focused view passes on: the lists
    /// keep ↑ and ↓, a source-list folder keeps ← and →, and a text field keeps them all.
    private func installArrowKeys() {
        windowController.metalWindow?.onUnusedKey = { [weak self] in self?.arrowKey($0, inVisualizer: false) ?? false }
        visualizer?.onUnusedKey = { [weak self] in self?.arrowKey($0, inVisualizer: true) ?? false }
    }

    /// False lets the window beep, as it did before: no song on, or a volume OldTunes can't set.
    private func arrowKey(_ event: NSEvent, inVisualizer: Bool) -> Bool {
        guard let command = ArrowCommand(event: event, inVisualizer: inVisualizer) else { return false }
        let songOn = player.state.nowPlaying != nil
        switch command {
        case .previousSong where songOn: player.previous()
        case .nextSong where songOn: player.next()
        case .previousAlbum where songOn: player.previousAlbum()
        case .nextAlbum where songOn: player.nextAlbum()
        case .scan(let seconds) where songOn: player.seek(to: player.state.position + seconds)
        case .volumeUp where player.state.isVolumeEnabled: volumeUp(nil)
        case .volumeDown where player.state.isVolumeEnabled: volumeDown(nil)
        default: return false
        }
        return true
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
        case #selector(newPlaylistFromSelectionAction(_:)):
            // Off when every song it can see is only in OldTunes: nothing could go in it.
            return tracks.selectionMayHaveMusicSongs
        case #selector(downloadAction(_:)):
            let item = Self.downloadMenuItem(isAsking: downloads.isAsking, mayHaveCloudSongs: tracks.selectionMayHaveCloudSongs)
            menuItem.title = item.title
            return item.enabled
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
        case #selector(toggleMute(_:)):
            menuItem.state = volumeBeforeMute != nil ? .on : .off
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
