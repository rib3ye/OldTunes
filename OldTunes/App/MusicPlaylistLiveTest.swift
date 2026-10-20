import AppKit
import iTunesLibrary

/// OLDTUNES_HARNESS=musicplaylists — the live check of the source list's playlist commands,
/// run only with Noah's go-ahead: it really makes, renames, duplicates and deletes playlists in
/// his Music library, and Sync Library carries each change to his iCloud Music Library for the
/// few seconds they exist. Everything it makes is named “OldTunes Test …” and deleted again
/// before it finishes.
///
/// It goes through the real MusicPlaylistEditor (what the right-click menu uses) and proves
/// each step by reading Music's own database through iTunesLibrary, independent of the
/// scripting path: a new folder; a new playlist inside it (Music's `move`); a rename; a
/// duplicate of one existing plain playlist with the same songs in the same order; deleting
/// the duplicate; deleting the folder, which must take its playlist along.
///
///   OLDTUNES_PLAYLIST_SOURCE=<the 16-hex-digit persistent ID of the plain playlist to copy>
///
/// That playlist is only read. Pick a short one: the copy is filled one song per Apple Event.
@MainActor
enum MusicPlaylistLiveTest {
    nonisolated static let prefix = "OldTunes Test"

    static func run() async {
        defer { Log.flush(); NSApp.terminate(nil) }
        guard let hex = ProcessInfo.processInfo.environment["OLDTUNES_PLAYLIST_SOURCE"],
              let sourceID = MusicPersistentID.bitPattern(fromHex: hex) else {
            Log.error("musicplaylists: set OLDTUNES_PLAYLIST_SOURCE to a plain playlist's persistent ID; nothing changed")
            return
        }
        let reader = MusicPlaylistReader()
        let before = await reader.playlists()
        guard let original = before[sourceID], original.kind == .regular, !original.items.isEmpty else {
            Log.error("musicplaylists: \(hex) isn't a plain playlist with songs in Music's library; nothing changed")
            return
        }
        guard !before.values.contains(where: { $0.name.hasPrefix(prefix) }) else {
            Log.error("musicplaylists: Music already has a playlist named “\(prefix)…”; delete it first. Nothing changed")
            return
        }

        let editor = MusicPlaylistEditor()
        var results: [(String, Bool)] = []
        func step(_ name: String, _ ok: Bool, _ detail: String) {
            results.append((name, ok))
            Log.info("musicplaylists: \(ok ? "PASS" : "FAIL") \(name) — \(detail)")
        }
        /// An ID from before the run would mean Music's answer led to one of Noah's playlists,
        /// which the next steps would rename or delete. Stop instead.
        func isNew(_ made: PlaylistInfo) throws -> PlaylistInfo {
            guard before[made.id] == nil else {
                throw TagEditError(message: "Music answered with \(MusicPersistentID.hex(made.id)), a playlist from before this run; stopped")
            }
            return made
        }
        /// Deletes only what this run made: never an ID from before it, never a playlist Music
        /// doesn't call “OldTunes Test …”.
        func deleteOwn(_ id: Int64) async throws {
            guard before[id] == nil else {
                throw TagEditError(message: "refused to delete \(MusicPersistentID.hex(id)): it was there before this run")
            }
            if let listed = await reader.playlists()[id], !listed.name.hasPrefix(prefix) {
                throw TagEditError(message: "refused to delete \(MusicPersistentID.hex(id)): Music calls it “\(listed.name)”")
            }
            try await editor.deletePlaylist(id)
        }
        do {
            let folderName = "\(prefix) Folder", renamed = "\(prefix) Playlist (renamed)"
            let started = Date()
            let folder = try isNew(try await editor.makePlaylist(named: folderName, isFolder: true, in: nil))
            Log.info("musicplaylists: made folder \(MusicPersistentID.hex(folder.id)) in " +
                     "\(String(format: "%.1f", Date().timeIntervalSince(started))) s (includes starting Music and any permission prompt)")
            var seen = await reader.waitFor(seconds: 60) { $0[folder.id]?.kind == .folder && $0[folder.id]?.name == folderName }
            step("new folder", seen.ok, "Music lists it after \(seen.seconds) s")

            let playlist = try isNew(try await editor.makePlaylist(named: "\(prefix) Playlist", isFolder: false, in: folder.id))
            seen = await reader.waitFor(seconds: 60) { $0[playlist.id]?.parentID == folder.id }
            step("new playlist inside the folder", seen.ok && playlist.parentID == folder.id,
                 "editor says parent \(playlist.parentID.map(MusicPersistentID.hex) ?? "none"); " +
                 "Music lists \(seen.lists[playlist.id]?.parentID.map(MusicPersistentID.hex) ?? "no parent") after \(seen.seconds) s")

            try await editor.renamePlaylist(playlist.id, to: renamed)
            seen = await reader.waitFor(seconds: 60) { $0[playlist.id]?.name == renamed }
            step("rename", seen.ok, "Music reads “\(seen.lists[playlist.id]?.name ?? "nothing")” after \(seen.seconds) s")

            let copyStarted = Date()
            let source = PlaylistInfo(id: sourceID, name: original.name, kind: .regular, parentID: original.parentID,
                                      trackCount: original.items.count)
            let copy = try isNew(try await editor.duplicatePlaylist(source, named: "\(prefix) Copy"))
            let copySeconds = String(format: "%.1f", Date().timeIntervalSince(copyStarted))
            seen = await reader.waitFor(seconds: 60) { $0[copy.id]?.items == original.items }
            step("duplicate", seen.ok, "\(original.items.count) songs copied in \(copySeconds) s; Music's copy has " +
                 "\(seen.lists[copy.id]?.items.count ?? 0) in the original's order: \(seen.lists[copy.id]?.items == original.items)")

            try await deleteOwn(copy.id)
            seen = await reader.waitFor(seconds: 60) { $0[copy.id] == nil }
            step("delete a playlist", seen.ok, "gone from Music after \(seen.seconds) s")

            try await deleteOwn(folder.id)
            seen = await reader.waitFor(seconds: 60) { $0[folder.id] == nil && $0[playlist.id] == nil }
            step("delete a folder with its playlist", seen.ok, "folder gone: \(seen.lists[folder.id] == nil), " +
                 "playlist gone: \(seen.lists[playlist.id] == nil), after \(seen.seconds) s")

            let after = await reader.playlists()
            step("the copied playlist is untouched", after[sourceID] == original, "\(after[sourceID]?.items.count ?? 0) songs")
        } catch {
            step("commands", false, error.localizedDescription)
        }

        // Whatever this run made that Music still lists goes, playlists before folders. Found by
        // name among the playlists that weren't there before, so a copy whose filling failed
        // before its ID came back goes too.
        func leftovers(_ lists: [Int64: MusicPlaylistReader.Listed]) -> [Int64: MusicPlaylistReader.Listed] {
            lists.filter { before[$0.key] == nil && $0.value.name.hasPrefix(prefix) }
        }
        for _ in 0..<3 {
            let left = leftovers(await reader.playlists())
            if left.isEmpty { break }
            for (id, _) in left.sorted(by: { ($0.value.kind == .folder ? 1 : 0) < ($1.value.kind == .folder ? 1 : 0) }) {
                do {
                    try await deleteOwn(id)
                    Log.info("musicplaylists: cleaned up \(MusicPersistentID.hex(id))")
                } catch {
                    Log.error("musicplaylists: couldn't clean up \(MusicPersistentID.hex(id)): \(error.localizedDescription)")
                }
            }
            try? await Task.sleep(for: .seconds(3))
        }
        let clean = await reader.waitFor(seconds: 20) { lists in
            !lists.contains { before[$0.key] == nil && $0.value.name.hasPrefix(prefix) }
        }
        let left = leftovers(clean.lists)
        step("nothing left behind", clean.ok, clean.ok ? "no “\(prefix) …” playlists in Music"
             : "still in Music, delete by hand: \(left.values.map(\.name))")
        Log.info("musicplaylists: SUMMARY " + results.map { "\($0.0)=\($0.1 ? "PASS" : "FAIL")" }.joined(separator: " "))
    }
}

