import AppKit

/// The 34 pt bottom bar (window y 465..498, §7.2, §7.4): four bevel buttons under the source pane
/// (Add Folder, shuffle, repeat, show/hide artwork), the centred library summary, three buttons on
/// the right, and the resize grip.
///
/// The right group (equalizer, visualizer, eject) is drawn because the 2005 window had it, but is
/// disabled: OldTunes has none of those features, and a live button that does nothing is worse
/// than a dimmed one. Transparent, so the window's metal shows through.
@MainActor
final class BottomBarView: NSView {
    var onAddFolder: (() -> Void)?
    var onShuffleToggle: (() -> Void)?
    var onRepeatCycle: (() -> Void)?
    var onArtworkToggle: (() -> Void)?

    let addButton = ChromeBevelButton(glyph: .add)
    let shuffleButton = ChromeBevelButton(glyph: .shuffle)
    let repeatButton = ChromeBevelButton(glyph: .repeatAll)
    let artworkButton = ChromeBevelButton(glyph: .artworkShow)
    let equalizerButton = ChromeBevelButton(glyph: .equalizer)
    let visualizerButton = ChromeBevelButton(glyph: .visualizer)
    let ejectButton = ChromeBevelButton(glyph: .eject)
    let grip = ChromeResizeGripView()

    private(set) var summary = ""
    private(set) var isShuffleOn = false
    private(set) var repeatMode: RepeatMode = .off
    private(set) var isArtworkVisible = false

    /// Local y = window y − 465.
    static let buttonTop = Theme.Metrics.bottomButtonTopInset
    static var summaryBaseline: CGFloat { Theme.Metrics.bottomBarHeight + 1 - ChromeMetrics.summaryBaselineFromBottom }
    /// The summary keeps this much air between itself and either button group.
    static let summaryGap: CGFloat = 8

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Theme.Metrics.referenceWindow.width,
                                 height: Theme.Metrics.bottomBarHeight + 1))
        for button in leftGroup + rightGroup { addSubview(button) }
        addSubview(grip)
        for button in rightGroup { button.isEnabled = false }

        addButton.onClick = { [weak self] in self?.onAddFolder?() }
        // Toggles flip at once for immediate feedback; the owner confirms with the setters.
        shuffleButton.onClick = { [weak self] in
            guard let self else { return }
            setShuffle(!isShuffleOn)
            onShuffleToggle?()
        }
        repeatButton.onClick = { [weak self] in
            guard let self else { return }
            setRepeat(Self.next(after: repeatMode))
            onRepeatCycle?()
        }
        artworkButton.onClick = { [weak self] in
            guard let self else { return }
            setArtworkVisible(!isArtworkVisible)
            onArtworkToggle?()
        }
        layoutButtons()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    var leftGroup: [ChromeBevelButton] { [addButton, shuffleButton, repeatButton, artworkButton] }
    var rightGroup: [ChromeBevelButton] { [equalizerButton, visualizerButton, ejectButton] }

    // MARK: - Public API

    func setSummary(_ text: String) {
        guard text != summary else { return }
        summary = text
        needsDisplay = true
    }

    func setShuffle(_ on: Bool) {
        isShuffleOn = on
        shuffleButton.isLit = on
    }

    func setRepeat(_ mode: RepeatMode) {
        repeatMode = mode
        repeatButton.isLit = mode != .off
        repeatButton.glyph = mode == .one ? .repeatOne : .repeatAll
    }

    /// The button's triangle points up to show the artwork pane and down to hide it.
    func setArtworkVisible(_ on: Bool) {
        isArtworkVisible = on
        artworkButton.isLit = on
        artworkButton.glyph = on ? .artworkHide : .artworkShow
    }

    /// iTunes' repeat button cycled off → all → one → off.
    static func next(after mode: RepeatMode) -> RepeatMode {
        switch mode {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }

    // MARK: - Layout

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        layoutButtons()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    private func layoutButtons() {
        let size = Theme.Metrics.bottomButtonSize
        let pitch = Theme.Metrics.bottomButtonPitch
        let height = size.height + ChromeBevelButton.lipRoom
        for (i, button) in leftGroup.enumerated() {
            button.frame = NSRect(x: Theme.Metrics.bottomLeftGroupFirstX + CGFloat(i) * pitch, y: Self.buttonTop,
                                  width: size.width, height: height)
        }
        let rightEdge = bounds.width - Theme.Metrics.bottomRightGroupRightInset
        for (i, button) in rightGroup.reversed().enumerated() {
            button.frame = NSRect(x: rightEdge - size.width - CGFloat(i) * pitch, y: Self.buttonTop,
                                  width: size.width, height: height)
        }
        let grip = Theme.Metrics.resizeGripSize
        self.grip.frame = NSRect(x: bounds.width - grip.width - 1, y: bounds.height - grip.height,
                                 width: grip.width + 1, height: grip.height)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard !summary.isEmpty,
              let leftEnd = leftGroup.last?.frame.maxX, let rightStart = rightGroup.first?.frame.minX else { return }
        let lo = leftEnd + Self.summaryGap, hi = rightStart - Self.summaryGap
        let width = ChromeDraw.textWidth(summary) + 4
        // Centred on the window like iTunes; slides into the free span only when it would collide.
        let centred = bounds.midX - width / 2 >= lo && bounds.midX + width / 2 <= hi
        ChromeDraw.text(summary, centerX: centred ? bounds.midX : (lo + hi) / 2, baseline: Self.summaryBaseline,
                        maxWidth: centred ? width : max(0, hi - lo), embossed: true)
    }
}
