import AppKit

/// OLDTUNES_HARNESS=appearance — test bench for Light, Dark and Match System (RESEARCH.md §7.7).
///
/// Builds the real main window over an INVENTED library (made-up bands, songs and playlists, so
/// every picture is safe to share), then:
///   1. photographs the main window, the browser, Settings, an alert sheet and Get Info in
///      Light and in Dark, and pixel-checks the photos against Theme's two values,
///   2. switches the live window and checks it redrew without anything else asking it to,
///   3. checks Match System hands the choice back to macOS,
///   4. drives Settings: a pick previews without saving, Cancel, Escape and the close button
///      put the old look back, OK and Return save, and the menu item opens it.
/// The saved appearance and the window layout it starts from (columns, browser, source width, and
/// where Settings opens) are put back exactly as they were. Pictures go to
/// $OLDTUNES_APPEARANCE_OUT (default: $TMPDIR/oldtunes-appearance).
@MainActor
enum AppearanceHarness {
    private typealias Probe = ChromeHarnessProbe
    private static var passed = 0
    private static var failed = 0

    /// What the bench changes in the app's real defaults, put back when it ends: it runs with the
    /// app's own bundle id, so these are the user's saved settings. Opening Settings saves its
    /// window's frame on this screen, over the one the user left.
    private static let restoredKeys = [AppearancePreference.defaultsKey, TrackColumnLayout.defaultsKey,
                                       "OldTunes.TrackList.browserVisible", "OldTunes.TrackList.browserFraction",
                                       "OldTunes.SourceList.expandedFolders", MetalContentView.sourceWidthDefaultsKey,
                                       SettingsWindowController.frameDefaultsKey]