/// Music's playlists as its own database lists them, through iTunesLibrary: separate from the
/// ScriptingBridge path that changes them. Owns its own ITLibrary off the main actor.
private actor MusicPlaylistReader {
    struct Listed: Sendable, Equatable {
        var name: String
        var kind: PlaylistInfo.Kind
        var parentID: Int64?
        /// Member persistent IDs, in Music's order, repeats kept.
        var items: [Int64]
    }

    private var library: ITLibrary?

    func playlists() -> [Int64: Listed] {
        if library == nil { library = try? ITLibrary(apiVersion: "1.0", options: .none) }
        guard let library else { return [:] }
        _ = library.reloadData()
        var out: [Int64: Listed] = [:]
        for playlist in library.allPlaylists {
            let kind: PlaylistInfo.Kind = switch playlist.kind {
            case .folder: .folder
            case .smart: .smart
            case .genius, .geniusMix: .genius
            default: .regular
            }
            out[Int64(bitPattern: playlist.persistentID.uint64Value)] = Listed(
                name: playlist.name, kind: kind, parentID: playlist.parentID.map { Int64(bitPattern: $0.uint64Value) },
                items: playlist.items.map { Int64(bitPattern: $0.persistentID.uint64Value) })
        }
        return out
    }

    /// Polls until `test` holds for Music's playlists, or `seconds` pass.
    func waitFor(seconds: Double, _ test: @Sendable ([Int64: Listed]) -> Bool) async
        -> (ok: Bool, lists: [Int64: Listed], seconds: String) {
        let start = Date()
        var lists: [Int64: Listed] = [:]
        while Date().timeIntervalSince(start) < seconds {
            lists = playlists()
            if test(lists) { return (true, lists, String(format: "%.1f", Date().timeIntervalSince(start))) }
            try? await Task.sleep(for: .seconds(1))
        }
        return (false, lists, String(format: "%.1f", Date().timeIntervalSince(start)))
    }
}
