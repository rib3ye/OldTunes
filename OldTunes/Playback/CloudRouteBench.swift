import Foundation
import GRDB
import MusicKit
import VisualizerCore

/// OLDTUNES_PLAYBACK_MODE=route — harness-only: what CloudAudioRoute does with real iCloud
/// songs, played through the app's own index and PlaybackCoordinator (OLDTUNES_DB_PATH, inside a
/// scratchpad folder, as for the ab mode). Logs a PASS or FAIL line per check:
/// - routing plays the song out times its Sound Check gain;
/// - Sound Check off mid-song leaves only OldTunes's volume, and on again brings the gain back;
/// - the first iCloud song finds the System Audio Recording permission on (SystemAudioProbe);
/// - the volume slider sets the level of what the route plays;
/// - routing survives a rebuild, as after a change of output device;
/// - the next song gets its own gain;
/// - a song that opens silent (simulated) stays routed: the probe still hears its tone, so the
///   silence is the song's own;
/// - a route without the permission (simulated, the probe included) gives up and lets the song
///   play directly, greys the slider out, and routes again from the next song once it has heard
///   sound;
/// - the visualizer's tap, made as VisualizerController makes it, takes OldTunes alone while the route
///   plays the song out (so it hears the song once), and RemotePlayerService again while it doesn't.
///
/// Two muted taps keep the run silent and do the measuring: one on OldTunes, which hears what the
/// route plays out, and one on RemotePlayerService, which hears the song as MusicKit renders it.
/// While routing, the first reads the second plus the song's gain. RemotePlayerService is made to
/// exist and tapped before anything plays, so a route that fails can't be heard either. Plays two
/// iCloud songs for about a minute in all, kept out of listening history.
@available(macOS 14.2, *)
@MainActor
enum CloudRouteBench {
    private static var passed = 0
    private static var failed = 0

