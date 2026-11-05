import Foundation
import SQLite3

/// Builds `Track` values from `song` rows by column position, straight off the C API.
///
/// The UI asks for all 15,900 rows at once whenever the list changes. Through GRDB's `Row` that
/// took 93-110 ms in a Debug build (a generic decode per column per row); reading the columns
/// directly took 36-40 ms.
enum TrackRowDecoder {
    static let columns = [
        "id", "origin", "persistent_id", "cloud_id", "store_item_id",                          // 0-4
        "title", "artist", "album", "album_artist", "composer", "genre", "comments", "grouping", // 5-12
        "year", "track_number", "track_count", "disc_number", "disc_count", "bpm",            // 13-18
        "total_time_ms", "added_at", "play_count", "rating", "kind",                          // 19-23
        "bit_rate", "sample_rate", "file_size", "has_artwork", "album_pid",                   // 24-28
        "bucket", "is_cloud", "location_type", "location_path",                               // 29-32
        // New columns go at the end so no index above moves (the scan in `tracks(ids:)` reads 0).
        "is_compilation",                                                                     // 33
        // The checkbox shown: oldTunes' own choice when there is one, else the source's.
        "COALESCE(checked_override, is_checked)",                                             // 34
        "sound_check_energy",                                                                 // 35
    ]
    static let columnList = columns.joined(separator: ", ")

    /// The track on the statement's current row. The statement must select `columnList`.
    static func track(_ s: OpaquePointer) -> Track {
        func int64(_ i: Int32) -> Int64 { sqlite3_column_int64(s, i) }
        func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(s, i)) }
        func bool(_ i: Int32) -> Bool { sqlite3_column_int64(s, i) != 0 }
        func isNull(_ i: Int32) -> Bool { sqlite3_column_type(s, i) == SQLITE_NULL }
        func text(_ i: Int32) -> String {
            guard let bytes = sqlite3_column_text(s, i) else { return "" }
            return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(s, i))), as: UTF8.self)
        }

        let addedAt = int64(20)
        let bucket = Track.Bucket(rawValue: int(29)) ?? .cloud
        let path = isNull(32) ? nil : text(32)
        return Track(
            id: int64(0),
            origin: Track.Origin(rawValue: int(1)) ?? .musicLibrary,
            persistentID: isNull(2) ? nil : int64(2),
            cloudID: isNull(3) ? nil : text(3),
            storeItemID: int64(4),
            title: text(5), artist: text(6), album: text(7), albumArtist: text(8), composer: text(9),
            genre: text(10), comments: text(11), grouping: text(12),
            year: int(13), trackNumber: int(14), trackCount: int(15), discNumber: int(16), discCount: int(17),
            bpm: int(18),
            duration: Double(int64(19)) / 1000,
            dateAdded: addedAt == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(addedAt)),
            playCount: int(21), rating: int(22), kind: text(23),
            bitRate: int(24), sampleRate: int(25), fileSize: int64(26), hasArtwork: bool(27), albumPID: int64(28),
            bucket: bucket, isCloud: bool(30), locationType: int(31),
            // Only a file that was on disk at ingest is offered for playback; a missing one is not.
            fileURL: bucket == .local ? path.map { URL(fileURLWithPath: $0) } : nil,
            isCompilation: bool(33),
            isChecked: bool(34),
            soundCheckEnergy: int(35))
    }
}
