import AppKit

/// One recessed pane in the metal: a 1 px border around an empty content container, a light lip
/// on the left, right and bottom, and a faint shadow line above, which is what made iTunes 4.9's
/// lists look sunk into the window (RESEARCH.md §7.1, §7.2).
///
/// All lines are one device pixel and hug the content, so on Retina the frame stays as fine as the
/// 2005 1x art instead of doubling. Integration puts one view inside `content`.
@MainActor
final class ChromePaneFrameView: NSView {
    enum Style { case source, track }

    /// The public `sourcePane` / `trackPane` container.
    let content = NSView()
    private let style: Style

    /// Room outside the content for the border and the lip/shadow, in points.
    static let outset: CGFloat = 2

    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        content.autoresizesSubviews = true
        content.clipsToBounds = true
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// The content rectangle in the superview's coordinates; the frame grows around it.
    var contentRect: NSRect {
        get { content.frame.offsetBy(dx: frame.minX, dy: frame.minY) }
        set {
            let o = Self.outset
            frame = newValue.insetBy(dx: -o, dy: -o)
            content.frame = NSRect(x: o, y: o, width: newValue.width, height: newValue.height)
            needsDisplay = true
        }
    }

    /// Only the content and its border take clicks; the lip around it belongs to the metal and to
    /// the splitter next to it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let hl = ChromeDraw.hairline(self)
        guard content.frame.insetBy(dx: -hl, dy: -hl).contains(local) else { return nil }
        return super.hitTest(point)
    }

    override func draw(_ dirtyRect: NSRect) {
        let hl = ChromeDraw.hairline(self)
        let c = content.frame
        let (left, right) = style == .source
            ? (Theme.paneBorderSrcL, Theme.paneBorderSrcR)
            : (Theme.paneBorderTrkL, Theme.paneBorderTrkR)

        ChromeDraw.fillRect(NSRect(x: c.minX - hl, y: c.minY - 2 * hl, width: c.width + 2 * hl, height: hl),
                            ChromePalette.recessShadow)
        ChromeDraw.fillRect(NSRect(x: c.minX - 2 * hl, y: c.minY - hl, width: hl, height: c.height + 2 * hl),
                            ChromePalette.paneSideHighlight)
        ChromeDraw.fillRect(NSRect(x: c.maxX + hl, y: c.minY - hl, width: hl, height: c.height + 2 * hl),
                            ChromePalette.paneSideHighlight)
        ChromeDraw.fillRect(NSRect(x: c.minX - 2 * hl, y: c.maxY + hl, width: c.width + 4 * hl, height: hl),
                            Theme.footHighlight)

        ChromeDraw.fillRect(NSRect(x: c.minX - hl, y: c.minY - hl, width: c.width + 2 * hl, height: hl), Theme.rule)
        ChromeDraw.fillRect(NSRect(x: c.minX - hl, y: c.maxY, width: c.width + 2 * hl, height: hl), Theme.rule)
        ChromeDraw.fillRect(NSRect(x: c.minX - hl, y: c.minY, width: hl, height: c.height), left)
        ChromeDraw.fillRect(NSRect(x: c.maxX, y: c.minY, width: hl, height: c.height), right)
    }
}
