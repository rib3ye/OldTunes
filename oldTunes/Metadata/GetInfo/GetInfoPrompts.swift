import AppKit

/// The three sheets Get Info can raise before or after saving.
@MainActor
enum GetInfoPrompts {
    /// UserDefaults key for the §6.6 sheet's "Don't show again" box.
    static let suppressFileWarningKey = "OldTunesSuppressFileTagWarning"
    /// Shown at most once per launch even without the box ticked, so a run of edits is not
    /// interrupted every time.
    private static var fileWarningShownThisLaunch = false

    /// Lets the harness show the sheet again in a launch that already showed it.
    static func resetFileWarningForThisLaunch() { fileWarningShownThisLaunch = false }

    static var shouldShowFileWarning: Bool {
        !fileWarningShownThisLaunch && !UserDefaults.standard.bool(forKey: suppressFileWarningKey)
    }

    /// RESEARCH.md §6.6: a direct file edit leaves Music showing old values until it re-reads
    /// the file. Only an added-folder song's file is written directly, so only those ask this;
    /// Music-library songs are saved through Music. Returns false if the user cancelled.
    static func confirmFileEdit(on window: NSWindow) async -> Bool {
        let sheet = AquaSheet(
            message: "Change the information in this song’s file?",
            informative: "This song was added from a folder, so oldTunes saves the change straight into its file "
                + "on this Mac. If the same file is also in your Music library, Music may keep showing the old "
                + "information until it re-reads the file.",
            checkboxTitle: "Don’t show again",
            buttons: ["Cancel", "OK"], cancelIndex: 0)
        let result = await sheet.run(on: window)
        guard result.buttonIndex == 1 else { return false }
        fileWarningShownThisLaunch = true
        if result.checkboxOn { UserDefaults.standard.set(true, forKey: suppressFileWarningKey) }
        return true
    }

    /// Shown before macOS asks for Automation permission, so the system prompt arrives with
    /// context (§6.5). Returns false for "Not Now".
    static func explainAutomation(on window: NSWindow) async -> Bool {
        let sheet = AquaSheet(
            message: "oldTunes needs to ask Music to save these changes.",
            informative: "Music keeps the information for the songs in your library, so oldTunes saves changes to "
                + "them through Music. Music then updates its library, and the song’s file too if it has one on "
                + "this Mac. macOS will now ask whether oldTunes may control Music — click OK there to allow it. "
                + "oldTunes only changes song information; it never plays anything in Music.",
            buttons: ["Not Now", "Continue"], cancelIndex: 0)
        return await sheet.run(on: window).buttonIndex == 1
    }

    /// Partial failures, one line per song.
    static func showFailures(_ lines: [String], savedCount: Int, on window: NSWindow) async {
        let message = lines.count == 1 ? "One song’s changes couldn’t be saved."
                                       : "\(lines.count) songs’ changes couldn’t be saved."
        let informative = savedCount > 0
            ? "The other \(savedCount == 1 ? "song was" : "\(savedCount) songs were") saved."
            : "Nothing was changed."
        let sheet = AquaSheet(message: message, informative: informative,
                              details: lines.joined(separator: "\n"), buttons: ["OK"], cancelIndex: 0)
        _ = await sheet.run(on: window)
    }
}
