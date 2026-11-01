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
        // Before anything plays: Apple's cloud players already running are someone else's, so the
        // ones that start later are ours (AudioHAL.ourRemotePlayers).
        let notOurs = AudioHAL.noteRemotePlayersAtLaunch()
        // Light, Dark (Graphite) or Match System, from Settings, before any window exists.
        AppearancePreference.applyAtLaunch()
        NSApp.mainMenu = MainMenu.make()
        #if BENCHES
        Snapshot.scheduleFromEnvironment()
        #endif

        // OLDTUNES_HARNESS launches straight into one module's test bench (see each *Harness.swift).
        // Pass it with:  open -n --env OLDTUNES_HARNESS=<name> build/dd/Build/Products/Debug/OldTunes.app
        // Only Debug and Bench builds have the benches (LaunchEnvironment).
        let harness = LaunchEnvironment.bench ?? ""
        Log.info("launch: harness=\(harness.isEmpty ? "(none)" : harness)")
        // Where this run keeps its settings and index, and how many settings it found: in the
        // sandbox that is the container, which nothing outside the app can look into, so this
        // line is how a first sandboxed launch shows that macOS moved the old ones in.
        let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        let settings = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?
            .keys.filter { $0.hasPrefix("OldTunes") }.count ?? 0
        Log.info("launch: \(sandboxed ? "sandboxed" : "not sandboxed"), home \(NSHomeDirectory()), \(settings) OldTunes settings")
        if !notOurs.isEmpty {
            Log.info("cloud: RemotePlayerService running before OldTunes started, so not ours: \(notOurs)")
        }
        Task { @MainActor in
            #if BENCHES
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
            case "musicwebchecks": await MusicWebPlaylistHarness.run()
            case "musicwebplaylists": await MusicWebPlaylistLiveTest.run()
            case "musicdownload": await MusicDownloadLiveTest.run()
            case "musicaccess": await MusicAccessProbe.run()
            default:          await AppAssembly.launch()
            }
            #else
            await AppAssembly.launch()
            #endif
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

    /// Right-click on the Dock icon: the song playing and the playback controls (DockMenu).
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { AppAssembly.dockMenu() }
}
