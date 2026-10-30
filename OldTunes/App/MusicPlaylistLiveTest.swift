import AppKit
import iTunesLibrary

/// OLDTUNES_HARNESS=musicplaylists — the live check of the source list's playlist commands,
/// run only with Noah's go-ahead: it really makes, renames, duplicates and deletes playlists in
/// his Music library, and Sync Library carries each change to his iCloud Music Library for the
/// few seconds they exist. Every playlist it makes is named “OldTunes Test …” and deleted again
/// before it finishes. A copy of a song, if Music makes one, it only names (below).
///
/// It goes through the real MusicPlaylistEditor (what the right-click menu uses) and proves
/// each step by reading Music's own database through iTunesLibrary, independent of the
/// scripting path: a new folder; a new playlist inside it (Music's `move`); a rename; adding
/// songs to it (Add to Playlist and drops: one song, then two more in a second call, one of them
/// the first again, so Music must list them in order with the repeat, and still 40 s later, when
/// Sync Library has had time to cut the playlist short or put it back); a duplicate of one
/// existing plain playlist with the same songs in the same order; deleting the duplicate;
/// deleting the folder, which must take its playlist along. Nine steps.
///
/// The add is the first `duplicate` sent with Music's own reference to a library song (the one
/// its whose-lookup answers with) rather than a playlist's track, so the first song goes in alone:
/// if Music lists it as anything but that song in the test playlist, or its library's songs
/// change (a copy of the song instead of an entry), the run stops there and deletes its
/// playlists. It never deletes a copy: a scripted `delete` of a song takes it out of the whole
/// library, and Sync Library takes it off every device, so a wrong ID would cost a real song.
/// Instead the log names each new song by persistent ID, as a copy Music made to remove by hand
/// in Music, and "nothing left behind" fails while one is still there, or while that can't be
/// told (an add call's reads couldn't be trusted, or more songs were new than it sent). The
/// library's songs are compared across each add call only (read just before it, and again after
/// its wait of up to 60 s for the playlist to show the songs), so a song Sync Library brings in
/// during the rest of the run isn't taken for a copy. A song is called a copy only if it is new
/// since the read before that call, and only while no more songs are new than the call sent; a
/// read that comes back empty, or smaller than the other by more songs than the call could have
/// touched, stops the run with "couldn’t read the library", naming no song (`songChange`).
/// Otherwise the songs added are only entries in the test playlist, and go with its folder. It
/// also logs whether Music stayed hidden and in the background, around its first command and
/// its first add, and for each add call how long it took a song and the library-changed notices
/// Music posted from its start until the read after its wait, by when they came: the numbers the
/// stale-playlists retry's back-off rests on (`LibraryIngest.staleRetryWait`, RESEARCH.md §6.10).
///
///   OLDTUNES_PLAYLIST_SOURCE=<the 16-hex-digit persistent ID of the plain playlist to copy>
///
/// That playlist is only read, and needs two different songs, the first two the add uses. Pick a
/// short one: the copy is filled one song per Apple Event.
@MainActor
enum MusicPlaylistLiveTest {
    nonisolated static let prefix = "OldTunes Test"
    /// Why the run stops when a read of Music's songs can't be trusted (`songChange`).
    nonisolated static let unreadable = "couldn’t read the library, so no song is named"

    /// Music's songs across one add call that sent `sent` songs, from the song-ID reads just
    /// before it (`before`) and after its wait (`after`). Nil when either read can't be trusted:
    /// it came back empty, or it is smaller than the other by more songs than the call could have
    /// touched. Then nothing may be said about any song: an empty "before" would make every song
    /// look new. Otherwise `copies` are the songs new since the read before the call, but only
    /// when there are no more of them than it sent: more than that came in some other way (Sync
    /// Library, another device), so none is named and `unnamed` counts them, since calling a
    /// real song a copy could cost it. `gone`: songs no longer there.
    nonisolated static func songChange(before: Set<Int64>, after: Set<Int64>, sent: Int)
        -> (copies: Set<Int64>, unnamed: Int, gone: Set<Int64>)? {
        guard !before.isEmpty, !after.isEmpty, after.count + sent >= before.count, before.count + sent >= after.count else {
            return nil
        }
        let new = after.subtracting(before)
        return new.count <= sent ? (new, 0, before.subtracting(after)) : ([], new.count, before.subtracting(after))
    }

    /// For the log: how long one add call took, `songs` sent from `started` until it `returned`,
    /// a song at a time, and the library-changed notices Music posted (`heard`, when each came)
    /// from its start until `until`, the read after its wait, by seconds after it started.
    nonisolated static func addCallTiming(songs: Int, started: Date, returned: Date, heard: [Date], until: Date) -> String {
        let took = returned.timeIntervalSince(started)
        let times = heard.filter { $0 >= started && $0 <= until }.map { String(format: "+%.1f", $0.timeIntervalSince(started)) }
        return "took \(String(format: "%.2f", took)) s for \(songs) \(songs == 1 ? "song" : "songs"), "
            + "\(String(format: "%.2f", took / Double(max(songs, 1)))) s a song; Music posted \(times.count) library-changed "
            + "\(times.count == 1 ? "notice" : "notices") from its start until the read after its wait"
            + (times.isEmpty ? "" : ", at \(times.joined(separator: " ")) s")
    }

