import Foundation
import MediaPlayer
import MusicKit

/// OLDTUNES_PLAYBACK_MODE=fixes (also run at the end of the default mode): regression checks for
/// the review's playback findings 3, 5, 7/15 and 17, and for the per-song checkbox.
///
/// Each scenario builds its own coordinator over a PlaybackHarnessLibrary whose Simulation
/// reproduces the failure on demand: missing MusicKit permission, lookups that hang and find
/// nothing, a song MusicKit will not prepare, a tag edit to the playing song. Checks marked
/// "(guard)" cover behavior that already worked and must keep working; the others failed on the
/// coordinator the review ran (commit 14fdd51). The Play-after-Pause check covers the review's side
/// note on finding 7 (a clock tick could swallow a resume).
///
/// Plays mostly the two shortest local files, a few seconds at a time, plus a few cloud songs for
/// the scrub and Pause checks. Never touches the volume.
@MainActor
final class ReviewFixBench {
    private let loaded: PlaybackHarnessLibrary.Loaded
    private let l1: Track, l2: Track
    private(set) var passed = 0
    private(set) var failed = 0
    /// Kept alive for the whole run, like the app's one coordinator.
    private var players: [PlaybackCoordinator] = []
    /// Every change of the now-playing id since the last reset(), across all players.
    private var nowPlayingIDs: [Track.ID?] = []
    private var lastNowPlaying: Track.ID?
    private var titles: [Track.ID: String] = [:]

    init(_ loaded: PlaybackHarnessLibrary.Loaded) {
        self.loaded = loaded
        let locals = loaded.locals.sorted { $0.duration < $1.duration }
        l1 = locals[0]
        l2 = locals[1]
    }

    func runAll() async {
        Log.info("fixes: local \(name(l1)) [\(f(l1.duration)) s], \(name(l2)) [\(f(l2.duration)) s]")
        await uncheckedSongs()
        await editsReachNowPlaying()
        await seekWhileLoading()
        await withoutPermission()
        await pauseEndsSkipRun()
        await pickedSongThatCannotPlay()
        await resumeAfterBusyMainThread()
        for player in players { player.stop() }
        Log.info("FIXES RESULT: \(passed) PASS, \(failed) FAIL")
    }

    // MARK: The per-song checkbox

