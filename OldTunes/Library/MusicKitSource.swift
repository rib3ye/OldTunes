import Foundation
import MusicKit

/// The playability authority (RESEARCH.md §2): finds the MusicKit `Song` that streams a library
/// track. Every call goes through `withTimeout`, because several MusicKit requests hang forever
/// instead of failing when the app is not authorized (§3.6).
enum MusicKitSource {
    struct Library: Sendable {
        /// Keyed by the Int64 bit pattern of the persistent id, the same key the index uses.
        var songs: [Int64: Song]
        var returned: Int
        /// The request itself (§0 measured ≈4.1 s).
        var requestSeconds: Double
        /// Reading the persistent id out of every song's play parameters.
        var keySeconds: Double
    }

    /// Every song in the user's library, cloud-only ones included (one request, §2).
    static func librarySongs() async throws -> Library {
        let started = Date()
        let items = try await withTimeout(30) { () -> [Song] in
            var request = MusicLibraryRequest<Song>()
            request.limit = 50_000
            return Array(try await request.response().items)
        }
        let requested = Date()
        let songs = await keyedByPersistentID(items)
        return Library(songs: songs, returned: items.count,
                       requestSeconds: requested.timeIntervalSince(started),
                       keySeconds: Date().timeIntervalSince(requested))
    }

    /// The key lives inside each song's play parameters and costs a JSON encode to read
    /// (`PersistentIDReader`), so the 15,900 reads are spread across cores.
    @concurrent
    private static func keyedByPersistentID(_ items: [Song]) async -> [Int64: Song] {
        let chunkSize = max(500, items.count / ProcessInfo.processInfo.activeProcessorCount + 1)
        return await withTaskGroup(of: [(Int64, Song)].self) { group in
            for start in stride(from: 0, to: items.count, by: chunkSize) {
                let chunk = Array(items[start..<min(start + chunkSize, items.count)])
                group.addTask {
                    let reader = PersistentIDReader()
                    return chunk.compactMap { song in reader.persistentID(of: song).map { ($0, song) } }
                }
            }
            var songs: [Int64: Song] = [:]
            songs.reserveCapacity(items.count)
            for await part in group {
                for (pid, song) in part { songs[pid] = song }
            }
            return songs
        }
    }

    /// One library song by its MusicKit id: the fast path while the full map is still loading.
    static func librarySong(cloudID: String) async throws -> Song? {
        try await withTimeout(5) {
            var request = MusicLibraryRequest<Song>()
            request.filter(matching: \.id, equalTo: MusicItemID(cloudID))
            request.limit = 1
            return try await request.response().items.first
        }
    }

    /// One library song when the index has no MusicKit id for it yet (first launch, before any
    /// full request finished): narrow by title, then pick the exact persistent id.
    static func librarySong(title: String, persistentID: Int64) async throws -> Song? {
        guard !title.isEmpty else { return nil }
        let candidates = try await withTimeout(5) { () -> [Song] in
            var request = MusicLibraryRequest<Song>()
            request.filter(matching: \.title, contains: title)
            request.limit = 500
            return Array(try await request.response().items)
        }
        let reader = PersistentIDReader()
        return candidates.first { reader.persistentID(of: $0) == persistentID }
    }

    /// Fallback step 3 (§1): the Apple Music catalog item, for rows the library request missed.
    static func catalogSong(storeItemID: Int64) async throws -> Song? {
        try await withTimeout(5) {
            let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(String(storeItemID)))
            return try await request.response().items.first
        }
    }

    static func subscription() async throws -> SubscriptionInfo {
        let current = try await withTimeout(5) { try await MusicSubscription.current }
        return SubscriptionInfo(canPlayCatalogContent: current.canPlayCatalogContent,
                                canBecomeSubscriber: current.canBecomeSubscriber,
                                hasCloudLibraryEnabled: current.hasCloudLibraryEnabled)
    }
}
