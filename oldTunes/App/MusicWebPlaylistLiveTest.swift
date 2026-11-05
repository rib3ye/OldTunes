import AppKit
import MusicKit

/// OLDTUNES_HARNESS=musicwebplaylists, OLDTUNES_WEBPLAYLIST_MODE=auth|read|write.
/// Read is the default. Write exercises only a new, uniquely named disposable cloud playlist.
/// No Apple Events or Music launch helper is used. Tokens and library contents are never logged.
@MainActor
enum MusicWebPlaylistLiveTest {
    static func run() async {
        defer { Log.flush(); NSApp.terminate(nil) }
        let mode = ProcessInfo.processInfo.environment["OLDTUNES_WEBPLAYLIST_MODE"] ?? "read"
        if mode == "auth" {
            await authenticateOnly()
            return
        }
        guard mode == "read" || mode == "write" else {
            Log.error("musicwebplaylists: FAIL mode must be auth, read, or write; nothing changed")
            return
        }
        let session = Session(writesEnabled: mode == "write")
        await session.run()
    }

    /// Diagnose native authorization independently of the closed-app proof. This mode only
    /// reads cloud resources and does not claim that Music remained closed.
    private static func authenticateOnly() async {
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty
        Log.info("musicwebplaylists: start mode=auth musicRunning=\(running); read-only, no closed-app claim")
        do {
            let client = try await MusicWebPlaylistClient.connect()
            Log.info("musicwebplaylists: native token connection succeeded")
            let playlists = try await client.playlists()
            let songs = try await client.songs(limit: 2)
            Log.info("musicwebplaylists: AUTH PASS playlists=\(playlists.count) songSample=\(songs.count); no writes")
        } catch let error as MusicWebPlaylistClient.Failure {
            Log.error("musicwebplaylists: AUTH FAIL \(error.errorDescription ?? "request failed"); no writes")
        } catch {
            Log.error("musicwebplaylists: AUTH FAIL request cancelled or timed out; details suppressed; no writes")
        }
    }

    private struct Failure: Error {
        let message: String
    }

    @MainActor
    private final class Session {
        private let writesEnabled: Bool
        private let monitor = MusicLaunchMonitor()
        private let originalName = "OldTunes Web Test \(UUID().uuidString)"
        private var renamedName: String { originalName + " Renamed" }
        private var client: MusicWebPlaylistClient?
        private var baselineIDs = Set<String>()
        private var baselineRead = false
        private var ownedIDs = Set<String>()
        private var createAttempted = false
        private var songBefore: MusicWebPlaylistClient.Resource?
        private var results: [(String, Bool)] = []
        private var activeStage = "startup"
        private let started = ContinuousClock.now

        init(writesEnabled: Bool) { self.writesEnabled = writesEnabled }

        func run() async {
            monitor.start()
            defer { monitor.stop() }
            Log.info("musicwebplaylists: start mode=\(writesEnabled ? "write" : "read")")
            do {
                guard !monitor.isRunning else {
                    throw Failure(message: "Music is already running; close it before this test; nothing changed")
                }
                try await exercise()
            } catch {
                record(activeStage, false, safeError(error))
            }
            if writesEnabled {
                await cleanup()
                await verifyOriginalSong(cleanup: true)
            }
            monitor.refresh()
            record("Music stayed closed", !monitor.observedLaunch && !monitor.isRunning,
                   "launchObserved=\(monitor.observedLaunch) runningNow=\(monitor.isRunning)")
            let passed = !results.isEmpty && results.allSatisfy(\.1)
            Log.info("musicwebplaylists: SUMMARY \(passed ? "PASS" : "FAIL") "
                + results.map { "\($0.0)=\($0.1 ? "PASS" : "FAIL")" }.joined(separator: "; ")
                + "; elapsed=\(seconds(since: started))s")
        }

