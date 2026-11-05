import Foundation

/// Settings ▸ Visualizer: whether the visualizer uses HDR (brighter than white) on screens that
/// can show it. On unless the user turns it off. Like Appearance, a click in Settings previews at
/// once; OK keeps it and Cancel puts back what was showing.
@MainActor
enum VisualizerPreference {
    static let hdrKey = "OldTunes.Visualizer.hdr"
    /// Posted when `currentHDR` changes, so a running visualizer switches.
    static let didChange = Notification.Name("OldTunesVisualizerPreferenceDidChange")

    /// The saved choice: on until the user turns it off.
    static var savedHDR: Bool {
        UserDefaults.standard.object(forKey: hdrKey) as? Bool ?? true
    }

    /// What applies right now: the saved choice or a Settings preview.
    private(set) static var currentHDR: Bool = savedHDR

    /// Shows `on` at once. `save: false` is a preview, which Settings keeps on OK and undoes on Cancel.
    static func chooseHDR(_ on: Bool, save: Bool) {
        if save { UserDefaults.standard.set(on, forKey: hdrKey) }
        guard on != currentHDR else { return }
        currentHDR = on
        Log.info("visualizer: HDR \(on ? "on" : "off")\(save ? "" : " (preview)")")
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
