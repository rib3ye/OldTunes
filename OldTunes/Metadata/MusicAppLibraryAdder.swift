import Foundation

/// The real hand-off for File ▸ Add Folder's "Also add to the Music app": Music.app's scripting
/// `add` command (hookAdd), through the same ScriptingBridge session and queue as tag saves.
/// One file per event, so a file Music turns down is named, and the rest still go in.
///
/// Sends `add` and one property read, nothing else: never play, pause or next track (§6.5).
struct MusicAppLibraryAdder: MusicLibraryAdding {
    func prepare() async -> String? {
        // The grant can only be read while Music runs; start it hidden if it isn't.
        guard await MusicAutomation.launchHiddenIfNeeded() else { return MusicAutomation.addUnavailableReason }
        var status = await MusicAutomation.permission(askIfNeeded: false)
        // Asked right after the user ticked "Also add to the Music app" and clicked Add, so the
        // system prompt (with NSAppleEventsUsageDescription) comes up in context.
        if status == .undetermined { status = await MusicAutomation.permission(askIfNeeded: true) }
        switch status {
        case .granted: return nil
        case .denied, .undetermined: return MusicAutomation.addDeniedReason
        case .musicUnavailable: return MusicAutomation.addUnavailableReason
        case .failed(let status): return "OldTunes couldn’t check its permission to control Music (error \(status))."
        }
    }

    func add(_ file: URL) async -> MusicAddOutcome {
        do {
            return try await MusicScriptingSession.run {
                let session = try MusicScriptingSession(for: .addingSongs)
                guard let track = try session.add(file: file) else {
                    return .refused("Music answered with nothing")
                }
                // Only for the log and the live check; the add stands without it.
                return .added(persistentID: try? session.persistentID(of: track))
            }
        } catch let error as TagEditError where MusicScriptingSession.endsConversation(error.code) {
            return .stopped(error.message)
        } catch {
            return .refused(error.localizedDescription)
        }
    }
}
