import AppKit

/// Small glyphs drawn into list cells. Hand-drawn because SF Symbols are a 2019 look and stock
/// controls render as Liquid Glass. All paths assume a flipped context (y grows downward), which
/// is what table cells and header views use.
@MainActor
enum ListGlyphs {

    /// The now-playing speaker: filled while playing, outlined while paused. Fits a 12 × 10 box.
    static func speaker(in box: NSRect, filled: Bool, color: NSColor) {
        let x = box.minX, midY = box.midY
        let body = NSBezierPath()
        body.move(to: NSPoint(x: x + 0.5, y: midY - 2))
        body.line(to: NSPoint(x: x + 3, y: midY - 2))
        body.line(to: NSPoint(x: x + 6, y: midY - 4.5))
        body.line(to: NSPoint(x: x + 6, y: midY + 4.5))
        body.line(to: NSPoint(x: x + 3, y: midY + 2))
        body.line(to: NSPoint(x: x + 0.5, y: midY + 2))
        body.close()
        color.set()
        if filled {
            body.fill()
        } else {
            body.lineWidth = 1
            body.lineJoinStyle = .round
            body.stroke()
        }
        // Two sound waves, arcs centred on the cone's mouth.
        for (radius, alpha) in [(CGFloat(3), CGFloat(1)), (CGFloat(5.5), CGFloat(filled ? 1 : 0.85))] {
            let wave = NSBezierPath()
            wave.appendArc(withCenter: NSPoint(x: x + 5.5, y: midY), radius: radius,
                           startAngle: -50, endAngle: 50, clockwise: false)
            wave.lineWidth = 1.1
            wave.lineCapStyle = .round
            color.withAlphaComponent(alpha).set()
            wave.stroke()
        }
    }

    /// The cloud badge on rows that live only in iCloud. Fits a 13 × 9 box.
    static func cloud(in box: NSRect, color: NSColor) {
        let path = NSBezierPath()
        let base = box.maxY - 0.5
        path.appendOval(in: NSRect(x: box.minX, y: base - 5, width: 5, height: 5))
        path.appendOval(in: NSRect(x: box.minX + 2.5, y: base - 8, width: 6.5, height: 6.5))
        path.appendOval(in: NSRect(x: box.minX + 7, y: base - 6.5, width: 5.5, height: 5.5))
        path.append(NSBezierPath(roundedRect: NSRect(x: box.minX + 1.5, y: base - 3.5, width: 10, height: 3.5),
                                 xRadius: 1.5, yRadius: 1.5))
        path.windingRule = .nonZero
        color.setFill()
        path.fill()
    }

    /// Column-header sort triangle: ▲ ascending, ▼ descending. 7 × 6, like the reference.
    static func sortTriangle(centeredAt c: NSPoint, ascending: Bool, color: NSColor) {
        let w: CGFloat = 7, h: CGFloat = 6
        let path = NSBezierPath()
        if ascending {
            path.move(to: NSPoint(x: c.x - w / 2, y: c.y + h / 2))
            path.line(to: NSPoint(x: c.x + w / 2, y: c.y + h / 2))
            path.line(to: NSPoint(x: c.x, y: c.y - h / 2))
        } else {
            path.move(to: NSPoint(x: c.x - w / 2, y: c.y - h / 2))
            path.line(to: NSPoint(x: c.x + w / 2, y: c.y - h / 2))
            path.line(to: NSPoint(x: c.x, y: c.y + h / 2))
        }
        path.close()
        color.setFill()
        path.fill()
    }

    /// Source-list disclosure triangle: ▶ collapsed, ▼ expanded, in a 9 × 9 box.
    static func disclosure(in box: NSRect, expanded: Bool, color: NSColor) {
        let path = NSBezierPath()
        if expanded {
            path.move(to: NSPoint(x: box.minX, y: box.minY + 1.5))
            path.line(to: NSPoint(x: box.maxX, y: box.minY + 1.5))
            path.line(to: NSPoint(x: box.midX, y: box.maxY - 0.5))
        } else {
            path.move(to: NSPoint(x: box.minX + 1.5, y: box.minY))
            path.line(to: NSPoint(x: box.maxX - 0.5, y: box.midY))
            path.line(to: NSPoint(x: box.minX + 1.5, y: box.maxY))
        }
        path.close()
        color.setFill()
        path.fill()
    }
}
