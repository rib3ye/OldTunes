import AppKit
import GRDB

/// The one place that names concrete implementations. Everything else codes against Contracts.swift.
@MainActor
enum AppAssembly {
    private static var controller: AppController?

    static func launch(smokeTest: Bool = false) async {
        let opened: (index: LibraryIndex, rebuilt: Bool)
        do {
            opened = try openIndex()
        } catch {
            // Even a freshly created index failed: the disk or the folder is the problem, not the file.
            Log.error("launch failed: \(error)")
            // A test bench quits at once, rather than waiting for a click on an alert no one sees
            // (for example an OLDTUNES_DB_PATH the sandbox won't open).
            if LaunchEnvironment.bench != nil {
                Log.flush()
                NSApp.terminate(nil)
                return
            }
            RetroAlert.runModal("oldTunes could not create its library database.",
                                informative: "\(error.localizedDescription)\n\nCheck that \(indexURL.deletingLastPathComponent().path) is writable.",
                                buttons: ["Quit"])
            NSApp.terminate(nil)
            return
        }
        let controller = AppController(index: opened.index, rebuiltIndex: opened.rebuilt)
        self.controller = controller
        #if BENCHES
        if smokeTest {
            controller.onFirstIngest = { report in Task { await SmokeTest(app: controller).run(report) } }
        }
        #endif
        controller.start()
    }

    /// Dock click or Window ▸ oldTunes after the main window was closed.
    static func showMainWindow() { controller?.showMainWindow(nil) }

    /// Right-click on the Dock icon. Nil while the app is starting and in test benches, so the
    /// Dock shows only its own items.
    static func dockMenu() -> NSMenu? { controller?.dockMenu() }

    // MARK: - Index recovery

    /// The index is a cache of the Music library that rebuilds in about 6 s, so a file that will not
    /// open is moved aside and recreated rather than stopping the app for good. Subtler damage is
    /// found by `checkIntegrityInBackground`, which flags the file for the same treatment next launch;
    /// SQLite's quick_check takes ~300 ms here, too slow to run before the window appears.
    /// Added folders are remembered outside the database (AppController) and re-added.
    private static func openIndex() throws -> (LibraryIndex, Bool) {
        let url = indexURL
        if UserDefaults.standard.bool(forKey: rebuildKey) {
            UserDefaults.standard.removeObject(forKey: rebuildKey)
            Log.info("index: rebuilding as flagged by last launch's integrity check")
            moveAside(url)
            return (try LibraryIndex(), true)
        }
        // No index yet counts as a rebuild too, so the added folders come back: a sandboxed
        // oldTunes's first launch finds its index here only if macOS moved the old one into the
        // container (container-migration.plist). Not for a bench's own index (OLDTUNES_DB_PATH),
        // which must stay free of the user's folders.
        let fresh = LaunchEnvironment.value("OLDTUNES_DB_PATH") == nil
            && !FileManager.default.fileExists(atPath: url.path)
        do {
            return (try LibraryIndex(), fresh)
        } catch {
            Log.error("index: could not open \(url.path) (\(error)); rebuilding")
            moveAside(url)
            return (try LibraryIndex(), true)
        }
    }

    nonisolated private static let rebuildKey = "oldTunes.rebuildIndexOnLaunch"

    /// Off the main thread, after the window is up. Returns false if the next launch must rebuild.
    nonisolated static func checkIntegrityInBackground(_ index: LibraryIndex) async -> Bool {
        let start = Date()
        let check = try? await index.pool.read { try String.fetchOne($0, sql: "PRAGMA quick_check(1)") }
        Log.info("index: quick_check=\(check ?? "failed to run") in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        guard check == "ok" else {
            UserDefaults.standard.set(true, forKey: rebuildKey)
            return false
        }
        return true
    }

    /// Same resolution as LibraryIndex.init: OLDTUNES_DB_PATH, else the default.
    private static var indexURL: URL {
        LaunchEnvironment.value("OLDTUNES_DB_PATH").map { URL(fileURLWithPath: $0) } ?? LibraryIndex.defaultURL
    }

    /// Keeps only the newest damaged copy, for diagnosis.
    private static func moveAside(_ url: URL) {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        for old in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where old.hasPrefix("\(base).corrupt-") {
            try? fm.removeItem(at: dir.appendingPathComponent(old))
        }
        let stamp = Date().formatted(.verbatim("\(year: .defaultDigits)\(month: .twoDigits)\(day: .twoDigits)-\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)",
                                               timeZone: .current, calendar: .current))
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: url.path + suffix)
            guard fm.fileExists(atPath: from.path) else { continue }
            let to = dir.appendingPathComponent("\(base).corrupt-\(stamp).\(url.pathExtension)\(suffix)")
            do { try fm.moveItem(at: from, to: to); Log.info("index: moved \(from.lastPathComponent) aside") }
            catch { try? fm.removeItem(at: from) }
        }
    }
}
