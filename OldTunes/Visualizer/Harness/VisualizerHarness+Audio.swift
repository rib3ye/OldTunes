import AVFoundation
import CoreAudio
import Foundation
import MusicKit
import VisualizerCore

/// OLDTUNES_VIS_MODE=audio — the visualizer's audio feed:
///   1. the AnalyserNode emulation and getFrame port against what Geiss HDR's own code returned in
///      Chrome (VisualizerFixtures+Analyser.swift, made by tools/analyser-fixtures.js),
///   2. the silence watchdog's decisions,
///   3. live (macOS 14.2+): the tap on a cloud song and a local file, our RemotePlayerService picked as
///      the one that started after OldTunes, the watchdog on a deaf tap, and 20 build/teardown cycles
///      that must leave no taps or aggregate devices behind.
/// The tap is muted unless OLDTUNES_VIS_AUDIBLE=1. Cloud plays stay out of the listening history.
extension VisualizerHarness {
    static func audio(_ bench: VisualizerBench) async {
        analyserParity(bench)
        feedParity(bench)
        waveScale(bench)
        watchdogDecisions(bench)
        if #available(macOS 14.2, *) {
            await liveTap(bench)
        } else {
            bench.note("live tap checks skipped: process taps need macOS 14.2")
        }
    }

    // MARK: - The synthetic signal (tools/analyser-fixtures.js builds the same one)

    private struct Mulberry32 {
        var state: UInt32
        mutating func next() -> Double {
            state &+= 0x6D2B79F5
            var t = state
            t = (t ^ (t >> 15)) &* (t | 1)
            t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
            return Double(t ^ (t >> 14)) / 4_294_967_296
        }
    }

    /// Only sums of powers of two, so it matches the JavaScript sample for sample.
    private static func fixtureSignal() -> (left: [Float], right: [Float], mono: [Float]) {
        let frames = AnalyserFixtures.frames
        var rand = Mulberry32(state: AnalyserFixtures.seed)
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        for n in 0..<frames {
            let noiseL = (rand.next() * 65536).rounded(.down) / 65536 - 0.5
            let noiseR = (rand.next() * 65536).rounded(.down) / 65536 - 0.5
            let saw = Double(n % 128) / 128 - 0.5
            let square = (n % 16) < 8 ? 0.5 : -0.5
            let triangle = abs(Double(n % 256) / 128 - 1) - 0.5
            var l = 0.5 * saw + 0.25 * square + noiseL / 32
            var r = 0.5 * triangle + noiseR / 32
            if n >= 9600 && n < 14400 { l = 0; r = 0 }
            if n >= 14400 {
                let burst = ((n % 512) < 256 ? 0.75 : -0.75) / pow(2, (Double(n - 14400) / 1024).rounded(.down))
                l += burst
                r -= burst / 2
            }
            left[n] = Float(l)
            right[n] = Float(r)
        }
        let mono = (0..<frames).map { (left[$0] + right[$0]) * 0.5 }
        return (left, right, mono)
    }

    // MARK: - 1. Analyser parity

    /// How far one frame is from Chrome's, in the units that matter for each field.
    private struct Gap {
        var waveMismatches = 0
        var rms = 0.0
        var visualEnergy = 0.0
        var decibels = 0.0
        var bands = 0.0
        var spectrum = 0.0

        mutating func add(_ frame: AudioFrame, _ want: AnalyserFixtures.Snapshot, decibels db: [Float]) {
            for (k, i) in AnalyserFixtures.waveIndices.enumerated() where frame.wave[i] != want.wave[k] { waveMismatches += 1 }
            rms = max(rms, relative(frame.rms, want.rms))
            visualEnergy = max(visualEnergy, relative(frame.visualEnergy, want.visualEnergy))
            for (k, bin) in AnalyserFixtures.bins.enumerated() {
                let got = db[bin], expected = want.decibels[k]
                // Below −100 dB both sides sit in rounding noise; there they need only agree to 1 dB.
                if expected > -100 || got > -100 { decibels = max(decibels, Double(abs(got - expected))) }
                else if abs(got - expected) > 1 { decibels = max(decibels, Double(abs(got - expected))) }
                if expected > -100 { spectrum = max(spectrum, relative(Double(frame.spectrum[bin]), Double(want.spectrum[k]))) }
            }
            for b in 0..<4 { bands = max(bands, relative(Double(frame.bandEnergy[b]), Double(want.bands[b]))) }
        }

        func relative(_ a: Double, _ b: Double) -> Double {
            a == b ? 0 : abs(a - b) / max(abs(a), abs(b), 1e-30)
        }

        var passes: Bool {
            waveMismatches == 0 && rms < 1e-12 && visualEnergy < 1e-12 && decibels <= 0.05 && bands < 1e-2 && spectrum < 1e-2
        }

        var summary: String {
            "wave mismatches \(waveMismatches), rms \(e(rms)), visual energy \(e(visualEnergy)), "
                + "dB \(String(format: "%.5f", decibels)), bands \(e(bands)), spectrum \(e(spectrum)) (relative)"
        }

        private func e(_ x: Double) -> String { String(format: "%.2e", x) }
    }

    private static func analyserParity(_ bench: VisualizerBench) {
        let signal = fixtureSignal()
        let builder = AudioFrameBuilder()
        var gap = Gap()
        for want in AnalyserFixtures.snapshots {
            let frame = signal.mono[(want.end - AudioFrame.fftSize)..<want.end].withUnsafeBufferPointer {
                builder.frame(timeDomain: $0, sampleRate: AnalyserFixtures.sampleRate)
            }
            gap.add(frame, want, decibels: builder.decibels)
        }
        bench.check("AnalyserNode and getFrame match Chrome on \(AnalyserFixtures.snapshots.count) frames", gap.passes, gap.summary)
    }

    // MARK: - The same through the sample ring and AudioFeed, as the render loop will read it

    private static func feedParity(_ bench: VisualizerBench) {
        let signal = fixtureSignal()
        let rate = AnalyserFixtures.sampleRate
        let ring = SampleRing(capacity: 32_768)
        let interleaved = (0..<AnalyserFixtures.frames).flatMap { [signal.left[$0], signal.right[$0]] }
        let start: UInt64 = 1_000_000_000
        // Written in 512-frame buffers, as the IOProc delivers them.
        for chunk in stride(from: 0, to: AnalyserFixtures.frames, by: 512) {
            interleaved[(chunk * 2)..<((chunk + 512) * 2)].withUnsafeBufferPointer {
                ring.writeInterleaved($0.baseAddress!, frames: 512, channels: 2, gain: 1,
                                      firstFrameHostTime: start + HostClock.ticks(seconds: Double(chunk) / rate), sampleRate: rate)
            }
        }
        let feed = AudioFeed(ring: ring)
        let direct = AnalyserNode()
        var gap = Gap()
        var binZero = 0.0
        var decibels = [Float](repeating: 0, count: AudioFrame.binCount)
        for want in AnalyserFixtures.snapshots {
            // Half a quantum past the window's end, so rounding either way snaps to the same boundary.
            let when = start + HostClock.ticks(seconds: Double(want.end + 63) / rate)
            let frame = feed.frame(endingAt: when)
            signal.mono[(want.end - AudioFrame.fftSize)..<want.end].withUnsafeBufferPointer { window in
                decibels.withUnsafeMutableBufferPointer { direct.analyse(window, decibels: $0) }
            }
            gap.add(frame, want, decibels: decibels)
            if want.decibels[0] > -100 { binZero = max(binZero, Double(abs(decibels[0] - want.decibels[0]))) }
        }
        bench.check("ring → AudioFeed reads the same windows and matches Chrome", gap.passes && binZero <= 0.05,
                    gap.summary + ", bin 0 dB \(String(format: "%.5f", binZero))")
    }

    private static func waveScale(_ bench: VisualizerBench) {
        let signal = fixtureSignal()
        let window = Array(signal.mono[2048..<4096])
        let one = window.withUnsafeBufferPointer { AudioFrameBuilder().frame(timeDomain: $0, sampleRate: 48_000, waveScale: 1) }
        let two = window.withUnsafeBufferPointer { AudioFrameBuilder().frame(timeDomain: $0, sampleRate: 48_000, waveScale: 2) }
        let ok = zip(one.wave, two.wave).allSatisfy { $0 * 2 == $1 }
            && abs(two.rms - 2 * one.rms) < 1e-12 && abs(two.visualEnergy - one.visualEnergy) < 1e-12
            && one.bandEnergy == two.bandEnergy
        bench.check("wave scale scales the wave and rms only", ok,
                    "rms \(one.rms) → \(two.rms), visual energy \(one.visualEnergy) → \(two.visualEnergy)")
    }

    // MARK: - 2. Watchdog decisions

    private static func watchdogDecisions(_ bench: VisualizerBench) {
        typealias W = SilenceWatchdog
        func run(_ steps: [(t: Double, audible: Bool, nonZero: UInt64)], airPlay: Bool = false,
                 from start: W = W()) -> (advice: [(Double, W.Advice)], end: W) {
            var w = start
            var out: [(Double, W.Advice)] = []
            for s in steps {
                let a = w.observe(now: s.t, audible: s.audible, airPlay: airPlay, nonZeroFrames: s.nonZero)
                if a != .none { out.append((s.t, a)) }
            }
            return (out, w)
        }
        let ticks = stride(from: 0.0, through: 8.0, by: 0.5)
        let deaf = ticks.map { (t: $0, audible: true, nonZero: UInt64(0)) }
        let first = run(deaf)
        bench.check("zeros while playing: one rebuild at 3 s, then the permission hint at 6 s",
                    first.advice.map(\.1) == [.rebuild, .showHint(.permission)] && first.advice.map(\.0) == [3.0, 6.0],
                    "\(first.advice)")

        let heard = run([(t: 8.5, audible: true, nonZero: 10)], from: first.end)
        bench.check("the first non-zero sample clears the hint", heard.advice.map(\.1) == [.clearHint], "\(heard.advice)")

        let again = run(stride(from: 9.0, through: 16.0, by: 0.5).map { (t: $0, audible: true, nonZero: UInt64(10)) }, from: heard.end)
        bench.check("a second silence within 30 s skips the rebuild", again.advice.map(\.1) == [.showHint(.permission)],
                    "\(again.advice)")

        let paused = run(ticks.map { (t: $0, audible: false, nonZero: UInt64(0)) })
        bench.check("zeros while paused or loading are fine", paused.advice.isEmpty, "\(paused.advice)")

        let quiet = run(ticks.map { (t: $0, audible: true, nonZero: UInt64($0 * 100)) })
        bench.check("quiet but non-zero music is not silence", quiet.advice.isEmpty, "\(quiet.advice)")

        let airPlay = run(deaf, airPlay: true)
        bench.check("on AirPlay the hint is the AirPlay one", airPlay.advice.map(\.1) == [.rebuild, .showHint(.airPlay)],
                    "\(airPlay.advice)")

        // The permission may come back while the hint shows, and the old tap may stay deaf.
        let later = stride(from: 8.5, through: 70.0, by: 0.5).map { (t: $0, audible: true, nonZero: UInt64(0)) }
        let retries = run(later, from: first.end)
        bench.check("while the permission hint shows, a new tap every 30 s",
                    retries.advice.map(\.1) == [.rebuild, .rebuild] && retries.advice.map(\.0) == [33.0, 63.0],
                    "\(retries.advice)")
        let airPlayLater = run(later, airPlay: true, from: airPlay.end)
        bench.check("but not for the AirPlay hint", airPlayLater.advice.isEmpty, "\(airPlayLater.advice)")
    }

    // MARK: - 3. Live

    @available(macOS 14.2, *)
    private static func liveTap(_ bench: VisualizerBench) async {
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
        let baselineTaps = AudioHAL.readIDs(AudioHAL.system, kAudioHardwarePropertyTapList).count
        let baselineDevices = AudioHAL.readIDs(AudioHAL.system, kAudioHardwarePropertyDevices).count
        let me = ProcessInfo.processInfo.processIdentifier
        bench.note("live: OldTunes pid \(me); \(baselineTaps) taps and \(baselineDevices) devices before; "
                   + "tap \(audible ? "audible" : "muted")")

        // Prepare the cloud song first, so its RemotePlayerService exists before the tap is built.
        let player = ApplicationMusicPlayer.shared
        player.state.shuffleMode = .off
        player.state.repeatMode = MusicPlayer.RepeatMode.none
        let queue = ApplicationMusicPlayer.Queue(for: [song])
        if #available(macOS 26.4, *) { queue.affectsListeningHistory = false }
        player.queue = queue
        do {
            try await withTimeout(20) { @MainActor in try await ApplicationMusicPlayer.shared.prepareToPlay() }
        } catch {
            bench.check("cloud song prepares", false, "\(error)")
            return
        }

        let ring = SampleRing()
        let tap = MusicAudioTap(ring: ring, muted: !audible)
        var reasons: [String] = []
        tap.onStatusChange = { _, reason in reasons.append(reason) }
        await tap.start()
        let status = tap.status
        bench.check("tap builds", status.isRunning, status.failure ?? "\(status.tapped), \(status.format), \(Int(status.buildMilliseconds)) ms")
        let remotes = status.tapped.filter { $0.bundleID == AudioHAL.remotePlayerBundleID }
        // Whether it is the right one shows below: the feed hears the cloud song only through ours.
        let listed = AudioHAL.processes().filter { $0.bundleID == AudioHAL.remotePlayerBundleID }
        bench.check("our RemotePlayerService is tapped, and none that was running before OldTunes started",
                    !remotes.isEmpty && remotes.allSatisfy { AudioHAL.isOurRemotePlayer(pid: $0.pid) },
                    "tapped \(remotes); listed: \(listed.map { "\($0) \(AudioHAL.isOurRemotePlayer(pid: $0.pid) ? "started after OldTunes" : "running before OldTunes started")" })")

        // Cloud. Only if the tap holds the RemotePlayerService: otherwise a muted bench would play out loud.
        let feed = AudioFeed(ring: ring)
        if remotes.isEmpty {
            bench.check("cloud song reaches the feed", false, "skipped: RemotePlayerService isn't tapped, so it would play out loud")
        } else {
            do {
                try await withTimeout(10) { @MainActor in try await ApplicationMusicPlayer.shared.play() }
            } catch {
                bench.check("cloud song plays", false, "\(error)")
            }
            await waitUntil(10) { player.playbackTime > 0.3 }
            let cloudLevels = await listen(ring, feed, seconds: 3)
            bench.check("cloud song reaches the feed", cloudLevels.nonZeroShare > 0.9 && cloudLevels.rms > 0.003,
                        cloudLevels.summary + ", MusicKit at \(String(format: "%.1f", player.playbackTime)) s")
        }
        player.stop()
        try? await Task.sleep(for: .milliseconds(500))

        // Local, played by OldTunes itself.
        let local = AVPlayer(url: file)
        local.play()
        await waitUntil(5) { local.currentTime().seconds > 0.3 }
        let localLevels = await listen(ring, feed, seconds: 3)
        bench.check("local file reaches the feed", localLevels.nonZeroShare > 0.5 && localLevels.rms > 0.0005,
                    localLevels.summary + ", AVPlayer at \(String(format: "%.1f", local.currentTime().seconds)) s")
        local.pause()

        // A deaf tap: nothing plays, but the watchdog is told something is.
        let watchdog = TapWatchdog(tap: tap, player: nil)
        var hints: [SilenceWatchdog.Hint?] = []
        watchdog.onHint = { hints.append($0) }
        watchdog.audibleOverride = true
        reasons.removeAll()
        watchdog.start()
        try? await Task.sleep(for: .milliseconds(7_500))
        bench.check("watchdog rebuilds a silent tap once, then shows the permission hint",
                    reasons == ["silent while playing"] && hints == [.permission],
                    "rebuilds \(reasons), hints \(hints)")
        local.play()
        await waitUntil(3) { hints.count >= 2 }
        bench.check("sound arriving clears the hint", hints.last == .some(nil), "hints \(hints)")
        local.pause()
        watchdog.stop()

        // Twenty build/teardown cycles.
        var slowest = 0.0
        var failures = 0
        for _ in 0..<20 {
            tap.stop()
            await tap.start()
            if !tap.status.isRunning { failures += 1 }
            slowest = max(slowest, tap.status.buildMilliseconds)
        }
        tap.stop()
        let rebuildsAfterStop = reasons.count
        // The HAL's lists can lag a destroy by a moment.
        try? await Task.sleep(for: .seconds(1))
        let taps = AudioHAL.readIDs(AudioHAL.system, kAudioHardwarePropertyTapList)
        let devices = AudioHAL.readIDs(AudioHAL.system, kAudioHardwarePropertyDevices)
        bench.check("20 build/teardown cycles leave nothing behind",
                    failures == 0 && taps.count == baselineTaps && devices.count == baselineDevices && reasons.count == rebuildsAfterStop,
                    "\(failures) failed builds, slowest \(Int(slowest)) ms; taps \(baselineTaps) → \(taps.count), devices \(baselineDevices) → \(devices.count) "
                    + "\(devices.map { AudioHAL.name($0) ?? "?" }); \(reasons.count - rebuildsAfterStop) rebuilds after stop")
    }

    private struct Levels {
        var frames: UInt64 = 0
        var nonZero: UInt64 = 0
        var rms = 0.0
        var nonZeroShare: Double { frames > 0 ? Double(nonZero) / Double(frames) : 0 }
        var summary: String {
            "\(frames) frames, \(String(format: "%.1f", nonZeroShare * 100))% non-zero, feed rms "
                + (rms > 0 ? String(format: "%.1f dBFS", 20 * log10(rms)) : "-inf")
        }
    }

    /// Ring growth over `seconds`, and the loudest frame the feed made from it.
    @MainActor
    private static func listen(_ ring: SampleRing, _ feed: AudioFeed, seconds: Int) async -> Levels {
        let before = ring.stats
        var levels = Levels()
        for _ in 0..<(seconds * 10) {
            try? await Task.sleep(for: .milliseconds(100))
            levels.rms = max(levels.rms, feed.frame().rms)
        }
        let after = ring.stats
        levels.frames = after.framesWritten - before.framesWritten
        levels.nonZero = after.nonZeroFrames - before.nonZeroFrames
        return levels
    }

    @MainActor
    private static func waitUntil(_ seconds: Double, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
