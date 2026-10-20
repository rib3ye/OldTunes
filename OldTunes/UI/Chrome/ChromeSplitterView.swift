import AppKit

/// The 9 pt divider between the source and track panes: a slightly cool metal strip with a small
/// recessed dimple at its middle, the only hint in 2005 that it could be dragged (§7.1 splitterCore,
/// reference itunes_dot.png). Its frame spans both pane borders so the whole 11 pt gap is grabbable.
@MainActor
final class ChromeSplitterView: NSView {
    /// Called continuously while dragging with the proposed source content width.
    var onDrag: ((CGFloat) -> Void)?
    /// Called once on mouse-up, so the width is persisted once per drag rather than per pixel.
    var onDragEnd: (() -> Void)?
    var currentWidth: (() -> CGFloat)?

    private var dragStartX: CGFloat = 0
    private var dragStartWidth: CGFloat = 0

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    /// Acts on the first click even in an inactive window, as Aqua window and media buttons did.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Between the two pane lips; each pane frame draws its own border and lip in the outer
        // 1 pt column on either side. In the reference the core averages #B8B8B8 down its whole
        // length, which is the metal itself at that x, so `splitterCore` is only a faint cool wash
        // over the metal and its grain rather than a flat fill (which read as a dark stripe).
        let core = NSRect(x: 1, y: 0, width: bounds.width - 2, height: bounds.height)
        ChromeDraw.fillRect(core, Theme.splitterCore.withAlphaComponent(0.25))

        // The dimple: dark upper-left, bright lower-right, about 4 pt across.
        let d: CGFloat = 4
        let dimple = NSRect(x: (bounds.midX - d / 2).rounded(), y: (bounds.midY - d / 2).rounded(), width: d, height: d)
        ChromeDraw.fill(NSBezierPath(ovalIn: dimple),
                        with: ChromeDraw.gradient([ChromePalette.dimpleShadow, Theme.rule, ChromePalette.dimpleLight],
                                                  [0, 0.45, 1]),
                        top: dimple.minY, bottom: dimple.maxY)
    }

    // Window coordinates, because this view moves under the mouse while it is dragged.
    override func mouseDown(with event: NSEvent) {
        dragStartX = event.locationInWindow.x
        dragStartWidth = currentWidth?() ?? Theme.Metrics.sourcePaneWidth
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(dragStartWidth + (event.locationInWindow.x - dragStartX))
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnd?()
    }
}