    static func run() async {
        guard let path = ProcessInfo.processInfo.environment["OLDTUNES_DB_PATH"], path.contains("/scratchpad/") else {
            Log.error("ROUTE: set OLDTUNES_DB_PATH to an index inside a scratchpad folder")
            return
        }
        let index: LibraryIndex
        do {
            index = try LibraryIndex(path: URL(fileURLWithPath: path))
        } catch {
            Log.error("ROUTE: could not open the index at \(path): \(error)")
            return
        }
        let ingest = LibraryIngest(index: index)
        let report = await ingest.refresh()
        guard report.status == .ok, let (quieter, louder) = try? await pickSongs(index) else {
            Log.error("ROUTE: no two iCloud songs with Sound Check values to play (ingest \(report.status))")
            return
        }
        Log.info("ROUTE: songs \(quieter.id) at \(f(SoundCheck.decibels(energy: quieter.soundCheckEnergy))) dB and "
                 + "\(louder.id) at \(f(SoundCheck.decibels(energy: louder.soundCheckEnergy))) dB")

        let me = ProcessInfo.processInfo.processIdentifier
        guard let own = ProcessTap.start(AudioTapBench.ownObject(me), label: "ROUTE OldTunes") else {
            Log.error("ROUTE: no tap on OldTunes")
            return
        }
        defer { own.stop() }
        guard await AudioABBench.toneCheck(own) else { return }
        guard let remote = await tapRemotePlayer(quieter, ingest: ingest) else { return }
        defer { remote.stop() }

        let player = PlaybackCoordinator(library: index, cloud: ingest)
        player.cloud.affectsListeningHistory = false
        player.setVolume(1)
        player.setSoundCheck(true)
        defer {
            player.stop()
            player.setSoundCheck(false)
        }

        // Routing.
        guard await startSong(quieter, in: [quieter, louder], player) else { return }
        check("the first iCloud song finds System Audio Recording on", player.cloud.permission == .granted,
              "probe answered \(player.cloud.permission?.rawValue ?? "nothing yet")")
        await compare("routing plays the song out times its gain", own, remote, gain: quieter, player)
        if let dir = ProcessInfo.processInfo.environment["OLDTUNES_ROUTE_DIR"] {
            await recordBoth(own, remote, seconds: 10, to: URL(fileURLWithPath: dir, isDirectory: true), suffix: "")
        }

        // The visualizer's tap, muted like every tap here.
        let ring = SampleRing()
        let visualizer = VisualizerAudio(ring: ring, player: player, muted: true,
                                         cloudRouted: { [weak player] in player?.cloud.route?.mode == .routing }) { _ in }
        defer { visualizer.stop() }
        visualizer.start()
        _ = await AudioABBench.waitUntil(5) { visualizer.tap.status.isRunning }
        await visualizerTaps("the visualizer's tap takes OldTunes alone while the route plays the song out, and hears it",
                             remotePlayer: false, visualizer, ring, me: me)

        // Off and on in the middle of a song.
        player.setSoundCheck(false)
        try? await Task.sleep(for: .milliseconds(300))
        await compare("Sound Check off mid-song leaves only OldTunes's volume (full)", own, remote, decibels: 0, player)
        player.setSoundCheck(true)
        try? await Task.sleep(for: .milliseconds(300))
        await compare("Sound Check on mid-song brings the song's gain back", own, remote, gain: quieter, player)

        // OldTunes's own volume.
        player.setVolume(0.5)
        try? await Task.sleep(for: .milliseconds(300))
        await compare("the volume slider at 50% takes 6.02 dB more off what the route plays", own, remote,
                      decibels: SoundCheck.decibels(energy: quieter.soundCheckEnergy) + 20 * log10(0.5), player)
        check("and the slider shows it, enabled", player.state.volume == 0.5 && player.state.isVolumeEnabled,
              "slider shows \(f(Double(player.state.volume))), \(player.state.isVolumeEnabled ? "enabled" : "greyed out")")
        player.setVolume(1)

        // As after a change of output device.
        await player.cloud.route?.rebuildAsAfterDeviceChange()
        try? await Task.sleep(for: .milliseconds(300))
        await compare("routing comes back after a rebuild, as after a device change", own, remote, gain: quieter, player)

        // The next song.
        player.next()
        guard await waitForSong(louder, player) else { return }
        player.seek(to: 40)
        try? await Task.sleep(for: .seconds(1))
        await compare("the next song gets its own gain", own, remote, gain: louder, player)
        if let dir = ProcessInfo.processInfo.environment["OLDTUNES_ROUTE_DIR"] {
            await recordBoth(own, remote, seconds: 6, to: URL(fileURLWithPath: dir, isDirectory: true), suffix: "-louder")
        }

        // A song that opens silent, simulated from its start: the tap hears only zeros, the probe
        // its tone.
        player.cloud.route?.simulatesSilentTap = true
        player.play(queue: [quieter.id, louder.id], startAt: quieter.id)
        guard await waitForSong(quieter, player) else { return }
        _ = await AudioABBench.waitUntil(6) { player.cloud.route?.lastSilenceCheck != nil }
        try? await Task.sleep(for: .milliseconds(300))
        check("a song that opens silent stays routed: the probe still hears its tone",
              player.cloud.route?.mode == .routing && player.cloud.route?.lastSilenceCheck == .granted && player.state.isVolumeEnabled,
              "probe \(player.cloud.route?.lastSilenceCheck?.rawValue ?? "never ran") after \(f(player.cloud.position)) s of the song; "
              + AudioABBench.routeStatus(player.cloud))
        player.cloud.route?.simulatesSilentTap = false
        try? await Task.sleep(for: .milliseconds(300))
        await compare("and once the song is heard, it plays out times its gain", own, remote, gain: quieter, player)

        // No permission, simulated from the start of a song: the tap and the probe hear only zeros.
        player.cloud.route?.simulatesMissingPermission = true
        player.play(queue: [quieter.id, louder.id], startAt: quieter.id)
        guard await waitForSong(quieter, player) else { return }
        let gaveUp = await AudioABBench.waitUntil(6) { player.cloud.route?.mode == .listening }
        check("without the permission (simulated) the route gives up and listens", gaveUp && player.cloud.route?.lastSilenceCheck == .denied,
              "probe \(player.cloud.route?.lastSilenceCheck?.rawValue ?? "never ran") after \(f(player.cloud.position)) s of the song; "
              + AudioABBench.routeStatus(player.cloud))
        player.cloud.route?.simulatesMissingPermission = false
        try? await Task.sleep(for: .milliseconds(500))
        await directly("then the song plays straight from RemotePlayerService", own, remote, player)
        check("and the slider greys out, as it must without a route", !player.cloud.ownsVolume && !player.state.isVolumeEnabled,
              "slider \(player.state.isVolumeEnabled ? "enabled" : "greyed out"); \(AudioABBench.routeStatus(player.cloud))")
        _ = await AudioABBench.waitUntil(3) { visualizer.tap.status.remotePlayerTapped }
        await visualizerTaps("and the visualizer's tap takes RemotePlayerService again", remotePlayer: true, visualizer, ring, me: me)

        // It heard the song while listening, so the next song is routed again.
        player.next()
        guard await waitForSong(louder, player) else { return }
        player.seek(to: 40)
        try? await Task.sleep(for: .seconds(1))
        check("having heard sound, the route routes the next song again, with the slider enabled",
              player.cloud.route?.mode == .routing && player.state.isVolumeEnabled,
              "slider \(player.state.isVolumeEnabled ? "enabled" : "greyed out"); \(AudioABBench.routeStatus(player.cloud))")
        await compare("and plays it out times its gain", own, remote, gain: louder, player)
        _ = await AudioABBench.waitUntil(3) { !visualizer.tap.status.remotePlayerTapped }
        await visualizerTaps("and the visualizer's tap leaves RemotePlayerService out again", remotePlayer: false, visualizer, ring, me: me)

        player.stop()
        try? await Task.sleep(for: .milliseconds(400))
        Log.info("ROUTE SUMMARY \(passed) passed, \(failed) failed")
    }

