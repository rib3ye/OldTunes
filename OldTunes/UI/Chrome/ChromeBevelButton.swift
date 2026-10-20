import AppKit

/// A 31 × 22 bottom-bar button (§7.2): rounded-rect bevel with a white lip under the border, a
/// soft ramp down to `bevelFill`, a darker band at the bottom, and a light emboss under the whole
/// button. Toggles light their glyph Aqua blue; disabled buttons draw dimmed and ignore clicks.
@MainActor
final class ChromeBevelButton: NSView {
    enum Glyph { case add, shuffle, repeatAll, repeatOne, artworkShow, artworkHide, equalizer, visualizer, eject }

    var glyph: Glyph { didSet { if glyph != oldValue { needsDisplay = true } } }
    var isLit = false { didSet { if isLit != oldValue { needsDisplay = true } } }
    var isEnabled = true { didSet { if isEnabled != oldValue { needsDisplay = true } } }
    var onClick: (() -> Void)?
    private(set) var isPressed = false { didSet { if isPressed != oldValue { needsDisplay = true } } }
    private var isTracking = false

    static let cornerRadius: CGFloat = 4
    /// Room under the button for the emboss lip.
    static let lipRoom: CGFloat = 1

    init(glyph: Glyph) {
        self.glyph = glyph
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    /// Acts on the first click even in an inactive window, as Aqua window and media buttons did.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var body: NSRect {
        NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - Self.lipRoom)
    }

    private func inside(_ event: NSEvent) -> Bool {
        body.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isTracking = true
        isPressed = inside(event)
    }

    override func mouseDragged(with event: NSEvent) {
        if isTracking { isPressed = inside(event) }
    }

    override func mouseUp(with event: NSEvent) {
        let fire = isTracking && inside(event)
        isTracking = false
        isPressed = false
        if fire { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = Self.cornerRadius
        let outer = body
        // Disabled buttons fade as one piece, so the border does not show through the interior.
        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.saveGState()
        if !isEnabled { ctx?.setAlpha(0.55) }
        ctx?.beginTransparencyLayer(auxiliaryInfo: nil)

        // The view has no room above the button, so the well shows only its lip; the dark border
        // already marks the top edge.
        ChromeDraw.buttonWell(wall: nil,
                              lip: NSBezierPath(roundedRect: outer.offsetBy(dx: 0, dy: 1), xRadius: r, yRadius: r))
        Theme.bevelBorder.setFill()
        NSBezierPath(roundedRect: outer, xRadius: r, yRadius: r).fill()
        let inner = outer.insetBy(dx: 1, dy: 1)
        ChromeDraw.fill(NSBezierPath(roundedRect: inner, xRadius: r - 1, yRadius: r - 1),
                        with: isPressed ? ChromePalette.bevelInteriorPressed : ChromePalette.bevelInterior,
                        top: inner.minY, bottom: inner.maxY)

        let ink = !isEnabled ? Theme.textDimmed : (isLit ? ChromePalette.lit : Theme.btnGlyph)
        let center = NSPoint(x: outer.midX, y: outer.midY)
        // A dimmed glyph is faint paint; an engraving line would make it busier, not quieter.
        if isEnabled, let engrave = ChromePalette.glyphEngrave {
            ChromeBevelGlyphs.draw(glyph, center: NSPoint(x: center.x, y: center.y - 1), ink: engrave,
                                   silhouette: true)
        }
        ChromeBevelGlyphs.draw(glyph, center: center, ink: ink)
        ctx?.endTransparencyLayer()
        ctx?.restoreGState()
    }
}
