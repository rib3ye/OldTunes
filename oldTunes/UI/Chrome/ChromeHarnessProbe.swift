import AppKit

/// Test-bench helpers for the chrome harness: reads pixels back out of a snapshot PNG and sends
/// synthetic mouse and key events through the real AppKit dispatch (window.sendEvent), so a
/// check exercises the same hit-testing and responder chain a real click would.
@MainActor
enum ChromeHarnessProbe {

    // MARK: - Pixels

    struct Pixels {
        let rep: NSBitmapImageRep
        /// Device pixels per point in the PNG (2 on Retina).
        let scale: CGFloat

        init?(url: URL, pointWidth: CGFloat) {
            guard let data = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: data) else { return nil }
            self.rep = rep
            scale = CGFloat(rep.pixelsWide) / pointWidth
        }

        /// 8-bit sRGB at a point (top-left origin, in points).
        func rgb(_ x: CGFloat, _ y: CGFloat) -> (r: Int, g: Int, b: Int) {
            rgb(pixelX: Int(x * scale), pixelY: Int(y * scale))
        }

        /// Converts the PNG's own bytes from its embedded profile (BT.2020 with the sRGB curve on
        /// this Mac) to sRGB. `colorAt(x:y:)` is NOT used: it tags the bytes as generic calibrated
        /// RGB (gamma 1.8), which reads every mid-gray about 14 levels too light.
        func rgb(pixelX: Int, pixelY: Int) -> (r: Int, g: Int, b: Int) {
            let x = min(max(pixelX, 0), rep.pixelsWide - 1), y = min(max(pixelY, 0), rep.pixelsHigh - 1)
            guard let data = rep.bitmapData, !rep.isPlanar, rep.bitsPerSample == 8, rep.samplesPerPixel >= 3,
                  !rep.bitmapFormat.contains(.alphaFirst) else {
                return (0, 0, 0)
            }
            let base = y * rep.bytesPerRow + x * (rep.bitsPerPixel / 8)
            let raw = (0..<3).map { CGFloat(data[base + $0]) / 255 } + [1]
            guard let c = NSColor(colorSpace: rep.colorSpace, components: raw, count: 4).usingColorSpace(.sRGB) else {
                return (0, 0, 0)
            }
            return (Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()),
                    Int((c.blueComponent * 255).rounded()))
        }

        /// Mean of the red channel over a horizontal band, per device-pixel column. Averaging over
        /// rows cancels the per-row grain and leaves the gradient's horizontal profile.
        func columnProfile(fromY y0: CGFloat, toY y1: CGFloat) -> [Double] {
            let rows = Array(Int(y0 * scale)..<Int(y1 * scale))
            return (0..<rep.pixelsWide).map { x in
                Double(rows.map { rgb(pixelX: x, pixelY: $0).r }.reduce(0, +)) / Double(max(rows.count, 1))
            }
        }

        /// Pixels at or below point row `fromY` where any byte differs by more than `tolerance`
        /// from `other`. Compares raw bytes: both PNGs come from the same snapshot path.
        func differingPixels(from other: Pixels, tolerance: Int, fromY: CGFloat = 0) -> Int? {
            guard rep.pixelsWide == other.rep.pixelsWide, rep.pixelsHigh == other.rep.pixelsHigh,
                  rep.bitsPerPixel == other.rep.bitsPerPixel, rep.bytesPerRow == other.rep.bytesPerRow,
                  rep.bitsPerPixel % 8 == 0, !rep.isPlanar, !other.rep.isPlanar,
                  let a = rep.bitmapData, let b = other.rep.bitmapData else { return nil }
            let bytesPerPixel = rep.bitsPerPixel / 8
            var count = 0
            for y in Int(fromY * scale)..<rep.pixelsHigh {
                let row = y * rep.bytesPerRow
                for x in 0..<rep.pixelsWide {
                    let base = row + x * bytesPerPixel
                    for i in 0..<bytesPerPixel where abs(Int(a[base + i]) - Int(b[base + i])) > tolerance {
                        count += 1
                        break
                    }
                }
            }
            return count
        }
    }

    static func hex(_ c: (r: Int, g: Int, b: Int)) -> String { String(format: "#%02X%02X%02X", c.r, c.g, c.b) }

    static func near(_ c: (r: Int, g: Int, b: Int), _ hex: Int, tolerance: Int) -> Bool {
        abs(c.r - (hex >> 16 & 0xFF)) <= tolerance && abs(c.g - (hex >> 8 & 0xFF)) <= tolerance
            && abs(c.b - (hex & 0xFF)) <= tolerance
    }

    // MARK: - Events

    private static var eventNumber = 1000

    /// A window point given top-left-origin points, as AppKit's bottom-left window coordinates.
    static func windowPoint(_ window: NSWindow, _ p: NSPoint) -> NSPoint {
        NSPoint(x: p.x, y: window.frame.height - p.y)
    }

    /// How many mouse events went through window.sendEvent, and how many had to be hand-delivered.
    private(set) static var sentEvents = 0
    private(set) static var handDeliveredEvents = 0
    private static weak var mouseDownView: NSView?

    static func mouse(_ type: NSEvent.EventType, _ window: NSWindow, at p: NSPoint, clicks: Int = 1) {
        eventNumber += 1
        guard let event = NSEvent.mouseEvent(with: type, location: windowPoint(window, p), modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil,
                                             eventNumber: eventNumber, clickCount: clicks, pressure: 1) else { return }
        if window.isKeyWindow {
            sentEvents += 1
            window.sendEvent(event)
            return
        }
        // When macOS has kept oldTunes in the background, AppKit swallows synthetic clicks on its
        // windows. Deliver them the way NSWindow does for a key window instead: hit-test from the
        // frame view (the same test a real click gets), then hand the event to that view, keeping
        // the mouse-down view as the target for drags and the mouse-up.
        handDeliveredEvents += 1
        switch type {
        case .leftMouseDown:
            mouseDownView = window.contentView?.superview?.hitTest(event.locationInWindow)
            mouseDownView?.mouseDown(with: event)
        case .leftMouseDragged:
            mouseDownView?.mouseDragged(with: event)
        case .leftMouseUp:
            mouseDownView?.mouseUp(with: event)
            mouseDownView = nil
        default:
            break
        }
    }

    /// Mouse down at the first point, dragged through the rest, released at the last.
    static func drag(_ window: NSWindow, through points: [NSPoint]) {
        guard let first = points.first, let last = points.last else { return }
        mouse(.leftMouseDown, window, at: first)
        for p in points.dropFirst() { mouse(.leftMouseDragged, window, at: p) }
        mouse(.leftMouseUp, window, at: last)
    }

    static func click(_ window: NSWindow, at p: NSPoint) { drag(window, through: [p]) }

    static func key(_ window: NSWindow, _ characters: String, keyCode: UInt16, command: Bool = false) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: command ? [.command] : [],
                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: keyCode)
    }

    /// Types into whatever is first responder, one key event per character.
    static func type(_ window: NSWindow, _ text: String) {
        for ch in text {
            if let event = key(window, String(ch), keyCode: 0) { window.sendEvent(event) }
        }
    }

    /// A ⌘-key the way NSApplication routes it: the window's key equivalents first, then the menu.
    @discardableResult
    static func commandKey(_ window: NSWindow, _ character: String, keyCode: UInt16) -> Bool {
        guard let event = key(window, character, keyCode: keyCode, command: true) else { return false }
        if window.performKeyEquivalent(with: event) { return true }
        return NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
    }

    /// Waits up to `timeout` seconds for `condition`, letting the run loop turn meanwhile.
    static func wait(upTo timeout: Double, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}