    /// An iCloud song Sound Check makes quieter and one it makes louder, 2 to 7 minutes long, the
    /// first of each by persistent id, so every run plays the same two.
    private static func pickSongs(_ index: LibraryIndex) async throws -> (Track, Track)? {
        let ids = try await index.pool.read { db in
            (try Int64.fetchOne(db, sql: """
                SELECT id FROM song WHERE origin = 0 AND bucket = 1 AND sound_check_energy > 1500
                  AND total_time_ms BETWEEN 120000 AND 420000 ORDER BY persistent_id LIMIT 1
                """),
             try Int64.fetchOne(db, sql: """
                SELECT id FROM song WHERE origin = 0 AND bucket = 1 AND sound_check_energy BETWEEN 400 AND 800
                  AND total_time_ms BETWEEN 120000 AND 420000 ORDER BY persistent_id LIMIT 1
                """))
        }
        guard let a = ids.0, let b = ids.1 else { return nil }
        let tracks = try await index.tracks(ids: [a, b])
        guard tracks.count == 2 else { return nil }
        return (tracks[0], tracks[1])
    }

    /// Makes MusicKit start its RemotePlayerService by preparing the first song, then taps that
    /// service, muted, before anything has played.
    private static func tapRemotePlayer(_ track: Track, ingest: LibraryIngest) async -> ProcessTap? {
        guard let song = await ingest.cloudSong(for: track) else {
            Log.error("ROUTE: MusicKit can't find song \(track.id)")
            return nil
        }
        let player = ApplicationMusicPlayer.shared
        let queue = ApplicationMusicPlayer.Queue(for: [song])
        if #available(macOS 26.4, *) { queue.affectsListeningHistory = false }
        player.queue = queue
        do {
            try await withTimeout(20) { @MainActor in try await ApplicationMusicPlayer.shared.prepareToPlay() }
        } catch {
            Log.error("ROUTE: the first song would not prepare: \(error)")
            return nil
        }
        player.queue = []
        let remotes = AudioTapBench.remotes()
        guard !remotes.isEmpty, let tap = ProcessTap.start(AudioTapBench.ours(remotes), label: "ROUTE RemotePlayerService") else {
            Log.error("ROUTE: no tap on RemotePlayerService (\(remotes.map(AudioTapBench.describe)))")
            return nil
        }
        return tap
    }

    private static func startSong(_ track: Track, in queue: [Track], _ player: PlaybackCoordinator) async -> Bool {
        player.play(queue: queue.map(\.id), startAt: track.id)
        guard await waitForSong(track, player) else { return false }
        player.seek(to: 40)
        try? await Task.sleep(for: .seconds(1))
        return true
    }

    private static func waitForSong(_ track: Track, _ player: PlaybackCoordinator) async -> Bool {
        let started = await AudioABBench.waitUntil(15) {
            player.state.nowPlaying?.id == track.id && player.cloud.isPlaying && !player.state.isLoading && player.cloud.position > 0.3
        }
        if !started { fail("song \(track.id) plays", player.state.lastError ?? "it never started") }
        return started
    }

    private static func compare(_ name: String, _ own: ProcessTap, _ remote: ProcessTap, gain track: Track,
                                _ player: PlaybackCoordinator) async {
        await compare(name, own, remote, decibels: SoundCheck.decibels(energy: track.soundCheckEnergy), player)
    }

