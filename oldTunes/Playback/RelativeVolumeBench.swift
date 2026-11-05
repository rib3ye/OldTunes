import AudioToolbox
import CoreAudio
import Foundation
import GRDB
import MusicKit

/// OLDTUNES_PLAYBACK_MODE=relvol — harness-only: what CloudVolume does to the sound of iCloud songs.
///
/// CloudVolume sets the level RemotePlayerService plays iCloud songs at with MusicKit's private
/// `-[MPMusicPlayerApplicationController setRelativeVolume:]`, so oldTunes has its volume and Sound
/// Check on them without listening to them. The bench measures the level in RemotePlayerService
/// with a muted process tap, which needs System Audio Recording; what it tests doesn't. Silent.
///
/// 1. The call: one iCloud song at 1, 0.5, 0.25, 0.1, 0 and 1 again, then through a pause, then into
///    a second song, with the Mac's own volume read before and after (it must not move).
/// 2. oldTunes's path: a CloudTransport plays an iCloud song Sound Check turns down and one it would
///    turn up, with Sound Check off and on and the volume at full and at half. The level follows
///    oldTunes's volume times the song's gain, capped at full (a file's boost isn't: LocalSoundCheck).
///
/// Songs come from an index of its own (OLDTUNES_DB_PATH, inside a scratchpad folder, as for the ab
/// mode) and are kept out of listening history. Every measurement seeks back to 40 s and reads the
/// same 3 s of the song by its own clock, so the song's changes in loudness cancel out. First
/// measured on November 4, 2026: 0.5 → −6.03 dB, 0.25 → −12.05, 0.1 → −20.00, 0 silent, 2 the
/// same as 1 (the call never boosts), and the level held through a pause and into the next song.
@available(macOS 14.2, *)
@MainActor
enum RelativeVolumeBench {
    private static var passed = 0
    private static var failed = 0
    private static let seekTo: TimeInterval = 40
    private static let settle: TimeInterval = 0.6
    private static let window: TimeInterval = 3

    static func run() async {
        guard let path = ProcessInfo.processInfo.environment["OLDTUNES_DB_PATH"], path.contains("/scratchpad/") else {
            Log.error("RELVOL: set OLDTUNES_DB_PATH to an index inside a scratchpad folder")
            return
        }
        let index: LibraryIndex
        do {
            index = try LibraryIndex(path: URL(fileURLWithPath: path))
        } catch {
            Log.error("RELVOL: could not open the index at \(path): \(error)")
            return
        }
        let ingest = LibraryIngest(index: index)
        let report = await ingest.refresh()
        guard report.status == .ok, let tracks = try? await pickSongs(index), tracks.count == 4 else {
            Log.error("RELVOL: no four iCloud songs to play (ingest \(report.status))")
            return
        }
        var songs: [Song] = []
        for track in tracks {
            guard let song = await ingest.cloudSong(for: track) else {
                Log.error("RELVOL: MusicKit can't find song \(track.id)")
                return
            }
            songs.append(song)
        }
        Log.info("RELVOL: songs " + tracks.map {
            "\($0.id) “\($0.title)” \(f($0.duration)) s, Sound Check \(f(SoundCheck.decibels(energy: $0.soundCheckEnergy))) dB"
        }.joined(separator: "; "))

        let player = ApplicationMusicPlayer.shared
        // As CloudTransport does, so the bench doesn't take Now Playing from whatever else plays.
        let inApp = CloudMediaControls.keepCommandsInApp()
        player.state.shuffleMode = .off
        player.state.repeatMode = MusicPlayer.RepeatMode.none
        guard await load(songs[0], player) else { return }
        guard CloudVolume.set(1) else {
            fail("CloudVolume finds setRelativeVolume:", "not found (Now Playing opt-out \(inApp ? "on" : "off"))")
            return
        }
        check("CloudVolume finds setRelativeVolume:", true, "on MPMusicPlayerApplicationController, taking a float")

        let remotes = AudioTapBench.remotes()
        guard !remotes.isEmpty, let tap = ProcessTap.start(AudioTapBench.ours(remotes), label: "RELVOL RemotePlayerService") else {
            Log.error("RELVOL: no tap on RemotePlayerService (\(remotes.map(AudioTapBench.describe)))")
            return
        }
        defer { tap.stop() }
        let macBefore = macVolume()
        let cloud = CloudTransport()
        cloud.affectsListeningHistory = false
        defer {
            _ = CloudVolume.set(1)
            cloud.stop()
            player.stop()
            player.queue = []
        }

        guard await playCall(tap, player, songs) else { return }
        await playThroughOldTunes(tap, cloud, tracks: Array(tracks[2...]), songs: Array(songs[2...]))

        let macAfter = macVolume()
        check("the Mac's output volume is untouched", macBefore == macAfter,
              "before \(macBefore.map { f(Double($0)) } ?? "unreadable"), after \(macAfter.map { f(Double($0)) } ?? "unreadable")")
        Log.info("RELVOL SUMMARY \(passed) passed, \(failed) failed")
    }

