import AppKit

/// A small 10.4 pop-up button: white gel body with the chosen item, and a blue gel cap at the
/// right holding the up/down arrows. Multiple Song Information used one for "Part of a
/// Compilation", because a plain checkbox there would sit beside its own "apply" checkbox and
/// the pair would be impossible to tell apart. The menu itself is the system's; only the
/// closed control is drawn here, as stock NSPopUpButton draws Liquid Glass.
@MainActor
final class AquaPopUpButton: NSControl {
    var items: [String] { didSet { needsDisplay = true } }
    var selectedIndex: Int { didSet { if selectedIndex != oldValue { needsDisplay = true } } }
    /// Called when the user picks an item (not when `selectedIndex` is set in code).
    var onSelect: ((Int) -> Void)?

    static let height: CGFloat = 19
    private static let capWidth: CGFloat = 17

    init(items: [String], selectedIndex: Int = 0) {
        self.items = items
        self.selectedIndex = selectedIndex
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width(for: items), height: Self.height))
        setAccessibilityRole(.popUpButton)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var isEnabled: Bool { didSet { needsDisplay = true } }
    /// Tiger's default keyboard access ("text boxes and lists only") skipped buttons and
    /// checkboxes, and nothing here draws a focus ring, so Tab would otherwise vanish into it.
    override var acceptsFirstResponder: Bool { false }

    static func width(for items: [String]) -> CGFloat {
        let widest = items.map { ($0 as NSString).size(withAttributes: [.font: AquaStyle.smallFont]).width }.max() ?? 0
        return ceil(widest) + 10 + capWidth + 12
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = NSRect(x: 0.5, y: 0, width: bounds.width - 1, height: Self.height - 1)
        let radius: CGFloat = 4
        AquaStyle.drawGel(in: rect, radius: radius, gel: isEnabled ? AquaStyle.whiteGel : AquaStyle.disabledGel, flipped: true)

        let cap = NSRect(x: rect.maxX - Self.capWidth, y: rect.minY, width: Self.capWidth, height: rect.height)
        if isEnabled {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: cap).addClip()
            AquaStyle.drawGel(in: rect, radius: radius, gel: AquaStyle.blueGel, flipped: true, shadow: false)
            NSGraphicsContext.restoreGraphicsState()
        }
        AquaStyle.whiteGel.rimBottom.withAlphaComponent(0.8).setFill()
        NSRect(x: cap.minX - 0.5, y: rect.minY + 1, width: 1, height: rect.height - 2).fill()

        // Up and down arrows, stacked, in the cap.
        let glyph = isEnabled ? NSColor(white: 0.08, alpha: 0.85) : AquaStyle.textDisabled
        glyph.setFill()
        let cx = cap.midX, cy = cap.midY
        let up = NSBezierPath()
        up.move(to: NSPoint(x: cx - 3, y: cy - 1.5)); up.line(to: NSPoint(x: cx + 3, y: cy - 1.5))
        up.line(to: NSPoint(x: cx, y: cy - 5.5)); up.close(); up.fill()
        let down = NSBezierPath()
        down.move(to: NSPoint(x: cx - 3, y: cy + 1.5)); down.line(to: NSPoint(x: cx + 3, y: cy + 1.5))
        down.line(to: NSPoint(x: cx, y: cy + 5.5)); down.close(); down.fill()

        guard items.indices.contains(selectedIndex) else { return }
        let color = isEnabled ? AquaStyle.text : AquaStyle.textDisabled
        let attrs = AquaStyle.attributes(AquaStyle.smallFont, color: color)
        (items[selectedIndex] as NSString).draw(in: NSRect(x: 8, y: 2, width: cap.minX - 10, height: 14), withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, title) in items.enumerated() {
            let item = NSMenuItem(title: title, action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = index == selectedIndex ? .on : .off
            menu.addItem(item)
        }
        menu.font = AquaStyle.smallFont
        menu.popUp(positioning: menu.item(at: selectedIndex), at: NSPoint(x: 0, y: 0), in: self)
    }

    @objc private func pick(_ sender: NSMenuItem) { choose(sender.tag) }

    /// Selects an item as if the user picked it from the menu.
    func choose(_ index: Int) {
        guard isEnabled, items.indices.contains(index) else { return }
        selectedIndex = index
        onSelect?(index)
    }

    override func accessibilityValue() -> Any? { items.indices.contains(selectedIndex) ? items[selectedIndex] : nil }
}
