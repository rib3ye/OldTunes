import AppKit

/// The brushed-metal main window: title bar with hand-drawn traffic lights, the control bar, two
/// bordered panes with a draggable splitter, and the bottom bar (RESEARCH.md §7, §8.1).
///
/// Integration owns this controller, wires the bars' callbacks, and adds ONE subview filling each
/// of `sourcePane` and `trackPane` (autoresizing [.width, .height]). The window's delegate is
/// left free for integration: the chrome gets everything it needs from MetalWindow itself.
@MainActor
final class MetalWindowController: NSWindowController {
    let controlBar: ControlBarView
    let bottomBar: BottomBarView
    /// Empty containers inside the bordered panes. They clip to their bounds.
    let sourcePane: NSView
    let trackPane: NSView
    /// The view that paints the metal and lays everything out.
    let metalView: MetalContentView

    /// Drawn centred in the title bar, and used for the Window menu and Mission Control.
    var titleText = "OldTunes" {
        didSet {
            metalView.titleBar.title = titleText
            window?.title = titleText
        }
    }

    init() {
        let controlBar = ControlBarView()
        let bottomBar = BottomBarView()
        let metalView = MetalContentView(controlBar: controlBar, bottomBar: bottomBar)
        self.controlBar = controlBar
        self.bottomBar = bottomBar
        self.metalView = metalView
        sourcePane = metalView.sourceFrame.content
        trackPane = metalView.trackFrame.content

        let window = MetalWindow(contentSize: Theme.Metrics.referenceWindow)
        window.contentView = metalView
        window.title = titleText
        window.onFind = { [weak controlBar] in controlBar?.focusSearch() }
        window.onActivityChange = { [weak metalView, weak controlBar] in
            metalView?.titleBar.windowActivityChanged()
            controlBar?.search.needsDisplay = true
        }
        // A resize grip means nothing in full screen, and dragging it there would fight AppKit.
        window.onFullScreenChange = { [weak bottomBar] full in bottomBar?.grip.isHidden = full }
        let editor = Self.makeSearchFieldEditor()
        window.fieldEditorProvider = { [weak controlBar] client in
            guard let field = client as? NSTextField, field === controlBar?.search.textField else { return nil }
            return editor
        }
        super.init(window: window)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var metalWindow: MetalWindow? { window as? MetalWindow }

    /// The search capsule's own field editor. The window's shared one draws the macOS 14+ accent
    /// caret; 2005's was black. A private editor changes that for the search field alone. Typing,
    /// selection, undo, copy and paste are stock NSTextView behaviour; plain text only, so a rich
    /// paste cannot bring fonts or colours into the capsule.
    private static func makeSearchFieldEditor() -> NSTextView {
        let editor = NSTextView(frame: .zero)
        editor.isFieldEditor = true
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.insertionPointColor = Theme.textPrimary
        return editor
    }
}
