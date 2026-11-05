import Foundation
import ObjectiveC

/// Sets the level iCloud songs play at, inside the Apple player that plays them.
///
/// MusicKit has no volume on macOS (Apple's DTS: developer.apple.com/forums/thread/850232), and
/// iCloud songs sound from another process, RemotePlayerService. The MPMusicPlayerApplicationController
/// that MusicKit's macOS adapter owns (the one CloudMediaControls reaches) has a private
/// `setRelativeVolume:`, which sends the level to that process's player server
/// (`MPMusicPlayerControllerApplicationServer`). Measured on November 4, 2026 (macOS 27,
/// RelativeVolumeBench, a muted tap on RemotePlayerService): an amplitude factor, 0.5 → −6.03 dB,
/// 0.25 → −12.05 dB, 0.1 → −20.00 dB, 0 → silence; nothing above 1 (2 played as 1). The level holds
/// through a pause and into the next song, and the Mac's own volume is left alone.
///
/// So OldTunes sets its volume and Sound Check on iCloud songs without listening to them, and
/// never needs System Audio Recording. Every step of the way is checked; if Apple removes or changes
/// the call, `set` returns false, the song plays at its own level and the slider greys out.
@MainActor
enum CloudVolume {
    /// Sets the level of what MusicKit's player plays, 0 to 1. False if the call isn't there.
    static func set(_ level: Float) -> Bool {
        guard let controller = applicationController() else {
            tellOnce("MusicKit's own player isn't where OldTunes looks for it")
            return false
        }
        let selector = NSSelectorFromString("setRelativeVolume:")
        guard let method = class_getInstanceMethod(type(of: controller), selector),
              method_getNumberOfArguments(method) == 3,
              typeName(method_copyReturnType(method)) == "v",
              typeName(method_copyArgumentType(method, 2)) == "f" else {
            tellOnce("MusicKit's player has no setRelativeVolume: taking a float")
            return false
        }
        typealias SetFloat = @convention(c) (AnyObject, Selector, Float) -> Void
        let set = unsafeBitCast(controller.method(for: selector), to: SetFloat.self)
        set(controller, selector, min(max(level, 0), 1))
        return true
    }

    /// The MPMusicPlayerApplicationController behind `ApplicationMusicPlayer.shared`, found as
    /// CloudMediaControls finds it.
    private static func applicationController() -> NSObject? {
        let factory = NSSelectorFromString("applicationMusicPlayer")
        guard let adapter = NSClassFromString("MusicKit_SoftLinking_MPMusicPlayerController") as? NSObject.Type,
              adapter.responds(to: factory),
              let wrapper = adapter.perform(factory)?.takeUnretainedValue() as? NSObject,
              let storage = class_getInstanceVariable(type(of: wrapper), "_underlyingPlayerController"),
              let encoding = ivar_getTypeEncoding(storage), encoding.pointee == 64, // Objective-C object (@)
              let controller = object_getIvar(wrapper, storage) as? NSObject,
              let applicationController = NSClassFromString("MPMusicPlayerApplicationController"),
              controller.isKind(of: applicationController) else { return nil }
        return controller
    }

    private static var told = false

    private static func tellOnce(_ why: String) {
        guard !told else { return }
        told = true
        Log.error("cloud volume: \(why), so iCloud songs play at their own level and the volume slider "
                  + "is greyed out during them")
    }

    /// An Objective-C type encoding the runtime copied out, freed here.
    private static func typeName(_ encoding: UnsafeMutablePointer<CChar>?) -> String? {
        guard let encoding else { return nil }
        defer { free(encoding) }
        return String(cString: encoding)
    }
}
