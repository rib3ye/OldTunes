import Foundation
import MediaPlayer
import MusicKit

/// Harness-only: RESEARCH.md §10-R3. Plays one cloud song on a bare ApplicationMusicPlayer,
/// jumps to six seconds before the end, and logs what MusicKit reports at 10 Hz through the
/// natural end and two seconds past it. CloudTransport's end detection is designed from this log.
@MainActor
enum CloudEndProbe {
    static func run(song: Song, label: String) async -> Bool {
        let player = ApplicationMusicPlayer.shared
        player.state.shuffleMode = .off
        player.state.repeatMode = MusicPlayer.RepeatMode.none
        let queue = ApplicationMusicPlayer.Queue(for: [song])
        if #available(macOS 26.4, *) { queue.affectsListeningHistory = false }
        player.queue = queue
        Log.info("R3 probe: \(label) songDuration=\(fmt(song.duration ?? -1)) repeatMode=\(String(describing: player.state.repeatMode)) shuffleMode=\(String(describing: player.state.shuffleMode))")
        logNowPlaying("before prepare")
        do {
            try await withTimeout(20) { @MainActor in try await ApplicationMusicPlayer.shared.prepareToPlay() }
            try await withTimeout(10) { @MainActor in try await ApplicationMusicPlayer.shared.play() }
        } catch {
            Log.error("R3 probe: could not start: \(error)")
            return false
        }
        let started = Date()
        while player.playbackTime < 0.5, Date().timeIntervalSince(started) < 10 {
            try? await Task.sleep(for: .milliseconds(100))
        }
        Log.info("R3 probe: playing after \(fmt(Date().timeIntervalSince(started))) s, playbackTime=\(fmt(player.playbackTime))")
        logNowPlaying("while playing")
        Log.info("R3 probe: processes running audio output: \(AudioProcessProbe.processesRunningOutput()) (oldTunes pid=\(ProcessInfo.processInfo.processIdentifier))")

        guard let duration = song.duration, duration > 8 else {
            Log.error("R3 probe: song has no usable duration")
            player.stop()
            return false
        }
        player.playbackTime = duration - 6
        let t0 = Date()
        var transitionAt: Date?
        var last = ""
        var lastTime = player.playbackTime
        while Date().timeIntervalSince(t0) < 14 {
            let status = player.state.playbackStatus
            let time = player.playbackTime
            let entry = player.queue.currentEntry
            let line = "status=\(status) entry=\(entry.map { "\($0.title)" } ?? "nil") entries=\(player.queue.entries.count) prepared=\(player.isPreparedToPlay)"
            let changed = line != last
            Log.info("R3 tick +\(fmt(Date().timeIntervalSince(t0))) time=\(fmt(time)) remaining=\(fmt(duration - time)) \(line)\(changed ? "  <-- changed" : "")")
            if transitionAt == nil, (status != .playing || entry == nil || time + 1 < lastTime) {
                transitionAt = Date()
                Log.info("R3 probe: TRANSITION at time=\(fmt(time)) (previous tick time=\(fmt(lastTime)), duration=\(fmt(duration))) status=\(status) entry=\(entry == nil ? "nil" : "present")")
            }
            if let transitionAt, Date().timeIntervalSince(transitionAt) > 2 { break }
            last = line
            lastTime = time
            try? await Task.sleep(for: .milliseconds(100))
        }
        logNowPlaying("after end")
        player.stop()
        Log.info("R3 probe: after stop() status=\(player.state.playbackStatus) time=\(fmt(player.playbackTime)) entry=\(player.queue.currentEntry == nil ? "nil" : "present")")
        return transitionAt != nil
    }

    static func logNowPlaying(_ when: String) {
        let center = MPNowPlayingInfoCenter.default()
        let info = center.nowPlayingInfo ?? [:]
        let summary = info.keys.sorted().map { "\($0)=\(String(describing: info[$0] ?? ""))" }.joined(separator: " ")
        Log.info("now-playing (\(when)): playbackState=\(center.playbackState.rawValue) info=[\(summary)]")
    }

    static func fmt(_ x: Double) -> String { String(format: "%.2f", x) }
}
