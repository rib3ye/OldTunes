import AppKit

/// A window whose whole face — title bar, traffic lights and pinstripes — is painted by
/// `AquaWindowView`. The real titlebar stays (for dragging, ⌘W, the Window menu) but is
/// transparent and its buttons are hidden, the same route the main window takes (§7.4).
@MainActor
final class AquaWindow: NSWindow {
    /// Return/Enter and Escape when no text view consumed them. Text fields route these through
    /// their delegate instead, so this only fires when focus is elsewhere (artwork tab, buttons).
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    init(contentSize: NSSize, title: String) {
        super.init(contentRect: NSRect(origin: .zero, size: contentSize),
                   styleMask: [.titled, .closable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        self.title = title
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        titlebarSeparatorStyle = .none
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(kind)?.isHidden = true
        }
        let face = AquaWindowView(frame: NSRect(origin: .zero, size: contentSize))
        face.title = title
        contentView = face
        if #available(macOS 26.0, *) { face.prefersCompactControlSizeMetrics = true }
        backgroundColor = AquaStyle.stripeLight
        // 10.4's text selection was a pale blue, not today's accent color.
        if let editor = fieldEditor(true, for: nil) as? NSTextView {
            editor.selectedTextAttributes = [.backgroundColor: AquaStyle.textSelection]
            editor.insertionPointColor = AquaStyle.text
        }
    }

    override var title: String {
        didSet { (contentView as? AquaWindowView)?.title = title }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onReturn?()          // Return, keypad Enter
        case 53: onEscape?()              // Escape
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if let onEscape { onEscape() } else { super.cancelOperation(sender) }
    }
}

/// Paints the 10.4 window face: pinstripes, a 22 pt gradient title bar with centred
/// Lucida Grande 13 title, and gel traffic lights (close live, minimise and zoom disabled,
/// as iTunes' Get Info dialog had them).
@MainActor
final class AquaWindowView: NSView {
    var title = "" { didSet { needsDisplay = true } }
    /// Sheets have no title bar.
    var showsTitleBar = true { didSet { needsDisplay = true } }

    private var closeHovered = false
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        AquaStyle.drawPinstripes(in: bounds)
        guard showsTitleBar else { return }

        let bar = NSRect(x: 0, y: 0, width: bounds.width, height: AquaStyle.titleBarHeight)
        NSGradient(starting: AquaStyle.titleTop, ending: AquaStyle.titleBottom)?.draw(in: bar, angle: 90)
        // Faint stripes through the gradient, as the 10.4 title bar had.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bar).addClip()
        AquaStyle.titleStripe.setFill()
        var y: CGFloat = 0
        while y < bar.maxY { NSRect(x: 0, y: y, width: bar.width, height: 2).fill(); y += 4 }
        NSGraphicsContext.restoreGraphicsState()
        AquaStyle.titleTopEdge.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        AquaStyle.titleRule.setFill()
        NSRect(x: 0, y: bar.maxY - 1, width: bounds.width, height: 1).fill()

        drawTrafficLight(center: NSPoint(x: 15, y: 11), color: Theme.tlRed, enabled: true, glyph: closeHovered)
        drawTrafficLight(center: NSPoint(x: 36, y: 11), color: Theme.tlYellow, enabled: false, glyph: false)
        drawTrafficLight(center: NSPoint(x: 57, y: 11), color: Theme.tlGreen, enabled: false, glyph: false)

        let attrs = AquaStyle.engravedAttributes(AquaStyle.titleFont, alignment: .center)
        let titleRect = NSRect(x: 72, y: 3, width: bounds.width - 144, height: 17)
        (title as NSString).draw(with: titleRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                 attributes: attrs)
    }

    /// A 14 pt Aqua orb: dark rim, colored body that glows toward the bottom, and a white
    /// specular cap. Disabled orbs are the pale hollow gel 10.4 used.
    private func drawTrafficLight(center: NSPoint, color: NSColor, enabled: Bool, glyph: Bool) {
        let d: CGFloat = 14
        let rect = NSRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d)
        let base = enabled ? color : AquaStyle.orbDisabled
        let rim = enabled ? (base.blended(withFraction: 0.55, of: .black) ?? base) : AquaStyle.orbDisabledRim

        AquaStyle.orbShadow.setFill()
        NSBezierPath(ovalIn: rect.offsetBy(dx: 0, dy: 0.75)).fill()
        rim.setFill()
        NSBezierPath(ovalIn: rect).fill()

        // Gel body: deeper at the top, warming to a bright caustic glow at the bottom.
        let body = rect.insetBy(dx: 1, dy: 1)
        let warm = NSColor(srgbRed: 1, green: 0.92, blue: 0.8, alpha: 1)
        let deep = base.blended(withFraction: enabled ? 0.28 : 0.08, of: .black) ?? base
        let glow = base.blended(withFraction: enabled ? 0.38 : AquaStyle.orbDisabledGlow, of: enabled ? warm : .white) ?? base
        NSGradient(colors: [deep, base, glow], atLocations: [0, 0.45, 1], colorSpace: .sRGB)?
            .draw(in: NSBezierPath(ovalIn: body), angle: 90)

        // Specular cap: a bright lens across the top half.
        let cap = NSRect(x: body.minX + 2.2, y: body.minY + 0.5, width: body.width - 4.4, height: body.height * 0.5)
        NSGradient(starting: NSColor(white: 1, alpha: enabled ? 0.95 : AquaStyle.orbDisabledCap),
                   ending: NSColor(white: 1, alpha: 0.12))?.draw(in: NSBezierPath(ovalIn: cap), angle: 90)

        guard glyph else { return }
        let x = NSBezierPath()
        let r: CGFloat = 2.6
        x.move(to: NSPoint(x: center.x - r, y: center.y - r)); x.line(to: NSPoint(x: center.x + r, y: center.y + r))
        x.move(to: NSPoint(x: center.x + r, y: center.y - r)); x.line(to: NSPoint(x: center.x - r, y: center.y + r))
        x.lineWidth = 1.4
        NSColor(white: 0, alpha: 0.6).setStroke()
        x.stroke()
    }

    // MARK: Close button

    private var closeRect: NSRect { NSRect(x: 8, y: 4, width: 14, height: 14) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: NSRect(x: 0, y: 0, width: 72, height: AquaStyle.titleBarHeight),
                                  options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { closeHovered = showsTitleBar; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { closeHovered = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if showsTitleBar, closeRect.insetBy(dx: -2, dy: -2).contains(p) {
            window?.performClose(nil)
        } else {
            super.mouseDown(with: event)
        }
    }
}
