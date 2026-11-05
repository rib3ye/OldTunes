import Foundation

/// One Music.app playlist as stored in the `playlist` table.
struct PlaylistRecord: Sendable {
    var info: PlaylistInfo
    var sortIndex: Int
    /// Member songs by persistent id, in playlist order. Non-song items are already dropped.
    var memberPIDs: [Int64]
}

extension PlaylistInfo.Kind {
    var storedValue: Int {
        switch self {
        case .regular: 0
        case .smart: 1
        case .folder: 2
        case .genius: 3
        }
    }

    init(storedValue: Int) {
        switch storedValue {
        case 1: self = .smart
        case 2: self = .folder
        case 3: self = .genius
        default: self = .regular
        }
    }
}
