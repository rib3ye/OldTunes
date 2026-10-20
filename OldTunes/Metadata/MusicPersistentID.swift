import Foundation

/// Converts between the index's persistent id (an Int64 bit pattern) and the string form
/// Music.app's scripting dictionary uses for `persistent ID`.
///
/// AppleScript reports a track's persistent ID as the unsigned 64-bit value in exactly 16
/// uppercase hex digits, zero-padded ("0A1B2C3D4E5F6071"). The index stores the same 64 bits as
/// a signed Int64 (SQLite has no unsigned type), so half of all ids are negative there and a
/// naive `String(id, radix: 16)` would produce "-…" strings that match nothing in Music.
enum MusicPersistentID {
    static func hex(_ bitPattern: Int64) -> String {
        let digits = String(UInt64(bitPattern: bitPattern), radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, 16 - digits.count)) + digits
    }

    /// Nil unless the string is exactly 16 hex digits, so a malformed id can never widen a
    /// `whose persistent ID is …` query into matching the wrong track.
    static func bitPattern(fromHex hex: String) -> Int64? {
        guard hex.count == 16, hex.allSatisfy(\.isHexDigit), let value = UInt64(hex, radix: 16) else {
            return nil
        }
        return Int64(bitPattern: value)
    }
}
