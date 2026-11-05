import Foundation
import iTunesLibrary

/// HARNESS ONLY. An in-memory `LibraryReading` over Noah's real library, read once and read-only
/// through ITLibrary, so the lists can be exercised before the Library module (SQLite) exists.
/// Sorts use SortKey like the real index; search is a plain folded `contains` per word.
/// Never used by the app proper.
actor ListsHarnessLibrary: LibraryReading {

    /// What one ITLibrary read produced. Plain values, so it can leave the detached task.
    struct Snapshot: Sendable {
        var tracks: [Track]
        var playlists: [PlaylistInfo]
        var members: [Int64: [Int64]]
        var itemCount: Int
        var loadMillis: Double
    }

    /// Precomputed per-row keys and the ascending orders, built off the main thread.
    struct Index: Sendable {
        var tracks: [Track]
        var rowOf: [Int64: Int]
        var ascending: [TrackSortField: [Int32]]
        var haystack: [String]
        var nameKey: [String], artistKey: [String], albumKey: [String], genreKey: [String]
        /// Column copies of the fields filters read, so a filter pass never copies a Track.
        var ids: [Int64], genres: [String], artists: [String], albums: [String], isLocal: [Bool]
        /// `ascending` as ids, for the unfiltered case.
        var ascendingIDs: [TrackSortField: [Int64]]
        var playlists: [PlaylistInfo]
        var memberRows: [Int64: Set<Int32>]
        /// Each regular or smart playlist's rows in its own order, a repeated song kept at its first
        /// position (what `.playlistOrder` shows). Folders have no order of their own.
        var memberOrder: [Int64: [Int32]]
        var buildMillis: Double
    }

    private let index: Index
    /// Rows forced to `.missing` for the dimmed-row visual check when the real library has none.
    private var missingOverride = Set<Int64>()
    /// The per-song checkbox as toggled in this run, like the index keeps oldTunes' own changes.
    private var checkedOverride: [Int64: Bool] = [:]
    /// Simulated slowness per search string, to prove stale results are dropped. The delay
    /// deliberately ignores cancellation, like a library call that cannot be interrupted.
    private var searchLatency: [String: Duration] = [:]

    private(set) var idsCalls = 0
    private(set) var tracksCalls = 0
    private(set) var rowsServed = 0
    private(set) var largestTracksRequest = 0
    private(set) var searchesSeen: [String] = []

    init(index: Index) { self.index = index }

    nonisolated var trackCount: Int { index.tracks.count }
    nonisolated var buildMillis: Double { index.buildMillis }

    func markMissing(_ ids: Set<Int64>) { missingOverride = ids }
    /// What `LibraryWriting.setChecked` does to the index, minus the notification (the bench
    /// reloads the list itself, as AppController does on `.libraryDidChange`).
    func setChecked(_ ids: [Int64], _ checked: Bool) { for id in ids { checkedOverride[id] = checked } }
    func clearCheckedOverrides() { checkedOverride = [:] }
    /// A playlist's own order as the index stores it, for checking `.playlistOrder`.
    func playlistOrder(_ id: Int64) -> [Int64] { (index.memberOrder[id] ?? []).map { index.ids[Int($0)] } }
    func setSearchLatency(_ latency: [String: Duration]) { searchLatency = latency }
    func resetCounters() {
        idsCalls = 0; tracksCalls = 0; rowsServed = 0; largestTracksRequest = 0; searchesSeen = []
    }

    // MARK: LibraryReading

    func ids(for query: TrackQuery) async throws -> [Track.ID] {
        idsCalls += 1
        searchesSeen.append(query.search)
        if let delay = searchLatency[query.search] {
            try? await Task.sleep(for: delay)
        }
        let unfiltered = query.scope == .library && query.search.isEmpty
            && query.genre == nil && query.artist == nil && query.album == nil
        if unfiltered, let ids = index.ascendingIDs[query.sort.field] {
            return query.sort.ascending ? ids : ids.reversed()
        }
        let rows = matchingRows(query, upTo: nil, ordered: query.sort.field)
        let ids = rows.map { index.ids[Int($0)] }
        return query.sort.ascending ? ids : ids.reversed()
    }

    func tracks(ids: [Track.ID]) async throws -> [Track] {
        tracksCalls += 1
        rowsServed += ids.count
        largestTracksRequest = max(largestTracksRequest, ids.count)
        return ids.compactMap { id in
            guard let row = index.rowOf[id] else { return nil }
            var track = index.tracks[row]
            if missingOverride.contains(id) {
                track.bucket = .missing
                track.isCloud = false
            }
            if let checked = checkedOverride[id] { track.isChecked = checked }
            return track
        }
    }

    func summary(for ids: [Track.ID]) async throws -> LibrarySummary {
        var s = LibrarySummary.empty
        for id in ids {
            guard let row = index.rowOf[id] else { continue }
            s.count += 1
            s.totalSeconds += index.tracks[row].duration
            s.totalBytes += index.tracks[row].fileSize
        }
        return s
    }

    func playlists() async throws -> [PlaylistInfo] { index.playlists }

    func browserValues(_ field: BrowserField, for query: TrackQuery) async throws -> [String] {
        var keyOf: [String: String] = [:]
        for row in matchingRows(query, upTo: field, ordered: nil) {
            let i = Int(row)
            let value: String, key: String
            switch field {
            case .genre: value = index.genres[i]; key = index.genreKey[i]
            case .artist: value = index.artists[i]; key = index.artistKey[i]
            case .album: value = index.albums[i]; key = index.albumKey[i]
            }
            if !value.isEmpty && keyOf[value] == nil { keyOf[value] = key }
        }
        return keyOf.sorted { ($0.value, $0.key) < ($1.value, $1.key) }.map(\.key)
    }

    func count() async throws -> Int { index.tracks.count }

    // MARK: Filtering

    /// Rows passing scope, search, and the browser filters LEFT of `field` (all three when nil).
    private func matchingRows(_ q: TrackQuery, upTo field: BrowserField?, ordered: TrackSortField?) -> [Int32] {
        var source: [Int32] = ordered.flatMap { index.ascending[$0] } ?? Array(0..<Int32(index.tracks.count))
        // A playlist in its own order; anywhere else .playlistOrder is artist order, as in the index.
        if ordered == .playlistOrder, case .playlist(let id) = q.scope, let own = index.memberOrder[id] {
            source = own
        }
        let needles = Self.fold(q.search).split(separator: " ").map(String.init)
        let members: Set<Int32>?
        if case .playlist(let id) = q.scope { members = index.memberRows[id] ?? [] } else { members = nil }
        let genre = field != .genre ? q.genre : nil
        let artist = field == nil || field == .album ? q.artist : nil
        let album = field == nil ? q.album : nil
        let onThisMac = q.scope == .onThisMac
        if members == nil, !onThisMac, genre == nil, artist == nil, album == nil, needles.isEmpty {
            return source
        }
        var out: [Int32] = []
        out.reserveCapacity(source.count)
        for row in source {
            let i = Int(row)
            if let members, !members.contains(row) { continue }
            if onThisMac, !index.isLocal[i] { continue }
            if let genre, index.genres[i] != genre { continue }
            if let artist, index.artists[i] != artist { continue }
            if let album, index.albums[i] != album { continue }
            if !needles.isEmpty {
                let hay = index.haystack[Int(row)]
                if !needles.allSatisfy({ hay.contains($0) }) { continue }
            }
            out.append(row)
        }
        return out
    }

    nonisolated static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    // MARK: Building

    /// Reads the real library. Read-only: ITLibrary has no write API we touch.
    nonisolated static func readITLibrary() async throws -> Snapshot {
        try await Task.detached(priority: .userInitiated) { () throws -> Snapshot in
            let start = Date()
            let library = try ITLibrary(apiVersion: "1.0", options: .lazyLoadData)
            let items = library.allMediaItems
            var tracks: [Track] = []
            tracks.reserveCapacity(items.count)
            for item in items where item.mediaKind == .kindSong {
                tracks.append(track(from: item))
            }
            let songIDs = Set(tracks.map(\.id))

            // Music.app's own lists (Music, Movies, Purchased…) are not user playlists; the
            // stock smart playlists (90's Music, Recently Added…) are, as in iTunes 4.9.
            let userVisibleDistinguished: Set<UInt> = [0, 42, 43, 44, 45, 46, 48, 52]
            var playlists: [PlaylistInfo] = []
            var members: [Int64: [Int64]] = [:]
            for list in library.allPlaylists {
                guard !list.isPrimary, list.isVisible,
                      userVisibleDistinguished.contains(UInt(list.distinguishedKind.rawValue)) else { continue }
                let kind: PlaylistInfo.Kind
                switch list.kind.rawValue {
                case 1: kind = .smart
                case 2, 4: kind = .genius
                case 3: kind = .folder
                default: kind = .regular
                }
                let id = Int64(bitPattern: list.persistentID.uint64Value)
                let ids = list.items.compactMap { item -> Int64? in
                    let tid = Int64(bitPattern: item.persistentID.uint64Value)
                    return songIDs.contains(tid) ? tid : nil
                }
                let parent = list.parentID.map { Int64(bitPattern: $0.uint64Value) }
                playlists.append(PlaylistInfo(id: id, name: list.name, kind: kind, parentID: parent, trackCount: ids.count))
                members[id] = ids
            }
            return Snapshot(tracks: tracks, playlists: playlists, members: members, itemCount: items.count,
                            loadMillis: Date().timeIntervalSince(start) * 1000)
        }.value
    }

    nonisolated private static func track(from item: ITLibMediaItem) -> Track {
        let pid = Int64(bitPattern: item.persistentID.uint64Value)
        var t = Track.blank(id: pid)
        t.persistentID = pid
        t.title = item.title
        t.artist = item.artist?.name ?? ""
        t.album = item.album.title ?? ""
        t.albumArtist = item.album.albumArtist ?? ""
        t.composer = item.composer
        t.genre = item.genre
        t.comments = item.comments ?? ""
        t.grouping = item.grouping ?? ""
        t.year = Int(item.year)
        t.trackNumber = Int(item.trackNumber)
        t.trackCount = Int(item.album.trackCount)
        t.discNumber = Int(item.album.discNumber)
        t.discCount = Int(item.album.discCount)
        t.bpm = Int(item.beatsPerMinute)
        t.duration = Double(item.totalTime) / 1000
        t.dateAdded = item.addedDate
        t.playCount = Int(item.playCount)
        t.rating = item.rating
        t.kind = item.kind ?? ""
        t.bitRate = Int(item.bitrate)
        t.sampleRate = Int(item.sampleRate)
        t.fileSize = Int64(clamping: item.fileSize)
        t.hasArtwork = item.hasArtworkAvailable
        t.albumPID = Int64(bitPattern: item.album.persistentID.uint64Value)
        t.isCloud = item.isCloud
        t.isChecked = !item.isUserDisabled
        t.locationType = Int(item.locationType.rawValue)
        let fileExists = item.locationType == .file
            && (item.location.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
        if fileExists {
            t.fileURL = item.location
            t.bucket = .local
        } else if item.isCloud || item.locationType == .remote {
            t.bucket = .cloud
        } else {
            t.bucket = .missing
        }
        return t
    }

    /// Sort keys and the eight ascending orders. iTunes' tie-breaks: artist → album → disc →
    /// track number → name; album → disc → track; a blank date or year sorts first ascending,
    /// so "newest first" ends with them, as the Track model documents.
    nonisolated static func buildIndex(_ snap: Snapshot) async -> Index {
        await Task.detached(priority: .userInitiated) { () -> Index in
            let start = Date()
            let tracks = snap.tracks
            let n = tracks.count
            let nameKey = tracks.map { SortKey.make($0.displayTitle) }
            let artistKey = tracks.map { SortKey.make($0.artist) }
            let albumKey = tracks.map { SortKey.make($0.album) }
            let genreKey = tracks.map { SortKey.make($0.genre) }
            let haystack = tracks.map { fold([$0.title, $0.artist, $0.album, $0.albumArtist, $0.composer].joined(separator: " ")) }
            var rowOf = [Int64: Int](minimumCapacity: n)
            for (i, t) in tracks.enumerated() { rowOf[t.id] = i }

            func albumOrder(_ a: Int, _ b: Int) -> Bool? {
                if albumKey[a] != albumKey[b] { return albumKey[a] < albumKey[b] }
                if tracks[a].discNumber != tracks[b].discNumber { return tracks[a].discNumber < tracks[b].discNumber }
                if tracks[a].trackNumber != tracks[b].trackNumber { return tracks[a].trackNumber < tracks[b].trackNumber }
                return nil
            }
            func byName(_ a: Int, _ b: Int) -> Bool {
                nameKey[a] != nameKey[b] ? nameKey[a] < nameKey[b] : tracks[a].id < tracks[b].id
            }
            let rows = Array(0..<n)
            var ascending: [TrackSortField: [Int32]] = [:]
            for field in TrackSortField.allCases {
                let sorted: [Int]
                switch field {
                case .name:
                    sorted = rows.sorted { a, b in
                        nameKey[a] != nameKey[b] ? nameKey[a] < nameKey[b]
                            : (artistKey[a] != artistKey[b] ? artistKey[a] < artistKey[b] : byName(a, b))
                    }
                case .artist, .playlistOrder:
                    sorted = rows.sorted { a, b in
                        if artistKey[a] != artistKey[b] { return artistKey[a] < artistKey[b] }
                        return albumOrder(a, b) ?? byName(a, b)
                    }
                case .album:
                    sorted = rows.sorted { a, b in albumOrder(a, b) ?? byName(a, b) }
                case .genre:
                    sorted = rows.sorted { a, b in
                        if genreKey[a] != genreKey[b] { return genreKey[a] < genreKey[b] }
                        if artistKey[a] != artistKey[b] { return artistKey[a] < artistKey[b] }
                        return albumOrder(a, b) ?? byName(a, b)
                    }
                case .time:
                    sorted = rows.sorted { a, b in
                        tracks[a].duration != tracks[b].duration ? tracks[a].duration < tracks[b].duration : byName(a, b)
                    }
                case .dateAdded:
                    sorted = rows.sorted { a, b in
                        let da = tracks[a].dateAdded ?? .distantPast, db = tracks[b].dateAdded ?? .distantPast
                        return da != db ? da < db : byName(a, b)
                    }
                case .year:
                    sorted = rows.sorted { a, b in
                        tracks[a].year != tracks[b].year ? tracks[a].year < tracks[b].year : (albumOrder(a, b) ?? byName(a, b))
                    }
                case .playCount:
                    sorted = rows.sorted { a, b in
                        tracks[a].playCount != tracks[b].playCount ? tracks[a].playCount < tracks[b].playCount : byName(a, b)
                    }
                }
                ascending[field] = sorted.map { Int32($0) }
            }

            // Folder playlists show everything inside them.
            var memberRows: [Int64: Set<Int32>] = [:]
            var memberOrder: [Int64: [Int32]] = [:]
            for (id, ids) in snap.members {
                let rows = ids.compactMap { rowOf[$0].map { Int32($0) } }
                memberRows[id] = Set(rows)
                var seen = Set<Int32>()
                memberOrder[id] = rows.filter { seen.insert($0).inserted }
            }
            for p in snap.playlists where p.kind == .folder { memberOrder[p.id] = nil }
            let childrenOf = Dictionary(grouping: snap.playlists.filter { $0.parentID != nil }, by: { $0.parentID ?? 0 })
            func collect(_ id: Int64, depth: Int) -> Set<Int32> {
                guard depth < 32 else { return [] }
                var all = memberRows[id] ?? []
                for child in childrenOf[id] ?? [] { all.formUnion(collect(child.id, depth: depth + 1)) }
                return all
            }
            var playlists = snap.playlists
            for i in playlists.indices where playlists[i].kind == .folder {
                let all = collect(playlists[i].id, depth: 0)
                memberRows[playlists[i].id] = all
                playlists[i].trackCount = all.count
            }

            return Index(tracks: tracks, rowOf: rowOf, ascending: ascending, haystack: haystack,
                         nameKey: nameKey, artistKey: artistKey, albumKey: albumKey, genreKey: genreKey,
                         ids: tracks.map(\.id), genres: tracks.map(\.genre), artists: tracks.map(\.artist),
                         albums: tracks.map(\.album), isLocal: tracks.map { $0.fileURL != nil },
                         ascendingIDs: ascending.mapValues { $0.map { tracks[Int($0)].id } },
                         playlists: playlists, memberRows: memberRows, memberOrder: memberOrder,
                         buildMillis: Date().timeIntervalSince(start) * 1000)
        }.value
    }
}
