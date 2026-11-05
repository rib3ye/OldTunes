import AppKit

/// Hand-drawn close / minimise / zoom orbs. The real buttons are hidden (they render as macOS 27
/// buttons and snap back on every resize, §7.4); these are 14 pt Aqua gel orbs at the §7.2
/// centres, wired to the same window actions.
///
/// Period behaviour: the ×, −, + glyphs appear only while the mouse is anywhere over the group,
/// and an inactive window draws all three gray, as Aqua did.
@MainActor
final class ChromeTrafficLightsView: NSView {
    enum Orb: Int, CaseIterable { case close, minimize, zoom }

    /// Where this view sits in the title bar; orb centres below are relative to it.
    static let frameInTitleBar = NSRect(x: 8, y: 4, width: 59, height: 17)

    /// True while the mouse is over the group. Settable so the harness can photograph the hover look.
    var isHovering = false { didSet { if isHovering != oldValue { needsDisplay = true } } }
    private(set) var pressed: Orb?
    private var tracking: Orb?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    /// Acts on the first click even in an inactive window, as Aqua window and media buttons did.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func center(of orb: Orb) -> NSPoint {
        let origin = Self.frameInTitleBar.origin
        return NSPoint(x: Theme.Metrics.trafficLightCentersX[orb.rawValue] - origin.x,
                       y: Theme.Metrics.trafficLightCenterY - origin.y)
    }

    private func orb(at point: NSPoint) -> Orb? {
        let radius = Theme.Metrics.trafficLightDiameter / 2 + 0.5
        return Orb.allCases.first { hypot(point.x - center(of: $0).x, point.y - center(of: $0).y) <= radius }
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        syncHover()
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    /// Re-reads whether the mouse is over the group. Minimising, zooming or closing from an orb
    /// moves the window out from under a still mouse, and no mouse-exited event follows, so
    /// without this the glyphs would stay drawn on the restored window.
    func syncHover() {
        guard let window, !window.isMiniaturized else { isHovering = false; return }
        isHovering = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    // MARK: - Clicks

    override func mouseDown(with event: NSEvent) {
        tracking = orb(at: convert(event.locationInWindow, from: nil))
        pressed = tracking
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let over = orb(at: convert(event.locationInWindow, from: nil))
        let newPressed = over == tracking ? tracking : nil
        if newPressed != pressed { pressed = newPressed; needsDisplay = true }
    }

    override func mouseUp(with event: NSEvent) {
        let fire = pressed
        pressed = nil
        tracking = nil
        needsDisplay = true
        if let fire { perform(fire) }
    }

    /// The last orb whose action fired; the harness reads it to tell "the click arrived" apart
    /// from "AppKit acted on it".
    private(set) var lastPerformed: Orb?

    func perform(_ orb: Orb) {
        lastPerformed = orb
        guard let window else { return }
        switch orb {
        case .close: window.performClose(nil)
        case .minimize: window.performMiniaturize(nil)
        case .zoom:
            // Aqua's green button zoomed. In full screen, zooming means nothing, so it leaves instead.
            if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) } else { window.zoom(nil) }
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let active = (window?.isKeyWindow ?? false) || (window?.isMainWindow ?? false) || isHovering
        let colors: [Orb: NSColor] = [.close: Theme.tlRed, .minimize: Theme.tlYellow, .zoom: Theme.tlGreen]
        for orb in Orb.allCases {
            let base = active ? (colors[orb] ?? Theme.bevelFill) : Theme.bevelFill
            drawOrb(orb, base: base, pressed: pressed == orb, glyph: isHovering, active: active)
        }
    }

    private func drawOrb(_ orb: Orb, base: NSColor, pressed: Bool, glyph: Bool, active: Bool) {
        let c = center(of: orb)
        let r = Theme.Metrics.trafficLightDiameter / 2
        let outer = NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        let mix = ChromePalette.mix
        // Pressed, the whole orb darkens, its inner glow included.
        let gel = Gel(base: base, hueShift: active ? orb.glowHueShift : 0, brightness: pressed ? 0.75 : 1)

        ChromePalette.emboss.setFill()
        NSBezierPath(ovalIn: outer.offsetBy(dx: 0, dy: 0.75)).fill()

        // Rim: nearly black across the top where the gel is thickest, the hue showing below.
        ChromeDraw.fill(NSBezierPath(ovalIn: outer),
                        with: ChromeDraw.gradient([mix(base, .black, 0.93), mix(base, .black, 0.62),
                                                   mix(base, .black, 0.42)], [0, 0.5, 1]),
                        top: outer.minY, bottom: outer.maxY)

        // Body: deep and saturated under the highlight, lit from inside toward the bottom the way
        // light came through Aqua gel. Stops follow the reference's centre column (12x crop):
        // red #C24A42 → #E87D6D → #FF9B9B → #E0A295, and the same shape in yellow and green.
        let body = outer.insetBy(dx: 1, dy: 1)
        let bodyPath = NSBezierPath(ovalIn: body)
        ChromeDraw.fill(bodyPath, with: ChromeDraw.gradient(
            [gel.deep, gel.deep, gel.mid, gel.glow, gel.glow, gel.bottom], [0, 0.36, 0.55, 0.72, 0.86, 1]),
            top: body.minY, bottom: body.maxY)
        // The sides fall back to the deep hue and darken into the rim, so it reads as a sphere.
        let sphere = NSPoint(x: c.x, y: c.y + 1.5)
        NSGraphicsContext.saveGraphicsState()
        bodyPath.addClip()
        ChromeDraw.gradient([gel.deep.withAlphaComponent(0), gel.deep.withAlphaComponent(0.9),
                             mix(gel.deep, .black, 0.3)], [0.5, 0.8, 1])?
            .draw(fromCenter: sphere, radius: 0, toCenter: sphere, radius: body.width / 2 + 1.5, options: [])
        NSGraphicsContext.restoreGraphicsState()

        // Specular highlight: a bright lens across the top that is gone by the middle.
        let spec = NSRect(x: c.x - r * 0.62, y: body.minY + 0.2, width: r * 1.24, height: 3.4)
        ChromeDraw.fill(NSBezierPath(ovalIn: spec),
                        with: ChromeDraw.gradient([NSColor.white.withAlphaComponent(active ? 0.95 : 0.85),
                                                   NSColor.white.withAlphaComponent(active ? 0.8 : 0.7),
                                                   NSColor.white.withAlphaComponent(0.05)], [0, 0.35, 1]),
                        top: spec.minY, bottom: spec.maxY)

        guard glyph else { return }
        let ink = mix(base, .black, 0.72).withAlphaComponent(0.9)
        ink.setStroke()
        let g: CGFloat = 2.6
        let path = NSBezierPath()
        path.lineWidth = 1.3
        path.lineCapStyle = .round
        switch orb {
        case .close:
            path.move(to: NSPoint(x: c.x - g, y: c.y - g)); path.line(to: NSPoint(x: c.x + g, y: c.y + g))
            path.move(to: NSPoint(x: c.x - g, y: c.y + g)); path.line(to: NSPoint(x: c.x + g, y: c.y - g))
        case .minimize:
            path.move(to: NSPoint(x: c.x - g - 0.4, y: c.y)); path.line(to: NSPoint(x: c.x + g + 0.4, y: c.y))
        case .zoom:
            path.move(to: NSPoint(x: c.x - g - 0.4, y: c.y)); path.line(to: NSPoint(x: c.x + g + 0.4, y: c.y))
            path.move(to: NSPoint(x: c.x, y: c.y - g - 0.4)); path.line(to: NSPoint(x: c.x, y: c.y + g + 0.4))
        }
        path.stroke()
    }
}

