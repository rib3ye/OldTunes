import Foundation
import MusicKit

/// OLDTUNES_PLAYBACK_MODE=edge — the independent verifier's bench. Where the main bench walks the
/// happy paths, this one tries to break the coordinator the way a user's hands would: clicks that
/// land while a cloud song is still loading, key presses in bursts, scrubbing to the very end,
/// searches typed mid-load, and lists far larger than the 35 songs the main bench uses.
///
/// Checks read the engines themselves (AVPlayer rate, MusicKit's own status), not the
/// coordinator's flags, so a flag that lies cannot make a check pass.
@MainActor
final class EdgeBench {
    private let library: PlaybackHarnessLibrary
    private let player: PlaybackCoordinator
    private let l1: Track, l2: Track
    private let c1: Track, c2: Track, c3: Track, c4: Track
    /// Rows like a cloud song with Sync Library turned off: no file and no MusicKit song.
    private let offline: [Track]
    private var passed = 0
    private var failed = 0
    private var notifications = 0
    private var nowPlayingChanges: [Track.ID?] = []
    private var lastNowPlaying: Track.ID?

    init(_ loaded: PlaybackHarnessLibrary.Loaded) {
        let locals = loaded.locals.sorted { $0.duration < $1.duration }
        l1 = locals[0]; l2 = locals[1]
        c1 = loaded.clouds[0]; c2 = loaded.clouds[1]; c3 = loaded.clouds[2]; c4 = loaded.clouds[3]
        offline = (0..<15_900).map { n in
            var t = Track.blank(id: 9_000_000_000 + Int64(n))
            t.persistentID = t.id
            t.title = "Harness: iCloud row with Sync Library off #\(n)"
            t.duration = 200
            t.bucket = .cloud
            t.isCloud = true
            return t
        }
        library = PlaybackHarnessLibrary(tracks: loaded.locals + loaded.clouds + offline, songs: loaded.songs)
        player = PlaybackCoordinator(library: library, cloud: library)
        player.cloud.affectsListeningHistory = false
        _ = player.addObserver { [weak self] state in
            guard let self else { return }
            self.notifications += 1
            if state.nowPlaying?.id != self.lastNowPlaying {
                self.lastNowPlaying = state.nowPlaying?.id
                self.nowPlayingChanges.append(state.nowPlaying?.id)
            }
        }
    }

    func runAll() async {
        // OLDTUNES_EDGE_ONLY=stop,toggle runs a subset while chasing one bug.
        let only = Set((ProcessInfo.processInfo.environment["OLDTUNES_EDGE_ONLY"] ?? "")
            .split(separator: ",").map(String.init))
        let steps: [(String, () async -> Void)] = [
            ("clicksCloud", rapidClicksEndOnCloud), ("clicksLocal", rapidClicksEndOnLocal),
            ("stop", stopWhileLoading), ("nextTwice", twoNextsInOneTurn), ("resort", resortInTheSameTurnAsPlay),
            ("pauseLoading", pauseWhileLoading), ("toggle", toggleBursts), ("pausedSeek", seekWhilePausedThenResume),
            ("seekEnd", seekToTheEnd), ("emptyShuffle", emptyQueueWhileShuffling), ("big", { self.bigQueues() }),
            ("unplayable", longRunOfUnplayableRows),
        ]
        for (name, step) in steps where only.isEmpty || only.contains(name) {
            await step()
        }
        player.stop()
        Log.info("EDGE RESULT: \(passed) PASS, \(failed) FAIL")
    }

    // MARK: Clicks that land while a song is loading

    /// Four double-clicks 80 ms apart, the last on a cloud song: only that song may be heard.
    private func rapidClicksEndOnCloud() async {
        Log.info("=== edge: four double-clicks 80 ms apart, ending on a cloud song ===")
        let q = [c1.id, c2.id, l1.id, c3.id]
        for (i, id) in q.enumerated() {
            player.play(queue: q, startAt: id)
            if i < q.count - 1 { try? await Task.sleep(for: .milliseconds(80)) }
        }
        let ok = await waitUntil(20) { self.started(self.c3) }
        let localHeard = await sample(3) { self.player.local.isPlaying }
        check("rapid clicks end on the last click's cloud song, local engine silent", ok && !localHeard
              && musicKitPlaying, stateLine())
    }

