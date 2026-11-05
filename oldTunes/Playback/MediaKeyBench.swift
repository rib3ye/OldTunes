import Foundation
import MusicKit

/// OLDTUNES_PLAYBACK_MODE=keys — media keys end to end, for a local song and a cloud song.
///
/// A key press reaches an app as a MediaRemote command routed by mediaremoted to the system's
/// Now Playing app. The bench cannot press keys, so a driver outside the app sends those same
/// commands (play/pause, next, previous) once this bench logs KEYS-READY, but only after checking
/// that oldTunes is the Now Playing app, so nothing else on the Mac is touched. The bench records
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
        player.stop()
        Log.info("KEYS-END \(passed) PASS, \(failed) FAIL")
    }

    /// The external driver sends one system command after each STARTUP-READY marker. Reclaim is
    /// disabled: this checks that MusicKit never takes the keys, rather than winning them back.
    func startup() async {
        player.nowPlayingReclaimDelays = []
        player.setVolume(0.15)
        let scenarios = [0, 30, 80, 150, 500].map { ("start", $0) }
            + [("resume", 80), ("local-to-cloud", 80), ("cloud-to-cloud", 80)]
        for (scenario, delay) in scenarios {
            for command in ["next", "previous", "toggle"] {
                player.stop()
                let before = scenario == "local-to-cloud" ? l2 : c1
                let queue = [before.id, c2.id, l1.id]
                player.play(queue: queue, startAt: scenario.hasSuffix("to-cloud") ? before.id : c2.id)
                if scenario.hasSuffix("to-cloud") {
                    _ = await ready(before.id)
                    player.next()
                }
                guard await ready(c2.id) else {
                    failed += 1
                    Log.info("FAIL startup \(scenario): cloud song did not start")
                    continue
                }
                if scenario == "resume" {
                    player.playPause()
                    try? await Task.sleep(for: .milliseconds(300))
                    player.playPause()
                    guard await ready(c2.id) else {
                        failed += 1
                        Log.info("FAIL startup resume: cloud song did not resume")
                        continue
                    }
                }
                Log.info("STARTUP-READY scenario=\(scenario) cmd=\(command) delay=\(delay) pid=\(ProcessInfo.processInfo.processIdentifier) bridge=\(player.cloud.keepsMediaControlsInApp)")
                try? await Task.sleep(for: .seconds(2.5))
                let expected = command == "next" ? l1.id : command == "previous" ? before.id : c2.id
                let ok = player.state.nowPlaying?.id == expected
                    && !player.state.isLoading && player.state.isPlaying == (command != "toggle")
                if ok { passed += 1 } else { failed += 1 }
                Log.info("\(ok ? "PASS" : "FAIL") startup \(scenario) \(command) +\(delay)ms: id=\(player.state.nowPlaying?.id ?? 0) playing=\(player.state.isPlaying)")
            }
        }
        player.stop()
        Log.info("STARTUP-END \(passed) PASS, \(failed) FAIL")
    }

    private func ready(_ id: Track.ID) async -> Bool {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if player.state.nowPlaying?.id == id, player.state.isPlaying, !player.state.isLoading,
               id != c2.id || ApplicationMusicPlayer.shared.state.playbackStatus == .playing { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
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