    // MARK: - 1. The call

    private static func playCall(_ tap: ProcessTap, _ player: ApplicationMusicPlayer, _ songs: [Song]) async -> Bool {
        guard await start(player, "the first song") else { return false }
        Log.info("RELVOL: tap \(tap.levels.startInfo)")
        guard let untouched = await measure(tap, "song 1 at 1") else { return false }
        guard untouched > -60 else {
            fail("the tap hears the song", "\(f(untouched)) dBFS: no sound to measure")
            return false
        }
        var levels: [(Float, Double)] = []
        for value: Float in [0.5, 0.25, 0.1, 0, 1] {
            setLevel(value)
            guard let level = await measure(tap, "song 1 at \(value)") else { return false }
            levels.append((value, level - untouched))
        }
        let change = Dictionary(levels.map { ($0.0, $0.1) }, uniquingKeysWith: { _, last in last })
        for value: Float in [0.5, 0.25, 0.1] {
            let expected = 20 * log10(Double(value))
            check("\(value) takes \(f(-expected)) dB off", abs((change[value] ?? 0) - expected) < 0.3,
                  "\(f(change[value] ?? 0)) dB")
        }
        check("0 silences it", (change[0] ?? 0) < -80, "\(f(change[0] ?? 0)) dB")
        check("back at 1, the level is where it started", abs(change[1] ?? 99) < 0.3, "\(f(change[1] ?? 99)) dB")

        setLevel(0.5)
        player.pause()
        try? await Task.sleep(for: .milliseconds(500))
        try? await withTimeout(20) { @MainActor in try await ApplicationMusicPlayer.shared.play() }
        _ = await waitUntil(5) { player.state.playbackStatus == .playing }
        if let level = await measure(tap, "song 1 at 0.5, after pause and play") {
            check("0.5 holds through a pause", abs(level - untouched - (change[0.5] ?? 0)) < 0.5,
                  "\(f(level - untouched)) dB; before the pause \(f(change[0.5] ?? 0)) dB")
        }

        guard await load(songs[1], player), await start(player, "the second song") else { return false }
        guard let carried = await measure(tap, "song 2, 0.5 set during song 1") else { return false }
        setLevel(1)
        guard let full = await measure(tap, "song 2 at 1") else { return false }
        check("0.5 set during one song holds for the next", abs(carried - full - (change[0.5] ?? 0)) < 0.5,
              "\(f(carried - full)) dB; song 1 \(f(change[0.5] ?? 0)) dB")
        return true
    }

    private static func setLevel(_ value: Float) {
        _ = CloudVolume.set(value)
        Log.info("RELVOL: setRelativeVolume:\(value)")
    }

    // MARK: - 2. oldTunes's path

    /// For each song, Sound Check off then on at full volume, then on at half: what RemotePlayerService
    /// plays against the same 3 s with Sound Check off at full.
    private static func playThroughOldTunes(_ tap: ProcessTap, _ cloud: CloudTransport, tracks: [Track], songs: [Song]) async {
        for (track, song) in zip(tracks, songs) {
            let gain = SoundCheck.gain(energy: track.soundCheckEnergy)
            let name = "“\(track.title)” (Sound Check \(f(SoundCheck.decibels(energy: track.soundCheckEnergy))) dB)"
            cloud.isSoundCheckOn = false
            cloud.volume = 1
            cloud.soundCheckGain = gain
            do {
                try await cloud.load(.cloud(song))
                try await cloud.play()
            } catch {
                fail("\(name) plays through CloudTransport", "\(error)")
                return
            }
            guard await start(nil, name) else { return }
            guard let off = await measure(tap, "\(name), Sound Check off, volume 1") else { return }
            cloud.isSoundCheckOn = true
            guard let on = await measure(tap, "\(name), Sound Check on, volume 1") else { return }
            let expectedOn = 20 * log10(Double(min(gain, 1)))
            check(gain < 1 ? "Sound Check turns \(name) down by its gain" : "\(name) plays at full, its boost capped",
                  abs(on - off - expectedOn) < 0.3,
                  "\(f(on - off)) dB, expected \(f(expectedOn)) dB; level \(f(Double(cloud.level))), \(cloud.ownsVolume ? "set" : "NOT set")")
            cloud.volume = 0.5
            guard let half = await measure(tap, "\(name), Sound Check on, volume 0.5") else { return }
            let expectedHalf = 20 * log10(Double(min(0.5 * gain, 1)))
            check("and oldTunes's volume at 50% plays it at half times the gain, capped at full",
                  abs(half - off - expectedHalf) < 0.3 && cloud.ownsVolume,
                  "\(f(half - off)) dB, expected \(f(expectedHalf)) dB; level \(f(Double(cloud.level)))")
        }
    }