    static func run() async {
        let out = outputDirectory()
        let defaults = UserDefaults.standard
        let saved = restoredKeys.map { ($0, defaults.object(forKey: $0)) }
        let originalChoice = defaults.object(forKey: AppearancePreference.defaultsKey)
        Log.info("appearance harness: writing to \(out.path); saved choice \(originalChoice.map { "\($0)" } ?? "(none)")")

        tokenChecks()
        let main = await MainWindow.build()
        await pictures(main, out: out)
        await liveSwitchChecks(main)
        await matchSystemChecks()
        await settingsChecks(out: out)

        for (key, value) in saved {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        let restored = saved.allSatisfy { key, value in
            (defaults.object(forKey: key) as? NSObject) == (value as? NSObject)
        }
        check("saved settings put back", restored,
              "appearance \(originalChoice.map { "\($0)" } ?? "(none)"), \(saved.filter { $0.1 != nil }.count) layout keys")
        Log.info("appearance harness: \(passed) PASS, \(failed) FAIL")
        Log.flush()
        NSApp.terminate(nil)
    }

    // MARK: - Reporting

    private static func outputDirectory() -> URL {
        let env = ProcessInfo.processInfo.environment["OLDTUNES_APPEARANCE_OUT"] ?? ""
        let url = env.isEmpty ? FileManager.default.temporaryDirectory.appendingPathComponent("oldtunes-appearance")
                              : URL(fileURLWithPath: env)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func check(_ name: String, _ ok: Bool, _ detail: String) {
        if ok { passed += 1 } else { failed += 1 }
        let line = "appearance: \(ok ? "PASS" : "FAIL") \(name): \(detail)"
        if ok { Log.info(line) } else { Log.error(line) }
    }

    private static func snapshot(_ window: NSWindow?, _ name: String, out: URL) -> ChromeHarnessProbe.Pixels? {
        guard let window else {
            check("snapshot \(name)", false, "no window")
            return nil
        }
        let url = out.appendingPathComponent(name)
        guard Snapshot.write(window, to: url) else {
            check("snapshot \(name)", false, "Snapshot.write failed")
            return nil
        }
        Log.info("snapshot written: \(url.path) (\(Int(window.frame.width))x\(Int(window.frame.height)) pt)")
        return ChromeHarnessProbe.Pixels(url: url, pointWidth: window.frame.width)
    }

    /// `color` as 8-bit sRGB in one appearance.
    private static func rgb(_ color: NSColor, dark: Bool) -> Int {
        var value = 0
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            guard let c = color.usingColorSpace(.sRGB) else { return }
            let byte = { (v: CGFloat) in Int((v * 255).rounded()) }
            value = byte(c.redComponent) << 16 | byte(c.greenComponent) << 8 | byte(c.blueComponent)
        }
        return value
    }

    private static func pixelCheck(_ name: String, _ px: ChromeHarnessProbe.Pixels, _ p: NSPoint,
                                   _ color: NSColor, dark: Bool, tolerance: Int) {
        let want = rgb(color, dark: dark)
        let got = px.rgb(p.x, p.y)
        check(name, Probe.near(got, want, tolerance: tolerance),
              "\(Probe.hex(got)) at (\(p.x), \(p.y)), want \(String(format: "#%06X", want)) ±\(tolerance)")
    }

    private static func waitForAppearance(_ dark: Bool, of window: NSWindow?) async -> Bool {
        await Probe.wait(upTo: 3) { window?.effectiveAppearance.isDark == dark }
    }

    // MARK: - 0. Tokens

    /// Every pair resolves to its own value, and the derived ones follow.
    private static func tokenChecks() {
        let pairs: [(String, NSColor, Int, Int)] = [
            ("metalEdge", Theme.metalEdge, 0xA4A4A4, 0x36373A),
            ("listBG", Theme.listBG, 0xFFFFFF, 0x1E1F22),
            ("lcdBG", Theme.lcdBG, 0xD7DBC0, 0x181B12),
            ("lcdInk is the day panel's sage at night", Theme.lcdInk, 0x1A1A1A, 0xD7DBC0),
            ("textPrimary", Theme.textPrimary, 0x1A1A1A, 0xDEDFE1),
            ("tlRed is the same in both", Theme.tlRed, 0xD4594A, 0xD4594A),
            ("AquaStyle.stripeLight", AquaStyle.stripeLight, 0xEEEEEE, 0x2B2C2F),
        ]
        for (name, color, light, dark) in pairs {
            let l = rgb(color, dark: false), d = rgb(color, dark: true)
            check("token \(name)", l == light && d == dark,
                  String(format: "light #%06X (want #%06X), dark #%06X (want #%06X)", l, light, d, dark))
        }
        // Derived by blending: light is the old formula, dark its own value.
        let end = (rgb(ChromePalette.lcdEndButton, dark: false), rgb(ChromePalette.lcdEndButton, dark: true))
        check("derived lcdEndButton", end.0 != end.1 && end.1 == 0x8E9478,
              String(format: "light #%06X, dark #%06X", end.0, end.1))
        var gradientEnds: (Int, Int) = (0, 0)
        for dark in [false, true] {
            NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
                var color = NSColor.clear, location: CGFloat = 0
                Theme.columnHeader.getColor(&color, location: &location, at: 0)
                let value = rgb(color, dark: dark)
                if dark { gradientEnds.1 = value } else { gradientEnds.0 = value }
            }
        }
        check("columnHeader gradient picks its appearance", gradientEnds == (0xFFFFFF, 0x4C4E52),
              String(format: "light starts #%06X, dark #%06X", gradientEnds.0, gradientEnds.1))
    }

    // MARK: - 1. Pictures

    private static func pictures(_ main: MainWindow, out: URL) async {
        for mode in [AppearanceMode.light, .dark] {
            let dark = mode == .dark
            AppearancePreference.choose(mode, save: false)
            let window = main.controller.window
            check("\(mode.rawValue): main window follows", await waitForAppearance(dark, of: window),
                  window?.effectiveAppearance.name.rawValue ?? "no window")
            main.tracks.isBrowserVisible = false
            main.controller.controlBar.isBrowseOn = false
            await main.tracks.waitForLoad()
            main.tracks.reveal(main.playingID)
            window?.makeFirstResponder(main.tracks.tableView)
            await Probe.pause(0.6)
            if let px = snapshot(window, "main_\(mode.rawValue).png", out: out) {
                mainPixelChecks(px, main, mode: mode)
            }

            main.tracks.isBrowserVisible = true
            main.controller.controlBar.isBrowseOn = true
            await main.tracks.waitForLoad()
            await Probe.pause(0.6)
            _ = snapshot(window, "main_browser_\(mode.rawValue).png", out: out)
            main.tracks.isBrowserVisible = false
            main.controller.controlBar.isBrowseOn = false

            // Typing in the search capsule: the field editor's text and caret, and the focus glow.
            main.controller.controlBar.focusSearch()
            (window?.firstResponder as? NSTextView)?.insertText("night", replacementRange: NSRange(location: 0, length: 0))
            await Probe.pause(0.3)
            await main.tracks.waitForLoad()
            await Probe.pause(0.5)
            _ = snapshot(window, "main_search_\(mode.rawValue).png", out: out)
            main.controller.controlBar.searchText = ""
            main.tracks.query.search = ""
            window?.makeFirstResponder(main.tracks.tableView)
            await main.tracks.waitForLoad()

            // An alert sheet over the main window, as RetroAlert shows one.
            if let window {
                let sheet = AquaSheet(message: "OldTunes couldn't add “Field Recordings”.",
                                      informative: "The folder is on a disk that is not connected. Connect the disk, then add the folder again.",
                                      buttons: ["Cancel", "Try Again"], cancelIndex: 0)
                let task = Task { await sheet.run(on: window) }
                _ = await Probe.wait(upTo: 3) { window.attachedSheet != nil }
                await Probe.pause(0.8)
                if let px = snapshot(sheet.window, "alert_\(mode.rawValue).png", out: out) {
                    pixelCheck("\(mode.rawValue): alert pinstripe (light row)", px, NSPoint(x: 8, y: 0.5),
                               AquaStyle.stripeLight, dark: dark, tolerance: 2)
                }
                sheet.press(0)
                _ = await task.value
                await Probe.pause(0.4)
            }

            // Get Info on an invented cloud-only song (the invented files do not exist), over a
            // harness library that records instead of writing.
            if let song = main.songs.first(where: { $0.title == "Letters by Morning" }) {
                let library = MetadataHarnessLibrary(main.songs)
                let info = GetInfoWindowController(tracks: [song], visibleOrder: main.songs.map(\.id),
                                                   editor: TagEditor(cloud: RecordingCloudWriter(answers: [.denied])),
                                                   library: library, artwork: { _ in nil })
                info.permissionChecker = RecordingCloudWriter(answers: [.denied])
                info.showWindow(nil)
                await Probe.pause(1.0)
                if let px = snapshot(info.window, "getinfo_\(mode.rawValue).png", out: out) {
                    pixelCheck("\(mode.rawValue): Get Info pinstripe (dark row)", px, NSPoint(x: 6, y: 26.5),
                               AquaStyle.stripeDark, dark: dark, tolerance: 2)
                }
                // The Info tab: editable fields, the Name field focused with its text selected.
                info.selectTab(1)
                await Probe.pause(0.6)
                _ = snapshot(info.window, "getinfo_fields_\(mode.rawValue).png", out: out)
                info.selectTab(0)
                info.window?.orderOut(nil)
                info.close()
            }

            SettingsWindowController.show()
            await Probe.pause(0.8)
            if let px = snapshot(SettingsWindowController.current?.window, "settings_\(mode.rawValue).png", out: out) {
                pixelCheck("\(mode.rawValue): Settings pinstripe (light row)", px, NSPoint(x: 6, y: 28.5),
                           AquaStyle.stripeLight, dark: dark, tolerance: 2)
            }
            SettingsWindowController.current?.cancelButton.performClick(nil)
            main.controller.window?.makeKeyAndOrderFront(nil)
            main.controller.window?.makeFirstResponder(main.tracks.tableView)
            await Probe.pause(0.3)
        }
    }

    /// The gutter, the window centre, the LCD glass, its text and the source list's empty rows.
    private static func mainPixelChecks(_ px: ChromeHarnessProbe.Pixels, _ main: MainWindow, mode: AppearanceMode) {
        let dark = mode == .dark
        let name = mode.rawValue
        // x 8 is 1% of the way from edge to centre; the grain moves a row up to 7 levels.
        pixelCheck("\(name): metal at the left gutter", px, NSPoint(x: 8, y: 300), Theme.metalEdge, dark: dark, tolerance: 9)
        let width = main.controller.window?.frame.width ?? 0
        pixelCheck("\(name): metal at the centre", px, NSPoint(x: (width / 2).rounded(), y: 4.5),
                   Theme.metalCenter, dark: dark, tolerance: 9)

        let lcd = main.controller.controlBar.lcd
        let origin = lcd.convert(NSPoint.zero, to: nil)
        let top = (main.controller.window?.frame.height ?? 0) - origin.y - 0   // flipped view: (0,0) is its top-left
        let lcdLeft = origin.x
        pixelCheck("\(name): LCD glass", px, NSPoint(x: lcdLeft + 21, y: top + 31), Theme.lcdBG, dark: dark, tolerance: 4)
        // Line 1's brightest and darkest ink: lit at night, dark by day.
        var brightest = 0, darkest = 255
        var x = lcdLeft + lcd.bounds.width / 2 - 60
        while x < lcdLeft + lcd.bounds.width / 2 + 60 {
            for y in stride(from: top + 5, to: top + 15, by: 0.5) {
                let c = px.rgb(x, y)
                let luma = (c.r * 3 + c.g * 6 + c.b) / 10
                brightest = max(brightest, luma)
                darkest = min(darkest, luma)
            }
            x += 0.5
        }
        if dark {
            check("dark: LCD text is lit", brightest > 170, "brightest ink luma \(brightest), glass luma ~25")
        } else {
            check("light: LCD text is dark ink", darkest < 70, "darkest ink luma \(darkest), panel luma ~216")
        }
        let height = main.controller.window?.frame.height ?? 0
        pixelCheck("\(name): source list below its last row", px, NSPoint(x: 90, y: height - 50),
                   Theme.listBG, dark: dark, tolerance: 2)
    }

    // MARK: - 2. Live switch

    /// The window already on screen must redraw by itself: nothing but the switch asks it to.
    private static func liveSwitchChecks(_ main: MainWindow) async {
        AppearancePreference.choose(.light, save: false)
        _ = await waitForAppearance(false, of: main.controller.window)
        await Probe.pause(0.8)
        let lcd = main.controller.controlBar.lcd
        let draws = lcd.drawCount, builds = main.controller.metalView.metalBuildCount
        AppearancePreference.choose(.dark, save: false)
        let followed = await waitForAppearance(true, of: main.controller.window)
        let redrew = await Probe.wait(upTo: 2) {
            lcd.drawCount > draws && main.controller.metalView.metalBuildCount > builds
        }
        check("live switch to dark redraws the open window", followed && redrew,
              "LCD draws \(draws) → \(lcd.drawCount), metal builds \(builds) → \(main.controller.metalView.metalBuildCount)")
        let back = main.controller.metalView.metalBuildCount
        AppearancePreference.choose(.light, save: false)
        let returned = await Probe.wait(upTo: 2) { main.controller.metalView.metalBuildCount > back }
        check("and back to light", returned && main.controller.window?.effectiveAppearance.isDark == false,
              "metal builds \(back) → \(main.controller.metalView.metalBuildCount)")
    }

    // MARK: - 3. Match System

    private static func matchSystemChecks() async {
        AppearancePreference.choose(.system, save: false)
        await Probe.pause(0.3)
        let systemIsDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        check("Match System clears the app's own appearance", NSApp.appearance == nil,
              "NSApp.appearance \(NSApp.appearance?.name.rawValue ?? "nil")")
        check("Match System follows System Settings", NSApp.effectiveAppearance.isDark == systemIsDark,
              "system \(systemIsDark ? "Dark" : "Light"), app \(NSApp.effectiveAppearance.name.rawValue)")
    }

    // MARK: - 4. Settings

    private static func settingsChecks(out: URL) async {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: AppearancePreference.defaultsKey)
        check("unset preference means Match System", AppearancePreference.saved == .system,
              "saved \(AppearancePreference.saved.rawValue)")

        let menuItem = NSApp.mainMenu?.items.first?.submenu?.items.first { $0.action == #selector(AppDelegate.showSettings(_:)) }
        check("app menu has Settings… ⌘,", menuItem?.title == "Settings…" && menuItem?.keyEquivalent == ","
              && menuItem?.keyEquivalentModifierMask == .command,
              "item \(menuItem?.title ?? "missing"), key \(menuItem?.keyEquivalent ?? "")")
        AppearancePreference.choose(.light, save: true)
        let sent = NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: menuItem)
        await Probe.pause(0.5)
        guard let prefs = SettingsWindowController.current, let window = prefs.window as? AquaWindow else {
            check("menu action opens Settings", false, "sent \(sent), no window")
            return
        }
        check("menu action opens Settings", sent && window.isVisible, "visible \(window.isVisible)")
        let shown = AppearanceMode.allCases.filter { prefs.radio(for: $0)?.isOn == true }
        check("radios show the saved choice", shown == [.light], "on: \(shown.map(\.rawValue))")

        // A pick previews: the look changes, nothing is saved.
        prefs.radio(for: .dark)?.pick()
        let previewed = await waitForAppearance(true, of: window)
        check("picking Dark shows it at once", previewed && AppearancePreference.current == .dark,
              "current \(AppearancePreference.current.rawValue)")
        check("a pick saves nothing", defaults.string(forKey: AppearancePreference.defaultsKey) == "light",
              "saved \(defaults.string(forKey: AppearancePreference.defaultsKey) ?? "nil")")
        let onAfterPick = AppearanceMode.allCases.filter { prefs.radio(for: $0)?.isOn == true }
        check("one radio on at a time", onAfterPick == [.dark], "on: \(onAfterPick.map(\.rawValue))")
        await Probe.pause(0.5)
        _ = snapshot(window, "settings_dark_preview.png", out: out)

        prefs.cancelButton.performClick(nil)
        let reverted = await waitForAppearance(false, of: NSApp.windows.first { $0 is MetalWindow })
        check("Cancel puts the old look back", reverted && AppearancePreference.current == .light && !window.isVisible,
              "current \(AppearancePreference.current.rawValue), window visible \(window.isVisible)")

        // OK saves.
        SettingsWindowController.show()
        prefs.radio(for: .system)?.pick()
        prefs.okButton.performClick(nil)
        await Probe.pause(0.3)
        check("OK saves Match System", AppearancePreference.saved == .system && NSApp.appearance == nil && !window.isVisible,
              "saved \(AppearancePreference.saved.rawValue), NSApp.appearance \(NSApp.appearance?.name.rawValue ?? "nil")")

        // The close button and Escape are Cancel; Return is OK.
        SettingsWindowController.show()
        prefs.radio(for: .dark)?.pick()
        window.performClose(nil)
        await Probe.pause(0.3)
        check("the close button cancels", AppearancePreference.current == .system && AppearancePreference.saved == .system
              && !window.isVisible, "current \(AppearancePreference.current.rawValue)")
        SettingsWindowController.show()
        prefs.radio(for: .light)?.pick()
        window.cancelOperation(nil)
        await Probe.pause(0.3)
        check("Escape cancels", AppearancePreference.current == .system && !window.isVisible,
              "current \(AppearancePreference.current.rawValue)")
        SettingsWindowController.show()
        prefs.radio(for: .dark)?.pick()
        window.onReturn?()
        await Probe.pause(0.3)
        check("Return is OK", AppearancePreference.saved == .dark && AppearancePreference.current == .dark,
              "saved \(AppearancePreference.saved.rawValue)")
        check("the saved choice is what a launch would read",
              defaults.string(forKey: AppearancePreference.defaultsKey) == "dark",
              "defaults \(defaults.string(forKey: AppearancePreference.defaultsKey) ?? "nil")")
    }