    /// Unchecked songs are stepped over by next(), previous(), the end of a song and shuffle, but
    /// a double-click still plays one. A list with nothing checked stops and says why.
    private func uncheckedSongs() async {
        Log.info("=== fixes: unchecked songs ===")
        let u1 = copy(l2, id: -101, title: "Harness: unchecked copy A", checked: false)
        let u2 = copy(l1, id: -102, title: "Harness: unchecked copy B", checked: false)
        let u3 = copy(l2, id: -103, title: "Harness: unchecked copy C", checked: false)
        let library = PlaybackHarnessLibrary(tracks: [l1, l2, u1, u2, u3], songs: loaded.songs)
        let player = makePlayer(library)
        let unchecked: Set<Track.ID> = [u1.id, u2.id, u3.id]
        func heardUnchecked() -> Bool { nowPlayingIDs.contains { $0.map(unchecked.contains) ?? false } }

        player.play(queue: [l1.id, u1.id, l2.id], startAt: u1.id)
        let picked = await waitUntil(5) { self.playing(player, u1) }
        check("a double-clicked unchecked song still plays (guard)", picked, line(player))

        player.play(queue: [l1.id, u1.id, l2.id], startAt: l1.id)
        _ = await waitUntil(5) { self.playing(player, self.l1) }
        reset()
        player.next()
        let nextOK = await waitUntil(5) { self.playing(player, self.l2) }
        check("next() skips an unchecked song", nextOK && !heardUnchecked(), changes() + line(player))

        reset()
        player.previous()
        let previousOK = await waitUntil(5) { self.playing(player, self.l1) }
        check("previous() skips an unchecked song", previousOK && !heardUnchecked(), changes() + line(player))

        player.play(queue: [l1.id, u1.id, l2.id], startAt: l1.id)
        _ = await waitUntil(5) { self.playing(player, self.l1) && player.state.duration > 3 }
        reset()
        player.seek(to: player.state.duration - 2)
        let advanced = await waitUntil(8) { self.playing(player, self.l2) }
        try? await Task.sleep(for: .seconds(0.5))
        check("the end of a song skips an unchecked song", advanced && !heardUnchecked() && nowPlayingIDs == [l2.id],
              changes() + line(player))

        // iTunes: previous() on the first song restarts it. Only unchecked songs before it is the same.
        player.play(queue: [u2.id, l2.id], startAt: l2.id)
        _ = await waitUntil(5) { self.playing(player, self.l2) }
        _ = await waitUntil(3) { player.state.position >= 1.5 }
        reset()
        player.previous()
        try? await Task.sleep(for: .seconds(1))
        check("previous() with only unchecked songs before it restarts the song",
              playing(player, l2) && player.state.position < 1.4 && !heardUnchecked(), changes() + line(player))

        player.setShuffle(true)
        var shuffleOK = true
        var rounds: [String] = []
        for _ in 0..<3 {
            player.stop()
            reset()
            player.play(queue: [u1.id, l1.id, u2.id, l2.id, u3.id], startAt: nil)
            _ = await waitUntil(5) { self.audible(player) }
            let first = player.state.nowPlaying?.id
            player.next()
            _ = await waitUntil(5) { player.state.nowPlaying?.id != first && self.audible(player) }
            player.next()
            let ended = await waitUntil(5) { player.state.nowPlaying == nil && !player.state.isPlaying }
            let played = nowPlayingIDs.compactMap { $0 }
            shuffleOK = shuffleOK && ended && !heardUnchecked() && played.count == 2 && Set(played) == [l1.id, l2.id]
            rounds.append("\(names(played)) then \(ended ? "stopped" : "kept going")")
        }
        player.setShuffle(false)
        check("shuffle plays only the checked songs, then stops", shuffleOK, rounds.joined(separator: "; "))

        for mode in [RepeatMode.off, .all] {
            player.setRepeat(mode)
            player.stop()
            reset()
            let t0 = Date()
            player.play(queue: [u1.id, u2.id, u3.id], startAt: nil)
            let stopped = await waitUntil(3) {
                player.state.lastError != nil && player.state.nowPlaying == nil && !player.state.isLoading
            }
            let took = Date().timeIntervalSince(t0)
            try? await Task.sleep(for: .seconds(0.5))
            check("a list with nothing checked stops at once and says why (repeat \(mode))",
                  stopped && took < 1 && !heardUnchecked() && !player.local.isPlaying && !player.state.isPlaying,
                  "after \(f(took)) s " + line(player))
        }
        player.setRepeat(.off)
        player.stop()
    }

    // MARK: Findings 7 and 15

