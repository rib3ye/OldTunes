import AppKit

/// A 10.4 text field: flat white fill, 1 px inset border, soft blue focus glow. The NSTextField
/// inside is borderless and backgroundless — a bezeled one would draw Liquid Glass — and this
/// container paints everything around it. The frame includes a 3 pt margin for the glow, so lay
/// it out with `setBezelFrame(_:)`.
@MainActor
final class AquaTextField: NSView, NSTextFieldDelegate {
    nonisolated static let ringMargin: CGFloat = 3
    nonisolated static let bezelHeight: CGFloat = 19

    let field = FocusReportingTextField()
    /// Called on every keystroke that changes the text.
    var onChange: (() -> Void)?
    /// Digits only, at most this many. Nil allows any text.
    var digitLimit: Int?

    private var isFocused = false { didSet { needsDisplay = true } }

    var stringValue: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    /// Numeric boxes use 0 for blank, matching TagFields.
    var intValue: Int {
        get { Int(field.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0 }
        set { field.stringValue = newValue == 0 ? "" : String(newValue) }
    }

    var isEditable: Bool {
        get { field.isEditable }
        set { field.isEditable = newValue; field.isSelectable = true; needsDisplay = true }
    }

    init(alignment: NSTextAlignment = .left) {
        super.init(frame: .zero)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = AquaStyle.smallFont
        field.textColor = AquaStyle.text
        field.alignment = alignment
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        field.onFocusChange = { [weak self] focused in self?.isFocused = focused }
        addSubview(field)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    func setBezelFrame(_ rect: NSRect) {
        let m = Self.ringMargin
        frame = rect.insetBy(dx: -m, dy: -m)
        let bezel = NSRect(x: m, y: m, width: rect.width, height: rect.height)
        field.frame = NSRect(x: bezel.minX + 3, y: bezel.minY + 2.5, width: bezel.width - 6, height: 14)
    }

    override func draw(_ dirtyRect: NSRect) {
        let bezel = bounds.insetBy(dx: Self.ringMargin, dy: Self.ringMargin)
        AquaStyle.drawFieldBezel(in: bezel, flipped: true, enabled: field.isEditable)
        if isFocused { AquaStyle.drawFocusRing(around: bezel) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(field)
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        if let limit = digitLimit {
            let digits = String(field.stringValue.filter(\.isASCII).filter(\.isNumber).prefix(limit))
            if digits != field.stringValue { field.stringValue = digits }
        }
        onChange?()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        AquaKeyRouting.route(selector, in: window)
    }
}

/// Reports first-responder changes so the container can draw the Aqua focus glow itself.
@MainActor
final class FocusReportingTextField: NSTextField {
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        return ok
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocusChange?(false)
    }
}

/// Return means OK and Escape means Cancel everywhere in the sheet, even inside a text box,
/// which is how the 2005 dialog behaved. Option-Return still types a newline in Comments.
@MainActor
enum AquaKeyRouting {
    static func route(_ selector: Selector, in window: NSWindow?) -> Bool {
        guard let window = window as? AquaWindow else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            window.onReturn?()
            return window.onReturn != nil
        case #selector(NSResponder.cancelOperation(_:)):
            window.onEscape?()
            return window.onEscape != nil
        default:
            return false
        }
    }
}
