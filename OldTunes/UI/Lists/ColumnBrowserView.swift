import AppKit

/// The Genre | Artist | Album browser above the track list (RESEARCH.md §7.4): three equal panes,
/// each with a centred pane header, its own Aqua scroller, 17 pt striped rows, and a bold
/// "All (N Genres)" first row. Layout from the Windows build's browser, colors from the Mac list.
///
/// This view only displays values and reports picks; TrackListViewController owns the query and
/// decides which panes to refetch.
final class ColumnBrowserView: NSView {
    let panes: [BrowserPane]
    /// A pane's selection changed by the user. Nil value means "All".
    var onSelect: ((BrowserField, String?) -> Void)? {
        didSet { for pane in panes { pane.onSelect = onSelect } }
    }

    init() {
        panes = BrowserField.allCases.map(BrowserPane.init(field:))
        super.init(frame: .zero)
        panes.forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    func pane(_ field: BrowserField) -> BrowserPane? { panes.first { $0.field == field } }

    /// Equal thirds with a 1 pt rule between panes; the last pane takes the rounding slack.
    override func layout() {
        super.layout()
        let count = CGFloat(panes.count)
        let width = max(((bounds.width - (count - 1)) / count).rounded(.down), 0)
        var x: CGFloat = 0
        for (i, pane) in panes.enumerated() {
            let w = i == panes.count - 1 ? max(bounds.width - x, 0) : width
            pane.frame = NSRect(x: x, y: 0, width: w, height: bounds.height)
            x += w + 1
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.paneBorderTrkL.setFill()
        dirtyRect.intersection(bounds).fill()
    }
}

/// One browser column.
final class BrowserPane: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let field: BrowserField
    let header: PaneHeaderView
    let table = RetroTableView(rowHeight: Theme.Metrics.trackRowHeight)
    let scrollView = RetroScrollView(lineHeight: Theme.Metrics.trackRowHeight)
    var onSelect: ((BrowserField, String?) -> Void)?

    private(set) var values: [String] = []
    /// Nil = "All".
    private(set) var selectedValue: String?
    /// Set while values are swapped in, so programmatic selection is not reported as a pick.
    private var isApplying = false

    init(field: BrowserField) {
        self.field = field
        header = PaneHeaderView(title: Self.title(for: field))
        super.init(frame: .zero)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        // One column filling the pane, so the value text sits a fixed 4 pt from the pane's edge.
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsEmptySelection = false
        table.allowsMultipleSelection = false
        // Same striped rows as the track list, down to the bottom of a short pane.
        table.stripesBeyondLastRow = true
        table.dataSource = self
        table.delegate = self
        scrollView.documentView = table
        addSubview(header)
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: PaneHeaderView.height)
        scrollView.frame = NSRect(x: 0, y: PaneHeaderView.height, width: bounds.width,
                                  height: max(bounds.height - PaneHeaderView.height, 0))
    }

    static func title(for field: BrowserField) -> String {
        switch field {
        case .genre: "Genre"
        case .artist: "Artist"
        case .album: "Album"
        }
    }

    /// "All (132 Genres)", singular for one.
    var allRowTitle: String {
        let noun: String
        switch field {
        case .genre: noun = values.count == 1 ? "Genre" : "Genres"
        case .artist: noun = values.count == 1 ? "Artist" : "Artists"
        case .album: noun = values.count == 1 ? "Album" : "Albums"
        }
        return "All (\(values.count.formatted()) \(noun))"
    }

    /// Swaps in a fresh value list and selects `value` (or All when it is nil or gone).
    /// Returns the value actually selected.
    @discardableResult
    func setValues(_ newValues: [String], selecting value: String?) -> String? {
        isApplying = true
        defer { isApplying = false }
        values = newValues
        table.reloadData()
        let index = value.flatMap { newValues.firstIndex(of: $0) }
        selectedValue = index == nil ? nil : value
        let row = index.map { $0 + 1 } ?? 0
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        return selectedValue
    }

    // MARK: Data source and delegate

