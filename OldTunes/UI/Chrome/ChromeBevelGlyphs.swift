import AppKit

/// The bottom-bar button glyphs, drawn as paths so they stay crisp at any scale. Shapes follow the
/// iTunes 4.9 reference (itunes_buttons.png): +, crossed shuffle arrows, the repeat loop (with a
/// "1" badge for repeat-one), the artwork frame, equalizer sliders, the visualizer flower, eject.
@MainActor
enum ChromeBevelGlyphs {
    /// `silhouette` draws the glyph's bare shape in `ink`, for the engraving line drawn behind it: no
    /// badge numeral or ring, and no see-through fill that would darken the glyph drawn on top.
    static func draw(_ glyph: ChromeBevelButton.Glyph, center c: NSPoint, ink: NSColor, silhouette: Bool = false) {
        ink.setFill()
        ink.setStroke()
        switch glyph {
        case .add:
            NSRect(x: c.x - 5.5, y: c.y - 1.4, width: 11, height: 2.8).fill()
            NSRect(x: c.x - 1.4, y: c.y - 5.5, width: 2.8, height: 11).fill()
        case .shuffle:
            shuffle(c)
        case .repeatAll:
            repeatLoop(c)
        case .repeatOne:
            repeatLoop(c)
            badgeOne(at: NSPoint(x: c.x + 7.6, y: c.y - 4.6), ink: ink, silhouette: silhouette)
        case .artworkShow, .artworkHide:
            artwork(c, pointingUp: glyph == .artworkShow)
        case .equalizer:
            equalizer(c)
        case .visualizer:
            visualizer(c, ink: ink, silhouette: silhouette)
        case .eject:
            polygon([NSPoint(x: c.x, y: c.y - 5.5), NSPoint(x: c.x + 6, y: c.y + 0.6),
                     NSPoint(x: c.x - 6, y: c.y + 0.6)]).fill()
            NSRect(x: c.x - 6, y: c.y + 2.4, width: 12, height: 2.6).fill()
        }
    }

    private static func polygon(_ points: [NSPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        guard let first = points.first else { return path }
        path.move(to: first)
        points.dropFirst().forEach { path.line(to: $0) }
        path.close()
        return path
    }

    private static func shuffle(_ c: NSPoint) {
        for sign in [CGFloat(1), -1] {
            let path = NSBezierPath()
            path.lineWidth = 2
            path.move(to: NSPoint(x: c.x - 7.5, y: c.y - 3.8 * sign))
            path.line(to: NSPoint(x: c.x - 4.5, y: c.y - 3.8 * sign))
            path.curve(to: NSPoint(x: c.x + 2.5, y: c.y + 3.8 * sign),
                       controlPoint1: NSPoint(x: c.x - 1, y: c.y - 3.8 * sign),
                       controlPoint2: NSPoint(x: c.x - 1, y: c.y + 3.8 * sign))
            path.line(to: NSPoint(x: c.x + 4.5, y: c.y + 3.8 * sign))
            path.stroke()
            polygon([NSPoint(x: c.x + 8, y: c.y + 3.8 * sign), NSPoint(x: c.x + 4, y: c.y + 0.6 * sign),
                     NSPoint(x: c.x + 4, y: c.y + 7 * sign)]).fill()
        }
    }

    private static func repeatLoop(_ c: NSPoint) {
        for sign in [CGFloat(1), -1] {
            // sign 1: the left side and top run, arrow pointing right; -1: the mirror image.
            let path = NSBezierPath()
            path.lineWidth = 2
            path.move(to: NSPoint(x: c.x - 6.5 * sign, y: c.y + 1.5 * sign))
            path.line(to: NSPoint(x: c.x - 6.5 * sign, y: c.y - 1.5 * sign))
            path.curve(to: NSPoint(x: c.x - 3.5 * sign, y: c.y - 4.5 * sign),
                       controlPoint1: NSPoint(x: c.x - 6.5 * sign, y: c.y - 3.3 * sign),
                       controlPoint2: NSPoint(x: c.x - 5.2 * sign, y: c.y - 4.5 * sign))
            path.line(to: NSPoint(x: c.x + 3 * sign, y: c.y - 4.5 * sign))
            path.stroke()
            polygon([NSPoint(x: c.x + 7 * sign, y: c.y - 4.5 * sign), NSPoint(x: c.x + 3 * sign, y: c.y - 7.7 * sign),
                     NSPoint(x: c.x + 3 * sign, y: c.y - 1.3 * sign)]).fill()
        }
    }

    /// Repeat-one: a small filled disc with a white "1", ringed in the button colour to stand off
    /// the arrows underneath.
    private static func badgeOne(at p: NSPoint, ink: NSColor, silhouette: Bool) {
        let r: CGFloat = 4
        let disc = NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        if silhouette {
            ink.setFill()
            disc.fill()
            return
        }
        Theme.bevelFill.setStroke()
        disc.lineWidth = 1.5
        disc.stroke()
        ink.setFill()
        disc.fill()
        let font = NSFont(name: Theme.boldFont.fontName, size: 7) ?? .boldSystemFont(ofSize: 7)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let size = ("1" as NSString).size(withAttributes: attrs)
        ("1" as NSString).draw(at: NSPoint(x: p.x - size.width / 2 + 0.2, y: p.y - size.height / 2),
                               withAttributes: attrs)
    }

    private static func artwork(_ c: NSPoint, pointingUp: Bool) {
        let frame = NSRect(x: c.x - 7, y: c.y - 5.5, width: 14, height: 11)
        let outline = NSBezierPath(rect: frame.insetBy(dx: 0.65, dy: 0.65))
        outline.lineWidth = 1.3
        outline.stroke()
        NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: 3).fill()
        let tipY = pointingUp ? c.y + 0.2 : c.y + 4
        let baseY = pointingUp ? c.y + 3.6 : c.y + 0.6
        polygon([NSPoint(x: c.x, y: tipY), NSPoint(x: c.x + 3.4, y: baseY), NSPoint(x: c.x - 3.4, y: baseY)]).fill()
    }

    private static func equalizer(_ c: NSPoint) {
        let knobs: [CGFloat] = [2.5, -2.5, 0]
        for (i, dx) in [CGFloat(-4.5), 0, 4.5].enumerated() {
            NSRect(x: c.x + dx - 0.7, y: c.y - 6, width: 1.4, height: 12).fill()
            NSRect(x: c.x + dx - 1.9, y: c.y + knobs[i] - 1.2, width: 3.8, height: 2.4).fill()
        }
    }

    private static func visualizer(_ c: NSPoint, ink: NSColor, silhouette: Bool) {
        for i in 0..<8 {
            let petal = NSBezierPath(ovalIn: NSRect(x: 0.8, y: -1.25, width: 5, height: 2.5))
            var t = AffineTransform(translationByX: c.x, byY: c.y)
            t.rotate(byDegrees: CGFloat(i) * 45)
            petal.transform(using: t)
            if !silhouette {
                ink.withAlphaComponent(0.25).setFill()
                petal.fill()
            }
            ink.setStroke()
            petal.lineWidth = 0.9
            petal.stroke()
        }
        ink.setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - 1.3, y: c.y - 1.3, width: 2.6, height: 2.6)).fill()
    }
}
