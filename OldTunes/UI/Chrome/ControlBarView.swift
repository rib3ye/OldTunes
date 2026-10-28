import AppKit

/// The 64 pt control bar under the title bar (window y 28..91, §7.2): transport buttons and volume
/// on the left, the LCD centred on the window, the search capsule and Browse button on the right.
///
/// Transparent: the window's metal shows through. It only draws the "Search" and "Browse" labels;
/// every control is its own hand-drawn subview.
@MainActor
final class ControlBarView: NSView {
    var onPlayPause: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    /// Continuously while dragging, 0...1.
    var onVolumeChange: ((Float) -> Void)?
    /// Once, on mouse-up after a scrubber drag or click.
    var onSeek: ((TimeInterval) -> Void)?
    /// Every keystroke; the receiver debounces.
    var onSearchTextChange: ((String) -> Void)?
    var onBrowseToggle: (() -> Void)?
    /// The LCD's right end button ("snap back" to the playing song): once per click, on mouse-up
    /// inside the button. The button draws pressed while held; a press dragged off fires nothing.
    var onRevealNowPlaying: (() -> Void)?

    let previousButton = ChromeTransportButton(kind: .previous)
    let playButton = ChromeTransportButton(kind: .playPause)
    let nextButton = ChromeTransportButton(kind: .next)
    let volumeSlider = ChromeVolumeSlider(frame: ChromeVolumeSlider.frameInControlBar)
    let lcd = ChromeLCDView()
    let search = ChromeSearchField()
    let browseButton = ChromeBrowseButton()

