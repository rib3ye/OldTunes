import AppKit

/// The box a playlist's name is edited in, laid over its source-list row: the 10.4 text field
/// Get Info uses (flat white, 1 px inset border, blue focus glow). Return, Tab or clicking away
/// keeps the typed name; Escape puts the old one back.
@MainActor
final class SourceRenameField: NSView, NSTextFieldDelegate {
    let field = NSTextField()
    /// Called once, when editing ends: the typed name (nil when cancelled), and whether a key
    /// ended it (Return, Tab, Escape) rather than a click somewhere else, which takes the focus.
    var onEnd: ((_ name: String?, _ byKey: Bool) -> Void)?
    private var ended = false

    init(name: String) {
        super.init(frame: .zero)
        field.stringValue = name
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Theme.font
        field.textColor = AquaStyle.text
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        addSubview(field)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// `bezel` is the field's outline, in the superview's coordinates; the glow draws outside it.
    func place(_ bezel: NSRect) {
        let m = AquaTextField.ringMargin
        frame = bezel.insetBy(dx: -m, dy: -m)
        field.frame = NSRect(x: m + 3, y: m + 2, width: max(bezel.width - 6, 0), height: 14)
    }

    override func draw(_ dirtyRect: NSRect) {
        let bezel = bounds.insetBy(dx: AquaTextField.ringMargin, dy: AquaTextField.ringMargin)
        AquaStyle.drawFieldBezel(in: bezel, flipped: true)
        AquaStyle.drawFocusRing(around: bezel)
    }

    /// Escape would otherwise ask the field editor for completions.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        finish(nil, byKey: true)
        return true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        let movement = (obj.userInfo?["NSTextMovement"] as? Int).flatMap(NSTextMovement.init(rawValue:))
        finish(field.stringValue, byKey: movement != nil && movement != .other)
    }

    private func finish(_ name: String?, byKey: Bool) {
        guard !ended else { return }
        ended = true
        onEnd?(name, byKey)
    }
}
