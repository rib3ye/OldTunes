import AppKit

/// The source list's 16 × 16 icons, drawn in code in the 2005 style: small glossy gradient
/// shapes with a dark 1 px outline, not SF Symbols. Paths assume a flipped context.
@MainActor
enum SourceIcon {
    case library, onThisMac, playlist, smartPlaylist, folder

    func draw(in box: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: box.minX, yBy: box.minY)
        transform.scale(by: box.width / 16)
        transform.concat()
        switch self {
        case .library: Self.drawLibrary()
        case .onThisMac: Self.drawHardDisk()
        case .playlist: Self.drawPlaylist()
        case .smartPlaylist: Self.drawSmartPlaylist()
        case .folder: Self.drawFolder()
        }
    }

    // MARK: Shapes

    /// Three stacked gold sleeves with a note on the front one (the iTunes 4 Library icon).
    private static func drawLibrary() {
        let fill = NSGradient(starting: Theme.hex(0xFBE38C), ending: Theme.hex(0xD9A42C))
        let stroke = Theme.hex(0x8C6A12)
        for origin in [NSPoint(x: 5, y: 0.5), NSPoint(x: 2.75, y: 2.75), NSPoint(x: 0.5, y: 5)] {
            let r = NSRect(x: origin.x, y: origin.y, width: 10.5, height: 10.5)
            let path = NSBezierPath(roundedRect: r, xRadius: 1.2, yRadius: 1.2)
            fill?.draw(in: path, angle: 90)
            stroke.setStroke()
            path.lineWidth = 0.75
            path.stroke()
        }
        note(at: NSPoint(x: 5.6, y: 13.2), scale: 0.85, color: Theme.hex(0x111111))
    }

    /// A silver drive with a front seam and a green activity light: "On This Mac".
    private static func drawHardDisk() {
        let body = NSRect(x: 0.5, y: 3.5, width: 15, height: 9)
        let path = NSBezierPath(roundedRect: body, xRadius: 1.8, yRadius: 1.8)
        NSGradient(colors: [Theme.hex(0xF4F4F4), Theme.hex(0xD2D2D2), Theme.hex(0x9E9E9E)],
                   atLocations: [0, 0.55, 1], colorSpace: .sRGB)?.draw(in: path, angle: 90)
        Theme.hex(0x5E5E5E).setStroke()
        path.lineWidth = 0.75
        path.stroke()
        Theme.hex(0x8A8A8A).setFill()
        NSRect(x: 1.5, y: 9, width: 13, height: 0.75).fill()
        Theme.hex(0xFFFFFF).withAlphaComponent(0.8).setFill()
        NSRect(x: 2, y: 4.5, width: 12, height: 0.75).fill()
        let led = NSBezierPath(ovalIn: NSRect(x: 11.6, y: 10, width: 2, height: 1.6))
        Theme.hex(0x3FBF3F).setFill()
        led.fill()
    }

    /// A pale blue page with a turned corner and a note: a regular playlist.
    private static func drawPlaylist() {
        let page = NSBezierPath()
        page.move(to: NSPoint(x: 2.5, y: 0.5))
        page.line(to: NSPoint(x: 10, y: 0.5))
        page.line(to: NSPoint(x: 13.5, y: 4))
        page.line(to: NSPoint(x: 13.5, y: 15.5))
        page.line(to: NSPoint(x: 2.5, y: 15.5))
        page.close()
        NSGradient(starting: Theme.hex(0xFFFFFF), ending: Theme.hex(0xC9DAF2))?.draw(in: page, angle: 90)
        Theme.hex(0x6E7F9C).setStroke()
        page.lineWidth = 0.75
        page.stroke()
        let fold = NSBezierPath()
        fold.move(to: NSPoint(x: 10, y: 0.5))
        fold.line(to: NSPoint(x: 10, y: 4))
        fold.line(to: NSPoint(x: 13.5, y: 4))
        Theme.hex(0xE6EEF9).setFill()
        fold.fill()
        fold.lineWidth = 0.75
        fold.stroke()
        note(at: NSPoint(x: 6.3, y: 12.6), scale: 0.9, color: Theme.hex(0x111111))
    }

    /// A lavender tile with a white gear: a smart playlist.
    private static func drawSmartPlaylist() {
        let tile = NSBezierPath(roundedRect: NSRect(x: 0.5, y: 0.5, width: 15, height: 15), xRadius: 2.2, yRadius: 2.2)
        NSGradient(starting: Theme.hex(0xD8C9F7), ending: Theme.hex(0x8467D2))?.draw(in: tile, angle: 90)
        Theme.hex(0x5B439F).setStroke()
        tile.lineWidth = 0.75
        tile.stroke()
        let gear = gearPath(center: NSPoint(x: 8, y: 8), outer: 5.6, inner: 4.1, teeth: 8)
        gear.append(NSBezierPath(ovalIn: NSRect(x: 6.2, y: 6.2, width: 3.6, height: 3.6)))
        gear.windingRule = .evenOdd
        Theme.hex(0x4A3590).withAlphaComponent(0.55).setStroke()
        gear.lineWidth = 0.9
        gear.stroke()
        NSColor.white.setFill()
        gear.fill()
    }

    /// A blue Aqua folder with a tab.
    private static func drawFolder() {
        let tab = NSBezierPath(roundedRect: NSRect(x: 1, y: 2.5, width: 6, height: 3), xRadius: 1, yRadius: 1)
        Theme.hex(0x7C9CCB).setFill()
        tab.fill()
        let body = NSBezierPath(roundedRect: NSRect(x: 0.5, y: 4, width: 15, height: 10.5), xRadius: 1.4, yRadius: 1.4)
        NSGradient(starting: Theme.hex(0xBFD3EE), ending: Theme.hex(0x6F92C6))?.draw(in: body, angle: 90)
        Theme.hex(0x4A6894).setStroke()
        body.lineWidth = 0.75
        body.stroke()
        Theme.hex(0xFFFFFF).withAlphaComponent(0.6).setFill()
        NSRect(x: 1.5, y: 5, width: 13, height: 0.75).fill()
    }

    // MARK: Pieces

    /// An eighth note whose head's centre-left sits at `at`.
    private static func note(at p: NSPoint, scale s: CGFloat, color: NSColor) {
        color.setFill()
        let head = NSBezierPath(ovalIn: NSRect(x: p.x - 3.2 * s, y: p.y - 1.6 * s, width: 3.6 * s, height: 2.8 * s))
        head.fill()
        NSRect(x: p.x - 0.1 * s, y: p.y - 7.2 * s, width: 1.1 * s, height: 7 * s).fill()
        let flag = NSBezierPath()
        flag.move(to: NSPoint(x: p.x + 1 * s, y: p.y - 7.2 * s))
        flag.curve(to: NSPoint(x: p.x + 3.2 * s, y: p.y - 3.2 * s),
                   controlPoint1: NSPoint(x: p.x + 1.4 * s, y: p.y - 5.4 * s),
                   controlPoint2: NSPoint(x: p.x + 3.6 * s, y: p.y - 5.2 * s))
        flag.curve(to: NSPoint(x: p.x + 1 * s, y: p.y - 5.2 * s),
                   controlPoint1: NSPoint(x: p.x + 2.6 * s, y: p.y - 4.6 * s),
                   controlPoint2: NSPoint(x: p.x + 1.6 * s, y: p.y - 5 * s))
        flag.close()
        flag.fill()
    }

    private static func gearPath(center c: NSPoint, outer: CGFloat, inner: CGFloat, teeth: Int) -> NSBezierPath {
        let path = NSBezierPath()
        let steps = teeth * 4
        for i in 0..<steps {
            // Each tooth: rise, top, fall, valley — four equal angular steps.
            let radius = (i % 4 == 1 || i % 4 == 2) ? outer : inner
            let angle = (CGFloat(i) / CGFloat(steps)) * 2 * .pi
            let point = NSPoint(x: c.x + cos(angle) * radius, y: c.y + sin(angle) * radius)
            if i == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        path.close()
        return path
    }
}
