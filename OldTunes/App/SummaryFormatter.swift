import Foundation

/// The bottom bar's summary, worded the way iTunes 4.9 did: "3293 songs, 9.3 days, 18.59 GB".
enum SummaryFormatter {
    static func string(for summary: LibrarySummary) -> String {
        guard summary.count > 0 else { return "" }
        let songs = summary.count == 1 ? "1 song" : "\(summary.count.formatted()) songs"
        return "\(songs), \(duration(summary.totalSeconds)), \(size(summary.totalBytes))"
    }

    static func duration(_ seconds: Double) -> String {
        let minutes = seconds / 60, hours = minutes / 60, days = hours / 24
        if days >= 1 { return "\(one(days)) days" }
        if hours >= 1 { return "\(one(hours)) hours" }
        return "\(one(minutes)) minutes"
    }

    static func size(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576, gb = mb / 1024
        if gb >= 1 { return String(format: "%.2f GB", gb) }
        return String(format: "%.1f MB", mb)
    }

    private static func one(_ value: Double) -> String { String(format: "%.1f", value) }
}
