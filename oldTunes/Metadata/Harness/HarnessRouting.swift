import AppKit

/// Regression checks for review findings 1, 2 and 8 (metadata half).
///
/// 1. A song in Music's library is saved through Music even when it has a file on this Mac, so
///    Music's database and the file change together and the next ingest agrees with the edit.
///    Only songs added from a folder have their file written directly. Get Info reads a
///    Music-library song from the library row, the same values the list shows.
/// 2. "Part of a compilation" starts from `Track.isCompilation`, so a compilation shows checked
///    and can be cleared.
/// 8. One Get Info save posts `.libraryDidChange` once (`LibraryWriting.update` posts it).
///
/// Every Music write goes to `RecordingCloudWriter`; no Apple Event is sent. The real files are
/// only copied — every edit lands on a copy in the evidence directory.
@MainActor
enum HarnessRouting {
    static func run(sample: HarnessLibrarySample, fixturesDir: URL, evidence: URL, tally: HarnessTally) async {
        NSApp.activate()
        let anchor = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: .borderless,
                              backing: .buffered, defer: false)
        anchor.alphaValue = 0
        anchor.ignoresMouseEvents = true
        anchor.isReleasedWhenClosed = false
        anchor.orderBack(nil)
        defer { anchor.orderOut(nil) }
        let savedSuppress = UserDefaults.standard.object(forKey: GetInfoPrompts.suppressFileWarningKey)
        defer {
            if let savedSuppress { UserDefaults.standard.set(savedSuppress, forKey: GetInfoPrompts.suppressFileWarningKey) }
            else { UserDefaults.standard.removeObject(forKey: GetInfoPrompts.suppressFileWarningKey) }
        }

