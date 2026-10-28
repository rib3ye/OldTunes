import AppKit
import AudioToolbox
import CoreAudio
import Foundation
import os

/// OldTunes's own volume and Sound Check for iCloud songs.
///
/// MusicKit plays iCloud songs in Apple's RemotePlayerService process and gives OldTunes no volume
/// for them (RESEARCH.md row 5). So a Core Audio process tap takes that process's sound away from
/// the speakers, and one IOProc on a private aggregate device plays it out again on the same output
/// device, times the gain: the volume slider, times the song's Sound Check gain when Sound Check is
/// on. The IOProc reads the tap and writes the speakers in the same callback, on the output device's
/// own clock. Measured on October 20, 2026: the song comes out 25 ms later than directly, at exactly
/// the gain in every octave band; the tap's drift compensation moves its timing by a few
/// microseconds at most.
///
/// It fails open. The tap mutes RemotePlayerService only while the IOProc is reading it
/// (`.mutedWhenTapped`), so a route that stops for any reason lets the song play directly again,
/// at its own level, rather than not at all.
///
/// The tap needs "System Audio Recording Only". Without it a tap reads zeros and reports no error,
/// which would leave the song silent. CloudTransport makes no route when SystemAudioProbe found the
/// permission off at the first iCloud song. And a route that has heard only silence after its song
/// has played for 1.5 s runs the probe again: if the probe hears its tone, the song is just quiet
/// and stays routed; if not, the route goes back to only listening, with RemotePlayerService
/// unmuted, and routes again from the next song once it has heard sound. The first tap a Mac sees
/// asks for the permission and waits for the answer, so taps are made off the main thread.
///
/// Rebuilds itself when the default output device changes (headphones in or out), when its
/// aggregate device dies, and after sleep.
@MainActor
final class CloudAudioRoute {
    enum Mode: String, Sendable {
        /// Nothing built.
        case off
        /// RemotePlayerService muted, its sound played out again times the gain.
        case routing
        /// Tapped but not muted, waiting to hear sound before routing again.
        case listening
    }

    private(set) var mode: Mode = .off
    /// What the song is played out at, as a factor: the volume slider times any Sound Check gain.
    /// A change ramps over one IO buffer.
    var gain: Float = 1 { didSet { io.setGain(gain) } }
    /// Harness only: the IOProc takes every tapped sample for silence, as for a song that opens
    /// quietly. SystemAudioProbe still hears its tone.
    var simulatesSilentTap: Bool {
        get { io.simulatesSilence }
        set { io.simulatesSilence = newValue }
    }
    /// Harness only: the IOProc and SystemAudioProbe both hear only silence, as without the System
    /// Audio Recording permission.
    var simulatesMissingPermission = false {
        didSet { simulatesSilentTap = simulatesMissingPermission }
    }
    /// What the route is doing, for the harness.
    var isRunning: Bool { procID != nil && running }
    var outputDeviceName: String { deviceName }
    /// Buffers the IOProc has handled, and whether it has heard sound this song, for the harness.
    var stats: RouteIO.Stats { io.stats }

    /// Song time played since start(), counted only while it moves forward normally, so a seek
    /// doesn't count as listening.
    private var playedSinceStart: TimeInterval = 0
    private var lastPosition: TimeInterval?
    private static let listenBeforeChecking: TimeInterval = 1.5
    /// Counts start()s, so a probe that answers after its song has ended doesn't speak for the next.
    private var song = 0
    /// True while SystemAudioProbe checks this song's silence.
    private var checking = false
    /// The probe heard its tone during this song: its silence is the song's own.
    private var silenceIsQuiet = false
    /// What the last silence check found, for the harness.
    private(set) var lastSilenceCheck: SystemAudioProbe.Answer?

