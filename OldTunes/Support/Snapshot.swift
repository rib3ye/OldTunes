import AppKit

/// Renders a window's content to a PNG without Screen Recording permission, by asking the view
/// hierarchy to draw itself. Everything OldTunes shows is custom-drawn, so this captures it all.
///
/// Driven by environment variables (pass them with `open --env`):
///   OLDTUNES_SNAPSHOT=/abs/path.png      write a PNG of the frontmost window
///   OLDTUNES_SNAPSHOT_DELAY=3            seconds to wait first (default 2)
///   OLDTUNES_QUIT_AFTER_SNAPSHOT=1       terminate after writing
@MainActor
enum Snapshot {
    static func scheduleFromEnvironment() {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["OLDTUNES_SNAPSHOT"], !path.isEmpty else { return }
        let delay = Double(env["OLDTUNES_SNAPSHOT_DELAY"] ?? "") ?? 2
        let quit = env["OLDTUNES_QUIT_AFTER_SNAPSHOT"] == "1"
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.orderedWindows.first { $0.isVisible }
            if let window {
                if write(window, to: URL(fileURLWithPath: path)) {
                    Log.info("snapshot written: \(path) (\(Int(window.frame.width))x\(Int(window.frame.height)) pt)")
                }
            } else {
                Log.error("snapshot failed: no visible window")
            }
            if quit { Log.flush(); NSApp.terminate(nil) }
        }
    }

    @discardableResult
    static func write(_ window: NSWindow, to url: URL) -> Bool {
        // With .fullSizeContentView the content view covers the title bar, so this is the whole window.
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        // The rep is in the display's profile. Convert so pixel checks can compare against sRGB hex values.
        let srgb = rep.converting(to: .sRGB, renderingIntent: .default) ?? rep
        guard let png = srgb.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: url)
            return true
        } catch {
            // A path the sandbox won't open lands here (Debug builds may write /private/tmp only).
            Log.error("snapshot failed: could not write \(url.path): \(error.localizedDescription)")
            return false
        }
    }
}
