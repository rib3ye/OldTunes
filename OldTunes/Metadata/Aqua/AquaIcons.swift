import AppKit

/// Small procedural pictures for the Get Info window. The app's own icon and Music's are modern
/// glass, which would be the one 2026 object in a 2005 dialog, so these are drawn instead.
@MainActor
enum AquaIcons {

    /// A silver CD with a blue double note: the iTunes 4 placeholder, used for alert sheets and
    /// for a song with no artwork.
    static func drawDisc(in rect: NSRect) {
        let r = min(rect.width, rect.height)
        let disc = NSRect(x: rect.midX - r / 2, y: rect.midY - r / 2, width: r, height: r).insetBy(dx: 1, dy: 1)

        NSColor(white: 0, alpha: 0.18).setFill()
        NSBezierPath(ovalIn: disc.offsetBy(dx: 0, dy: r * 0.02)).fill()
        Theme.hex(0x8A8A8A).setFill()
        NSBezierPath(ovalIn: disc).fill()

        let face = disc.insetBy(dx: 1, dy: 1)
        let silver = NSGradient(colors: [0xFBFBFB, 0xD6D9DE, 0xEEF0F2, 0xB9BDC4, 0xF4F4F4].map(Theme.hex),
                                atLocations: [0, 0.3, 0.55, 0.8, 1], colorSpace: .sRGB)
        silver?.draw(in: NSBezierPath(ovalIn: face), angle: 35)

        // A faint rainbow sheen, as pressed CDs catch the light.
        let sheen = NSGradient(colors: [NSColor(srgbRed: 0.6, green: 0.8, blue: 1, alpha: 0.0),
                                        NSColor(srgbRed: 0.75, green: 0.6, blue: 1, alpha: 0.28),
                                        NSColor(srgbRed: 1, green: 0.85, blue: 0.6, alpha: 0.22),
                                        NSColor(srgbRed: 0.6, green: 1, blue: 0.8, alpha: 0.0)],
                               atLocations: [0, 0.4, 0.6, 1], colorSpace: .sRGB)
        sheen?.draw(in: NSBezierPath(ovalIn: face), angle: -50)

        let hub = NSRect(x: disc.midX - r * 0.16, y: disc.midY - r * 0.16, width: r * 0.32, height: r * 0.32)
        Theme.hex(0xC9CCD1).setFill()
        NSBezierPath(ovalIn: hub).fill()
        Theme.hex(0x9A9A9A).setStroke()
        NSBezierPath(ovalIn: hub).stroke()
        AquaStyle.stripeLight.setFill()
        NSBezierPath(ovalIn: hub.insetBy(dx: r * 0.1, dy: r * 0.1)).fill()

        let note = "♫" as NSString
        let font = NSFont.systemFont(ofSize: r * 0.5, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.hex(0x2F6FD0)]
        let size = note.size(withAttributes: attrs)
        note.draw(at: NSPoint(x: disc.midX - size.width / 2 + r * 0.02, y: disc.midY - size.height / 2),
                  withAttributes: attrs)
    }

    /// The small cloud that marks a song stored only in iCloud.
    static func drawCloud(in rect: NSRect, color: NSColor = Theme.hex(0x6E8DB5)) {
        let w = rect.width, h = rect.height
        let path = NSBezierPath()
        path.appendOval(in: NSRect(x: rect.minX + w * 0.05, y: rect.minY + h * 0.35, width: w * 0.42, height: h * 0.55))
        path.appendOval(in: NSRect(x: rect.minX + w * 0.28, y: rect.minY + h * 0.08, width: w * 0.48, height: h * 0.72))
        path.appendOval(in: NSRect(x: rect.minX + w * 0.55, y: rect.minY + h * 0.32, width: w * 0.4, height: h * 0.56))
        path.appendRect(NSRect(x: rect.minX + w * 0.22, y: rect.minY + h * 0.55, width: w * 0.58, height: h * 0.35))
        path.windingRule = .nonZero
        color.setFill()
        path.fill()
    }
}
