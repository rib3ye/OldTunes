import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import os
import Security

/// Whether OldTunes has the "System Audio Recording Only" permission, found by trying it, with
/// public API only. macOS has no call that just reports it (developer.apple.com/forums/thread/756783);
/// TCC's preflight, which OldTunes asked before, is private, and App Review rejects apps that use it.
///
/// OldTunes plays a 660 Hz tone at −60 dBFS for 200 ms through an audio engine of its own and taps
/// its own process, muted, while the tone plays. A tap without the permission reads exact zeros and
/// reports no error, so any sample that comes through means the permission is on. The tap mutes the
/// tone, which would be too quiet to hear anyway.
///
/// While the tap is read, everything OldTunes plays is muted, CloudAudioRoute's output included. So
/// the probe runs only when that output is silent anyway: before an iCloud song starts, and when the
/// route has heard only silence.
///
/// The first tap a Mac sees shows the permission prompt and waits for the answer, so the probe runs
/// off the main thread and takes as long as the person does. Otherwise it answers "granted" in
/// about 100 ms and "denied" in about 0.9 s (measured October 28, 2026).
enum SystemAudioProbe {
    enum Answer: String, Sendable {
        /// The tone came through the tap.
        case granted
        /// The tap read only zeros.
        case denied
        /// The probe couldn't run: no output device, or the engine, tap or aggregate device failed.
        case untested
    }

    /// What the probe found at an earlier launch's first iCloud song, granted or denied; nil if it
    /// never ran. A guess for whoever needs one before this launch's probe has run: the visualizer,
    /// which mustn't be what raises the prompt (VisualizerAudio). It can be out of date if the
    /// permission was changed since.
    ///
    /// Kept with the certificate this copy is signed with, and nil for a copy signed with another: a
    /// Debug build and the installed app share these settings, but macOS keeps the permission per
    /// signing certificate, and they are signed differently (Apple Development and Developer ID).
    static var lastAnswer: Answer? {
        get {
            guard let saved = UserDefaults.standard.dictionary(forKey: lastAnswerKey),
                  saved["signer"] as? String == signer else { return nil }
            return (saved["answer"] as? String).flatMap(Answer.init(rawValue:))
        }
        set {
            let saved = newValue.map { ["answer": $0.rawValue, "signer": signer] }
            UserDefaults.standard.set(saved, forKey: lastAnswerKey)
        }
    }
    private static let lastAnswerKey = "OldTunes.systemAudioRecording"

