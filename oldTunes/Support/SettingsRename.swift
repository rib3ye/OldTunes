import Foundation

/// Settings saved before the app was renamed oldTunes (November 2026) sit under keys that begin
/// "OldTunes" ("OldTunes.volume", "NSWindow Frame OldTunesMainWindow", …). Defaults keys match
/// letter for letter, so each one is moved to its oldTunes key once, before anything reads them.
/// A key that already has a value under the new name keeps it. Remove this once no copy from
/// before the rename is left (any copy that has opened since has moved its settings).
enum SettingsRename {
    /// Kept by releases up to November 2026 for a System Audio Recording check that is gone.
    private static let dropped: Set<String> = ["OldTunes.systemAudioRecording"]

    static func moveOldKeys(in defaults: UserDefaults = .standard, domain: String? = Bundle.main.bundleIdentifier) {
        guard let domain,
              let saved = defaults.persistentDomain(forName: domain) else { return }
        var moved = 0
        for (key, value) in saved {
            guard let new = renamed(key) else { continue }
            if !dropped.contains(key), saved[new] == nil {
                defaults.set(value, forKey: new)
                moved += 1
            }
            defaults.removeObject(forKey: key)
        }
        if moved > 0 { Log.info("launch: moved \(moved) settings from OldTunes keys to oldTunes keys") }
    }

    /// The oldTunes key for a key saved under the old name, or nil for any other key.
    static func renamed(_ key: String) -> String? {
        for prefix in ["OldTunes", "NSWindow Frame OldTunes"] where key.hasPrefix(prefix) {
            return prefix.replacingOccurrences(of: "OldTunes", with: "oldTunes") + key.dropFirst(prefix.count)
        }
        return nil
    }
}