    private let io = RouteIO()
    private var tapID = HAL.unknown
    private var tappedProcess = HAL.unknown
    private var aggregateID = HAL.unknown
    private var procID: AudioDeviceIOProcID?
    private var deviceUID = ""
    private var deviceName = ""
    private var running = false
    /// True between start() and pause(): the IOProc should be running.
    private var wanted = false
    private var generation = 0
    private var buildTask: Task<Void, Never>?
    private var listeners: [Listener] = []
    private let listenerContext = RouteListenerContext()
    private var wakeObserver: NSObjectProtocol?
    private var pendingRebuild: Task<Void, Never>?

    private struct Listener {
        var object: AudioObjectID
        var address: AudioObjectPropertyAddress
    }

    init() {
        listenerContext.route = self
    }

    // MARK: - Driven by CloudTransport

    /// A song is loaded and about to play: make sure the route taps this OldTunes's own
    /// RemotePlayerService on the current default output, and run it. Returns once it runs, or once
    /// it has failed. Only the very first tap on a Mac takes long: that one waits for the permission.
    func start() async {
        wanted = true
        installListeners()
        // A listening route that heard the last song has its permission: route again.
        let heard = io.takeHeard()
        let want: Mode = mode == .listening && !heard ? .listening : .routing
        if mode == .listening, heard {
            Log.info("cloud route: heard the last song through the tap; routing again")
        }
        guard let target = HAL.ourRemotePlayer() else {
            Log.error("cloud route: no RemotePlayerService of this OldTunes to tap; this song plays at its own level")
            return
        }
        let device = HAL.defaultOutputDevice().flatMap(HAL.deviceUID) ?? ""
        if tappedProcess != target || deviceUID != device || procID == nil || mode != want {
            await rebuild(want, reason: "a song starts")
        } else if let buildTask {
            await buildTask.value
        }
        playedSinceStart = 0
        lastPosition = nil
        song += 1
        silenceIsQuiet = false
        guard wanted else { return }
        startIO()
    }

    /// No song loaded: stop the IOProc, which also unmutes RemotePlayerService. Keeps the tap.
    func pause() {
        wanted = false
        stopIO()
    }

    /// CloudTransport's 10 Hz tick. A routing tap that has heard nothing while the song played on
    /// for 1.5 s may lack the permission, or the song may open quietly. SystemAudioProbe tells
    /// which: the song stays routed if the probe hears its tone, and otherwise the route unmutes and
    /// listens instead.
    func watch(playing: Bool, position: TimeInterval) {
        defer { lastPosition = position }
        guard mode == .routing, running, playing, !checking, !silenceIsQuiet, let last = lastPosition else { return }
        let step = position - last
        if step > 0, step < 0.5 { playedSinceStart += step }
        guard playedSinceStart >= Self.listenBeforeChecking, !io.hasHeard else { return }
        checking = true
        let silent = String(format: "%.1f", playedSinceStart)
        let thisSong = song
        let simulated = simulatesMissingPermission
        Task {
            let answer = await SystemAudioProbe.run(simulatingMissingPermission: simulated)
            checking = false
            lastSilenceCheck = answer
            // The song's own sound may have come through meanwhile, or the song may have ended.
            guard mode == .routing, wanted, !io.hasHeard else { return }
            if answer == .granted {
                if thisSong == song { silenceIsQuiet = true }
                Log.info("cloud route: the tap heard only silence for \(silent) s of playing, but System Audio Recording "
                         + "is on (the probe heard its tone), so the song is just quiet; it stays routed")
                return
            }
            Log.error("cloud route: the tap heard only silence for \(silent) s of playing, and so did the probe "
                      + "(\(answer.rawValue)): System Audio Recording looks off for OldTunes. iCloud songs play at their own level, "
                      + "with the volume slider greyed out, until the tap hears sound.")
            mode = .listening
            await rebuild(.listening, reason: "no sound through the tap")
        }
    }

    /// Harness only: builds everything again, the way a change of default output device does.
    func rebuildAsAfterDeviceChange() async {
        guard mode != .off else { return }
        await rebuild(mode, reason: "the harness asked, as after a device change")
    }

    // MARK: - Building