    // MARK: - Helpers

    /// The first song plays twice; two songs Sound Check turns down and up come after. Each is an
    /// iCloud song 2 to 7 minutes long, the first by persistent id, so every run plays the same.
    private static func pickSongs(_ index: LibraryIndex) async throws -> [Track] {
        let ids = try await index.pool.read { db -> [Int64] in
            let length = "origin = 0 AND bucket = 1 AND total_time_ms BETWEEN 120000 AND 420000"
            let any = try Int64.fetchAll(db, sql: "SELECT id FROM song WHERE \(length) ORDER BY persistent_id LIMIT 2")
            let quieter = try Int64.fetchOne(db, sql: "SELECT id FROM song WHERE \(length) AND sound_check_energy > 1500 ORDER BY persistent_id LIMIT 1")
            let louder = try Int64.fetchOne(db, sql: "SELECT id FROM song WHERE \(length) AND sound_check_energy BETWEEN 400 AND 800 ORDER BY persistent_id LIMIT 1")
            return any + [quieter, louder].compactMap { $0 }
        }
        let found = try await index.tracks(ids: ids)
        // In the order asked for, whatever order the index hands them back in.
        return ids.compactMap { id in found.first { $0.id == id } }
    }

    private static func load(_ song: Song, _ player: ApplicationMusicPlayer) async -> Bool {
        let queue = ApplicationMusicPlayer.Queue(for: [song])
        if #available(macOS 26.4, *) { queue.affectsListeningHistory = false }
        player.queue = queue
        do {
            try await withTimeout(20) { @MainActor in try await ApplicationMusicPlayer.shared.prepareToPlay() }
            return true
        } catch {
            fail("“\(song.title)” prepares", "\(error)")
            return false
        }
    }

    /// Plays the loaded song (unless something else already did, `player` nil) and waits until it is.
    private static func start(_ player: ApplicationMusicPlayer?, _ name: String) async -> Bool {
        if player != nil {
            do {
                try await withTimeout(20) { @MainActor in try await ApplicationMusicPlayer.shared.play() }
            } catch {
                fail("\(name) plays", "\(error)")
                return false
            }
        }
        let shared = ApplicationMusicPlayer.shared
        guard await waitUntil(15, { shared.state.playbackStatus == .playing && shared.playbackTime > 0.3 }) else {
            fail("\(name) plays", "status \(shared.state.playbackStatus), at \(f(shared.playbackTime)) s")
            return false
        }
        return true
    }

    /// Seeks to `seekTo`, waits `settle` s of the song's own clock, then measures the next `window`
    /// seconds of it.
    private static func measure(_ tap: ProcessTap, _ label: String) async -> Double? {
        let player = ApplicationMusicPlayer.shared
        player.playbackTime = seekTo
        let start = seekTo + settle
        guard await waitUntil(8, { player.playbackTime >= start && player.playbackTime < start + 1 }) else {
            fail(label, "the song never reached \(f(start)) s (at \(f(player.playbackTime)) s, \(player.state.playbackStatus))")
            return nil
        }
        _ = tap.levels.take()
        let from = player.playbackTime
        guard await waitUntil(window + 5, { player.playbackTime >= from + window }) else {
            fail(label, "the song stopped at \(f(player.playbackTime)) s")
            return nil
        }
        let measured = tap.levels.take()
        let to = player.playbackTime
        let level = measured.samples > 0 && measured.sumSquares > 0 ? 10 * log10(measured.sumSquares / Double(measured.samples)) : -.infinity
        Log.info("RELVOL \(label): \(f(level)) dBFS over \(f(from))–\(f(to)) s of the song; \(measured.summary)")
        return level
    }

    /// The default output device's volume, as the menu bar's slider shows it.
    private static func macVolume() -> Float32? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        var volume: Float32 = 0
        size = UInt32(MemoryLayout<Float32>.size)
        address = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                             mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr ? volume : nil
    }

    /// Polls every 10 ms, finer than AudioABBench.waitUntil, so measured windows line up.
    private static func waitUntil(_ seconds: Double, _ done: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return done()
    }

    private static func check(_ name: String, _ ok: Bool, _ detail: String) {
        if ok {
            passed += 1
            Log.info("RELVOL PASS \(name): \(detail)")
        } else {
            fail(name, detail)
        }
    }

    private static func fail(_ name: String, _ detail: String) {
        failed += 1
        Log.error("RELVOL FAIL \(name): \(detail)")
    }

    private static func f(_ x: Double) -> String { String(format: "%.2f", x) }
}
