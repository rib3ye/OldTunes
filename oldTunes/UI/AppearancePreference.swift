import AppKit

/// Settings ▸ Appearance. Raw values are what UserDefaults stores, so never rename one.
enum AppearanceMode: String, CaseIterable, Sendable {
    case light, dark, system

    /// What Settings calls it.
    var title: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        case .system: "Match System"
        }
    }
}

/// Light (the 2005 look), Dark (Graphite, RESEARCH.md §7.7), or Match System, applied to the
/// whole app through `NSApp.appearance`, so every window follows it, and the system-drawn menus
/// and Open panel with them.
///
/// Match System leaves `NSApp.appearance` nil. AppKit then follows System Settings ▸ Appearance,
/// including its Auto setting, which switches the Mac at sunset with oldTunes along with it.
@MainActor
enum AppearancePreference {
    static let defaultsKey = "oldTunes.appearance"

    /// The saved choice. Match System until the user picks one.
    static var saved: AppearanceMode {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(AppearanceMode.init(rawValue:)) ?? .system
    }

    /// What is applied right now: the saved choice, a Settings preview, or a launch override.
    private(set) static var current: AppearanceMode = .system

    /// Before any window exists. In Debug and Bench builds (LaunchEnvironment),
    /// OLDTUNES_APPEARANCE=light|dark|system sets this launch's appearance without saving it. Test
    /// benches start in Light whatever is saved, because their pixel checks compare against the
    /// 2005 measurements (§7.1); pass OLDTUNES_APPEARANCE=dark to run one in the dark.
    static func applyAtLaunch() {
        let override = LaunchEnvironment.value("OLDTUNES_APPEARANCE").flatMap(AppearanceMode.init(rawValue:))
        let isHarness = LaunchEnvironment.bench != nil
        apply(override ?? (isHarness ? .light : saved))
        // Under Match System the system can change the look at any moment (a click in System
        // Settings, or Auto at sunset); AppKit redraws, this catches cached art too.
        systemObservation = NSApp.observe(\.effectiveAppearance) { _, _ in
            Task { @MainActor in redrawAllWindows() }
        }
    }

    /// Shows `mode` at once. `save: false` is a preview, which Settings keeps on OK and
    /// undoes on Cancel.
    static func choose(_ mode: AppearanceMode, save: Bool) {
        if save { UserDefaults.standard.set(mode.rawValue, forKey: defaultsKey) }
        guard mode != current else { return }
        apply(mode)
        Log.info("appearance: \(mode.rawValue)\(save ? "" : " (preview)")")
    }

    private static var systemObservation: NSKeyValueObservation?

    private static func apply(_ mode: AppearanceMode) {
        current = mode
        NSApp.appearance = switch mode {
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        case .system: nil
        }
        redrawAllWindows()
    }

    /// AppKit redraws a view whose appearance changed, but a view that cached art for the old
    /// look would show it until something else dirtied it. Marking every view is a few hundred
    /// flags, once per switch, and leaves nothing to chance.
    static func redrawAllWindows() {
        func mark(_ view: NSView) {
            view.needsDisplay = true
            view.subviews.forEach(mark)
        }
        for window in NSApp.windows { window.contentView.map(mark) }
    }
}