    /// Clicks on two cloud songs, then a local song 400 ms later. A MusicKit play() still in
    /// flight from an abandoned click must not start the cloud engine behind the local song.
    private func rapidClicksEndOnLocal() async {
        Log.info("=== edge: cloud, cloud, then local 400 ms later ===")
        let q = [c1.id, c2.id, l1.id]
        player.play(queue: q, startAt: c1.id)
        try? await Task.sleep(for: .milliseconds(80))
        player.play(queue: q, startAt: c2.id)
        try? await Task.sleep(for: .milliseconds(400))
        player.play(queue: q, startAt: l1.id)
        let ok = await waitUntil(10) { self.started(self.l1) }
        try? await Task.sleep(for: .milliseconds(300))
        let cloudHeard = await sample(4) { self.musicKitPlaying }
        check("an abandoned cloud start never plays behind the local song", ok && !cloudHeard
              && player.local.isPlaying, stateLine())
    }

    private func stopWhileLoading() async {
        Log.info("=== edge: stop() 150 ms into a cloud load ===")
        player.play(queue: [c2.id], startAt: c2.id)
        try? await Task.sleep(for: .milliseconds(150))
        Log.info("edge: calling stop() with \(stateLine())")
        player.stop()
        // MusicKit's status lags a stop() by a few tens of ms; what matters is a late start.
        try? await Task.sleep(for: .milliseconds(300))
        let cloudHeard = await sample(4) { self.musicKitPlaying }
        let s = player.state
        check("stop() during a cloud load: nothing plays and the state stays stopped",
              !cloudHeard && !s.isPlaying && !s.isLoading && s.nowPlaying == nil && !player.local.isPlaying, stateLine())
    }

    /// Two next() calls before the first song change has started must skip two songs.
    private func twoNextsInOneTurn() async {
        Log.info("=== edge: next() twice in one turn ===")
        player.play(queue: [l1.id, l2.id, c1.id, c2.id], startAt: l1.id)
        _ = await waitUntil(5) { self.started(self.l1) }
        player.next()
        player.next()
        let ok = await waitUntil(20) { self.started(self.c1) }
        check("next() twice skips two songs", ok, stateLine())
    }

    /// The list is re-sorted in the same turn as a double-click: the clicked song must play.
    private func resortInTheSameTurnAsPlay() async {
        Log.info("=== edge: re-sort in the same turn as a double-click ===")
        player.play(queue: [l1.id, l2.id, c1.id], startAt: l2.id)
        player.replaceQueue([l2.id, c1.id, l1.id])
        let ok = await waitUntil(10) { self.started(self.l2) }
        check("the double-clicked song plays despite a same-turn re-sort", ok && player.cursor == 0,
              "cursor \(player.cursor) " + stateLine())
    }

    // MARK: Play/pause

    /// Space (or the play/pause key) pressed while a cloud song is still loading must keep it
    /// from starting, and a second press must start it.
    private func pauseWhileLoading() async {
        Log.info("=== edge: play/pause pressed while a cloud song loads ===")
        player.play(queue: [c3.id, c4.id], startAt: c3.id)
        try? await Task.sleep(for: .milliseconds(30))
        let wasLoading = player.state.isLoading || player.state.nowPlaying?.id != c3.id
        player.playPause()
        try? await Task.sleep(for: .seconds(5))
        let stayedQuiet = !musicKitPlaying && !player.state.isPlaying && player.state.nowPlaying?.id == c3.id
            && !player.state.isLoading
        check("pause pressed during a cloud load keeps the song from starting", wasLoading && stayedQuiet, stateLine())
        player.playPause()
        let resumed = await waitUntil(10) { self.started(self.c3) }
        check("a second press starts the loaded song", resumed, stateLine())
    }

