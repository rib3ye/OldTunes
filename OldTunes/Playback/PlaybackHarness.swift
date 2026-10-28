import AppKit
import iTunesLibrary
import MediaPlayer
import MusicKit

/// OLDTUNES_HARNESS=playback — test bench for the playback coordinator and transports.
///
/// Runs against Noah's real library through PlaybackHarnessLibrary (read-only), logs one PASS/FAIL line
/// per check, and quits. OLDTUNES_PLAYBACK_MODE=probe runs only the R3 end-of-song probe;
/// =history only logs play counts of the songs the bench plays; =edge runs EdgeBench; =keys runs
/// MediaKeyBench (needs its outside driver); =quit quits mid-stream without stop(); =fixes runs only
/// ReviewFixBench, which the default mode also runs after the main bench; =tap runs AudioTapBench,
/// which reads a cloud and a local song through a Core Audio process tap (asks for System Audio
/// Recording the first time); =ab runs AudioABBench, which records one song from OldTunes and from
/// Music for a side-by-side comparison; =route runs CloudRouteBench, which checks what Sound Check's
/// route does with iCloud songs; =permission runs PermissionBench, which checks SystemAudioProbe and
/// a cheaper permission check against this Mac's real System Audio Recording setting.
/// Cloud plays are kept out of the Music library's play history (affectsListeningHistory).
@MainActor
enum PlaybackHarness {
    static func run() async {
        let mode = ProcessInfo.processInfo.environment["OLDTUNES_PLAYBACK_MODE"] ?? "all"
        Log.info("playback harness: mode=\(mode) auth=\(MusicAuthorization.currentStatus) pid=\(ProcessInfo.processInfo.processIdentifier)")
        if mode == "ab" || mode == "route" || mode == "permission" {
            // Each plays songs from an index of its own, not the harness library, or none.
            if #available(macOS 14.2, *) {
                switch mode {
                case "ab": await AudioABBench.run()
                case "route": await CloudRouteBench.run()
                default: await PermissionBench.run()
                }
            } else {
                Log.error("\(mode): process taps need macOS 14.2")
            }
            Log.flush()
            NSApp.terminate(nil)
            return
        }
        do {
            let loaded = try await PlaybackHarnessLibrary.load(cloudLimit: 30)
            Log.info("playback harness: locals=\(loaded.locals.count) clouds=\(loaded.clouds.count)")
            if mode == "probe" {
                if let first = loaded.clouds.first, let song = loaded.songs[first.id] {
                    _ = await CloudEndProbe.run(song: song, label: "\(first.title) — \(first.artist)")
                }
            } else if mode == "tap" {
                if #available(macOS 14.2, *) {
                    await AudioTapBench.run(loaded)
                } else {
                    Log.error("TAP: process taps need macOS 14.2")
                }
            } else if mode == "history" {
                await logListeningHistory(ids: (loaded.clouds.prefix(4) + loaded.locals).map(\.id))
            } else if mode == "edge" {
                await EdgeBench(loaded).runAll()
            } else if mode == "keys" {
                await MediaKeyBench(loaded).run()
            } else if mode == "window" {
                await MediaKeyBench(loaded).measureWindow()
            } else if mode == "quit" {
                await quitWhileStreaming(loaded)
            } else if mode == "realfail" {
                if let title = ProcessInfo.processInfo.environment["OLDTUNES_PLAYBACK_TITLE"], !title.isEmpty {
                    await pickRealSong(loaded, title: title)
                } else {
                    Log.info("REALFAIL: set OLDTUNES_PLAYBACK_TITLE to the title of the library song to try")
                }
            } else if mode == "fixes" {
                let fixes = ReviewFixBench(loaded)
                await fixes.runAll()
                Log.info("PLAYBACK HARNESS RESULT: \(fixes.passed) PASS, \(fixes.failed) FAIL")
            } else {
                let bench = Bench(loaded)
                await bench.runAll()
                bench.stopAll()
                let fixes = ReviewFixBench(loaded)
                await fixes.runAll()
                Log.info("PLAYBACK HARNESS RESULT: \(bench.passed + fixes.passed) PASS, \(bench.failed + fixes.failed) FAIL")
            }
        } catch {
            Log.error("playback harness: load failed: \(error)")
        }
        Log.flush()
        NSApp.terminate(nil)
    }
}

extension PlaybackHarness {
    private static var quitPlayer: PlaybackCoordinator?