    private func rebuild(_ want: Mode, reason: String) async {
        generation += 1
        let gen = generation
        let task = Task { [weak self] in
            guard let self else { return }
            await self.build(want, generation: gen, reason: reason)
        }
        buildTask = task
        await task.value
        if generation == gen { buildTask = nil }
    }

    private func build(_ want: Mode, generation gen: Int, reason: String) async {
        guard #available(macOS 14.2, *) else {
            Log.error("cloud route: process taps need macOS 14.2; iCloud songs play at their own level")
            return
        }
        let wasRunning = running
        teardown()
        guard let target = HAL.ourRemotePlayer() else {
            Log.error("cloud route: no RemotePlayerService of this OldTunes to tap (\(reason))")
            return
        }
        let began = ContinuousClock.now
        let uuid = UUID()
        let created = await Self.createTap(target, uuid: uuid, muted: want == .routing)
        guard gen == generation else {
            if case .success(let late) = created { AudioHardwareDestroyProcessTap(late) }
            return
        }
        guard case .success(let tap) = created else {
            if case .failure(let failure) = created { Log.error("cloud route: \(failure) (\(reason)); songs play at their own level") }
            return
        }
        tapID = tap
        tappedProcess = target
        guard let output = HAL.defaultOutputDevice(), let uid = HAL.deviceUID(output) else {
            teardown()
            Log.error("cloud route: no default output device (\(reason))")
            return
        }
        // Drift compensation stays on even though RemotePlayerService plays to this same device:
        // without it the tap and the device's IO slip against each other, which measured as
        // dropouts on October 20 (correlation with Music fell from 0.999 to 0.95).
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "OldTunes cloud route",
            kAudioAggregateDeviceUIDKey: "com.noahtsutsui.oldtunes.cloudroute." + uuid.uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: uid,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: uuid.uuidString, kAudioSubTapDriftCompensationKey: 1]],
        ]
        var aggregate = HAL.unknown
        let made = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate)
        guard made == noErr else {
            teardown()
            Log.error("cloud route: making the aggregate device failed: \(HAL.describe(made)) (\(reason))")
            return
        }
        aggregateID = aggregate
        var proc: AudioDeviceIOProcID?
        let block = Self.ioBlock(io: io, tapBuffer: HAL.inputBufferCount(output))
        // No queue: the block runs on the device's own real-time IO thread, which a song being
        // played out needs (a queue would add a thread hop to every buffer).
        let createdProc = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, nil, block)
        guard createdProc == noErr, let proc else {
            teardown()
            Log.error("cloud route: making the IOProc failed: \(HAL.describe(createdProc)) (\(reason))")
            return
        }
        procID = proc
        listen(to: aggregate, kAudioDevicePropertyDeviceIsAlive)
        deviceUID = uid
        deviceName = HAL.name(output) ?? uid
        mode = want
        io.setReemit(want == .routing)
        let elapsed = ContinuousClock.now - began
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        Log.info("cloud route: \(want == .routing ? "routing" : "listening to") \(HAL.describe(target)) "
                 + "through \(deviceName), \(Self.describeFormat(tap)), built in \(String(format: "%.0f", ms)) ms (\(reason))")
        if wasRunning || wanted { startIO() }
    }

    /// The tap is made off the main thread: the first one a Mac sees waits for the permission prompt.
    nonisolated private static func createTap(_ process: AudioObjectID, uuid: UUID, muted: Bool) async -> Result<AudioObjectID, RouteFailure> {
        guard #available(macOS 14.2, *) else { return .failure(RouteFailure("process taps need macOS 14.2")) }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let description = CATapDescription(stereoMixdownOfProcesses: [process])
                description.name = "OldTunes cloud route"
                description.uuid = uuid
                description.isPrivate = true
                description.muteBehavior = muted ? .mutedWhenTapped : .unmuted
                var id = HAL.unknown
                let status = AudioHardwareCreateProcessTap(description, &id)
                continuation.resume(returning: status == noErr && id != HAL.unknown
                                    ? .success(id) : .failure(RouteFailure("making the process tap failed: \(HAL.describe(status))")))
            }
        }
    }

    private func startIO() {
        guard let procID, aggregateID != HAL.unknown, !running else { return }
        let status = AudioDeviceStart(aggregateID, procID)
        if status == noErr {
            running = true
        } else {
            Log.error("cloud route: starting the aggregate device failed: \(HAL.describe(status)); this song plays at its own level")
        }
    }

    private func stopIO() {
        guard let procID, running else { return }
        AudioDeviceStop(aggregateID, procID)
        running = false
    }

    private func teardown() {
        stopIO()
        if aggregateID != HAL.unknown {
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            unlisten(aggregateID)
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = HAL.unknown
        }
        procID = nil
        if tapID != HAL.unknown, #available(macOS 14.2, *) {
            AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = HAL.unknown
        tappedProcess = HAL.unknown
        deviceUID = ""
    }

    nonisolated private static func describeFormat(_ tap: AudioObjectID) -> String {
        guard #available(macOS 14.2, *),
              let format = HAL.read(tap, kAudioTapPropertyFormat, AudioStreamBasicDescription()) else { return "format unreadable" }
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        return "\(Int(format.mSampleRate)) Hz \(format.mChannelsPerFrame) ch \(interleaved ? "interleaved" : "non-interleaved")"
    }

    // MARK: - The IOProc

    /// Made outside the main actor, so Swift doesn't tie the block to the main thread. Copies the
    /// tap's stereo to the output's first two channels times the gain (ramped across the buffer when
    /// it changes); a mono output gets the mix of both. Never allocates and never logs.
    nonisolated static func ioBlock(io: RouteIO, tapBuffer: Int) -> AudioDeviceIOBlock {
        { _, input, _, output, _ in
            let settings = io.beginBuffer()
            let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            let outs = UnsafeMutableAudioBufferListPointer(output)

            // The tap's stereo: one interleaved buffer, or one buffer per channel.
            var left: UnsafeMutablePointer<Float>?
            var right: UnsafeMutablePointer<Float>?
            var stride = 1
            var frames = 0
            if tapBuffer < ins.count, let data = ins[tapBuffer].mData {
                let channels = Int(ins[tapBuffer].mNumberChannels)
                let samples = data.assumingMemoryBound(to: Float.self)
                if channels >= 2 {
                    left = samples
                    right = samples + 1
                    stride = channels
                    frames = Int(ins[tapBuffer].mDataByteSize) / (MemoryLayout<Float>.size * channels)
                } else if channels == 1 {
                    left = samples
                    right = samples
                    frames = Int(ins[tapBuffer].mDataByteSize) / MemoryLayout<Float>.size
                    if tapBuffer + 1 < ins.count, ins[tapBuffer + 1].mNumberChannels == 1, let other = ins[tapBuffer + 1].mData {
                        right = other.assumingMemoryBound(to: Float.self)
                    }
                }
            }
            if settings.simulatesSilence { left = nil; right = nil }

            var heard = false
            if let left, let right {
                for frame in 0..<frames where left[frame * stride] != 0 || right[frame * stride] != 0 {
                    heard = true
                    break
                }
            }

            var outputChannels = 0
            for buffer in outs { outputChannels += Int(buffer.mNumberChannels) }
            var channelBase = 0
            for buffer in outs {
                let channels = Int(buffer.mNumberChannels)
                defer { channelBase += channels }
                guard let data = buffer.mData else { continue }
                guard settings.reemit, let left, let right, channels > 0 else {
                    memset(data, 0, Int(buffer.mDataByteSize))
                    continue
                }
                let out = data.assumingMemoryBound(to: Float.self)
                let outFrames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
                let count = min(outFrames, frames)
                let step = count > 0 ? (settings.target - settings.from) / Float(count) : 0
                for frame in 0..<count {
                    let g = settings.from + step * Float(frame + 1)
                    let l = left[frame * stride] * g
                    let r = right[frame * stride] * g
                    for channel in 0..<channels {
                        let index = channelBase + channel
                        out[frame * channels + channel] = outputChannels == 1 ? (l + r) * 0.5 : index == 0 ? l : index == 1 ? r : 0
                    }
                }
                if count < outFrames {
                    memset(out + count * channels, 0, (outFrames - count) * channels * MemoryLayout<Float>.size)
                }
            }
            io.endBuffer(heard: heard)
        }
    }

    // MARK: - Watching the HAL

    private func installListeners() {
        guard listeners.isEmpty else { return }
        listen(to: HAL.system, kAudioHardwarePropertyDefaultOutputDevice)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                                         queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRebuild("wake from sleep") }
        }
    }

    private func listen(to object: AudioObjectID, _ selector: AudioObjectPropertySelector) {
        var address = HAL.address(selector)
        let status = AudioObjectAddPropertyListener(object, &address, cloudRouteListener, listenerContext.pointer)
        guard status == noErr else {
            Log.error("cloud route: watching a HAL property failed: \(HAL.describe(status))")
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
        AudioObjectRemovePropertyListener(listener.object, &address, cloudRouteListener, listenerContext.pointer)
    }

    fileprivate func halChanged(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) {
        guard mode != .off else { return }
        switch selector {
        case kAudioHardwarePropertyDefaultOutputDevice:
            // RemotePlayerService follows the default output by itself; the aggregate has to be
            // made again on the new device, or the song would go on playing on the old one.
            scheduleRebuild("the default output device changed")
        case kAudioDevicePropertyDeviceIsAlive:
            guard object == aggregateID, (HAL.read(object, selector, UInt32(1)) ?? 0) == 0 else { return }
            scheduleRebuild("the aggregate device died")
        default:
            break
        }
    }

    /// One rebuild for a burst of HAL notices.
    private func scheduleRebuild(_ reason: String) {
        pendingRebuild?.cancel()
        pendingRebuild = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self, self.mode != .off, self.tapID != HAL.unknown || self.wanted else { return }
            await self.rebuild(self.mode, reason: reason)
        }
    }
}

