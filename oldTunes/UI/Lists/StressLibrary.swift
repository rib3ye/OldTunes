import Foundation

/// HARNESS ONLY. Wraps ListsHarnessLibrary with the misbehaviour a real index can show: calls that
/// are slow and do NOT stop when their task is cancelled, and playlist reads that land out of
/// order. The stress bench uses it to prove the lists never show a stale answer.
actor StressLibrary: LibraryReading {
    let base: ListsHarnessLibrary

    private var idsLatency: [String: Duration] = [:]
    private var tracksLatency: Duration = .zero
    /// When set, ids(for:) takes this long and, if its task is cancelled meanwhile, throws what a
    /// real SQLite read throws when interrupted (not CancellationError). The nonce tags the error
    /// so a check can find exactly its own line in the shared log.
    private var interruptible: (latency: Duration, nonce: String)?
    /// When set, rewrites every ids(for:) answer: a library change that moves or removes songs.
    private var orderEdit: (@Sendable ([Track.ID]) -> [Track.ID])?
    /// Each playlists() call takes the next entry; nil list means "whatever the base returns".
    private var playlistScript: [(latency: Duration, list: [PlaylistInfo]?)] = []

    private(set) var idsCalls = 0
    private(set) var tracksCalls = 0
    /// Search strings in the order their ids(for:) calls RETURNED.
    private(set) var completedSearches: [String] = []

    init(base: ListsHarnessLibrary) { self.base = base }

    func setIDsLatency(_ latency: [String: Duration]) { idsLatency = latency }
    func setTracksLatency(_ latency: Duration) { tracksLatency = latency }
    func setInterruptible(_ mode: (latency: Duration, nonce: String)?) { interruptible = mode }
    func setOrderEdit(_ edit: (@Sendable ([Track.ID]) -> [Track.ID])?) { orderEdit = edit }
    func setPlaylistScript(_ script: [(latency: Duration, list: [PlaylistInfo]?)]) { playlistScript = script }
    func resetCounters() { idsCalls = 0; tracksCalls = 0; completedSearches = [] }

    func ids(for query: TrackQuery) async throws -> [Track.ID] {
        idsCalls += 1
        if let latency = idsLatency[query.search] { await Self.sleepIgnoringCancellation(latency) }
        if let mode = interruptible {
            do { try await Task.sleep(for: mode.latency) } catch {
                throw HarnessInterruptedError(nonce: mode.nonce)
            }
        }
        var ids = try await base.ids(for: query)
        if let orderEdit { ids = orderEdit(ids) }
        completedSearches.append(query.search)
        return ids
    }

    func tracks(ids: [Track.ID]) async throws -> [Track] {
        tracksCalls += 1
        let latency = tracksLatency
        if latency > .zero { await Self.sleepIgnoringCancellation(latency) }
        return try await base.tracks(ids: ids)
    }

    func summary(for ids: [Track.ID]) async throws -> LibrarySummary { try await base.summary(for: ids) }

    func playlists() async throws -> [PlaylistInfo] {
        guard !playlistScript.isEmpty else { return try await base.playlists() }
        let step = playlistScript.removeFirst()
        if step.latency > .zero { await Self.sleepIgnoringCancellation(step.latency) }
        if let list = step.list { return list }
        return try await base.playlists()
    }

    func browserValues(_ field: BrowserField, for query: TrackQuery) async throws -> [String] {
        try await base.browserValues(field, for: query)
    }

    func count() async throws -> Int { try await base.count() }

    /// A detached sleep: cancelling the caller does not shorten it, like a query already
    /// running inside SQLite.
    static func sleepIgnoringCancellation(_ duration: Duration) async {
        await Task.detached { try? await Task.sleep(for: duration) }.value
    }
}

/// HARNESS ONLY. Stands in for GRDB's `DatabaseError` with SQLITE_INTERRUPT (code 9), which is what
/// LibraryIndex.ids(for:) throws when its task is cancelled mid-query (review finding 8).
struct HarnessInterruptedError: Error, CustomStringConvertible {
    let nonce: String
    var description: String { "SQLite error 9: interrupted (harness \(nonce))" }
}

/// HARNESS ONLY. An empty library, for checking what the lists do with nothing to show.
struct EmptyLibrary: LibraryReading {
    func ids(for query: TrackQuery) async throws -> [Track.ID] { [] }
    func tracks(ids: [Track.ID]) async throws -> [Track] { [] }
    func summary(for ids: [Track.ID]) async throws -> LibrarySummary { .empty }
    func playlists() async throws -> [PlaylistInfo] { [] }
    func browserValues(_ field: BrowserField, for query: TrackQuery) async throws -> [String] { [] }
    func count() async throws -> Int { 0 }
}
