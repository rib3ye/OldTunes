import AppKit

/// The search capsule (§7.4: 22 tall, radius 11; at least 103 wide, and ControlBarView widens it with
/// the window): an inset white capsule with a plain black magnifier and a tiny dropdown triangle,
/// wrapping a borderless, non-bezeled NSTextField.
///
/// Typing, selection, copy/paste and undo come from the stock field editor; only the bezel is
/// ours, because a stock NSSearchField renders as macOS 27 glass with no opt-out (§8.1). Focus is
/// shown as a soft Aqua-blue glow around the capsule, like Tiger's focus ring, instead of the
/// modern hard ring.
@MainActor
final class ChromeSearchField: NSView, NSTextFieldDelegate {
    /// Every keystroke; the receiver debounces.
    var onTextChange: ((String) -> Void)?
    let textField = ChromeSearchTextField()
    /// Clips the text to the capsule's text area. While editing, AppKit hosts the field editor in
    /// a clip view 1–2 pt larger than the field on every side, so a long query scrolled to its
    /// end would otherwise draw over the magnifier's triangle.
    private let textClip = ChromeSearchTextClip()

    /// True while the window's field editor is editing this field. Read from the responder chain
    /// rather than tracked, because Return ends editing without moving focus.
    var isFocused: Bool {
        guard let editor = window?.firstResponder as? NSTextView else { return false }
        return editor.delegate === textField
    }

    /// Room around the capsule for the focus glow and the lip.
    static let margin: CGFloat = 3
    private static let textLeft: CGFloat = 24
    private static let textRight: CGFloat = 10

    override init(frame: NSRect) {
        super.init(frame: frame)
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = Theme.font
        textField.textColor = Theme.textPrimary
        textField.usesSingleLineMode = true
        textField.lineBreakMode = .byClipping
        textField.cell?.isScrollable = true
        textField.cell?.wraps = false
        textField.delegate = self
        textField.onFocusChange = { [weak self] in self?.needsDisplay = true }
        textClip.clipsToBounds = true
        textClip.addSubview(textField)
        addSubview(textClip)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    var capsule: NSRect { bounds.insetBy(dx: Self.margin, dy: Self.margin) }

    var text: String {
        get { textField.stringValue }
        set { textField.stringValue = newValue }
    }

    func focus() {
        guard let window else { return }
        window.makeFirstResponder(textField)
        textField.currentEditor()?.selectAll(nil)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        let height = ceil(textField.cell?.cellSize.height ?? 14)
        let c = capsule
        // The clip spans the capsule's inside top to bottom, so only the ends are cut.
        textClip.frame = NSRect(x: c.minX + Self.textLeft, y: c.minY + 1,
                                width: max(0, c.width - Self.textLeft - Self.textRight), height: c.height - 2)
        textField.frame = NSRect(x: 0, y: (c.midY - height / 2).rounded() - textClip.frame.minY,
                                 width: textClip.frame.width, height: height)
    }

    /// Clicking the magnifier or the capsule's ends focuses the field, as with any search field.
    override func mouseDown(with event: NSEvent) { focus() }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        onTextChange?(textField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        // Escape clears, like iTunes. The field keeps focus so the next search can start at once.
        if !textField.stringValue.isEmpty {
            textField.stringValue = ""
            onTextChange?("")
        }
        return true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let c = capsule
        let r = c.height / 2
        if isFocused, window?.isKeyWindow ?? false {
            // A soft halo, strongest next to the field, fading outward.
            for (outset, alpha) in [(CGFloat(3), CGFloat(0.25)), (1.6, 0.5)] {
                ChromePalette.focusGlow.withAlphaComponent(alpha).setFill()
                NSBezierPath(roundedRect: c.insetBy(dx: -outset, dy: -outset),
                             xRadius: r + outset, yRadius: r + outset).fill()
            }
        } else {
            ChromePalette.emboss.setFill()
            NSBezierPath(roundedRect: c.offsetBy(dx: 0, dy: 0.75), xRadius: r, yRadius: r).fill()
        }

        ChromeDraw.fill(NSBezierPath(roundedRect: c, xRadius: r, yRadius: r),
                        with: ChromeDraw.gradient([Theme.searchBorderTop, Theme.searchBorderBottom], [0, 1]),
                        top: c.minY, bottom: c.maxY)
        let inner = c.insetBy(dx: 1, dy: 1)
        let h = inner.height
        ChromeDraw.fill(NSBezierPath(roundedRect: inner, xRadius: r - 1, yRadius: r - 1),
                        with: ChromeDraw.gradient([ChromePalette.mix(Theme.searchInnerTop, .black, 0.08),
                                                   Theme.searchInnerTop, Theme.searchFill, Theme.searchFill,
                                                   Theme.searchInnerBottom], [0, 1 / h, 3 / h, 1 - 1.2 / h, 1]),
                        top: inner.minY, bottom: inner.maxY)

        drawMagnifier(in: c)
    }

    /// A plain black lens and handle plus a small ▾: no recessed circle, that is a later era (§7.4).
    private func drawMagnifier(in c: NSRect) {
        let lens = NSPoint(x: c.minX + 10.5, y: c.minY + 9.5)
        Theme.textPrimary.setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: lens.x - 3.7, y: lens.y - 3.7, width: 7.4, height: 7.4))
        ring.lineWidth = 1.6
        ring.stroke()
        let handle = NSBezierPath()
        handle.lineWidth = 2.4
        handle.lineCapStyle = .round
        handle.move(to: NSPoint(x: lens.x + 3, y: lens.y + 3))
        handle.line(to: NSPoint(x: lens.x + 5.6, y: lens.y + 5.6))
        handle.stroke()

        Theme.btnGlyph.setFill()
        let tri = NSBezierPath()
        tri.move(to: NSPoint(x: c.minX + 17.5, y: c.minY + 9.6))
        tri.line(to: NSPoint(x: c.minX + 21.5, y: c.minY + 9.6))
        tri.line(to: NSPoint(x: c.minX + 19.5, y: c.minY + 12.2))
        tri.close()
        tri.fill()
    }
}

/// The text field inside the capsule. Tells the capsule when focus may have moved so it can
/// redraw its glow.
@MainActor
final class ChromeSearchTextField: NSTextField {
    var onFocusChange: (() -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        onFocusChange?()
        return accepted
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocusChange?()
    }
}

/// The search text's clip: flipped like the rest of the chrome, and click-through, so a click
/// above or below the text still reaches the capsule (which focuses the field) instead of
/// falling to the metal and dragging the window.
@MainActor
private final class ChromeSearchTextClip: NSView {
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
