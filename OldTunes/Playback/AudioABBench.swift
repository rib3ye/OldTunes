import AVFoundation
import CoreAudio
import Foundation
import iTunesLibrary
import MusicKit

/// OLDTUNES_PLAYBACK_MODE=ab — harness-only: does one song sound the same from OldTunes and from
/// Music? Plays the song Music has loaded (or OLDTUNES_AB_PID, 16 hex digits) from the same spot in
/// each app, records what each app sends to the speakers through a muted process tap, and writes
/// the two recordings to OLDTUNES_AB_DIR as oldtunes.wav and music.wav for a side-by-side analysis.
/// OLDTUNES_AB_SONG=cloud picks an iCloud song instead. OLDTUNES_AB_START picks the spot in seconds;
/// the default is about a third of the way in. Logs the song's Sound Check data from the iTunes
/// Library framework, to compare with the gain Music applied.
///
/// The taps are muted, so the run is silent, and a leg whose tap reads only zeros stops after 2 s.
/// Music is driven with AppleScript, which the app itself never does (MusicScriptingSession,
/// §6.5); the run leaves Music paused where it found the song. Neither play should count:
/// OldTunes's is kept out of listening history, and Music's stops after about 25 s.
@available(macOS 14.2, *)
@MainActor
enum AudioABBench {
    static let musicBundleID = "com.apple.Music"
    static let seconds = 20.0
    /// Played before recording starts, so both recordings begin in steady playback.
    static let settle = 1.5

    struct Take {
        var samples: [Float]
        var channels: Int
        var rate: Double
    }

