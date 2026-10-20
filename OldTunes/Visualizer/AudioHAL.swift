import CoreAudio
import Foundation

/// Small, synchronous reads of the Core Audio HAL, for the visualizer's tap. Safe on any thread.
///
/// AudioTapBench and AudioProcessProbe have their own copies of some of this; they are harness code
/// that other benches build on, so they are left as they are.
enum AudioHAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)
    static let remotePlayerBundleID = "com.apple.MediaPlayer.RemotePlayerService"

    /// One process the HAL knows about.
    struct Process: Sendable, Equatable, CustomStringConvertible {
        var object: AudioObjectID
        var pid: pid_t
        var bundleID: String
        var isRunningOutput: Bool
        var description: String { "\(bundleID.isEmpty ? "?" : bundleID)(\(pid))" }
    }

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// A fixed-size property (an ID, a flag, a rate, a format).
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

    /// An array of object IDs (process list, device list, tap list).
    static func readIDs(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var where_ = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &where_, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: unknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &where_, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    /// Every process the HAL lists, with its bundle ID and whether it is sending audio.
    static func processes() -> [Process] {
        readIDs(system, kAudioHardwarePropertyProcessObjectList).map(process(_:))
    }

    static func process(_ object: AudioObjectID) -> Process {
        Process(object: object,
                pid: read(object, kAudioProcessPropertyPID, pid_t(0)) ?? 0,
                bundleID: readString(object, kAudioProcessPropertyBundleID) ?? "",
                isRunningOutput: (read(object, kAudioProcessPropertyIsRunningOutput, UInt32(0)) ?? 0) != 0)
    }

    /// This process's own HAL object.
    static func processObject(pid: pid_t) -> AudioObjectID? {
        var pid = pid
        var where_ = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var object = unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(system, &where_, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != unknown ? object : nil
    }

    static func defaultOutputDevice() -> AudioObjectID? {
        guard let device = read(system, kAudioHardwarePropertyDefaultOutputDevice, unknown), device != unknown else { return nil }
        return device
    }

    static func deviceUID(_ device: AudioObjectID) -> String? { readString(device, kAudioDevicePropertyDeviceUID) }
    static func name(_ object: AudioObjectID) -> String? { readString(object, kAudioObjectPropertyName) }

    static func transportType(_ device: AudioObjectID) -> UInt32? {
        read(device, kAudioDevicePropertyTransportType, UInt32(0))
    }

    static func isAirPlay(_ device: AudioObjectID) -> Bool {
        transportType(device) == kAudioDeviceTransportTypeAirPlay
    }

    /// How many buffers a device's own input streams put in front of the tap's in an aggregate's input
    /// buffer list. Speakers have none; an audio interface with inputs has some.
    static func inputBufferCount(_ device: AudioObjectID) -> Int {
        var where_ = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &where_, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &where_, 0, nil, &size, raw) == noErr else { return 0 }
        return Int(raw.assumingMemoryBound(to: AudioBufferList.self).pointee.mNumberBuffers)
    }

    /// Activity Monitor's "responsible process": the app macOS holds responsible for a helper such as
    /// RemotePlayerService. Private libSystem call, looked up at run time; nil if it's gone.
    static func responsiblePID(_ pid: pid_t) -> pid_t? {
        guard let symbol = responsibilitySymbol else { return nil }
        typealias Responsible = @convention(c) (pid_t) -> pid_t
        let result = unsafeBitCast(symbol, to: Responsible.self)(pid)
        return result > 0 ? result : nil
    }

    /// Whether the private call above exists on this macOS.
    static var canTellResponsibleProcess: Bool { responsibilitySymbol != nil }

    private static var responsibilitySymbol: UnsafeMutableRawPointer? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
    }

    /// The four-character code in an OSStatus, when it has one, for log lines.
    static func describe(_ status: OSStatus) -> String {
        let bytes = withUnsafeBytes(of: UInt32(bitPattern: status).bigEndian, Array.init)
        let code = bytes.allSatisfy { (32...126).contains($0) } ? "'\(String(decoding: bytes, as: UTF8.self))' " : ""
        return "\(code)(\(status))"
    }
}
