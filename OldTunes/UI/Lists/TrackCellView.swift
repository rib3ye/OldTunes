import AppKit

/// One track-list cell, drawn directly rather than through an NSTextField: a screenful is about
/// 200 cells and each redraw is one string draw, which keeps scrolling flat on 15,900 rows.
final class TrackCellView: NSTableCellView {

    enum Indicator: Equatable { case none, playing, paused }

    private(set) var column: TrackColumn = .name
    private var text = ""
    private var dimmed = false
    private var cloudBadge = false
    private var indicator: Indicator = .none
    /// Name cells only: whether the row has data (so a box is drawn) and the song's checkbox.
    private var hasCheckbox = false
    private var checked = true

    /// The cloud badge's slot at the right edge of the Name cell.
    static let badgeWidth: CGFloat = 17

    /// The per-song checkbox at the left of the Name cell: 12 × 12, like Get Info's small Aqua
    /// checkbox (RESEARCH.md §7.4), vertically centred in the 17 pt row.
    static func checkboxRect(cellHeight: CGFloat) -> NSRect {
        NSRect(x: 2.5, y: ((cellHeight - 12) / 2).rounded(.down), width: 12, height: 12)
    }
    /// Where a click toggles the box: everything left of the title, the full row height.
    static func checkboxHitRect(cellHeight: CGFloat) -> NSRect {
        NSRect(x: 0, y: 0, width: nameTextLeft - 1, height: cellHeight)
    }
    /// The Name text starts after the box, 20 pt into the column as in the reference.
    static let nameTextLeft: CGFloat = 18.5

    init(column: TrackColumn) {
        self.column = column
        super.init(frame: NSRect(x: 0, y: 0, width: column.defaultWidth, height: Theme.Metrics.trackRowHeight))
        identifier = column.identifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// The row view pushes `.emphasized` here when the row is selected; the text turns white.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if backgroundStyle != oldValue { needsDisplay = true } }
    }

    /// Nil `track` means the row's data is still being fetched: draw nothing until it lands.
    func configure(track: Track?, indicator: Indicator) {
        let newText: String
        var newDimmed = false, newBadge = false, newHasBox = false, newChecked = true
        if let track {
            newText = Self.text(for: column, of: track)
            newDimmed = track.bucket == .missing
            newBadge = column == .name && track.isCloudOnly
            newHasBox = column == .name
            newChecked = track.isChecked
        } else {
            newText = ""
        }
        guard newText != text || newDimmed != dimmed || newBadge != cloudBadge || indicator != self.indicator
              || newHasBox != hasCheckbox || newChecked != checked else { return }
        text = newText
        dimmed = newDimmed
        cloudBadge = newBadge
        hasCheckbox = newHasBox
        checked = newChecked
        self.indicator = indicator
        needsDisplay = true
    }

    /// The configured text, for tests.
    var displayedText: String { text }
    var showsCloudBadge: Bool { cloudBadge }
    var isDimmed: Bool { dimmed }
    var indicatorState: Indicator { indicator }
    /// Nil when this cell draws no checkbox (not Name, or the row is still loading).
    var checkboxState: Bool? { hasCheckbox ? checked : nil }

    static func text(for column: TrackColumn, of track: Track) -> String {
        switch column {
        case .indicator: ""
        case .name: track.displayTitle
        case .time: ListsPalette.time(track.duration)
        case .artist: track.artist
        case .album: track.album
        case .genre: track.genre
        case .dateAdded: track.dateAdded.map { ListsPalette.shortDate.string(from: $0) } ?? ""
        case .year: track.year > 0 ? String(track.year) : ""
        case .plays: track.playCount > 0 ? String(track.playCount) : ""
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let onSelection = backgroundStyle == .emphasized
        if column == .indicator {
            guard indicator != .none else { return }
            let color = onSelection ? Theme.textOnSelection : Theme.textPrimary
            let box = NSRect(x: (bounds.width - 12) / 2, y: (bounds.height - 10) / 2, width: 12, height: 10)
            ListGlyphs.speaker(in: box, filled: indicator == .playing, color: color)
            return
        }
        // Unchecked songs are not dimmed: iTunes drew them like any other row.
        let color = onSelection ? Theme.textOnSelection : (dimmed ? Theme.textDimmed : Theme.textPrimary)
        var textRect = NSRect(x: 2, y: 2, width: bounds.width - 4, height: 13)
        if column == .name {
            textRect.origin.x = Self.nameTextLeft
            textRect.size.width = bounds.width - Self.nameTextLeft - 2
            if hasCheckbox { Self.drawCheckbox(in: Self.checkboxRect(cellHeight: bounds.height), checked: checked) }
        }
        if cloudBadge {
            textRect.size.width -= Self.badgeWidth
            let badge = NSRect(x: bounds.width - Self.badgeWidth + 1, y: 4, width: 13, height: 9)
            ListGlyphs.cloud(in: badge, color: onSelection ? Theme.textOnSelection : ListsPalette.cloudBadge)
        }
        guard !text.isEmpty, textRect.width > 0 else { return }
        (text as NSString).draw(in: textRect, withAttributes: Self.attributes(color: color, alignment: column.alignment))
    }

    /// Get Info's small checkbox (AquaCheckbox, size .small): the Aqua gel, blue when checked and
    /// white when not, with the black tick that overshoots the top-right corner. Same on a selected
    /// row, as in the reference.
    static func drawCheckbox(in box: NSRect, checked: Bool) {
        AquaStyle.drawGel(in: box, radius: 2.5, gel: checked ? AquaStyle.blueGel : AquaStyle.whiteGel,
                          flipped: true, shadow: true)
        guard checked else { return }
        let s = box.width
        let tick = NSBezierPath()
        tick.move(to: NSPoint(x: box.minX + s * 0.22, y: box.minY + s * 0.52))
        tick.line(to: NSPoint(x: box.minX + s * 0.43, y: box.minY + s * 0.78))
        tick.line(to: NSPoint(x: box.minX + s * 0.92, y: box.minY - s * 0.06))
        tick.lineWidth = 1.8
        tick.lineCapStyle = .round
        tick.lineJoinStyle = .round
        NSColor(white: 0.08, alpha: 1).setStroke()
        tick.stroke()
    }

    /// Attribute dictionaries are rebuilt per draw otherwise; there are only six combinations.
    private static var attributeCache: [String: [NSAttributedString.Key: Any]] = [:]

    private static func attributes(color: NSColor, alignment: NSTextAlignment) -> [NSAttributedString.Key: Any] {
        let key = "\(color.hashValue)-\(alignment.rawValue)"
        if let cached = attributeCache[key] { return cached }
        let attrs = Theme.textAttributes(color: color, alignment: alignment)
        attributeCache[key] = attrs
        return attrs
    }
}