    /// OLDTUNES_PLAYBACK_MODE=quit: quits with a cloud song playing and nobody calling stop(),
    /// as Cmd-Q does. MusicKit renders in its own process, so the question is whether that
    /// process goes quiet when OldTunes goes away. Starts 8 s before the end so that, if it does
    /// not, the song runs out by itself almost at once. The shell watches the audio processes.
    static func quitWhileStreaming(_ loaded: PlaybackHarnessLibrary.Loaded) async {
        guard let track = loaded.clouds.first else { return }
        let library = PlaybackHarnessLibrary(tracks: loaded.clouds, songs: loaded.songs)
        let player = PlaybackCoordinator(library: library, cloud: library)
        // Alive until the process ends, like the app's one coordinator.
        quitPlayer = player
        player.cloud.affectsListeningHistory = false
        player.play(queue: [track.id], startAt: track.id)
        let deadline = Date().addingTimeInterval(20)
        while ApplicationMusicPlayer.shared.state.playbackStatus != .playing, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let lead = Double(ProcessInfo.processInfo.environment["OLDTUNES_QUIT_LEAD"] ?? "") ?? 8
        player.seek(to: max(0, track.duration - lead))
        try? await Task.sleep(for: .seconds(1.5))
        // OLDTUNES_QUIT_STOP_FIRST=1 is the control run: how long the audio process lingers after
        // an ordinary stop().
        if ProcessInfo.processInfo.environment["OLDTUNES_QUIT_STOP_FIRST"] == "1" {
            player.stop()
            Log.info("QUIT: stop() called first")
        }
        Log.info("QUIT: terminating with MusicKit status=\(ApplicationMusicPlayer.shared.state.playbackStatus) at \(String(format: "%.2f", player.state.position)) of \(String(format: "%.2f", track.duration)) s; audio processes \(AudioProcessProbe.processesRunningOutput())")
    }

    /// OLDTUNES_PLAYBACK_MODE=realfail: double-clicks the library song titled OLDTUNES_PLAYBACK_TITLE
    /// (in the review, an uploaded song MusicKit refused to prepare with error 6), with a local
    /// file after it, and logs what happened. Informational: whether MusicKit prepares a given
    /// uploaded song shifts from run to run. A song that does play is stopped after 1 s.
    static func pickRealSong(_ loaded: PlaybackHarnessLibrary.Loaded, title: String) async {
        guard let file = loaded.locals.min(by: { $0.duration < $1.duration }) else { return }
        let found = try? await withTimeout(15) { () -> [Song] in
            var request = MusicLibraryRequest<Song>()
            request.filter(matching: \.title, equalTo: title)
            return Array(try await request.response().items)
        }
        guard let song = found?.first, let pid = PlaybackHarnessLibrary.persistentID(of: song) else {
            Log.info("REALFAIL: no library song titled \u{201C}\(title)\u{201D}")
            return
        }
        var track = Track.blank(id: pid)
        track.persistentID = pid
        track.cloudID = song.id.rawValue
        track.title = song.title
        track.artist = song.artistName
        track.duration = song.duration ?? 0
        track.isCloud = true
        let library = PlaybackHarnessLibrary(tracks: [track, file], songs: [pid: song])
        let player = PlaybackCoordinator(library: library, cloud: library)
        quitPlayer = player
        player.cloud.affectsListeningHistory = false
        var seen: [String] = []
        _ = player.addObserver { state in
            let now = state.nowPlaying?.displayTitle ?? "nil"
            if seen.last != now { seen.append(now) }
        }
        player.play(queue: [track.id, file.id], startAt: track.id)
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline, player.state.isLoading || player.state.nowPlaying == nil && player.state.lastError == nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
        try? await Task.sleep(for: .seconds(1))
        let s = player.state
        Log.info("REALFAIL: \u{201C}\(title)\u{201D} id=\(song.id.rawValue): now=\(s.nowPlaying?.displayTitle ?? "nil") "
                 + "playing=\(s.isPlaying) loading=\(s.isLoading) localPlaying=\(player.local.isPlaying) "
                 + "musicKit=\(ApplicationMusicPlayer.shared.state.playbackStatus) shown=\(seen) err=\(s.lastError ?? "nil")")
        player.stop()
    }

    /// Reads play counts and last-played dates for the songs the bench plays, to confirm the runs
    /// stayed out of the library's listening history.
    static func logListeningHistory(ids: [Track.ID]) async {
        let wanted = Set(ids)
        let lines = await Task.detached { () -> [String] in
            guard let library = try? ITLibrary(apiVersion: "1.0", options: .lazyLoadData) else { return ["ITLibrary failed"] }
            return library.allMediaItems
                .filter { wanted.contains(Int64(bitPattern: $0.persistentID.uint64Value)) }
                .map { "history: \($0.title) playCount=\($0.playCount) lastPlayed=\($0.lastPlayedDate.map { $0.formatted(.iso8601) } ?? "never")" }
        }.value
        lines.forEach { Log.info($0) }
    }
}

/// Records what observers see, so checks are made on the published state, not on internals.
@MainActor
private final class Recorder {
    var notifications = 0
    var offMainThread = 0
    var loadingChanges: [Bool] = []
    var nowPlayingIDs: [Track.ID?] = []
    var last = PlaybackState()

    func observe(_ state: PlaybackState) {
        notifications += 1
        if !Thread.isMainThread { offMainThread += 1 }
        if state.isLoading != last.isLoading { loadingChanges.append(state.isLoading) }
        if state.nowPlaying?.id != last.nowPlaying?.id { nowPlayingIDs.append(state.nowPlaying?.id) }
        last = state
    }

    func reset() {
        loadingChanges = []
        nowPlayingIDs = []
    }
}

@MainActor
private final class Bench {
    let loaded: PlaybackHarnessLibrary.Loaded
    let library: PlaybackHarnessLibrary
    let player: PlaybackCoordinator
    let recorder = Recorder()
    private(set) var passed = 0
    private(set) var failed = 0

    let l1: Track, l2: Track
    let c1: Track, c2: Track, c3: Track, c4: Track
    let noSource: Track, missingFile: Track
    /// A file that exists but is not audio: with no cloud song, and with c4's cloud song.
    let corruptOnly: Track, corruptWithCloud: Track
    /// Why the not-audio file couldn't be written, if it couldn't.
    let fixtureProblem: String?

