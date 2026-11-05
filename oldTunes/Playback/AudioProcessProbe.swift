import CoreAudio
import Foundation

/// Harness-only: asks the HAL which processes are sending audio to an output right now.
/// Answers the volume question for cloud playback: if MusicKit rendered inside oldTunes, the app
/// would have something of its own to attenuate; if another process renders, it does not.
enum AudioProcessProbe {
    struct Client: Sendable, CustomStringConvertible {
        var pid: pid_t
        var bundleID: String
        /// The HAL process object, which is what a process tap names.
        var object = AudioObjectID(kAudioObjectUnknown)
        var isRunningOutput = false
        var description: String { "\(bundleID.isEmpty ? "?" : bundleID)(\(pid))" }
    }

    static func processesRunningOutput() -> [Client] {
        allProcesses().filter(\.isRunningOutput)
    }

    /// Every process connected to the HAL, sending audio or not.
    static func allProcesses() -> [Client] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }

        return objects.map { object in
            let pid = read32(object, kAudioProcessPropertyPID).map { pid_t(bitPattern: $0) } ?? 0
            return Client(pid: pid, bundleID: bundleID(of: object), object: object,
                          isRunningOutput: (read32(object, kAudioProcessPropertyIsRunningOutput) ?? 0) != 0)
        }
    }

    /// Both properties read here are 32-bit (a UInt32 flag and a pid_t).
    private static func read32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func bundleID(of object: AudioObjectID) -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return "" }
        return value.takeRetainedValue() as String
    }
}
