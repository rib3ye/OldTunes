import Foundation
import ScriptingBridge

/// The real `PlaylistEditing`: Music.app's scripting, through the same ScriptingBridge session
/// and queue as tag saves and song adds. Every playlist is found by persistent ID.
///
/// Sends `make` (as a plain Apple Event; see `MusicScriptingSession.makePlaylist`), `move`,
/// `duplicate` (songs into a new playlist, or added to one), `delete`, and the `name` and
/// `persistent ID` properties; never play, pause or next track (§6.5).
struct MusicPlaylistEditor: PlaylistEditing {
    static let musicQuitReason = "Music quit, so oldTunes stopped adding songs."
    static let timeoutReason = "Music didn’t answer in time, so oldTunes stopped adding songs."
    static let unansweredReason = "Music didn’t answer in time, so oldTunes stopped adding songs. "
        + "The song it was adding may still go in."
    /// Followed by Music's reason for the third of them.
    static let threeInARowReason = "Music turned down three songs in a row, so oldTunes stopped adding songs."
    /// The playlist left Music (deleted there, or on another device) before the chunk could find
    /// it. AppController tells this stop by it, to have the source list catch up.
    static let playlistGoneReason = "Music no longer has this playlist, so oldTunes stopped adding songs."

    /// For a playlist Music takes no songs into. Names no playlist: the alert's first line already
    /// does, and a stop reason also goes to the log, which names playlists only by hex ID.
    static let refusesSongsReason = "Music doesn’t let songs be added to this playlist."

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