private extension ChromeTrafficLightsView.Orb {
    /// Light through the gel shifted hue as it brightened: red toward pink, yellow toward lemon,
    /// green toward lime (reference, 12x crop: #C24A42 → #FF9B9B, #E2A123 → #FFFA90,
    /// #77B129 → #D9FF98).
    var glowHueShift: CGFloat {
        switch self {
        case .close: -6
        case .minimize: 21
        case .zoom: -10
        }
    }
}

/// The four tones of one Aqua gel orb, derived from its Theme colour in HSB so a Theme change
/// carries through. Gray (inactive) bases stay gray.
@MainActor
private struct Gel {
    let deep, mid, glow, bottom: NSColor

    /// `brightness` scales every tone; below 1 it is the pressed look.
    init(base: NSColor, hueShift: CGFloat, brightness scale: CGFloat) {
        let c = base.usingColorSpace(.sRGB) ?? base
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        func tone(_ shift: CGFloat, _ sat: CGFloat, _ bright: CGFloat) -> NSColor {
            var hue = h + shift / 360
            hue -= floor(hue)
            return NSColor(colorSpace: .sRGB, hue: hue, saturation: min(1, s * sat),
                           brightness: min(1, bright) * scale, alpha: 1)
        }
        deep = tone(0, 1.02, b * 0.92)
        mid = tone(hueShift * 0.4, 0.8, max(b, 0.92))
        glow = tone(hueShift, 0.58, 1)
        bottom = tone(hueShift, 0.6, 0.88)
    }
}
