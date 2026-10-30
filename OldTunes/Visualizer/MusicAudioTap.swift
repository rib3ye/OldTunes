import AppKit
import CoreAudio
import Foundation
import VisualizerCore

/// What the tap is doing, for the log, the silence watchdog and the bench.
struct TapStatus: Sendable, Equatable {
    var isRunning = false
    /// The processes the tap listens to: our own, plus our RemotePlayerService once MusicKit starts it
    /// (AudioHAL.ourRemotePlayers).
    var tapped: [AudioHAL.Process] = []
    var outputDevice = ""
    var outputIsAirPlay = false
    var format = ""
    var buildMilliseconds = 0.0
    var failure: String?
    /// What the HAL showed when the tap was built, for the log: how many audio processes it listed,
    /// which of the tapped processes and Apple's players were running output, and each
    /// RemotePlayerService left out because it was running before OldTunes started.
    var seen = ""

    var remotePlayerTapped: Bool { tapped.contains { $0.bundleID == AudioHAL.remotePlayerBundleID } }
}

/// What the visualizer hears the music with. VisualizerAudio picks one: MusicAudioTap, a process tap
/// that needs System Audio Recording, or SelfCapture, ScreenCaptureKit on OldTunes itself, which
/// needs no permission. Both write the same SampleRing.
@MainActor
protocol VisualizerEars: AnyObject {
    var ring: SampleRing { get }
    var status: TapStatus { get }
    /// How far behind the present the render loop reads the ring: about how late the newest sound
    /// arrives, so each step finds new sound rather than the last delivery again.
    var readDelay: TimeInterval { get }
    func start() async
    func stop()
    func rebuild(reason: String) async
}

@available(macOS 14.2, *)
extension MusicAudioTap: VisualizerEars {
    /// The IOProc writes each buffer within a few milliseconds of its time stamp.
    var readDelay: TimeInterval { 0 }
}

@available(macOS 14.4, *)
extension SelfCapture: VisualizerEars {
    /// Sound arrives in 20 ms buffers, 31–34 ms after it played on the median and 46–49 ms at worst
    /// in a run (SelfCapture). Past about 30 ms late, the newest sound is older than 50 ms for a few
    /// milliseconds before the next buffer lands, so now and then (buffers about 38 ms late or more)
    /// two steps read the same window. Reading further back would make the picture trail the sound
    /// by more, which is worse.
    var readDelay: TimeInterval { 0.05 }
}

/// The visualizer's ears: one Core Audio process tap on OldTunes itself (local files) and on the
/// RemotePlayerService that renders this OldTunes's cloud songs, inside a private aggregate device
/// clocked by the default output. The IOProc mixes to mono into a SampleRing. While CloudAudioRoute
/// plays cloud songs out from OldTunes itself, it taps OldTunes alone (`leavesOutRemotePlayer`).
///
/// Unmuted, so the music still plays; benches can mute it. Exists only while the visualizer is on.
/// The first tap ever built asks for "System Audio Recording Only", and on macOS 27 that call waits
/// for the answer, so it runs off the main thread. A denied permission gives zeros and no error; the
/// TapWatchdog notices that.
///
/// Rebuilds itself when the HAL's process list changes (RemotePlayerService appears, or comes back with
/// a new pid), when the default output device changes, when the aggregate dies, and after sleep.
@available(macOS 14.2, *)
@MainActor
final class MusicAudioTap {
    let ring: SampleRing
    let muted: Bool
    private(set) var status = TapStatus()
    /// Called after every build or teardown, with the reason.
    var onStatusChange: ((TapStatus, String) -> Void)?
    /// While CloudAudioRoute plays cloud songs out from OldTunes itself, OldTunes's own output already
    /// carries them, after the volume slider, and RemotePlayerService's is the same song a second time,
    /// 25 ms earlier: leave it out then. VisualizerAudio keeps this in step with the route and rebuilds.
    var leavesOutRemotePlayer = false

    private var tapID = AudioHAL.unknown
    private var aggregateID = AudioHAL.unknown
    private var procID: AudioDeviceIOProcID?
    private var wanted = false
    /// Bumped by every start and stop, so a build that finishes late knows it was overtaken.
    private var generation = 0
    /// The generation of the build in flight, if one is, so a second start doesn't make a second tap.
    private var building: Int?
    private var listeners: [Listener] = []
    private let listenerContext = TapListenerContext()
    private var wakeObserver: NSObjectProtocol?
    private var pendingRebuild: Task<Void, Never>?
    private let ioQueue = DispatchQueue(label: "com.noahtsutsui.oldtunes.visualizer.tap", qos: .userInteractive)

