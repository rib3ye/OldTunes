import Foundation

/// Harness-only library: a dictionary of tracks that records every `update` call, so the Get
/// Info flows can prove they call `library.update(ids:applying:)` with exactly the songs that
/// saved. Like `LibraryIndex.update`, `update` posts `.libraryDidChange` on main itself
/// (Contracts.swift), so a caller that posts again shows up as a second post.
actor MetadataHarnessLibrary: LibraryReading, LibraryWriting {
    private var rows: [Track.ID: Track]
    private(set) var updates: [(ids: [Track.ID], patch: TagPatch)] = []

    init(_ tracks: [Track]) {
        rows = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func add(_ track: Track) { rows[track.id] = track }
    func updateCount() -> Int { updates.count }
    func lastUpdate() -> (ids: [Track.ID], patch: TagPatch)? { updates.last }
    func track(_ id: Track.ID) -> Track? { rows[id] }

    func ids(for query: TrackQuery) async throws -> [Track.ID] { rows.keys.sorted() }
    func tracks(ids: [Track.ID]) async throws -> [Track] { ids.compactMap { rows[$0] } }
    func summary(for ids: [Track.ID]) async throws -> LibrarySummary { .empty }
    func playlists() async throws -> [PlaylistInfo] { [] }
    func browserValues(_ field: BrowserField, for query: TrackQuery) async throws -> [String] { [] }
    func count() async throws -> Int { rows.count }

    func update(ids: [Track.ID], applying patch: TagPatch) async throws {
        updates.append((ids, patch))
        for id in ids {
            guard var t = rows[id] else { continue }
            if let v = patch.title { t.title = v }
            if let v = patch.artist { t.artist = v }
            if let v = patch.album { t.album = v }
            if let v = patch.albumArtist { t.albumArtist = v }
            if let v = patch.composer { t.composer = v }
            if let v = patch.genre { t.genre = v }
            if let v = patch.grouping { t.grouping = v }
            if let v = patch.comments { t.comments = v }
            if let v = patch.year { t.year = v }
            if let v = patch.trackNumber { t.trackNumber = v }
            if let v = patch.trackCount { t.trackCount = v }
            if let v = patch.discNumber { t.discNumber = v }
            if let v = patch.discCount { t.discCount = v }
            if let v = patch.bpm { t.bpm = v }
            if let v = patch.isCompilation { t.isCompilation = v }
            if patch.artwork != nil { t.hasArtwork = true }
            if patch.removeArtwork { t.hasArtwork = false }
            rows[id] = t
        }
        await MainActor.run { NotificationCenter.default.post(name: .libraryDidChange, object: nil) }
    }
}

/// Stands in for Music.app: records what would have been written and never sends an Apple
/// Event. `answers` is the sequence of permission states to report, last one repeating.
actor RecordingCloudWriter: CloudTagWriting {
    private var answers: [MusicAutomationStatus]
    private(set) var permissionAsks: [Bool] = []
    private(set) var writes: [(hex: String, patch: TagPatch)] = []

    init(answers: [MusicAutomationStatus]) { self.answers = answers }

    func permission(askIfNeeded: Bool) async -> MusicAutomationStatus {
        permissionAsks.append(askIfNeeded)
        return answers.count > 1 ? answers.removeFirst() : (answers.first ?? .granted)
    }

    func apply(_ patch: TagPatch, persistentID: Int64) async throws {
        writes.append((MusicPersistentID.hex(persistentID), patch))
    }

    func name(persistentID: Int64) async throws -> String? { nil }

    func asks() -> [Bool] { permissionAsks }
    func recordedWrites() -> [(hex: String, patch: TagPatch)] { writes }
}

/// Counts PASS/FAIL lines so the run ends with one verdict.
@MainActor
final class HarnessTally {
    private(set) var passed = 0
    private(set) var failed = 0
    private(set) var failures: [String] = []

    func check(_ ok: Bool, _ what: String, detail: @autoclosure () -> String = "") {
        if ok {
            passed += 1
            Log.info("PASS \(what)")
        } else {
            failed += 1
            let d = detail()
            failures.append(what)
            Log.error("FAIL \(what)\(d.isEmpty ? "" : " — \(d)")")
        }
    }
}
