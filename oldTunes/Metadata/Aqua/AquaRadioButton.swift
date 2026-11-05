import AppKit

/// A 10.4 radio button: a round gel, white when off and Aqua blue with a dark dot when on, with a
/// Lucida Grande label to its right. Clicking the label picks it too. There is no group object:
/// whoever owns a set of them turns the others off in `onPick`, as a few lines of plain code.
@MainActor
final class AquaRadioButton: NSControl {
    var title: String { didSet { needsDisplay = true } }
    var isOn = false { didSet { if isOn != oldValue { needsDisplay = true } } }
    /// Called when a click picks this button (not when `isOn` is set in code). A click on the one
    /// already picked does nothing, as with any radio button.
    var onPick: (() -> Void)?

    private let labelFont: NSFont
    private var isPressed = false { didSet { needsDisplay = true } }

    /// The regular 10.4 size; the label sits 6 pt to its right.
    static let diameter: CGFloat = 14

    init(title: String, font: NSFont = AquaStyle.controlFont) {
        self.title = title
        self.labelFont = font
        super.init(frame: .zero)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(title)
        setFrameSize(fittingSize)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var isEnabled: Bool { didSet { needsDisplay = true } }
    /// Tiger's default keyboard access ("text boxes and lists only") skipped radio buttons too.
    override var acceptsFirstResponder: Bool { false }

    override var fittingSize: NSSize {
        let w = (title as NSString).size(withAttributes: [.font: labelFont]).width
        return NSSize(width: Self.diameter + 6 + ceil(w) + 2, height: max(Self.diameter + 2, 17))
    }

    override func draw(_ dirtyRect: NSRect) {
        let d = Self.diameter
        let y = ((bounds.height - d) / 2).rounded(.down)
        let circle = NSRect(x: 0.5, y: y, width: d, height: d)
        let gel: AquaStyle.Gel
        if !isEnabled { gel = AquaStyle.disabledGel }
        else if isPressed { gel = isOn ? AquaStyle.bluePressedGel : AquaStyle.blueGel }
        else { gel = isOn ? AquaStyle.blueGel : AquaStyle.whiteGel }
        AquaStyle.drawGel(in: circle, radius: d / 2, gel: gel, flipped: true, shadow: true)

        if isOn {
            // The dot sits a hair above centre, under the specular highlight, as 10.4 drew it.
            let r: CGFloat = 2.6
            (isEnabled ? NSColor(white: 0.08, alpha: 0.9) : AquaStyle.textDisabled).setFill()
            NSBezierPath(ovalIn: NSRect(x: circle.midX - r, y: circle.midY - r - 0.25, width: 2 * r, height: 2 * r)).fill()
        }

        let color = isEnabled ? AquaStyle.text : AquaStyle.textDisabled
        let attrs = AquaStyle.attributes(labelFont, color: color)
        let textHeight = ceil(labelFont.ascender - labelFont.descender)
        (title as NSString).draw(in: NSRect(x: d + 6, y: ((bounds.height - textHeight) / 2).rounded(.down),
                                            width: bounds.width - d - 6, height: textHeight),
                                 withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let window else { return }
        isPressed = true
        while true {
            guard let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            let inside = bounds.contains(convert(next.locationInWindow, from: nil))
            if next.type == .leftMouseUp {
                isPressed = false
                if inside { pick() }
                return
            }
            isPressed = inside
        }
        isPressed = false
    }

    /// Picks this button as if clicked.
    func pick() {
        guard isEnabled, !isOn else { return }
        isOn = true
        onPick?()
    }

    override func accessibilityValue() -> Any? { isOn ? 1 : 0 }
    override func accessibilityPerformPress() -> Bool { pick(); return true }
}
