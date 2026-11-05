import AppKit

/// `RetroAlert`, the 10.4 alert AppController uses in place of NSAlert: as a sheet on a visible
/// window, and app-modal with no window, answered by a click, by Return and by Escape.
@MainActor
enum HarnessAlert {
    static func run(evidence: URL, tally: HarnessTally) async {
        // As a sheet on a visible window.
        let host = AquaWindow(contentSize: NSSize(width: 520, height: 260), title: "Alert host")
        host.center()
        host.makeKeyAndOrderFront(nil)
        await settle(0.3)
        let result = Box<Int>()
        Task { @MainActor in
            result.value = await RetroAlert.show("oldTunes can’t see your music library.",
                                                 informative: "Turn on oldTunes in System Settings ▸ Privacy & Security ▸ Media & Apple Music, then quit and reopen oldTunes.",
                                                 buttons: ["Not Now", "Open System Settings"], cancelIndex: 0, on: host)
        }
        let up = await waitFor(3) { AquaSheet.presented != nil }
        let sheet = AquaSheet.presented
        tally.check(up && host.attachedSheet != nil && host.attachedSheet === sheet?.window,
                    "alert: with a visible window, RetroAlert slides down from it as a sheet")
        await settle(0.4)
        snap(host, "alert-sheet-host", evidence)
        snap(sheet?.window, "alert-sheet", evidence)
        sheet?.press(0)
        _ = await waitFor(3) { result.value != nil }
        tally.check(result.value == 0, "alert: the sheet returns the pressed button's index (Not Now = 0)",
                    detail: "\(String(describing: result.value))")
        host.orderOut(nil)

        // App-modal, no window: a click on the default button.
        let seen = Box<Bool>()
        schedule(after: 0.4) {
            guard let alert = AquaSheet.presented else { return }
            seen.value = NSApp.modalWindow === alert.window
            // Key only when oldTunes is the active app, which another app can hold for a moment.
            Log.info("alert: app-modal alert key=\(alert.window.isKeyWindow) app active=\(NSApp.isActive)")
            HarnessAlert.snap(alert.window, "alert-modal", evidence)
            alert.press(alert.buttonTitles.count - 1)
        }
        let clicked = RetroAlert.runModal("oldTunes could not open its library database.",
                                          informative: "The database file is damaged.", buttons: ["Quit"])
        tally.check(seen.value == true && clicked == 0 && AquaSheet.presented == nil,
                    "alert: with no window, RetroAlert is app-modal and returns when a button is pressed",
                    detail: "modal=\(String(describing: seen.value)) returned \(clicked)")

        // App-modal: Return picks the last button, Escape the cancel button.
        for (code, chars, expected, name) in [(UInt16(36), "\r", 1, "Return"), (UInt16(53), "\u{1b}", 0, "Escape")] {
            schedule(after: 0.3) {
                guard let alert = AquaSheet.presented,
                      let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: alert.window.windowNumber, context: nil,
                                                 characters: chars, charactersIgnoringModifiers: chars,
                                                 isARepeat: false, keyCode: code) else { return }
                NSApp.sendEvent(key)
            }
            let pressed = RetroAlert.runModal("Keyboard check", informative: "\(name) answers this alert.",
                                              buttons: ["Cancel", "OK"], cancelIndex: 0)
            tally.check(pressed == expected, "alert: \(name) answers an app-modal alert with button \(expected)",
                        detail: "returned \(pressed)")
        }

        // show() with a window that is not on screen falls back to app-modal.
        let hidden = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: .titled,
                              backing: .buffered, defer: false)
        hidden.isReleasedWhenClosed = false
        let fellBack = Box<Bool>()
        schedule(after: 0.3) {
            guard let alert = AquaSheet.presented else { return }
            fellBack.value = NSApp.modalWindow === alert.window
            alert.press(0)
        }
        let hiddenResult = await RetroAlert.show("No window to hang on", on: hidden)
        tally.check(fellBack.value == true && hiddenResult == 0,
                    "alert: show() on a window that is not visible runs app-modal instead")
    }

    /// Runs `body` on the main thread from a timer that also fires inside a modal session.
    private static func schedule(after seconds: Double, _ body: @escaping @MainActor () -> Void) {
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated { body() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private static func settle(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    private static func waitFor(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private static func snap(_ window: NSWindow?, _ name: String, _ dir: URL) {
        guard let window else { return }
        window.displayIfNeeded()
        let url = dir.appendingPathComponent("\(name).png")
        if Snapshot.write(window, to: url) { Log.info("snapshot: \(url.path)") }
    }
}

@MainActor
private final class Box<T> {
    var value: T?
}