        await routing(sample: sample, fixturesDir: fixturesDir, evidence: evidence, tally: tally)
        await compilation(sample: sample, evidence: evidence, tally: tally)
    }

    // MARK: - Finding 1: route by origin

    private static func routing(sample: HarnessLibrarySample, fixturesDir: URL, evidence: URL, tally: HarnessTally) async {
        let fm = FileManager.default
        guard let item = sample.localFiles.first(where: { $0.location.map { FileTagIO.problem(with: $0) == nil } ?? false }),
              let original = item.location else {
            tally.check(false, "routing: the library has a Music-library song with an editable local file")
            return
        }
        let folderSource = fixturesDir.appendingPathComponent("gen-aac.m4a")
        guard fm.fileExists(atPath: folderSource.path) else {
            tally.check(false, "routing: fixture gen-aac.m4a exists (run the full harness once first)")
            return
        }
        func copy(_ source: URL, as name: String) -> URL? {
            let url = fixturesDir.appendingPathComponent(name)
            try? fm.removeItem(at: url)
            guard (try? fm.copyItem(at: source, to: url)) != nil else { return nil }
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            return url
        }
        let ext = original.pathExtension
        guard let musicCopy = copy(original, as: "routing-music-local.\(ext)"),
              let orphanCopy = copy(original, as: "routing-no-pid.\(ext)"),
              let folderCopy = copy(folderSource, as: "routing-folder.m4a") else {
            tally.check(false, "routing: scratch copies made")
            return
        }
        Log.info("routing: Music-library song “\(item.title)” (\(original.lastPathComponent)); editing scratch copy \(musicCopy.path)")

        // The index row for a Music-library song with a file, pointed at the scratch copy. Its
        // title differs from the file's, so a read can tell which one it came from.
        var musicLocal = HarnessLibrarySample.track(from: item, id: 801, fileURL: musicCopy)
        musicLocal.title = "Library Title (not the file's)"
        let musicHex = MusicPersistentID.hex(musicLocal.persistentID ?? 0)
        var folder = HarnessFixtures.folderTrack(id: 802, url: folderCopy)
        folder.title = "Routing Folder"
        var orphan = Track.blank(id: 803)               // Music-library origin, a file, no persistent ID
        orphan.fileURL = orphanCopy
        orphan.bucket = .local
        orphan.title = "No persistent ID"
        let cloud = sample.cloudSamples.first.map { HarnessLibrarySample.track(from: $0, id: 804) }

        var patch = TagPatch()
        patch.title = "Routed Title"
        patch.genre = "Routed Genre"

        // Reads.
        do {
            let writer = RecordingCloudWriter(answers: [.granted])
            let editor = TagEditor(cloud: writer)
            let fields = try? await editor.readFields(of: musicLocal)
            let asks = await writer.asks()
            tally.check(fields == TagFields(track: musicLocal) && asks.isEmpty,
                        "routing: Get Info reads a Music-library song from the library row, not its file (no Music call)",
                        detail: "read title “\(fields?.title ?? "nil")”, row title “\(musicLocal.title)”")
            let folderFields = try? await editor.readFields(of: folder)
            let fromFile = try? FileTagIO.readFields(at: folderCopy)
            tally.check(folderFields != nil && folderFields == fromFile,
                        "routing: Get Info reads a folder song from its file")
        }

        // Writes, one song at a time.
        do {
            let before = fm.contents(atPath: musicCopy.path)
            let writer = RecordingCloudWriter(answers: [.granted])
            let r = await TagEditor(cloud: writer).apply(patch, to: [musicLocal])
            let writes = await writer.recordedWrites()
            let unchanged = fm.contents(atPath: musicCopy.path) == before
            tally.check(r.succeeded == [musicLocal.id] && writes.count == 1 && writes.first?.hex == musicHex
                        && writes.first?.patch == patch,
                        "routing: a Music-library song with a file is saved through Music by persistent ID \(musicHex)",
                        detail: "succeeded=\(r.succeeded) Music writes=\(writes.count) failed=\(r.failed.map(\.reason))")
            tally.check(unchanged, "routing: oldTunes leaves that song's file to Music (file bytes unchanged)")
        }
        do {
            let writer = RecordingCloudWriter(answers: [.granted])
            let r = await TagEditor(cloud: writer).apply(patch, to: [folder])
            let writes = await writer.recordedWrites()
            let asks = await writer.asks()
            let back = try? FileTagIO.readFields(at: folderCopy)
            tally.check(r.succeeded == [folder.id] && back?.title == "Routed Title" && back?.genre == "Routed Genre"
                        && writes.isEmpty && asks.isEmpty,
                        "routing: a folder song is written to its file and Music is never asked",
                        detail: "file title “\(back?.title ?? "nil")” writes=\(writes.count) asks=\(asks)")
        }
        do {
            let before = fm.contents(atPath: orphanCopy.path)
            let writer = RecordingCloudWriter(answers: [.granted])
            let r = await TagEditor(cloud: writer).apply(patch, to: [orphan])
            let writes = await writer.recordedWrites()
            let reason = r.failed.first?.reason ?? ""
            Log.info("routing: Music-library row without a persistent ID → “\(reason)”")
            tally.check(r.succeeded.isEmpty && r.failed.map(\.id) == [orphan.id] && writes.isEmpty
                        && fm.contents(atPath: orphanCopy.path) == before && !reason.isEmpty,
                        "routing: a Music-library row with no persistent ID is refused and its file left alone",
                        detail: "succeeded=\(r.succeeded) reason=\(reason)")
        }

        // A mixed batch: one permission check, each song to its own home.
        if let cloud {
            let musicBefore = fm.contents(atPath: musicCopy.path)
            var genreOnly = TagPatch()
            genreOnly.genre = "Batch Genre"
            let writer = RecordingCloudWriter(answers: [.granted])
            let r = await TagEditor(cloud: writer).apply(genreOnly, to: [folder, musicLocal, cloud])
            let writes = await writer.recordedWrites()
            let asks = await writer.asks()
            let back = try? FileTagIO.readFields(at: folderCopy)
            let cloudHex = MusicPersistentID.hex(cloud.persistentID ?? 0)
            tally.check(Set(r.succeeded) == [folder.id, musicLocal.id, cloud.id] && asks == [false]
                        && writes.map(\.hex) == [musicHex, cloudHex] && back?.genre == "Batch Genre"
                        && fm.contents(atPath: musicCopy.path) == musicBefore,
                        "routing: a mixed selection checks permission once; folder file written, both library songs sent to Music",
                        detail: "asks=\(asks) writes=\(writes.map(\.hex)) folder genre=\(back?.genre ?? "nil")")
        }

        // Get Info, one Music-library song with a file: no file-warning sheet; the Automation
        // explanation comes first instead, and its words fit a song that has a file.
        do {
            UserDefaults.standard.removeObject(forKey: GetInfoPrompts.suppressFileWarningKey)
            GetInfoPrompts.resetFileWarningForThisLaunch()
            let library = MetadataHarnessLibrary([musicLocal, folder])
            let writer = RecordingCloudWriter(answers: [.granted])
            let checker = RecordingCloudWriter(answers: [.undetermined, .granted])
            let c = GetInfoWindowController(tracks: [musicLocal], visibleOrder: [musicLocal.id],
                                            editor: TagEditor(cloud: writer), library: library, artwork: { _ in nil })
            c.permissionChecker = checker
            c.showWindow(nil)
            await settle(0.6)
            guard let window = c.window, let info = c.infoPane else {
                tally.check(false, "routing: Get Info opened")
                return
            }
            c.selectTab(1)
            await settle(0.2)
            let note = visibleNote(in: info)
            tally.check(note?.contains("Music") == true,
                        "routing: the Info tab says a Music-library song's changes are saved through Music",
                        detail: "note=\(note ?? "hidden")")
            snap(window, "routing-music-local-info", evidence)
            let before = fm.contents(atPath: musicCopy.path)
            window.makeFirstResponder(info.name.field)
            replaceText(in: window, with: "Saved through Music")
            let notifications = NotificationCounter()
            let (ok, sheets) = await answeringSheets(evidence: evidence, prefix: "routing-single") { await c.performOK() }
            notifications.stop()
            let writes = await writer.recordedWrites()
            let update = await library.lastUpdate()
            let kinds = sheets.map(kind(of:))
            tally.check(kinds == ["automation"],
                        "routing: saving a Music-library song shows the Automation explanation, not the file warning",
                        detail: "sheets=\(kinds)")
            let explanation = sheets.first { kind(of: $0) == "automation" }?.informative ?? ""
            tally.check(!explanation.isEmpty && !explanation.contains("no file on this Mac"),
                        "routing: the Automation explanation does not claim the songs have no file",
                        detail: explanation)
            tally.check(ok && writes.count == 1 && writes.first?.hex == musicHex && writes.first?.patch.title == "Saved through Music"
                        && fm.contents(atPath: musicCopy.path) == before && update?.ids == [musicLocal.id],
                        "routing: Get Info OK sends the edit to Music, leaves the file alone, updates the row",
                        detail: "ok=\(ok) writes=\(writes.count) update=\(update?.ids ?? [])")
            tally.check(notifications.count == 1, "routing: one Get Info save posts .libraryDidChange once",
                        detail: "\(notifications.count) posts")
            if window.isVisible { c.close() }
        }

        // Multiple Song Information over a folder song and a Music-library song with a file:
        // the file warning is for the folder file; the library song still goes to Music.
        do {
            UserDefaults.standard.removeObject(forKey: GetInfoPrompts.suppressFileWarningKey)
            GetInfoPrompts.resetFileWarningForThisLaunch()
            let library = MetadataHarnessLibrary([musicLocal, folder])
            let writer = RecordingCloudWriter(answers: [.granted])
            let selection = [folder, musicLocal]
            let c = GetInfoWindowController(tracks: selection, visibleOrder: selection.map(\.id),
                                            editor: TagEditor(cloud: writer), library: library, artwork: { _ in nil })
            c.permissionChecker = RecordingCloudWriter(answers: [.granted])
            c.showWindow(nil)
            await settle(0.6)
            guard let window = c.window, let pane = c.multiplePane, let genre = pane.fields[.genre] else {
                tally.check(false, "routing: Multiple Song Information opened")
                return
            }
            let note = visibleNote(in: pane)
            tally.check(note?.contains("Music") == true,
                        "routing: Multiple Song Information notes that library songs are saved through Music",
                        detail: "note=\(note ?? "hidden")")
            let before = fm.contents(atPath: musicCopy.path)
            window.makeFirstResponder(genre.field)
            replaceText(in: window, with: "Multi Routed")
            await settle(0.1)
            snap(window, "routing-multi", evidence)
            let (ok, sheets) = await answeringSheets(evidence: evidence, prefix: "routing-multi") { await c.performOK() }
            let writes = await writer.recordedWrites()
            let back = try? FileTagIO.readFields(at: folderCopy)
            let kinds = sheets.map(kind(of:))
            tally.check(kinds == ["file-warning"], "routing: multi save warns once about the folder file", detail: "sheets=\(kinds)")
            tally.check(ok && back?.genre == "Multi Routed" && writes.map(\.hex) == [musicHex]
                        && fm.contents(atPath: musicCopy.path) == before,
                        "routing: multi save writes the folder file and sends the library song to Music",
                        detail: "ok=\(ok) folder genre=\(back?.genre ?? "nil") writes=\(writes.map(\.hex))")
            if window.isVisible { c.close() }
        }
    }

    // MARK: - Finding 2: compilation

    private static func compilation(sample: HarnessLibrarySample, evidence: URL, tally: HarnessTally) async {
        guard let item = sample.compilationSample else {
            tally.check(false, "compilation: the library has a cloud song on a compilation album")
            return
        }
        let track = HarnessLibrarySample.track(from: item, id: 821)
        var other = track
        other.id = 822
        other.persistentID = (track.persistentID ?? 0) &+ 1
        other.title = track.title + " (second)"
        Log.info("compilation: “\(item.title)” on “\(item.album)” — ITLibAlbum.isCompilation=\(item.isCompilation)")
        tally.check(track.isCompilation && TagFields(track: track).isCompilation,
                    "compilation: TagFields(track:) carries Track.isCompilation",
                    detail: "track=\(track.isCompilation) fields=\(TagFields(track: track).isCompilation)")

        let library = MetadataHarnessLibrary([track, other])
        let writer = RecordingCloudWriter(answers: [.granted])
        let c = GetInfoWindowController(tracks: [track], visibleOrder: [track.id],
                                        editor: TagEditor(cloud: writer), library: library, artwork: { _ in nil })
        c.permissionChecker = RecordingCloudWriter(answers: [.granted])
        c.showWindow(nil)
        await settle(0.6)
        guard let window = c.window, let info = c.infoPane else {
            tally.check(false, "compilation: Get Info opened")
            return
        }
        c.selectTab(1)
        await settle(0.2)
        snap(window, "compilation-info", evidence)
        tally.check(info.compilation.isOn, "compilation: the Info tab shows “Part of a compilation” checked for a compilation")
        info.compilation.isOn = false
        let patch = c.currentPatch()
        tally.check(patch.isCompilation == false && patch.changedFieldNames == ["isCompilation"],
                    "compilation: unticking it makes a patch that clears the flag",
                    detail: "\(patch.changedFieldNames) isCompilation=\(String(describing: patch.isCompilation))")
        let (ok, _) = await answeringSheets(evidence: nil, prefix: "") { await c.performOK() }
        let writes = await writer.recordedWrites()
        let row = await library.track(track.id)
        tally.check(ok && writes.first?.patch.isCompilation == false && row?.isCompilation == false,
                    "compilation: clearing it is sent to Music and lands in the row",
                    detail: "ok=\(ok) writes=\(writes.map { String(describing: $0.patch.isCompilation) }) row=\(String(describing: row?.isCompilation))")
        if window.isVisible { c.close() }

        // Multiple Song Information over two compilations shows "Yes".
        let both = [track, other]
        let m = GetInfoWindowController(tracks: both, visibleOrder: both.map(\.id),
                                        editor: TagEditor(cloud: RecordingCloudWriter(answers: [.granted])),
                                        library: library, artwork: { _ in nil })
        m.permissionChecker = RecordingCloudWriter(answers: [.granted])
        m.showWindow(nil)
        await settle(0.8)
        let shown = m.multiplePane?.compilation.selectedIndex ?? -1
        snap(m.window, "compilation-multi", evidence)
        tally.check(shown == 1, "compilation: Multiple Song Information shows Compilation “Yes” for two compilations",
                    detail: "selectedIndex=\(shown)")
        m.close()
    }

    // MARK: - Finding 1 end to end, against a real index

    /// Ingests Noah's library into the private database named by OLDTUNES_DB_PATH, edits one of
    /// the Music-library songs that has a file (pointed at a scratch copy) through the real Get
    /// Info window and the real `LibraryIndex`, then re-ingests — what every launch and every
    /// Music change does. Music is the recording stand-in, so it never applies the edit; what
    /// must hold is that Music was sent it, the file was not touched behind Music's back, and
    /// after the re-ingest Get Info and the list agree.
    static func ingestRoundTrip(fixturesDir: URL, evidence: URL, tally: HarnessTally) async {
        guard let dbPath = ProcessInfo.processInfo.environment["OLDTUNES_DB_PATH"], !dbPath.isEmpty else {
            Log.info("ingest round trip: skipped — needs OLDTUNES_DB_PATH so the real index is never written")
            return
        }
        let fm = FileManager.default
        let index: LibraryIndex
        do { index = try LibraryIndex() } catch {
            tally.check(false, "ingest: open the private index at \(dbPath)", detail: "\(error)")
            return
        }
        let ingest = LibraryIngest(index: index)
        let first = await ingest.refresh()
        tally.check(first.status == .ok, "ingest: first ingest ok", detail: "\(first.status) songs=\(first.musicLibrarySongs)")

        let localIDs = (try? await index.ids(for: TrackQuery(scope: .onThisMac))) ?? []
        let locals = ((try? await index.tracks(ids: localIDs)) ?? [])
            .filter { $0.origin == .musicLibrary && $0.persistentID != nil }
        guard let target = locals.first(where: { $0.fileURL.map { FileTagIO.problem(with: $0) == nil } ?? false }),
              let original = target.fileURL else {
            tally.check(false, "ingest: a Music-library row with an editable file", detail: "\(locals.count) candidates")
            return
        }
        let copy = fixturesDir.appendingPathComponent("ingest-" + original.lastPathComponent)
        try? fm.removeItem(at: copy)
        guard (try? fm.copyItem(at: original, to: copy)) != nil else {
            tally.check(false, "ingest: scratch copy of \(original.lastPathComponent)")
            return
        }
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: copy.path)
        var probe = target
        probe.fileURL = copy
        let hex = MusicPersistentID.hex(target.persistentID ?? 0)
        Log.info("ingest: row id=\(target.id) pid=\(hex) “\(target.title)”; editing scratch copy \(copy.path)")

        // MetadataHarness.run() puts the user's own value back before quitting.
        UserDefaults.standard.removeObject(forKey: GetInfoPrompts.suppressFileWarningKey)
        GetInfoPrompts.resetFileWarningForThisLaunch()
        let writer = RecordingCloudWriter(answers: [.granted])
        let editor = TagEditor(cloud: writer)
        let c = GetInfoWindowController(tracks: [probe], visibleOrder: [probe.id], editor: editor,
                                        library: index, artwork: { _ in nil })
        c.permissionChecker = RecordingCloudWriter(answers: [.granted])
        c.showWindow(nil)
        await settle(0.6)
        guard let window = c.window, let info = c.infoPane else {
            tally.check(false, "ingest: Get Info opened")
            return
        }
        c.selectTab(1)
        await settle(0.2)
        let edited = "METADATA HARNESS EDITED TITLE"
        let bytesBefore = fm.contents(atPath: copy.path)
        window.makeFirstResponder(info.name.field)
        replaceText(in: window, with: edited)
        let notifications = NotificationCounter()
        let (ok, sheets) = await answeringSheets(evidence: nil, prefix: "") { await c.performOK() }
        await settle(0.3)
        notifications.stop()
        if window.isVisible { c.close() }

        let writes = await writer.recordedWrites()
        let rowAfterSave = try? await index.tracks(ids: [target.id]).first
        Log.info("ingest: after OK sheets=\(sheets.map(kind(of:))) Music writes=\(writes.count) " +
                 "file title “\((try? FileTagIO.readFields(at: copy).title) ?? "?")” row title “\(rowAfterSave?.title ?? "?")” " +
                 "posts=\(notifications.count)")
        tally.check(ok && writes.count == 1 && writes.first?.hex == hex && writes.first?.patch.title == edited,
                    "ingest: the edit is sent to Music for persistent ID \(hex)", detail: "writes=\(writes.count)")
        tally.check(fm.contents(atPath: copy.path) == bytesBefore, "ingest: the song's file is not rewritten behind Music's back")
        tally.check(rowAfterSave?.title == edited, "ingest: the list shows the edit right away",
                    detail: rowAfterSave?.title ?? "nil")
        tally.check(notifications.count == 1, "ingest: the real index's save posts .libraryDidChange once",
                    detail: "\(notifications.count) posts")

        // What every launch and every Music change (+5 s) runs.
        let second = await ingest.refresh()
        let row = try? await index.tracks(ids: [target.id]).first
        var shownRow = row
        shownRow?.fileURL = copy
        let getInfo = try? await editor.readFields(of: shownRow ?? probe)
        Log.info("ingest: after re-ingest (\(second.status)) row title “\(row?.title ?? "?")”, Get Info shows “\(getInfo?.title ?? "?")”")
        tally.check(row != nil && getInfo != nil && getInfo == row.map(TagFields.init(track:)),
                    "ingest: after a re-ingest, Get Info and the list show the same values",
                    detail: "list “\(row?.title ?? "?")” vs Get Info “\(getInfo?.title ?? "?")”")

        await folderRoundTrip(index: index, ingest: ingest, source: original, fixturesDir: fixturesDir, tally: tally)
    }

    /// The other half of the routing rule, through the real index rather than a hand-built
    /// Track: a song added with Add Folder decodes as a `.folder` row, so Get Info writes its
    /// file (after the file warning), never asks Music, and the folder rescan reads the edit back.
    /// Added in verification: every other folder check builds its Track by hand, so nothing else
    /// would notice if a real folder row stopped routing to its file.
    private static func folderRoundTrip(index: LibraryIndex, ingest: LibraryIngest, source: URL,
                                        fixturesDir: URL, tally: HarnessTally) async {
        let fm = FileManager.default
        let folder = fixturesDir.appendingPathComponent("ingest-added-folder", isDirectory: true)
        let name = "Added From Folder.\(source.pathExtension)"
        let file = folder.appendingPathComponent(name)
        try? fm.removeItem(at: folder)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        guard (try? fm.copyItem(at: source, to: file)) != nil else {
            tally.check(false, "ingest folder: scratch copy in a folder to add")
            return
        }
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        let added = (try? await ingest.addFolder(folder)) ?? -1
        let ids = (try? await index.ids(for: TrackQuery(scope: .onThisMac))) ?? []
        let rows = (try? await index.tracks(ids: ids)) ?? []
        guard let row = rows.first(where: { $0.origin == .folder && $0.fileURL?.lastPathComponent == name }),
              let rowURL = row.fileURL else {
            tally.check(false, "ingest folder: Add Folder indexes the copy as an added-folder row", detail: "added=\(added)")
            return
        }
        tally.check(TagEditor.route(for: row) == .file(rowURL) && GetInfoWindowController.musicNote(for: [row]) == nil,
                    "ingest folder: a real added-folder row routes to its file, with no Music note",
                    detail: "route=\(TagEditor.route(for: row))")

        // MetadataHarness.run() puts the user's own value back before quitting.
        UserDefaults.standard.removeObject(forKey: GetInfoPrompts.suppressFileWarningKey)
        GetInfoPrompts.resetFileWarningForThisLaunch()
        let writer = RecordingCloudWriter(answers: [.granted])
        let checker = RecordingCloudWriter(answers: [.granted])
        let editor = TagEditor(cloud: writer)
        let c = GetInfoWindowController(tracks: [row], visibleOrder: [row.id], editor: editor,
                                        library: index, artwork: { _ in nil })
        c.permissionChecker = checker
        c.showWindow(nil)
        await settle(0.6)
        guard let window = c.window, let info = c.infoPane else {
            tally.check(false, "ingest folder: Get Info opened")
            return
        }
        c.selectTab(1)
        await settle(0.2)
        let edited = "METADATA HARNESS FOLDER TITLE"
        window.makeFirstResponder(info.name.field)
        replaceText(in: window, with: edited)
        let notifications = NotificationCounter()
        let (ok, sheets) = await answeringSheets(evidence: nil, prefix: "") { await c.performOK() }
        await settle(0.3)
        notifications.stop()
        if window.isVisible { c.close() }

        let writes = await writer.recordedWrites()
        let asks = await checker.asks() + (await writer.asks())
        let fileTitle = try? FileTagIO.readFields(at: file).title
        tally.check(ok && sheets.map(kind(of:)) == ["file-warning"] && fileTitle == edited && writes.isEmpty && asks.isEmpty,
                    "ingest folder: Get Info OK warns about the file, writes it, and never asks Music",
                    detail: "ok=\(ok) sheets=\(sheets.map(kind(of:))) file “\(fileTitle ?? "nil")” writes=\(writes.count) asks=\(asks)")
        tally.check(notifications.count == 1, "ingest folder: the save posts .libraryDidChange once",
                    detail: "\(notifications.count) posts")

        _ = try? await ingest.addFolder(folder)
        let rescanned = try? await index.tracks(ids: [row.id]).first
        var shown: String?
        if let rescanned { shown = try? await editor.readFields(of: rescanned).title }
        tally.check(rescanned?.title == edited && shown == edited,
                    "ingest folder: after the folder rescan the list and Get Info keep the edit",
                    detail: "list “\(rescanned?.title ?? "nil")” Get Info “\(shown ?? "nil")”")
    }

    // MARK: - Helpers

    struct SeenSheet { var message: String; var informative: String }

    /// Runs `action`, answering every sheet it raises with its default button (photographing
    /// each when `evidence` is given), and returns the action's result and the sheets in order.
    static func answeringSheets(evidence: URL?, prefix: String,
                                _ action: @escaping @MainActor () async -> Bool) async -> (Bool, [SeenSheet]) {
        let result = ResultBox()
        Task { @MainActor in result.value = await action() }
        var seen: [SeenSheet] = []
        var handled: AquaSheet?
        let deadline = Date().addingTimeInterval(20)
        while result.value == nil, Date() < deadline {
            if let sheet = AquaSheet.presented, sheet !== handled {
                handled = sheet
                seen.append(SeenSheet(message: sheet.message, informative: sheet.informative))
                await settle(0.3)
                if let evidence { snap(sheet.window, "\(prefix)-sheet-\(seen.count)", evidence) }
                sheet.press(sheet.buttonTitles.count - 1)
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return (result.value ?? false, seen)
    }

    static func kind(of sheet: SeenSheet) -> String {
        if sheet.message.contains("ask Music") { return "automation" }
        if sheet.message.contains("couldn’t be saved") { return "failures" }
        if sheet.message.contains("file") { return "file-warning" }
        return sheet.message
    }

    /// The "saved through Music" note under a pane, if it is showing.
    static func visibleNote(in pane: NSView) -> String? {
        pane.subviews.compactMap { $0 as? CloudBadgeView }.first { !$0.isHidden }?.text
    }

    private static func settle(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    private static func replaceText(in window: NSWindow, with text: String) {
        guard let editor = window.firstResponder as? NSTextView else { return }
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    private static func snap(_ window: NSWindow?, _ name: String, _ dir: URL) {
        guard let window else { return }
        window.displayIfNeeded()
        let url = dir.appendingPathComponent("\(name).png")
        if Snapshot.write(window, to: url) { Log.info("snapshot: \(url.path)") }
    }
}

@MainActor
private final class ResultBox {
    var value: Bool?
}