    func numberOfRows(in tableView: NSTableView) -> Int { values.count + 1 }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = tableView.makeView(withIdentifier: Self.rowID, owner: self) as? TrackRowView ?? TrackRowView()
        view.identifier = Self.rowID
        view.drawsColumnLines = false
        view.displayRow = row
        return view
    }

    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        (rowView as? TrackRowView)?.displayRow = row
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: Self.cellID, owner: self) as? BrowserCellView ?? BrowserCellView()
        cell.identifier = Self.cellID
        if row == 0 {
            cell.configure(text: allRowTitle, bold: true)
        } else if row - 1 < values.count {
            cell.configure(text: values[row - 1], bold: false)
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplying else { return }
        let row = table.selectedRow
        let value: String? = row > 0 && row - 1 < values.count ? values[row - 1] : nil
        guard value != selectedValue else { return }
        selectedValue = value
        onSelect?(field, value)
    }

    private static let rowID = NSUserInterfaceItemIdentifier("browserRow")
    private static let cellID = NSUserInterfaceItemIdentifier("browserCell")
}

/// A browser row's text; the All row is bold.
final class BrowserCellView: NSTableCellView {
    private var text = ""
    private var bold = false

    override var isFlipped: Bool { true }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if backgroundStyle != oldValue { needsDisplay = true } }
    }

    func configure(text: String, bold: Bool) {
        guard text != self.text || bold != self.bold else { return }
        self.text = text
        self.bold = bold
        needsDisplay = true
    }

    var displayedText: String { text }

    override func draw(_ dirtyRect: NSRect) {
        let color = backgroundStyle == .emphasized ? Theme.textOnSelection : Theme.textPrimary
        let attrs = Theme.textAttributes(bold ? Theme.boldFont : Theme.font, color: color)
        (text as NSString).draw(in: NSRect(x: 4, y: 2, width: bounds.width - 6, height: 13), withAttributes: attrs)
    }
}

/// The ~11 pt bar between the browser and the track list, with a small centred grab handle.
/// It paints no background, so the window's brushed metal shows through as it did in iTunes.
///
/// It also draws the two pane edges facing it, the only ones the chrome frame around the track
/// pane cannot: the browser's bottom rule along its top edge and the list's top rule along its
/// bottom edge, each one device pixel of `Theme.rule`, with the frame's light lip below the first
/// and its faint recess shadow above the second, so they match ChromePaneFrameView's edges.
final class BrowserSplitterView: NSView {
    /// Called with the vertical drag distance since the last event (flipped: positive = down).
    var onDrag: ((CGFloat) -> Void)?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let hl = Theme.hairline(for: self)
        Theme.rule.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: hl).fill()
        NSRect(x: 0, y: bounds.maxY - hl, width: bounds.width, height: hl).fill()
        Theme.footHighlight.setFill()
        NSRect(x: 0, y: hl, width: bounds.width, height: hl).fill()
        ListsPalette.recessShadow.setFill()
        NSRect(x: 0, y: bounds.maxY - 2 * hl, width: bounds.width, height: hl).fill(using: .sourceOver)

        // A recessed dimple: dark upper-left, light lower-right, like the 10.4 split-view knob.
        let d: CGFloat = 6
        let r = NSRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
        let dimple = NSBezierPath(ovalIn: r)
        NSGradient(starting: ListsPalette.splitterDimpleTop, ending: ListsPalette.splitterDimpleBottom)?
            .draw(in: dimple, angle: 45)
        ListsPalette.splitterDimpleRim.setStroke()
        dimple.lineWidth = 0.5
        dimple.stroke()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    /// Tracks in window coordinates: this view moves while it is dragged, so its own
    /// coordinates would shift under the pointer. Window y grows upward, hence the negation.
    override func mouseDown(with event: NSEvent) {
        var last = event.locationInWindow.y
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let y = next.locationInWindow.y
            if y != last { onDrag?(last - y) }
            last = y
            if next.type == .leftMouseUp { break }
        }
    }
}
