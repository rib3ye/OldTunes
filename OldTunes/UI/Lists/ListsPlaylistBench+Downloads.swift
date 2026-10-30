import AppKit
import GRDB

/// HARNESS ONLY: ListsPlaylistBench's checks for downloading iCloud songs (RESEARCH.md §6.9).
/// Download in the track pane's row menu, on and off by kind of song; the blue cloud in pixels at
/// 1x and 2x, by day and by night; a download as the index sees it, on a scratch index and track
/// list of their own (the same song turning missing, then a file, and another leaving the
/// library); DownloadWatch on a made-up clock, the Mac's sleep included; and AppController's
/// download decisions and wording: a batch's answers tallied as the send loop tallies them (the
/// refusals in a row that stop it, a quit, its count after Stop Downloading, when the alert
/// leaves out the advice to try again), File ▸ Download's title and click, and how the
/// downloader reads Music's answers. Nothing here asks Music for anything.
extension ListsPlaylistBench {

    // MARK: Download in the row menu

    func downloadMenuChecks(_ tracks: TrackListViewController, index: LibraryIndex, in window: NSWindow) async {
        let table = tracks.tableView
        guard let rows = await showLibrary(tracks, index: index) else { return }
        func row(_ title: String) -> Int { rows.firstIndex { $0.title == title } ?? -1 }
        let cloud = row("Invented Song 1"), file = row("Invented Song 7"), missing = row("Invented Song 8")
        let folder = row("Invented Folder Song 1")
        /// The row menu with `selected` selected, right-clicked on the first of them.
        func menu(_ selected: [Int]) -> NSMenu? {
            select(table, selected)
            return rightClick(table, row: selected[0], in: window)
        }
        func download(_ menu: NSMenu?) -> NSMenuItem? { menu?.items.first { $0.title == "Download" } }

        var m = menu([cloud])
        check("a song only in iCloud: Download is on, and File ▸ Download's rule agrees",
              download(m)?.isEnabled == true && tracks.selectionMayHaveCloudSongs, Self.describe(m))
        perform(download(m))
        check("…and choosing it asks for that song", downloadAsks.last == [rows[cloud].id], "\(downloadAsks)")
        m = menu([file])
        check("a song with its file on this Mac: Download is off, Show in Finder on",
              download(m)?.isEnabled == false && m?.items.last?.isEnabled == true && !tracks.selectionMayHaveCloudSongs,
              Self.describe(m))
        m = menu([missing])
        check("a song whose file is missing: Download is off (Music's download brings down iCloud songs, not lost files)",
              download(m)?.isEnabled == false && !tracks.selectionMayHaveCloudSongs, Self.describe(m))
        m = menu([folder])
        check("a song only in OldTunes: Download is off", download(m)?.isEnabled == false && !tracks.selectionMayHaveCloudSongs,
              Self.describe(m))
        m = menu([file, cloud])
        perform(download(m))
        check("one iCloud song among them turns it on, and the whole selection is asked about in row order "
              + "(AppController keeps the iCloud songs)",
              download(m)?.isEnabled == true && downloadAsks.last == [rows[cloud].id, rows[file].id], "\(downloadAsks)")
        let ask = tracks.onDownload
        tracks.onDownload = nil
        m = menu([cloud])
        tracks.onDownload = ask
        check("with nobody to ask, Download is off", download(m)?.isEnabled == false, Self.describe(m))
    }

    // MARK: The blue cloud, in pixels

