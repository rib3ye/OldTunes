import Foundation
import iTunesLibrary
import MusicKit

/// Reads Music.app's library (iTunesLibrary) and MusicKit, and keeps the index in step with them
/// and with any added folders (RESEARCH.md §2).
///
/// The slow parts run elsewhere — the iTunesLibrary parse on `ITLibSource`, MusicKit and
/// AVFoundation as plain async calls — so this actor stays free to answer `cloudSong(for:)`
/// promptly while a refresh is in flight.
actor LibraryIngest: LibraryIngesting, CloudSongResolving {
    private let index: LibraryIndex
    /// Internal rather than private so the library harness can cross-check the index against it.
    let itlib = ITLibSource()

    /// The play map (§1 step 2). Filled from the same MusicKit request that writes `cloud_id`.
    private var cloudSongs: [Int64: Song] = [:]
    /// True once a full library request has filled `cloudSongs`; until then a miss is not final.
    private var cloudMapReady = false
    private var subscription: SubscriptionInfo?
    /// Set when the catalog refuses to mint a developer token; see `cloudSong(for:)`.
    private var catalogUnavailable = false

    /// Refreshes run one at a time, in call order.
    private var refreshChain: Task<IngestReport, Never>?
    /// Refreshes running or waiting their turn in the chain, so `refreshIfIdle` can tell.
    private var refreshesInFlight = 0
    /// Of those, the ones that haven't begun. Each reads Music's playlists after whatever ran
    /// before it, so while one waits, neither the stale-playlists retry nor `refreshSoon` needs a
    /// pass of its own.
    private var refreshesWaiting = 0
    /// Finished refreshes and when the last one started; lets a caller see that a change
    /// notification really led to a re-ingest.
    private(set) var refreshCount = 0
    private(set) var lastRefreshStarted: Date?
    /// When the newest refresh that worked started, set once it has written Music's library to the
    /// index. One that failed (no permission, iTunesLibrary or the index write failing) sets
    /// `lastRefreshStarted` too, but read nothing in: the download watch, whose last re-read before
    /// it gives up on a song must have read the library, goes by this (`DownloadWatch.tick`).
    private(set) var lastWrittenRefreshStarted: Date?
    private var changeObserver: (any NSObjectProtocol)?
    /// The re-ingest a change notification has scheduled, until it starts.
    private var pendingChange: Task<Void, Never>?
    /// When the first of the change notifications still waiting for that re-ingest came.
    private var firstUnhandledChange: ContinuousClock.Instant?
    /// When the last change notification came, to tell a new run of them from one still going.
    private var lastChange: ContinuousClock.Instant?
    /// Re-ingests in a row that the max wait started, since Music was last quiet for 5 s.
    private var forcedChanges = 0
    /// The pass the stale-playlists retry has scheduled, until it starts (`retryStalePlaylists`).
    private var pendingRetry: Task<Void, Never>?
    /// Passes in a row that found Music's playlists edited while they read them (`staleRetryWait`).
    private var stalePasses = 0

    /// How long Music must be quiet before a change notification triggers a re-ingest. The
    /// notification is coarse and arrives in bursts while Music.app writes (§8.5).
    static let changeDebounce: Duration = .seconds(5)
    /// The longest a re-ingest waits while Music keeps posting. A long download batch or a long
    /// Add to Playlist may never leave Music quiet for 5 s, and its songs should still show up as
    /// they land rather than all at the end.
    static let changeMaxWait: Duration = .seconds(30)
    /// Such a job can go on for hours, and a re-ingest takes 5 to 18 s, a MusicKit request among
    /// it, so while the changes keep coming the max wait doubles after each re-ingest it starts,
    /// up to this (`changeWait`).
    static let changeMaxWaitCap: Duration = .seconds(5 * 60)

    /// The max wait after `forced` re-ingests in a row that it started: 30 s, then twice as long
    /// each time, up to 5 minutes.
    static func changeMaxWait(after forced: Int) -> Duration {
        // 30 s × 2⁴ is past the cap already, so the shift stays small.
        min(changeMaxWaitCap, changeMaxWait * (1 << min(max(forced, 0), 4)))
    }

    /// The change debounce's rule, on durations alone so the library bench can run it.
    /// A notification comes `sinceFirst` after the first one still waiting, and `sinceLast` after
    /// the one before it (nil: none yet). `forced`: the re-ingests in a row the max wait started;
    /// Music quiet for more than 5 s before this one starts that count over, which matters when
    /// the last run of changes ended on a forced re-ingest and left nothing waiting. Returns how
    /// long to wait before the re-ingest, 5 s of quiet but no longer than the max wait from the
    /// first, and what `forced` becomes if that re-ingest starts: one more when the max wait cut
    /// the 5 s short, 0 when Music was quiet for them, which puts the max wait back to 30 s.
    static func changeWait(sinceFirst: Duration, sinceLast: Duration?,
                           forced: inout Int) -> (wait: Duration, forcedOnStart: Int) {
        if sinceLast.map({ $0 > changeDebounce }) ?? true { forced = 0 }
        let wait = max(.zero, min(changeDebounce, changeMaxWait(after: forced) - sinceFirst))
        return (wait, wait < changeDebounce ? forced + 1 : 0)
    }

    /// The stale-playlists retry's rule, on counts alone so the library bench can run it. A pass
    /// that found Music's playlists edited while it read them (`stale`) left them alone (§6.8),
    /// and nothing else may read them again: Music's last notification can have come before the
    /// edit, and Music may post nothing while a long add goes in. `stalePasses`: such passes in a
    /// row, counting this one; a pass that read them whole sets it back to 0 and needs no retry
    /// (nil). The first retry's base delay is 5 s; performRefresh also waits for edit settling.
    /// While every
    /// pass finds another edit (an add whose chunks land faster than iTunesLibrary loads), the
    /// wait is 30 s, then twice as long each time, up to 5 minutes, as the max wait is.
    static func staleRetryWait(stale: Bool, stalePasses: inout Int) -> Duration? {
        guard stale else {
            stalePasses = 0
            return nil
        }
        stalePasses += 1
        return stalePasses == 1 ? changeDebounce : changeMaxWait(after: stalePasses - 2)
    }

    init(index: LibraryIndex) {
        self.index = index
    }

    // MARK: - LibraryIngesting

    func refresh() async -> IngestReport {
        // This pass reads Music's playlists after any that found them edited, so a retry still
        // waiting has nothing left to do (one pass at a time).
        pendingRetry?.cancel()
        pendingRetry = nil
        let previous = refreshChain
        refreshesInFlight += 1
        refreshesWaiting += 1
        let task = Task { [weak self] () -> IngestReport in
            _ = await previous?.value
            guard let self else { return IngestReport(status: .failed("The library was closed.")) }
            return await self.performRefresh()
        }
        refreshChain = task
        let report = await task.value
        refreshesInFlight -= 1
        return report
    }

    /// A re-ingest, unless one is already running, waiting its turn, or scheduled by a change
    /// notification: for a caller that only needs the index to be fairly fresh, such as watching
    /// for downloads to land in case Music doesn't say. Nil when skipped. A stale-playlists retry
    /// still waiting doesn't skip it: this re-ingest reads the playlists again in its place.
    func refreshIfIdle() async -> IngestReport? {
        guard refreshesInFlight == 0, pendingChange == nil else { return nil }
        return await refresh()
    }

    /// A re-ingest that reads the library from now on, for a caller that knows the index is behind
    /// Music: unlike `refreshIfIdle`, it doesn't skip while a pass runs, which may have read the
    /// library too early, but queues behind it (`refresh`). Skipped (nil) only when a pass is
    /// already waiting its turn, or a change notification has scheduled one: that pass starts
    /// later, so it reads what this one would. It never queues a pass behind one already waiting.
    /// For an add that ends with Music maybe still adding a song, or with its playlist gone
    /// (`AppController.addRereadsLibrary`): a running pass that found the playlists edited while it
    /// read them would read them again only after its back-off (`staleRetryWait`).
    func refreshSoon() async -> IngestReport? {
        guard refreshesWaiting == 0, pendingChange == nil else { return nil }
        return await refresh()
    }

    func addFolder(_ url: URL) async throws -> Int {
        let path = url.standardizedFileURL.path
        // A root that does not exist would be stored forever and shown as missing rows.
        guard FileManager.default.fileExists(atPath: path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: path])
        }
        let root = FolderScanner.canonicalPath(path)
        try await index.addFolderRoot(root)
        let scan = try await rescanFolder(root)
        if scan.changedIndex { await LibraryIndex.postDidChange() }
        Log.info("library: added folder \(root): \(scan.addedOrUpdated) tracks added or updated")
        return scan.addedOrUpdated
    }

    func addFolder(_ url: URL, handingOffTo music: any MusicLibraryAdding) async throws -> MusicHandoffReport {
        let path = url.standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: path])
        }
        let root = FolderScanner.canonicalPath(path)
        var report = MusicHandoffReport(root: root)
        let owned = try await index.musicOwnedPaths()
        // Finder order, so an album reaches Music track by track.
        let files = await FolderScanner.scan(root).files.map(\.path)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let offers = files.filter { !owned.contains($0) }
        report.alreadyInMusic = files.count - offers.count

        if !offers.isEmpty, let reason = await music.prepare() {
            report.notSent = offers
            report.stopReason = reason
        } else {
            offering: for (n, file) in offers.enumerated() {
                switch await music.add(URL(fileURLWithPath: file)) {
                case .added(let pid):
                    // Recorded at once: Music announces every add, so a re-ingest can rescan this
                    // folder before the last file is offered.
                    try await index.recordHandoff(path: file, persistentID: pid)
                    report.handedOff.append(file)
                case .refused(let why):
                    report.refused.append(file)
                    Log.info("library: Music didn't add \(file): \(why)")
                case .stopped(let why):
                    report.notSent = Array(offers[n...])
                    report.stopReason = why
                    Log.error("library: hand-off to Music stopped at \(file): \(why)")
                    break offering
                }
            }
        }

        // The rest is a plain folder add, which the hand-off records keep away from Music's songs.
        try await index.addFolderRoot(root)
        let scan = try await rescanFolder(root)
        if scan.changedIndex { await LibraryIndex.postDidChange() }
        report.folderTracks = scan.addedOrUpdated
        Log.info("library: added folder \(root) with Music: \(report.handedOff.count) to Music, " +
                 "\(report.refused.count) refused, \(report.notSent.count) not sent, \(report.alreadyInMusic) already there; " +
                 "\(scan.addedOrUpdated) folder tracks added or updated, \(scan.removed) removed")
        return report
    }

    func restoreHandoffs(_ paths: [String]) async {
        do {
            let restored = try await index.restoreHandoffs(paths)
            Log.info("library: restored \(restored) of \(paths.count) Music hand-off records")
        } catch {
            Log.error("library: restoring Music hand-off records failed: \(error)")
        }
    }

    func artworkData(for track: Track) async -> Data? {
        switch track.origin {
        case .musicLibrary:
            guard let pid = track.persistentID else { return nil }
            return await itlib.artworkData(persistentID: pid)
        case .folder:
            guard let url = track.fileURL else { return nil }
            return await AudioFileReader.artwork(at: url)
        }
    }

    // MARK: - CloudSongResolving

    func cloudSong(for track: Track) async -> Song? {
        guard track.origin == .musicLibrary, let pid = track.persistentID else { return nil }
        if let song = cloudSongs[pid] { return song }

        // The full map takes ~4 s to build; never make a double-click wait for it.
        if !cloudMapReady, let song = await resolveOne(track, persistentID: pid) {
            cloudSongs[pid] = song
            return song
        }
        // Step 3 (§1): the catalog, only for rows with a catalog id and a subscription that can play it.
        guard track.storeItemID != 0, !catalogUnavailable, await canPlayCatalog() else { return nil }
        do {
            return try await MusicKitSource.catalogSong(storeItemID: track.storeItemID)
        } catch MusicTokenRequestError.developerTokenRequestFailed {
            // Not per-song: the App ID lacks the MusicKit App Service (§3.4), so every catalog
            // request will fail the same way until that portal step is done and the app relaunched.
            catalogUnavailable = true
            Log.error("library: catalog requests need the MusicKit App Service on com.noahtsutsui.oldtunes " +
                      "(RESEARCH.md §3.4); fallback step 3 is off for this launch")
            return nil
        } catch {
            Log.error("library: catalog lookup for \(track.storeItemID) failed: \(error)")
            return nil
        }
    }

    /// Step 2 for a single row: by MusicKit id when an earlier ingest stored one, else by title
    /// narrowed to the exact persistent id.
    private func resolveOne(_ track: Track, persistentID: Int64) async -> Song? {
        do {
            if let cloudID = track.cloudID {
                return try await MusicKitSource.librarySong(cloudID: cloudID)
            }
            return try await MusicKitSource.librarySong(title: track.title, persistentID: persistentID)
        } catch {
            Log.error("library: single-song lookup for \(track.id) failed: \(error)")
            return nil
        }
    }

    private func canPlayCatalog() async -> Bool {
        if subscription == nil { subscription = try? await MusicKitSource.subscription() }
        return subscription?.canPlayCatalogContent ?? false
    }

    // MARK: - Watching Music.app

    /// Observes the Music library's change notification (distributed center), debounced, and re-runs refresh().
    func startWatchingForChanges() {
        guard changeObserver == nil else { return }
        // Distributed, not NotificationCenter.default: registering there compiles and never fires (§8.5).
        // Never removed: the ingest lives as long as the app, and the weak capture makes the
        // block a no-op if it ever does not.
        changeObserver = DistributedNotificationCenter.default().addObserver(
            forName: .ITLibraryDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            Task { await self?.libraryDidChange() }
        }
        Log.info("library: watching \(Notification.Name.ITLibraryDidChange.rawValue)")
    }

    /// Re-ingests 5 s after the last notification, but never later than the max wait after the
    /// first one still waiting: 30 s, and longer while Music keeps posting (`changeWait`).
    private func libraryDidChange() {
        let now = ContinuousClock.now
        let first = firstUnhandledChange ?? now
        firstUnhandledChange = first
        let (wait, forced) = Self.changeWait(sinceFirst: now - first, sinceLast: lastChange.map { now - $0 },
                                             forced: &forcedChanges)
        lastChange = now
        pendingChange?.cancel()
        pendingChange = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self else { return }
            await self.changeSettled(forced: forced)
        }
    }

    /// The wait is over: notifications from here on count toward the next re-ingest.
    /// `forced`: the re-ingests in a row the max wait has now started (`changeWait`).
    private func changeSettled(forced: Int) async {
        // A notification that came while this task woke has scheduled a newer one.
        guard !Task.isCancelled else { return }
        pendingChange = nil
        firstUnhandledChange = nil
        forcedChanges = forced
        Log.info("library: Music library changed; re-ingesting" + (forced == 0 ? "" :
                 " without 5 s of quiet, \(forced) in a row; the next waits up to " +
                 "\(Self.changeMaxWait(after: forced).components.seconds) s"))
        _ = await refresh()
    }

    /// Reads Music's playlists again `wait` from now (`staleRetryWait`), unless a pass is
    /// already waiting its turn, which reads them anyway. Not through the change debounce:
    /// Music posted nothing, and there each retry came 5 s after the pass before it. Whichever
    /// comes first, this pass or a notification's, calls the other off (`refresh`,
    /// `retrySettled`), so the two never queue two passes.
    private func retryStalePlaylists(after wait: Duration) {
        guard refreshesWaiting == 0 else {
            Log.info("library: playlist snapshot predates an edit or its settling window; the queued re-ingest reads them again")
            return
        }
        Log.info("library: playlist snapshot predates an edit or its settling window; reading again in \(wait.components.seconds) s")
        pendingRetry?.cancel()
        pendingRetry = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self else { return }
            await self.retrySettled()
        }
    }

    /// The retry's wait is over. A change notification still waiting for its own re-ingest is
    /// read by this pass too, so that one is called off.
    private func retrySettled() async {
        // A pass queued while this task woke has taken its place.
        guard !Task.isCancelled else { return }
        pendingRetry = nil
        pendingChange?.cancel()
        pendingChange = nil
        firstUnhandledChange = nil
        _ = await refresh()
    }

    // MARK: - Refresh

    private func performRefresh() async -> IngestReport {
        refreshesWaiting -= 1
        let started = Date()
        lastRefreshStarted = started
        defer { refreshCount += 1 }
        var report = IngestReport(status: .ok)

        if let refusal = await Self.authorizationRefusal() {
            report.status = .notAuthorized(refusal)
            Log.error("library: not authorized: \(refusal)")
            return report
        }

        // MusicKit's ~4 s request overlaps the iTunesLibrary parse instead of following it.
        async let musicKit = Self.fetchMusicKitLibrary()
        async let subscription = try? MusicKitSource.subscription()

        // Read before the snapshot, so a playlist edit applied while iTunesLibrary is being read
        // (an Add to Playlist going in, say) isn't overwritten by a snapshot older than it.
        let playlistStamp = try? await index.playlistEditStamp()
        let playlistReadStarted = Date()
        let snapshot: ITLibSource.Snapshot
        do {
            snapshot = try await itlib.load()
        } catch ITLibSource.LoadError.emptyLibrary {
            // Never wipe the index on iTunesLibrary's word alone: an unauthorized read looks exactly
            // like an empty library (§3.6). MusicKit throws instead when it may not read the library,
            // so when it found no songs either, the library really is empty.
            guard Self.confirmsEmptyLibrary(await musicKit), let empty = try? await itlib.load(acceptingEmpty: true) else {
                report.status = .notAuthorized(Self.permissionMessage)
                Log.error("library: iTunesLibrary returned no items and MusicKit did not confirm an empty library; " +
                          "treating as not authorized")
                return report
            }
            Log.info("library: iTunesLibrary and MusicKit both found no songs; the Music library is empty")
            snapshot = empty
        } catch {
            report.status = .failed(error.localizedDescription)
            Log.error("library: iTunesLibrary failed: \(error)")
            return report
        }

        do {
            let write = try await index.replaceMusicLibrary(snapshot.records, playlists: snapshot.playlists,
                                                            playlistStamp: playlistStamp,
                                                            playlistReadStarted: playlistReadStarted)
            // Music's songs are in the index as this pass read them.
            lastWrittenRefreshStarted = started
            // The change notification is coarse (§8.5), so many re-ingests find nothing new; a post
            // then would only make the UI reload for nothing.
            if write.changedIndex { await LibraryIndex.postDidChange() }
            report.musicLibrarySongs = snapshot.records.count
            for record in snapshot.records {
                switch record.bucket {
                case .local: report.localFiles += 1
                case .cloud: report.cloudOnly += 1
                case .missing: report.missing += 1
                }
            }
            Log.info("library: iTunesLibrary items=\(snapshot.mediaItemCount) songs=\(snapshot.records.count) " +
                     "load=\(Self.ms(snapshot.loadSeconds)) rows=\(Self.ms(snapshot.rowsSeconds)) " +
                     "playlists=\(snapshot.playlists.count) (\(Self.ms(snapshot.playlistSeconds))) " +
                     "unchecked=\(snapshot.records.lazy.filter { !$0.isChecked }.count) " +
                     "storeIDs=\(snapshot.nonZeroStoreIDs) [key \(ITLibKeys.storeItemID)] " +
                     "albumPIDs=\(snapshot.nonZeroAlbumPIDs) agree=\(snapshot.albumPIDAgreement) " +
                     "[key \(ITLibKeys.albumPersistentID)]")
            Log.info("library: index write inserted=\(write.inserted) updated=\(write.updated) " +
                     "unchanged=\(write.unchanged) deleted=\(write.deleted) " +
                     "playlists rewritten=\(write.playlistsRewritten) (\(write.playlistItems) items) " +
                     "playlist snapshot deferred=\(write.playlistsStale) " +
                     "analyzed=\(write.analyzed) in \(Self.ms(write.seconds))")
            // The snapshot predates an edit or began inside its settling window. Retry no sooner
            // than that window ends, with the existing back-off while edits keep landing.
            if let wait = Self.staleRetryWait(stale: write.playlistsStale, stalePasses: &stalePasses) {
                retryStalePlaylists(after: max(wait, .seconds(write.playlistRetryAfter)))
            }
        } catch {
            report.status = .failed("The library index could not be written: \(error.localizedDescription)")
            Log.error("library: index write failed: \(error)")
            return report
        }

        report.folderTracks = await rescanAllFolders()

        let kit = await musicKit
        report.subscription = await subscription
        if let sub = report.subscription { self.subscription = sub }
        switch kit {
        case .success(let library):
            let libraryPIDs = Set(snapshot.records.compactMap(\.persistentID))
            report.musicKitSongs = library.returned
            report.joined = library.songs.keys.reduce(0) { $0 + (libraryPIDs.contains($1) ? 1 : 0) }
            cloudSongs = library.songs
            cloudMapReady = true
            do {
                let changed = try await index.applyCloudIDs(library.songs.mapValues { $0.id.rawValue })
                if changed > 0 { await LibraryIndex.postDidChange() }
                Log.info("library: MusicKit songs=\(library.returned) keyed=\(library.songs.count) " +
                         "joined=\(report.joined)/\(snapshot.records.count) request=\(Self.ms(library.requestSeconds)) " +
                         "keying=\(Self.ms(library.keySeconds)); " +
                         "cloud_id changed=\(changed)")
            } catch {
                Log.error("library: writing cloud ids failed: \(error)")
            }
        case .failure(let error):
            // The rows are still good; playback falls back to one-song lookups by stored cloud id.
            Log.error("library: MusicLibraryRequest failed: \(error)")
        }

        report.seconds = Date().timeIntervalSince(started)
        return report
    }

    private static func fetchMusicKitLibrary() async -> Result<MusicKitSource.Library, any Error> {
        do { return .success(try await MusicKitSource.librarySongs()) } catch { return .failure(error) }
    }

    /// Whether MusicKit's answer shows that a Music library iTunesLibrary read as empty really is
    /// empty: the request went through and found no songs. A failed request shows nothing.
    static func confirmsEmptyLibrary(_ musicKit: Result<MusicKitSource.Library, any Error>) -> Bool {
        guard case .success(let library) = musicKit else { return false }
        return library.returned == 0
    }

    static let permissionMessage = "OldTunes can't read your music library. Open System Settings ▸ Privacy & Security ▸ " +
        "Media & Apple Music, turn on OldTunes, then quit and reopen OldTunes."

    /// Nil when MusicKit is authorized. `.denied` is also what a build missing its usage key
    /// reports (§3.6), and a new grant only takes effect after relaunch, so the message says so.
    private static func authorizationRefusal() async -> String? {
        var status = MusicAuthorization.currentStatus
        if status == .notDetermined { status = await MusicAuthorization.request() }
        switch status {
        case .authorized: return nil
        case .restricted: return "Access to your music library is restricted on this Mac."
        default: return permissionMessage
        }
    }

    // MARK: - Folders

    /// Rescans every added folder. Returns the folder tracks now in the index.
    private func rescanAllFolders() async -> Int {
        do {
            var changed = false
            for root in try await index.folderRoots() {
                changed = try await rescanFolder(root).changedIndex || changed
            }
            if changed { await LibraryIndex.postDidChange() }
            return try await index.rowCount(origin: .folder)
        } catch {
            Log.error("library: folder rescan failed: \(error)")
            return 0
        }
    }

    private struct FolderScan {
        var addedOrUpdated = 0
        var removed = 0
        /// Rows flipped between local and missing because the root came or went.
        var availabilityFlips = 0
        var changedIndex: Bool { addedOrUpdated + removed + availabilityFlips > 0 }
    }

    /// Adds new files, re-reads changed ones, drops rows whose file is gone. Unchanged paths keep
    /// their rows untouched.
    private func rescanFolder(_ root: String) async throws -> FolderScan {
        var scan = FolderScan()
        let there = FileManager.default.fileExists(atPath: root)
        let available = there && FolderScanner.canOpen(root)
        scan.availabilityFlips = try await index.setFolderRoot(root, available: available)
        guard available else {
            Log.info("library: folder \(root) is \(there ? "shut to OldTunes until chosen again" : "not available"); " +
                     "its rows are marked missing")
            return scan
        }

        let walk = await FolderScanner.scan(root)
        let files = walk.files
        let known = try await index.folderFiles(under: root)
        // Swift compares and hashes strings by canonical equivalence, so a Music path spelled in
        // NFD still matches the walk's NFC spelling of the same file (the harness checks this).
        let ownedByMusic = try await index.musicOwnedPaths()

        let changed = files.filter { file in
            guard !ownedByMusic.contains(file.path) else { return false }
            guard let old = known[file.path] else { return true }
            return old.size != file.size || old.mtime != file.mtime
        }
        let present = Set(files.map(\.path)).subtracting(ownedByMusic)
        // A file under a subfolder the walk couldn't open wasn't seen, not deleted: its row is
        // marked missing below, and comes back when OldTunes may open the folder again.
        let shut = walk.shut.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        let gone = known.keys.filter { path in !present.contains(path) && !shut.contains { path.hasPrefix($0) } }

        let records = await FolderScanner.records(for: changed, addedAt: Int64(Date().timeIntervalSince1970))
        try await index.upsertFolderRecords(records)
        scan.addedOrUpdated = records.count
        scan.removed = try await index.deleteFolderRows(paths: Array(gone))
        for folder in walk.shut {
            scan.availabilityFlips += try await index.setFolderRoot(folder, available: false)
        }
        if !walk.shut.isEmpty {
            Log.info("library: folder \(root): \(walk.shut.count) folder(s) inside are shut to OldTunes; their rows are marked missing")
        }
        if scan.addedOrUpdated > 0 || scan.removed > 0 {
            Log.info("library: folder \(root): \(files.count) files, \(scan.addedOrUpdated) added/updated, \(scan.removed) removed")
        }
        return scan
    }

    private static func ms(_ seconds: Double) -> String { "\(Int((seconds * 1000).rounded())) ms" }
}
