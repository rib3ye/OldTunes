import Foundation
import GRDB

/// One `song` row as the ingest writes it. Separate from `Track` because it carries the sort-key
/// sources and file bookkeeping that readers never see, and because `Track.id` does not exist
/// until SQLite assigns it.
struct SongRecord: Sendable {
    var origin: Track.Origin
    var persistentID: Int64?
    var storeItemID: Int64 = 0

    var title = ""
    var artist = ""
    var album = ""
    var albumArtist = ""
    var composer = ""
    var genre = ""
    var comments = ""
    var grouping = ""

    var totalTimeMs: Int64 = 0
    var trackNumber = 0
    var trackCount = 0
    var discNumber = 0
    var discCount = 0
    var year = 0
    var bpm = 0
    /// Unix seconds, 0 = unknown.
    var addedAt: Int64 = 0
    var playCount = 0
    var rating = 0
    var isCompilation = false
    /// The source's own checkbox: Music's `!isUserDisabled`; always true for a folder file.
    /// OldTunes' own choice is kept apart, in `checked_override` (LibrarySchema).
    var isChecked = true

    var bucket: Track.Bucket = .cloud
    var isCloud = false
    var locationType = 0
    var locationPath: String?
    var hasArtwork = false
    var albumPID: Int64 = 0
    var kind = ""
    var bitRate = 0
    var sampleRate = 0
    var fileSize: Int64 = 0
    /// Folder rows only: modification time in Unix seconds, so a rescan can skip unchanged files.
    var fileMtime: Int64 = 0

    /// What each fold key is made from: the source's own sort field when it has one ("Beatles"
    /// for "The Beatles"), else the value itself (RESEARCH.md §4.3). Folding is deferred to
    /// `arguments` because it is the expensive part of building a record, and a re-ingest
    /// writes only the rows that changed.
    var titleSortSource = ""
    var artistSortSource = ""
    var albumSortSource = ""
    var albumArtistSortSource = ""

    /// Column order shared by both upsert statements in `LibraryIndex+Ingest.swift`.
    static let columns = [
        "origin", "persistent_id", "store_item_id",
        "title", "artist", "album", "album_artist", "composer", "genre", "comments", "grouping",
        "total_time_ms", "track_number", "track_count", "disc_number", "disc_count", "year", "bpm",
        "added_at", "play_count", "rating", "is_compilation", "is_checked",
        "bucket", "is_cloud", "location_type", "location_path", "has_artwork", "album_pid", "kind",
        "bit_rate", "sample_rate", "file_size", "file_mtime",
        "sk_title", "sk_artist", "sk_album", "sk_album_artist", "sk_genre", "content_hash",
    ]

    func arguments(contentHash: Int64) -> StatementArguments {
        let values: [(any DatabaseValueConvertible)?] = [
            origin.rawValue, persistentID, storeItemID,
            title, artist, album, albumArtist, composer, genre, comments, grouping,
            totalTimeMs, trackNumber, trackCount, discNumber, discCount, year, bpm,
            addedAt, playCount, rating, isCompilation, isChecked,
            bucket.rawValue, isCloud, locationType, locationPath, hasArtwork, albumPID, kind,
            bitRate, sampleRate, fileSize, fileMtime,
            SortKey.make(titleSortSource), SortKey.make(artistSortSource), SortKey.make(albumSortSource),
            SortKey.make(albumArtistSortSource), SortKey.make(genre), contentHash,
        ]
        return StatementArguments(values)
    }

    /// `computeContentHash()` as of when the record was finished. Stored so the hashing happens
    /// where the record is built, not inside the write transaction that compares it.
    var contentHash: Int64 = 0

    /// Covers every stored value, so an equal hash means the row would be rewritten unchanged.
    func computeContentHash() -> Int64 {
        var h = StableHasher()
        h.combine(origin.rawValue); h.combine(persistentID); h.combine(storeItemID)
        for text in [title, artist, album, albumArtist, composer, genre, comments, grouping, kind,
                     titleSortSource, artistSortSource, albumSortSource, albumArtistSortSource] {
            h.combine(text)
        }
        for number in [trackNumber, trackCount, discNumber, discCount, year, bpm, playCount, rating,
                       bucket.rawValue, locationType, bitRate, sampleRate] {
            h.combine(number)
        }
        h.combine(totalTimeMs); h.combine(addedAt); h.combine(albumPID); h.combine(fileSize); h.combine(fileMtime)
        h.combine(isCompilation); h.combine(isChecked); h.combine(isCloud); h.combine(hasArtwork)
        h.combine(locationPath)
        return h.value
    }
}
