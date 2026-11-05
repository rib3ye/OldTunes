import AppKit

/// One of the three round transport buttons: back (29 pt), play/pause (37 pt), forward (29 pt).
/// Gel interior per §7.1, darker while pressed, glyphs in `btnGlyph`.
@MainActor
final class ChromeTransportButton: NSView {
    enum Kind { case previous, playPause, next }

    let kind: Kind
    var onClick: (() -> Void)?
    /// Play/pause shows pause bars while playing and a play triangle otherwise.
    var isPlaying = false { didSet { if isPlaying != oldValue { needsDisplay = true } } }
    private(set) var isPressed = false { didSet { if isPressed != oldValue { needsDisplay = true } } }
    private var isTracking = false

    /// Room around the circle for the emboss lip.
    static let margin: CGFloat = 2

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    /// Acts on the first click even in an inactive window, as Aqua window and media buttons did.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var diameter: CGFloat {
        kind == .playPause ? Theme.Metrics.playButton.diameter : Theme.Metrics.backButton.diameter
    }

    private var circle: NSRect { bounds.insetBy(dx: Self.margin, dy: Self.margin) }

    private func inside(_ event: NSEvent) -> Bool {
        let p = convert(event.locationInWindow, from: nil)
        return hypot(p.x - circle.midX, p.y - circle.midY) <= diameter / 2
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return hypot(p.x - circle.midX, p.y - circle.midY) <= diameter / 2 ? self : nil
    }

    override func mouseDown(with event: NSEvent) { isTracking = true; isPressed = inside(event) }
    override func mouseDragged(with event: NSEvent) { if isTracking { isPressed = inside(event) } }
    override func mouseUp(with event: NSEvent) {
        let fire = isTracking && inside(event)
        isTracking = false
        isPressed = false
        if fire { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let isPlay = kind == .playPause
        ChromeDraw.gelButton(in: circle, top: isPlay ? Theme.btnPlayTop : Theme.btnStepTop,
                             bottom: isPlay ? Theme.btnPlayBottom : Theme.btnStepBottom, pressed: isPressed)
        let c = NSPoint(x: circle.midX, y: circle.midY)
        if let engrave = ChromePalette.glyphEngrave {
            engrave.setFill()
            drawGlyph(at: NSPoint(x: c.x, y: c.y - 1))
        }
        Theme.btnGlyph.setFill()
        drawGlyph(at: c)
    }

    /// The glyph centred on `c`, in the current fill color.
    private func drawGlyph(at c: NSPoint) {
        switch kind {
        case .previous:
            triangle(tipX: c.x - 8.5, baseX: c.x - 0.5, cy: c.y)
            triangle(tipX: c.x - 0.5, baseX: c.x + 7.5, cy: c.y)
        case .next:
            triangle(tipX: c.x + 8.5, baseX: c.x + 0.5, cy: c.y)
            triangle(tipX: c.x + 0.5, baseX: c.x - 7.5, cy: c.y)
        case .playPause where isPlaying:
            let w = Theme.Metrics.pauseBarWidth, gap = Theme.Metrics.pauseBarGap, h: CGFloat = 15
            let left = c.x - w - gap / 2
            NSRect(x: left, y: c.y - h / 2, width: w, height: h).fill()
            NSRect(x: left + w + gap, y: c.y - h / 2, width: w, height: h).fill()
        case .playPause:
            // Optical centre: a right-pointing triangle looks centred when nudged right.
            let path = NSBezierPath()
            path.move(to: NSPoint(x: c.x - 5, y: c.y - 8))
            path.line(to: NSPoint(x: c.x + 8.5, y: c.y))
            path.line(to: NSPoint(x: c.x - 5, y: c.y + 8))
            path.close()
            path.fill()
        }
    }

    /// The back/forward glyph is two 9 pt-tall triangles touching tip to base, 16 pt across.
    private func triangle(tipX: CGFloat, baseX: CGFloat, cy: CGFloat) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: tipX, y: cy))
        path.line(to: NSPoint(x: baseX, y: cy - 4.75))
        path.line(to: NSPoint(x: baseX, y: cy + 4.75))
        path.close()
        path.fill()
    }
}