    /// Bursts of play/pause on a cloud song: the end state must match the number of presses,
    /// in the coordinator and in MusicKit, and must stay that way.
    private func toggleBursts() async {
        Log.info("=== edge: play/pause bursts on a cloud song ===")
        if !started(c3) {
            player.play(queue: [c3.id, c4.id], startAt: c3.id)
            _ = await waitUntil(20) { self.started(self.c3) }
        }
        try? await Task.sleep(for: .seconds(1))
        player.playPause(); player.playPause()
        try? await Task.sleep(for: .seconds(2.5))
        check("two quick presses leave it playing", player.state.isPlaying && musicKitPlaying, stateLine())
        player.playPause(); player.playPause(); player.playPause()
        try? await Task.sleep(for: .seconds(2.5))
        check("three quick presses leave it paused", !player.state.isPlaying && !musicKitPlaying, stateLine())
        // Play, then pause 40 ms later, while MusicKit's play() is still on its way.
        player.playPause()
        try? await Task.sleep(for: .milliseconds(40))
        player.playPause()
        try? await Task.sleep(for: .seconds(2.5))
        check("pause landing while MusicKit is still starting leaves it paused",
              !player.state.isPlaying && !musicKitPlaying, stateLine())
    }

    private func seekWhilePausedThenResume() async {
        Log.info("=== edge: seek a paused cloud song, then resume ===")
        player.seek(to: 100)
        try? await Task.sleep(for: .seconds(0.8))
        let parked = abs(player.state.position - 100) < 0.6 && !player.state.isPlaying && !musicKitPlaying
        check("seek while paused moves the position and stays paused", parked, stateLine())
        player.playPause()
        try? await Task.sleep(for: .seconds(2))
        check("resume after a paused seek plays from there", (100.5...102.6).contains(player.state.position)
              && musicKitPlaying, stateLine())
    }

    /// Dragging the scrubber all the way right. iTunes moved on at once.
    private func seekToTheEnd() async {
        for (label, a, b) in [("cloud", c1, c2), ("local", l1, l2)] {
            Log.info("=== edge: seek to the very end of a \(label) song ===")
            player.play(queue: [a.id, b.id, c4.id], startAt: a.id)
            guard await waitUntil(20, { self.started(a) }) else {
                check("seek to end (\(label)): song starts", false, stateLine())
                continue
            }
            nowPlayingChanges = []
            let t0 = Date()
            player.seek(to: player.state.duration)
            let advanced = await waitUntil(15) { self.started(b) }
            let took = Date().timeIntervalSince(t0)
            try? await Task.sleep(for: .seconds(2))
            check("seek to the end of a \(label) song advances once, promptly",
                  advanced && took < 2.5 && nowPlayingChanges == [b.id],
                  "after \(f(took)) s; changes \(nowPlayingChanges.map { idName($0) }); " + stateLine())
        }
    }

    // MARK: Queues

    private func emptyQueueWhileShuffling() async {
        Log.info("=== edge: play(queue: []) while shuffling, then next() ===")
        player.setShuffle(true)
        player.play(queue: [l1.id, l2.id], startAt: l1.id)
        _ = await waitUntil(5) { self.started(self.l1) }
        player.play(queue: [], startAt: nil)
        player.next()
        player.playPause()
        try? await Task.sleep(for: .seconds(1.5))
        check("an emptied queue stays empty while shuffling", player.state.nowPlaying == nil && !player.state.isPlaying
              && !player.local.isPlaying && player.queue.isEmpty, "queue \(player.queue.count) " + stateLine())
        player.setShuffle(false)
    }

    /// Sorting and searching call replaceQueue per keystroke; 50,000 ids is three times this library.
    private func bigQueues() {
        Log.info("=== edge: 50,000-id queues ===")
        let big = (0..<50_000).map { Int64(8_000_000_000 + $0) }
        var timings: [String] = []
        func time(_ label: String, _ body: () -> Void) {
            let t0 = ContinuousClock.now
            body()
            let ms = (ContinuousClock.now - t0) / .milliseconds(1)
            timings.append("\(label) \(f(ms)) ms")
        }
        player.stop()
        player.setShuffle(false)
        time("replaceQueue") { player.replaceQueue(big) }
        time("setShuffle(on)") { player.setShuffle(true) }
        time("replaceQueue narrowed") { player.replaceQueue(big.filter { $0 % 3 == 0 }) }
        time("replaceQueue cleared") { player.replaceQueue(big) }
        let permutation = Set(player.queue).count == big.count && player.queue.count == big.count
        time("setShuffle(off)") { player.setShuffle(false) }
        let worst = timings.compactMap { Double($0.split(separator: " ").dropLast().last ?? "") }.max() ?? 0
        check("50,000-id queue operations stay under 50 ms each", worst < 50 && permutation, timings.joined(separator: ", "))
        player.replaceQueue([])
    }