    /// A Get Info save (or a re-ingest) that changes the playing song reaches the LCD's state and
    /// the system's Now Playing at once, without restarting or pausing the audio.
    private func editsReachNowPlaying() async {
        Log.info("=== fixes: editing the playing song's tags ===")
        let library = PlaybackHarnessLibrary(tracks: [l1, l2], songs: loaded.songs)
        let player = makePlayer(library)
        player.play(queue: [l1.id, l2.id], startAt: l1.id)
        guard await waitUntil(5, { self.playing(player, self.l1) }) else {
            check("edits: the song starts", false, line(player))
            return
        }
        try? await Task.sleep(for: .seconds(1))
        let p0 = player.state.position
        library.edit(l1.id) {
            $0.title = "Harness Edited Title"
            $0.artist = "Harness Edited Artist"
        }
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        let updated = await waitUntil(2) { player.state.nowPlaying?.title == "Harness Edited Title" }
        // A restart would put the position back near 0; carrying on puts it past p0.
        try? await Task.sleep(for: .seconds(0.6))
        let p1 = player.state.position
        check("an edit to the playing song reaches state.nowPlaying (the LCD)",
              updated && player.state.nowPlaying?.artist == "Harness Edited Artist", line(player))
        check("an edit to the playing song reaches Now Playing",
              nowPlayingTitle() == "Harness Edited Title" && nowPlayingArtist() == "Harness Edited Artist",
              "title=\(nowPlayingTitle() ?? "nil") artist=\(nowPlayingArtist() ?? "nil")")
        check("an edit to the playing song does not interrupt it (guard)",
              playing(player, l1) && player.local.isPlaying && p1 > p0 + 0.3 && player.state.duration > 0,
              "position \(f(p0)) → \(f(p1)) " + line(player))

        player.playPause()
        _ = await waitUntil(2) { !player.state.isPlaying }
        let paused = player.state.position
        library.edit(l1.id) { $0.title = "Harness Edited Again" }
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        let updatedPaused = await waitUntil(2) { player.state.nowPlaying?.title == "Harness Edited Again" }
        try? await Task.sleep(for: .seconds(0.5))
        check("an edit while paused updates the title and Now Playing, and stays paused",
              updatedPaused && !player.state.isPlaying && !player.local.isPlaying
                && abs(player.state.position - paused) < 0.25 && nowPlayingTitle() == "Harness Edited Again"
                && MPNowPlayingInfoCenter.default().playbackState == .paused,
              "title=\(nowPlayingTitle() ?? "nil") " + line(player))
        player.stop()
        library.clearEdits()
    }

    // MARK: Finding 17, part A

    /// The scrubber is live while a cloud song loads; a drag made then must land when it starts.
    private func seekWhileLoading() async {
        Log.info("=== fixes: scrubbing while a cloud song loads ===")
        guard loaded.clouds.count > 6 else {
            check("scrub while loading: two spare cloud songs", false, "only \(loaded.clouds.count) cloud songs")
            return
        }
        let c = loaded.clouds[5], d = loaded.clouds[6]
        let library = PlaybackHarnessLibrary(tracks: [c, d, l1], songs: loaded.songs)
        let player = makePlayer(library)
        let target = min(60, c.duration / 2)

        // Every position the LCD is sent once the song is playing. MusicKit reports the old
        // playbackTime for a moment after a seek; passing that on flicks the thumb back.
        var shownAfterStart: [TimeInterval] = []
        var sawLoading = false
        let token = player.addObserver { state in
            guard state.nowPlaying?.id == c.id else { return }
            if state.isLoading { sawLoading = true } else if sawLoading { shownAfterStart.append(state.position) }
        }
        player.play(queue: [c.id, l1.id], startAt: c.id)
        let loading = await waitUntil(5, poll: 0.01) { player.state.nowPlaying?.id == c.id && player.state.isLoading }
        player.seek(to: target)
        let held = abs(player.state.position - target) < 0.01
        check("a scrub while loading holds the target on the LCD", loading && held, line(player))
        let started = await waitUntil(20) { self.playing(player, c) }
        try? await Task.sleep(for: .seconds(1.5))
        let position = player.state.position
        let musicKit = ApplicationMusicPlayer.shared.playbackTime
        check("a scrub while loading lands once the song starts",
              loading && started && (target...target + 4).contains(position) && (target...target + 4).contains(musicKit),
              "target \(f(target)), position \(f(position)), MusicKit \(f(musicKit)); " + line(player))
        let lowest = shownAfterStart.min() ?? 0
        check("once it starts, the LCD never shows the song back near 0:00 (guard)",
              started && lowest >= target - 2,
              "lowest position shown \(f(lowest)) of \(shownAfterStart.count) updates, target \(f(target))")
        // The same seek on a song already playing, for comparison.
        shownAfterStart = []
        player.seek(to: target + 40)
        try? await Task.sleep(for: .seconds(1.5))
        let lowestPlaying = shownAfterStart.min() ?? 0
        check("a seek on a playing cloud song never shows the old position again (guard)",
              lowestPlaying >= target + 38,
              "lowest position shown \(f(lowestPlaying)) of \(shownAfterStart.count) updates, target \(f(target + 40))")
        player.removeObserver(token)

        // Guard: the scrub belongs to that song only.
        player.play(queue: [d.id, l1.id], startAt: d.id)
        _ = await waitUntil(5, poll: 0.01) { player.state.nowPlaying?.id == d.id && player.state.isLoading }
        player.seek(to: target)
        player.next()
        let moved = await waitUntil(8) { self.playing(player, self.l1) }
        try? await Task.sleep(for: .seconds(0.5))
        check("a scrub made while loading never carries over to the next song (guard)",
              moved && player.state.position < 2, line(player))
        player.stop()
    }

