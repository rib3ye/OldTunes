import AVFoundation
import CoreAudio
import Foundation
import MusicKit
import os

/// OLDTUNES_PLAYBACK_MODE=tap — throwaway test for a visualizer: can OldTunes read the samples of a
/// playing cloud song? Cloud songs sound from Apple's RemotePlayerService process, not from OldTunes
/// (AudioProcessProbe), so this taps that process plus OldTunes itself with one Core Audio process
/// tap, the way a visualizer would. Plays one cloud song for about 10 s, then one local file for
/// about 5 s, and logs RMS, peak and the count of non-zero samples once a second.
///
/// The tap is muted: while it exists, the tapped processes send nothing to the speakers. Reading it
/// needs the "System Audio Recording Only" permission, and without it the tap hands over zeros and
/// no error, so the run also logs the permission as TCC's private preflight call reports it.
@available(macOS 14.2, *)
@MainActor
enum AudioTapBench {
    static let remoteBundleID = "com.apple.MediaPlayer.RemotePlayerService"
    static let cloudSeconds = 10
    static let localSeconds = 5

    static func run(_ loaded: PlaybackHarnessLibrary.Loaded) async {
        let me = ProcessInfo.processInfo.processIdentifier
        guard let cloud = loaded.clouds.first, let song = loaded.songs[cloud.id],
              let file = loaded.locals.min(by: { $0.duration < $1.duration })?.fileURL else {
            Log.error("TAP: needs one cloud song and one local file")
            return
        }
        let permissionAtStart = AudioCapturePermission.preflight()
        Log.info("TAP: OldTunes pid=\(me), permission \(AudioCapturePermission.describe(permissionAtStart)); "
                 + "RemotePlayerService before any MusicKit playback: \(remotes().map(describe))")
        askForPermissionIfNeeded(me, permissionAtStart)

        // Cloud. Prepared first, so the tap can exist (and mute) before the song makes a sound.
        let player = ApplicationMusicPlayer.shared
        player.state.shuffleMode = .off
        player.state.repeatMode = MusicPlayer.RepeatMode.none
        let queue = ApplicationMusicPlayer.Queue(for: [song])
        if #available(macOS 26.4, *) { queue.affectsListeningHistory = false }
        player.queue = queue
        do {
            try await withTimeout(20) { @MainActor in try await ApplicationMusicPlayer.shared.prepareToPlay() }
        } catch {
            Log.error("TAP: cloud song would not prepare: \(error)")
            return
        }
        var found = remotes()
        Log.info("TAP: after prepareToPlay, RemotePlayerService: \(found.map(describe))")
        var tap = found.isEmpty ? nil : ProcessTap.start(ours(found, me) + ownObject(me), label: "cloud + OldTunes")
        let cloudAt = mach_absolute_time()
        tap?.levels.arm(at: cloudAt)
        do {
            try await withTimeout(10) { @MainActor in try await ApplicationMusicPlayer.shared.play() }
        } catch {
            Log.error("TAP: cloud song would not play: \(error)")
            tap?.stop()
            return
        }
        if tap == nil {
            let deadline = Date().addingTimeInterval(5)
            while found.isEmpty, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(20))
                found = remotes()
            }
            Log.info("TAP: RemotePlayerService \(found.isEmpty ? "still missing 5 s" : "appeared \(millis(mach_absolute_time(), since: cloudAt)) ms") "
                     + "after play(): \(found.map(describe))")
            tap = found.isEmpty ? nil : ProcessTap.start(ours(found, me) + ownObject(me), label: "cloud + OldTunes")
            tap?.levels.arm(at: cloudAt)
        }
        guard let tap else {
            Log.error("TAP: no tap, giving up")
            player.stop()
            return
        }
        let started = Date()
        while player.playbackTime < 0.2, Date().timeIntervalSince(started) < 10 {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let cloudLevels = await measure("cloud", cloudSeconds, tap) {
            "MusicKit \(player.state.playbackStatus) at \(f(player.playbackTime)) s"
        }
        let cloudOnset = tap.levels.onset
        player.stop()
        try? await Task.sleep(for: .milliseconds(500))
        Log.info("TAP gap, the 0.5 s after stopping the cloud song: \(tap.levels.take().summary)")

        // Local, through the same tap: OldTunes plays files itself.
        let local = AVPlayer(url: file)
        let localAt = mach_absolute_time()
        tap.levels.arm(at: localAt)
        local.play()
        let localStarted = Date()
        while local.currentTime().seconds < 0.2, Date().timeIntervalSince(localStarted) < 5 {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let localFrom = local.currentTime().seconds
        let localLevels = await measure("local", localSeconds, tap) {
            "AVPlayer rate \(local.rate) at \(f(local.currentTime().seconds)) s"
        }
        let localTo = local.currentTime().seconds
        let localOnset = tap.levels.onset
        local.pause()
        try? await Task.sleep(for: .milliseconds(300))
        tap.stop()

        Log.info("TAP RESULT cloud: \(cloudLevels.summary)")
        Log.info("TAP RESULT local: \(localLevels.summary)")
        Log.info("TAP RESULT local, the file itself: \(fileLevels(file, from: localFrom, to: localTo))")
        Log.info("TAP RESULT first non-zero sample: cloud \(onset(cloudOnset, since: cloudAt)), local \(onset(localOnset, since: localAt)); "
                 + "\(tap.levels.startInfo); \(tap.setup)")
        Log.info("TAP RESULT permission: \(AudioCapturePermission.describe(permissionAtStart)) at start, "
                 + "\(AudioCapturePermission.describe(AudioCapturePermission.preflight())) at end")
    }

    /// Logs one line a second for `seconds` and returns the sum of those windows.
    static func measure(_ label: String, _ seconds: Int, _ tap: ProcessTap, status: () -> String) async -> TapLevels.Window {
        _ = tap.levels.take()
        var total = TapLevels.Window()
        for second in 1...seconds {
            try? await Task.sleep(for: .seconds(1))
            let window = tap.levels.take()
            total.add(window)
            Log.info("TAP \(label) +\(second) s: \(window.summary); \(status()); sending audio: \(AudioProcessProbe.processesRunningOutput())")
        }
        return total
    }

    /// Before any song plays: if macOS has not asked yet, a tap on OldTunes alone makes it ask now.
    /// On macOS 27 building that tap blocks until the prompt is answered. The preflight answer is
    /// cached inside the process, so re-reading it here would still say "not asked"; TCC's log has it.
    static func askForPermissionIfNeeded(_ me: pid_t, _ current: Int32?) {
        guard let current, current != 0, current != 1 else { return }
        let asked = Date()
        guard let tap = ProcessTap.start(ownObject(me), label: "OldTunes alone, to ask") else { return }
        Log.info("TAP: the asking tap took \(f(Date().timeIntervalSince(asked))) s to build")
        tap.stop()
    }

    static func remotes() -> [AudioProcessProbe.Client] {
        AudioProcessProbe.allProcesses().filter { $0.bundleID == remoteBundleID }
    }

    /// The instances serving this OldTunes; all of them if that can't be told.
    static func ours(_ found: [AudioProcessProbe.Client], _ me: pid_t) -> [AudioObjectID] {
        let serving = found.filter { responsiblePID($0.pid) == me }
        return (serving.isEmpty ? found : serving).map(\.object)
    }

    /// The file's own samples between two positions, decoded here, to compare with what the tap read.
    static func fileLevels(_ url: URL, from start: Double, to end: Double) -> String {
        guard let file = try? AVAudioFile(forReading: url) else { return "file unreadable by AVAudioFile" }
        let rate = file.processingFormat.sampleRate
        file.framePosition = AVAudioFramePosition(start * rate)
        let frames = AVAudioFrameCount(max(0, end - start) * rate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
              (try? file.read(into: buffer, frameCount: frames)) != nil, let channels = buffer.floatChannelData else {
            return "file samples unreadable"
        }
        var window = TapLevels.Window()
        for channel in 0..<Int(buffer.format.channelCount) {
            for sample in UnsafeBufferPointer(start: channels[channel], count: Int(buffer.frameLength)) {
                if sample != 0 { window.nonZero += 1 }
                window.sumSquares += Double(sample) * Double(sample)
                window.peak = max(window.peak, abs(sample))
            }
            window.samples += Int(buffer.frameLength)
        }
        window.frames = Int(buffer.frameLength)
        return "\(window.summary) (\(Int(rate)) Hz \(buffer.format.channelCount) ch, \(f(start))–\(f(end)) s)"
    }

    /// OldTunes's own process object, as a list so it adds onto the tapped processes.
    static func ownObject(_ me: pid_t) -> [AudioObjectID] {
        guard let own = AudioProcessProbe.allProcesses().first(where: { $0.pid == me }) else {
            Log.error("TAP: OldTunes is not in the HAL process list")
            return []
        }
        return [own.object]
    }

    /// A RemotePlayerService instance, with the app macOS holds responsible for it (its client).
    static func describe(_ c: AudioProcessProbe.Client) -> String {
        "\(c) object \(c.object) \(c.isRunningOutput ? "sending audio" : "quiet"), serving pid \(responsiblePID(c.pid).map(String.init) ?? "?")"
    }

    /// Activity Monitor's "responsible process", through a private libSystem call. Harness-only.
    static func responsiblePID(_ pid: pid_t) -> pid_t? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        typealias Responsible = @convention(c) (pid_t) -> pid_t
        let result = unsafeBitCast(symbol, to: Responsible.self)(pid)
        return result > 0 ? result : nil
    }

    static func onset(_ onset: TapLevels.Onset?, since: UInt64) -> String {
        guard let onset else { return "never" }
        return "\(millis(onset.sample, since: since)) ms after play() (handed to OldTunes at \(millis(onset.seen, since: since)) ms)"
    }

    static func f(_ x: Double) -> String { String(format: "%.2f", x) }
}

