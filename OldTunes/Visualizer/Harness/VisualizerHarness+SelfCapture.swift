import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import MusicKit
import VisualizerCore

/// OLDTUNES_VIS_MODE=selfcapture — the visualizer's ears without System Audio Recording (SelfCapture):
///   1. which ears VisualizerAudio picks (the app: always self-capture; benches and muted ears: the
///      tap), and the silence watchdog's rules for new ears (a baseline, a ring that starts over),
///   2. live (macOS 14.4+, OLDTUNES_VIS_AUDIBLE=1 only): SelfCapture builds, hears a local file and
///      an iCloud song whose RemotePlayerService starts after the capture does, hears silence when the
///      song pauses, delivers within its read delay, and survives 10 start/stop cycles.
/// The live part plays out loud, a few seconds of each: SelfCapture can't mute what it hears, so it
/// runs only with OLDTUNES_VIS_AUDIBLE=1. The local file plays at a tenth of full volume; the iCloud
/// song at its own level, as MusicKit has no volume. Cloud plays stay out of the listening history.
/// replayd makes the capture's tap on its own entitlements, so this build's own System Audio Recording
/// grant (which only the benches' taps use) doesn't come into it. tools/self-capture-probe shows the
/// same with no grant at all.
extension VisualizerHarness {
    static func selfCapture(_ bench: VisualizerBench) async {
        guard #available(macOS 14.4, *) else {
            bench.note("skipped: capturing OldTunes's own content needs macOS 14.4")
            return
        }
        sourceDecisions(bench)
        watchdogBaselines(bench)
        guard audible else {
            bench.note("live checks skipped: they play out loud, so they need OLDTUNES_VIS_AUDIBLE=1")
            return
        }
        await liveSelfCapture(bench)
    }

    // MARK: - 1. Which ears

    @available(macOS 14.4, *)
    private static func sourceDecisions(_ bench: VisualizerBench) {
        typealias Source = VisualizerAudio.Source
        let cases: [(Bool, Bool, Source?, Source, String)] = [
            (false, false, nil, .selfCapture, "the app: self-capture, which needs no permission"),
            (false, false, .tap, .tap, "OLDTUNES_VIS_EARS=tap in a Debug launch: the tap"),
            (false, false, .selfCapture, .selfCapture, "OLDTUNES_VIS_EARS=self-capture: self-capture"),
            (true, false, nil, .tap, "a bench: the tap, which can mute"),
            (true, false, .selfCapture, .tap, "a bench, whatever OLDTUNES_VIS_EARS says: the tap"),
            (false, true, nil, .tap, "muted ears: the tap, the only ears that can mute"),
        ]
        for (isBench, muted, forced, want, label) in cases {
            let got = VisualizerAudio.choose(bench: isBench, muted: muted, forced: forced)
            bench.check(label, got == want, "got the \(got.rawValue)")
        }
    }

    private static func watchdogBaselines(_ bench: VisualizerBench) {
        var other = SilenceWatchdog(baseline: 50_000)
        _ = other.observe(now: 0, audible: true, airPlay: false, nonZeroFrames: 50_000)
        bench.check("sound other ears left in the ring isn't heard", !other.hasHeard, "")

        // New ears at another sample rate start the ring over, so its count drops.
        var restarted = SilenceWatchdog(baseline: 50_000)
        _ = restarted.observe(now: 0, audible: true, airPlay: false, nonZeroFrames: 0)
        _ = restarted.observe(now: 0.5, audible: true, airPlay: false, nonZeroFrames: 480)
        bench.check("sound in a ring that started over is heard", restarted.hasHeard, "")

        var deaf = SilenceWatchdog(baseline: 50_000)
        let advice = stride(from: 0.0, through: 7.0, by: 0.5).map {
            deaf.observe(now: $0, audible: true, airPlay: false, nonZeroFrames: 0)
        }.filter { $0 != .none }
        bench.check("ears that start over deaf still get the rebuild and the hint",
                    advice == [.rebuild, .showHint(.cantHear)] && !deaf.hasHeard, "\(advice)")
    }

    // MARK: - 2. Live

    @available(macOS 14.4, *)
    private static func liveSelfCapture(_ bench: VisualizerBench) async {
        let loaded: PlaybackHarnessLibrary.Loaded
        do {
            loaded = try await PlaybackHarnessLibrary.load(cloudLimit: 3)
        } catch {
            bench.check("library loads for the live checks", false, "\(error)")
            return
        }
        guard let cloud = loaded.clouds.first, let song = loaded.songs[cloud.id],
              let file = loaded.locals.min(by: { $0.duration < $1.duration })?.fileURL else {
            bench.check("a cloud song and a local file to play", false,
                        "\(loaded.clouds.count) cloud songs, \(loaded.locals.count) local files")
            return
        }
        bench.note("live: OldTunes pid \(ProcessInfo.processInfo.processIdentifier); Screen Recording preflight "
                   + "\(CGPreflightScreenCaptureAccess()); plays out loud")

        // The app normally has its window open when the visualizer turns on, and a capture started
        // with none on screen is untested (docs/VISUALIZER.md ▸ Measured), so the bench opens one.
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let window = NSWindow(contentRect: NSRect(x: screen.maxX - 340, y: screen.minY + 20, width: 320, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.title = "OldTunes self-capture bench"
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        // Before any song, so RemotePlayerService starts after the capture, as when the visualizer is
        // turned on before the first iCloud song.
        let ring = SampleRing()
        let capture = SelfCapture(ring: ring)
        var reasons: [String] = []
        capture.onStatusChange = { _, reason in reasons.append(reason) }
        await capture.start()
        bench.check("self-capture builds", capture.status.isRunning,
                    capture.status.failure ?? "\(capture.status.seen), \(Int(capture.status.buildMilliseconds)) ms")
        guard capture.status.isRunning else { return }
        let feed = AudioFeed(ring: ring)

        // Local, played by OldTunes itself.
        let local = AVPlayer(url: file)
        local.volume = 0.1
        local.play()
        await waitUntil(5) { local.currentTime().seconds > 0.3 }
        let localLevels = await listen(ring, feed, seconds: 2)
        bench.check("a local file reaches the feed", localLevels.nonZeroShare > 0.5 && localLevels.rms > 0,
                    localLevels.summary + ", AVPlayer at a tenth of full volume")
        local.pause()

        // Cloud, played by RemotePlayerService, which RunningBoard counts as hosted by OldTunes.
        let player = ApplicationMusicPlayer.shared
        player.state.shuffleMode = .off
        player.state.repeatMode = MusicPlayer.RepeatMode.none
        let queue = ApplicationMusicPlayer.Queue(for: [song])
        if #available(macOS 26.4, *) { queue.affectsListeningHistory = false }
        player.queue = queue
        do {
            try await withTimeout(20) { @MainActor in try await ApplicationMusicPlayer.shared.prepareToPlay() }
            try await withTimeout(10) { @MainActor in try await ApplicationMusicPlayer.shared.play() }
        } catch {
            bench.check("cloud song plays", false, "\(error)")
            capture.stop()
            return
        }
        await waitUntil(10) { player.playbackTime > 0.3 }
        let cloudLevels = await listen(ring, feed, seconds: 3)
        let remotes = AudioHAL.processes().filter { $0.bundleID == AudioHAL.remotePlayerBundleID && AudioHAL.isOurRemotePlayer(pid: $0.pid) }
        bench.check("an iCloud song reaches the feed through self-capture", cloudLevels.nonZeroShare > 0.9 && cloudLevels.rms > 0.003,
                    cloudLevels.summary + ", MusicKit at \(String(format: "%.1f", player.playbackTime)) s; "
                    + "our RemotePlayerService: \(remotes.map(\.description))")

        // Delivery: how far the newest sample lags the present, sampled while the song plays. A sample
        // includes how long its buffer has waited for the next one (up to 20 ms), so the median is
        // what the read delay has to cover; the worst only shows the clock conversion is sane.
        var lags: [Double] = []
        for _ in 0..<80 {
            try? await Task.sleep(for: .milliseconds(25))
            let newest = ring.stats.newestHostTime
            let now = HostClock.now
            if newest > 0, now > newest { lags.append(HostClock.seconds(now - newest)) }
        }
        lags.sort()
        let median = lags.isEmpty ? .infinity : lags[lags.count / 2]
        let worst = lags.last ?? .infinity
        bench.check("sound arrives within the read delay", median <= capture.readDelay && worst < 0.15,
                    String(format: "lag median %.0f ms, worst %.0f ms over %d samples; read delay %.0f ms",
                           median * 1000, worst * 1000, lags.count, capture.readDelay * 1000))

        player.pause()
        try? await Task.sleep(for: .milliseconds(400))
        let paused = await listen(ring, feed, seconds: 1)
        bench.check("a paused song is silence", paused.nonZero == 0 && paused.frames > 0, paused.summary)
        player.stop()

        // Ten start/stop cycles, then nothing may start again by itself.
        var failures = 0
        var slowest = 0.0
        for _ in 0..<10 {
            capture.stop()
            await capture.start()
            if !capture.status.isRunning { failures += 1 }
            slowest = max(slowest, capture.status.buildMilliseconds)
        }
        capture.stop()
        let afterStop = reasons.count
        try? await Task.sleep(for: .milliseconds(1_500))
        bench.check("10 start/stop cycles, and nothing restarts after the last stop",
                    failures == 0 && Set(reasons).isSubset(of: ["start", "stop"]) && reasons.count == afterStop,
                    "\(failures) failed, slowest \(Int(slowest)) ms; reasons \(Set(reasons).sorted()), "
                    + "\(reasons.count - afterStop) after the last stop")
    }
}