    // MARK: Finding 3

    /// Without Media & Apple Music permission, a double-clicked cloud song must stop at once with
    /// the real reason, not wait on MusicKit row after row and start a file nobody chose.
    private func withoutPermission() async {
        Log.info("=== fixes: no Media & Apple Music permission ===")
        let clouds = Array(loaded.clouds.prefix(4))
        let library = PlaybackHarnessLibrary(tracks: clouds + [l1, l2], songs: loaded.songs,
                                             simulation: .init(unauthorizedLookupDelay: .seconds(1)))
        let player = makePlayer(library, authorization: .denied)

        reset()
        let t0 = Date()
        player.play(queue: clouds.map(\.id) + [l1.id], startAt: clouds[0].id)
        let stopped = await waitUntil(1.5) {
            player.state.nowPlaying == nil && !player.state.isLoading && player.state.lastError != nil
        }
        let took = Date().timeIntervalSince(t0)
        check("no permission: a double-clicked cloud song stops at once and says why",
              stopped && (player.state.lastError ?? "").contains("Media & Apple Music"),
              "after \(f(took)) s " + line(player))
        let strayFile = await sample(4.5) { player.state.nowPlaying?.id == self.l1.id || player.local.isPlaying }
        check("no permission: nothing else starts later", !strayFile && !nowPlayingIDs.contains(l1.id), changes() + line(player))
        check("no permission: MusicKit is not asked at all", library.lookups == 0, "\(library.lookups) lookups")

        player.play(queue: [l1.id, clouds[0].id, clouds[1].id, l2.id], startAt: l1.id)
        _ = await waitUntil(5) { self.playing(player, self.l1) }
        let asked = library.lookups
        player.seek(to: player.state.duration - 2)
        let reached = await waitUntil(8) { self.playing(player, self.l2) }
        check("no permission: the end of a song passes the cloud songs at once and plays the next file",
              reached && library.lookups == asked && (player.state.lastError ?? "").contains("Media & Apple Music"),
              "\(library.lookups - asked) lookups " + line(player))
        player.stop()
    }

