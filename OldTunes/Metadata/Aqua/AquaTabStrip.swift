import AppKit

/// The 10.4 tab row: one joined gel lozenge, centred over the content box and straddling its
/// top edge, with the selected tab in Aqua blue. Stock NSTabView draws Liquid Glass.
@MainActor
final class AquaTabStrip: NSView {
    var titles: [String] { didSet { layoutTabs(); needsDisplay = true } }
    var selectedIndex = 0 { didSet { needsDisplay = true } }
    var onSelect: ((Int) -> Void)?

    static let height: CGFloat = 22
    private var tabRects: [NSRect] = []

    init(titles: [String]) {
        self.titles = titles
        super.init(frame: .zero)
        setAccessibilityRole(.tabGroup)
        setFrameSize(NSSize(width: Self.totalWidth(for: titles), height: Self.height))
        layoutTabs()
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    private static func tabWidth(_ title: String) -> CGFloat {
        let w = (title as NSString).size(withAttributes: [.font: AquaStyle.controlFont]).width
        return max(64, ceil(w) + 30)
    }

    static func totalWidth(for titles: [String]) -> CGFloat {
        titles.reduce(0) { $0 + tabWidth($1) } + 2
    }

    private func layoutTabs() {
        var x: CGFloat = 1
        tabRects = titles.map { title in
            let w = Self.tabWidth(title)
            defer { x += w }
            return NSRect(x: x, y: 0, width: w, height: Self.height - 1)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutTabs()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let first = tabRects.first, let last = tabRects.last else { return }
        let whole = NSRect(x: first.minX, y: 0, width: last.maxX - first.minX, height: Self.height - 1)
        let radius: CGFloat = 8

        // The whole lozenge in white gel, then the selected segment re-painted blue inside a clip.
        AquaStyle.drawGel(in: whole, radius: radius, gel: AquaStyle.whiteGel, flipped: true)
        if tabRects.indices.contains(selectedIndex) {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: tabRects[selectedIndex]).addClip()
            AquaStyle.drawGel(in: whole, radius: radius, gel: AquaStyle.wideBlueGel, flipped: true, shadow: false)
            NSGraphicsContext.restoreGraphicsState()
        }

        // Dividers between segments.
        AquaStyle.whiteGel.rimBottom.withAlphaComponent(0.85).setFill()
        for rect in tabRects.dropFirst() {
            NSRect(x: rect.minX - 0.5, y: whole.minY + 1, width: 1, height: whole.height - 2).fill()
        }

        for (i, rect) in tabRects.enumerated() {
            let attrs = AquaStyle.engravedAttributes(AquaStyle.controlFont, alignment: .center)
            (titles[i] as NSString).draw(with: NSRect(x: rect.minX, y: 3, width: rect.width, height: 16),
                                         options: [.usesLineFragmentOrigin], attributes: attrs)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let index = tabRects.firstIndex(where: { $0.contains(p) }), index != selectedIndex else { return }
        selectedIndex = index
        onSelect?(index)
    }
}
