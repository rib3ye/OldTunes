import Foundation

/// Property keys for the two iTunesLibrary fields that have no typed property.
///
/// The constants (`ITLibMediaItemPropertyStoreItemID`, `ITLibMediaItemPropertyAlbumPersistentID`)
/// are exported from iTunesLibrary.framework but declared in no public header, so Swift cannot name
/// them. Their string values are short names unrelated to the symbol names (RESEARCH.md §8.6); these
/// are the values the exported symbols held on macOS 27 (checked 2026-10-27). They are written out
/// rather than looked up with dlsym, which reaches for a non-public symbol. If a macOS ever changes
/// them, both fields read as 0: the library harness's StoreItemID count catches that, and album
/// grouping falls back to the typed album persistentID.
enum ITLibKeys {
    static let storeItemID = "StoreItemID"
    static let albumPersistentID = "AlbumPersistentID"
}
