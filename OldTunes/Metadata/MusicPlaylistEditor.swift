import Foundation
import ScriptingBridge

/// The real `PlaylistEditing`: Music.app's scripting, through the same ScriptingBridge session
/// and queue as tag saves and song adds. Every playlist is found by persistent ID.
///
/// Sends `make` (as a plain Apple Event; see `MusicScriptingSession.makePlaylist`), `move`,
/// `duplicate` (songs into a new playlist), `delete`, and the `name` and `persistent ID`
/// properties; never play, pause or next track (§6.5).
struct MusicPlaylistEditor: PlaylistEditing {
    func makePlaylist(named name: String, isFolder: Bool, in parent: Int64?) async throws -> PlaylistInfo {
        try await ready()
        return try await MusicScriptingSession.run {
            let session = try MusicScriptingSession(for: .editingPlaylists)
            // Looked up first, so a folder deleted in Music fails before anything is made.
            let folder = try parent.map { try session.playlist(persistentID: $0) }
            let id = try session.makePlaylist(named: name, isFolder: isFolder)
            let made = try session.playlist(persistentID: id)
            try Self.confirm(made, isNamed: name, in: session)
            let parentID = Self.file(made, into: folder, parent, in: session)
            return PlaylistInfo(id: id, name: name, kind: isFolder ? .folder : .regular, parentID: parentID, trackCount: 0)
        }
    }

    func renamePlaylist(_ id: Int64, to name: String) async throws {
        try await ready()
        try await MusicScriptingSession.run {
            let session = try MusicScriptingSession(for: .editingPlaylists)
            try session.rename(try session.playlist(persistentID: id), to: name)
        }
    }

    func duplicatePlaylist(_ playlist: PlaylistInfo, named name: String) async throws -> PlaylistInfo {
        try await ready()
        return try await MusicScriptingSession.run {
            let session = try MusicScriptingSession(for: .editingPlaylists)
            let original = try session.playlist(persistentID: playlist.id)
            let folder = try playlist.parentID.map { try session.playlist(persistentID: $0) }
            let id = try session.makePlaylist(named: name, isFolder: false)
            let copy = try session.playlist(persistentID: id)
            try Self.confirm(copy, isNamed: name, in: session)
            let parentID = Self.file(copy, into: folder, playlist.parentID, in: session)
            let songs = try session.copyTracks(of: original, to: copy)
            Log.info("playlists: Music copied \(songs) songs into the duplicate \(MusicPersistentID.hex(id))")
            return PlaylistInfo(id: id, name: name, kind: .regular, parentID: parentID, trackCount: playlist.trackCount)
        }
    }

    func deletePlaylist(_ id: Int64) async throws {
        try await ready()
        try await MusicScriptingSession.run {
            let session = try MusicScriptingSession(for: .editingPlaylists)
            try session.deletePlaylist(try session.playlist(persistentID: id))
        }
    }

    /// Music running (hidden) and OldTunes allowed to control it, asking if it never has: the
    /// user has just chosen a playlist command, so the system prompt comes up in context.
    private func ready() async throws {
        guard await MusicAutomation.launchHiddenIfNeeded() else {
            throw TagEditError(message: MusicAutomation.playlistUnavailableReason)
        }
        var status = await MusicAutomation.permission(askIfNeeded: false)
        if status == .undetermined { status = await MusicAutomation.permission(askIfNeeded: true) }
        switch status {
        case .granted: return
        case .denied, .undetermined: throw TagEditError(message: MusicAutomation.playlistDeniedReason)
        case .musicUnavailable: throw TagEditError(message: MusicAutomation.playlistUnavailableReason)
        case .failed(let status):
            throw TagEditError(message: "OldTunes couldn’t check its permission to control Music (error \(status)).")
        }
    }

    /// Reads the new playlist's name back before anything moves or fills it. Callers pick names
    /// no playlist has yet, so the name proves the ID in Music's answer leads to what it made,
    /// not to some other playlist that a move or a copy would then change.
    private static func confirm(_ made: SBObject, isNamed name: String, in session: MusicScriptingSession) throws {
        guard try session.name(of: made, failure: "Music couldn’t read the new playlist’s name") == name else {
            throw TagEditError(message: "Music made “\(name)” but OldTunes couldn’t find it again. It appears in a few seconds.")
        }
    }

    /// Moves what was just made into its folder. A failed move is not worth undoing the make
    /// for: the playlist then stays at the top level, and the answer says so.
    private static func file(_ made: SBObject, into folder: SBObject?, _ parent: Int64?,
                             in session: MusicScriptingSession) -> Int64? {
        guard let folder else { return nil }
        do {
            try session.move(made, into: folder)
            return parent
        } catch {
            Log.error("playlists: made at the top level; moving into \(parent.map(MusicPersistentID.hex) ?? "?") failed: " +
                      error.localizedDescription)
            return nil
        }
    }
}