    private struct Listener {
        var object: AudioObjectID
        var address: AudioObjectPropertyAddress
    }

    init(ring: SampleRing, muted: Bool = false) {
        self.ring = ring
        self.muted = muted
        listenerContext.tap = self
    }

    /// Builds the tap if it isn't running. Returns once it is running or has failed.
    func start() async {
        wanted = true
        installListeners()
        if status.isRunning || building == generation { return }
        await build(reason: "start")
    }

    /// Takes everything down: the IOProc, the aggregate, the tap and the listeners.
    func stop() {
        wanted = false
        generation += 1
        pendingRebuild?.cancel()
        pendingRebuild = nil
        removeListeners()
        teardown()
        report("stop")
    }

    /// Tears down and builds again, for the watchdog and the HAL listeners.
    func rebuild(reason: String) async {
        guard wanted else { return }
        generation += 1
        teardown()
        await build(reason: reason)
    }

    // MARK: - Building

    /// The processes to tap: ourselves, plus every RemotePlayerService that plays for this OldTunes
    /// (AudioHAL.ourRemotePlayers) unless `includingRemotePlayer` is false. `seen` describes the rest
    /// for the log (see `TapStatus.seen`).
    nonisolated static func targets(includingRemotePlayer: Bool = true) -> (processes: [AudioHAL.Process], seen: String) {
        let me = ProcessInfo.processInfo.processIdentifier
        let listed = AudioHAL.processes()
        var chosen: [AudioHAL.Process] = []
        if let own = AudioHAL.processObject(pid: me) { chosen.append(AudioHAL.process(own)) }
        guard includingRemotePlayer else {
            return (chosen, "\(listed.count) audio processes listed; "
                    + "RemotePlayerService left out: OldTunes plays its cloud songs out itself (CloudAudioRoute)")
        }
        let remotes = listed.filter { $0.bundleID == AudioHAL.remotePlayerBundleID }
        let ours = AudioHAL.ourRemotePlayers(remotes)
        let playing = (chosen + remotes).filter(\.isRunningOutput).map(\.description)
        var seen = "\(listed.count) audio processes listed; running output: "
            + (playing.isEmpty ? "none of ours or Apple's players" : playing.joined(separator: ", "))
        let others = remotes.filter { !ours.contains($0) }
        if !others.isEmpty {
            seen += "; running before OldTunes started, so not ours: " + others.map(\.description).joined(separator: ", ")
        }
        return (chosen + ours, seen)
    }

