import AppKit

/// The top 28 pt of the window: the hand-drawn traffic lights and the centred title in
/// `Theme.titleFont`, Lucida Grande in regular weight (§7.4, §7.5; review finding 22 measured the
/// reference title's stems and found them regular, not bold). Transparent, so the metal shows
/// through, and draggable, so the title bar moves the window as it always did.
@MainActor
final class ChromeTitleBarView: NSView {
    let trafficLights = ChromeTrafficLightsView(frame: ChromeTrafficLightsView.frameInTitleBar)

    var title = "oldTunes" { didSet { needsDisplay = true } }

    static let titleBaseline = ChromeMetrics.titleBaseline
    /// Keeps a long title clear of the traffic lights on both sides.
    static let titleSideMargin: CGFloat = 76

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(trafficLights)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// The title bar moves the window itself instead of leaving it to "movable by background":
    /// that path swallows the mouse-down, so a double-click would never arrive here.
    override var mouseDownCanMoveWindow: Bool { false }
    /// A real title bar drags an inactive window on the first click, without a separate click
    /// to activate it first.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Dragging moves the window; double-clicking zooms it as a 2005 title bar did (respecting the
    /// user's "double-click a window's title bar to" setting).
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        guard event.clickCount == 2 else { return window.performDrag(with: event) }
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize" {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        default: window.zoom(nil)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let active = (window?.isKeyWindow ?? false) || (window?.isMainWindow ?? false)
        ChromeDraw.text(title, centerX: bounds.midX, baseline: Self.titleBaseline,
                        maxWidth: bounds.width - 2 * Self.titleSideMargin, font: Theme.titleFont,
                        color: active ? Theme.textPrimary : Theme.textDimmed, embossed: true)
    }

    /// Redraws everything that depends on whether the window is active.
    func windowActivityChanged() {
        needsDisplay = true
        trafficLights.needsDisplay = true
        trafficLights.syncHover()
    }
}