/// Milliseconds from one host time to another, signed, for the log.
private func millis(_ host: UInt64, since: UInt64) -> String {
    let nanos = host >= since ? Double(AudioConvertHostTimeToNanos(host - since)) : -Double(AudioConvertHostTimeToNanos(since - host))
    return String(format: "%.0f", nanos / 1e6)
}

/// One private, muted process tap inside a private aggregate device, read by an IOProc.
@available(macOS 14.2, *)
final class ProcessTap {
    let levels = TapLevels()
    /// What was built, for the log.
    private(set) var setup = ""
    private var tapID = ProcessTap.unknown
    private var deviceID = ProcessTap.unknown
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "com.noahtsutsui.oldtunes.tap", qos: .userInteractive)
    private static let unknown = AudioObjectID(kAudioObjectUnknown)

    /// Builds and starts a tap, or logs the step that failed and returns nil.
    static func start(_ processes: [AudioObjectID], label: String) -> ProcessTap? {
        let tap = ProcessTap()
        do {
            try tap.build(processes, label: label)
            Log.info("TAP: \(label): \(tap.setup)")
            return tap
        } catch {
            Log.error("TAP: \(label): \(error)")
            tap.stop()
            return nil
        }
    }

    private func build(_ processes: [AudioObjectID], label: String) throws {
        let began = mach_absolute_time()
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.name = "OldTunes tap test"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .muted
        try check("AudioHardwareCreateProcessTap", AudioHardwareCreateProcessTap(description, &tapID))
        let format = Self.read(tapID, kAudioTapPropertyFormat, AudioStreamBasicDescription())

        // The output device is the clock and the tap is the only input (AudioCap's recipe).
        guard let output = Self.read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, Self.unknown),
              let outputUID = Self.readString(output, kAudioDevicePropertyDeviceUID) else {
            throw TapError(step: "reading the default output device", status: 0)
        }
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "OldTunes tap test",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: 1]],
        ]
        try check("AudioHardwareCreateAggregateDevice", AudioHardwareCreateAggregateDevice(composition as CFDictionary, &deviceID))
        let levels = levels
        try check("AudioDeviceCreateIOProcIDWithBlock", AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue) { now, input, inputTime, output, _ in
            levels.record(input, now: now.pointee, inputTime: inputTime.pointee)
            // The output device's streams are part of the aggregate; keep them silent.
            for buffer in UnsafeMutableAudioBufferListPointer(output) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
        })
        levels.markStart(mach_absolute_time())
        try check("AudioDeviceStart", AudioDeviceStart(deviceID, procID))

        let rate = Self.read(deviceID, kAudioDevicePropertyNominalSampleRate, Float64(0)) ?? 0
        let frames = Self.read(deviceID, kAudioDevicePropertyBufferFrameSize, UInt32(0)) ?? 0
        let latency = Self.read(deviceID, kAudioDevicePropertyLatency, UInt32(0), scope: kAudioObjectPropertyScopeInput)
        let safety = Self.read(deviceID, kAudioDevicePropertySafetyOffset, UInt32(0), scope: kAudioObjectPropertyScopeInput)
        let bufferMs = rate > 0 ? String(format: "%.1f", Double(frames) / rate * 1000) : "?"
        setup = "tap \(tapID) on process objects \(processes), muted, private, format \(Self.describe(format)); "
            + "aggregate \(deviceID) clocked by \(Self.readString(output, kAudioObjectPropertyName) ?? outputUID), "
            + "\(frames) frames per buffer at \(Int(rate)) Hz (\(bufferMs) ms), input latency \(latency.map(String.init) ?? "?") "
            + "+ safety offset \(safety.map(String.init) ?? "?") frames; built in \(millis(mach_absolute_time(), since: began)) ms"
    }

    func stop() {
        if deviceID != Self.unknown {
            if let procID {
                AudioDeviceStop(deviceID, procID)
                AudioDeviceDestroyIOProcID(deviceID, procID)
            }
            AudioHardwareDestroyAggregateDevice(deviceID)
            deviceID = Self.unknown
        }
        procID = nil
        if tapID != Self.unknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = Self.unknown
        }
    }

    private func check(_ step: String, _ status: OSStatus) throws {
        guard status == noErr else { throw TapError(step: step, status: status) }
    }

    private static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutableBytes(of: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!) }
        return status == noErr ? value : nil
    }

    private static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func describe(_ format: AudioStreamBasicDescription?) -> String {
        guard let format else { return "unreadable" }
        let float = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        return "\(Int(format.mSampleRate)) Hz \(format.mChannelsPerFrame) ch \(format.mBitsPerChannel)-bit "
            + "\(float ? "float" : "integer") \(interleaved ? "interleaved" : "non-interleaved")"
    }
}

