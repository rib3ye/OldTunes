import Foundation

/// The strings iTunes 4.9's Summary tab showed, in its own formats ("3.4 MB", "128 kbps",
/// "44.100 kHz"), so the technical block reads like the original.
enum GetInfoFormat {
    static func size(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "—" }
        let mb = Double(bytes) / 1_048_576
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }

    static func bitRate(_ kbps: Int) -> String {
        kbps > 0 ? "\(kbps) kbps" : "—"
    }

    static func sampleRate(_ hz: Int) -> String {
        hz > 0 ? String(format: "%.3f kHz", Double(hz) / 1000) : "—"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Shown in the Mac's own time zone (Noah's is America/Los_Angeles), the way iTunes did.
    static func date(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: date)
    }

    static func kind(_ track: Track) -> String {
        if !track.kind.isEmpty { return track.kind }
        guard let ext = track.fileURL?.pathExtension.lowercased(), !ext.isEmpty else { return "—" }
        switch ext {
        case "mp3": return "MPEG audio file"
        case "m4a": return "AAC audio file"
        case "aif", "aiff": return "AIFF audio file"
        case "wav", "wave": return "WAV audio file"
        case "flac": return "FLAC audio file"
        default: return "\(ext.uppercased()) audio file"
        }
    }

    static func whereText(_ track: Track, maxCharacters: Int = .max) -> String {
        if let url = track.fileURL { return middleTruncated(url.path, columns: maxCharacters) }
        return track.isCloudOnly || track.isCloud ? "iCloud Music Library" : "—"
    }

    /// A path too long for its box loses its middle, never its end: the file name is the part
    /// a person is looking for. Full-width characters count as two columns, as Monaco draws them.
    static func middleTruncated(_ path: String, columns: Int) -> String {
        func width(_ c: Character) -> Int { c.unicodeScalars.contains { $0.value >= 0x1100 } ? 2 : 1 }
        let chars = Array(path)
        guard chars.reduce(0, { $0 + width($1) }) > columns, columns > 8 else { return path }
        let budget = columns - 1
        var head: [Character] = [], tail: [Character] = []
        var used = 0, i = 0, j = chars.count - 1
        // Spend two thirds of the room on the end (folder + file name), the rest on the start.
        while i <= j {
            let takeTail = tail.count * 1 <= head.count * 2
            let c = takeTail ? chars[j] : chars[i]
            guard used + width(c) <= budget else { break }
            used += width(c)
            if takeTail { tail.insert(c, at: 0); j -= 1 } else { head.append(c); i += 1 }
        }
        return String(head) + "…" + String(tail)
    }
}