    init(_ loaded: PlaybackHarnessLibrary.Loaded) {
        self.loaded = loaded
        // The two shortest local files; the others are hour-long DJ mixes.
        let locals = loaded.locals.sorted { $0.duration < $1.duration }
        l1 = locals[0]
        l2 = locals[1]
        c1 = loaded.clouds[0]; c2 = loaded.clouds[1]; c3 = loaded.clouds[2]; c4 = loaded.clouds[3]
        var a = Track.blank(id: -1)
        a.title = "Harness: no file, no cloud song"
        a.duration = 200
        var b = Track.blank(id: -2)
        b.title = "Harness: file deleted, no cloud song"
        b.fileURL = URL(fileURLWithPath: "/private/tmp/oldtunes-harness-does-not-exist.m4a")
        b.bucket = .local
        b.duration = 200
        noSource = a
        missingFile = b
        // The fixture lives in the evidence directory (OLDTUNES_PLAYBACK_FIXTURES), never in ~/Music.
        let fixtures = ProcessInfo.processInfo.environment["OLDTUNES_PLAYBACK_FIXTURES"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let broken = fixtures.appendingPathComponent("broken-not-audio.m4a")
        // Without the file, the corrupt-file checks would test a missing file instead (as in a
        // sandboxed build without the bench exception), so a failed write fails the bench.
        do {
            try Data(repeating: 0x5A, count: 64 * 1024).write(to: broken)
            fixtureProblem = nil
        } catch {
            fixtureProblem = "\(broken.path): \(error.localizedDescription)"
        }
        var c = Track.blank(id: -3)
        c.title = "Harness: corrupt file, no cloud song"
        c.fileURL = broken
        c.bucket = .local
        c.duration = 200
        var d = c4
        d.id = -4
        d.title = "Harness: corrupt file, but in iCloud"
        d.fileURL = broken
        d.bucket = .local
        corruptOnly = c
        corruptWithCloud = d
        library = PlaybackHarnessLibrary(tracks: loaded.locals + loaded.clouds + [a, b, c, d], songs: loaded.songs)
        player = PlaybackCoordinator(library: library, cloud: library)
        player.cloud.affectsListeningHistory = false
        _ = player.addObserver { [recorder] in recorder.observe($0) }
    }

    func runAll() async {
        for t in [l1, l2] { Log.info("bench: local \(name(t)) [\(f(t.duration)) s] \(t.fileURL?.lastPathComponent ?? "")") }
        for t in [c1, c2, c3, c4] { Log.info("bench: cloud \(name(t)) [\(f(t.duration)) s] song=\(loaded.songs[t.id] != nil)") }

        if let song = loaded.songs[c1.id] {
            check("R3 probe saw the end-of-song transition", await CloudEndProbe.run(song: song, label: name(c1)))
        }
        detectorCases()
        await deadlines()
        await localThenCloud()
        await cloudThenLocal()
        await previousRule()
        await replaceAndShuffle()
        await autoAdvanceMatrix()
        await repeatOne()
        await repeatAllAndEnd()
        await unplayable()
        await volume()
        await stopping()
        check("observers never called off the main thread", recorder.offMainThread == 0)
        Log.info("RESULT: \(passed) PASS, \(failed) FAIL; observers notified \(recorder.notifications) times, \(recorder.offMainThread) off the main thread")
    }

    func stopAll() { player.stop() }

    // MARK: Steps

    /// Local song for 3 s, then next() across the local → cloud boundary.
    func localThenCloud() async {
        Log.info("=== local 3 s, then next() local → cloud ===")
        recorder.reset()
        player.play(queue: [l1.id, c1.id, l2.id], startAt: l1.id)
        let started = await waitUntil(5) { self.playing(self.l1) }
        check("local song starts", started, "\(stateLine())")
        let p0 = player.state.position
        let n0 = recorder.notifications
        try? await Task.sleep(for: .seconds(3))
        let p1 = player.state.position
        let rate = Double(recorder.notifications - n0) / 3
        check("local position advances over 3 s", p1 - p0 > 2.5, "\(f(p0)) → \(f(p1))")
        check("observers notified about 10 Hz while playing", rate >= 8 && rate <= 12, "\(f(rate)) per second")
        check("local transport is the one playing", player.local.isPlaying && !player.cloud.isPlaying)
        nowPlayingCheck(l1)
        Log.info("audio output processes during local playback: \(AudioProcessProbe.processesRunningOutput())")

        player.seek(to: 30)
        try? await Task.sleep(for: .seconds(1))
        check("seek on local lands", (30...31.6).contains(player.state.position), "position \(f(player.state.position)) after seek(30) + 1 s")

        recorder.reset()
        let overlap = await watchBoundary("local → cloud") { self.player.next() }
        check("never both engines audible across local → cloud", !overlap)
        let cloudStarted = await waitUntil(20) { self.playing(self.c1) }
        check("next() reaches the cloud song", cloudStarted, stateLine())
        check("isLoading went true then false", recorder.loadingChanges == [true, false], "\(recorder.loadingChanges)")
        let q0 = player.state.position
        try? await Task.sleep(for: .seconds(3))
        let q1 = player.state.position
        check("cloud position advances over 3 s", q1 - q0 > 2.5, "\(f(q0)) → \(f(q1))")
        check("cloud transport is the one playing", player.cloud.isPlaying && !player.local.isPlaying)
        Log.info("audio output processes during cloud playback: \(AudioProcessProbe.processesRunningOutput())")
        nowPlayingCheck(c1)
        check("state.volume shows OldTunes's own volume when a cloud song starts, "
              + (player.cloud.ownsVolume ? "enabled (CloudAudioRoute sets its level)" : "greyed out (System Audio Recording is off)"),
              abs(player.state.volume - player.appVolume) < 0.001 && player.state.isVolumeEnabled == player.cloud.ownsVolume,
              "state \(f(Double(player.state.volume))) OldTunes \(f(Double(player.appVolume))), "
              + "\(player.state.isVolumeEnabled ? "enabled" : "greyed out"), probe \(player.cloud.permission?.rawValue ?? "nothing yet")")

        player.seek(to: 60)
        try? await Task.sleep(for: .seconds(1.5))
        check("seek on cloud lands", (60...62.5).contains(player.state.position), "position \(f(player.state.position)) after seek(60) + 1.5 s")
    }

    /// next() across the cloud → local boundary (continues the queue from localThenCloud).
    func cloudThenLocal() async {
        Log.info("=== next() cloud → local ===")
        let overlap = await watchBoundary("cloud → local") { self.player.next() }
        check("never both engines audible across cloud → local", !overlap)
        let ok = await waitUntil(5) { self.playing(self.l2) }
        check("next() reaches the local song", ok, stateLine())
        let p0 = player.state.position
        try? await Task.sleep(for: .seconds(1.5))
        check("local song plays after the boundary", player.state.position - p0 > 1.0 && player.local.isPlaying, stateLine())
    }

    /// previous(): past 3 s restarts the song; within 3 s goes back one. previousSong(), the Dock
    /// menu's, goes back one past 3 s too.
    func previousRule() async {
        Log.info("=== previous() at 5 s vs at 1 s ===")
        player.seek(to: 5)
        try? await Task.sleep(for: .seconds(0.3))
        player.previous()
        try? await Task.sleep(for: .seconds(0.3))
        check("previous() at 5 s restarts the same song",
              player.state.nowPlaying?.id == l2.id && player.state.position < 1.5, stateLine())
        _ = await waitUntil(3) { self.player.state.position >= 1.0 }
        Log.info("previous() pressed at \(f(player.state.position)) s")
        player.previous()
        let back = await waitUntil(20) { self.playing(self.c1) }
        check("previous() at 1 s goes to the previous song", back, stateLine())

        // Back on l2, past 3 s, where previous() only restarts it.
        player.next()
        _ = await waitUntil(5) { self.playing(self.l2) }
        player.seek(to: 5)
        try? await Task.sleep(for: .seconds(0.3))
        Log.info("previousSong() pressed at \(f(player.state.position)) s")
        player.previousSong()
        let backPast3 = await waitUntil(20) { self.playing(self.c1) }
        check("previousSong() at 5 s goes to the previous song", backPast3, stateLine())
    }

    /// replaceQueue keeps the current song; shuffle pins it first and permutes the rest.
    func replaceAndShuffle() async {
        Log.info("=== replaceQueue and shuffle ===")
        let current = player.state.nowPlaying?.id
        let all = library.order
        let before = player.state.position
        player.replaceQueue(all)
        try? await Task.sleep(for: .seconds(1))
        check("replaceQueue keeps the current song playing",
              player.state.nowPlaying?.id == current && player.state.isPlaying && player.state.position > before,
              "position \(f(before)) → \(f(player.state.position))")
        check("replaceQueue re-finds the cursor by id", player.cursor == all.firstIndex(of: current ?? 0), "cursor \(player.cursor)")

        player.setShuffle(true)
        let shuffled = player.queue
        check("shuffle is a permutation of the queue", shuffled.sorted() == all.sorted(), "\(shuffled.count) of \(all.count)")
        check("shuffle keeps the current song first", shuffled.first == current && player.cursor == 0)
        check("shuffle actually reorders", shuffled != all)
        check("turning shuffle on does not interrupt the song", player.state.nowPlaying?.id == current && player.state.isPlaying)
        // A search narrows the list while shuffling: the shuffle order of what is left must not change.
        let narrowed = all.enumerated().filter { $0.offset % 2 == 0 || $0.element == current }.map(\.element)
        let expected = shuffled.filter { Set(narrowed).contains($0) }
        player.replaceQueue(narrowed)
        check("replaceQueue while shuffling keeps the remaining shuffle order", player.queue == expected
              && player.cursor == expected.firstIndex(of: current ?? 0) && player.state.nowPlaying?.id == current,
              "\(expected.count) songs, cursor \(player.cursor)")
        player.replaceQueue(all)
        check("clearing the search appends the returning songs after the kept order",
              Array(player.queue.prefix(expected.count)) == expected && Set(player.queue) == Set(all) && player.queue.count == all.count)
        player.setShuffle(false)
        check("shuffle off restores the sorted order around the song", player.queue == all && player.cursor == all.firstIndex(of: current ?? 0))

        // Uniformity: with 0 pinned, each of 1...4 should land second about 1/4 of the time.
        var counts = [Int: Int]()
        for _ in 0..<4000 { counts[Shuffle.permutation(of: [0, 1, 2, 3, 4], first: 0)[1], default: 0] += 1 }
        let spread = counts.values.map { abs($0 - 1000) }.max() ?? 0
        check("Fisher–Yates spreads evenly (4000 runs)", counts.keys.sorted() == [1, 2, 3, 4] && spread < 120, "\(counts.sorted { $0.key < $1.key })")
    }

    /// Each pair: seek track 1 near its end; it must advance to track 2 exactly once.
    func autoAdvanceMatrix() async {
        let pairs: [(String, Track, Track)] = [("cloud→cloud", c2, c3), ("cloud→local", c2, l1),
                                               ("local→cloud", l1, c2), ("local→local", l1, l2)]
        for (label, a, b) in pairs {
            Log.info("=== auto-advance \(label): \(name(a)) → \(name(b)) ===")
            player.play(queue: [a.id, b.id, c4.id], startAt: a.id)
            guard await waitUntil(20, { self.playing(a) }) else {
                check("auto-advance \(label): first song starts", false, stateLine())
                continue
            }
            recorder.reset()
            player.seek(to: player.state.duration - 3)
            let finishedAt = Date()
            let advanced = await waitUntil(25) { self.playing(b) }
            let took = Date().timeIntervalSince(finishedAt)
            try? await Task.sleep(for: .seconds(2.5))
            let sequence = recorder.nowPlayingIDs
            let once = sequence == [b.id] && player.state.nowPlaying?.id == b.id && player.state.isPlaying
            check("auto-advance \(label) exactly once", advanced && once,
                  "advanced after \(f(took)) s (3 s of song left); nowPlaying changes \(sequence.map { idName($0) }); now \(stateLine())"
                  + (a.isLocal ? "" : "; cloud reason: \(player.cloud.lastFinishReason)"))
        }
    }

    /// Repeat One replays the same song, for both engines.
    func repeatOne() async {
        for (label, t) in [("cloud", c3), ("local", l2)] {
            Log.info("=== repeat one (\(label)) ===")
            player.setRepeat(.one)
            player.play(queue: [t.id, c4.id], startAt: t.id)
            guard await waitUntil(20, { self.playing(t) }) else {
                check("repeat one (\(label)): song starts", false, stateLine())
                continue
            }
            recorder.reset()
            player.seek(to: player.state.duration - 2)
            let wrapped = await waitUntil(15) { self.player.state.position < 2 && self.player.state.isPlaying }
            try? await Task.sleep(for: .seconds(1.5))
            check("repeat one replays the \(label) song", wrapped && player.state.nowPlaying?.id == t.id
                  && player.state.isPlaying && player.state.position > 0.5 && recorder.nowPlayingIDs.isEmpty, stateLine())
        }
        player.setRepeat(.off)
    }

    /// withTimeout must return at its deadline even when the body ignores cancellation, which is
    /// how a stuck MusicKit XPC call behaves. Support's withTimeout is measured alongside.
    func deadlines() async {
        Log.info("=== timeouts around a body that ignores cancellation for 2 s ===")
        let stubborn: @Sendable () async -> Int = {
            await withCheckedContinuation { c in DispatchQueue.global().asyncAfter(deadline: .now() + 2) { c.resume(returning: 1) } }
        }
        var start = Date()
        var deadlineTimedOut = false
        do { _ = try await withTimeout(0.3) { await stubborn() } } catch { deadlineTimedOut = error is TimeoutError }
        let deadlineTook = Date().timeIntervalSince(start)
        start = Date()
        var supportOutcome = "returned a value"
        do { _ = try await withTimeout(0.3) { await stubborn() } } catch { supportOutcome = "threw \(error)" }
        let supportTook = Date().timeIntervalSince(start)
        check("withTimeout(0.3) returns at the deadline", deadlineTimedOut && deadlineTook < 0.6, "returned after \(f(deadlineTook)) s")
        Log.info("Support withTimeout(0.3) on the same body \(supportOutcome) after \(f(supportTook)) s")
    }

    /// Repeat All wraps both ways; without repeat, next() on the last song stops.
    func repeatAllAndEnd() async {
        Log.info("=== repeat all wraps; end of list stops ===")
        player.setRepeat(.all)
        player.play(queue: [l1.id, l2.id], startAt: l2.id)
        _ = await waitUntil(5) { self.playing(self.l2) }
        player.next()
        let wrapped = await waitUntil(5) { self.playing(self.l1) }
        check("repeat all: next() on the last song wraps to the first", wrapped, stateLine())
        player.previous()
        let back = await waitUntil(5) { self.playing(self.l2) }
        check("repeat all: previous() on the first song wraps to the last", back, stateLine())
        player.setRepeat(.off)
        player.next()
        let stopped = await waitUntil(3) { !self.player.state.isPlaying && self.player.state.nowPlaying == nil }
        check("repeat off: next() on the last song stops", stopped && !player.local.isPlaying, stateLine())
    }

    /// The end-of-song rules on recorded and invented tick sequences, including the watchdog,
    /// which real MusicKit never needed during the runs.
    func detectorCases() {
        Log.info("=== end-of-song detector on synthetic tick sequences ===")
        struct Tick { var t: Double; var status: MusicKit.MusicPlayer.PlaybackStatus; var pos: Double; var pausedByUs = false }
        func ticks(_ from: Double, _ to: Double, every: Double = 0.1, _ make: (Double) -> Tick) -> [Tick] {
            stride(from: from, to: to, by: every).map(make)
        }
        /// Feeds ticks the way CloudTransport does, including its "follow an outside pause" rule
        /// (after MusicKit has been seen playing or 1 s has passed). `followedPause` reports
        /// whether that rule ended up showing the song as paused.
        var followedPause = false
        func fires(_ seq: [Tick], duration: Double, start: Double) -> [(Double, String)] {
            let base = ContinuousClock.now
            func at(_ s: Double) -> ContinuousClock.Instant { base + .milliseconds(Int((s * 1000).rounded())) }
            var d = CloudEndDetector(now: at(0))
            d.restart(at: start, now: at(0))
            var wants = true, mismatch = 0
            var out: [(Double, String)] = []
            followedPause = false
            for tick in seq {
                if tick.pausedByUs { wants = false }
                if let reason = d.evaluate(status: tick.status, position: tick.pos, duration: duration,
                                           now: at(tick.t), pausedByUs: tick.pausedByUs, wantsPlay: wants) {
                    out.append((tick.t, reason))
                    wants = false
                    continue
                }
                if wants, tick.status != .playing, d.sawPlaying || tick.t > 1.0 {
                    mismatch += 1
                    if mismatch >= 5 { wants = false; followedPause = true }
                } else {
                    mismatch = 0
                }
            }
            return out
        }
        func report(_ what: String, _ got: [(Double, String)], expectAt: Double?) {
            let ok = expectAt.map { e in got.count == 1 && abs(got[0].0 - e) < 0.15 } ?? got.isEmpty
            check("detector: \(what)", ok, got.isEmpty ? "no end" : got.map { "fired at +\(f($0.0)) s: \($0.1)" }.joined(separator: "; "))
        }

        // 1. The R3 recording: playing up to 0.04 s before the end, then paused with time reset to 0.
        let dur = 192.89
        var seq = ticks(0, 6.0, every: 0.105) { Tick(t: $0, status: .playing, pos: 186.89 + $0) }
        let resetAt = 6.0
        seq += ticks(resetAt, resetAt + 3) { Tick(t: $0, status: .paused, pos: 0) }
        report("recorded R3 end fires once, on the reset tick", fires(seq, duration: dur, start: 186.89), expectAt: resetAt)
        // 2. The user pauses mid-song and leaves it for five minutes.
        seq = ticks(0, 10) { Tick(t: $0, status: .playing, pos: 90 + $0) }
        seq += ticks(10, 310, every: 0.5) { Tick(t: $0, status: .paused, pos: 100, pausedByUs: true) }
        report("a pause mid-song never ends it", fires(seq, duration: 200, start: 90), expectAt: nil)
        // 3. Something outside OldTunes stops MusicKit mid-song (time resets to 0).
        seq = ticks(0, 10) { Tick(t: $0, status: .playing, pos: 90 + $0) }
        seq += ticks(10, 310, every: 0.1) { Tick(t: $0, status: .stopped, pos: 0) }
        report("an outside stop mid-song never ends it", fires(seq, duration: 200, start: 90), expectAt: nil)
        // 4. MusicKit keeps saying .playing but the time freezes 0.2 s before the end.
        seq = ticks(0, 4.8) { Tick(t: $0, status: .playing, pos: 195 + $0) }
        seq += ticks(4.8, 15) { Tick(t: $0, status: .playing, pos: 199.8) }
        report("watchdog: frozen at the end while .playing", fires(seq, duration: 200, start: 195), expectAt: 4.8 + 0.2 + 3)
        // 5. The main thread is starved for 4.5 s across the end.
        seq = ticks(0, 1) { Tick(t: $0, status: .playing, pos: 195 + $0) }
        seq += [Tick(t: 5.5, status: .paused, pos: 0)] + ticks(5.6, 8) { Tick(t: $0, status: .paused, pos: 0) }
        report("starved ticks: wall clock confirms the end", fires(seq, duration: 200, start: 195), expectAt: 5.5)
        // 6. The real song is 10 s longer than its listed duration.
        seq = ticks(0, 15) { Tick(t: $0, status: .playing, pos: 195 + $0) }
        seq += ticks(15, 18) { Tick(t: $0, status: .paused, pos: 0) }
        report("a song longer than its duration plays out, then ends once", fires(seq, duration: 200, start: 195), expectAt: 15)
        // 7. MusicKit never starts at all: shown paused once it has had a second to start, not
        //    left "playing" at 0:00 until the watchdog (the builder's version gave up at +33 s).
        seq = ticks(0, 40) { Tick(t: $0, status: .paused, pos: 0) }
        let never = fires(seq, duration: 30, start: 0)
        check("detector: a song that never starts is shown paused, not ended", never.isEmpty && followedPause,
              never.isEmpty ? "followed as paused" : never.map { "fired at +\(f($0.0)) s" }.joined())
        // 8. A key reaches MusicKit's own player 0.1 s after it starts (recorded in the verify run:
        //    playing at 0.01 s, paused at 0.04 s, before any 10 Hz tick saw it playing): followed.
        seq = ticks(0, 0.1, every: 0.1) { Tick(t: $0 + 0.12, status: .paused, pos: 0.04) }
        seq += ticks(0.2, 4) { Tick(t: $0, status: .paused, pos: 0) }
        let early = fires(seq, duration: 200, start: 0)
        check("detector: a pause MusicKit took before the clock saw it play is followed", early.isEmpty && followedPause,
              early.isEmpty ? "followed as paused" : early.map { "fired at +\(f($0.0)) s" }.joined())
    }

    /// Songs with no file and no cloud song are skipped with lastError set, and never loop.
    /// These play the list from the top (startAt nil): a double-clicked song that can't play stops
    /// there instead, which ReviewFixBench checks.
    func unplayable() async {
        Log.info("=== unplayable songs ===")
        player.play(queue: [noSource.id, missingFile.id, c2.id], startAt: nil)
        let skipped = await waitUntil(20) { self.playing(self.c2) }
        check("two unplayable songs are skipped to the next playable one", skipped, stateLine())
        check("lastError explains the skip", player.state.lastError != nil, "lastError=\(player.state.lastError ?? "nil")")

        // Fallback chain step 1 → 2: a file that exists but will not decode falls back to iCloud.
        check("the not-audio fixture was written", fixtureProblem == nil, fixtureProblem ?? "")
        recorder.reset()
        player.play(queue: [corruptOnly.id, corruptWithCloud.id], startAt: nil)
        let fellBack = await waitUntil(20) { self.playing(self.corruptWithCloud) }
        // The decode failure's own reason: a missing or a shut file would name something else.
        let reason = player.state.lastError ?? ""
        check("an undecodable file with no cloud song is skipped",
              fellBack && reason.contains("corrupt file, no cloud") && reason.contains("its file could not be opened"),
              "lastError=\(player.state.lastError ?? "nil")")
        check("an undecodable file that is also in iCloud streams from iCloud instead",
              fellBack && player.cloud.isPlaying && !player.local.isPlaying && recorder.loadingChanges.contains(true), stateLine())

        for mode in [RepeatMode.off, .all] {
            player.setRepeat(mode)
            let start = Date()
            player.play(queue: [noSource.id, missingFile.id], startAt: nil)
            let gaveUp = await waitUntil(5) { !self.player.state.isPlaying && !self.player.state.isLoading && self.player.state.nowPlaying == nil }
            try? await Task.sleep(for: .seconds(0.5))
            check("all-unplayable queue stops instead of looping (repeat \(mode))",
                  gaveUp && player.state.nowPlaying == nil && player.state.lastError != nil,
                  "after \(f(Date().timeIntervalSince(start))) s lastError=\(player.state.lastError ?? "nil")")
        }
        player.setRepeat(.off)
    }

    /// Files and cloud songs share OldTunes's own volume; nothing in OldTunes moves the Mac's. An
    /// iCloud song OldTunes can't set the level of (no System Audio Recording, simulated here) greys
    /// the slider out.
    func volume() async {
        Log.info("=== volume ===")
        player.play(queue: [l1.id], startAt: l1.id)
        _ = await waitUntil(5) { self.playing(self.l1) }
        player.setVolume(0.4)
        check("local setVolume sets the AVPlayer volume, slider enabled",
              abs(player.local.volume - 0.4) < 0.001 && player.state.isVolumeEnabled,
              "player \(f(Double(player.local.volume))), \(enabled())")
        player.setVolume(0.75)

        player.play(queue: [c2.id], startAt: c2.id)
        guard await waitUntil(20, { self.playing(self.c2) }) else {
            check("cloud volume: song starts", false, stateLine())
            return
        }
        player.setVolume(0.4)
        let gain = player.cloud.route?.gain ?? -1
        check("cloud setVolume sets OldTunes's own volume and the route's gain, slider enabled",
              abs(player.cloud.volume - 0.4) < 0.001 && abs(gain - 0.4) < 0.001 && player.state.isVolumeEnabled,
              "cloud \(f(Double(player.cloud.volume))) route gain \(f(Double(gain))), \(enabled())")
        player.setVolume(0.75)

        // Without the permission, simulated: the next iCloud song's probe hears nothing.
        player.cloud.simulatesMissingPermission = true
        player.play(queue: [c1.id], startAt: c1.id)
        let started = await waitUntil(20) { self.playing(self.c1) }
        try? await Task.sleep(for: .milliseconds(300))
        check("without System Audio Recording (simulated) an iCloud song makes no route and greys the slider out",
              started && player.cloud.permission == .denied && player.cloud.route?.isRunning != true && !player.state.isVolumeEnabled,
              "probe \(player.cloud.permission?.rawValue ?? "nothing yet"), route \(player.cloud.route?.isRunning == true ? "running" : "not running"), "
              + "\(enabled()); \(stateLine())")
        player.setVolume(0.5)
        check("setVolume then still keeps OldTunes's own volume, for files and later routes",
              abs(player.appVolume - 0.5) < 0.001 && abs(player.local.volume - 0.5) < 0.001 && abs(player.cloud.volume - 0.5) < 0.001,
              "OldTunes \(f(Double(player.appVolume))) local \(f(Double(player.local.volume))) cloud \(f(Double(player.cloud.volume)))")
        player.setVolume(0.75)
        player.play(queue: [l1.id], startAt: l1.id)
        let file = await waitUntil(5) { self.playing(self.l1) }
        check("a file after it enables the slider again", file && player.state.isVolumeEnabled, "\(enabled()); \(stateLine())")

        player.cloud.simulatesMissingPermission = false
        player.play(queue: [c2.id], startAt: c2.id)
        let again = await waitUntil(20) { self.playing(self.c2) }
        try? await Task.sleep(for: .milliseconds(300))
        check("with the permission back, the next iCloud song probes again, routes, and enables the slider",
              again && player.cloud.permission == .granted && player.cloud.route?.isRunning == true && player.state.isVolumeEnabled,
              "probe \(player.cloud.permission?.rawValue ?? "nothing yet"), \(enabled()); \(stateLine())")
    }

    private func enabled() -> String { player.state.isVolumeEnabled ? "slider enabled" : "slider greyed out" }

    func stopping() async {
        Log.info("=== stop() ===")
        player.stop()
        try? await Task.sleep(for: .seconds(0.3))
        let n0 = recorder.notifications
        try? await Task.sleep(for: .seconds(1))
        let s = player.state
        check("stop() silences both engines and clears now playing",
              !player.local.isPlaying && !player.cloud.isPlaying && !s.isPlaying && s.nowPlaying == nil && s.position == 0,
              "musicKit=\(ApplicationMusicPlayer.shared.state.playbackStatus) localRate=\(player.local.isPlaying)")
        check("no notifications after stop()", recorder.notifications == n0)
        let info = MPNowPlayingInfoCenter.default()
        check("Now Playing cleared after stop()", info.nowPlayingInfo == nil && info.playbackState == .stopped)
    }

    // MARK: Helpers

    /// Runs `action` and samples both engines every 20 ms for 12 s. Returns true if both were
    /// audible at once: the local player rate and MusicKit's own status, not our intent flags.
    func watchBoundary(_ label: String, _ action: () -> Void) async -> Bool {
        action()
        var overlap = false
        var lastLine = ""
        let start = Date()
        while Date().timeIntervalSince(start) < 12 {
            let musicKit = ApplicationMusicPlayer.shared.state.playbackStatus == .playing
            let localAudible = player.local.isPlaying
            let line = "local.isPlaying=\(localAudible) cloud.isPlaying=\(player.cloud.isPlaying) musicKitStatus=\(ApplicationMusicPlayer.shared.state.playbackStatus) loading=\(player.state.isLoading) now=\(idName(player.state.nowPlaying?.id))"
            if line != lastLine {
                Log.info("boundary \(label) +\(f(Date().timeIntervalSince(start))) s: \(line)")
                lastLine = line
            }
            if musicKit && localAudible { overlap = true }
            if player.state.isPlaying && !player.state.isLoading && Date().timeIntervalSince(start) > 1.5 { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return overlap
    }

    func nowPlayingCheck(_ track: Track) {
        let center = MPNowPlayingInfoCenter.default()
        let info = center.nowPlayingInfo ?? [:]
        let ok = info[MPMediaItemPropertyTitle] as? String == track.displayTitle
            && info[MPMediaItemPropertyArtist] as? String == track.artist
            && info[MPMediaItemPropertyAlbumTitle] as? String == track.album
            && (info[MPMediaItemPropertyPlaybackDuration] as? Double ?? 0) > 0
            && info[MPNowPlayingInfoPropertyElapsedPlaybackTime] != nil
            && info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1.0
            && center.playbackState == .playing
        let commands = MPRemoteCommandCenter.shared()
        let enabled = [commands.playCommand, commands.pauseCommand, commands.togglePlayPauseCommand,
                       commands.nextTrackCommand, commands.previousTrackCommand].allSatisfy(\.isEnabled)
        check("Now Playing published for \(track.isLocal ? "local" : "cloud") song, commands enabled", ok && enabled,
              "playbackState=\(center.playbackState.rawValue) title=\(info[MPMediaItemPropertyTitle] ?? "nil") elapsed=\(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] ?? "nil") duration=\(info[MPMediaItemPropertyPlaybackDuration] ?? "nil")")
    }

    /// Started and audible. isPlaying alone also covers a song that is still loading, and when
    /// the same song is played again the state already names it before the restart has begun;
    /// a song change pauses the old engine, so a running engine means the new start is done.
    func playing(_ t: Track) -> Bool {
        let s = player.state
        return s.isPlaying && !s.isLoading && s.nowPlaying?.id == t.id && (player.local.isPlaying || player.cloud.isPlaying)
    }

    func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    func check(_ what: String, _ ok: Bool, _ detail: String = "") {
        if ok { passed += 1 } else { failed += 1 }
        Log.info("\(ok ? "PASS" : "FAIL") \(what)\(detail.isEmpty ? "" : " — \(detail)")")
    }

    func stateLine() -> String {
        let s = player.state
        return "now=\(idName(s.nowPlaying?.id)) playing=\(s.isPlaying) loading=\(s.isLoading) pos=\(f(s.position))/\(f(s.duration)) err=\(s.lastError ?? "nil")"
    }

    func idName(_ id: Track.ID?) -> String {
        guard let id else { return "nil" }
        return library.byID[id].map(name) ?? "\(id)"
    }

    func name(_ t: Track) -> String { "\u{201C}\(t.displayTitle)\u{201D}" }
    func f(_ x: Double) -> String { String(format: "%.2f", x) }
}
