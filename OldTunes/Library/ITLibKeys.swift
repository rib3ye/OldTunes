import Darwin
import Foundation

/// Property keys for the two iTunesLibrary fields that have no typed property.
///
/// The constants are exported from iTunesLibrary.framework but declared in no public header, so
/// Swift cannot name them. Their string values are short names unrelated to the symbol names
/// (RESEARCH.md §8.6), so the value is read from the exported `NSString *` at runtime and the
/// documented literal is only a fallback.
enum ITLibKeys {
    struct Key: Sendable {
        var value: String
        /// False when dlsym found nothing and the literal fallback is in use.
        var fromSymbol: Bool
    }

    static let storeItemID = resolve("ITLibMediaItemPropertyStoreItemID", fallback: "StoreItemID")
    static let albumPersistentID = resolve("ITLibMediaItemPropertyAlbumPersistentID", fallback: "AlbumPersistentID")

    private static func resolve(_ symbol: String, fallback: String) -> Key {
        // RTLD_DEFAULT is a C macro cast Swift cannot import; its value is -2.
        let everywhere = UnsafeMutableRawPointer(bitPattern: -2)
        guard let address = dlsym(everywhere, symbol) else { return Key(value: fallback, fromSymbol: false) }
        let string = address.assumingMemoryBound(to: NSString?.self).pointee
        guard let string else { return Key(value: fallback, fromSymbol: false) }
        return Key(value: string as String, fromSymbol: true)
    }
}