    /// Over the same 2 s, what OldTunes plays out against what RemotePlayerService rendered. Within
    /// 0.3 dB: the two taps' windows are not lined up (the route is 25 ms behind), which moves a
    /// lively song's level by up to 0.15 dB. The exact gain comes from ab-analyze on the
    /// OLDTUNES_ROUTE_DIR recordings, which are lined up.
    private static func compare(_ name: String, _ own: ProcessTap, _ remote: ProcessTap, decibels expected: Double,
                                _ player: PlaybackCoordinator) async {
        _ = own.levels.take()
        _ = remote.levels.take()
        try? await Task.sleep(for: .seconds(2))
        let out = db(own.levels.take()), rendered = db(remote.levels.take())
        check(name, rendered > -60 && abs(out - rendered - expected) < 0.3,
              "OldTunes \(f(out)) dBFS, RemotePlayerService \(f(rendered)) dBFS: \(f(out - rendered)) dB, "
              + "expected \(f(expected)) dB; \(AudioABBench.routeStatus(player.cloud))")
    }

    /// What the visualizer's tap holds: OldTunes, plus our RemotePlayerService when `remotePlayer`; and
    /// that it hears the song.
    private static func visualizerTaps(_ name: String, remotePlayer: Bool, _ visualizer: VisualizerAudio, _ ring: SampleRing,
                                       me: pid_t) async {
        let before = ring.stats.nonZeroFrames
        try? await Task.sleep(for: .seconds(1))
        let tapped = visualizer.tap.status.tapped
        let heard = ring.stats.nonZeroFrames - before
        check(name, tapped.contains { $0.pid == me } && tapped.count == (remotePlayer ? 2 : 1)
              && visualizer.tap.status.remotePlayerTapped == remotePlayer && heard > 0,
              "tapped \(tapped), \(heard) non-zero frames in 1 s")
    }

    /// OLDTUNES_ROUTE_DIR: what RemotePlayerService rendered (rendered.wav) and what the route played
    /// out (played.wav) over the same seconds, for ab-analyze. The second should be the first times
    /// the gain and nothing else.
    private static func recordBoth(_ own: ProcessTap, _ remote: ProcessTap, seconds: Double, to dir: URL, suffix: String) async {
        own.recording.start(frames: Int(seconds * own.sampleRate))
        remote.recording.start(frames: Int(seconds * remote.sampleRate))
        try? await Task.sleep(for: .seconds(seconds + 0.3))
        for (name, tap) in [("played", own), ("rendered", remote)] {
            let (samples, channels) = tap.recording.finish()
            let url = dir.appendingPathComponent("\(name)\(suffix).wav")
            do {
                guard channels > 0 else { throw TapError(step: "recording", status: 0) }
                try AudioABBench.write(AudioABBench.Take(samples: samples, channels: channels, rate: tap.sampleRate), to: url)
                Log.info("ROUTE: \(samples.count / channels) frames → \(url.path)")
            } catch {
                Log.error("ROUTE: couldn't record \(name): \(error)")
            }
        }
    }

    /// OldTunes plays out nothing, and RemotePlayerService has the song: it is playing directly.
    private static func directly(_ name: String, _ own: ProcessTap, _ remote: ProcessTap, _ player: PlaybackCoordinator) async {
        _ = own.levels.take()
        _ = remote.levels.take()
        try? await Task.sleep(for: .seconds(1))
        let out = db(own.levels.take()), rendered = db(remote.levels.take())
        check(name, out < -100 && rendered > -60,
              "OldTunes \(f(out)) dBFS, RemotePlayerService \(f(rendered)) dBFS; \(AudioABBench.routeStatus(player.cloud))")
    }

    private static func db(_ window: TapLevels.Window) -> Double {
        window.samples > 0 && window.sumSquares > 0 ? 10 * log10(window.sumSquares / Double(window.samples)) : -.infinity
    }

    private static func check(_ name: String, _ ok: Bool, _ detail: String) {
        if ok {
            passed += 1
            Log.info("ROUTE PASS \(name): \(detail)")
        } else {
            fail(name, detail)
        }
    }

    private static func fail(_ name: String, _ detail: String) {
        failed += 1
        Log.error("ROUTE FAIL \(name): \(detail)")
    }

    private static func f(_ x: Double) -> String { String(format: "%.2f", x) }
}
