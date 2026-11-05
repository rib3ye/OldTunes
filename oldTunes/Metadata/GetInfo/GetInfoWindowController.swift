import AppKit

/// iTunes 4.9's Get Info window, hand-drawn in 10.4 Aqua. One song gets the Summary / Info /
/// Artwork tabs with Previous and Next walking the track list's visible order; several songs
/// get "Multiple Song Information", where only the fields the user touched are saved.
///
/// Saving goes through `TagEditing` (Music-library songs through Music, added-folder songs into
/// their files; see `TagEditor.route(for:)`), then `LibraryWriting.update` for the songs that
/// succeeded, which posts `.libraryDidChange` so the list redraws without a re-ingest. Songs
/// that fail are listed by name with the reason.
@MainActor
final class GetInfoWindowController: NSWindowController, NSWindowDelegate {
    /// Open windows keep their controllers alive, so callers can show one and forget it.
    private static var open: [ObjectIdentifier: GetInfoWindowController] = [:]
    /// iTunes reopened Get Info on the tab last used.
    private static var lastTab = 0

    private let editor: any TagEditing
    private let library: any LibraryReading & LibraryWriting
    private let artworkProvider: @Sendable (Track) async -> Data?
    private let visibleOrder: [Track.ID]

    /// Checked before the first cloud save, so the Automation prompt can be explained first.
    var permissionChecker: any MusicPermissionChecking = MusicAppTagWriter()

    let isMultiple: Bool
    private(set) var tracks: [Track]
    private(set) var current: Track

    // Single-song edit state.
    private var original = TagFields()
    private var pendingArtwork: Data?
    private var artworkRemoved = false
    private var loadGeneration = 0
    private(set) var isBusy = false
    /// True from the moment OK, Return, Previous or Next starts a save until it finishes —
    /// including the sheets and the Automation check before the write, where `isBusy` is not yet
    /// set — so a second press cannot start a second save of the same patch.
    private(set) var isSaving = false

    private let aquaWindow: AquaWindow
    private let box = AquaBoxView()
    private let tabStrip = AquaTabStrip(titles: ["Summary", "Info", "Artwork"])
    private(set) var summaryPane: GetInfoSummaryPane?
    private(set) var infoPane: GetInfoInfoPane?
    private(set) var artworkPane: GetInfoArtworkPane?
    private(set) var multiplePane: GetInfoMultiplePane?
    private let previousButton = AquaButton(title: "Previous")
    private let nextButton = AquaButton(title: "Next")
    private let cancelButton = AquaButton(title: "Cancel")
    private let okButton = AquaButton(title: "OK", isDefault: true)
    private let statusLabel = FormKit.label("", font: AquaStyle.tinyFont, color: AquaStyle.noteText, alignment: .center)