/// What the route's IOProc shares with the main thread: the gain it should reach, whether it
/// plays the tap out at all, and what it has heard. The IOProc takes the lock twice per buffer.
final class RouteIO: Sendable {
    struct Settings: Sendable {
        var from: Float
        var target: Float
        var reemit: Bool
        var simulatesSilence: Bool
    }

    struct Stats: Sendable {
        var buffers = 0
        /// A non-zero sample came through the tap since the last takeHeard().
        var heard = false
    }

    private struct State: Sendable {
        var target: Float = 1
        var current: Float = 1
        var reemit = false
        var simulatesSilence = false
        var stats = Stats()
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func setGain(_ gain: Float) { state.withLock { $0.target = gain } }
    func setReemit(_ on: Bool) { state.withLock { $0.reemit = on } }

    var simulatesSilence: Bool {
        get { state.withLock { $0.simulatesSilence } }
        set { state.withLock { $0.simulatesSilence = newValue } }
    }

    var stats: Stats { state.withLock { $0.stats } }
    var hasHeard: Bool { state.withLock { $0.stats.heard } }

    /// Whether a sample was heard since the last call, and starts listening afresh.
    func takeHeard() -> Bool {
        state.withLock { s in
            defer { s.stats.heard = false }
            return s.stats.heard
        }
    }

