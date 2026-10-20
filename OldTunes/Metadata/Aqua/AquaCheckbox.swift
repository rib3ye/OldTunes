import AppKit

/// A 10.4 checkbox: a small rounded gel square, white when off and Aqua blue with a black tick
/// when on, with an optional Lucida Grande label to its right. Clicking the label toggles it.
@MainActor
final class AquaCheckbox: NSControl {
    enum Size { case regular, small }

    var title: String { didSet { needsDisplay = true } }
    var isOn = false { didSet { if isOn != oldValue { needsDisplay = true } } }
    /// Called after a click toggles the box (not when `isOn` is set in code).
    var onToggle: ((Bool) -> Void)?

    private let size: Size
    private var isPressed = false { didSet { needsDisplay = true } }

    init(title: String = "", size: Size = .regular, onToggle: ((Bool) -> Void)? = nil) {
        self.title = title
        self.size = size
        self.onToggle = onToggle
        super.init(frame: .zero)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(title)
        setFrameSize(fittingSize)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var isEnabled: Bool { didSet { needsDisplay = true } }
    /// Tiger's default keyboard access ("text boxes and lists only") skipped buttons and
    /// checkboxes, and nothing here draws a focus ring, so Tab would otherwise vanish into it.
    override var acceptsFirstResponder: Bool { false }

    private var boxSide: CGFloat { size == .regular ? 14 : 12 }
    private var labelFont: NSFont { AquaStyle.smallFont }

    override var fittingSize: NSSize {
        guard !title.isEmpty else { return NSSize(width: boxSide + 2, height: boxSide + 2) }
        let w = (title as NSString).size(withAttributes: [.font: labelFont]).width
        return NSSize(width: boxSide + 6 + ceil(w) + 2, height: max(boxSide + 2, 15))
    }

    override func draw(_ dirtyRect: NSRect) {
        let y = ((bounds.height - boxSide) / 2).rounded(.down)
        let box = NSRect(x: 0.5, y: y, width: boxSide, height: boxSide)
        let gel: AquaStyle.Gel
        if !isEnabled { gel = AquaStyle.disabledGel }
        else if isPressed { gel = isOn ? AquaStyle.bluePressedGel : AquaStyle.blueGel }
        else { gel = isOn ? AquaStyle.blueGel : AquaStyle.whiteGel }
        AquaStyle.drawGel(in: box, radius: size == .regular ? 3 : 2.5, gel: gel, flipped: true, shadow: true)

        if isOn { drawTick(in: box) }

        guard !title.isEmpty else { return }
        let color = isEnabled ? AquaStyle.text : AquaStyle.textDisabled
        let attrs = AquaStyle.attributes(labelFont, color: color)
        let textY = ((bounds.height - 14) / 2).rounded(.down)
        (title as NSString).draw(in: NSRect(x: boxSide + 6, y: textY, width: bounds.width - boxSide - 6, height: 14),
                                 withAttributes: attrs)
    }

    /// The Aqua tick overshoots the box's top-right corner, which is half of what made it read
    /// as 2005 rather than as a modern checkmark.
    private func drawTick(in box: NSRect) {
        let s = box.width
        let tick = NSBezierPath()
        tick.move(to: NSPoint(x: box.minX + s * 0.22, y: box.minY + s * 0.52))
        tick.line(to: NSPoint(x: box.minX + s * 0.43, y: box.minY + s * 0.78))
        tick.line(to: NSPoint(x: box.minX + s * 0.92, y: box.minY - s * 0.06))
        tick.lineWidth = size == .regular ? 2.1 : 1.8
        tick.lineCapStyle = .round
        tick.lineJoinStyle = .round
        (isEnabled ? NSColor(white: 0.08, alpha: 1) : AquaStyle.textDisabled).setStroke()
        tick.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let window else { return }
        isPressed = true
        while true {
            guard let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            let inside = bounds.contains(convert(next.locationInWindow, from: nil))
            if next.type == .leftMouseUp {
                isPressed = false
                if inside { toggle() }
                return
            }
            isPressed = inside
        }
        isPressed = false
    }

    func toggle() {
        guard isEnabled else { return }
        isOn.toggle()
        onToggle?(isOn)
    }

    override func accessibilityValue() -> Any? { isOn ? 1 : 0 }
    override func accessibilityPerformPress() -> Bool { toggle(); return true }
}
