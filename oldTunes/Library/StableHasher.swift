import Foundation

/// 64-bit FNV-1a. Swift's `Hasher` is seeded per process, so its values cannot be stored and
/// compared on the next launch; this one can, which is what lets a re-ingest skip unchanged rows.
struct StableHasher {
    private var state: UInt64 = 0xcbf2_9ce4_8422_2325
    private static let prime: UInt64 = 0x0000_0100_0000_01b3

    mutating func combine(_ text: String) {
        // Strings from iTunesLibrary are bridged NSStrings; withUTF8 makes them contiguous once
        // instead of transcoding byte by byte through the UTF-8 view.
        var text = text
        var h = state
        text.withUTF8 { bytes in
            for byte in bytes { h = (h ^ UInt64(byte)) &* Self.prime }
        }
        state = h
        mix(0xFF)   // never occurs in UTF-8, so "ab"+"c" and "a"+"bc" differ
    }

    mutating func combine(_ text: String?) {
        if let text { mix(1); combine(text) } else { mix(0) }
    }

    mutating func combine(_ value: Int64) {
        var bits = UInt64(bitPattern: value)
        for _ in 0..<8 {
            mix(UInt8(truncatingIfNeeded: bits))
            bits >>= 8
        }
    }

    mutating func combine(_ value: Int64?) {
        if let value { mix(1); combine(value) } else { mix(0) }
    }

    mutating func combine(_ value: Int) { combine(Int64(value)) }
    mutating func combine(_ value: Bool) { mix(value ? 1 : 0) }

    var value: Int64 { Int64(bitPattern: state) }

    private mutating func mix(_ byte: UInt8) {
        state = (state ^ UInt64(byte)) &* Self.prime
    }
}