    // MARK: - The window under test

    @MainActor
    private final class MainWindow {
        let controller = MetalWindowController()
        let sources: SourceListViewController
        let tracks: TrackListViewController
        let songs: [Track]
        /// The song the LCD shows as playing.
        private(set) var playingID: Track.ID = 0

        private init(library: ListsHarnessLibrary, songs: [Track]) {
            sources = SourceListViewController(library: library)
            tracks = TrackListViewController(library: library)
            self.songs = songs
        }

        static func build() async -> MainWindow {
            let snap = InventedLibrary.snapshot()
            let library = ListsHarnessLibrary(index: await ListsHarnessLibrary.buildIndex(snap))
            let main = MainWindow(library: library, songs: snap.tracks)
            // Start from the default layout, whatever an earlier run left behind.
            for key in [TrackColumnLayout.defaultsKey, "OldTunes.TrackList.browserVisible",
                        "OldTunes.TrackList.browserFraction", MetalContentView.sourceWidthDefaultsKey] {
                UserDefaults.standard.removeObject(forKey: key)
            }
            main.embed()
            await main.sources.reload()
            await main.tracks.reload()
            await main.tracks.waitForLoad()

            let playing = snap.tracks.first { $0.title == "Paper Moon Motel" } ?? snap.tracks[0]
            main.playingID = playing.id
            var state = PlaybackState()
            state.nowPlaying = playing
            state.isPlaying = true
            state.position = 83
            state.duration = playing.duration
            state.volume = 0.6
            main.controller.controlBar.update(state)
            main.tracks.setNowPlaying(playing.id, isPlaying: true)
            let seconds = snap.tracks.reduce(0) { $0 + $1.duration }
            let bytes = snap.tracks.reduce(Int64(0)) { $0 + $1.fileSize }
            main.controller.bottomBar.setSummary(SummaryFormatter.string(
                for: LibrarySummary(count: snap.tracks.count, totalSeconds: seconds, totalBytes: bytes)))

            guard let window = main.controller.window else { return main }
            window.setContentSize(NSSize(width: 1000, height: 640))
            window.center()
            main.controller.showWindow(nil)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            _ = await Probe.wait(upTo: 4) { window.isKeyWindow }
            // The playing song, selected and scrolled into view: the speaker, the blue row.
            main.tracks.reveal(playing.id)
            window.makeFirstResponder(main.tracks.tableView)
            await Probe.pause(0.8)
            return main
        }

