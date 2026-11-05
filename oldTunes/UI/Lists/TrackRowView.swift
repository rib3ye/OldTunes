import AppKit

/// A 17 pt track-list (and column-browser) row: white/#ECF3FE stripes and the FLAT blue
/// selection with its 1 px lighter bottom edge (RESEARCH.md §7.4, §8.2).
///
/// The stripe comes from the DISPLAY row, never the model id, or the stripes scramble the moment
/// the list is sorted or filtered. `usesAlternatingRowBackgroundColors` stays off: it paints the
/// system's colors, not these.
final class TrackRowView: NSTableRowView {
    /// Set by the table delegate in rowViewForRow and didAdd (row views are reused).
    var displayRow = 0 { didSet { if displayRow % 2 != oldValue % 2 { needsDisplay = true } } }
    /// iTunes 4.9 ran faint vertical lines down the list under each header separator; the
    /// single-column browser panes have none.
    var drawsColumnLines = true

    override var isOpaque: Bool { true }

    override func drawBackground(in dirtyRect: NSRect) {
        (displayRow % 2 == 0 ? Theme.listBG : Theme.rowStripe).setFill()
        dirtyRect.intersection(bounds).fill()
        drawColumnLines(ListsPalette.rowColumnLine, in: dirtyRect)
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let fill = isEmphasized ? Theme.trkSel : Theme.trkSelOff
        fill.setFill()
        bounds.fill()
        drawColumnLines(ListsPalette.rowColumnLine(onSelection: fill), in: dirtyRect)
        (isEmphasized ? Theme.trkSelEdge : Theme.trkSelOffEdge).setFill()
        NSRect(x: bounds.minX, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    /// White text on any selection, focused or not.
    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        isSelected ? .emphasized : .normal
    }

    override func drawSeparator(in dirtyRect: NSRect) {}

    private func drawColumnLines(_ color: NSColor, in dirtyRect: NSRect) {
        guard drawsColumnLines, let table = superview as? NSTableView else { return }
        color.setFill()
        for (index, column) in table.tableColumns.enumerated() where !column.isHidden {
            let x = table.rect(ofColumn: index).maxX - 1
            guard x >= dirtyRect.minX - 1, x <= dirtyRect.maxX else { continue }
            NSRect(x: x, y: bounds.minY, width: 1, height: bounds.height).fill()
        }
    }
}
