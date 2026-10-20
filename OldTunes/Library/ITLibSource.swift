import Foundation
import iTunesLibrary

/// The metadata authority (RESEARCH.md §2): owns the process's only `ITLibrary` and turns its
/// songs and playlists into Sendable records.
///
/// An actor of its own, separate from `LibraryIngest`, because touching `allMediaItems` blocks
/// for ~1.5 s. While that runs here, `LibraryIngest` stays free to resolve a cloud song for a
/// double-click.
actor ITLibSource {
    enum LoadError: LocalizedError {
        /// The framework's own permission lie (§3.6): init succeeds, the library is empty.
        case emptyLibrary
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .emptyLibrary: "The Music library came back empty, which is what macOS reports when access is denied."
            case .unavailable(let reason): "The Music library could not be opened: \(reason)"
            }
        }
    }

    struct Snapshot: Sendable {
        var records: [SongRecord]
        var playlists: [PlaylistRecord]
        var mediaItemCount: Int
        var nonZeroStoreIDs: Int
        var nonZeroAlbumPIDs: Int
        /// Songs where the album persistent id from `valueForProperty` equals `album.persistentID`.
        var albumPIDAgreement: Int
        var loadSeconds: Double
        var rowsSeconds: Double
        var playlistSeconds: Double
    }

    /// Exactly one per process (§8.5): two instances share a process-wide cache.
    private var library: ITLibrary?
    /// Kept so artwork reads need no reload. The items are only touched on this actor.
    private var itemsByPID: [Int64: ITLibMediaItem] = [:]

    func load() throws -> Snapshot {
        let started = Date()
        let library = try openLibrary()
        let items = library.allMediaItems
        guard !items.isEmpty else { throw LoadError.emptyLibrary }
        let loaded = Date()

        let songs = items.filter { $0.mediaKind == .kindSong }
        var records: [SongRecord] = []
        records.reserveCapacity(songs.count)
        var byPID: [Int64: ITLibMediaItem] = [:]
        byPID.reserveCapacity(songs.count)
        var storeIDs = 0, albumPIDs = 0, agreement = 0
        let fileManager = FileManager.default
        for item in songs {
            let check = AlbumPIDCheck(item)
            let record = Self.record(for: item, albumPID: check.value, fileManager: fileManager)
            if record.storeItemID != 0 { storeIDs += 1 }
            if record.albumPID != 0 { albumPIDs += 1 }
            if check.agrees { agreement += 1 }
            records.append(record)
            if let pid = record.persistentID { byPID[pid] = item }
        }
        itemsByPID = byPID
        let rowsDone = Date()

        let playlists = Self.playlists(library.allPlaylists, songPIDs: Set(byPID.keys))
        let done = Date()

        return Snapshot(records: records, playlists: playlists, mediaItemCount: items.count,
                        nonZeroStoreIDs: storeIDs, nonZeroAlbumPIDs: albumPIDs, albumPIDAgreement: agreement,
                        loadSeconds: loaded.timeIntervalSince(started),
                        rowsSeconds: rowsDone.timeIntervalSince(loaded),
                        playlistSeconds: done.timeIntervalSince(rowsDone))
    }

    /// Full-size artwork bytes from the Music library. Never `artworkForMediaFile` (§8.6).
    func artworkData(persistentID: Int64) -> Data? {
        if itemsByPID.isEmpty, let library = try? openLibrary() {
            for item in library.allMediaItems where item.mediaKind == .kindSong {
                itemsByPID[Int64(bitPattern: item.persistentID.uint64Value)] = item
            }
        }
        return itemsByPID[persistentID]?.artwork?.imageData
    }

    // MARK: - Cross-checks for the library harness

    /// Music's own member list for one playlist, in Music's order with repeats kept, read straight
    /// from iTunesLibrary rather than from the index. Nil when Music has no such playlist.
    func musicMemberPIDs(ofPlaylist id: Int64) throws -> [Int64]? {
        let library = try currentLibrary()
        guard let playlist = library.allPlaylists.first(where: { Int64(bitPattern: $0.persistentID.uint64Value) == id }) else {
            return nil
        }
        return playlist.items.map { Int64(bitPattern: $0.persistentID.uint64Value) }
    }

    /// The songs Music shows unchecked (`isUserDisabled`), by persistent id.
    func musicUncheckedPIDs() throws -> Set<Int64> {
        var out = Set<Int64>()
        for item in try currentLibrary().allMediaItems where item.mediaKind == .kindSong && item.isUserDisabled {
            out.insert(Int64(bitPattern: item.persistentID.uint64Value))
        }
        return out
    }

    /// The open library as last loaded, without asking it to re-read Music's database.
    private func currentLibrary() throws -> ITLibrary {
        if let library { return library }
        return try openLibrary()
    }

    /// Opens the library once, and on later calls asks it to re-read Music's database.
    private func openLibrary() throws -> ITLibrary {
        if let library {
            library.reloadData()
            return library
        }
        do {
            let opened = try ITLibrary(apiVersion: "1.0", options: .lazyLoadData)
            library = opened
            return opened
        } catch {
            throw LoadError.unavailable(error.localizedDescription)
        }
    }

    // MARK: - Mapping

    private static func record(for item: ITLibMediaItem, albumPID: Int64, fileManager: FileManager) -> SongRecord {
        let album = item.album
        var r = SongRecord(origin: .musicLibrary)
        r.persistentID = Int64(bitPattern: item.persistentID.uint64Value)
        r.storeItemID = (item.value(forProperty: ITLibKeys.storeItemID.value) as? NSNumber)?.int64Value ?? 0

        r.title = item.title
        r.artist = item.artist?.name ?? ""
        r.album = album.title ?? ""
        r.albumArtist = album.albumArtist ?? ""
        r.composer = item.composer
        r.genre = item.genre
        r.comments = item.comments ?? ""
        r.grouping = item.grouping ?? ""

        r.totalTimeMs = Int64(item.totalTime)
        r.trackNumber = item.trackNumber
        r.trackCount = album.trackCount
        r.discNumber = album.discNumber
        r.discCount = album.discCount
        r.year = item.year
        r.bpm = item.beatsPerMinute
        r.addedAt = item.addedDate.map { Int64($0.timeIntervalSince1970) } ?? 0
        r.playCount = item.playCount
        r.rating = item.rating
        r.isCompilation = album.isCompilation
        // The typed property; the checkbox is off when Music marks the song user-disabled.
        r.isChecked = !item.isUserDisabled

        r.isCloud = item.isCloud
        r.locationType = Int(item.locationType.rawValue)
        r.hasArtwork = item.hasArtworkAvailable
        r.albumPID = albumPID
        r.kind = item.kind ?? ""
        r.bitRate = item.bitrate
        r.sampleRate = item.sampleRate
        r.fileSize = Int64(clamping: item.fileSize)

        // Classified once here (§0): only a file that is really on disk counts as local.
        if item.locationType == .file, let url = item.location {
            r.locationPath = url.path
            r.bucket = fileManager.fileExists(atPath: url.path) ? .local : .missing
        } else if item.locationType == .file {
            r.bucket = .missing
        } else {
            r.bucket = .cloud
        }

        // The library's own sort fields win when present (§4.3). They live on the related
        // objects; the item only has sortTitle.
        r.titleSortSource = item.sortTitle ?? item.title
        r.artistSortSource = item.artist?.sortName ?? r.artist
        r.albumSortSource = album.sortTitle ?? r.album
        r.albumArtistSortSource = album.sortAlbumArtist ?? r.albumArtist
        r.contentHash = r.computeContentHash()
        return r
    }

    private static func playlists(_ all: [ITLibPlaylist], songPIDs: Set<Int64>) -> [PlaylistRecord] {
        var out: [PlaylistRecord] = []
        for playlist in all {
            guard !playlist.isPrimary, playlist.isVisible,
                  isMusicPlaylist(playlist.distinguishedKind) else { continue }
            let members = playlist.items.compactMap { item -> Int64? in
                let pid = Int64(bitPattern: item.persistentID.uint64Value)
                return songPIDs.contains(pid) ? pid : nil
            }
            let info = PlaylistInfo(
                id: Int64(bitPattern: playlist.persistentID.uint64Value),
                name: playlist.name,
                kind: kind(of: playlist.kind),
                parentID: playlist.parentID.map { Int64(bitPattern: $0.uint64Value) },
                trackCount: members.count)
            out.append(PlaylistRecord(info: info, sortIndex: out.count, memberPIDs: members))
        }
        return out
    }

    /// User playlists and the music smart playlists iTunes 4.9 showed. The "Music" distinguished
    /// playlist is the library itself, and the rest are video, podcast and app lists.
    private static func isMusicPlaylist(_ kind: ITLibDistinguishedPlaylistKind) -> Bool {
        switch kind {
        case .kindNone, .kind90sMusic, .kindMyTopRated, .kindTop25MostPlayed, .kindRecentlyPlayed,
             .kindRecentlyAdded, .kindClassicalMusic, .kindLovedSongs, .kindPurchases:
            true
        default:
            false
        }
    }

    private static func kind(of kind: ITLibPlaylistKind) -> PlaylistInfo.Kind {
        switch kind {
        case .smart: .smart
        case .folder: .folder
        case .genius, .geniusMix: .genius
        default: .regular
        }
    }
}

/// Reads the album persistent id both ways so the ingest can report whether the undocumented key
/// actually returns values (the typed `album.persistentID` is the cross-check).
private struct AlbumPIDCheck {
    var value: Int64
    var agrees: Bool

    init(_ item: ITLibMediaItem) {
        let typed = Int64(bitPattern: item.album.persistentID.uint64Value)
        let keyed = (item.value(forProperty: ITLibKeys.albumPersistentID.value) as? NSNumber)
            .map { Int64(bitPattern: $0.uint64Value) } ?? 0
        value = keyed != 0 ? keyed : typed
        agrees = keyed == typed
    }
}