        private func embed() {
            for (child, pane) in [(sources.view, controller.sourcePane), (tracks.view, controller.trackPane)] {
                child.frame = pane.bounds
                child.autoresizingMask = [.width, .height]
                pane.addSubview(child)
            }
            sources.onScopeChange = { [weak self] scope in self?.tracks.query.scope = scope }
            controller.controlBar.onSearchTextChange = { [weak self] text in self?.tracks.query.search = text }
        }
    }
}

/// HARNESS ONLY. A small made-up library in 2005's shape: ten albums, a few cloud-only songs, one
/// missing file, one unchecked song, iTunes 4.9's stock smart playlists and a folder of mixes.
/// Every name is invented.
@MainActor
enum InventedLibrary {
    private static let albums: [(artist: String, album: String, genre: String, year: Int, songs: [String])] = [
        ("The Paper Lanterns", "Harbor Lights", "Alternative", 2004,
         ["Paper Moon Motel", "Tidewater", "Lamplighter", "Salt in the Radio", "The Long Way Round", "Anchor Song"]),
        ("Mira Okafor", "Telegraph Hill", "Singer/Songwriter", 2003,
         ["Letters by Morning", "Copper Kettle", "Telegraph Hill", "Fog Signals", "Small Hours"]),
        ("Juniper Static", "Low Tide Radio", "Electronic", 2005,
         ["Carrier Wave", "Low Tide Radio", "Night Ferry", "Signal Fires", "Afterglow (Reprise)"]),
        ("Calloway & the Brights", "Sunday Atlas", "Rock", 2002,
         ["Highway Ghosts", "Sunday Atlas", "Engine Red", "Gravel Road Waltz", "Last Call at Lou's"]),
        ("Inès Valcourt", "Rue des Lilas", "Jazz", 2004,
         ["Rue des Lilas", "Café au Lait", "Blue Shutters", "Minuit Moins Cinq"]),
        ("Northbound Telephone", "Static Postcards", "Indie", 2005,
         ["Static Postcards", "Area Code", "Switchboard Heart", "Long Distance", "Dial Tone Lullaby"]),
        ("Velvet Orchard", "Fieldnotes", "Folk", 2005,
         ["Fieldnotes", "Apple Cart", "Barn Owl", "Under the Elms"]),
        ("DJ Lumen", "Night Bus EP", "Electronic", 2005,
         ["Night Bus", "Neon Puddles", "Last Train Home"]),
        ("The Marigold Hours", "Postcards from Nowhere", "Pop", 2004,
         ["Postcards from Nowhere", "Sugar Rush Summer", "Polaroid", "Kaleidoscope Eyes", "Goodnight, Marigold"]),
        ("Kona Coast Serenaders", "Slack Key Afternoons", "World", 2001,
         ["Trade Winds", "Lanai Morning", "Moonrise over Mauna Kea", "Island Time"]),
    ]

