import AppKit

/// A scroll view with square corners and Aqua scrollers.
///
/// macOS 27 rounds an in-window NSScrollView's corners (16 pt) with no API call from us; a nil
/// `cornerConfiguration` is the only thing that stops it (RESEARCH.md §8.1).
final class RetroScrollView: NSScrollView {

    @available(macOS 27.0, *)
    override var cornerConfiguration: NSViewCornerConfiguration? { nil }

    init(lineHeight: CGFloat, horizontal: Bool = false, autohides: Bool = false) {
        super.init(frame: .zero)
        // hasVerticalScroller is what turns the scroller on; assigning one alone leaves it hidden.
        hasVerticalScroller = true
        verticalScroller = AquaScroller(frame: NSRect(x: 0, y: 0, width: Theme.Metrics.scrollerWidth, height: 100))
        hasHorizontalScroller = horizontal
        if horizontal {
            horizontalScroller = AquaScroller(frame: NSRect(x: 0, y: 0, width: 100, height: Theme.Metrics.scrollerWidth))
        }
        autohidesScrollers = autohides
        scrollerStyle = .legacy
        borderType = .noBorder
        drawsBackground = true
        backgroundColor = Theme.listBG
        automaticallyAdjustsContentInsets = false
        contentInsets = NSEdgeInsetsZero
        verticalLineScroll = lineHeight
        horizontalLineScroll = lineHeight
        // Elastic bounce is a 2011 behaviour; a 2005 list stops dead at its ends.
        verticalScrollElasticity = .none
        horizontalScrollElasticity = .none
        // macOS 27's content-background view is a scroller-width larger than the scroll view;
        // unclipped (the default since macOS 14) it paints white past the pane's edges.
        clipsToBounds = true
    }

    /// The document area actually on screen. macOS 27 lays the header and both scrollers over
    /// the clip view and records them as its contentInsets (16 top, 15 right, 15 bottom), so
    /// the clip's bounds and the table's visibleRect include rows hidden under them.
    var unobscuredDocumentRect: NSRect {
        let clip = contentView
        let insets = clip.contentInsets
        var rect = clip.bounds
        rect.origin.x += insets.left
        rect.origin.y += insets.top
        rect.size.width = max(rect.width - insets.left - insets.right, 0)
        rect.size.height = max(rect.height - insets.top - insets.bottom, 0)
        return rect
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Clipped to bounds: during cacheDisplay the dirty rect is not, and an unclipped fill
    /// painted white over every sibling drawn before this view.
    override func draw(_ dirtyRect: NSRect) {
        Theme.listBG.setFill()
        dirtyRect.intersection(bounds).fill()
    }

    /// The white square where the two scrollers meet. The clip view runs under both scrollers
    /// on macOS 27, so without it the rows show through that corner.
    private let corner = ScrollCornerView()

    override func tile() {
        super.tile()
        guard hasVerticalScroller, hasHorizontalScroller,
              let v = verticalScroller, let h = horizontalScroller, !v.isHidden, !h.isHidden else {
            corner.isHidden = true
            return
        }
        if corner.superview !== self { addSubview(corner, positioned: .above, relativeTo: nil) }
        corner.frame = NSRect(x: v.frame.minX, y: h.frame.minY, width: v.frame.width, height: h.frame.height)
        corner.isHidden = false
    }
}

private final class ScrollCornerView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        Theme.listBG.setFill()
        dirtyRect.intersection(bounds).fill()
    }
}
