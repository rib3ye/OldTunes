import Foundation

/// Settings ▸ Sound Check, Music's setting of the same name. Off until turned on, as in Music.
/// Settings previews a click at once (the song playing changes level), OK saves it, and Cancel
/// puts back what was on before, the same as the Appearance choice. AppController hands every
/// change to the player.
@MainActor
enum SoundCheckPreference {
    static let defaultsKey = "OldTunes.soundCheck"

    static var saved: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    /// What the player uses right now: the saved setting, or a Settings preview.
    private(set) static var current = saved

    /// `save: false` is a preview, which Settings keeps on OK and undoes on Cancel.
    static func choose(_ on: Bool, save: Bool) {
        if save { UserDefaults.standard.set(on, forKey: defaultsKey) }
        guard on != current else { return }
        current = on
        Log.info("sound check: \(on ? "on" : "off")\(save ? "" : " (preview)")")
        NotificationCenter.default.post(name: .soundCheckDidChange, object: nil)
    }
}

extension Notification.Name {
    /// Posted on the main thread when `SoundCheckPreference.current` changes.
    static let soundCheckDidChange = Notification.Name("OldTunes.soundCheckDidChange")
}