    static func snapshot() -> ListsHarnessLibrary.Snapshot {
        var tracks: [Track] = []
        var id: Int64 = 1
        for (albumIndex, a) in albums.enumerated() {
            for (n, title) in a.songs.enumerated() {
                var t = Track.blank(id: id)
                t.title = title
                t.artist = a.artist
                t.album = a.album
                t.genre = a.genre
                t.year = a.year
                t.trackNumber = n + 1
                t.trackCount = a.songs.count
                t.duration = TimeInterval(148 + Int(id * 37 % 190))
                // Added through mid-2005, newest last.
                t.dateAdded = Date(timeIntervalSince1970: 1_104_537_600 + Double(id) * 86_400 * 2.3)
                t.playCount = Int(id * 7 % 23)
                t.kind = albumIndex % 3 == 1 ? "Purchased AAC audio file" : "AAC audio file"
                t.bitRate = 128
                t.sampleRate = 44_100
                t.fileSize = Int64(t.duration * 16_000)
                t.albumPID = Int64(albumIndex + 1)
                if albumIndex % 3 == 1 {
                    t.bucket = .cloud
                    t.isCloud = true
                    t.cloudID = "i.harness\(id)"
                } else {
                    t.bucket = .local
                    t.fileURL = URL(fileURLWithPath: "/Volumes/Music/\(a.artist)/\(a.album)/\(title).m4a")
                }
                tracks.append(t)
                id += 1
            }
        }
        if let i = tracks.firstIndex(where: { $0.title == "Gravel Road Waltz" }) {
            tracks[i].bucket = .missing
        }
        if let i = tracks.firstIndex(where: { $0.title == "Salt in the Radio" }) {
            tracks[i].isChecked = false
        }

        let all = tracks.map(\.id)
        func ids(_ titles: [String]) -> [Int64] { titles.compactMap { t in tracks.first { $0.title == t }?.id } }
        let lists: [(PlaylistInfo, [Int64])] = [
            (PlaylistInfo(id: 9_001, name: "90's Music", kind: .smart, parentID: nil, trackCount: 0), []),
            (PlaylistInfo(id: 9_002, name: "My Top Rated", kind: .smart, parentID: nil, trackCount: 0),
             Array(all.filter { $0 % 4 == 0 })),
            (PlaylistInfo(id: 9_003, name: "Recently Played", kind: .smart, parentID: nil, trackCount: 0),
             Array(all.suffix(12))),
            (PlaylistInfo(id: 9_004, name: "Top 25 Most Played", kind: .smart, parentID: nil, trackCount: 0),
             Array(all.prefix(25))),
            (PlaylistInfo(id: 9_010, name: "Road Trip", kind: .regular, parentID: nil, trackCount: 0),
             ids(["Highway Ghosts", "Engine Red", "Long Distance", "Night Bus", "Sugar Rush Summer", "Area Code"])),
            (PlaylistInfo(id: 9_011, name: "Rainy Sunday", kind: .regular, parentID: nil, trackCount: 0),
             ids(["Fog Signals", "Blue Shutters", "Under the Elms", "Small Hours", "Café au Lait"])),
            (PlaylistInfo(id: 9_020, name: "Mixes", kind: .folder, parentID: nil, trackCount: 0), []),
            (PlaylistInfo(id: 9_021, name: "Late Night", kind: .regular, parentID: 9_020, trackCount: 0),
             ids(["Night Ferry", "Neon Puddles", "Minuit Moins Cinq", "Dial Tone Lullaby"])),
            (PlaylistInfo(id: 9_022, name: "Summer 2005", kind: .regular, parentID: 9_020, trackCount: 0),
             ids(["Sugar Rush Summer", "Trade Winds", "Polaroid", "Island Time", "Signal Fires"])),
        ]
        var playlists: [PlaylistInfo] = []
        var members: [Int64: [Int64]] = [:]
        for (list, songIDs) in lists {
            var list = list
            list.trackCount = songIDs.count
            playlists.append(list)
            members[list.id] = songIDs
        }
        return ListsHarnessLibrary.Snapshot(tracks: tracks, playlists: playlists, members: members,
                                            itemCount: tracks.count, loadMillis: 0)
    }
}
