import Foundation
import MusicKit

/// OLDTUNES_PLAYBACK_MODE=keys — media keys end to end, for a local song and a cloud song.
///
/// A key press reaches an app as a MediaRemote command routed by mediaremoted to the system's
/// Now Playing app. The bench cannot press keys, so a driver outside the app sends those same
/// commands (play/pause, next, previous) once this bench logs KEYS-READY, but only after checking
/// that OldTunes is the Now Playing app, so nothing else on the Mac is touched. The bench records
/// what the coordinator did in response; it never calls the coordinator itself during a phase.
@MainActor
final class MediaKeyBench {
    private let player: PlaybackCoordinator
    private let library: PlaybackHarnessLibrary
    private let l1: Track, l2: Track, c1: Track, c2: Track
    private var passed = 0, failed = 0
    private var events: [String] = []
    private var last: (Track.ID?, Bool) = (nil, false)

    init(_ loaded: PlaybackHarnessLibrary.Loaded) {
        let locals = loaded.locals.sorted { $0.duration < $1.duration }
        l1 = locals[0]; l2 = locals[1]
        c1 = loaded.clouds[0]; c2 = loaded.clouds[1]
        library = PlaybackHarnessLibrary(tracks: loaded.locals + loaded.clouds, songs: loaded.songs)
        player = PlaybackCoordinator(library: library, cloud: library)
        player.cloud.affectsListeningHistory = false
        _ = player.addObserver { [weak self] state in
            guard let self, !state.isLoading else { return }
            let now = (state.nowPlaying?.id, state.isPlaying)
            guard now != self.last else { return }
            self.last = now
            let event = "\(self.name(state.nowPlaying?.id)) \(state.isPlaying ? "playing" : "paused")"
            self.events.append(event)
            Log.info("KEYS state: \(event) at \(String(format: "%.2f", state.position)) s")
        }
    }

    func run() async {
        await phase("local", start: l1, next: l2, queue: [l1, l2, c1])
        await phase("cloud", start: c1, next: c2, queue: [c1, c2, l1])
        await takeoverWindow()
        player.stop()
        Log.info("KEYS-END \(passed) PASS, \(failed) FAIL")
    }

    /// The driver sends: play/pause, play/pause, next, previous, about 2.5 s apart.
    private func phase(_ label: String, start: Track, next: Track, queue: [Track]) async {
        player.play(queue: queue.map(\.id), startAt: start.id)
        let deadline = Date().addingTimeInterval(20)
        while !(player.state.nowPlaying?.id == start.id && player.state.isPlaying && !player.state.isLoading), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        // Past the moment MusicKit's player takes Now Playing and the coordinator takes it back.
        try? await Task.sleep(for: .seconds(2.5))
        events = []
        last = (player.state.nowPlaying?.id, player.state.isPlaying)
        Log.info("KEYS-READY phase=\(label) pid=\(ProcessInfo.processInfo.processIdentifier)")
        try? await Task.sleep(for: .seconds(14))
        let expected = ["\(name(start.id)) paused", "\(name(start.id)) playing", "\(name(next.id)) playing", "\(name(start.id)) playing"]
        let ok = events == expected
        if ok { passed += 1 } else { failed += 1 }
        Log.info("\(ok ? "PASS" : "FAIL") keys (\(label)): play/pause, play/pause, next, previous — saw \(events), expected \(expected)")
    }

