import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// NSApplication holds its delegate weakly, so the app keeps it alive here.
    private static var shared: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        shared = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Light, Dark (Graphite) or Match System, from Settings, before any window exists.
        AppearancePreference.applyAtLaunch()
        NSApp.mainMenu = MainMenu.make()
        Snapshot.scheduleFromEnvironment()

        // OLDTUNES_HARNESS launches straight into one module's test bench (see each *Harness.swift).
        // Pass it with:  open -n --env OLDTUNES_HARNESS=<name> build/dd/Build/Products/Debug/OldTunes.app
        let harness = ProcessInfo.processInfo.environment["OLDTUNES_HARNESS"] ?? ""
        Log.info("launch: harness=\(harness.isEmpty ? "(none)" : harness)")
        Task { @MainActor in
            switch harness {
            case "authcheck": await AuthCheck.run(); Log.flush(); NSApp.terminate(nil)
            case "library":   await LibraryHarness.run()
            case "playback":  await PlaybackHarness.run()
            case "metadata":  await MetadataHarness.run()
            case "chrome":    await ChromeHarness.run()
            case "lists":     await ListsHarness.run()
            case "appearance": await AppearanceHarness.run()
            case "visualizer": await VisualizerHarness.run()
            case "smoke":     await AppAssembly.launch(smokeTest: true)
            case "musictag":  await MusicTagLiveTest.run()
            case "musicadd":  await MusicAddLiveTest.run()
            case "musicplaylists": await MusicPlaylistLiveTest.run()
            default:          await AppAssembly.launch()
            }
        }
    }

    /// OldTunes ▸ Settings… (⌘,). Reached through the responder chain, so it works in every launch.
    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.show()
    }

    /// iTunes kept playing with its window closed; a Dock click or ⌘1 brings the window back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Always reopen the main window: with only a Get Info window open, `hasVisibleWindows` is true
    /// even though the main window is gone.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppAssembly.showMainWindow()
        return true
    }
}
