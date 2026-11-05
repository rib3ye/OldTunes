import AppKit

/// The 10.4 alert, for code outside Get Info, in place of `NSAlert` (whose buttons draw as
/// Liquid Glass on macOS 27). Built on `AquaSheet`: disc icon, bold message, small informative
/// text, gel buttons.
///
/// Buttons read left to right, as on screen. The LAST one is the default (blue, Return), and
/// `cancelIndex`, if given, answers Escape. Both calls return the index of the button pressed —
/// so NSAlert's "first button added" is the last entry here:
///
///     // was: alert.addButton("Open System Settings"); alert.addButton("Not Now")
///     let pressed = await RetroAlert.show("oldTunes can't see your music library.",
///                                         informative: message,
///                                         buttons: ["Not Now", "Open System Settings"], cancelIndex: 0,
///                                         on: windowController.window)
///     if pressed == 1 { … open System Settings … }
@MainActor
enum RetroAlert {
    /// Shows the alert and waits for a button. With a visible `window` it slides down from it as
    /// a sheet (like `NSAlert.beginSheetModal(for:)`); otherwise it is app-modal and centred on
    /// the screen (like `NSAlert.runModal()`).
    @discardableResult
    static func show(_ message: String, informative: String = "", details: String? = nil,
                     buttons: [String] = ["OK"], cancelIndex: Int? = nil, on window: NSWindow? = nil) async -> Int {
        let alert = AquaSheet(message: message, informative: informative, details: details,
                              buttons: buttons, cancelIndex: cancelIndex)
        if let window, window.isVisible {
            return await alert.run(on: window).buttonIndex
        }
        return alert.runModal().buttonIndex
    }

    /// Blocking and app-modal, a drop-in for `NSAlert.runModal()` where the caller cannot await
    /// (for example the launch-failure path just before `NSApp.terminate`).
    @discardableResult
    static func runModal(_ message: String, informative: String = "", details: String? = nil,
                         buttons: [String] = ["OK"], cancelIndex: Int? = nil) -> Int {
        AquaSheet(message: message, informative: informative, details: details,
                  buttons: buttons, cancelIndex: cancelIndex).runModal().buttonIndex
    }
}
