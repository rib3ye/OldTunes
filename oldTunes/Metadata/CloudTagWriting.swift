import Foundation

/// Reads (and, with `askIfNeeded`, requests) the Automation grant for Music. Get Info checks it
/// before saving so it can explain the system prompt before macOS shows it.
protocol MusicPermissionChecking: Sendable {
    func permission(askIfNeeded: Bool) async -> MusicAutomationStatus
}

/// The Music-library half of `TagEditor`: every song in Music's library — stored in iCloud or
/// with a file on this Mac — is edited through Music.app, so Music's database and the file change
/// together. A protocol so the harness can route these edits to a recorder and prove the routing
/// without sending a single Apple Event to Noah's library.
protocol CloudTagWriting: MusicPermissionChecking {
    func apply(_ patch: TagPatch, persistentID: Int64) async throws
    /// Read-only probe used by the live harness check.
    func name(persistentID: Int64) async throws -> String?
}

/// The real writer: Music.app via ScriptingBridge, on the queue every conversation with Music
/// shares (`MusicScriptingSession.run`).
struct MusicAppTagWriter: CloudTagWriting {
    func permission(askIfNeeded: Bool) async -> MusicAutomationStatus {
        // The grant can only be read while Music runs; start it hidden if it isn't.
        guard await MusicAutomation.launchHiddenIfNeeded() else { return .musicUnavailable }
        return await MusicAutomation.permission(askIfNeeded: askIfNeeded)
    }

    func apply(_ patch: TagPatch, persistentID: Int64) async throws {
        guard await MusicAutomation.launchHiddenIfNeeded() else {
            throw TagEditError(message: MusicAutomation.unavailableReason)
        }
        try await MusicScriptingSession.run {
            let session = try MusicScriptingSession()
            let track = try session.track(persistentID: persistentID)
            try session.apply(patch, to: track)
        }
    }

    func name(persistentID: Int64) async throws -> String? {
        guard await MusicAutomation.launchHiddenIfNeeded() else {
            throw TagEditError(message: MusicAutomation.unavailableReason)
        }
        return try await MusicScriptingSession.run {
            let session = try MusicScriptingSession()
            return try session.name(of: try session.track(persistentID: persistentID))
        }
    }
}
