import AppKit

/// NSTableView with the 2005 configuration applied once (RESEARCH.md §8.4), plus the keyboard
/// and right-click behaviour iTunes had.
final class RetroTableView: NSTableView {
    /// Return or Enter on the selection.
    var onReturn: (() -> Void)?
    /// Delete or Forward Delete on the selection.
    var onDelete: (() -> Void)?
    /// ⌘I while this table is focused.
    var onCommandI: (() -> Void)?
    /// ← or → (`right`), alone or with ⌥ (`option`). Return true when used; otherwise the key goes
    /// on up the responder chain, where the window plays the previous or next song (ArrowCommand).
    var onLeftRight: ((_ right: Bool, _ option: Bool) -> Bool)?
    /// Clicks that should not reach NSTableView (the source list's disclosure triangles).
    /// Return true when handled.
    var interceptMouseDown: ((NSEvent) -> Bool)?
    /// Fires when focus enters or leaves, so the selection can switch between blue and gray.
    var onFocusChange: ((Bool) -> Void)?

    init(rowHeight: CGFloat) {
        super.init(frame: .zero)
        // .automatic infers the modern inset look from the hierarchy. .plain is the 2005 list: rows
        // edge to edge, square selection, and columns at exactly their widths. .fullWidth also
        // looks right at a glance but pads the first column by 5–6 pt and the last by 4–6 pt, which
        // pushed every column and source icon off the reference (review finding 18).
        style = .plain
        selectionHighlightStyle = .regular
        usesAlternatingRowBackgroundColors = false
        gridStyleMask = []
        self.rowHeight = rowHeight
        usesAutomaticRowHeights = false
        intercellSpacing = Theme.Metrics.intercellSpacing
        backgroundColor = Theme.listBG
        focusRingType = .none
        allowsTypeSelect = false
        if #available(macOS 26.0, *) { prefersCompactControlSizeMetrics = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Mac OS X list stripes ran on below the last row to the bottom of the pane, with the
    /// column lines; a short list should not end in a white void.
    var stripesBeyondLastRow = false
    var columnLinesBeyondLastRow = false

    override func drawBackground(inClipRect clipRect: NSRect) {
        Theme.listBG.setFill()
        clipRect.intersection(bounds).fill()
        let pitch = rowHeight + intercellSpacing.height
        let firstEmptyY = CGFloat(numberOfRows) * pitch
        guard clipRect.maxY > firstEmptyY, pitch > 0 else { return }
        if stripesBeyondLastRow {
            Theme.rowStripe.setFill()
            var row = max(numberOfRows, Int((clipRect.minY / pitch).rounded(.down)))
            while CGFloat(row) * pitch < clipRect.maxY {
                if row % 2 == 1 {
                    NSRect(x: clipRect.minX, y: CGFloat(row) * pitch, width: clipRect.width, height: pitch).fill()
                }
                row += 1
            }
        }
        if columnLinesBeyondLastRow {
            ListsPalette.rowColumnLine.setFill()
            let top = max(firstEmptyY, clipRect.minY)
            for (index, column) in tableColumns.enumerated() where !column.isHidden {
                let x = rect(ofColumn: index).maxX - 1
                NSRect(x: x, y: top, width: 1, height: clipRect.maxY - top).fill()
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:   // Return, keypad Enter
            onReturn?()
        case 51, 117:   // Delete, Forward Delete
            if let onDelete { onDelete() } else { super.keyDown(with: event) }
        case 123, 124:   // ←, →
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if modifiers.isSubset(of: .option), onLeftRight?(event.keyCode == 124, modifiers == .option) == true { return }
            super.keyDown(with: event)
        default:
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command, event.charactersIgnoringModifiers == "i",
           window?.firstResponder === self, let onCommandI {
            onCommandI()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if let interceptMouseDown, interceptMouseDown(event) { return }
        super.mouseDown(with: event)
    }

    /// The row the last right-click landed on, or -1 for the empty space below the rows.
    private(set) var menuRow = -1

    /// Right-clicking a row outside the selection selects it first, as iTunes did, so the menu
    /// acts on what the user is pointing at.
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        menuRow = row
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        // Not super: NSTableView's version also makes the row the menu's target and adds an
        // NSMenuHighlightView that outlines it in the macOS 11 style while the menu is open.
        // The menu's actions read the selection, never clickedRow.
        return menu
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocusChange?(false) }
        return ok
    }
}