    static func run() async {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["OLDTUNES_AB_DIR"].map({ URL(fileURLWithPath: $0, isDirectory: true) }) else {
            Log.error("AB: set OLDTUNES_AB_DIR to the folder for the recordings")
            return
        }
        let me = ProcessInfo.processInfo.processIdentifier
        Log.info("AB: OldTunes pid=\(me), permission \(AudioCapturePermission.describe(AudioCapturePermission.preflight()))")
        guard let found = MusicState.read() else { return }
        Log.info("AB: Music before: \(found)")
        let items = (try? ITLibrary(apiVersion: "1.0", options: .lazyLoadData))?.allMediaItems ?? []
        var chosen = env["OLDTUNES_AB_PID"] ?? (found.trackPID.isEmpty ? nil : found.trackPID)
        if env["OLDTUNES_AB_SONG"] == "cloud" {
            // A 2–7 minute iCloud song that Music has Sound Check data for, the first by persistent id.
            chosen = items.filter { $0.mediaKind == .kindSong && $0.locationType != .file && $0.volumeNormalizationEnergy > 0
                                    && (120_000...420_000).contains($0.totalTime) }
                .min { $0.persistentID.uint64Value < $1.persistentID.uint64Value }
                .map { MusicPersistentID.hex(Int64(bitPattern: $0.persistentID.uint64Value)) }
        }
        guard let hex = chosen, let pid = MusicPersistentID.bitPattern(fromHex: hex) else {
            Log.error("AB: no song: Music has no current track and OLDTUNES_AB_PID is unset")
            return
        }
        let item = items.first { Int64(bitPattern: $0.persistentID.uint64Value) == pid }
        Log.info("AB: Sound Check data for \(hex): \(item.map(soundCheck) ?? "not in the iTunes Library framework")")
        if found.state == "playing" {
            MusicScript.run(#"tell application "Music" to pause"#)
            Log.info("AB: paused Music, which was playing")
        }

        guard let song = await librarySong(pid, title: item?.title ?? found.name) else {
            Log.error("AB: MusicKit has no library song with persistent id \(hex)")
            return
        }
        let duration = song.duration ?? found.duration ?? 0
        let start = env["OLDTUNES_AB_START"].flatMap(Double.init)
            ?? max(0, min(max(20, duration * 0.35), duration - seconds - settle - 8))
        Log.info("AB: song \(hex) “\(song.title)” — \(song.artistName), \(f(duration)) s; recording \(f(seconds)) s from \(f(start + settle)) s")
        do {
            let detailed = try await withTimeout(10) { try await song.with([.audioVariants]) }
            Log.info("AB: MusicKit lists these versions: \(detailed.audioVariants.map { $0.map(\.description).joined(separator: ", ") } ?? "none listed")")
        } catch {
            Log.info("AB: MusicKit couldn't list the song's versions: \(error)")
        }

        let oldTunes = await recordOldTunes(song, from: start, me: me)
        try? await Task.sleep(for: .milliseconds(500))
        let other = found.trackPID != hex && !found.trackPID.isEmpty
        let music = await recordMusic(hex, from: start, restore: other ? found.position.map { (found.trackPID, $0) } : nil)

        if found.trackPID == hex, let position = found.position {
            MusicScript.run(#"tell application "Music" to set player position to \#(f(position))"#)
        } else if found.state == "stopped" {
            MusicScript.run(#"tell application "Music" to stop"#)
        }
        let after = MusicState.read()
        Log.info("AB: Music after: \(after.map(String.init(describing:)) ?? "unreadable")")
        if after?.state == "playing" {
            Log.error("AB: Music was left playing; pausing it")
            _ = await holdPaused(at: nil)
        }

        for (name, take) in [("oldtunes", oldTunes), ("music", music)] {
            guard let take else {
                Log.error("AB RESULT \(name): no recording")
                continue
            }
            let url = dir.appendingPathComponent("\(name).wav")
            do {
                try write(take, to: url)
                Log.info("AB RESULT \(name): \(take.samples.count / max(1, take.channels)) frames, \(take.channels) ch at \(Int(take.rate)) Hz → \(url.path)")
            } catch {
                Log.error("AB RESULT \(name): couldn't write \(url.path): \(error)")
            }
        }
    }

    /// The library song by its MusicKit id (the persistent id in decimal, either signedness), else
    /// by title narrowed to the exact persistent id.
    static func librarySong(_ pid: Int64, title: String) async -> Song? {
        for id in [String(pid), String(UInt64(bitPattern: pid))] {
            if let song = try? await MusicKitSource.librarySong(cloudID: id) { return song }
        }
        return try? await MusicKitSource.librarySong(title: title, persistentID: pid)
    }

    /// OldTunes's way: MusicKit's ApplicationMusicPlayer, heard from RemotePlayerService.
    static func recordOldTunes(_ song: Song, from start: Double, me: pid_t) async -> Take? {
        let player = ApplicationMusicPlayer.shared
        player.state.shuffleMode = .off
        player.state.repeatMode = MusicPlayer.RepeatMode.none
        let queue = ApplicationMusicPlayer.Queue(for: [song])
        if #available(macOS 26.4, *) { queue.affectsListeningHistory = false }
        player.queue = queue
        do {
            try await withTimeout(20) { @MainActor in try await ApplicationMusicPlayer.shared.prepareToPlay() }
        } catch {
            Log.error("AB OldTunes: the song would not prepare: \(error)")
            return nil
        }
        let remotes = AudioTapBench.remotes()
        Log.info("AB OldTunes: RemotePlayerService after prepareToPlay: \(remotes.map(AudioTapBench.describe))")
        guard !remotes.isEmpty,
              let tap = ProcessTap.start(AudioTapBench.ours(remotes, me) + AudioTapBench.ownObject(me), label: "AB OldTunes") else {
            Log.error("AB OldTunes: no tap")
            player.queue = []
            return nil
        }
        var take: Take?
        do {
            try await withTimeout(10) { @MainActor in try await ApplicationMusicPlayer.shared.play() }
            player.playbackTime = start
            if await waitUntil(10, { player.playbackTime >= start + settle }) {
                take = await record(tap, label: "AB OldTunes") {
                    "MusicKit \(player.state.playbackStatus) at \(f(player.playbackTime)) s, "
                        + "playing version \(player.state.audioVariant.map(\.description) ?? "not said")"
                }
            } else {
                Log.error("AB OldTunes: never reached \(f(start + settle)) s (at \(f(player.playbackTime)) s)")
            }
        } catch {
            Log.error("AB OldTunes: the song would not play: \(error)")
        }
        // Silence the player before the tap goes, or its last moment would reach the speakers.
        player.stop()
        player.queue = []
        try? await Task.sleep(for: .milliseconds(400))
        tap.stop()
        return take
    }

    /// Music's Sound Check data, as the iTunes Library framework reports it, and the gain Music
    /// applies for it: −20·log10(energy / 1000) dB, which matched this bench to 0.01 dB on two
    /// songs. The iTunNORM-style −10·log10 gives half of that.
    static func soundCheck(_ item: ITLibMediaItem) -> String {
        let energy = item.volumeNormalizationEnergy
        let gain = energy > 0 ? String(format: "%+.2f dB", -20 * log10(Double(energy) / 1000)) : "none"
        return "normalization energy \(energy) (Sound Check gain \(gain)), volume adjustment \(item.volumeAdjustment), "
            + "location type \(item.locationType.rawValue), kind \(item.kind ?? "-")"
    }

    /// Music's way, driven with AppleScript and heard from Music's own process. `restore` puts
    /// Music back on the song it had before, while the tap still mutes it.
    static func recordMusic(_ hex: String, from start: Double, restore: (hex: String, position: Double)?) async -> Take? {
        let objects = AudioProcessProbe.allProcesses().filter { $0.bundleID == musicBundleID }.map(\.object)
        guard !objects.isEmpty, let tap = ProcessTap.start(objects, label: "AB Music") else {
            Log.error("AB Music: no tap (Music in the HAL process list: \(objects))")
            return nil
        }
        var take: Take?
        // `once`: Music stops at the end of this song instead of going on to the next one.
        if MusicScript.run(#"tell application "Music" to play (first track of library playlist 1 whose persistent ID is "\#(hex)") with once"#) != nil {
            // Jump to the spot once the song is playing; a jump before that can be lost.
            var moved = false
            let ready = await waitUntil(15) {
                guard let now = MusicState.playback() else { return false }
                if !moved, now.state == "playing" {
                    MusicScript.run(#"tell application "Music" to set player position to \#(f(start))"#)
                    moved = true
                    return false
                }
                return moved && now.position >= start + settle
            }
            if ready {
                take = await record(tap, label: "AB Music") {
                    MusicState.playback().map { "Music \($0.state) at \(f($0.position)) s" } ?? "Music unreadable"
                }
            } else {
                Log.error("AB Music: never reached \(f(start + settle)) s: \(MusicState.playback().map { "\($0.state) at \(f($0.position)) s" } ?? "unreadable")")
            }
        }
        MusicScript.run(#"tell application "Music" to pause"#)
        if let restore {
            if MusicScript.run(#"tell application "Music" to play (first track of library playlist 1 whose persistent ID is "\#(restore.hex)") with once"#) != nil {
                // Music says "playing" before the song has really started, and a pause sent then
                // can lose to the start: on October 20 that left Music playing out loud once the
                // tap was gone. So wait until the position moves.
                _ = await waitUntil(10) { MusicState.playback().map { $0.state == "playing" && $0.position > 0.2 } ?? false }
            }
        }
        // Only then let go of the tap, which is what keeps Music silent.
        if !(await holdPaused(at: restore?.position)) {
            Log.error("AB Music: Music was still playing after 5 s of pausing it")
        }
        try? await Task.sleep(for: .milliseconds(400))
        tap.stop()
        return take
    }

    /// Pauses Music until it has stayed paused for a second (10 polls), then moves it to `position`.
    /// False if it was still playing after 5 s.
    static func holdPaused(at position: Double?) async -> Bool {
        var quietTicks = 0
        var placed = false
        for _ in 0..<50 {
            guard let now = MusicState.playback() else { return false }
            if now.state == "playing" {
                quietTicks = 0
                placed = false
                MusicScript.run(#"tell application "Music" to pause"#)
            } else {
                if let position, !placed {
                    MusicScript.run(#"tell application "Music" to set player position to \#(f(position))"#)
                    placed = true
                }
                quietTicks += 1
                if quietTicks >= 10 { return true }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// Records `seconds` of the tap. After the first 2 s, gives up if the tap has read only zeros:
    /// then the sound is coming from somewhere else, unmuted.
    static func record(_ tap: ProcessTap, label: String, status: () -> String) async -> Take? {
        _ = tap.levels.take()
        tap.recording.start(frames: Int(seconds * tap.sampleRate))
        try? await Task.sleep(for: .seconds(2))
        let early = tap.levels.take()
        Log.info("\(label) first 2 s: \(early.summary); \(status()); sending audio: \(AudioProcessProbe.processesRunningOutput())")
        guard early.nonZero > 0 else {
            Log.error("\(label): the tap read only zeros, stopping")
            _ = tap.recording.finish()
            return nil
        }
        try? await Task.sleep(for: .seconds(seconds - 2 + 0.3))
        Log.info("\(label) rest: \(tap.levels.take().summary); \(status())")
        let (samples, channels) = tap.recording.finish()
        return channels > 0 ? Take(samples: samples, channels: channels, rate: tap.sampleRate) : nil
    }

    static func waitUntil(_ seconds: Double, _ done: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return done()
    }

    /// A 32-bit float WAV, the tap's own sample format.
    static func write(_ take: Take, to url: URL) throws {
        let frames = take.samples.count / take.channels
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: take.rate,
                                         channels: AVAudioChannelCount(take.channels), interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData else {
            throw TapError(step: "making the WAV buffer", status: 0)
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<take.channels {
            for frame in 0..<frames { channels[channel][frame] = take.samples[frame * take.channels + channel] }
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: take.rate, AVNumberOfChannelsKey: take.channels,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    static func f(_ x: Double) -> String { String(format: "%.2f", x) }
}

/// Harness-only AppleScript to Music, on the main thread as NSAppleScript requires.
@MainActor
enum MusicScript {
    @discardableResult
    static func run(_ source: String) -> String? {
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error) else {
            Log.error("AB: AppleScript to Music failed: \(error.map { "\($0)" } ?? "no script")")
            return nil
        }
        return result.stringValue ?? ""
    }
}

/// What Music is doing, and the settings of its own that change the sound and that its
/// AppleScript dictionary exposes (Sound Enhancer, Sound Check and Dolby Atmos are not among them).
@MainActor
struct MusicState: CustomStringConvertible {
    var state = ""
    var position: Double?
    var appVolume = ""
    var equalizer = ""
    var trackPID = ""
    var name = ""
    var artist = ""
    var duration: Double?
    var trackDetails = ""

    nonisolated var description: String {
        "\(state) at \(position.map { String(format: "%.2f", $0) } ?? "-") s, app volume \(appVolume), equalizer \(equalizer); "
            + "track \(trackPID.isEmpty ? "none" : trackPID) “\(name)” — \(artist), \(duration.map { String(format: "%.1f", $0) } ?? "-") s; \(trackDetails)"
    }

    static func read() -> MusicState? {
        let source = """
            tell application "Music"
                set out to {player state as text}
                try
                    set end of out to (player position as text)
                on error
                    set end of out to ""
                end try
                set end of out to (sound volume as text)
                try
                    set end of out to (EQ enabled as text) & ", preset " & (name of current EQ preset)
                on error
                    set end of out to (EQ enabled as text)
                end try
                try
                    set t to current track
                    set end of out to (persistent ID of t)
                    set end of out to (name of t)
                    set end of out to (artist of t)
                    set end of out to (duration of t as text)
                    set d to "kind " & (kind of t)
                    try
                        set d to d & ", cloud status " & (cloud status of t as text)
                    end try
                    try
                        set d to d & ", " & (bit rate of t as text) & " kbps, " & (sample rate of t as text) & " Hz"
                    end try
                    try
                        set d to d & ", song's own EQ preset “" & (EQ of t) & "”, volume adjustment " & (volume adjustment of t as text)
                    end try
                    set end of out to d
                on error
                    repeat 5 times
                        set end of out to ""
                    end repeat
                end try
                set AppleScript's text item delimiters to tab
                set s to out as text
                set AppleScript's text item delimiters to ""
                return s
            end tell
            """
        guard let text = MusicScript.run(source) else { return nil }
        let fields = text.components(separatedBy: "\t")
        guard fields.count >= 9 else {
            Log.error("AB: Music's state came back as \(fields.count) fields: \(text)")
            return nil
        }
        return MusicState(state: fields[0], position: Double(fields[1]), appVolume: fields[2], equalizer: fields[3],
                          trackPID: fields[4], name: fields[5], artist: fields[6], duration: Double(fields[7]),
                          trackDetails: fields[8...].joined(separator: " "))
    }

    /// Just the player state and position, cheap enough to poll.
    static func playback() -> (state: String, position: Double)? {
        let source = """
            tell application "Music"
                try
                    return (player state as text) & tab & (player position as text)
                on error
                    return (player state as text) & tab & "0"
                end try
            end tell
            """
        guard let fields = MusicScript.run(source)?.components(separatedBy: "\t"), fields.count == 2 else { return nil }
        return (fields[0], Double(fields[1]) ?? 0)
    }
}