    private func build(reason: String) async {
        let gen = generation
        building = gen
        defer { if building == gen { building = nil } }
        let began = HostClock.now
        let targets = Self.targets(includingRemotePlayer: !leavesOutRemotePlayer)
        guard !targets.processes.isEmpty else {
            fail("no audio process to tap (OldTunes is not in the HAL's process list)", reason: reason)
            return
        }
        let uuid = UUID()
        let created = await Self.createTap(targets.processes.map(\.object), uuid: uuid, muted: muted)
        guard gen == generation, wanted else {
            if case .success(let late) = created { AudioHardwareDestroyProcessTap(late) }
            return
        }
        switch created {
        case .failure(let failure): fail(failure.description, reason: reason); return
        case .success(let id): tapID = id
        }

        guard let output = AudioHAL.defaultOutputDevice(), let outputUID = AudioHAL.deviceUID(output) else {
            teardown()
            fail("no default output device", reason: reason)
            return
        }
        // The tap is the aggregate's only input besides any inputs the output device has itself.
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "OldTunes visualizer",
            kAudioAggregateDeviceUIDKey: "com.noahtsutsui.oldtunes.visualizer." + uuid.uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: uuid.uuidString, kAudioSubTapDriftCompensationKey: 1]],
        ]
        var aggregate = AudioHAL.unknown
        let made = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate)
        guard made == noErr else {
            teardown()
            fail("creating the aggregate device failed: \(AudioHAL.describe(made))", reason: reason)
            return
        }
        aggregateID = aggregate

        let rate = AudioHAL.read(aggregate, kAudioDevicePropertyNominalSampleRate, Float64(0)) ?? 48_000
        let tapBuffer = AudioHAL.inputBufferCount(output)
        let format = AudioHAL.read(tapID, kAudioTapPropertyFormat, AudioStreamBasicDescription())
        var proc: AudioDeviceIOProcID?
        let block = Self.ioBlock(ring: ring, tapBuffer: tapBuffer, sampleRate: rate)
        let created2 = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, ioQueue, block)
        guard created2 == noErr, let proc else {
            teardown()
            fail("creating the IOProc failed: \(AudioHAL.describe(created2))", reason: reason)
            return
        }
        procID = proc
        let started = AudioDeviceStart(aggregate, proc)
        guard started == noErr else {
            teardown()
            fail("starting the aggregate device failed: \(AudioHAL.describe(started))", reason: reason)
            return
        }
        listen(to: aggregate, kAudioDevicePropertyDeviceIsAlive)

        status = TapStatus(isRunning: true, tapped: targets.processes,
                           outputDevice: AudioHAL.name(output) ?? outputUID, outputIsAirPlay: AudioHAL.isAirPlay(output),
                           format: Self.describe(format, rate: rate, tapBuffer: tapBuffer),
                           buildMilliseconds: HostClock.seconds(HostClock.now - began) * 1000, failure: nil,
                           seen: targets.seen)
        report(reason)
    }

    /// Makes the tap off the main thread: the first one ever waits for the permission prompt.
    nonisolated private static func createTap(_ processes: [AudioObjectID], uuid: UUID, muted: Bool) async -> Result<AudioObjectID, TapFailure> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let description = CATapDescription(stereoMixdownOfProcesses: processes)
                description.name = "OldTunes visualizer"
                description.uuid = uuid
                description.isPrivate = true
                description.muteBehavior = muted ? .muted : .unmuted
                var id = AudioHAL.unknown
                let status = AudioHardwareCreateProcessTap(description, &id)
                continuation.resume(returning: status == noErr && id != AudioHAL.unknown
                                    ? .success(id) : .failure(TapFailure("creating the process tap failed: \(AudioHAL.describe(status))")))
            }
        }
    }

    /// The IOProc. Made outside the main actor, so Swift doesn't tie it to the main thread. It only
    /// copies samples into the ring and silences the aggregate's own output.
    nonisolated private static func ioBlock(ring: SampleRing, tapBuffer: Int, sampleRate: Double) -> AudioDeviceIOBlock {
        { _, input, inputTime, output, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            let host = inputTime.pointee.mFlags.contains(.hostTimeValid) ? inputTime.pointee.mHostTime : mach_absolute_time()
            if buffers.count - tapBuffer >= 2, buffers[tapBuffer].mNumberChannels == 1,
               let left = buffers[tapBuffer].mData, let right = buffers[tapBuffer + 1].mData {
                // Non-interleaved: one buffer per channel.
                let frames = Int(buffers[tapBuffer].mDataByteSize) / MemoryLayout<Float>.size
                ring.writePlanarStereo(left: left.assumingMemoryBound(to: Float.self), right: right.assumingMemoryBound(to: Float.self),
                                       frames: frames, firstFrameHostTime: host, sampleRate: sampleRate)
            } else if tapBuffer < buffers.count, let data = buffers[tapBuffer].mData {
                let channels = max(1, Int(buffers[tapBuffer].mNumberChannels))
                let frames = Int(buffers[tapBuffer].mDataByteSize) / (MemoryLayout<Float>.size * channels)
                ring.writeInterleaved(data.assumingMemoryBound(to: Float.self), frames: frames, channels: channels, gain: 1,
                                      firstFrameHostTime: host, sampleRate: sampleRate)
            }
            for buffer in UnsafeMutableAudioBufferListPointer(output) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
        }
    }

    private func teardown() {
        if aggregateID != AudioHAL.unknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            unlisten(aggregateID)
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioHAL.unknown
        }
        procID = nil
        if tapID != AudioHAL.unknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioHAL.unknown
        }
        status.isRunning = false
    }

    private func fail(_ message: String, reason: String) {
        status = TapStatus(failure: message)
        report(reason)
    }

    private func report(_ reason: String) {
        if let failure = status.failure {
            Log.error("visualizer: tap \(reason): \(failure)")
        } else if status.isRunning {
            Log.info("visualizer: tap \(reason): \(status.tapped) "
                     + "on \(status.outputDevice)\(status.outputIsAirPlay ? " (AirPlay)" : ""), \(status.format), "
                     + "\(muted ? "muted, " : "")built in \(String(format: "%.0f", status.buildMilliseconds)) ms; \(status.seen)")
        } else {
            Log.info("visualizer: tap \(reason)")
        }
        onStatusChange?(status, reason)
    }

    nonisolated private static func describe(_ format: AudioStreamBasicDescription?, rate: Double, tapBuffer: Int) -> String {
        guard let format else { return "format unreadable, \(Int(rate)) Hz" }
        let float = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        return "\(Int(format.mSampleRate)) Hz \(format.mChannelsPerFrame) ch \(format.mBitsPerChannel)-bit "
            + "\(float ? "float" : "integer") \(interleaved ? "interleaved" : "non-interleaved"), device \(Int(rate)) Hz"
            + (tapBuffer > 0 ? ", tap after \(tapBuffer) device input buffer(s)" : "")
    }

    // MARK: - Watching the HAL

    private func installListeners() {
        guard listeners.isEmpty else { return }
        listen(to: AudioHAL.system, kAudioHardwarePropertyProcessObjectList)
        listen(to: AudioHAL.system, kAudioHardwarePropertyDefaultOutputDevice)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                                         queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRebuild("wake from sleep", after: .seconds(1)) }
        }
    }

    private func removeListeners() {
        for listener in listeners { remove(listener) }
        listeners.removeAll()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    private func listen(to object: AudioObjectID, _ selector: AudioObjectPropertySelector) {
        var address = AudioHAL.address(selector)
        let status = AudioObjectAddPropertyListener(object, &address, visualizerTapListener, listenerContext.pointer)
        guard status == noErr else {
            Log.error("visualizer: watching HAL property \(AudioHAL.describe(OSStatus(bitPattern: selector))) failed: \(AudioHAL.describe(status))")
            return
        }
        listeners.append(Listener(object: object, address: address))
    }

    private func unlisten(_ object: AudioObjectID) {
        listeners.removeAll { listener in
            guard listener.object == object else { return false }
            remove(listener)
            return true
        }
    }

    private func remove(_ listener: Listener) {
        var address = listener.address
        let status = AudioObjectRemovePropertyListener(listener.object, &address, visualizerTapListener, listenerContext.pointer)
        if status != noErr, status != kAudioHardwareBadObjectError {
            Log.error("visualizer: unwatching HAL property \(AudioHAL.describe(OSStatus(bitPattern: address.mSelector))) failed: \(AudioHAL.describe(status))")
        }
    }

    fileprivate func halChanged(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) {
        guard wanted else { return }
        switch selector {
        case kAudioHardwarePropertyProcessObjectList:
            // Rebuild only if the set we should tap has changed (another app starting doesn't count).
            let now = Set(Self.targets(includingRemotePlayer: !leavesOutRemotePlayer).processes.map(\.object))
            if now != Set(status.tapped.map(\.object)) { scheduleRebuild("audio processes changed", after: .milliseconds(250)) }
        case kAudioHardwarePropertyDefaultOutputDevice:
            scheduleRebuild("default output device changed", after: .milliseconds(250))
        case kAudioDevicePropertyDeviceIsAlive:
            // Only the aggregate in use, and only if it really died: a late notice about one this tap
            // already destroyed must not start another rebuild.
            guard object == aggregateID, (AudioHAL.read(object, selector, UInt32(1)) ?? 0) == 0 else { return }
            scheduleRebuild("aggregate device died", after: .milliseconds(250))
        default:
            break
        }
    }

    /// Coalesces bursts of HAL notifications into one rebuild.
    private func scheduleRebuild(_ reason: String, after delay: Duration) {
        pendingRebuild?.cancel()
        pendingRebuild = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await self.rebuild(reason: reason)
        }
    }
}

/// What the HAL listener finds the tap through. Core Audio holds it unretained; the tap keeps it alive.
@available(macOS 14.2, *)
@MainActor
final class TapListenerContext {
    weak var tap: MusicAudioTap?
    nonisolated var pointer: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }
}

/// Core Audio calls this on its own thread for each watched property; it hops to the main actor.
/// A plain function, not a block: removing a listener needs the very pointer that added it, and Swift
/// makes a new block every time it passes a closure.
@available(macOS 14.2, *)
private func visualizerTapListener(_ object: AudioObjectID, _ count: UInt32,
                                   _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
                                   _ clientData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let clientData else { return noErr }
    let context = Unmanaged<TapListenerContext>.fromOpaque(clientData).takeUnretainedValue()
    let selectors = (0..<Int(count)).map { addresses[$0].mSelector }
    Task { @MainActor in
        for selector in selectors { context.tap?.halChanged(object, selector) }
    }
    return noErr
}

struct TapFailure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}