    /// Each key pressed in the first moments of a cloud song, while MusicKit's own Now Playing
    /// player can still hold the keys. Logs MusicKit's state at 10 Hz so the effect is on record.
    private func takeoverWindow() async {
        // Hold the keys back for 3 s, so the commands are sure to reach MusicKit's player.
        player.nowPlayingReclaimDelays = [3]
        defer { player.nowPlayingReclaimDelays = [0, 0.5] }
        for command in ["next", "previous", "toggle"] {
            player.stop()
            try? await Task.sleep(for: .seconds(0.5))
            player.play(queue: [c2.id, c1.id, l1.id], startAt: c2.id)
            let deadline = Date().addingTimeInterval(20)
            while !(player.state.nowPlaying?.id == c2.id && !player.state.isLoading
                    && ApplicationMusicPlayer.shared.state.playbackStatus == .playing), Date() < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            events = []
            last = (player.state.nowPlaying?.id, player.state.isPlaying)
            Log.info("KEYS-WINDOW cmd=\(command) pid=\(ProcessInfo.processInfo.processIdentifier)")
            let t0 = Date()
            var lastLine = ""
            while Date().timeIntervalSince(t0) < 4 {
                let mk = ApplicationMusicPlayer.shared
                let line = "status=\(mk.state.playbackStatus) time=\(String(format: "%.2f", mk.playbackTime)) entry=\(mk.queue.currentEntry == nil ? "nil" : "set") entries=\(mk.queue.entries.count) coordinator=\(name(player.state.nowPlaying?.id)) playing=\(player.state.isPlaying)"
                if line != lastLine {
                    Log.info("KEYS window \(command) +\(String(format: "%.2f", Date().timeIntervalSince(t0))) \(line)")
                    lastLine = line
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: .seconds(2))
            Log.info("KEYS window result (\(command) while MusicKit's player held the keys): \(events.isEmpty ? "no change" : "\(events)")")
            // Measured, not wished for: in this window MusicKit's player pauses at 0.00 for both
            // Next and Play/Pause (indistinguishable, so OldTunes follows it as a pause) and
            // restarts the song for Previous. Only the pause is right; the fix is keeping the
            // window short (nowPlayingReclaimDelays), here forced open for 3 s.
            let expected: [String]? = command == "toggle" ? ["\(name(c2.id)) paused"] : nil
            if let expected {
                let ok = events == expected
                if ok { passed += 1 } else { failed += 1 }
                Log.info("\(ok ? "PASS" : "FAIL") keys (\(command) reaching MusicKit's own player) — saw \(events), expected \(expected)")
            }
        }
    }

    /// OLDTUNES_PLAYBACK_MODE=window: cloud starts of every kind, with millisecond UTC times of
    /// each action and of MusicKit turning to .playing, to line up against the Now Playing pid
    /// log (scratchpad tools/pidwatch.swift) and measure how long MusicKit's player holds the keys.
    func measureWindow() async {
        let steps: [(String, () -> Void)] = [
            ("play cloud from stopped", { self.player.play(queue: [self.c1.id, self.c2.id], startAt: self.c1.id) }),
            ("next cloud → cloud", { self.player.next() }),
            ("play local", { self.player.play(queue: [self.l1.id, self.c1.id], startAt: self.l1.id) }),
            ("next local → cloud", { self.player.next() }),
            ("seek cloud to 60 s", { self.player.seek(to: 60) }),
            ("pause cloud", { self.player.playPause() }),
            ("resume cloud", { self.player.playPause() }),
        ]
        for (label, action) in steps {
            action()
            Log.info("WINDOW \(Self.stamp()) action: \(label)")
            var wasPlaying = ApplicationMusicPlayer.shared.state.playbackStatus == .playing
            let t0 = Date()
            while Date().timeIntervalSince(t0) < 3.5 {
                let playing = ApplicationMusicPlayer.shared.state.playbackStatus == .playing
                if playing != wasPlaying {
                    Log.info("WINDOW \(Self.stamp()) MusicKit \(playing ? "playing" : "not playing")")
                    wasPlaying = playing
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        player.stop()
        Log.info("WINDOW \(Self.stamp()) done")
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: Date()) + "Z"
    }

    private func name(_ id: Track.ID?) -> String {
        guard let id else { return "nil" }
        return library.byID[id].map { "\u{201C}\($0.displayTitle)\u{201D}" } ?? "\(id)"
    }
}
