import AppKit

/// An 18 pt source-list row: white, with the VERTICAL gradient selection (#69A7EE → #2972D8,
/// 1 px edges) when focused and the gray variant when not (RESEARCH.md §7.1, §7.4). The track
/// list's selection is flat; this one is not — the contrast is part of the look.
final class SourceRowView: NSTableRowView {
    override var isOpaque: Bool { true }

    override func drawBackground(in dirtyRect: NSRect) {
        Theme.listBG.setFill()
        dirtyRect.intersection(bounds).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let gradient = isEmphasized ? Theme.sourceSelection : Theme.sourceSelectionOff
        gradient.draw(in: bounds, angle: isFlipped ? 90 : -90)
        // The 1 px edges. Unfocused, the reference shows a darker top line and a bottom that
        // simply ends on the gradient's last value.
        let top = isEmphasized ? Theme.srcSelEdgeTop : ListsPalette.sourceSelectionOffEdgeTop
        let bottom = isEmphasized ? Theme.srcSelEdgeBottom : Theme.srcSelOffBottom
        top.setFill()
        NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: 1).fill()
        bottom.setFill()
        NSRect(x: bounds.minX, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        isSelected ? .emphasized : .normal
    }

    override func drawSeparator(in dirtyRect: NSRect) {}
}

/// One source-list entry: disclosure triangle (folders), 16 × 16 icon at x 14, text at x 33,
/// each shifted right by the folder depth.
final class SourceCellView: NSTableCellView {
    /// Per nesting level, the width of one icon column less a little, as Finder lists did.
    static let indentPerLevel: CGFloat = 14

    private(set) var title = ""
    private var icon: SourceIcon = .playlist
    private var depth = 0
    private var disclosure: Bool?

    override var isFlipped: Bool { true }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if backgroundStyle != oldValue { needsDisplay = true } }
    }

    /// `disclosure` is nil for leaves, otherwise whether the folder is expanded.
    func configure(title: String, icon: SourceIcon, depth: Int, disclosure: Bool?) {
        self.title = title
        self.icon = icon
        self.depth = depth
        self.disclosure = disclosure
        needsDisplay = true
    }

    static func disclosureRect(depth: Int) -> NSRect {
        NSRect(x: 3 + CGFloat(depth) * indentPerLevel, y: 4.5, width: 9, height: 9)
    }

    override func draw(_ dirtyRect: NSRect) {
        let selected = backgroundStyle == .emphasized
        let indent = CGFloat(depth) * Self.indentPerLevel
        if let expanded = disclosure {
            ListGlyphs.disclosure(in: Self.disclosureRect(depth: depth), expanded: expanded,
                                  color: selected ? Theme.textOnSelection : ListsPalette.disclosure)
        }
        icon.draw(in: NSRect(x: Theme.Metrics.sourceIconLeft + indent, y: 1,
                             width: Theme.Metrics.sourceIconSize, height: Theme.Metrics.sourceIconSize))
        let x = Theme.Metrics.sourceTextLeft + indent
        let attrs = Theme.textAttributes(color: selected ? Theme.textOnSelection : Theme.textPrimary)
        (title as NSString).draw(in: NSRect(x: x, y: 2.5, width: max(bounds.width - x - 3, 0), height: 13),
                                 withAttributes: attrs)
    }
}
