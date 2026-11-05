import AppKit

// Pane frames: the chrome module's ChromePaneFrameView draws the one-device-pixel frame around the
// source pane and around the whole track pane (RESEARCH.md §7.2), so these views draw no outer
// border of their own; a second one beside it made every edge three device pixels thick (review
// finding 19). The only edges the chrome cannot draw are the two facing the browser splitter,
// inside the track pane, and BrowserSplitterView draws those in the chrome frame's weight.

/// "Source" / "Genre" / "Artist" / "Album": Lucida Grande 11 regular (Theme.paneHeaderFont),
/// centred on the #E9E9E9 → #8C8C8C gradient, 15 pt plus a 1 pt rule underneath.
final class PaneHeaderView: NSView {
    static let height: CGFloat = Theme.Metrics.columnHeaderHeight + 1

    var title: String { didSet { needsDisplay = true } }

    init(title: String) {
        self.title = title
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: Self.height))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let band = NSRect(x: 0, y: 0, width: bounds.width, height: Theme.Metrics.columnHeaderHeight)
        Theme.paneHeader.draw(in: band, angle: 90)
        ListsPalette.headerRule.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
        let attrs = Theme.textAttributes(Theme.paneHeaderFont, color: ListsPalette.paneHeaderText, alignment: .center)
        (title as NSString).draw(in: NSRect(x: 2, y: 1, width: bounds.width - 4, height: 13), withAttributes: attrs)
    }
}