    static func run() async {
        defer { Log.flush(); NSApp.terminate(nil) }
        guard let hex = ProcessInfo.processInfo.environment["OLDTUNES_PLAYLIST_SOURCE"],
              let sourceID = MusicPersistentID.bitPattern(fromHex: hex) else {
            Log.error("musicplaylists: set OLDTUNES_PLAYLIST_SOURCE to a plain playlist's persistent ID; nothing changed")
            return
        }
        let reader = MusicPlaylistReader()
        let before = await reader.playlists()
        guard let original = before[sourceID], original.kind == .regular, Set(original.items).count >= 2 else {
            Log.error("musicplaylists: \(hex) isn't a plain playlist with two different songs in Music's library; nothing changed")
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
        /// Songs new in Music's library across an add call: copies Music made instead of playlist
        /// entries. Never deleted here (see the header), only named.
        var strays: Set<Int64> = []
        /// An add call's reads of the library couldn't be trusted, or more songs were new than it
        /// sent, so `strays` may lack a copy Music made: "nothing left behind" can't pass then.
        /// (More new songs than it sent with none gone makes `songChange` nil; `unnamed` counts
        /// them only when some left as well.)
        var copiesUnknown = false
        func copies(_ ids: Set<Int64>) -> String {
            ids.sorted().map { "\(MusicPersistentID.hex($0)) (a copy Music made; remove it by hand in Music)" }
                .joined(separator: ", ")
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
            // Whether the first command, which may start Music, keeps it out of sight (§6.5).
            Log.info("musicplaylists: before the first command: \(MusicDownloadLiveTest.musicState())")
            let started = Date()
            let folder = try isNew(try await editor.makePlaylist(named: folderName, isFolder: true, in: nil))
            Log.info("musicplaylists: made folder \(MusicPersistentID.hex(folder.id)) in " +
                     "\(String(format: "%.1f", Date().timeIntervalSince(started))) s (includes starting Music and any permission prompt); " +
                     MusicDownloadLiveTest.musicState())
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

            // One song first: an entry of the test playlist carrying that song's own ID, and no
            // new song in the library, or stop before sending more.
            let a = original.items[0]
            let b = original.items.first { $0 != a } ?? a
            let songsBefore = await reader.songIDs()
            // Nothing goes to Music without a read to compare with: every song would look new.
            guard !songsBefore.isEmpty else {
                step("add songs to a playlist", false, "\(unreadable), before the first song")
                throw TagEditError(message: "\(unreadable); stopped before adding anything")
            }
            Log.info("musicplaylists: before the first add: \(MusicDownloadLiveTest.musicState())")
            // Every library-changed notice from here on, by when it came (`addCallTiming`). Reads only.
            let notices = NoticeTimes()
            let observer = DistributedNotificationCenter.default().addObserver(forName: .ITLibraryDidChange, object: nil,
                                                                               queue: .main) { _ in
                MainActor.assumeIsolated { notices.times.append(Date()) }
            }
            defer { DistributedNotificationCenter.default().removeObserver(observer) }
            let addStarted = Date()
            let first = await editor.addSongs([a], to: playlist.id)
            let firstReturned = Date()
            seen = await reader.waitFor(seconds: 60) { $0[playlist.id]?.items == [a] }
            let songsAfter = await reader.songIDs()
            Log.info("musicplaylists: the first add call " + Self.addCallTiming(songs: 1, started: addStarted, returned: firstReturned,
                                                                                heard: notices.times, until: Date()))
            guard let change = Self.songChange(before: songsBefore, after: songsAfter, sent: 1) else {
                step("add songs to a playlist", false, "\(unreadable), after the first song (library songs " +
                     "\(songsBefore.count) → \(songsAfter.count))")
                copiesUnknown = true
                throw TagEditError(message: "\(unreadable); stopped")
            }
            strays.formUnion(change.copies)
            if change.unnamed > 0 { copiesUnknown = true }
            Log.info("musicplaylists: added one song in \(String(format: "%.1f", Date().timeIntervalSince(addStarted))) s: " +
                     "\(first.added.count) added, \(first.refused.count) refused\(first.stopReason.map { ", stopped: \($0)" } ?? ""); " +
                     "Music lists \(seen.lists[playlist.id]?.items.map(MusicPersistentID.hex) ?? []) after \(seen.seconds) s; " +
                     "library songs \(songsBefore.count) → \(songsAfter.count), \(change.copies.count + change.unnamed) new, " +
                     "\(change.gone.count) gone; \(MusicDownloadLiveTest.musicState())")
            guard first.added == [a], seen.ok, change.copies.isEmpty, change.unnamed == 0, change.gone.isEmpty else {
                step("add songs to a playlist", false, "the first song didn’t go in as an entry of the test playlist " +
                     "(added \(first.added.map(MusicPersistentID.hex)), library songs \(songsBefore.count) → \(songsAfter.count))" +
                     (change.copies.isEmpty ? "" : "; new in Music's library: \(copies(change.copies))") +
                     (change.unnamed == 0 ? "" : "; \(change.unnamed) songs new in Music's library, more than the call sent, so none is named") +
                     (change.gone.isEmpty ? "" : "; gone from it: \(change.gone.sorted().map(MusicPersistentID.hex))"))
                throw TagEditError(message: "Music didn’t add the song as the test playlist’s entry; stopped")
            }
            // Then two in a later call, as the chunks after an add's first go: no starting Music.
            let songsBeforeSecond = await reader.songIDs()
            guard !songsBeforeSecond.isEmpty else {
                step("add songs to a playlist", false, "\(unreadable), before the second call")
                throw TagEditError(message: "\(unreadable); stopped")
            }
            let secondStarted = Date()
            let second = await editor.addSongs([b, a], to: playlist.id, continuing: true)
            let secondReturned = Date()
            seen = await reader.waitFor(seconds: 60) { $0[playlist.id]?.items == [a, b, a] }
            let songsAfterSecond = await reader.songIDs()
            Log.info("musicplaylists: the second add call " + Self.addCallTiming(songs: 2, started: secondStarted,
                                                                                 returned: secondReturned, heard: notices.times,
                                                                                 until: Date()))
            guard let secondChange = Self.songChange(before: songsBeforeSecond, after: songsAfterSecond, sent: 2) else {
                step("add songs to a playlist", false, "\(unreadable), after the second call (library songs " +
                     "\(songsBeforeSecond.count) → \(songsAfterSecond.count))")
                copiesUnknown = true
                throw TagEditError(message: "\(unreadable); stopped")
            }
            strays.formUnion(secondChange.copies)
            if secondChange.unnamed > 0 { copiesUnknown = true }
            let addSeconds = String(format: "%.1f", Date().timeIntervalSince(addStarted))
            // Sync Library has been reported to cut a playlist short, or put it back, a little later.
            try? await Task.sleep(for: .seconds(40))
            let later = await reader.playlists()[playlist.id]?.items
            step("add songs to a playlist", second.added == [b, a] && seen.ok && later == [a, b, a]
                    && secondChange.copies.isEmpty && secondChange.unnamed == 0,
                 "one song, then two more, one of them again, in \(addSeconds) s (\(second.refused.count) refused" +
                 "\(second.stopReason.map { ", stopped: \($0)" } ?? "")); Music lists them in order with the repeat: " +
                 "\(seen.ok) after \(seen.seconds) s; 40 s later \(later == [a, b, a] ? "the same" : "\(later?.count ?? 0) entries")" +
                 (secondChange.copies.isEmpty ? "" : "; new in Music's library: \(copies(secondChange.copies))") +
                 (secondChange.unnamed == 0 ? "" : "; \(secondChange.unnamed) songs new in Music's library, more than the call " +
                    "sent, so none is named"))

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
        // A copy Music made is only named, never deleted here: it is left while Music still has it.
        var songsNow: Set<Int64> = []
        if !strays.isEmpty { songsNow = await reader.songIDs() }
        let copiesLeft = strays.intersection(songsNow)
        var behind: [String] = []
        if !clean.ok { behind.append("still in Music, delete by hand: \(left.values.map(\.name))") }
        if !strays.isEmpty, songsNow.isEmpty {
            behind.append("couldn’t read the library, so whether the copies named above are still there is unknown")
        } else if !copiesLeft.isEmpty {
            behind.append("songs still in Music's library: \(copies(copiesLeft))")
        }
        // Names no song: there is none it could name.
        if copiesUnknown {
            behind.append("an add call’s reads of the library couldn’t be trusted, or more songs were new than it sent, so "
                          + "whether Music made a copy of a song is unknown; look in Music before removing anything")
        }
        step("nothing left behind", behind.isEmpty,
             behind.isEmpty ? "no “\(prefix) …” playlists in Music, and no copy of a song" : behind.joined(separator: "; "))
        Log.info("musicplaylists: SUMMARY " + results.map { "\($0.0)=\($0.1 ? "PASS" : "FAIL")" }.joined(separator: " "))
    }
}

/// When Music's library-changed notices came, during the add calls.
@MainActor
private final class NoticeTimes {
    var times: [Date] = []
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

    /// The songs in Music's library, by persistent ID: adding songs to a playlist must add none.
    /// Empty when iTunesLibrary can't be read.
    func songIDs() -> Set<Int64> {
        if library == nil { library = try? ITLibrary(apiVersion: "1.0", options: .none) }
        guard let library else { return [] }
        _ = library.reloadData()
        return Set(library.allMediaItems.filter { $0.mediaKind == .kindSong }.map { Int64(bitPattern: $0.persistentID.uint64Value) })
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