    /// A run of songs that take a while to fail (each lookup hangs 1 s, then finds nothing): Pause
    /// must end it, and nothing may start behind the user's back afterwards.
    private func pauseEndsSkipRun() async {
        Log.info("=== fixes: Pause during a run of unplayable songs ===")
        let slow = (0..<4).map { n -> Track in
            var t = Track.blank(id: -200 - Int64(n))
            t.persistentID = t.id
            t.title = "Harness: lookup hangs, finds nothing #\(n)"
            t.duration = 200
            t.isCloud = true
            return t
        }
        let library = PlaybackHarnessLibrary(
            tracks: slow + [l1], songs: loaded.songs,
            simulation: .init(slowMisses: Dictionary(uniqueKeysWithValues: slow.map { ($0.id, Duration.seconds(1)) })))
        let player = makePlayer(library)
        reset()
        player.play(queue: slow.map(\.id) + [l1.id], startAt: nil)
        try? await Task.sleep(for: .seconds(1.5))
        let wasSkipping = player.state.isLoading
        player.playPause()
        let ended = await waitUntil(0.5) {
            !player.state.isLoading && player.state.nowPlaying == nil && !player.state.isPlaying
        }
        check("Pause during a run of unplayable songs ends it", wasSkipping && ended && player.state.lastError != nil,
              "skipping=\(wasSkipping) " + line(player))
        let strayFile = await sample(5) { player.state.nowPlaying?.id == self.l1.id || player.local.isPlaying }
        check("after that Pause nothing starts later", !strayFile, changes() + line(player))
        player.stop()

        // Pause while the first song loads holds it (as before); its lookup then fails and the run
        // goes on, silently paused. Pressing Play then means play: the run must carry on to the
        // file, not stop. (Worked at 14fdd51; the first version of the Pause fix stopped here.)
        reset()
        player.play(queue: slow.map(\.id) + [l1.id], startAt: nil)
        try? await Task.sleep(for: .seconds(0.3))
        player.playPause()
        let held = !player.state.isPlaying && player.state.isLoading
        _ = await waitUntil(3) { player.state.lastError != nil || player.cursor > 0 }
        try? await Task.sleep(for: .seconds(0.3))
        let midRun = player.state.isLoading && player.cursor > 0
        player.playPause()
        let resumed = await waitUntil(6) { self.playing(player, self.l1) }
        check("Play pressed during a run that was paused while loading carries on to the next playable song (guard)",
              held && midRun && resumed, "held=\(held) midRun=\(midRun) " + changes() + line(player))
        player.stop()

        // A run that has found a song and is loading it: Pause holds that song, paused, as for any
        // song still loading, instead of ending playback. (Same history as the check above.)
        guard let c = loaded.clouds.dropFirst(7).first else { return }
        let library2 = PlaybackHarnessLibrary(
            tracks: [slow[0], c, l1], songs: loaded.songs,
            simulation: .init(slowMisses: [slow[0].id: .seconds(1)]))
        let player2 = makePlayer(library2)
        reset()
        player2.play(queue: [slow[0].id, c.id, l1.id], startAt: nil)
        let foundLoading = await waitUntil(6, poll: 0.005) { player2.state.nowPlaying?.id == c.id && player2.state.isLoading }
        player2.playPause()
        let pausedOnIt = await waitUntil(15) {
            player2.state.nowPlaying?.id == c.id && !player2.state.isLoading && !player2.state.isPlaying
        }
        let silent = !(await sample(1.5) { player2.cloud.isPlaying || player2.local.isPlaying || player2.state.isPlaying })
        check("Pause while a run's found song loads holds that song, paused (guard)",
              foundLoading && pausedOnIt && silent && player2.state.nowPlaying?.id == c.id,
              "found loading=\(foundLoading) " + changes() + line(player2))
        player2.playPause()
        let plays = await waitUntil(8) { self.playing(player2, c) }
        check("Play then starts that song (guard)", plays, line(player2))
        player2.stop()
    }

    // MARK: Finding 5

