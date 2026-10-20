import AppKit

/// The visualizer alone on a screen (⇧⌘F), in its own native full-screen space, as iTunes' Full
/// Screen visualizer filled the display. The visualizer view moves in here and back out; Esc, a click
/// or ⇧⌘F returns it to the main window. The cursor hides while the mouse is still.
@MainActor
final class VisualizerFullScreenWindow: NSWindow {
    /// Full screen ended (Esc, a click, ⇧⌘F, or the system's own exit).
    var onExit: (() -> Void)?
    private var cursorTimer: Timer?
    private var lastMouse = NSPoint.zero
    private var exiting = false

    init(on screen: NSScreen?) {
        let frame = screen?.frame ?? NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        super.init(contentRect: frame, styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        title = "Visualizer"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .black
        isReleasedWhenClosed = false
        collectionBehavior = [.fullScreenPrimary, .fullScreenDisallowsTiling]
        contentView = NSView(frame: NSRect(origin: .zero, size: frame.size))
        contentView?.wantsLayer = true
        contentView?.layer?.backgroundColor = NSColor.black.cgColor
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(didExitFullScreen(_:)),
                           name: NSWindow.didExitFullScreenNotification, object: self)
    }

    /// Shows `view` filling the window and goes full screen.
    func present(_ view: NSView) {
        guard let content = contentView else { return }
        view.frame = content.bounds
        view.autoresizingMask = [.width, .height]
        content.addSubview(view)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(view)
        toggleFullScreen(nil)
        startHidingCursor()
    }

    /// Leaves full screen; `onExit` follows once AppKit has finished.
    func leave() {
        guard !exiting else { return }
        exiting = true
        if styleMask.contains(.fullScreen) { toggleFullScreen(nil) } else { finish() }
    }

    override func cancelOperation(_ sender: Any?) { leave() }

    @objc private func didExitFullScreen(_ notification: Notification) {
        finish()
    }

    private func finish() {
        cursorTimer?.invalidate()
        cursorTimer = nil
        NSCursor.setHiddenUntilMouseMoves(false)
        orderOut(nil)
        let exit = onExit
        onExit = nil
        exit?()
    }

    /// Geiss HDR hides the cursor after a second without movement; so does this.
    private func startHidingCursor() {
        lastMouse = NSEvent.mouseLocation
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideCursorIfStill() }
        }
        RunLoop.main.add(timer, forMode: .common)
        cursorTimer = timer
    }

    private func hideCursorIfStill() {
        let mouse = NSEvent.mouseLocation
        defer { lastMouse = mouse }
        guard isKeyWindow, mouse == lastMouse else { return }
        NSCursor.setHiddenUntilMouseMoves(true)
    }
}
