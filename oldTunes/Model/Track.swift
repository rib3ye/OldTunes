import Foundation

/// One song in the merged library. A value type so it can cross actor boundaries freely.
///
/// Mirrors one row of the `song` table (docs/RESEARCH.md §4.2). Integer tag fields use 0 for
/// "blank", matching the table's `NOT NULL DEFAULT 0` columns, so there is one convention end to end.
///
/// A track is playable from a local file, from the iCloud music library, or both. Playback tries
/// them in the order of the fallback chain in docs/RESEARCH.md §1.
struct Track: Sendable, Hashable, Identifiable {
    /// SQLite rowid in the local index. Stable across re-ingests (rows are upserted, not recreated).
    typealias ID = Int64

    /// Where a row came from. Re-ingesting one origin never touches the other's rows.
    enum Origin: Int, Sendable { case musicLibrary = 0, folder = 1 }

    /// Classified at ingest. Raw values are stored in the `bucket` column.
    enum Bucket: Int, Sendable { case local = 0, cloud = 1, missing = 2 }

    var id: ID
    var origin: Origin

    // MARK: Identity upstream

    /// `ITLibMediaItem.persistentID` as its Int64 bit pattern: `Int64(bitPattern: item.persistentID.uint64Value)`.
    /// The join key to MusicKit (100% match on this library). Nil for folder tracks.
    var persistentID: Int64?
    /// MusicKit `Song.id.rawValue`. Present when MusicKit can stream it.
    var cloudID: String?
    /// Apple Music catalog id from `StoreItemID`. 0 = none.
    var storeItemID: Int64

    // MARK: Tags

    var title: String
    var artist: String
    var album: String
    var albumArtist: String
    var composer: String
    var genre: String
    var comments: String
    var grouping: String
    var year: Int
    var trackNumber: Int
    var trackCount: Int
    var discNumber: Int
    var discCount: Int
    var bpm: Int

    // MARK: Library facts

    var duration: TimeInterval
    /// Nil when the library has no date (52 songs). Sorts last under "newest first".
    var dateAdded: Date?
    var playCount: Int
    /// 0...100, like the Music library stores it.
    var rating: Int
    /// "MPEG audio file", "Matched AAC audio file", etc. Shown in Get Info, like iTunes did.
    var kind: String
    var bitRate: Int
    var sampleRate: Int
    var fileSize: Int64
    var hasArtwork: Bool
    /// Album persistent id; the artwork cache key. 0 = unknown.
    var albumPID: Int64

    // MARK: Where the audio is

    var bucket: Bucket
    /// The Music library marks this as an iTunes Match / iCloud Music Library track.
    var isCloud: Bool
    /// `ITLibMediaItemLocationType` raw value (0 unknown, 1 file, 2 URL, 3 remote).
    var locationType: Int
    /// A local file we can decode ourselves. Nil for cloud-only tracks.
    var fileURL: URL?
    /// "Part of a compilation" (ITLibAlbum.isCompilation, MP4 cpil, ID3 TCMP). Defaulted so the
    /// memberwise initializer stays source-compatible for callers written before it existed.
    var isCompilation = false
    /// The per-song checkbox. iTunes skipped unchecked songs when playing through a list or shuffling,
    /// but still played one you double-clicked. Starts from the Music library's own state
    /// (`!ITLibMediaItem.isUserDisabled`); oldTunes keeps its own changes in the index.
    var isChecked = true
    /// Music's Sound Check value for the song (`ITLibMediaItem.volumeNormalizationEnergy`); 0 when
    /// Music has none. Playback turns it into a gain with `SoundCheck.gain(energy:)`.
    var soundCheckEnergy = 0

    var isLocal: Bool { fileURL != nil }
    /// In your library, not on this disk. Shown with a cloud badge.
    var isCloudOnly: Bool { fileURL == nil && bucket == .cloud }
    /// File tags are writable; cloud-only tags are written through Music.app instead.
    var hasWritableFile: Bool { fileURL != nil }
}

extension Track {
    /// Empty track for new rows, tests, and previews.
    static func blank(id: ID = 0) -> Track {
        Track(id: id, origin: .musicLibrary, persistentID: nil, cloudID: nil, storeItemID: 0,
              title: "", artist: "", album: "", albumArtist: "", composer: "", genre: "",
              comments: "", grouping: "", year: 0, trackNumber: 0, trackCount: 0,
              discNumber: 0, discCount: 0, bpm: 0, duration: 0, dateAdded: nil, playCount: 0,
              rating: 0, kind: "", bitRate: 0, sampleRate: 0, fileSize: 0, hasArtwork: false,
              albumPID: 0, bucket: .cloud, isCloud: false, locationType: 0, fileURL: nil)
    }

    /// What the Name column shows when the title tag is missing (iTunes showed the file name).
    var displayTitle: String {
        if !title.isEmpty { return title }
        return fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    /// Album-level artist for grouping, falling back to the track artist.
    var effectiveAlbumArtist: String { albumArtist.isEmpty ? artist : albumArtist }

    /// Whether two songs are on one album, for ⌥← and ⌥→. Music's album id decides when both songs
    /// have one. Folder songs have none, so they go by album name and album artist; a compilation's
    /// songs, whose artists differ, by the name alone.
    func isOnSameAlbum(as other: Track) -> Bool {
        if albumPID != 0, other.albumPID != 0 { return albumPID == other.albumPID }
        guard album.caseInsensitiveCompare(other.album) == .orderedSame else { return false }
        return (isCompilation && other.isCompilation)
            || effectiveAlbumArtist.caseInsensitiveCompare(other.effectiveAlbumArtist) == .orderedSame
    }
}

/// Columns the user can click to sort. The four the user asked for come first. Raw values are
/// saved in UserDefaults (the track list's last header sort), so never rename one.
enum TrackSortField: String, Sendable, CaseIterable {
    case name, artist, album, dateAdded, time, genre, year, playCount
    /// A playlist's own order (iTunes restored it from the leftmost column header). Outside a
    /// playlist there is no such order, so the index falls back to artist order.
    case playlistOrder
}

struct TrackSort: Sendable, Hashable {
    var field: TrackSortField
    var ascending: Bool

    static let `default` = TrackSort(field: .artist, ascending: true)
}
