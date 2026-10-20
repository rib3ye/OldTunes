import AppKit

/// Geometry shared by the Get Info panes, in flipped window points. The window is a little
/// wider than iTunes 4.9's (456 vs ~430 pt) to fit the Album Artist row it did not have.
enum GetInfoLayout {
    static let windowWidth: CGFloat = 456
    static let tabStripTop: CGFloat = 34
    /// The content box's top edge runs through the middle of the tab strip.
    static let boxTop: CGFloat = 45
    static let boxInsetX: CGFloat = 18
    static let contentTop: CGFloat = 70
    static let contentLeft: CGFloat = 34
    static let contentRight: CGFloat = windowWidth - 34
    static let labelHeight: CGFloat = 14
    static let fieldHeight: CGFloat = AquaTextField.bezelHeight
    /// Label top to the next label top.
    static let rowPitch: CGFloat = 42
    static let numberWidth: CGFloat = 34
    static let bottomMargin: CGFloat = 16
    static let buttonGap: CGFloat = 10
}

@MainActor
enum FormKit {
    static func label(_ text: String, font: NSFont = AquaStyle.smallFont, color: NSColor = AquaStyle.text,
                      alignment: NSTextAlignment = .left) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = font
        l.textColor = color
        l.alignment = alignment
        l.lineBreakMode = .byTruncatingTail
        l.drawsBackground = false
        return l
    }

    /// Adds "Label" with its field beneath, the 10.4 Get Info arrangement.
    @discardableResult
    static func addLabeledField(_ title: String, to view: NSView, x: CGFloat, y: CGFloat, width: CGFloat,
                                alignment: NSTextAlignment = .left, digits: Int? = nil) -> AquaTextField {
        let l = label(title)
        l.frame = NSRect(x: x, y: y, width: max(width, 120), height: GetInfoLayout.labelHeight)
        view.addSubview(l)
        let field = AquaTextField(alignment: alignment)
        field.digitLimit = digits
        field.setBezelFrame(NSRect(x: x, y: y + GetInfoLayout.labelHeight + 2, width: width, height: GetInfoLayout.fieldHeight))
        view.addSubview(field)
        return field
    }
}
