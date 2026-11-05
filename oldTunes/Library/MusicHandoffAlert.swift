import Foundation

/// The one alert after an Add Folder that handed songs to Music (AppController shows it). It
/// names every file that stayed oldTunes-only, so no song silently misses iCloud Music Library.
extension MusicHandoffReport {
    struct Alert: Sendable, Equatable {
        var message: String
        var informative: String
        /// One file per line, relative to its added folder.
        var details: String
    }

    /// Nil when Music took every new file: the songs simply appear, as they did in iTunes.
    static func alert(for reports: [MusicHandoffReport]) -> Alert? {
        let named = reports.count > 1
        let refused = reports.flatMap { report in report.refused.map { report.displayName($0, withFolder: named) } }
        let notSent = reports.flatMap { report in report.notSent.map { report.displayName($0, withFolder: named) } }
        let missed = refused.count + notSent.count
        guard missed > 0 else { return nil }
        let offered = missed + reports.reduce(0) { $0 + $1.handedOff.count }

        let message: String
        if missed == offered {
            message = missed == 1 ? "The song wasn’t added to the Music app." : "The songs weren’t added to the Music app."
        } else {
            message = "\(missed) of the \(offered) songs \(missed == 1 ? "wasn’t" : "weren’t") added to the Music app."
        }

        var sentences: [String] = []
        if let reason = reports.lazy.compactMap(\.stopReason).first { sentences.append(reason) }
        if !refused.isEmpty {
            sentences.append(refused.count == 1 ? "Music didn’t accept one file." : "Music didn’t accept \(refused.count) files.")
        }
        sentences.append(missed == 1
            ? "It’s in oldTunes, but not in Music, so it won’t reach your iCloud Music Library."
            : "They’re in oldTunes, but not in Music, so they won’t reach your iCloud Music Library.")
        if !notSent.isEmpty {
            sentences.append("To try again, choose Add Folder to Library again with “Also add to the Music app” on.")
        }

        let details: String
        if refused.isEmpty || notSent.isEmpty {
            details = (refused + notSent).joined(separator: "\n")
        } else {
            details = (["Music didn’t accept:"] + refused + ["", "Not sent to Music:"] + notSent).joined(separator: "\n")
        }
        return Alert(message: message, informative: sentences.joined(separator: " "), details: details)
    }

    /// A file as the user knows it: its path inside the folder they picked, and with several
    /// folders picked, that folder's name in front.
    func displayName(_ path: String, withFolder: Bool) -> String {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        let inside = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : (path as NSString).lastPathComponent
        return withFolder ? (root as NSString).lastPathComponent + "/" + inside : inside
    }
}
