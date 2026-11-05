import AppKit

/// Drawing primitives shared by the chrome views. Every chrome view is flipped (origin top-left),
/// so RESEARCH.md §7.2's top-down y values apply directly, less each view's own top.
@MainActor
enum ChromeDraw {

    /// Fills `path` with `gradient` running from `top` to `bottom`. Explicit end points, because
    /// `NSGradient.draw(in:angle:)` reads angles differently in flipped views.
    static func fill(_ path: NSBezierPath, with gradient: NSGradient?, top: CGFloat, bottom: CGFloat) {
        guard let gradient else { return }
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        gradient.draw(from: NSPoint(x: 0, y: top), to: NSPoint(x: 0, y: bottom),
                      options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation])
        NSGraphicsContext.restoreGraphicsState()
    }

    static func gradient(_ colors: [NSColor], _ locations: [CGFloat]) -> NSGradient? {
        var stops = locations
        return NSGradient(colors: colors, atLocations: &stops, colorSpace: .sRGB)
    }

    /// Text centred on `centerX` with its baseline at `baseline`, truncated with an ellipsis to
    /// `maxWidth`. The reference was measured by baseline, so text is placed by baseline, not by box.
    ///
    /// `embossed` adds the lip that 2005 labels engraved on metal had: light and under the letters,
    /// or, on graphite, dark and over them (ChromePalette.engrave). `glow` is the night LCD's.
    static func text(_ string: String, centerX: CGFloat, baseline: CGFloat, maxWidth: CGFloat,
                     font: NSFont = Theme.font, color: NSColor = Theme.textPrimary, embossed: Bool = false,
                     glow: NSShadow? = nil) {
        guard maxWidth > 4, !string.isEmpty else { return }
        let top = baseline - baselineOffset(for: font)
        let rect = NSRect(x: centerX - maxWidth / 2, y: top, width: maxWidth,
                          height: ceil(font.ascender - font.descender) + 4)
        if embossed {
            let lip = Theme.textAttributes(font, color: ChromePalette.engrave, alignment: .center)
            (string as NSString).draw(with: rect.offsetBy(dx: 0, dy: ChromePalette.engraveOffset),
                                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: lip)
        }
        var attrs = Theme.textAttributes(font, color: color, alignment: .center)
        if let glow { attrs[.shadow] = glow }
        (string as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                  attributes: attrs)
    }

    private static var baselineOffsets: [String: CGFloat] = [:]
    private static let layoutManager = NSLayoutManager()

    /// Where TextKit puts the first baseline below a line fragment's top. It is not the font's
    /// ascender (Lucida Grande 11 rounds 10.63 up), so using the ascender drew text half a pixel low.
    static func baselineOffset(for font: NSFont) -> CGFloat {
        let key = "\(font.fontName)-\(font.pointSize)"
        if let cached = baselineOffsets[key] { return cached }
        let offset = layoutManager.defaultBaselineOffset(for: font)
        baselineOffsets[key] = offset
        return offset
    }

    static func textWidth(_ string: String, font: NSFont = Theme.font) -> CGFloat {
        ceil((string as NSString).size(withAttributes: [.font: font]).width)
    }

    /// A round Aqua gel button on metal (transport and Browse): a light lip under it, a 1 pt ring,
    /// an interior that is darker at the TOP, and a light sweep across the lower half. The sweep is
    /// what makes it read as 2005 gel rather than a flat disc. On graphite the well's shadowed wall
    /// shows above the ring too, and the cap catches a rim light along its top edge.
    static func gelButton(in circle: NSRect, top: NSColor, bottom: NSColor, pressed: Bool) {
        buttonWell(wall: NSBezierPath(ovalIn: circle.offsetBy(dx: 0, dy: -0.75)),
                   lip: NSBezierPath(ovalIn: circle.offsetBy(dx: 0, dy: 0.75)))

        Theme.btnRing.setFill()
        NSBezierPath(ovalIn: circle).fill()

        let inner = circle.insetBy(dx: 1, dy: 1)
        let innerPath = NSBezierPath(ovalIn: inner)
        let k = pressed ? ChromePalette.pressedDarkening : 0
        let shadeTop = ChromePalette.mix(top, .black, 0.1 + k)
        let shadeMid = ChromePalette.mix(top, .black, k)
        let shadeBottom = ChromePalette.mix(bottom, .black, k)
        fill(innerPath, with: gradient([shadeTop, shadeMid, shadeBottom], [0, 0.45, 1]),
             top: inner.minY, bottom: inner.maxY)

        // The sweep: a large soft oval rising from the lower left, clipped to the interior.
        NSGraphicsContext.saveGraphicsState()
        innerPath.addClip()
        let r = inner.width / 2
        let sweep = NSRect(x: inner.minX - r * 0.5, y: inner.midY - r * 0.05,
                           width: inner.width * 1.3, height: inner.height * 1.25)
        let sweepAlpha = ChromePalette.gelSweep
        let glossTop = NSColor.white.withAlphaComponent(pressed ? sweepAlpha.pressedTop : sweepAlpha.top)
        let glossBottom = NSColor.white.withAlphaComponent(pressed ? sweepAlpha.pressedBottom : sweepAlpha.bottom)
        fill(NSBezierPath(ovalIn: sweep), with: gradient([glossTop, glossBottom], [0, 1]),
             top: sweep.minY, bottom: inner.maxY)
        NSGraphicsContext.restoreGraphicsState()

        // The rim light: the cap less a copy of itself 1.5 pt lower leaves a crescent along the top
        // of the ring, thickest at the top and gone by the sides, fading out toward the middle.
        if let rim = ChromePalette.gelRimLight {
            let crescent = NSBezierPath(ovalIn: inner)
            crescent.append(NSBezierPath(ovalIn: inner.offsetBy(dx: 0, dy: 1.5)).reversed)
            let light = NSColor.white.withAlphaComponent(pressed ? rim.pressed : rim.rest)
            fill(crescent, with: gradient([light, light.withAlphaComponent(0)], [0, 1]),
                 top: inner.minY, bottom: inner.minY + inner.height * 0.45)
        }
    }

    /// The well a button sits in: the light lip along its lower edge (§7.1) and, on graphite, the
    /// shadowed wall along its upper edge. Draw it first; the button covers all but the edges.
    static func buttonWell(wall: NSBezierPath?, lip: NSBezierPath) {
        if let wall, let shadow = ChromePalette.buttonWellShadow {
            shadow.setFill()
            wall.fill()
        }
        ChromePalette.buttonLip.setFill()
        lip.fill()
    }

    /// One device pixel in `view`, so hairlines stay hairlines on Retina (§7.3).
    static func hairline(_ view: NSView) -> CGFloat { Theme.hairline(for: view) }

    static func fillRect(_ rect: NSRect, _ color: NSColor) {
        color.setFill()
        rect.fill(using: .sourceOver)
    }
}