    /// A song Music was asked to download keeps its cloud, drawn in blue, until its file is here.
    /// Rendered at 1x and 2x by day and by night beside a plain iCloud row on the same background:
    /// the blue must show at 1x, where a cut-out arrow would have been a smear (RESEARCH.md §7.4).
    func downloadBadgeLooks(_ tracks: TrackListViewController, index: LibraryIndex, in window: NSWindow) async {
        let table = tracks.tableView
        guard let content = window.contentView, let rows = await showLibrary(tracks, index: index) else { return }
        func row(_ title: String) -> Int { rows.firstIndex { $0.title == title } ?? -1 }
        // Rows 2 and 4, so both on the plain white rows, not the stripes.
        let requested = row("Invented Song 1"), plain = row("Invented Song 3")
        let file = row("Invented Song 7"), missing = row("Invented Song 8")
        let nameColumn = table.column(withIdentifier: TrackColumn.name.identifier)
        func cell(_ row: Int) -> TrackCellView? {
            table.view(atColumn: nameColumn, row: row, makeIfNecessary: false) as? TrackCellView
        }
        /// The badge's 13 × 9 slot at the right of the Name cell, in the window's content.
        func badge(_ row: Int) -> NSRect? {
            guard let cell = cell(row) else { return nil }
            return content.convert(NSRect(x: cell.bounds.width - TrackCellView.badgeWidth + 1, y: 4, width: 13, height: 9), from: cell)
        }
        table.deselectAll(nil)
        tracks.setDownloading([rows[requested].id, rows[file].id, rows[missing].id])
        await settle()
        window.displayIfNeeded()
        check("a song Music was asked for shows the blue cloud, a plain iCloud song the gray one, a file on this Mac none",
              cell(requested)?.showsDownloading == true && cell(requested)?.showsCloudBadge == true
              && cell(plain)?.showsDownloading == false && cell(plain)?.showsCloudBadge == true
              && cell(file)?.showsDownloading == false && cell(file)?.showsCloudBadge == false,
              "requested \(String(describing: cell(requested)?.showsDownloading)), plain \(String(describing: cell(plain)?.showsCloudBadge)), "
              + "file \(String(describing: cell(file)?.showsCloudBadge))")
        check("a requested song whose file is listed but not there yet keeps the blue cloud, dimmed, rather than going dim with no badge",
              cell(missing)?.showsDownloading == true && cell(missing)?.showsCloudBadge == true && cell(missing)?.isDimmed == true)

        for (name, look) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: look)
            await settle()
            window.displayIfNeeded()
            let blue = resolved(ListsPalette.cloudRequested, in: window), gray = resolved(ListsPalette.cloudBadge, in: window)
            for scale in [1, 2] as [CGFloat] {
                guard let rep = render(content, scale: scale), let a = badge(requested), let b = badge(plain) else {
                    check("\(name) \(Int(scale))x: the window renders", false)
                    continue
                }
                save(rep, "P04_blue_cloud_\(name)_\(Int(scale))x.png")
                var differ = 0, nearBlue = 0, plainNearGray = 0, plainNearBlue = 0
                let x0 = Int((a.minX * scale).rounded(.down)), y0 = Int((a.minY * scale).rounded(.down))
                let dy = Int(((b.minY - a.minY) * scale).rounded())
                for y in y0..<Int((a.maxY * scale).rounded(.up)) {
                    for x in x0..<Int((a.maxX * scale).rounded(.up)) {
                        guard let p = sample(rep, x: x, y: y), let q = sample(rep, x: x, y: y + dy) else { continue }
                        if p.distance(to: q) >= 40 { differ += 1 }
                        if p.distance(to: blue) <= 30 { nearBlue += 1 }
                        if q.distance(to: gray) <= 30 { plainNearGray += 1 }
                        if q.distance(to: blue) <= 30 { plainNearBlue += 1 }
                    }
                }
                let wanted = scale == 1 ? 20 : 80
                check("\(name) \(Int(scale))x: the requested cloud is the accent blue and plainly not the gray one",
                      differ >= wanted && nearBlue >= wanted / 4 && plainNearGray >= wanted / 4 && plainNearBlue == 0,
                      "\(differ) pixels differ by 40 or more (want \(wanted)); \(nearBlue) near \(blue.hex), "
                      + "the plain one \(plainNearGray) near \(gray.hex) and \(plainNearBlue) near the blue")
            }
        }
        window.appearance = nil
        await settle()

        // On a selected row the badge is white, blue or not, as every glyph there is. Nothing
        // else in its slot is: the text stops short of it.
        select(table, [requested])
        await settle()
        window.displayIfNeeded()
        if let rep = render(content, scale: 2), let a = badge(requested) {
            var white = 0
            for y in Int(a.minY * 2)..<Int((a.maxY * 2).rounded(.up)) {
                for x in Int(a.minX * 2)..<Int((a.maxX * 2).rounded(.up)) {
                    if let p = sample(rep, x: x, y: y), min(p.r, p.g, p.b) >= 235 { white += 1 }
                }
            }
            check("on a selected row the requested cloud is white, like every glyph there",
                  white >= 20 && cell(requested)?.showsDownloading == true, "\(white) white pixels in its slot at 2x")
        }
        table.deselectAll(nil)
        tracks.setDownloading([])
        check("once nothing is downloading, the plain cloud comes back", cell(requested)?.showsDownloading == false
              && cell(requested)?.showsCloudBadge == true && cell(missing)?.showsCloudBadge == false)
    }

    // MARK: A download, as the index sees it

    /// What a download looks like to OldTunes: nothing from Music, only the re-ingest finding the
    /// song's row a file, on the same row and Track.ID. Its own scratch index and its own track list
    /// in a second window, so indexChecks' index keeps its state.
    func downloadIndexChecks() async {
        let url = outDir.appendingPathComponent("playlist-bench-downloads.sqlite")
        removeIndex(at: url)
        defer { removeIndex(at: url) }
        let (window, backdrop) = benchWindow(size: NSSize(width: 560, height: 220), title: "OldTunes — downloads")
        defer { window.orderOut(nil) }
        do {
            let index = try LibraryIndex(path: url)
            var songs = Self.songsForDownloads
            let playlists = Self.playlistsForDownloads
            _ = try await index.replaceMusicLibrary(songs, playlists: playlists)
            let tracks = TrackListViewController(library: index)
            HarnessPanes.frame(source: nil, tracks: tracks.view, in: backdrop, top: 12, bottom: 12)
            window.center()
            window.orderFront(nil)
            tracks.setScope(.library, sort: TrackSort(field: .name, ascending: true))
            await tracks.waitForLoad()
            await tracks.waitForRows()
            window.layoutIfNeeded()
            window.displayIfNeeded()
            let table = tracks.tableView
            let nameColumn = table.column(withIdentifier: TrackColumn.name.identifier)
            func cell(_ id: Track.ID) -> TrackCellView? {
                guard let row = tracks.order.firstIndex(of: id) else { return nil }
                return table.view(atColumn: nameColumn, row: row, makeIfNecessary: false) as? TrackCellView
            }
            func idOf(_ pid: Int64) async throws -> Track.ID? {
                try await index.pool.read { try Int64.fetchOne($0, sql: "SELECT id FROM song WHERE persistent_id = ?", arguments: [pid]) }
            }
            /// The re-ingest of a library where Music has the song's file as `bucket`.
            func reingest(_ change: (inout [SongRecord]) -> Void) async throws -> LibraryIndex.MusicLibraryWrite {
                change(&songs)
                let write = try await index.replaceMusicLibrary(songs, playlists: playlists)
                await tracks.reload()
                await tracks.waitForRows()
                window.displayIfNeeded()
                return write
            }
            guard let coming = try await idOf(1002), let leaving = try await idOf(1006) else {
                check("the downloads index has its invented songs", false)
                return
            }
            let t0 = Date(timeIntervalSince1970: 1_000_000)
            let watch = DownloadWatch()
            watch.add([coming, leaving], now: t0)
            for id in [coming, leaving] {
                _ = watch.take(id)
                _ = watch.answer(.requested, for: id, rest: [], now: t0)
            }
            tracks.setDownloading(watch.ids)
            var rows = try await index.tracks(ids: [coming, leaving])
            let early = watch.settle(rows: rows, requested: watch.ids, now: t0.addingTimeInterval(30))
            check("songs Music took show the blue cloud, and stay watched while still in iCloud",
                  cell(coming)?.showsDownloading == true && cell(leaving)?.showsDownloading == true && early.isEmpty
                  && watch.ids == [coming, leaving], "settled \(early)")

            // Music's library may list the file before all of it has landed: the row turns missing.
            var write = try await reingest { $0[1] = Self.downloaded($0[1], as: .missing) }
            rows = try await index.tracks(ids: [coming])
            let midway = watch.settle(rows: rows, requested: [coming], now: t0.addingTimeInterval(60))
            check("a requested song whose file is listed but not there yet stays watched, dimmed, with the blue cloud",
                  write.updated == 1 && rows.first?.bucket == .missing && midway.isEmpty && watch.ids.contains(coming)
                  && cell(coming)?.isDimmed == true && cell(coming)?.showsDownloading == true,
                  "updated \(write.updated), bucket \(String(describing: rows.first?.bucket)), settled \(midway)")

            write = try await reingest { $0[1] = Self.downloaded($0[1], as: .local) }
            rows = try await index.tracks(ids: [coming])
            let sameID = try await idOf(1002)
            let onThisMac = try await index.ids(for: TrackQuery(scope: .onThisMac))
            check("the file lands: the re-ingest updates the same row in place, same Track.ID, and the song is on this Mac",
                  write.updated == 1 && write.inserted == 0 && write.deleted == 0 && !write.playlistsRewritten
                  && sameID == coming && rows.first?.fileURL != nil && rows.first?.isCloudOnly == false && onThisMac == [coming],
                  "updated \(write.updated), inserted \(write.inserted), deleted \(write.deleted), id \(String(describing: sameID)) "
                  + "(was \(coming)), On This Mac \(onThisMac)")
            let done = watch.settle(rows: rows, requested: [coming], now: t0.addingTimeInterval(90))
            check("…the watch counts it done, and its row draws no cloud, blue or gray, even before the list is told",
                  done == [coming] && watch.ids == [leaving] && cell(coming)?.showsCloudBadge == false
                  && cell(coming)?.showsDownloading == false, "settled \(done)")
            tracks.setDownloading(watch.ids)

            write = try await reingest { songs in songs.removeAll { $0.persistentID == 1006 } }
            rows = try await index.tracks(ids: [leaving])
            let gone = watch.settle(rows: rows, requested: [leaving], now: t0.addingTimeInterval(120))
            check("a watched song that leaves the library counts as done, never as a download that failed",
                  write.deleted == 1 && rows.isEmpty && gone == [leaving] && watch.isEmpty && watch.end() == nil,
                  "deleted \(write.deleted), settled \(gone)")
            tracks.setDownloading(watch.ids)
        } catch {
            check("a download on a scratch index of its own", false, "\(error)")
        }
    }

    /// Six invented songs in iCloud, in one playlist.
    static let songsForDownloads: [SongRecord] = (1...6).map { n in
        var r = SongRecord(origin: .musicLibrary)
        r.persistentID = 1000 + Int64(n)
        r.title = "Invented Song \(n)"
        r.artist = "Invented Artist"
        r.album = "Invented Album"
        r.titleSortSource = r.title
        r.artistSortSource = r.artist
        r.albumSortSource = r.album
        r.isCloud = true
        r.locationType = 3
        r.contentHash = r.computeContentHash()
        return r
    }

    static let playlistsForDownloads = [
        PlaylistRecord(info: PlaylistInfo(id: 701, name: "Lakeside", kind: .regular, parentID: nil, trackCount: 2),
                       sortIndex: 0, memberPIDs: [1001, 1002]),
    ]

    /// `record` as the re-ingest reads it once Music has its file: listed, and on disk (`.local`)
    /// or not yet (`.missing`). The hash is worked out again, as ITLibSource does for every record.
    static func downloaded(_ record: SongRecord, as bucket: Track.Bucket) -> SongRecord {
        var r = record
        r.bucket = bucket
        r.locationType = 1
        r.locationPath = "/private/tmp/oldtunes-playlist-bench/Downloads/\(r.title).m4a"
        r.contentHash = r.computeContentHash()
        return r
    }

    // MARK: DownloadWatch, on a made-up clock

    /// A quarter of an hour of the watch's rules in no time: what counts as done, when it asks for
    /// a re-read, and when it gives up. Ticks come 30 s apart, as AppController's loop sends them
    /// while the Mac is awake: a longer gap is the Mac asleep (`DownloadWatch.sleepGap`).
    func downloadWatchChecks() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
        func requested(_ watch: DownloadWatch, _ ids: [Track.ID], at time: Date) {
            for id in ids {
                _ = watch.take(id)
                _ = watch.answer(.requested, for: id, rest: [], now: time)
            }
        }
        /// A tick every 30 s from `start` up to, not including, `end`; whatever they gave up on.
        func tickThrough(_ watch: DownloadWatch, from start: TimeInterval, to end: TimeInterval,
                         lastRefresh: Date?) -> Set<Track.ID> {
            var expired = Set<Track.ID>()
            for now in stride(from: start, to: end, by: 30) {
                expired.formUnion(watch.tick(now: at(now), lastRefresh: lastRefresh).expired)
            }
            return expired
        }

        let w = DownloadWatch()
        check("Download watches each song once: only the new ones are asked for",
              w.add([1, 2, 3], now: t0) == [1, 2, 3] && w.add([2, 3, 4], now: t0) == [4] && w.queued == [1, 2, 3, 4] && w.isAsking)
        check("a song is asked for once", w.take(1) && w.inFlight == 1 && !w.take(1))
        let a1 = w.answer(.requested, for: 1, rest: [], now: at(10))
        check("Music took it: still watched, and that counts as progress",
              a1.dropped.isEmpty && a1.goOn && w.pending[1] != nil && w.inFlight == nil && w.lastProgress == at(10))
        _ = w.take(2)
        let a2 = w.answer(.refused("no"), for: 2, rest: [], now: at(11))
        check("Music turned one down: no longer watched, the batch goes on, and no progress",
              a2.dropped == [2] && a2.goOn && w.pending[2] == nil && w.lastProgress == at(10))
        _ = w.take(3)
        let a3 = w.answer(.unanswered("slow"), for: 3, rest: [4], now: at(12))
        check("Music didn't answer in time: that song stays watched (it may still come), the rest of the batch isn't asked for",
              a3.dropped == [4] && !a3.goOn && w.pending[3] != nil && w.pending[4] == nil && !w.isAsking && w.ids == [1, 3])

        let s = DownloadWatch()
        s.add([10, 11, 12, 13], now: t0)
        requested(s, [10, 11, 12, 13], at: t0)
        let done = s.settle(rows: [Self.track(10), Self.track(11, bucket: .missing), Self.track(12, file: true)],
                            requested: [10, 11, 12, 13], now: at(60))
        check("settling: a song with its file here is done, and so is one with no row (it left the library)",
              done == [12, 13] && s.lastProgress == at(60), "\(done)")
        check("…one still in iCloud keeps waiting, and so does one whose file is listed but missing",
              s.ids == [10, 11], "\(s.ids)")
        check("…and songs whose rows weren't read are left alone", s.settle(rows: [], requested: [], now: at(61)).isEmpty && s.ids == [10, 11])

        let fresh = s.tick(now: at(90), lastRefresh: at(60))
        _ = tickThrough(s, from: 120, to: 240, lastRefresh: at(60))
        let stale = s.tick(now: at(60 + 180), lastRefresh: at(60))
        check("a re-read is due when the library hasn't been read for 3 minutes, or ever",
              fresh == (false, []) && stale == (true, []) && s.tick(now: at(250), lastRefresh: nil).refreshDue,
              "\(fresh), then \(stale)")
        let quiet = 60 + DownloadWatch.quietLimit
        _ = tickThrough(s, from: 270, to: quiet - 1, lastRefresh: at(250))
        let before = s.tick(now: at(quiet - 1), lastRefresh: at(quiet - 100))
        let asked = s.tick(now: at(quiet), lastRefresh: at(quiet - 100))
        check("after 15 quiet minutes the watch asks for a re-read first, and gives up on nothing yet",
              before == (false, []) && asked == (true, []) && s.ids == [10, 11], "\(before) then \(asked)")
        let waiting = s.tick(now: at(quiet + 30), lastRefresh: at(quiet - 100))
        let early = s.tick(now: at(quiet + 40), lastRefresh: at(quiet + 30))
        check("…asks again until a re-read has started, and waits while that one may still be running",
              waiting == (true, []) && early == (false, []) && s.ids == [10, 11], "\(waiting), then \(early)")
        let gaveUp = s.tick(now: at(quiet + 60), lastRefresh: at(quiet + 30))
        check("…then, 30 s after that re-read started, gives up on what is still watched",
              gaveUp.expired == [10, 11] && !gaveUp.refreshDue && s.isEmpty, "\(gaveUp)")
        let ending = s.end()
        check("…and the end says 2 of the 4 songs didn't come, not because Music quit; once",
              ending?.unfinished.sorted() == [10, 11] && ending?.watched == 4 && ending?.musicQuit == false && s.end() == nil,
              "\(String(describing: ending))")

        let r = DownloadWatch()
        r.add([20, 21], now: t0)
        requested(r, [20, 21], at: t0)
        let q = DownloadWatch.quietLimit
        _ = r.tick(now: at(q), lastRefresh: at(0))
        _ = r.settle(rows: [Self.track(20, file: true), Self.track(21)], requested: [20, 21], now: at(q + 10))
        check("a song that comes down during that last re-read calls the giving up off",
              r.tick(now: at(q + 60), lastRefresh: at(q + 20)).expired.isEmpty && r.ids == [21])
        _ = tickThrough(r, from: q + 90, to: q + 10 + q, lastRefresh: at(q + 20))
        _ = r.tick(now: at(q + 10 + q), lastRefresh: at(q + 20))
        _ = r.tick(now: at(q + 10 + q + 30), lastRefresh: at(q + 10 + q + 25))
        let newer = r.tick(now: at(q + 10 + q + 31), lastRefresh: at(q + 10 + q + 29))
        check("a newer re-read starting shows the first one finished: the watch gives up then", newer.expired == [21], "\(newer)")

        let busy = DownloadWatch()
        busy.add([30, 31], now: t0)
        let queued = busy.tick(now: at(q * 3), lastRefresh: at(q * 3))
        _ = busy.take(30)
        _ = busy.answer(.requested, for: 30, rest: [31], now: at(5))
        _ = busy.take(31)
        let flying = busy.tick(now: at(q * 3), lastRefresh: at(q * 3))
        check("nothing gives up while songs wait to be asked for, or one is being asked about",
              queued == (false, []) && flying == (false, []) && busy.ids == [30, 31], "\(queued), \(flying)")

        let stop = DownloadWatch()
        stop.add([40, 41, 42], now: t0)
        requested(stop, [40], at: t0)
        _ = stop.take(41)
        check("Stop Downloading drops only the songs not asked for yet", stop.stopAsking() == [42] && stop.ids == [40, 41]
              && !stop.isAsking && !stop.take(42))
        stop.add([43], now: at(1))
        let quit = stop.expireAll(musicQuit: true)
        let quitEnd = stop.end()
        check("Music quitting gives up on every song at once, queued ones too, and the end says Music quit",
              quit == [40, 41, 43] && stop.isEmpty && stop.inFlight == nil && quitEnd?.musicQuit == true
              && quitEnd?.watched == 3 && quitEnd?.unfinished == [40, 41, 43], "\(String(describing: quitEnd))")

        // The Mac asleep, where Music can't bring anything down: ticks at t and t + 30 s, then
        // none for 8 hours. That time isn't quiet time.
        let sleeper = DownloadWatch()
        sleeper.add([50, 51], now: t0)
        requested(sleeper, [50, 51], at: t0)
        let dozing = [sleeper.tick(now: at(0), lastRefresh: at(0)), sleeper.tick(now: at(30), lastRefresh: at(0))]
        let wake: TimeInterval = 30 + 8 * 3600
        let woke = sleeper.tick(now: at(wake), lastRefresh: at(0))
        let awake = tickThrough(sleeper, from: wake + 30, to: wake + q, lastRefresh: at(wake + 5))
        check("the Mac asleep for 8 hours: its first tick awake gives up on nothing, only asks for a re-read of the "
              + "8-hour-old library, and nothing is given up in the 15 awake minutes after",
              dozing.allSatisfy { $0 == (false, []) } && woke == (true, []) && sleeper.lastProgress == at(wake)
              && awake.isEmpty && sleeper.ids == [50, 51],
              "on waking \(woke), quiet since \(sleeper.lastProgress.map { "\(Int($0.timeIntervalSince(t0))) s" } ?? "never"); "
              + "\(awake.count) given up in the 15 minutes after")
        let reread = at(wake + q + 10)
        let ask = sleeper.tick(now: at(wake + q), lastRefresh: at(wake + 5))
        let wait = sleeper.tick(now: at(wake + q + 30), lastRefresh: reread)
        let gone = sleeper.tick(now: at(wake + q + 60), lastRefresh: reread)
        check("…then, 15 awake minutes on, the usual: a re-read first, and giving up 30 s after it started",
              ask == (true, []) && wait == (false, []) && gone.expired == [50, 51] && sleeper.isEmpty,
              "\(ask), \(wait), \(gone)")
        let next = DownloadWatch()
        next.add([60], now: t0)
        requested(next, [60], at: t0)
        _ = next.tick(now: at(30), lastRefresh: at(0))
        _ = next.settle(rows: [Self.track(60, file: true)], requested: [60], now: at(40))
        let later = at(5 * 3600)
        next.add([61], now: later)
        requested(next, [61], at: later)
        _ = next.tick(now: later.addingTimeInterval(30), lastRefresh: later)
        check("a watch with nothing left forgets its last tick: the next Download's first tick, hours later, isn't taken for a wake",
              next.ids == [61] && next.lastProgress == later,
              "quiet since \(next.lastProgress.map { "\(Int($0.timeIntervalSince(later))) s after the Download" } ?? "never")")
    }

    /// An invented song: in iCloud unless `file` (on this Mac) or another `bucket`.
    static func track(_ id: Track.ID, bucket: Track.Bucket = .cloud, file: Bool = false,
                      origin: Track.Origin = .musicLibrary) -> Track {
        var t = Track.blank(id: id)
        t.origin = origin
        t.persistentID = origin == .folder ? nil : 0x1000 + id
        t.title = "Invented Song \(id)"
        t.bucket = file ? .local : bucket
        t.fileURL = file ? URL(fileURLWithPath: "/private/tmp/oldtunes-playlist-bench/Invented Song \(id).m4a") : nil
        return t
    }

    // MARK: AppController's downloads, decided and worded

    /// The pure statics AppController downloads with, and how the downloader reads Music's answers.
    func downloadBuilderChecks() {
        typealias App = AppController
        let candidates = App.downloadCandidates([Self.track(1), Self.track(2, origin: .folder), Self.track(3, file: true),
                                                 Self.track(4, bucket: .missing), Self.track(1), Self.track(5)])
        check("Download asks for the Music library's iCloud songs only, once each: not files, folder songs or missing files",
              candidates.map(\.id) == [1, 5], "\(candidates.map(\.id))")

        check("what one answer from Music means for its batch",
              DownloadWatch.reduce(.requested, for: 1, rest: [2, 3]) == ([], true)
              && DownloadWatch.reduce(.refused("x"), for: 1, rest: [2, 3]) == ([1], true)
              && DownloadWatch.reduce(.unanswered("x"), for: 1, rest: [2, 3]) == ([2, 3], false)
              && DownloadWatch.reduce(.stopped("x"), for: 1, rest: [2, 3]) == ([1, 2, 3], false))

        // Music turning down song after song the same way, by its error code, before it has taken
        // any of the batch. A refused `download` carries Music's code; a song that couldn't be
        // looked up carries none (no `download` went out for it).
        func streak(_ answers: [MusicDownloadOutcome]) -> [String] {
            var refusals = DownloadWatch.RefusalStreak()
            return answers.compactMap { refusals.note($0) }
        }
        let inARow = DownloadWatch.RefusalStreak.threeInARowReason
        let three = streak([.refused("why", code: -50), .refused("why", code: -50), .refused("why", code: -50)])
        check("three refusals in a row, the same way, before Music took any song of the batch, stop it, with Music's reason",
              inARow == "Music turned down three songs in a row, so OldTunes stopped asking it to download songs."
              && three == ["\(inARow) why"], "\(three)")
        check("…the same way only: a, b, b goes on, and a third b stops",
              streak([.refused("a", code: -1), .refused("b", code: -2), .refused("b", code: -2)]).isEmpty
              && streak([.refused("a", code: -1), .refused("b", code: -2), .refused("b", code: -2), .refused("b", code: -2)])
                == ["\(inARow) b"])
        check("…and none once Music has taken a song of the batch, first or in between: a refusal is then about its own song",
              streak([.requested] + Array(repeating: .refused("x", code: -50), count: 4)).isEmpty
              && streak([.refused("x", code: -50), .refused("x", code: -50), .requested]
                        + Array(repeating: .refused("x", code: -50), count: 3)).isEmpty)
        let named = streak([.refused("Music couldn’t download “A”.", code: -50), .refused("Music couldn’t download “B”.", code: -50),
                            .refused("Music couldn’t download “C”.", code: -50)])
        check("…“the same way” is Music's error code, not its words, which may name each song: the stop quotes the last; "
              + "the same words with different codes don't stop",
              named == ["\(inARow) Music couldn’t download “C”."]
              && streak([.refused("why", code: -1), .refused("why", code: -2), .refused("why", code: -3)]).isEmpty, "\(named)")
        let lookups = streak([.refused("x", code: -50), .refused("gone 1"), .refused("x", code: -50), .refused("gone 2"),
                              .refused("x", code: -50)])
        check("…and a song that couldn't be looked up neither counts nor breaks the run, as in an add",
              lookups == ["\(inARow) x"] && streak(Array(repeating: .refused("gone"), count: 4)).isEmpty, "\(lookups)")

        func outcome(_ code: Int, sent: Bool, missing: Bool = false) -> MusicDownloadOutcome {
            MusicSongDownloader.outcome(of: TagEditError(message: "why", code: code, missingCommand: missing), downloadSent: sent)
        }
        let timeout = MusicSongDownloader.timeoutReason
        check("the downloader reads Music's answers: a timeout after the download went out may still come down, "
              + "one before it stops the batch; -10004, no permission and a missing command stop; Music's own -1708 "
              + "refuses that song, with its code; a missing song refuses that song, with none",
              outcome(-1712, sent: true) == .unanswered(timeout) && outcome(-1712, sent: false) == .stopped(timeout)
              && outcome(-10004, sent: true) == .stopped("why", retryWontHelp: true) && outcome(-1743, sent: false) == .stopped("why")
              && outcome(-1708, sent: true, missing: true) == .stopped("why", retryWontHelp: true)
              && outcome(-1708, sent: true) == .refused("why", code: -1708) && outcome(-1728, sent: false) == .refused("why")
              && MusicSongDownloader.outcome(of: CocoaError(.featureUnsupported), downloadSent: true)
                == .refused(CocoaError(.featureUnsupported).localizedDescription))
        let gone = MusicSongDownloader.musicQuitReason
        check("…and Music gone once prepare() had it running (-600, -609), at the lookup or the download, means it quit: "
              + "the downloader's own quit reason, which the send loop takes for a quit",
              outcome(-600, sent: false) == .stopped(gone) && outcome(-600, sent: true) == .stopped(gone)
              && outcome(-609, sent: false) == .stopped(gone) && outcome(-609, sent: true) == .stopped(gone))
        let forGood = [-10004, -1742].flatMap { code in [false, true].map { outcome(code, sent: $0) } }
        check("…and which stops choosing Download again would only meet again: -10004, -1742 (nothing reaches Music) and a "
              + "missing `download`, at the lookup or the download; never a quit, a timeout, the permission or a missing song",
              forGood.allSatisfy { $0 == .stopped("why", retryWontHelp: true) }
              && MusicSongDownloader.retryWontHelp(after: TagEditError(message: "why", code: -1708, missingCommand: true))
              && ![-600, -609, -1712, -1743, -1708, -1728].contains {
                  MusicSongDownloader.retryWontHelp(after: TagEditError(message: "why", code: $0))
              }, "\(forGood)")

        let d = App.downloadQuestion(count: 1_234, bytes: 8_200_000_000, freeBytes: 61_300_000_000)
        check("a big Download asks first: how many, how much space, how much is free, and that only Music removes them",
              App.downloadQuestion(count: 100, bytes: 2_000_000_000, freeBytes: 1) == nil
              && d?.message == "Download 1,234 songs to this Mac?"
              && d?.informative == "They use about 8.2 GB, and this Mac has 61.3 GB free. The Music app downloads them in the "
                + "background, and only the Music app can remove them again.", "\(String(describing: d))")
        let full = App.downloadQuestion(count: 15_895, bytes: 102_400_000_000, freeBytes: 61_300_000_000)
        check("…and says so first when they won't fit",
              full?.informative.hasPrefix("These songs need about 102.4 GB, but this Mac has only 61.3 GB free. ") == true,
              "\(String(describing: full))")
        check("…by size alone too, free space unknown",
              App.downloadQuestion(count: 3, bytes: 2_500_000_000, freeBytes: nil)?.informative
                == "They use about 2.5 GB. The Music app downloads them in the background, and only the Music app can remove them again.")
        check("sizes in decimal units, as Finder counts free space", App.diskSize(640_000_000) == "640 MB"
              && App.diskSize(999_600_000) == "1.0 GB", "\(App.diskSize(640_000_000)), \(App.diskSize(999_600_000))")
        let roomy = App.downloadQuestion(count: 1_234, bytes: 8_200_000_000, freeBytes: 1_234_500_000_000)
        check("…a terabyte and more in TB, from 999.5 GB up, as the question says it: “1.2 TB”, never “1234.5 GB”",
              App.diskSize(1_234_500_000_000) == "1.2 TB" && App.diskSize(999_500_000_000) == "1.0 TB"
              && App.diskSize(999_400_000_000) == "999.4 GB"
              && roomy?.informative.hasPrefix("They use about 8.2 GB, and this Mac has 1.2 TB free.") == true,
              "\(App.diskSize(1_234_500_000_000)), \(App.diskSize(999_500_000_000)), \(App.diskSize(999_400_000_000))")

        // File ▸ Download, as validateMenuItem shows it and downloadAction takes a click on it.
        check("File ▸ Download while songs still wait to be asked for: Stop Downloading, on, whatever is selected; "
              + "otherwise Download, on only when the selection may hold an iCloud song",
              App.downloadMenuItem(isAsking: true, mayHaveCloudSongs: false) == ("Stop Downloading", true)
              && App.downloadMenuItem(isAsking: false, mayHaveCloudSongs: true) == ("Download", true)
              && App.downloadMenuItem(isAsking: false, mayHaveCloudSongs: false) == ("Download", false))
        check("…a click on Stop Downloading stops, even once the asking ended while the menu was open, so it never starts "
              + "a Download of the selection; a click on Download while idle downloads",
              App.downloadClickStops(isAsking: false, clickedTitle: App.stopDownloadingTitle)
              && App.downloadClickStops(isAsking: true, clickedTitle: App.downloadTitle)
              && !App.downloadClickStops(isAsking: false, clickedTitle: App.downloadTitle)
              && !App.downloadClickStops(isAsking: false, clickedTitle: nil))

        check("a Download where everything came down says nothing, nor one where a song only didn't answer in time",
              App.downloadAlert(.init(total: 9)) == nil && App.downloadAlert(.init(total: 1, unanswered: ["U"])) == nil)
        let expired = App.downloadAlert(.init(total: 12, unfinished: ["A", "B", "C"]))
        check("songs Music took and never brought down",
              expired?.message == "3 of the 12 songs weren’t downloaded."
              && expired?.informative == "The Music app didn’t finish them. They’re still in iCloud. To try again, choose Download again."
              && expired?.details == "A\nB\nC", "\(String(describing: expired))")
        let quit = App.downloadAlert(.init(total: 3, unfinished: ["A", "B", "C"], musicQuit: true))
        check("…because Music quit",
              quit?.message == "The songs weren’t downloaded."
              && quit?.informative == "The Music app quit before it finished. They’re still in iCloud. To try again, choose Download again.",
              "\(String(describing: quit))")
        let one = App.downloadAlert(.init(total: 1, unfinished: ["A"]))
        check("…one song, said for one",
              one?.message == "The song wasn’t downloaded."
              && one?.informative == "The Music app didn’t finish it. It’s still in iCloud. To try again, choose Download again.",
              "\(String(describing: one))")
        let stopped = App.downloadAlert(.init(total: 9, notSent: Array(repeating: "N", count: 7), stopReason: timeout,
                                              unanswered: ["U"]))
        check("Music stopping partway: why, how to try again, and the song that may still come listed apart",
              stopped?.message == "7 of the 9 songs weren’t downloaded."
              && stopped?.informative == "\(timeout) To try again, choose Download again."
              && stopped?.details.contains("Music didn’t answer in time; it may still download it:\nU") == true,
              "\(String(describing: stopped))")
        let refused = App.downloadAlert(.init(total: 9, refused: ["A — r", "B — r"]))
        check("songs Music turned down, with its reasons",
              refused?.message == "2 of the 9 songs weren’t downloaded." && refused?.informative == "Music didn’t accept them."
              && refused?.details == "A — r\nB — r", "\(String(describing: refused))")

        // The songs a Download's end alert still names, read once it can show (unfinishedTitles):
        // it waits while a playlist's name is open for typing, as long as OldTunes stays hidden,
        // and Music may bring songs down meanwhile. A song with no row left the library, or came
        // back as a new song, as DownloadWatch.settle counts it.
        let waited = App.unfinishedTitles([1, 2, 3, 4], rows: [Self.track(1), Self.track(2, file: true),
                                                               Self.track(4, bucket: .missing)])
        check("the songs given up on, read when the alert can show: one that came down meanwhile isn't named, nor one with no "
              + "row; one in iCloud and a dimmed one are, in the order given; a read that found none names none; a failed "
              + "read names them all by a stand-in",
              waited == ["Invented Song 1", "Invented Song 4"]
              && App.unfinishedTitles([1, 2], rows: []).isEmpty
              && App.unfinishedTitles([1, 2], rows: nil) == ["Song 1", "Song 2"], "\(waited)")
        var someDown = App.DownloadTrouble(total: 3), allDown = App.DownloadTrouble(total: 2, musicQuit: true)
        someDown.unfinished = App.unfinishedTitles([1, 2, 5], rows: [Self.track(1), Self.track(2, file: true), Self.track(5, file: true)])
        allDown.unfinished = App.unfinishedTitles([2, 5], rows: [Self.track(2, file: true), Self.track(5, file: true)])
        let someDownAlert = App.downloadAlert(someDown)
        check("…so when two of three came down while it waited, it names the one still in iCloud, of the 3; when all of them "
              + "did, after Music quit and was opened again, it says nothing",
              someDownAlert?.message == "1 of the 3 songs wasn’t downloaded." && someDownAlert?.details == "Invented Song 1"
              && App.downloadAlert(allDown) == nil, "\(String(describing: someDownAlert))")

        // A Download's answers as sendDownloads takes them, on a real watch with Music's answers
        // made up: the watch's answer, then the batch's tally (AppController.DownloadBatch), which
        // says whether to go on and which waiting songs to take off the watch. `stopAfter`: Stop
        // Downloading before that song is asked for.
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        func send(_ ids: [Track.ID], answers: [MusicDownloadOutcome], stopAfter: Int? = nil,
                  on watch: DownloadWatch) -> (trouble: App.DownloadTrouble, tally: App.DownloadBatch, unasked: Set<Track.ID>, reads: Int) {
            var tally = App.DownloadBatch(titles: Dictionary(uniqueKeysWithValues: ids.map { ($0, "Invented Song \($0)") }))
            var unasked = Set<Track.ID>(), reads = 0
            watch.add(ids, now: t0)
            for (n, id) in ids.enumerated() {
                if n == stopAfter {
                    unasked = watch.stopAsking()
                    break
                }
                guard n < answers.count, watch.take(id) else { break }
                let rest: [Track.ID]
                switch answers[n] {
                case .requested, .refused: rest = []
                case .unanswered, .stopped: rest = Array(ids[(n + 1)...])
                }
                let step = watch.answer(answers[n], for: id, rest: rest, now: t0)
                let next = tally.record(answers[n], title: "Invented Song \(id)", step: step) {
                    reads += 1
                    return ids[(n + 1)...].filter(watch.queued.contains)
                }
                watch.remove(next.unsent)
                guard next.goOn else { break }
            }
            return (tally.finish(), tally, unasked, reads)
        }

        // Stop Downloading partway: ten songs; Music turns the first down and takes the next two; then Stop.
        let stopped3 = send(Array(1...10), answers: [.refused("r", code: -50), .requested, .requested], stopAfter: 3,
                            on: DownloadWatch())
        let afterStop = App.downloadAlert(stopped3.trouble)
        check("Stop Downloading partway, after one refusal and two songs Music took: “1 of the 3”, not “1 of the 10”; "
              + "the 7 Stop took aren't counted, as the watch's own count leaves them out",
              stopped3.unasked.count == 7 && stopped3.trouble.total == 3 && stopped3.tally.requested == 2
              && afterStop?.message == "1 of the 3 songs wasn’t downloaded." && afterStop?.informative == "Music didn’t accept it.",
              "total \(stopped3.trouble.total), \(String(describing: afterStop))")
        var unready = App.DownloadBatch(titles: [1: "A", 2: "B"])
        unready.notReady(MusicAutomation.downloadDeniedReason, unsent: [1, 2])
        check("…a Download Music wasn't ready for counts the songs it didn't send; a stopped one, every song it asked about or reports on",
              unready.finish().total == 2 && unready.finish().notSent == ["A", "B"]
              && App.DownloadTrouble(refused: ["A — r"], notSent: ["S", "T", "U"], unanswered: ["Q"]).batchTotal(requested: 3) == 8)

        // A quit, told by the downloader's own reason; isMusicRunning is read only for a stop.
        var looked = 0
        func running(_ value: Bool) -> Bool {
            looked += 1
            return value
        }
        let quits = [App.DownloadBatch.musicQuit(.stopped(MusicSongDownloader.musicQuitReason), musicRunning: running(true)),
                     App.DownloadBatch.musicQuit(.stopped("why"), musicRunning: running(false)),
                     App.DownloadBatch.musicQuit(.stopped(timeout), musicRunning: running(true))]
        let lookedForStops = looked
        let others = [MusicDownloadOutcome.requested, .refused("why", code: -50), .refused("why"), .unanswered(timeout)]
            .filter { App.DownloadBatch.musicQuit($0, musicRunning: running(false)) }
        check("a Download stops as Music quitting on the downloader's quit reason, even while Music still shows as running, or "
              + "on any stop while it isn't; no other answer is one, and none of them even looks whether Music runs",
              quits == [true, true, false] && others.isEmpty && looked == lookedForStops, "\(quits), \(others)")

        // Three refusals in a row stop the batch: the songs still waiting come off the watch, and
        // the alert gives no advice to try again, which would only meet them again (K2).
        let streakWatch = DownloadWatch()
        let refusing = send(Array(1...5), answers: Array(repeating: .refused("Music’s reason", code: -50), count: 5), on: streakWatch)
        let refusedAlert = App.downloadAlert(refusing.trouble)
        check("three refusals in a row stop the batch: the two songs still waiting come off the watch, as not sent, and the alert "
              + "gives Music's reason without “To try again”",
              refusing.trouble.notSent == ["Invented Song 4", "Invented Song 5"] && refusing.trouble.refused.count == 3
              && streakWatch.isEmpty && refusing.reads == 1 && refusing.trouble.total == 5
              && refusedAlert?.message == "The songs weren’t downloaded."
              && refusedAlert?.informative == "\(inARow) Music’s reason Music didn’t accept 3 songs.",
              "not sent \(refusing.trouble.notSent), still watched \(streakWatch.ids.sorted()); \(String(describing: refusedAlert))")
        let walls = send(Array(1...4), answers: [.requested, .stopped("Music refused this request (error -10004).", retryWontHelp: true)],
                         on: DownloadWatch())
        let slow = send(Array(1...3), answers: [.stopped(timeout)], on: DownloadWatch())
        var unfinishedToo = refusing.trouble
        unfinishedToo.unfinished = ["Invented Song 9"]
        check("…nor after -10004, -1742 or a missing `download`, which every song would meet; while after a timeout, and for "
              + "songs Music took and didn't finish, the advice stays: those can be tried again",
              App.downloadAlert(walls.trouble)?.message == "3 of the 4 songs weren’t downloaded."
              && App.downloadAlert(walls.trouble)?.informative == "Music refused this request (error -10004)."
              && App.downloadAlert(slow.trouble)?.informative == "\(timeout) To try again, choose Download again."
              && App.downloadAlert(unfinishedToo)?.informative.hasSuffix("To try again, choose Download again.") == true,
              "\(String(describing: App.downloadAlert(walls.trouble)?.informative)) / "
              + "\(String(describing: App.downloadAlert(slow.trouble)?.informative))")

        // Counts over 1,000 with separators, as the question before a big Download has them.
        let many = App.downloadAlert(.init(total: 15_895, notSent: Array(repeating: "N", count: 15_000),
                                           stopReason: MusicSongDownloader.musicQuitReason))
        let unfinished = App.downloadAlert(.init(total: 2_000, refused: ["A — r"], unfinished: Array(repeating: "U", count: 1_234)))
        check("a Download of more than 1,000 songs counts with separators, as its question does",
              many?.message == "15,000 of the 15,895 songs weren’t downloaded."
              && unfinished?.message == "1,235 of the 2,000 songs weren’t downloaded."
              && unfinished?.informative.hasPrefix("The Music app didn’t finish 1,234 songs. Music didn’t accept one song.") == true,
              "\(many?.message ?? "no alert") / \(unfinished?.message ?? "no alert") \(unfinished?.informative ?? "")")
    }
}
