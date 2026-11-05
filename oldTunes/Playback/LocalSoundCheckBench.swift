import AVFoundation
import Foundation

/// Generated tones, measured after AVPlayer through a muted tap on this process alone.
/// No library, MusicKit, saved settings, or system volume changes.
@available(macOS 14.2, *)
@MainActor
enum LocalSoundCheckBench {
    static func run() async {
        var passed = 0, failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { passed += 1 } else { failed += 1 }
            Log.info("\(ok ? "PASS" : "FAIL") local Sound Check: \(name) \(detail)")
        }
        let directory = URL(fileURLWithPath: "/private/tmp/oldtunes-soundcheck-\(UUID().uuidString)", isDirectory: true)
        let local = LocalTransport()
        defer {
            local.stop()
            try? FileManager.default.removeItem(at: directory)
            Log.info("SOUNDCHECK-END \(passed) PASS, \(failed) FAIL")
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let first = directory.appendingPathComponent("quiet.caf")
            let second = directory.appendingPathComponent("next.caf")
            try tone(first)
            try tone(second)
            guard let own = ProcessTap.start(AudioTapBench.ownObject(ProcessInfo.processInfo.processIdentifier), label: "local Sound Check") else {
                check("output tap starts", false)
                return
            }
            defer { own.stop() }
            guard await AudioABBench.toneCheck(own) else {
                check("output tap hears audio", false)
                return
            }
            func level() async -> Double {
                // Let AVPlayer drain any buffers decoded before the setting changed.
                try? await Task.sleep(for: .seconds(0.7))
                _ = own.levels.take()
                try? await Task.sleep(for: .seconds(0.5))
                let w = own.levels.take()
                return w.samples > 0 ? sqrt(w.sumSquares / Double(w.samples)) : 0
            }
            func ratio(_ name: String, _ measured: Double, _ baseline: Double, _ expected: Double) {
                let got = baseline > 0 ? measured / baseline : 0
                check(name, baseline > 0.001 && abs(got - expected) < 0.035,
                      String(format: "gain %.3f, expected %.3f", got, expected))
            }
            local.volume = 1
            local.soundCheckGain = SoundCheck.gain(energy: 250) // +12.04 dB, four times the samples.
            try await local.load(.local(first))
            try await local.play()
            let baseline = await level()
            check("off preserves the file's level", abs(baseline - 0.05 / sqrt(2)) < 0.002)
            local.isSoundCheckOn = true
            ratio("boost at full slider", await level(), baseline, 4)
            local.volume = 0.5
            ratio("boost with half slider", await level(), baseline, 2)
            local.volume = 0
            check("mute remains silent", await level() < 0.00001)
            local.volume = 1
            local.isSoundCheckOn = false
            ratio("toggle off during playback", await level(), baseline, 1)
            local.isSoundCheckOn = true
            local.pause()
            check("pause remains silent", await level() < 0.00001)
            local.seek(to: 2)
            try await local.play()
            ratio("seek and resume preserve gain", await level(), baseline, 4)
            await local.preload(second, soundCheckGain: 0.5)
            check("next file preloads", local.preloadedURL == second)
            local.soundCheckGain = 0.5
            try await local.load(.local(second))
            try await local.play()
            ratio("preloaded next file has its own attenuation", await level(), baseline, 0.5)
            local.stop()
            local.soundCheckGain = 2
            try await local.load(.local(first))
            try await local.play()
            ratio("fresh load after stop has its own boost", await level(), baseline, 2)
            local.stop()
            local.soundCheckGain = 32
            local.volume = 0.25
            try await local.load(.local(first))
            try await local.play()
            ratio("float headroom survives until the slider", await level(), baseline, 8)
        } catch {
            check("fixture playback", false, error.localizedDescription)
        }
    }

    private static func tone(_ url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) {
            let sample = Float(0.05 * sin(2 * .pi * 440 * Double(frame) / 48_000))
            buffer.floatChannelData![0][frame] = sample
            buffer.floatChannelData![1][frame] = sample
        }
        for _ in 0..<30 { try file.write(from: buffer) }
    }
}