struct TapError: Error, CustomStringConvertible {
    var step: String
    var status: OSStatus
    var description: String {
        let bytes = withUnsafeBytes(of: UInt32(bitPattern: status).bigEndian, Array.init)
        let code = bytes.allSatisfy { (32...126).contains($0) } ? "'\(String(decoding: bytes, as: UTF8.self))' " : ""
        return "\(step) failed: \(code)(\(status))"
    }
}

/// What the IOProc measured, shared between the IO queue and the bench.
final class TapLevels: Sendable {
    struct Window: Sendable {
        var callbacks = 0
        var frames = 0
        var samples = 0
        var nonZero = 0
        var sumSquares = 0.0
        var peak: Float = 0
        /// Summed over callbacks: how old the buffer's first sample was when the IOProc ran.
        var lagNanos: UInt64 = 0

        mutating func add(_ other: Window) {
            callbacks += other.callbacks
            frames += other.frames
            samples += other.samples
            nonZero += other.nonZero
            sumSquares += other.sumSquares
            peak = max(peak, other.peak)
            lagNanos += other.lagNanos
        }

        var summary: String {
            let rms = samples > 0 ? (sumSquares / Double(samples)).squareRoot() : 0
            let lag = callbacks > 0 ? String(format: "%.1f ms", Double(lagNanos) / Double(callbacks) / 1e6) : "-"
            return "rms \(Self.db(rms)) dBFS, peak \(Self.db(Double(peak))) dBFS, non-zero \(nonZero)/\(samples) samples, "
                + "\(callbacks) callbacks, \(frames) frames, lag \(lag)"
        }