    /// A double-clicked song that cannot play stops there with a plain reason. The end of a song
    /// and Next still skip such songs, and the reason clears at the next clean start.
    private func pickedSongThatCannotPlay() async {
        Log.info("=== fixes: a double-clicked song that cannot play ===")
        guard loaded.clouds.count > 4 else {
            check("picked song that cannot play: a spare cloud song", false, "only \(loaded.clouds.count) cloud songs")
            return
        }
        var bad = loaded.clouds[4]
        bad.id = -300
        bad.title = "Harness: iCloud can't prepare this one"
        var none = Track.blank(id: -301)
        none.title = "Harness: no file, no iCloud song"
        none.duration = 200
        let l1b = copy(l1, id: -302, title: "Harness: second copy of the shortest file")
        let library = PlaybackHarnessLibrary(tracks: [bad, none, l1, l2, l1b], songs: loaded.songs,
                                             simulation: .init(unpreparable: [bad.id]))
        let player = makePlayer(library)

        reset()
        player.play(queue: [bad.id, l1.id], startAt: bad.id)
        let stopped = await waitUntil(5) {
            player.state.lastError != nil && player.state.nowPlaying == nil && !player.state.isLoading
        }
        let other = await sample(2) { player.state.nowPlaying?.id == self.l1.id || player.local.isPlaying }
        let error = player.state.lastError ?? ""
        check("a double-clicked song MusicKit can't prepare stops there, not on the next song",
              stopped && !other && !player.state.isPlaying, changes() + line(player))
        check("its reason names the song in plain words",
              error.contains(bad.displayTitle) && !error.contains("ErrorDomain") && !error.contains("operation couldn"),
              "lastError=\(error)")
        player.next()
        let after = await waitUntil(5) { self.playing(player, self.l1) }
        check("next() after that failure plays the song after it", after, line(player))

        player.stop()
        reset()
        player.play(queue: [none.id, l1.id], startAt: none.id)
        let stoppedNone = await waitUntil(3) {
            player.state.lastError != nil && player.state.nowPlaying == nil && !player.state.isLoading
        }
        let otherNone = await sample(1.5) { player.state.nowPlaying?.id == self.l1.id || player.local.isPlaying }
        check("a double-clicked song with no file and no iCloud song stops there",
              stoppedNone && !otherNone && (player.state.lastError ?? "").contains(none.displayTitle), line(player))

        player.play(queue: [l1.id, bad.id, l2.id, l1b.id], startAt: l1.id)
        _ = await waitUntil(5) { self.playing(player, self.l1) }
        player.seek(to: player.state.duration - 2)
        let skipped = await waitUntil(8) { self.playing(player, self.l2) }
        check("the end of a song still skips one that can't play (guard)",
              skipped && (player.state.lastError ?? "").contains(bad.displayTitle), line(player))
        player.seek(to: player.state.duration - 2)
        let clean = await waitUntil(8) { self.playing(player, l1b) }
        check("the next clean start clears the old reason", clean && player.state.lastError == nil, line(player))

        player.play(queue: [l1.id, bad.id, l2.id], startAt: l1.id)
        _ = await waitUntil(5) { self.playing(player, self.l1) }
        player.next()
        let nextSkipped = await waitUntil(8) { self.playing(player, self.l2) }
        check("next() onto a song that can't play skips it (guard)",
              nextSkipped && (player.state.lastError ?? "").contains(bad.displayTitle), line(player))
        player.stop()
    }

    // MARK: Play after Pause (review side note on finding 7)

    /// resume() starts the engine from a Task. A clock tick that ran before that Task copied the
    /// paused engine's "not playing" into the state, and the Task then took that for a second
    /// press and dropped the resume: Play after Pause did nothing. A busy main thread (a table
    /// reload, a snapshot) makes the tick overdue, which is how the review hit it.
    private func resumeAfterBusyMainThread() async {
        Log.info("=== fixes: Play after Pause with a clock tick overdue ===")
        let library = PlaybackHarnessLibrary(tracks: [l1, l2], songs: loaded.songs)
        let player = makePlayer(library)
        player.play(queue: [l1.id, l2.id], startAt: l1.id)
        guard await waitUntil(5, { self.playing(player, self.l1) }) else {
            check("Play after Pause: the song starts", false, line(player))
            return
        }
        var dropped = 0
        for _ in 0..<6 {
            // Back to playing first, without a busy main thread, so each round tests one Play press.
            if !player.state.isPlaying { player.playPause() }
            _ = await waitUntil(1) { player.local.isPlaying && player.state.isPlaying }
            player.playPause()
            _ = await waitUntil(1) { !player.local.isPlaying && !player.state.isPlaying }
            try? await Task.sleep(for: .seconds(0.2))
            // Block the main thread past a tick, as a long table reload does.
            Self.blockCurrentThread(0.25)
            player.playPause()
            let resumed = await waitUntil(1) { player.local.isPlaying && player.state.isPlaying }
            if !resumed { dropped += 1 }
        }
        check("Play after Pause resumes even with a clock tick overdue", dropped == 0,
              "\(dropped) of 6 Play presses dropped; " + line(player))
        // From playing: Pause, Play, Pause in one go must end paused, and the Play between them
        // must never reach the engine.
        if !player.state.isPlaying { player.playPause() }
        _ = await waitUntil(1) { player.local.isPlaying && player.state.isPlaying }
        player.playPause()
        player.playPause()
        player.playPause()
        let heard = await sample(0.8) { player.local.isPlaying }
        check("Pause, Play, Pause pressed at once ends paused, silent throughout (guard)",
              !heard && !player.state.isPlaying && !player.local.isPlaying, line(player))
        player.stop()
    }

