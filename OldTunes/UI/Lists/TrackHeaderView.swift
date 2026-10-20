import AppKit

/// One column header: the bright-dipped-bright gradient (blue on the sorted column), a 1 px
/// #C0C0C0 separator at the right edge, Lucida Grande 11, and the sort triangle (§7.4, §8.2).
final class TrackHeaderCell: NSTableHeaderCell {
    /// Nil when this column is not the sort column.
    var sortAscending: Bool?

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let gradient = sortAscending == nil ? Theme.columnHeader : Theme.columnHeaderSorted
        gradient.draw(in: cellFrame, angle: controlView.isFlipped ? 90 : -90)
        Theme.colSep.setFill()
        NSRect(x: cellFrame.maxX - 1, y: cellFrame.minY, width: 1, height: cellFrame.height).fill()
        drawInterior(withFrame: cellFrame, in: controlView)
        if let ascending = sortAscending {
            drawSortIndicator(withFrame: cellFrame, in: controlView, ascending: ascending, priority: 0)
        }
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        guard !stringValue.isEmpty else { return }
        let triangleRoom: CGFloat = sortAscending == nil ? 0 : 14
        let textRect = NSRect(x: cellFrame.minX + 5, y: cellFrame.minY + 1,
                              width: max(cellFrame.width - 10 - triangleRoom, 0), height: 13)
        (stringValue as NSString).draw(in: textRect,
                                       withAttributes: Theme.textAttributes(alignment: alignment))
    }

    /// The header file says to override this to customise the sorting UI.
    override func drawSortIndicator(withFrame cellFrame: NSRect, in controlView: NSView,
                                    ascending: Bool, priority: Int) {
        guard priority == 0 else { return }
        let center = NSPoint(x: cellFrame.maxX - 10.5, y: cellFrame.minY + 7.5)
        ListGlyphs.sortTriangle(centeredAt: center, ascending: ascending, color: ListsPalette.sortTriangle)
    }

    override func sortIndicatorRect(forBounds rect: NSRect) -> NSRect {
        NSRect(x: rect.maxX - 15, y: rect.minY, width: 12, height: rect.height)
    }
}

/// Draws the whole header itself: every column through its TrackHeaderCell, the gradient past
/// the last column, and the 1 px rule under it. Stock NSTableHeaderView would paint the
/// macOS 27 look between and around the cells.
final class TrackHeaderView: NSTableHeaderView {
    /// 15 pt of gradient plus the rule below it (the rule above is the pane border).
    static let height: CGFloat = Theme.Metrics.columnHeaderHeight + 1

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let band = NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: Theme.Metrics.columnHeaderHeight)
        Theme.columnHeader.draw(in: band, angle: isFlipped ? 90 : -90)
        if let table = tableView {
            for (index, column) in table.tableColumns.enumerated() where !column.isHidden {
                var rect = headerRect(ofColumn: index)
                rect.size.height = Theme.Metrics.columnHeaderHeight
                guard rect.intersects(dirtyRect) else { continue }
                column.headerCell.draw(withFrame: rect, in: self)
            }
        }
        ListsPalette.headerRule.setFill()
        NSRect(x: bounds.minX, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }
}

/// The square above the vertical scroller, continuing the header.
final class HeaderCornerView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let band = NSRect(x: 0, y: 0, width: bounds.width, height: Theme.Metrics.columnHeaderHeight)
        Theme.columnHeader.draw(in: band, angle: 90)
        ListsPalette.headerRule.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }
}
