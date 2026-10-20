import Foundation
import iTunesLibrary
import MusicKit
import os

/// Harness-only stand-in for the Library module, which lives in another worktree. Reads a few
/// real songs read-only from iTunesLibrary and MusicKit so the coordinator is tested against the
/// same kinds of rows it will get in the app. Never writes anything.
///
/// Track ids are the persistent-id bit patterns, so a row and its MusicKit song share one key.
///
/// `Simulation` reproduces, on demand, the failures the review found: MusicKit permission missing
/// (the real resolver then waited out a hung subscription check on every row), lookups that are
/// slow and find nothing, and songs that resolve but that MusicKit will not prepare.
final class PlaybackHarnessLibrary: LibraryReading, CloudSongResolving {
    struct Simulation: Sendable {
        /// MusicKit permission is missing: every lookup waits this long, then finds nothing, as
        /// the real resolver did while MusicSubscription.current hung (review finding 3).
        var unauthorizedLookupDelay: Duration?
        /// Rows whose lookup waits this long, then finds nothing.
        var slowMisses: [Track.ID: Duration] = [:]
        /// Rows that resolve to a MusicKit song that MusicKit then refuses to prepare (finding 5).
        /// The harness makes CloudTransport fail exactly these songs (`unpreparableSongIDs`).
        var unpreparable: Set<Track.ID> = []
    }

    let order: [Track.ID]
    let byID: [Track.ID: Track]
    let simulation: Simulation
    private let songs: [Int64: Song]
    /// Rows changed since load, the way a Get Info save or a re-ingest changes them.
    private let edits = OSAllocatedUnfairLock<[Track.ID: Track]>(initialState: [:])
    private let lookupCount = OSAllocatedUnfairLock(initialState: 0)

    init(tracks: [Track], songs: [Int64: Song], simulation: Simulation = Simulation()) {
        self.order = tracks.map(\.id)
        self.byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        self.songs = songs
        self.simulation = simulation
    }

    /// How many times cloudSong(for:) has been called.
    var lookups: Int { lookupCount.withLock { $0 } }

    /// Changes a row the way LibraryWriting.update does. The caller posts `.libraryDidChange`.
    func edit(_ id: Track.ID, _ change: (inout Track) -> Void) {
        guard var track = edits.withLock({ $0[id] }) ?? byID[id] else { return }
        change(&track)
        let edited = track
        edits.withLock { $0[id] = edited }
    }

    func clearEdits() { edits.withLock { $0 = [:] } }

    /// The MusicKit song ids that the `unpreparable` rows resolve to.
    var unpreparableSongIDs: Set<MusicItemID> {
        Set(simulation.unpreparable.compactMap { byID[$0]?.persistentID }.compactMap { songs[$0]?.id })
    }

    /// What MusicKit's prepareToPlay threw for an uploaded song in the review: code 6.
    static func prepareFailure() -> any Error {
        NSError(domain: "MPMusicPlayerControllerErrorDomain", code: 6)
    }

    // MARK: LibraryReading

    func ids(for query: TrackQuery) async throws -> [Track.ID] { order }

    func tracks(ids: [Track.ID]) async throws -> [Track] {
        let edited = edits.withLock { $0 }
        return ids.compactMap { edited[$0] ?? byID[$0] }
    }

    func summary(for ids: [Track.ID]) async throws -> LibrarySummary {
        let rows = ids.compactMap { byID[$0] }
        return LibrarySummary(count: rows.count, totalSeconds: rows.reduce(0) { $0 + $1.duration },
                              totalBytes: rows.reduce(0) { $0 + $1.fileSize })
    }

    func playlists() async throws -> [PlaylistInfo] { [] }
    func browserValues(_ field: BrowserField, for query: TrackQuery) async throws -> [String] { [] }
    func count() async throws -> Int { order.count }

    // MARK: CloudSongResolving

    func cloudSong(for track: Track) async -> Song? {
        lookupCount.withLock { $0 += 1 }
        if let delay = simulation.unauthorizedLookupDelay {
            try? await Task.sleep(for: delay)
            return nil
        }
        if let delay = simulation.slowMisses[track.id] {
            try? await Task.sleep(for: delay)
            return nil
        }
        guard let pid = track.persistentID else { return nil }
        return songs[pid]
    }
}

extension PlaybackHarnessLibrary {
    struct Loaded: Sendable {
        var locals: [Track]
        var clouds: [Track]
        var songs: [Int64: Song]
    }

    /// Every local-file song plus up to `cloudLimit` cloud songs that MusicKit can stream.
    static func load(cloudLimit: Int) async throws -> Loaded {
        let songs = try await withTimeout(30) { () -> [Song] in
            var request = MusicLibraryRequest<Song>()
            request.limit = 200
            return Array(try await request.response().items)
        }
        var byPID: [Int64: Song] = [:]
        for song in songs {
            if let pid = persistentID(of: song) { byPID[pid] = song }
        }
        if let first = songs.first {
            Log.info("harness: MusicKit sample id=\(first.id.rawValue) joinKey=\(persistentID(of: first).map(String.init) ?? "nil")")
        }
        Log.info("harness: MusicLibraryRequest returned \(songs.count) songs, \(byPID.count) with a persistent id")

        let wanted = Set(byPID.keys)
        let all = try await Task.detached { () throws -> [Track] in
            let library = try ITLibrary(apiVersion: "1.0", options: .lazyLoadData)
            return library.allMediaItems
                .filter { $0.mediaKind == .kindSong }
                .filter { $0.locationType == .file || wanted.contains(Int64(bitPattern: $0.persistentID.uint64Value)) }
                .map(track(from:))
        }.value

        let locals = all.filter { $0.fileURL != nil }
        let clouds = all.filter { $0.fileURL == nil && $0.duration >= 60 && $0.duration <= 600 }
            .sorted { $0.id < $1.id }
            .prefix(cloudLimit)
        return Loaded(locals: locals, clouds: Array(clouds), songs: byPID)
    }

    /// MusicKit library song ids on macOS are the persistent id in decimal; the play parameters
    /// carry it too, which covers either signedness.
    static func persistentID(of song: Song) -> Int64? {
        let raw = song.id.rawValue
        if let signed = Int64(raw) { return signed }
        if let unsigned = UInt64(raw) { return Int64(bitPattern: unsigned) }
        guard let params = song.playParameters,
              let data = try? JSONEncoder().encode(params),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        switch json["musicKit_persistentID"] {
        case let n as NSNumber: return n.int64Value
        case let s as String: return Int64(s) ?? UInt64(s).map { Int64(bitPattern: $0) }
                                    ?? UInt64(s, radix: 16).map { Int64(bitPattern: $0) }
        default: return nil
        }
    }

    private static func track(from item: ITLibMediaItem) -> Track {
        let pid = Int64(bitPattern: item.persistentID.uint64Value)
        var t = Track.blank(id: pid)
        t.persistentID = pid
        t.title = item.title
        t.artist = item.artist?.name ?? ""
        t.album = item.album.title ?? ""
        t.duration = Double(item.totalTime) / 1000
        t.locationType = Int(item.locationType.rawValue)
        t.isCloud = item.isCloud
        if item.locationType == .file, let url = item.location {
            t.fileURL = url
            t.bucket = .local
        } else {
            t.bucket = .cloud
        }
        return t
    }
}
