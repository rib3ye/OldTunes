import Foundation
import ObjectiveC

/// MusicKit's macOS adapter owns a separate MPMusicPlayerApplicationController. Prevent that
/// controller from claiming Now Playing before its first prepare/play, so every remote command
/// reaches OldTunes's queue. There is no public MusicKit equivalent on macOS.
///
/// This optional bridge uses a private framework setting. Check each runtime boundary and fall
/// back to the existing reclaim path if Apple removes it. Never change the system music player.
@MainActor
enum CloudMediaControls {
    static func keepCommandsInApp() -> Bool {
        let factory = NSSelectorFromString("applicationMusicPlayer")
        guard let adapter = NSClassFromString("MusicKit_SoftLinking_MPMusicPlayerController") as? NSObject.Type,
              adapter.responds(to: factory),
              let wrapper = adapter.perform(factory)?.takeUnretainedValue() as? NSObject,
              let storage = class_getInstanceVariable(type(of: wrapper), "_underlyingPlayerController"),
              let encoding = ivar_getTypeEncoding(storage), encoding.pointee == 64, // Objective-C object (@)
              let controller = object_getIvar(wrapper, storage) as? NSObject,
              let applicationController = NSClassFromString("MPMusicPlayerApplicationController"),
              controller.isKind(of: applicationController) else { return false }

        let setter = NSSelectorFromString("setDisableAutomaticCanBeNowPlaying:")
        let getter = NSSelectorFromString("disableAutomaticCanBeNowPlaying")
        guard let setterMethod = class_getInstanceMethod(type(of: controller), setter),
              let getterMethod = class_getInstanceMethod(type(of: controller), getter),
              method_getNumberOfArguments(setterMethod) == 3,
              method_getNumberOfArguments(getterMethod) == 2,
              hasType(method_copyReturnType(setterMethod), in: ["v"]),
              hasType(method_copyArgumentType(setterMethod, 2), in: ["B", "c"]),
              hasType(method_copyReturnType(getterMethod), in: ["B", "c"]) else { return false }
        typealias SetFlag = @convention(c) (AnyObject, Selector, Bool) -> Void
        typealias GetFlag = @convention(c) (AnyObject, Selector) -> Bool
        let set = unsafeBitCast(controller.method(for: setter), to: SetFlag.self)
        let get = unsafeBitCast(controller.method(for: getter), to: GetFlag.self)
        set(controller, setter, true)
        return get(controller, getter)
    }

    private static func hasType(_ encoding: UnsafeMutablePointer<CChar>?, in accepted: [String]) -> Bool {
        guard let encoding else { return false }
        defer { free(encoding) }
        return accepted.contains(String(cString: encoding))
    }
}
