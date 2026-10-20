import Foundation
import GRDB

extension LibraryIndex {
    /// Applies a successful tag edit to the index so the list and search update without a
    /// re-ingest. Sort keys are recomputed from the new text; the FTS triggers re-index the row.
    func update(ids: [Track.ID], applying patch: TagPatch) async throws {
        guard !ids.isEmpty, !patch.isEmpty else { return }
        var sets: [String] = []
        var values: [(any DatabaseValueConvertible)?] = []
        func set(_ column: String, _ value: (any DatabaseValueConvertible)?) {
            sets.append("\(column) = ?")
            values.append(value)
        }
        func setText(_ column: String, _ sortColumn: String?, _ text: String?) {
            guard let text else { return }
            set(column, text)
            if let sortColumn { set(sortColumn, SortKey.make(text)) }
        }
        setText("title", "sk_title", patch.title)
        setText("artist", "sk_artist", patch.artist)
        setText("album", "sk_album", patch.album)
        setText("album_artist", "sk_album_artist", patch.albumArtist)
        setText("composer", nil, patch.composer)
        setText("genre", "sk_genre", patch.genre)
        setText("grouping", nil, patch.grouping)
        setText("comments", nil, patch.comments)
        if let v = patch.year { set("year", v) }
        if let v = patch.trackNumber { set("track_number", v) }
        if let v = patch.trackCount { set("track_count", v) }
        if let v = patch.discNumber { set("disc_number", v) }
        if let v = patch.discCount { set("disc_count", v) }
        if let v = patch.bpm { set("bpm", v) }
        if let v = patch.isCompilation { set("is_compilation", v) }
        if patch.removeArtwork { set("has_artwork", false) } else if patch.artwork != nil { set("has_artwork", true) }
        guard !sets.isEmpty else { return }
        // The row no longer matches what was ingested, so the next refresh must rewrite it from
        // Music rather than skip it as unchanged (in case the edit never reached Music).
        set("content_hash", 0)

        values.append(Self.jsonArray(ids))
        let sql = "UPDATE song SET \(sets.joined(separator: ", ")) WHERE id IN (SELECT value FROM json_each(?))"
        let arguments = StatementArguments(values)
        try await pool.write { db in try db.execute(sql: sql, arguments: arguments) }
        await Self.postDidChange()
    }

    /// The per-song checkbox, as OldTunes' own choice.
    ///
    /// The rule: once a song's box is toggled in OldTunes, OldTunes' value is the one shown, for
    /// as long as the song stays in the index. It lives in `checked_override`, which neither
    /// upsert names, so a Music re-ingest (which does rewrite `is_checked` whenever Music's own
    /// checkbox changes) and a folder rescan both leave it alone, and the content-hash skip never
    /// sees it. It belongs to the row: a song removed from Music, or a folder file deleted, takes
    /// it along. Unknown ids are ignored; posts `.libraryDidChange` when any row matched.
    func setChecked(ids: [Track.ID], checked: Bool) async throws {
        guard !ids.isEmpty else { return }
        let json = Self.jsonArray(ids)
        let matched = try await pool.write { db -> Int in
            try db.execute(sql: "UPDATE song SET checked_override = ? WHERE id IN (SELECT value FROM json_each(?))",
                           arguments: [checked, json])
            return db.changesCount
        }
        if matched > 0 { await Self.postDidChange() }
    }
}