    // MARK: Helpers

    private static func blockCurrentThread(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

    private func makePlayer(_ library: PlaybackHarnessLibrary,
                            authorization: MusicAuthorization.Status = .authorized) -> PlaybackCoordinator {
        let player = PlaybackCoordinator(library: library, cloud: library, cloudAuthorization: { authorization })
        player.cloud.affectsListeningHistory = false
        let failing = library.unpreparableSongIDs
        if !failing.isEmpty {
            player.cloud.simulatedPrepareFailure = { failing.contains($0.id) ? PlaybackHarnessLibrary.prepareFailure() : nil }
        }
        for track in library.byID.values { titles[track.id] = track.displayTitle }
        _ = player.addObserver { [weak self] state in self?.observe(state) }
        players.append(player)
        return player
    }

    private func observe(_ state: PlaybackState) {
        guard state.nowPlaying?.id != lastNowPlaying else { return }
        lastNowPlaying = state.nowPlaying?.id
        nowPlayingIDs.append(state.nowPlaying?.id)
    }

    private func reset() { nowPlayingIDs = [] }

    private func copy(_ track: Track, id: Track.ID, title: String, checked: Bool = true) -> Track {
        var t = track
        t.id = id
        t.title = title
        t.isChecked = checked
        return t
    }

    /// Started and audible on its own engine.
    private func playing(_ player: PlaybackCoordinator, _ t: Track) -> Bool {
        player.state.nowPlaying?.id == t.id && audible(player)
    }

    private func audible(_ player: PlaybackCoordinator) -> Bool {
        let s = player.state
        return s.isPlaying && !s.isLoading && s.nowPlaying != nil && (player.local.isPlaying || player.cloud.isPlaying)
    }

    private func nowPlayingTitle() -> String? {
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String
    }

    private func nowPlayingArtist() -> String? {
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtist] as? String
    }

    private func waitUntil(_ seconds: Double, poll: Double = 0.05, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .seconds(poll))
        }
        return condition()
    }

    /// True if `condition` held at any 20 ms sample during `seconds`.
    private func sample(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let start = Date()
        var seen = false
        while Date().timeIntervalSince(start) < seconds {
            if condition() { seen = true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return seen
    }

    private func check(_ what: String, _ ok: Bool, _ detail: String = "") {
        if ok { passed += 1 } else { failed += 1 }
        Log.info("\(ok ? "PASS" : "FAIL") fixes: \(what)\(detail.isEmpty ? "" : " — \(detail)")")
    }

    private func line(_ player: PlaybackCoordinator) -> String {
        let s = player.state
        return "now=\(idName(s.nowPlaying?.id)) playing=\(s.isPlaying) loading=\(s.isLoading) "
            + "pos=\(f(s.position))/\(f(s.duration)) local=\(player.local.isPlaying) err=\(s.lastError ?? "nil")"
    }

    private func changes() -> String { "changes \(names(nowPlayingIDs)); " }

    private func names(_ ids: [Track.ID?]) -> String {
        "[" + ids.map(idName).joined(separator: ", ") + "]"
    }

    private func idName(_ id: Track.ID?) -> String {
        guard let id else { return "nil" }
        return titles[id].map { "\u{201C}\($0)\u{201D}" } ?? "\(id)"
    }

    private func name(_ t: Track) -> String { "\u{201C}\(t.displayTitle)\u{201D}" }
    private func f(_ x: Double) -> String { String(format: "%.2f", x) }
}