    func beginBuffer() -> Settings {
        state.withLock { s in
            // Nothing played out while not re-emitting, so there is nothing to ramp from.
            if !s.reemit { s.current = s.target }
            return Settings(from: s.current, target: s.target, reemit: s.reemit, simulatesSilence: s.simulatesSilence)
        }
    }

    func endBuffer(heard: Bool) {
        state.withLock { s in
            s.current = s.target
            s.stats.buffers += 1
            if heard { s.stats.heard = true }
        }
    }
}

struct RouteFailure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

/// What the HAL listener finds the route through. Core Audio holds it unretained; the route keeps
/// it alive.
@MainActor
final class RouteListenerContext {
    weak var route: CloudAudioRoute?
    nonisolated var pointer: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }
}

/// Core Audio calls this on its own thread; it hops to the main actor. A plain function rather than
/// a block, because removing a listener needs the very pointer that added it.
private func cloudRouteListener(_ object: AudioObjectID, _ count: UInt32,
                                     _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
                                     _ clientData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let clientData else { return noErr }
    let context = Unmanaged<RouteListenerContext>.fromOpaque(clientData).takeUnretainedValue()
    let selectors = (0..<Int(count)).map { addresses[$0].mSelector }
    Task { @MainActor in
        for selector in selectors { context.route?.halChanged(object, selector) }
    }
    return noErr
}

