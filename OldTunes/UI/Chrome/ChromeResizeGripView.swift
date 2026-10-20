import AppKit

/// The diagonal-ridged resize grip in the bottom-right corner (§7.2: x 728..754, y 474..499).
/// Dragging it resizes the window with the top-left corner fixed, as a 2005 grip did; the system's
/// own edge resizing still works too. macOS 27's rounded window corner clips the outermost ridges.
@MainActor
final class ChromeResizeGripView: NSView {
    private var startMouse = NSPoint.zero
    private var startFrame = NSRect.zero

    /// Ridges sit this far (in points, measured along both edges) from the bottom-right corner,
    /// and stop `edgeInset` short of the edges so macOS 27's 16 pt corner rounding never clips them.
    static let ridges: [CGFloat] = [10, 14, 18, 22]
    static let edgeInset: CGFloat = 3

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    /// Acts on the first click even in an inactive window, as Aqua window and media buttons did.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let hl = ChromeDraw.hairline(self)
        let corner = NSPoint(x: bounds.maxX, y: bounds.maxY)
        let e = Self.edgeInset
        for k in Self.ridges {
            line(from: NSPoint(x: corner.x - k, y: corner.y - e), to: NSPoint(x: corner.x - e, y: corner.y - k),
                 color: Theme.rule, width: 1)
            line(from: NSPoint(x: corner.x - k + 1.2, y: corner.y - e),
                 to: NSPoint(x: corner.x - e, y: corner.y - k + 1.2),
                 color: ChromePalette.emboss, width: max(hl * 2, 0.8))
        }
    }

    private func line(from a: NSPoint, to b: NSPoint, color: NSColor, width: CGFloat) {
        let path = NSBezierPath()
        path.move(to: a)
        path.line(to: b)
        path.lineWidth = width
        color.setStroke()
        path.stroke()
    }

    // Screen coordinates, because the window (and so this view) moves while it is dragged.
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        startMouse = window.convertPoint(toScreen: event.locationInWindow)
        startFrame = window.frame
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        let now = window.convertPoint(toScreen: event.locationInWindow)
        let minSize = window.minSize
        let width = max(minSize.width, startFrame.width + (now.x - startMouse.x))
        let height = max(minSize.height, startFrame.height - (now.y - startMouse.y))
        // Screen coordinates grow upward: keep the top edge where it was.
        let frame = NSRect(x: startFrame.minX, y: startFrame.maxY - height, width: width, height: height)
        window.setFrame(frame, display: true)
    }
}