    func renamePlaylist(_ id: Int64, to name: String, continuing: Bool) async throws {
        // Between two chunks of an add, the name goes as the chunks do: only the first may
        // start Music (`addSongs`).
        if !continuing { try await ready() }
        try await MusicScriptingSession.run {
            // As at the top of `send`: ScriptingBridge would start Music again for the lookup,
            // and this can wait its turn here behind a download or a tag save while the user
            // quits Music to stop the add.
            if continuing, !MusicAutomation.isMusicRunning {
                throw TagEditError(message: Self.musicQuitReason, code: -600)
            }
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

    func removeSongs(_ persistentIDs: [Int64], from playlist: Int64, continuing: Bool) async -> PlaylistRemoveReport {
        guard !persistentIDs.isEmpty else { return PlaylistRemoveReport() }
        do {
            if !continuing { try await ready() }
            return try await MusicScriptingSession.run {
                guard MusicAutomation.isMusicRunning else { return PlaylistRemoveReport(stopReason: Self.removeQuitReason) }
                let session = try MusicScriptingSession(for: .editingPlaylists)
                let target = try session.playlistRemovalTarget(playlist)
                var report = PlaylistRemoveReport()
                for pid in persistentIDs {
                    guard MusicAutomation.isMusicRunning else {
                        report.stopReason = Self.removeQuitReason
                        break
                    }
                    do {
                        try session.removeSong(pid, from: target)
                        report.removed.append(pid)
                    } catch {
                        report.stopReason = Self.removeStopReason(for: Self.scriptingError(error))
                        break
                    }
                }
                return report
            }
        } catch {
            return PlaylistRemoveReport(stopReason: Self.removeStopReason(for: Self.scriptingError(error)))
        }
    }

    static let removeQuitReason = "Music quit, so oldTunes stopped removing songs."

    static func removeStopReason(for error: TagEditError) -> String {
        switch error.code {
        case -600, -609: removeQuitReason
        case -1712: "Music didn’t answer in time. The last song may still be removed from the playlist."
        default: error.message
        }
    }

    func addSongs(_ persistentIDs: [Int64], to playlist: Int64, continuing: Bool) async -> PlaylistAddReport {
        guard !persistentIDs.isEmpty else { return PlaylistAddReport() }
        let started = Date()
        let report: PlaylistAddReport
        do {
            // Only an add's first chunk may start Music; `send` stops any chunk once it has quit.
            if !continuing { try await ready() }
            report = try await MusicScriptingSession.run {
                try Self.send(persistentIDs, to: playlist, firstChunk: !continuing)
            }
        } catch {
            // Music isn't ready, or the playlist itself couldn't be found: nothing went in.
            let error = Self.scriptingError(error)
            report = PlaylistAddReport(stopReason: Self.stopReason(for: error), retryWontHelp: Self.retryWontHelp(after: error))
        }
        let refusal = report.refused.first.map { "; first refusal: \($0.reason)" } ?? ""
        Log.info("playlists: Music added \(report.added.count) of \(persistentIDs.count) songs to " +
                 "\(MusicPersistentID.hex(playlist)) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s, " +
                 "\(report.refused.count) refused\(refusal)\(report.stopReason.map { "; stopped: \($0)" } ?? "")")
        return report
    }

    /// One chunk of an add, on the scripting queue: a lookup and a `duplicate … to` per song.
    /// Throws only before the first song is sent: no session, or no such playlist. What a song
    /// that fails means for the rest is `afterFailure`'s to say, and `apply` puts it in the
    /// report; this only sends.
    private static func send(_ persistentIDs: [Int64], to playlist: Int64, firstChunk: Bool) throws -> PlaylistAddReport {
        // Before the first event, finding the playlist, which ScriptingBridge would start Music
        // again for: a chunk can wait its turn here behind a download or a tag save, and the user
        // may quit Music meanwhile. For a first chunk, `ready()` has only just made sure it runs.
        guard MusicAutomation.isMusicRunning else { return PlaylistAddReport(stopReason: musicQuitReason) }
        let session = try MusicScriptingSession(for: .editingPlaylists)
        let destination = try session.playlist(persistentID: playlist)
        var report = PlaylistAddReport()
        // Songs Music has just turned down one after another, and the error code they share.
        var streak: (code: Int?, count: Int) = (nil, 0)
        for pid in persistentIDs {
            // ScriptingBridge would start Music again for the next event, and quitting Music is
            // how a user stops a long add.
            guard MusicAutomation.isMusicRunning else {
                report.stopReason = musicQuitReason
                break
            }
            var duplicateSent = false
            do {
                let track = try session.track(persistentID: pid)
                duplicateSent = true
                try session.add(track, to: destination)
                report.added.append(pid)
                streak = (nil, 0)
            } catch {
                let error = scriptingError(error)
                let after = afterFailure(error, duplicateSent: duplicateSent, firstChunk: firstChunk,
                                         addedSoFar: report.added.count, streak: &streak)
                if apply(after, to: pid, failedWith: error, in: &report) { break }
            }
        }
        return report
    }

    /// What `send` does with a song that failed (`afterFailure`, then `apply`).
    struct AfterFailure: Sendable, Equatable {
        /// The song goes in the report's `refused`, with Music's reason.
        var refused = false
        /// The song is the report's `unanswered` one: Music didn't answer its `duplicate` in time,
        /// and may still add it.
        var unanswered = false
        /// Why the chunk stops at this song; nil goes on to the next.
        var stopReason: String? = nil
        /// Trying again would stop the same way (`PlaylistAddReport.retryWontHelp`).
        var retryWontHelp = false
    }

    /// `send`'s choice after a song fails, in its order, made on Music's answer alone: pure, so
    /// the playlists bench runs it without Music. Only `send`'s checks that Music still runs are
    /// left to a hand check (RESEARCH.md §6.10). `duplicateSent`: the song was found and its
    /// `duplicate` sent (false: its lookup failed). `addedSoFar`: the songs this chunk has put in.
    /// `streak`: the refusals in a row before this song and the code they share; only a
    /// turned-down `duplicate` counts, a failed lookup neither counts nor breaks the run, and a
    /// song going in starts it over (`send`).
    static func afterFailure(_ error: TagEditError, duplicateSent: Bool, firstChunk: Bool, addedSoFar: Int,
                             streak: inout (code: Int?, count: Int)) -> AfterFailure {
        guard duplicateSent else {
            // A timeout stops here too, but nothing was sent to the playlist for this song.
            if MusicScriptingSession.stopsBatch(error) {
                return AfterFailure(stopReason: stopReason(for: error), retryWontHelp: retryWontHelp(after: error))
            }
            // Gone from Music since the last re-ingest, most likely: this song only.
            return AfterFailure(refused: true)
        }
        if error.code == -1712 {
            // Music still carries out an event it didn't answer in time, so this song isn't
            // counted as refused: it may still go in.
            return AfterFailure(unanswered: true, stopReason: unansweredReason)
        }
        if MusicScriptingSession.stopsBatch(error) {
            return AfterFailure(stopReason: stopReason(for: error), retryWontHelp: retryWontHelp(after: error))
        }
        if firstChunk && addedSoFar == 0 {
            // The first song Music was asked to take, turned down. iTunesLibrary shows Purchased
            // and Apple Music playlists as plain ones, and Music takes no songs into those, so the
            // rest would only be turned down one by one. That song was sent and turned down, so
            // it is listed with Music's reason, as at three in a row; the run isn't touched.
            return AfterFailure(refused: true, stopReason: "\(refusesSongsReason) \(error.message)", retryWontHelp: true)
        }
        streak = (error.code, streak.code == error.code ? streak.count + 1 : 1)
        // The same refusal three times running is about the playlist, not the songs.
        guard streak.count == 3 else { return AfterFailure(refused: true) }
        return AfterFailure(refused: true, stopReason: "\(threeInARowReason) \(error.message)", retryWontHelp: true)
    }

    /// Puts `afterFailure`'s choice for the song `pid` into the chunk's report, as `send` does for
    /// each song that fails: in `refused` with Music's reason, or as the `unanswered` one, and the
    /// stop with whether trying again would meet it. True when the chunk stops at this song. Pure,
    /// so the playlists bench takes Music's answers into a report through these same lines.
    static func apply(_ after: AfterFailure, to pid: Int64, failedWith error: TagEditError,
                      in report: inout PlaylistAddReport) -> Bool {
        if after.refused { report.refused.append(.init(persistentID: pid, reason: error.message)) }
        if after.unanswered { report.unanswered = pid }
        guard let stop = after.stopReason else { return false }
        report.stopReason = stop
        report.retryWontHelp = after.retryWontHelp
        return true
    }

    /// A timeout, a quit or a playlist gone in plain words; anything else as the session put it
    /// (permission, -10004). Music was running when the chunk began (`ready()`, then the check at
    /// the top of `send`), so Music gone (-600, -609) means the user quit it, or it crashed,
    /// since then. A -1728 comes here only from the chunk's playlist lookup: for one song it
    /// turns down that song, and the add goes on (`stopsBatch`). `ready()`'s own failures carry
    /// no code and keep their sentences. Pure, so a bench can check it.
    static func stopReason(for error: TagEditError) -> String {
        switch error.code {
        case -1712: timeoutReason
        case -600, -609: musicQuitReason
        case -1728: playlistGoneReason
        default: error.message
        }
    }

    /// Whether trying the add again would stop the same way: the playlist is gone (-1728, at its
    /// lookup), the sandbox lets nothing reach Music (-1742) or doesn't let this request through
    /// (-10004), or a command is missing from Music's dictionary. `MusicSongDownloader` has the
    /// same rule for downloads, without the playlist.
    static func retryWontHelp(after error: TagEditError) -> Bool {
        error.missingCommand || [-10004, -1742, -1728].contains(error.code)
    }

    private static func scriptingError(_ error: any Error) -> TagEditError {
        error as? TagEditError ?? TagEditError(message: error.localizedDescription)
    }

    /// Music running (hidden) and oldTunes allowed to control it, asking if it never has: the
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
            throw TagEditError(message: "oldTunes couldn’t check its permission to control Music (error \(status)).")
        }
    }

    /// Reads the new playlist's name back before anything moves or fills it. Callers pick names
    /// no playlist has yet, so the name proves the ID in Music's answer leads to what it made,
    /// not to some other playlist that a move or a copy would then change.
    private static func confirm(_ made: SBObject, isNamed name: String, in session: MusicScriptingSession) throws {
        guard try session.name(of: made, failure: "Music couldn’t read the new playlist’s name") == name else {
            throw TagEditError(message: "Music made “\(name)” but oldTunes couldn’t find it again. It appears in a few seconds.")
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
