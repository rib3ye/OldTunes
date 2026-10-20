import AudioToolbox
import CoreAudio

/// The default output device's volume, which is the only volume the app can reach for cloud
/// playback. MusicKit has no volume API on macOS, and the audio is not rendered in OldTunes at
/// all: the harness found it coming from `com.apple.MediaPlayer.RemotePlayerService`, a separate
/// process, so there is no in-process mixer to attenuate.
///
/// Tries the same "virtual main" control the menu-bar volume slider uses, then the device's own
/// main-element scalar, then the left/right channels together (some USB devices only have those).
enum OutputDeviceVolume {
    static func read() -> Float? {
        guard let device = defaultOutputDevice() else { return nil }
        if let v = scalar(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyElementMain) { return v }
        if let v = scalar(device, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyElementMain) { return v }
        let channels = [UInt32(1), 2].compactMap { scalar(device, kAudioDevicePropertyVolumeScalar, $0) }
        return channels.isEmpty ? nil : channels.reduce(0, +) / Float(channels.count)
    }

    /// Returns false when the device has no settable volume (HDMI and some interfaces).
    @discardableResult
    static func write(_ volume: Float) -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        let v = min(max(volume, 0), 1)
        if setScalar(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyElementMain, v) { return true }
        if setScalar(device, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyElementMain, v) { return true }
        let results = [UInt32(1), 2].map { setScalar(device, kAudioDevicePropertyVolumeScalar, $0, v) }
        return results.contains(true)
    }

    static func defaultOutputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private static func scalar(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector,
                               _ element: AudioObjectPropertyElement) -> Float? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func setScalar(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                  _ element: AudioObjectPropertyElement, _ value: Float) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return false }
        var v = Float32(value)
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr
    }
}
