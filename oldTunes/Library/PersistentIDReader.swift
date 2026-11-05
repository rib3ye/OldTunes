import Foundation
import MusicKit

/// Extracts the join key from a library `Song`.
///
/// `Song.id` is a library id ("i.AbCdEfGhIjK") with no numeric relation to iTunesLibrary. The
/// persistent id is only inside `playParameters`, which is opaque except through `Codable`: its
/// JSON carries `"musicKit_persistentID": "-1234567890123456789"`, a signed decimal that equals
/// `Int64(bitPattern: ITLibMediaItem.persistentID)`. Measured on this library before writing
/// this: 15,900 of 15,900 songs carry it.
struct PersistentIDReader {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func persistentID(of song: Song) -> Int64? {
        guard let parameters = song.playParameters,
              let json = try? encoder.encode(parameters),
              let keys = try? decoder.decode(Keys.self, from: json) else { return nil }
        return keys.persistentID
    }

    private struct Keys: Decodable {
        var persistentID: Int64?

        enum CodingKeys: String, CodingKey { case persistentID = "musicKit_persistentID" }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let text = try? container.decode(String.self, forKey: .persistentID) {
                persistentID = Int64(text) ?? UInt64(text).map { Int64(bitPattern: $0) }
            } else {
                persistentID = try? container.decode(Int64.self, forKey: .persistentID)
            }
        }
    }
}