    /// The name on this copy's signing certificate ("Developer ID Application: …"), or its path if it
    /// has none (signed ad hoc).
    private static let signer: String = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let certificates = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first, let name = SecCertificateCopySubjectSummary(leaf) as String? else {
            return Bundle.main.bundlePath
        }
        return name
    }()

    private static let toneHertz = 660.0
    private static let toneSeconds = 0.2
    /// −60 dBFS.
    private static let toneLevel: Float = 0.001
    /// How long to wait for the tone once it is scheduled: its own 200 ms, plus the engine's and the
    /// tap's buffers, with room for a slow output device.
    private static let listenFor: Duration = .milliseconds(800)

    /// Logs one line with the answer and how long it took. `simulatingMissingPermission` (harness
    /// only) takes every tapped sample for silence, as without the permission.
    static func run(simulatingMissingPermission simulated: Bool = false) async -> Answer {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: test(simulated: simulated))
            }
        }
    }

    private static func test(simulated: Bool) -> Answer {
        guard #available(macOS 14.2, *) else { return untested("process taps need macOS 14.2") }
        let began = ContinuousClock.now
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        var tap = HAL.unknown
        var aggregate = HAL.unknown
        var proc: AudioDeviceIOProcID?
        defer {
            player.stop()
            engine.stop()
            // After the engine, so the rest of the tone stays muted.
            if let proc {
                AudioDeviceStop(aggregate, proc)
                AudioDeviceDestroyIOProcID(aggregate, proc)
            }
            if aggregate != HAL.unknown { AudioHardwareDestroyAggregateDevice(aggregate) }
            if tap != HAL.unknown { AudioHardwareDestroyProcessTap(tap) }
        }

        engine.attach(player)
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate > 0 ? rate : 48_000, channels: 1),
              let tone = makeTone(format) else { return untested("no format for the tone") }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            // Output only, so no microphone prompt.
            try engine.start()
        } catch {
            return untested("the engine wouldn't start: \(error)")
        }
        // Playing silence is enough for OldTunes to have a process object to tap.
        player.play()
        var me = HAL.unknown
        for _ in 0..<40 where me == HAL.unknown {
            me = HAL.processObject(getpid())
            if me == HAL.unknown { Thread.sleep(forTimeInterval: 0.005) }
        }
        guard me != HAL.unknown else { return untested("OldTunes has no audio process object") }

        let description = CATapDescription(stereoMixdownOfProcesses: [me])
        description.name = "OldTunes permission probe"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        let asking = ContinuousClock.now
        let made = AudioHardwareCreateProcessTap(description, &tap)
        guard made == noErr, tap != HAL.unknown else { return untested("making the tap failed: \(HAL.describe(made))") }
        // A developer reports that without the permission, writing a tap's description back fails
        // with kAudioDevicePermissionsError. Apple hasn't confirmed it, and only the permission-on
        // side could be tested here (PermissionBench: noErr, October 28, 2026). So it only ever
        // answers "denied" sooner; anything else goes on to the tone.
        if !simulated, writeBack(description, to: tap) == kAudioDevicePermissionsError {
            let total = ms(began.duration(to: .now))
            Log.info("system audio probe: denied; the tap refused its own description back ('hog!') (\(total) ms in all)")
            return .denied
        }

        guard let output = HAL.defaultOutputDevice(), let uid = HAL.deviceUID(output) else {
            return untested("no default output device")
        }
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "OldTunes permission probe",
            kAudioAggregateDeviceUIDKey: "com.noahtsutsui.oldtunes.probe." + description.uuid.uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: uid,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        let aggregated = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate)
        guard aggregated == noErr else { return untested("making the aggregate device failed: \(HAL.describe(aggregated))") }
        let heard = OSAllocatedUnfairLock(initialState: false)
        let created = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, nil, listenBlock(heard: heard, tapBuffer: HAL.inputBufferCount(output)))
        guard created == noErr, proc != nil else { return untested("making the IOProc failed: \(HAL.describe(created))") }
        let started = AudioDeviceStart(aggregate, proc)
        guard started == noErr else { return untested("starting the aggregate device failed: \(HAL.describe(started))") }
        // Long only when the tap waited for the permission prompt.
        let asked = ms(asking.duration(to: .now))

        // The tap is read from here on, so OldTunes is muted before the tone starts.
        player.scheduleBuffer(tone, completionHandler: nil)
        let toneAt = ContinuousClock.now
        var heardAfter: Duration?
        while heardAfter == nil, toneAt.duration(to: .now) < listenFor {
            if !simulated, heard.withLock({ $0 }) {
                heardAfter = toneAt.duration(to: .now)
            } else {
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        let total = ms(began.duration(to: .now))
        let wait = asked > 500 ? ", \(asked) ms of it waiting for the tap (the permission prompt)" : ""
        if let heardAfter {
            Log.info("system audio probe: granted; the tap heard the tone \(ms(heardAfter)) ms after it started (\(total) ms in all\(wait))")
            return .granted
        }
        Log.info("system audio probe: denied; the tap heard only silence for \(ms(listenFor)) ms of tone"
                 + "\(simulated ? " (simulated)" : "") (\(total) ms in all\(wait))")
        return .denied
    }

    /// Made outside any actor, so Swift doesn't tie the block to one. Watches only the tap's buffers,
    /// never the output device's own inputs (a microphone would hear the room), and writes silence.
    private static func listenBlock(heard: OSAllocatedUnfairLock<Bool>, tapBuffer: Int) -> AudioDeviceIOBlock {
        { _, input, _, output, _ in
            let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            var found = false
            if tapBuffer < ins.count {
                for buffer in ins[tapBuffer...] where !found {
                    guard let data = buffer.mData else { continue }
                    let samples = data.assumingMemoryBound(to: Float.self)
                    for i in 0..<Int(buffer.mDataByteSize) / MemoryLayout<Float>.size where samples[i] != 0 {
                        found = true
                        break
                    }
                }
            }
            for buffer in UnsafeMutableAudioBufferListPointer(output) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            if found { heard.withLock { $0 = true } }
        }
    }

    /// Writes `description` to the tap's kAudioTapPropertyDescription; PermissionBench uses it too.
    @available(macOS 14.2, *)
    static func writeBack(_ description: CATapDescription, to tap: AudioObjectID) -> OSStatus {
        var address = HAL.address(kAudioTapPropertyDescription)
        var value = description
        return withUnsafeMutablePointer(to: &value) {
            AudioObjectSetPropertyData(tap, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
        }
    }

    private static func makeTone(_ format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(format.sampleRate * toneSeconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            samples[i] = toneLevel * Float(sin(2 * Double.pi * toneHertz * Double(i) / format.sampleRate))
        }
        return buffer
    }

    private static func untested(_ why: String) -> Answer {
        Log.error("system audio probe: couldn't test System Audio Recording: \(why)")
        return .untested
    }

    private static func ms(_ duration: Duration) -> Int {
        Int(Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15)
    }
}