/// The few HAL reads the route and SystemAudioProbe need. Safe on any thread.
enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)
    static let remotePlayerBundleID = "com.apple.MediaPlayer.RemotePlayerService"

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var where_ = address(selector, scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutableBytes(of: &value) {
            AudioObjectGetPropertyData(object, &where_, 0, nil, &size, $0.baseAddress!)
        }
        return status == noErr ? value : nil
    }

    static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var where_ = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &where_, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// The RemotePlayerService that plays this OldTunes's songs, told apart from other apps' by
    /// the app macOS holds responsible for it (a private libSystem call, looked up at run time).
    /// Without that call, only a lone instance counts as ours: muting another app's would be worse
    /// than playing this song at its own level.
    static func ourRemotePlayer() -> AudioObjectID? {
        var where_ = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &where_, 0, nil, &size) == noErr, size > 0 else { return nil }
        var objects = [AudioObjectID](repeating: unknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &where_, 0, nil, &size, &objects) == noErr else { return nil }
        let remotes = objects.filter { readString($0, kAudioProcessPropertyBundleID) == remotePlayerBundleID }
        guard let responsible = responsibilitySymbol else { return remotes.count == 1 ? remotes.first : nil }
        typealias Responsible = @convention(c) (pid_t) -> pid_t
        let me = ProcessInfo.processInfo.processIdentifier
        return remotes.first { object in
            guard let pid = read(object, kAudioProcessPropertyPID, pid_t(0)), pid > 0 else { return false }
            return unsafeBitCast(responsible, to: Responsible.self)(pid) == me
        }
    }

    private static var responsibilitySymbol: UnsafeMutableRawPointer? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
    }

    static func describe(_ process: AudioObjectID) -> String {
        "RemotePlayerService(\(read(process, kAudioProcessPropertyPID, pid_t(0)).map(String.init) ?? "?"))"
    }

    /// The audio process object of a process, once it has played something; unknown before.
    static func processObject(_ pid: pid_t) -> AudioObjectID {
        var where_ = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifier = pid
        var object = unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(system, &where_, UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &object)
        return status == noErr ? object : unknown
    }

    static func defaultOutputDevice() -> AudioObjectID? {
        guard let device = read(system, kAudioHardwarePropertyDefaultOutputDevice, unknown), device != unknown else { return nil }
        return device
    }

    static func deviceUID(_ device: AudioObjectID) -> String? { readString(device, kAudioDevicePropertyDeviceUID) }
    static func name(_ object: AudioObjectID) -> String? { readString(object, kAudioObjectPropertyName) }

    /// How many buffers the output device's own inputs put in front of the tap's in the aggregate's
    /// input. Speakers have none; an audio interface with inputs has some.
    static func inputBufferCount(_ device: AudioObjectID) -> Int {
        var where_ = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &where_, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &where_, 0, nil, &size, raw) == noErr else { return 0 }
        return Int(raw.assumingMemoryBound(to: AudioBufferList.self).pointee.mNumberBuffers)
    }

    /// The four-character code in an OSStatus, when it has one.
    static func describe(_ status: OSStatus) -> String {
        let bytes = withUnsafeBytes(of: UInt32(bitPattern: status).bigEndian, Array.init)
        let code = bytes.allSatisfy { (32...126).contains($0) } ? "'\(String(decoding: bytes, as: UTF8.self))' " : ""
        return "\(code)(\(status))"
    }
}