    /// tracks: the selection (1 = single-song Get Info, >1 = "Multiple Song Information").
    /// visibleOrder: the track list's current order, so Previous/Next can walk it for a single song.
    init(tracks: [Track], visibleOrder: [Track.ID],
         editor: any TagEditing, library: any LibraryReading & LibraryWriting,
         artwork: @escaping @Sendable (Track) async -> Data?) {
        self.tracks = tracks
        self.current = tracks.first ?? .blank()
        self.isMultiple = tracks.count > 1
        self.visibleOrder = visibleOrder
        self.editor = editor
        self.library = library
        self.artworkProvider = artwork

        let L = GetInfoLayout.self
        let boxTop: CGFloat
        let boxBottom: CGFloat
        if tracks.count > 1 {
            let pane = GetInfoMultiplePane(frame: .zero)
            multiplePane = pane
            boxTop = 34
            boxBottom = pane.contentBottom + 8
        } else {
            let pane = GetInfoInfoPane(frame: .zero)
            infoPane = pane
            boxTop = L.boxTop
            boxBottom = pane.contentBottom + 8
        }
        let buttonsY = boxBottom + 14
        let size = NSSize(width: L.windowWidth, height: buttonsY + AquaButton.height + L.bottomMargin + 2)
        let title = tracks.count > 1 ? "Multiple Song Information" : (tracks.first?.displayTitle ?? "Get Info")
        aquaWindow = AquaWindow(contentSize: size, title: title)

        super.init(window: aquaWindow)
        aquaWindow.delegate = self
        buildViews(size: size, boxTop: boxTop, boxBottom: boxBottom, buttonsY: buttonsY)
        aquaWindow.onReturn = { [weak self] in self?.okPressed() }
        aquaWindow.onEscape = { [weak self] in self?.cancelPressed() }
        aquaWindow.autorecalculatesKeyViewLoop = true

        if isMultiple { loadMultiple() } else { load(current) }
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Views

    private func buildViews(size: NSSize, boxTop: CGFloat, boxBottom: CGFloat, buttonsY: CGFloat) {
        guard let face = aquaWindow.contentView else { return }
        let L = GetInfoLayout.self
        let full = NSRect(origin: .zero, size: size)

        box.frame = NSRect(x: L.boxInsetX, y: boxTop, width: size.width - 2 * L.boxInsetX, height: boxBottom - boxTop)
        face.addSubview(box)

        if let multiplePane {
            multiplePane.frame = full
            face.addSubview(multiplePane)
            multiplePane.showMusicNote(Self.musicNote(for: tracks))
        } else if let infoPane {
            let summary = GetInfoSummaryPane(frame: full)
            let artwork = GetInfoArtworkPane(frame: full, boxBottom: boxBottom)
            infoPane.frame = full
            for pane in [summary, infoPane, artwork] as [NSView] { face.addSubview(pane) }
            summaryPane = summary
            artworkPane = artwork
            artwork.onAdd = { [weak self] data in self?.artworkChosen(data) }
            artwork.onDelete = { [weak self] in self?.artworkDeleted() }

            tabStrip.setFrameOrigin(NSPoint(x: ((size.width - tabStrip.frame.width) / 2).rounded(), y: L.tabStripTop))
            tabStrip.onSelect = { [weak self] index in self?.selectTab(index) }
            face.addSubview(tabStrip)
        }

        let prevW = AquaButton.width(for: previousButton.title)
        let nextW = AquaButton.width(for: nextButton.title)
        previousButton.frame = NSRect(x: L.boxInsetX, y: buttonsY, width: prevW, height: AquaButton.height)
        nextButton.frame = NSRect(x: L.boxInsetX + prevW + L.buttonGap, y: buttonsY, width: nextW, height: AquaButton.height)
        let okW = max(80, AquaButton.width(for: okButton.title))
        let cancelW = max(80, AquaButton.width(for: cancelButton.title))
        okButton.frame = NSRect(x: size.width - L.boxInsetX - okW, y: buttonsY, width: okW, height: AquaButton.height)
        cancelButton.frame = NSRect(x: okButton.frame.minX - L.buttonGap - cancelW, y: buttonsY, width: cancelW, height: AquaButton.height)
        previousButton.onPress = { [weak self] in self?.stepPressed(-1) }
        nextButton.onPress = { [weak self] in self?.stepPressed(1) }
        cancelButton.onPress = { [weak self] in self?.cancelPressed() }
        okButton.onPress = { [weak self] in self?.okPressed() }
        for b in [previousButton, nextButton] { b.isHidden = isMultiple }
        for b in [previousButton, nextButton, cancelButton, okButton] { face.addSubview(b) }

        let statusX = nextButton.frame.maxX + 8
        statusLabel.frame = NSRect(x: statusX, y: buttonsY + 4, width: cancelButton.frame.minX - 8 - statusX, height: 13)
        face.addSubview(statusLabel)

        if !isMultiple { selectTab(Self.lastTab) }
    }

    /// 0 Summary, 1 Info, 2 Artwork.
    func selectTab(_ index: Int) {
        guard !isMultiple else { return }
        let i = min(max(index, 0), 2)
        Self.lastTab = i
        tabStrip.selectedIndex = i
        summaryPane?.isHidden = i != 0
        infoPane?.isHidden = i != 1
        artworkPane?.isHidden = i != 2
        if i == 1, let name = infoPane?.name.field {
            aquaWindow.makeFirstResponder(name)
        } else {
            aquaWindow.makeFirstResponder(nil)
        }
    }

    var selectedTab: Int { tabStrip.selectedIndex }
    var canGoPrevious: Bool { previousButton.isEnabled }
    var canGoNext: Bool { nextButton.isEnabled }

    override func showWindow(_ sender: Any?) {
        Self.open[ObjectIdentifier(self)] = self
        if !aquaWindow.isVisible {
            if let main = NSApp.mainWindow, main !== aquaWindow {
                let f = main.frame
                aquaWindow.setFrameOrigin(NSPoint(x: f.midX - aquaWindow.frame.width / 2,
                                                  y: f.maxY - 60 - aquaWindow.frame.height))
            } else {
                aquaWindow.center()
            }
        }
        super.showWindow(sender)
        aquaWindow.makeKeyAndOrderFront(sender)
        if !isMultiple, selectedTab == 1, let name = infoPane?.name.field { aquaWindow.makeFirstResponder(name) }
    }

    /// The close orb and ⌘W wait for a save in progress, so its failure sheet has a window.
    func windowShouldClose(_ sender: NSWindow) -> Bool { !isSaving }

    func windowWillClose(_ notification: Notification) {
        Self.open[ObjectIdentifier(self)] = nil
    }

    // MARK: - Loading

    private func load(_ track: Track) {
        current = track
        aquaWindow.title = track.displayTitle
        original = TagFields(track: track)
        pendingArtwork = nil
        artworkRemoved = false
        infoPane?.load(original)
        infoPane?.showMusicNote(Self.musicNote(for: [track]))
        summaryPane?.show(track, fields: original)
        summaryPane?.showReadProblem(nil)
        summaryPane?.showArtwork(nil)
        artworkPane?.show(nil)
        updateStepButtons()

        loadGeneration += 1
        let generation = loadGeneration
        let editor = self.editor
        let provider = self.artworkProvider
        let placeholder = original
        Task { [weak self] in
            do {
                let fields = try await editor.readFields(of: track)
                guard let self, self.loadGeneration == generation else { return }
                self.original = fields
                if let infoPane = self.infoPane {
                    // Anything typed while the file was being read wins over the file's value,
                    // and stays a change against it, so OK still saves it.
                    let shown = infoPane.currentFields()
                    let merged = fields.applying(TagPatch(from: placeholder, to: shown))
                    if merged != shown { infoPane.load(merged) }
                }
                self.summaryPane?.show(track, fields: fields)
            } catch {
                guard let self, self.loadGeneration == generation else { return }
                self.summaryPane?.showReadProblem(error.localizedDescription)
                Log.error("metadata: Get Info read failed id=\(track.id): \(error.localizedDescription)")
            }
            let data = await provider(track)
            guard let self, self.loadGeneration == generation else { return }
            self.summaryPane?.showArtwork(data)
            self.artworkPane?.show(data)
        }
    }

    private func loadMultiple() {
        multiplePane?.load(tracks.map(TagFields.init(track:)))
        let editor = self.editor
        let tracks = self.tracks
        Task { [weak self] in
            var all: [TagFields] = []
            for track in tracks {
                all.append((try? await editor.readFields(of: track)) ?? TagFields(track: track))
            }
            // Keep whatever the user ticked or typed while the files were being read.
            self?.multiplePane?.load(all, keepingEdits: true)
        }
    }

    private func updateStepButtons() {
        let index = visibleOrder.firstIndex(of: current.id)
        previousButton.isEnabled = !isBusy && (index.map { $0 > 0 } ?? false)
        nextButton.isEnabled = !isBusy && (index.map { $0 < visibleOrder.count - 1 } ?? false)
    }

    // MARK: - Editing

    private func artworkChosen(_ data: Data) {
        pendingArtwork = data
        artworkRemoved = false
        artworkPane?.show(data)
        summaryPane?.showArtwork(data)
    }

    private func artworkDeleted() {
        pendingArtwork = nil
        artworkRemoved = true
        artworkPane?.show(nil)
        summaryPane?.showArtwork(nil)
    }

    /// Exactly what Save would write right now.
    func currentPatch() -> TagPatch {
        if let multiplePane { return multiplePane.patch() }
        guard let infoPane else { return TagPatch() }
        var patch = TagPatch(from: original, to: infoPane.currentFields())
        if let pendingArtwork {
            patch.artwork = pendingArtwork
        } else if artworkRemoved {
            patch.removeArtwork = true
        }
        return patch
    }

    // MARK: - Buttons

    private func okPressed() {
        guard !isBusy, !isSaving else { return }
        Task { await performOK() }
    }

    private func cancelPressed() {
        guard !isBusy, !isSaving else { return }
        close()
    }

    private func stepPressed(_ delta: Int) {
        guard !isBusy, !isSaving else { return }
        Task { await performStep(delta) }
    }

    /// Saves, then closes if everything saved. Returns whether the window closed.
    @discardableResult
    func performOK() async -> Bool {
        guard await save() else { return false }
        close()
        return true
    }

    /// iTunes saved the current song before moving to the next one.
    @discardableResult
    func performStep(_ delta: Int) async -> Bool {
        guard !isMultiple, await save(),
              let index = visibleOrder.firstIndex(of: current.id),
              visibleOrder.indices.contains(index + delta) else { return false }
        let id = visibleOrder[index + delta]
        do {
            guard let next = try await library.tracks(ids: [id]).first else { return false }
            let tab = selectedTab
            load(next)
            selectTab(tab)
            return true
        } catch {
            Log.error("metadata: Get Info could not load id=\(id): \(error.localizedDescription)")
            return false
        }
    }

    /// Applies the current patch. True when there was nothing to save or everything saved;
    /// false if another save is still running.
    func save() async -> Bool {
        guard !isSaving else { return false }
        let patch = currentPatch()
        if patch.isEmpty { return true }
        isSaving = true
        defer { isSaving = false }
        let targets = isMultiple ? tracks : [current]
        let routes = targets.map(TagEditor.route(for:))

        // §6.6's warning is about oldTunes writing a file directly, which only an added-folder
        // song gets; a Music-library song's file is written by Music itself.
        if routes.contains(where: { if case .file = $0 { true } else { false } }), GetInfoPrompts.shouldShowFileWarning {
            guard await GetInfoPrompts.confirmFileEdit(on: aquaWindow) else { return false }
        }
        if routes.contains(where: { if case .music = $0 { true } else { false } }) {
            let status = await permissionChecker.permission(askIfNeeded: false)
            Log.info("metadata: Music automation status before save: \(status)")
            if status == .undetermined {
                guard await GetInfoPrompts.explainAutomation(on: aquaWindow) else { return false }
                let answered = await permissionChecker.permission(askIfNeeded: true)
                Log.info("metadata: Music automation status after asking: \(answered)")
            }
        }

        setBusy(true)
        Log.info("metadata: saving \(patch.changedFieldNames.joined(separator: ",")) for \(targets.count) song(s)")
        let result = await editor.apply(patch, to: targets)
        if !result.succeeded.isEmpty {
            // `update` posts `.libraryDidChange` itself once the row is written (Contracts.swift);
            // a second post here would start a second full reload of every list.
            do {
                try await library.update(ids: result.succeeded, applying: patch)
            } catch {
                Log.error("metadata: library update failed: \(error.localizedDescription)")
            }
            await refreshAfterSave(patch, succeeded: Set(result.succeeded))
        }
        setBusy(false)

        guard result.failed.isEmpty else {
            let names = Dictionary(targets.map { ($0.id, $0.displayTitle) }, uniquingKeysWith: { a, _ in a })
            let lines = result.failed.map { "\(names[$0.id] ?? "Song \($0.id)") — \($0.reason)" }
            await GetInfoPrompts.showFailures(lines, savedCount: result.succeeded.count, on: aquaWindow)
            return false
        }
        return true
    }

    private func refreshAfterSave(_ patch: TagPatch, succeeded: Set<Track.ID>) async {
        if let refreshed = try? await library.tracks(ids: tracks.map(\.id)), refreshed.count == tracks.count {
            tracks = refreshed
        }
        guard !isMultiple, succeeded.contains(current.id) else { return }
        if let updated = try? await library.tracks(ids: [current.id]).first { current = updated }
        original = original.applying(patch)
        if let art = patch.artwork { artworkPane?.show(art) }
        pendingArtwork = nil
        artworkRemoved = false
        summaryPane?.show(current, fields: original)
        aquaWindow.title = current.displayTitle
    }

    /// The small note under the fields saying a save goes through Music.
    struct MusicNote: Equatable {
        var text: String
        /// The cloud glyph, for songs stored in iCloud.
        var showsCloud: Bool
    }

    /// Nil when no song in `tracks` is saved through Music (folder files only).
    static func musicNote(for tracks: [Track]) -> MusicNote? {
        let throughMusic = tracks.filter { if case .music = TagEditor.route(for: $0) { true } else { false } }
        guard !throughMusic.isEmpty else { return nil }
        let allInCloud = throughMusic.allSatisfy(\.isCloudOnly)
        if tracks.count == 1 {
            return allInCloud ? MusicNote(text: "Stored in iCloud — changes are saved through Music", showsCloud: true)
                              : MusicNote(text: "In your Music library — changes are saved through Music", showsCloud: false)
        }
        return allInCloud ? MusicNote(text: "Changes to songs stored in iCloud are saved through Music.", showsCloud: true)
                          : MusicNote(text: "Changes to songs in your Music library are saved through Music.", showsCloud: false)
    }

    private func setBusy(_ busy: Bool) {
        isBusy = busy
        statusLabel.stringValue = busy ? "Saving…" : ""
        okButton.isEnabled = !busy
        cancelButton.isEnabled = !busy
        infoPane?.setEditable(!busy)
        artworkPane?.setEditable(!busy)
        updateStepButtons()
    }
}
