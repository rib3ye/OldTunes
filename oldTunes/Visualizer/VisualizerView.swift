import AppKit
import QuartzCore

/// Where the visualizer draws: a view backed by a CAMetalLayer, which the renderer sets up, with an
/// overlay for key feedback, the "can't hear the music" hint and the key list (H).
///
/// It sits in the track pane in place of the track list, or alone in the full-screen window. It takes
/// keyboard focus while it shows, so the visualizer's letter keys reach it; Space and every ⌘ key
/// still belong to oldTunes (Space through AppController's monitor, ⌘ keys through the menus).
@MainActor
final class VisualizerView: NSView {
    let metalLayer = CAMetalLayer()
    /// A key the visualizer may want. Return true if it was used.
    var onKey: ((NSEvent) -> Bool)?
    /// Esc: leave full screen.
    var onEscape: (() -> Void)?
    /// A click: in full screen it leaves, as in iTunes.
    var onClick: (() -> Void)?
    /// The size in points changed, or the view moved to another screen or window.
    var onGeometryChange: (() -> Void)?

    private let toast = OverlayText()
    private let hintBox = OverlayText()
    private let keyList = OverlayText()
    private var toastFade: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?
    private(set) var hint: SilenceWatchdog.Hint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        metalLayer.backgroundColor = NSColor.black.cgColor
        metalLayer.isOpaque = true
        for overlay in [toast, hintBox, keyList] {
            overlay.isHidden = true
            addSubview(overlay)
        }
        keyList.text = Self.keyListText
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Visualizer")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func makeBackingLayer() -> CALayer { metalLayer }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        if event.keyCode == 53 { onEscape?(); return }   // Esc the visualizer didn't use
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onClick?()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutOverlays()
        onGeometryChange?()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        onGeometryChange?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        if let window {
            screenObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification,
                                                                    object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onGeometryChange?() }
            }
        }
        onGeometryChange?()
    }

    // MARK: - Overlay

    /// A line of feedback for a key ("Palette locked"), fading out after a moment.
    func showToast(_ text: String) {
        toast.text = text
        toast.isHidden = false
        toast.alphaValue = 1
        layoutOverlays()
        toastFade?.cancel()
        toastFade = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled, let self else { return }
            await NSAnimationContext.runAnimationGroup { $0.duration = 0.3; self.toast.animator().alphaValue = 0 }
        }
    }

    /// The watchdog's hint, or nil to clear it.
    func showHint(_ hint: SilenceWatchdog.Hint?) {
        self.hint = hint
        switch hint {
        case .cantHear?:
            hintBox.text = "The visualizer can't hear the music.\n"
                + "It keeps trying. Turning the visualizer off and on again may help."
        case .airPlay?:
            hintBox.text = "The visualizer can't hear music playing over AirPlay."
        case .stopped?:
            hintBox.text = "The visualizer stopped listening when sharing was stopped from the menu bar.\n"
                + "Turn the visualizer off and on again to listen again."
        case nil:
            break
        }
        hintBox.isHidden = hint == nil
        layoutOverlays()
    }

    var isShowingKeyList: Bool { !keyList.isHidden }

    func toggleKeyList() {
        keyList.isHidden.toggle()
        layoutOverlays()
    }

    /// The key list (H), headed by the credit Geiss HDR's NOTICE asks derivative works to carry.
    static let keyListText = """
        Visualizer — based on Geiss HDR by Ryan Geiss
        R  new everything          P M W  new palette, motion, wave
        ⇧P ⇧M ⇧W  lock one         L  lock or unlock all
        E ⇧E  brightness           D ⇧D  darkening
        J ⇧J  wave size            S ⇧S  wave smoothing
        − +  motion speed          [ ]  transition speed
        Q ⇧Q  resolution           1–6  effects
        0  reset                   ⌃H  HDR on or off
        ⇧F  freeze                 H  this list
        Space  play or pause       Esc  leave full screen
        ← →  previous, next song   ↑ ↓  volume
        """

    private func layoutOverlays() {
        let margin: CGFloat = 12
        let width = max(0, bounds.width - 2 * margin)
        if !keyList.isHidden {
            let size = keyList.fittingSize(maxWidth: width)
            keyList.frame = NSRect(x: margin, y: margin, width: size.width, height: size.height)
        }
        if !hintBox.isHidden {
            let size = hintBox.fittingSize(maxWidth: min(width, 460))
            hintBox.frame = NSRect(x: (bounds.width - size.width) / 2, y: bounds.height - margin - size.height,
                                   width: size.width, height: size.height)
        }
        if !toast.isHidden {
            let size = toast.fittingSize(maxWidth: width)
            let top = hintBox.isHidden ? bounds.height - margin - size.height : hintBox.frame.minY - 8 - size.height
            toast.frame = NSRect(x: (bounds.width - size.width) / 2, y: top, width: size.width, height: size.height)
        }
    }

}

/// White text on a translucent black rounded box, drawn over the visualizer.
@MainActor
private final class OverlayText: NSView {
    var text = "" { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    private static let inset = NSSize(width: 10, height: 7)
    private static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    private var attributes: [NSAttributedString.Key: Any] {
        [.font: Self.font, .foregroundColor: NSColor.white]
    }

    func fittingSize(maxWidth: CGFloat) -> NSSize {
        let bounds = (text as NSString).boundingRect(with: NSSize(width: max(1, maxWidth - 2 * Self.inset.width), height: 10_000),
                                                     options: [.usesLineFragmentOrigin], attributes: attributes)
        return NSSize(width: ceil(bounds.width) + 2 * Self.inset.width, height: ceil(bounds.height) + 2 * Self.inset.height)
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0, alpha: 0.62).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        (text as NSString).draw(with: bounds.insetBy(dx: Self.inset.width, dy: Self.inset.height),
                                options: [.usesLineFragmentOrigin], attributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        if let onClick { onClick() } else { super.mouseDown(with: event) }
    }
}
