import AppKit
import GRDB
import iTunesLibrary

/// OLDTUNES_HARNESS=musictag — the live check of saving a tag through Music.app, run only with
/// Noah's go-ahead because it changes his iCloud Music Library. Sets one song's Comments to a
/// marker through the real TagEditor (the same path Get Info uses), proves the change landed by
/// re-reading Music's own database through iTunesLibrary (independent of the write path), then
/// writes the original back and proves that too.
///
///   OLDTUNES_TAG_EXPECT_PID=<persistent id, Int64>  the song
///   OLDTUNES_TAG_ID=<index row id>                  optional, a safety match
/// Without a row id the song is found in the index by its persistent ID: a sandboxed oldTunes's
/// own index is in its container, where nothing outside the app can look up a row id.
@MainActor
enum MusicTagLiveTest {
    static let marker = "oldtunes-test"

    static func run() async {
        let env = ProcessInfo.processInfo.environment
        defer { Log.flush(); NSApp.terminate(nil) }
        guard let expected = env["OLDTUNES_TAG_EXPECT_PID"].flatMap(Int64.init) else {
            Log.error("musictag: set OLDTUNES_TAG_EXPECT_PID (and optionally OLDTUNES_TAG_ID)"); return
        }
        guard let index = try? LibraryIndex() else {
            Log.error("musictag: the index won't open; nothing written"); return
        }
        var rowID = env["OLDTUNES_TAG_ID"].flatMap(Int64.init)
        if rowID == nil {
            rowID = try? await index.pool.read { db in
                try Int64.fetchOne(db, sql: "SELECT id FROM song WHERE persistent_id = ?", arguments: [expected])
            }
        }
        guard let id = rowID, let track = try? await index.tracks(ids: [id]).first,
              track.persistentID == expected, track.origin == .musicLibrary else {
            Log.error("musictag: no row is the expected Music-library song \(expected); nothing written"); return
        }
        let original = track.comments
        Log.info("musictag: song “\(track.title)” by \(track.artist) — row \(id), pid \(expected), " +
                 "original comment “\(original)”, route \(TagEditor.route(for: track))")

        let reader = MusicDatabaseReader()
        let before = await reader.comment(persistentID: expected)
        Log.info("musictag: Music's database before: “\(before.flatMap { $0 } ?? "nil")”")

        let editor = TagEditor()
        var patch = TagPatch(); patch.comments = marker
        let started = Date()
        let set = await editor.apply(patch, to: [track])
        Log.info("musictag: apply(\(marker)) succeeded=\(set.succeeded) failed=\(set.failed.map(\.reason)) " +
                 "in \(String(format: "%.1f", Date().timeIntervalSince(started))) s (includes the permission prompt)")
        guard set.failed.isEmpty else { Log.error("musictag: FAIL save did not go through; nothing to restore"); return }

        let landed = await reader.waitFor(expected, toRead: marker, seconds: 60)
        Log.info("musictag: \(landed.ok ? "PASS" : "FAIL") Music's database reads “\(landed.value ?? "nil")” after \(landed.seconds) s")

        // Restore no matter what the check said: the save reported success, so Music may hold the marker.
        var restore = TagPatch(); restore.comments = original
        let back = await editor.apply(restore, to: [track])
        Log.info("musictag: restore succeeded=\(back.succeeded) failed=\(back.failed.map(\.reason))")
        let restored = await reader.waitFor(expected, toRead: original, seconds: 60)
        Log.info("musictag: \(restored.ok ? "PASS" : "FAIL") restored; Music's database reads “\(restored.value ?? "nil")” " +
                 "after \(restored.seconds) s")
        Log.info("musictag: SUMMARY save=\(landed.ok ? "PASS" : "FAIL") restore=\(restored.ok ? "PASS" : "FAIL")")
    }
}

/// Reads one song's comment from Music's library database through iTunesLibrary, which is
/// separate from the ScriptingBridge path that writes it. Owns its own ITLibrary off the main actor.
private actor MusicDatabaseReader {
    private var library: ITLibrary?

    func comment(persistentID: Int64) -> String?? {
        if library == nil { library = try? ITLibrary(apiVersion: "1.0", options: .none) }
        guard let library else { return .none }
        _ = library.reloadData()
        let pid = NSNumber(value: UInt64(bitPattern: persistentID))
        guard let item = library.allMediaItems.first(where: { $0.persistentID == pid }) else { return .none }
        return .some(item.comments)
    }

    /// Polls until the comment equals `expected` (nil and "" count as the same empty comment).
    func waitFor(_ persistentID: Int64, toRead expected: String, seconds: Double) async
        -> (ok: Bool, value: String?, seconds: String) {
        let start = Date()
        var last: String?
        while Date().timeIntervalSince(start) < seconds {
            if case .some(let value) = comment(persistentID: persistentID) {
                last = value
                if (value ?? "") == expected {
                    return (true, value, String(format: "%.1f", Date().timeIntervalSince(start)))
                }
            }
            try? await Task.sleep(for: .seconds(2))
        }
        return (false, last, String(format: "%.1f", Date().timeIntervalSince(start)))
    }
}