        private func exercise() async throws {
            let connected = try await request("native token connection") { try await MusicWebPlaylistClient.connect() }
            client = connected
            let before = try await request("cloud playlist baseline") { try await connected.playlists() }
            baselineIDs = Set(before.map(\.id))
            baselineRead = true
            guard baselineIDs.count == before.count else {
                throw Failure(message: "playlist baseline contains duplicate IDs; no writes permitted")
            }
            record("cloud reads", true, "playlists=\(before.count)")

            if !writesEnabled, let id = ProcessInfo.processInfo.environment["OLDTUNES_WEBPLAYLIST_INSPECT_ID"] {
                let item = try await request("inspect fixture identity") { try await connected.playlist(id: id) }
                Log.info("musicwebplaylists: inspection listed=\(baselineIDs.contains(id)) resourcePresent=\(item != nil) "
                    + "attributesPresent=\(item?.attributes != nil) namePresent=\(item?.attributes?.name != nil) "
                    + "playParamsPresent=\(item?.attributes?.playParams != nil) editable=\(item?.attributes?.canEdit == true)")
            }

            let songs = try await request("read library songs") { try await connected.songs(limit: 2) }
            Log.info("musicwebplaylists: library song sample count=\(songs.count)")
            try await nativeMapping(cloudIDs: baselineIDs)
            guard writesEnabled else { return }
            guard let candidate = songs.first(where: { $0.type == "library-songs" && $0.id.hasPrefix("i.") }),
                  let originalSong = try await request("snapshot source song", {
                      try await connected.song(id: candidate.id)
                  }) else {
                throw Failure(message: "no existing cloud library song available; no writes made")
            }
            guard originalSong.id == candidate.id && originalSong.type == "library-songs" else {
                throw Failure(message: "source song lookup did not return the expected library identity")
            }
            songBefore = originalSong
            guard !before.contains(where: { $0.attributes?.name == originalName }) else {
                throw Failure(message: "the generated test name already exists; no writes made")
            }

            // Claim the returned ID inside the request, before its post-call Music check can
            // throw. A timeout or malformed success instead triggers exact-name reconciliation.
            let created = try await request("create disposable playlist") {
                self.createAttempted = true
                let created = try await connected.createPlaylist(name: self.originalName)
                try self.claim(created)
                return created
            }
            let id = created.id
            Log.info("musicwebplaylists: owned fixture id=\(id)")
            try await poll("verify created playlist") {
                let item = try await connected.playlist(id: id)
                return item?.id == id && item?.attributes?.name == self.originalName
            }
            let empty = try await request("check new playlist is empty") { try await connected.tracks(playlistID: id) }
            guard empty.isEmpty else { throw Failure(message: "new test playlist unexpectedly contains tracks") }
            record("create", true, "fixture visible and empty")

            try await requireOwned(id)
            try await request("rename disposable playlist") {
                try await connected.renamePlaylist(id: id, name: self.renamedName)
            }
            try await poll("verify rename") {
                try await connected.playlist(id: id)?.attributes?.name == self.renamedName
            }
            record("rename", true, "renamed fixture read back")

            try await requireOwned(id)
            try await request("append existing library song") { try await connected.addSongs(ids: [originalSong.id], to: id) }
            try await poll("verify appended song") {
                let tracks = try await connected.tracks(playlistID: id)
                return tracks.count == 1 && tracks.first?.id == originalSong.id && tracks.first?.type == "library-songs"
            }
            record("append", true, "exactly one matching library song read back")

            try await requireOwned(id)
            try await request("remove song from disposable playlist") {
                try await connected.removeSongs(ids: [originalSong.id], from: id)
            }
            try await poll("verify removed song") { try await connected.tracks(playlistID: id).isEmpty }
            record("remove", true, "fixture tracks empty")
            try await checkOriginalSong(cleanup: false)
            record("source song preserved after removal", true, "original library resource present; name and play parameters match")

            try await deleteOwn(id, cleanup: false)
            record("delete", true, "fixture absent from playlist listing; lookup has no name or edit capability")
        }