    /// Sync Library off: every iCloud row is unplayable and only the files on this Mac play.
    /// Playing the list from the top (Play with nothing selected) must reach the file at the end
    /// of 15,900 such rows without hanging, and without flooding observers. A double-click on one
    /// of them stops right there with the reason instead.
    private func longRunOfUnplayableRows() async {
        Log.info("=== edge: 15,900 unplayable iCloud rows before one file ===")
        let q = offline.map(\.id) + [l2.id]
        player.play(queue: q, startAt: q[0])
        let stoppedAtPick = await waitUntil(2) { self.player.state.nowPlaying == nil && self.player.state.lastError != nil }
        let reachedFile = await sample(1) { self.player.state.nowPlaying?.id == self.l2.id }
        check("a double-click on an unplayable row stops there with a reason", stoppedAtPick && !reachedFile, stateLine())
        let n0 = notifications
        let t0 = Date()
        player.play(queue: q, startAt: nil)
        let reached = await waitUntil(120) { self.started(self.l2) }
        let took = Date().timeIntervalSince(t0)
        let sent = notifications - n0
        check("a run of 15,900 unplayable rows reaches the playable file", reached, "after \(f(took)) s, \(sent) notifications; " + stateLine())
        // Where the time goes: one deadline-guarded resolver call per row is the floor.
        let t1 = Date()
        for _ in 0..<2_000 { _ = try? await withTimeout(10) { () -> Int? in nil } }
        Log.info("edge: 2,000 withTimeout round trips from the main actor took \(f(Date().timeIntervalSince(t1))) s")
        check("skipping 15,900 unplayable rows takes under 2 s", reached && took < 2, "\(f(took)) s")
        player.stop()
    }

    // MARK: Helpers

    private var musicKitPlaying: Bool { ApplicationMusicPlayer.shared.state.playbackStatus == .playing }

    /// Audible on the right engine, per the engines themselves.
    private func started(_ t: Track) -> Bool {
        let s = player.state
        guard s.nowPlaying?.id == t.id, s.isPlaying, !s.isLoading else { return false }
        return t.isLocal ? player.local.isPlaying : musicKitPlaying
    }

    /// True if `condition` held at any 20 ms sample during `seconds`. Logs the first sample where
    /// it held, so a failure says when.
    private func sample(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let start = Date()
        var seen = false
        while Date().timeIntervalSince(start) < seconds {
            if condition(), !seen {
                seen = true
                Log.info("edge sample: condition held at +\(f(Date().timeIntervalSince(start))) s: \(stateLine())")
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return seen
    }

    private func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private func check(_ what: String, _ ok: Bool, _ detail: String = "") {
        if ok { passed += 1 } else { failed += 1 }
        Log.info("\(ok ? "PASS" : "FAIL") edge: \(what)\(detail.isEmpty ? "" : " — \(detail)")")
    }

    private func stateLine() -> String {
        let s = player.state
        return "now=\(idName(s.nowPlaying?.id)) playing=\(s.isPlaying) loading=\(s.isLoading) pos=\(f(s.position))/\(f(s.duration)) "
            + "local=\(player.local.isPlaying) musicKit=\(ApplicationMusicPlayer.shared.state.playbackStatus) err=\(s.lastError ?? "nil")"
    }

    private func idName(_ id: Track.ID?) -> String {
        guard let id else { return "nil" }
        return library.byID[id].map { "\u{201C}\($0.displayTitle)\u{201D}" } ?? "\(id)"
    }

    private func f(_ x: Double) -> String { String(format: "%.2f", x) }
}