        static func db(_ x: Double) -> String { x > 0 ? String(format: "%.1f", 20 * log10(x)) : "-inf" }
    }

    /// The first non-zero sample after arm(at:): when it was rendered and when the IOProc saw it.
    struct Onset: Sendable {
        var sample: UInt64
        var seen: UInt64
    }

    private struct State: Sendable {
        var window = Window()
        var startedAt: UInt64 = 0
        var firstCallback: UInt64 = 0
        var layout = ""
        var armedAt: UInt64 = 0
        var onset: Onset?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Called on the IO queue for every buffer. Assumes float samples, which the setup line confirms.
    func record(_ input: UnsafePointer<AudioBufferList>, now: AudioTimeStamp, inputTime: AudioTimeStamp) {
        var window = Window()
        window.callbacks = 1
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        for (index, buffer) in buffers.enumerated() {
            guard let data = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size
            if index == 0 { window.frames = count / max(1, Int(buffer.mNumberChannels)) }
            for sample in UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float32.self), count: count) {
                if sample != 0 { window.nonZero += 1 }
                window.sumSquares += Double(sample) * Double(sample)
                window.peak = max(window.peak, abs(sample))
            }
            window.samples += count
        }
        if now.mFlags.contains(.hostTimeValid), inputTime.mFlags.contains(.hostTimeValid), now.mHostTime >= inputTime.mHostTime {
            window.lagNanos = AudioConvertHostTimeToNanos(now.mHostTime - inputTime.mHostTime)
        }
        let measured = window
        let sampleTime = inputTime.mHostTime
        let seen = mach_absolute_time()
        let first = state.withLock { $0.firstCallback == 0 }
        let layout = first ? "\(buffers.count) input buffer(s): " + buffers.map { "\($0.mNumberChannels) ch \($0.mDataByteSize) bytes" }.joined(separator: ", ") : ""
        state.withLock { s in
            s.window.add(measured)
            if s.firstCallback == 0 {
                s.firstCallback = seen
                s.layout = layout
            }
            if s.armedAt != 0, s.onset == nil, measured.nonZero > 0 { s.onset = Onset(sample: sampleTime, seen: seen) }
        }
    }

    func markStart(_ host: UInt64) { state.withLock { $0.startedAt = host } }

    /// Starts looking for the first non-zero sample from here.
    func arm(at host: UInt64) {
        state.withLock {
            $0.armedAt = host
            $0.onset = nil
        }
    }

    /// The measurements since the last take().
    func take() -> Window {
        state.withLock { s in
            defer { s.window = Window() }
            return s.window
        }
    }

    var onset: Onset? { state.withLock { $0.onset } }

    var startInfo: String {
        let s = state.withLock { $0 }
        guard s.firstCallback != 0 else { return "the IOProc never ran" }
        return "first IOProc call \(millis(s.firstCallback, since: s.startedAt)) ms after AudioDeviceStart, \(s.layout)"
    }
}

/// The "System Audio Recording Only" permission as TCC's private preflight call reports it, read the
/// way AudioCap reads it: 0 granted, 1 denied, anything else not asked yet. Harness-only: there is no
/// public API for it. nil when the call can't be found.
enum AudioCapturePermission {
    static func preflight() -> Int32? {
        guard let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW),
              let symbol = dlsym(tcc, "TCCAccessPreflight") else { return nil }
        typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
        return unsafeBitCast(symbol, to: Preflight.self)("kTCCServiceAudioCapture" as CFString, nil)
    }

    static func describe(_ raw: Int32?) -> String {
        switch raw {
        case nil: "unreadable"
        case 0?: "granted (0)"
        case 1?: "denied (1)"
        case let other?: "not asked yet (\(other))"
        }
    }
}
