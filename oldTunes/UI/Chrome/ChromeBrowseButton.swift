import AppKit

/// The 37 pt round Browse button with iTunes' eye: an almond outline, a rainbow iris and a black
/// pupil, all drawn in code. It is a toggle: while the column browser is shown it stays pressed in.
/// The eye is a picture, so it keeps its own inks on graphite (ChromePalette.eyeInk).
@MainActor
final class ChromeBrowseButton: NSView {
    var onClick: (() -> Void)?
    var isOn = false { didSet { if isOn != oldValue { needsDisplay = true } } }
    private var isPressed = false { didSet { if isPressed != oldValue { needsDisplay = true } } }
    private var isTracking = false

    static let margin: CGFloat = 2

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    /// Acts on the first click even in an inactive window, as Aqua window and media buttons did.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var circle: NSRect { bounds.insetBy(dx: Self.margin, dy: Self.margin) }

    private func inside(_ p: NSPoint) -> Bool {
        hypot(p.x - circle.midX, p.y - circle.midY) <= circle.width / 2
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        inside(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        isTracking = true
        isPressed = inside(convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        if isTracking { isPressed = inside(convert(event.locationInWindow, from: nil)) }
    }

    override func mouseUp(with event: NSEvent) {
        let fire = isTracking && inside(convert(event.locationInWindow, from: nil))
        isTracking = false
        isPressed = false
        if fire { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        ChromeDraw.gelButton(in: circle, top: Theme.btnPlayTop, bottom: Theme.btnPlayBottom,
                             pressed: isPressed || isOn)
        drawEye(center: NSPoint(x: circle.midX, y: circle.midY))
    }

    private func drawEye(center c: NSPoint) {
        // About 23 × 13.5 pt, the iris filling the opening top to bottom, as in the reference.
        let halfWidth: CGFloat = 11.5, lid: CGFloat = 9
        let almond = NSBezierPath()
        almond.move(to: NSPoint(x: c.x - halfWidth, y: c.y))
        almond.curve(to: NSPoint(x: c.x + halfWidth, y: c.y),
                     controlPoint1: NSPoint(x: c.x - 5, y: c.y - lid),
                     controlPoint2: NSPoint(x: c.x + 5, y: c.y - lid))
        almond.curve(to: NSPoint(x: c.x - halfWidth, y: c.y),
                     controlPoint1: NSPoint(x: c.x + 5, y: c.y + lid),
                     controlPoint2: NSPoint(x: c.x - 5, y: c.y + lid))
        almond.close()
        ChromePalette.eyeWhite.setFill()
        almond.fill()

        // Rainbow iris: wedges around the hue wheel, clipped by the lids.
        NSGraphicsContext.saveGraphicsState()
        almond.addClip()
        let r: CGFloat = 6.6
        let segments = 48
        let step = 360 / CGFloat(segments)
        for i in 0..<segments {
            let start = CGFloat(i) * step
            let wedge = NSBezierPath()
            wedge.move(to: c)
            // Each wedge overlaps the next by half a degree so no hairline seams show.
            wedge.appendArc(withCenter: c, radius: r, startAngle: start, endAngle: start + step + 0.5)
            wedge.close()
            NSColor(hue: CGFloat(i) / CGFloat(segments), saturation: 0.75, brightness: 1, alpha: 1).setFill()
            wedge.fill()
        }
        let irisRim = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        irisRim.lineWidth = 1
        ChromePalette.eyeIrisRim.setStroke()
        irisRim.stroke()
        NSGraphicsContext.restoreGraphicsState()

        ChromePalette.eyeInk.setFill()
        let p: CGFloat = 3
        NSBezierPath(ovalIn: NSRect(x: c.x - p, y: c.y - p, width: 2 * p, height: 2 * p)).fill()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - 2.4, y: c.y - 2.6, width: 1.7, height: 1.7)).fill()

        ChromePalette.eyeInk.setStroke()
        almond.lineWidth = 1.7
        almond.lineJoinStyle = .miter
        almond.stroke()
    }
}
