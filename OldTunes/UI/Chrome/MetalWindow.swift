import AppKit

/// The main window (RESEARCH.md §7.4): full-size content under a transparent, title-less title
/// bar, so the content view can paint the whole 2005 frame itself.
///
/// The real traffic lights are hidden rather than moved; moved ones snap back on every resize.
/// The style mask keeps .closable/.miniaturizable/.resizable so ⌘W, ⌘M and edge resizing work.
///
/// Everything the chrome needs from the window (key/main changes, full screen, the search
/// field's editor) is handled here by overrides and self-observation, not by the window's
/// delegate, so integration is free to set a delegate without silently breaking the chrome.
@MainActor
final class MetalWindow: NSWindow {
    /// ⌘F when no menu item claims it, so search focus works before integration adds a Find item.
    var onFind: (() -> Void)?
    /// The window gained or lost key or main status: orbs, title and focus glow redraw.
    var onActivityChange: (() -> Void)?
    /// Full screen began (true) or ended (false).
    var onFullScreenChange: ((Bool) -> Void)?
    /// A private field editor for one client (the search field), or nil for the shared one.
    var fieldEditorProvider: ((Any?) -> NSText?)?
    /// A key nothing in the window used, such as an arrow the song list passes on. Return true when
    /// handled; otherwise the window beeps as usual.
    var onUnusedKey: ((NSEvent) -> Bool)?
    /// Whether the first showing has happened (see makeKeyAndOrderFront).
    private var settledInitialFocus = false

    init(contentSize: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: contentSize),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        titlebarSeparatorStyle = .none
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        minSize = Theme.Metrics.minimumWindow
        contentMinSize = Theme.Metrics.minimumWindow
        collectionBehavior.insert(.fullScreenPrimary)
        hideStandardButtons()

        // Full screen re-tiles the title bar (§10 R12): re-hide the real buttons at every step.
        let center = NotificationCenter.default
        for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
            center.addObserver(self, selector: #selector(fullScreenWillChange(_:)), name: name, object: self)
        }
        center.addObserver(self, selector: #selector(enteredFullScreen(_:)),
                           name: NSWindow.didEnterFullScreenNotification, object: self)
        center.addObserver(self, selector: #selector(leftFullScreen(_:)),
                           name: NSWindow.didExitFullScreenNotification, object: self)
    }

    /// Called again after full-screen transitions in case AppKit rebuilt the title bar.
    func hideStandardButtons() {
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(kind)?.isHidden = true
        }
    }

    var standardButtonsHidden: Bool {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .allSatisfy { standardWindowButton($0)?.isHidden ?? true }
    }

    @objc private func fullScreenWillChange(_ notification: Notification) {
        hideStandardButtons()
    }

    @objc private func enteredFullScreen(_ notification: Notification) {
        hideStandardButtons()
        onFullScreenChange?(true)
    }

    @objc private func leftFullScreen(_ notification: Notification) {
        hideStandardButtons()
        onFullScreenChange?(false)
    }

    // MARK: - Key and main

    override func becomeKey() {
        super.becomeKey()
        onActivityChange?()
    }

    /// With no initialFirstResponder, AppKit focuses the first key view while it first orders the
    /// window in (and records the content view as the initial responder), and the first key view
    /// is the search field: it would glow at launch and swallow the first keystrokes. 2005 iTunes
    /// opened with nothing being typed into, so a window that integration has not given an
    /// initial responder starts with no field focused. Only the first showing is touched.
    override func makeKeyAndOrderFront(_ sender: Any?) {
        let appKitChooses = !settledInitialFocus && initialFirstResponder == nil
        settledInitialFocus = true
        super.makeKeyAndOrderFront(sender)
        if appKitChooses, let editor = firstResponder as? NSText, editor.isFieldEditor {
            makeFirstResponder(nil)
        }
    }

    override func resignKey() {
        super.resignKey()
        onActivityChange?()
    }

    override func becomeMain() {
        super.becomeMain()
        onActivityChange?()
    }

    override func resignMain() {
        super.resignMain()
        onActivityChange?()
    }

    // MARK: - Field editor

    override func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSText? {
        fieldEditorProvider?(object) ?? super.fieldEditor(createFlag, for: object)
    }

    // MARK: - Keys

    /// The end of the responder chain: a key gets here when no view used it, or none has focus.
    override func keyDown(with event: NSEvent) {
        if onUnusedKey?(event) == true { return }
        super.keyDown(with: event)
    }

    /// ⌘W and ⌘F fallbacks for when the menu bar has no item for them. A menu item, when present,
    /// always wins, because the menu is asked first here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased(), !menuBarClaims(key) else { return false }
        switch key {
        case "w":
            performClose(nil)
            return true
        case "f":
            guard let onFind else { return false }
            onFind()
            return true
        default:
            return false
        }
    }

    private func menuBarClaims(_ key: String) -> Bool {
        func claims(_ menu: NSMenu) -> Bool {
            menu.items.contains { item in
                (item.keyEquivalent == key && item.keyEquivalentModifierMask == .command)
                    || (item.submenu.map(claims) ?? false)
            }
        }
        return NSApp.mainMenu.map(claims) ?? false
    }
}