    /// The LCD never comes closer than this to the volume glyph (x 132) or the search capsule.
    static let lcdLeftLimit: CGFloat = 140
    static let lcdSearchGap: CGFloat = 10
    /// The LCD and the search capsule grow with the window in the proportions of Noah's iTunes 4
    /// reference screenshot, measured on its middle rows: in the 943 px window the LCD is 414 px
    /// wide and the capsule 133 px. Neither gets narrower than its §7.2 size (313 and 103).
    static let lcdWidthFraction: CGFloat = 414 / 943
    static let searchWidthFraction: CGFloat = 133 / 943
    /// The bar's top in window coordinates; every local y below is a §7.2 window y minus this.
    static let windowY = Theme.Metrics.titleBarHeight + 1
    /// "Search" and "Browse" labels sit on window y 80 (measured; see ChromeMetrics).
    static let labelBaseline = ChromeMetrics.labelBaseline - windowY

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Theme.Metrics.referenceWindow.width,
                                 height: Theme.Metrics.controlBarHeight))
        for view in [previousButton, playButton, nextButton, volumeSlider, lcd, search, browseButton] as [NSView] {
            addSubview(view)
        }
        previousButton.onClick = { [weak self] in self?.onPrevious?() }
        playButton.onClick = { [weak self] in self?.onPlayPause?() }
        nextButton.onClick = { [weak self] in self?.onNext?() }
        volumeSlider.onChange = { [weak self] in self?.onVolumeChange?($0) }
        lcd.onSeek = { [weak self] in self?.onSeek?($0) }
        lcd.onRevealNowPlaying = { [weak self] in self?.onRevealNowPlaying?() }
        search.onTextChange = { [weak self] in self?.onSearchTextChange?($0) }
        browseButton.onClick = { [weak self] in
            guard let self else { return }
            browseButton.isOn.toggle()
            onBrowseToggle?()
        }
        layoutControls()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    // MARK: - Public API

    /// Play/pause glyph, LCD lines, scrubber and volume knob. Position is ignored while the user
    /// drags the scrubber, and volume while they drag the knob. The slider greys out when the
    /// volume can't reach the song playing.
    func update(_ state: PlaybackState) {
        playButton.isPlaying = state.isPlaying
        lcd.update(state)
        volumeSlider.isEnabled = state.isVolumeEnabled
        if !volumeSlider.isDragging { volumeSlider.value = min(max(state.volume, 0), 1) }
    }

    /// The LCD's two lines when nothing is playing.
    func setIdleText(_ line1: String, _ line2: String) {
        lcd.setIdleText(line1, line2)
    }

    var searchText: String {
        get { search.text }
        set { search.text = newValue }
    }

    func focusSearch() { search.focus() }

    var isBrowseOn: Bool {
        get { browseButton.isOn }
        set { browseButton.isOn = newValue }
    }

    // MARK: - Layout (§7.2; local y = window y − 28)

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        layoutControls()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    private func layoutControls() {
        let w = bounds.width
        let cy = Theme.Metrics.transportCenterY - Self.windowY
        previousButton.frame = buttonFrame(centerX: Theme.Metrics.backButton.centerX, cy: cy,
                                           diameter: Theme.Metrics.backButton.diameter)
        playButton.frame = buttonFrame(centerX: Theme.Metrics.playButton.centerX, cy: cy,
                                       diameter: Theme.Metrics.playButton.diameter)
        nextButton.frame = buttonFrame(centerX: Theme.Metrics.forwardButton.centerX, cy: cy,
                                       diameter: Theme.Metrics.forwardButton.diameter)

        let capsule = searchCapsuleFrame
        search.frame = capsule.insetBy(dx: -ChromeSearchField.margin, dy: -ChromeSearchField.margin)

        let browse = Theme.Metrics.browseButton
        let side = browse.diameter + 2 * ChromeBrowseButton.margin
        browseButton.frame = NSRect(x: w - browse.rightInsetToCenter - side / 2, y: cy - side / 2,
                                    width: side, height: side)

        // The LCD is centred on the WINDOW at every width; it narrows rather than collide.
        let proportional = max(Theme.Metrics.lcdSize.width, (w * Self.lcdWidthFraction).rounded())
        let half = min(proportional / 2, w / 2 - Self.lcdLeftLimit, capsule.minX - Self.lcdSearchGap - w / 2)
        let lcdWidth = max(120, 2 * half)
        // An odd width in an even window (313 in 700) starts the centred LCD on a half point. That
        // is a whole device pixel on Retina, but on a 1x display it would smear the scrubber's 1 pt
        // outline over two pixels.
        let centred = NSRect(x: w / 2 - lcdWidth / 2, y: Theme.Metrics.lcdTop - Self.windowY, width: lcdWidth,
                             height: Theme.Metrics.lcdSize.height + 1)
        lcd.frame = window == nil ? centred : backingAlignedRect(centred, options: .alignAllEdgesNearest)
        lcd.needsDisplay = true
    }

    // Re-align when the bar lands in a window or moves to a screen with another scale.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layoutControls()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layoutControls()
    }

    /// Its right end stays 79 pt from the window's; it grows leftward with the window.
    var searchCapsuleFrame: NSRect {
        let size = Theme.Metrics.searchSize
        let width = max(size.width, (bounds.width * Self.searchWidthFraction).rounded())
        return NSRect(x: bounds.width - Theme.Metrics.searchRightInset - width,
                      y: Theme.Metrics.searchTop - Self.windowY, width: width, height: size.height)
    }

    private func buttonFrame(centerX: CGFloat, cy: CGFloat, diameter: CGFloat) -> NSRect {
        let side = diameter + 2 * ChromeTransportButton.margin
        return NSRect(x: centerX - side / 2, y: cy - side / 2, width: side, height: side)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let capsule = searchCapsuleFrame
        ChromeDraw.text("Search", centerX: capsule.midX, baseline: Self.labelBaseline, maxWidth: capsule.width + 10,
                        embossed: true)
        let browseX = bounds.width - Theme.Metrics.browseButton.rightInsetToCenter
        ChromeDraw.text("Browse", centerX: browseX, baseline: Self.labelBaseline, maxWidth: 60, embossed: true)
    }
}
