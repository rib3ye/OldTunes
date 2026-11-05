import AppKit
import CoreServices

/// Whether oldTunes may send Apple Events to Music (the Automation privacy grant).
enum MusicAutomationStatus: Sendable, Equatable {
    case granted
    case denied
    /// Never asked. Asking shows the system prompt, so the UI explains first (§6.5).
    case undetermined
    /// Music is not running and could not be started, so the grant cannot be read.
    case musicUnavailable
    case failed(OSStatus)
}

/// Talks to TCC and Launch Services about Music.app. Nothing here sends an Apple Event:
/// `AEDeterminePermissionToAutomateTarget` only reads the grant, and with `askIfNeeded == false`
/// it can never show a prompt.
enum MusicAutomation {
    static let bundleID = "com.apple.Music"

    /// Where the user turns the grant back on. Spelled out because the Automation list is
    /// nested two levels deep and nobody finds it unprompted.
    static let deniedReason = "oldTunes isn’t allowed to control Music, so changes to songs in your Music library can’t be saved. "
        + "Turn it on in System Settings ▸ Privacy & Security ▸ Automation ▸ oldTunes ▸ Music."

    static let unavailableReason = "Music couldn’t be opened, so changes to songs in your Music library can’t be saved right now."

    /// The same two refusals, for File ▸ Add Folder's "Also add to the Music app".
    static let addDeniedReason = "oldTunes isn’t allowed to control Music, so it couldn’t add songs to Music. "
        + "Turn it on in System Settings ▸ Privacy & Security ▸ Automation ▸ oldTunes ▸ Music."

    static let addUnavailableReason = "Music couldn’t be opened, so oldTunes couldn’t add songs to it."

    /// And for the source list's playlist commands.
    static let playlistDeniedReason = "oldTunes isn’t allowed to control Music, so it can’t change your playlists. "
        + "Turn it on in System Settings ▸ Privacy & Security ▸ Automation ▸ oldTunes ▸ Music."

    static let playlistUnavailableReason = "Music couldn’t be opened, so oldTunes can’t change your playlists right now."

    /// And for downloading iCloud songs.
    static let downloadDeniedReason = "oldTunes isn’t allowed to control Music, so it can’t download songs. "
        + "Turn it on in System Settings ▸ Privacy & Security ▸ Automation ▸ oldTunes ▸ Music."

    static let downloadUnavailableReason = "Music couldn’t be opened, so oldTunes can’t download songs right now."

    static var isMusicRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Reads the Automation grant. The call needs Music running (it answers procNotFound
    /// otherwise), and with `askIfNeeded` it blocks until the user answers the prompt, so it
    /// runs on a plain dispatch thread rather than tying up a Swift concurrency thread.
    static func permission(askIfNeeded: Bool) async -> MusicAutomationStatus {
        guard isMusicRunning else { return .musicUnavailable }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
                guard let desc = target.aeDesc else {
                    continuation.resume(returning: .failed(OSStatus(paramErr)))
                    return
                }
                // The silent check asks about any event (typeWildCard, '****'). The asking call
                // names the event every save sends, core/setd: the grant is per app pair either
                // way, and a concrete event does not depend on how TCC treats a wildcard when it
                // has to prompt (untested here: no prompt may be raised without someone present).
                let wildcard = AEEventClass(0x2A2A_2A2A)
                let eventClass = askIfNeeded ? AEEventClass(0x636F_7265) : wildcard   // 'core'
                let eventID = askIfNeeded ? AEEventID(0x7365_7464) : wildcard          // 'setd'
                let status = AEDeterminePermissionToAutomateTarget(desc, eventClass, eventID, askIfNeeded)
                continuation.resume(returning: map(status))
            }
        }
    }

    static func map(_ status: OSStatus) -> MusicAutomationStatus {
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .undetermined
        case OSStatus(procNotFound): return .musicUnavailable
        default: return .failed(status)
        }
    }

    /// Starts Music hidden and in the background if it is not running. Music takes over the
    /// Now Playing controls when it comes forward, which a replacement player must not provoke,
    /// so it is never activated.
    static func launchHiddenIfNeeded() async -> Bool {
        if isMusicRunning { return true }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.hides = true
        config.addsToRecentItems = false
        config.promptsUserIfNeeded = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        } catch {
            Log.error("metadata: could not launch Music hidden: \(error.localizedDescription)")
            return false
        }
        // openApplication returns once the process exists; scripting needs it finished launching.
        for _ in 0..<50 {
            if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .contains(where: \.isFinishedLaunching) { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return isMusicRunning
    }
}