        /// MusicKit's opaque play parameters can carry the native persistent ID. Inspect keys
        /// and join coverage only; never print playlist names, play-parameter values or tokens.
        private func nativeMapping(cloudIDs: Set<String>) async throws {
            let playlists = try await request("native playlist identity diagnostic") {
                try await withTimeout(30) {
                    var request = MusicLibraryRequest<Playlist>()
                    request.limit = 50_000
                    return Array(try await request.response().items)
                }
            }
            var keys = Set<String>()
            var parametersCount = 0
            var persistentCount = 0
            var parameterCloudMatches = 0
            let encoder = JSONEncoder()
            for playlist in playlists {
                guard let parameters = playlist.playParameters,
                      let data = try? encoder.encode(parameters),
                      let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                parametersCount += 1
                keys.formUnion(values.keys)
                if let value = values["musicKit_persistentID"],
                   Int64(String(describing: value)) != nil || UInt64(String(describing: value)) != nil {
                    persistentCount += 1
                }
                if let id = values["id"] as? String, cloudIDs.contains(id) { parameterCloudMatches += 1 }
            }
            let directMatches = playlists.filter { cloudIDs.contains($0.id.rawValue) }.count
            // Key names originate in Apple's Codable schema; keep them to ordinary identifiers.
            let safeKeys = keys.filter { $0.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" } }
            record("native ID diagnostic", true,
                   "native=\(playlists.count) cloud=\(cloudIDs.count) directMatches=\(directMatches) "
                    + "playParameters=\(parametersCount) persistentIDs=\(persistentCount) parameterMatches=\(parameterCloudMatches) "
                    + "keys=\(safeKeys.sorted().joined(separator: ","))")
        }

        private func claim(_ resource: MusicWebPlaylistClient.Resource) throws {
            guard baselineRead, resource.type == "library-playlists", resource.id.hasPrefix("p."),
                  !baselineIDs.contains(resource.id),
                  resource.attributes?.name == nil || resource.attributes?.name == originalName else {
                throw Failure(message: "create returned an unexpected identity; cannot claim it for mutation")
            }
            ownedIDs.insert(resource.id)
        }

        /// Every later write requires both this run's ownership and its exact generated name.
        /// The name check also explicitly retains the test prefix before rename or deletion.
        private func requireOwned(_ id: String, cleanup: Bool = false) async throws {
            guard writesEnabled, baselineRead, ownedIDs.contains(id), !baselineIDs.contains(id), let client else {
                throw Failure(message: "refused a write outside this run's fixture allowlist")
            }
            guard let item = try await request("verify fixture ownership", cleanup: cleanup, {
                try await client.playlist(id: id)
            }), item.id == id, item.type == "library-playlists", let name = item.attributes?.name,
                  name.hasPrefix("OldTunes Web Test "), name == originalName || name == renamedName else {
                throw Failure(message: "fixture identity or exact generated name cannot be verified; write refused")
            }
        }

        private func deleteOwn(_ id: String, cleanup: Bool) async throws {
            guard let client else { throw Failure(message: "no connected client for cleanup") }
            try await requireOwned(id, cleanup: cleanup)
            try await request(cleanup ? "cleanup delete fixture" : "delete disposable playlist", cleanup: cleanup) {
                try await client.deletePlaylist(id: id)
            }
            try await verifyDeleted(id, cleanup: cleanup)
        }

        private func verifyDeleted(_ id: String, cleanup: Bool) async throws {
            guard let client else { throw Failure(message: "no connected client for deletion verification") }
            // AMP can keep returning an unnamed placeholder with play parameters after
            // deletion. Require both library membership absence and unresolved metadata,
            // twice, instead of mistaking that placeholder for a still-existing playlist.
            for confirmation in 0..<2 {
                if confirmation > 0 { try await Task.sleep(for: .seconds(1)) }
                try await poll("verify fixture deletion", cleanup: cleanup) {
                    let listed = try await client.playlists().contains { $0.id == id }
                    let item = try await client.playlist(id: id)
                    return !listed && item?.attributes?.name == nil && item?.attributes?.canEdit != true
                }
            }
        }

        private func cleanup() async {
            guard createAttempted, baselineRead, let client else { return }
            do {
                if ownedIDs.isEmpty {
                    // An ambiguous POST may have succeeded. Claim only its exact UUID name
                    // and only when it was absent from the complete pre-run ID snapshot.
                    try await poll("reconcile uncertain create", cleanup: true) {
                        let matches = try await client.playlists().filter {
                            !self.baselineIDs.contains($0.id) && $0.attributes?.name == self.originalName
                        }
                        guard matches.count <= 1 else {
                            throw Failure(message: "more than one exact test-name match; automatic cleanup refused")
                        }
                        if let match = matches.first { try self.claim(match); return true }
                        return false
                    }
                }
                for id in ownedIDs.sorted() { try await cleanupOwn(id, client: client) }
                record("cleanup", true, "all allowlisted fixtures verified absent")
            } catch {
                record("cleanup", false, safeError(error) + "; fixtureIDs=\(ownedIDs.sorted().joined(separator: ","))")
                if ownedIDs.isEmpty {
                    Log.error("musicwebplaylists: uncertain create could not be reconciled; generated fixture name=\(originalName)")
                }
            }
        }

        /// A timed-out DELETE can still have succeeded. Inspect again before another attempt;
        /// a 404 by itself is insufficient until the complete playlist listing also omits it.
        private func cleanupOwn(_ id: String, client: MusicWebPlaylistClient) async throws {
            var lastError: (any Error)?
            for attempt in 1...3 {
                do {
                    let existing = try await request("cleanup inspect fixture", cleanup: true) { try await client.playlist(id: id) }
                    if existing?.attributes?.name != nil { try await deleteOwn(id, cleanup: true) }
                    else { try await verifyDeleted(id, cleanup: true) }
                    return
                } catch {
                    lastError = error
                    Log.info("musicwebplaylists: cleanup attempt=\(attempt) fixtureID=\(id) \(safeError(error))")
                    if attempt < 3 { try await Task.sleep(for: .seconds(2)) }
                }
            }
            throw lastError ?? Failure(message: "fixture cleanup could not be verified")
        }

        private func verifyOriginalSong(cleanup: Bool) async {
            guard songBefore != nil else { return }
            do {
                try await checkOriginalSong(cleanup: cleanup)
                record("source song preserved at finish", true, "original library resource present; name and play parameters match")
            } catch { record("source song preserved at finish", false, safeError(error)) }
        }

        private func checkOriginalSong(cleanup: Bool) async throws {
            guard let before = songBefore, let client else { return }
            let after = try await request("verify source song remains in library", cleanup: cleanup) {
                try await client.song(id: before.id)
            }
            guard let after, after.id == before.id, after.type == before.type,
                  after.attributes?.name == before.attributes?.name,
                  after.attributes?.playParams?.id == before.attributes?.playParams?.id,
                  after.attributes?.playParams?.kind == before.attributes?.playParams?.kind,
                  after.attributes?.playParams?.catalogId == before.attributes?.playParams?.catalogId else {
                throw Failure(message: "original library song could not be verified unchanged; no library-song deletion attempted")
            }
        }

        private func request<T>(_ stage: String, cleanup: Bool = false,
                                _ operation: () async throws -> T) async throws -> T {
            activeStage = stage
            monitor.refresh()
            if !cleanup && (monitor.observedLaunch || monitor.isRunning) {
                throw Failure(message: "Music launched or is running; further test operations stopped")
            }
            let start = ContinuousClock.now
            do {
                let result = try await operation()
                monitor.refresh()
                Log.info("musicwebplaylists: stage=\(stage) elapsed=\(seconds(since: start))s "
                    + "musicRunning=\(monitor.isRunning) launchObserved=\(monitor.observedLaunch)")
                if !cleanup && (monitor.observedLaunch || monitor.isRunning) {
                    throw Failure(message: "Music launched during this step; only fixture cleanup may continue")
                }
                return result
            } catch {
                monitor.refresh()
                Log.info("musicwebplaylists: stage=\(stage) failed elapsed=\(seconds(since: start))s "
                    + "musicRunning=\(monitor.isRunning) launchObserved=\(monitor.observedLaunch)")
                throw error
            }
        }

        private func poll(_ stage: String, cleanup: Bool = false,
                          _ condition: @escaping @MainActor @Sendable () async throws -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            repeat {
                let remaining = ContinuousClock.now.duration(to: deadline).components
                let secondsLeft = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
                guard secondsLeft > 0 else { break }
                // Readback may make multiple paginated requests; bound the entire poll, not
                // just each HTTP call. No network mutation runs inside this timeout wrapper.
                if try await request(stage, cleanup: cleanup, {
                    try await withTimeout(secondsLeft) { try await condition() }
                }) { return }
                if ContinuousClock.now >= deadline { break }
                try await Task.sleep(for: .seconds(1))
            } while ContinuousClock.now < deadline
            throw Failure(message: "readback did not confirm the expected result within 30 seconds")
        }

        private func safeError(_ error: any Error) -> String {
            if let error = error as? Failure { return error.message }
            if let error = error as? MusicWebPlaylistClient.Failure {
                return error.errorDescription ?? "web-player request failed"
            }
            if let error = error as? TimeoutError { return "request timed out after \(Int(error.seconds)) seconds" }
            if error is CancellationError { return "request cancelled" }
            if let error = error as? URLError { return "network request failed (code \(error.code.rawValue))" }
            // Client errors deliberately omit response bodies. Other error payloads can contain
            // account details, URLs or tokens, so their localized descriptions are not logged.
            return "request failed; error details suppressed"
        }

        private func record(_ stage: String, _ passed: Bool, _ detail: String) {
            results.append((stage, passed))
            Log.info("musicwebplaylists: \(passed ? "PASS" : "FAIL") \(stage) — \(detail)")
        }

        private func seconds(since start: ContinuousClock.Instant) -> String {
            let duration = start.duration(to: .now).components
            return String(format: "%.2f", Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
        }
    }

    @MainActor
    private final class MusicLaunchMonitor {
        private var observer: NSObjectProtocol?
        private var startedClosed = false
        private(set) var observedLaunch = false
        private(set) var isRunning = false

        func start() {
            observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
            ) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == "com.apple.Music" else { return }
                MainActor.assumeIsolated { self?.observedLaunch = true }
            }
            refresh()
            startedClosed = !isRunning
        }

        func refresh() {
            isRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty
            if startedClosed && isRunning { observedLaunch = true }
        }

        func stop() {
            if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
            observer = nil
        }
    }
}
