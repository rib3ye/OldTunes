import AppKit

/// The window's content view: paints the brushed metal under everything in one pass and lays out
/// the title bar, control bar, the two bordered panes with the splitter, and the bottom bar.
///
/// Every child is transparent, so the metal is drawn exactly once per pixel from one cached bitmap
/// and the horizontal gradient stays continuous across all of them (RESEARCH.md §7.3).
@MainActor
final class MetalContentView: NSView {
    let titleBar = ChromeTitleBarView()
    let controlBar: ControlBarView
    let bottomBar: BottomBarView
    let sourceFrame = ChromePaneFrameView(style: .source)
    let trackFrame = ChromePaneFrameView(style: .track)
    let splitter = ChromeSplitterView()

    /// Source pane content width in points (§7.2: 158, resizable 120...400). Persisted.
    private(set) var sourceWidth: CGFloat

    /// How many times the metal bitmap has been rebuilt, and how long the last build took.
    /// The harness reads these to prove the cache only rebuilds on a size change.
    private(set) var metalBuildCount = 0
    private(set) var lastMetalBuildSeconds: Double = 0
    private var metalImage: CGImage?
    private var metalPixelSize = (width: 0, height: 0)
    /// Which appearance the cached metal was built for: graphite and aluminum are different bitmaps.
    private var metalIsDark = false

    static let sourceWidthDefaultsKey = "OldTunes.Chrome.sourcePaneWidth"
    /// The track pane never gets narrower than this, whatever the stored source width.
    static let minimumTrackWidth: CGFloat = 200

    init(controlBar: ControlBarView, bottomBar: BottomBarView) {
        self.controlBar = controlBar
        self.bottomBar = bottomBar
        let stored = UserDefaults.standard.double(forKey: Self.sourceWidthDefaultsKey)
        let range = Theme.Metrics.sourcePaneWidthRange
        sourceWidth = stored > 0 ? min(max(CGFloat(stored), range.lowerBound), range.upperBound)
                                 : Theme.Metrics.sourcePaneWidth
        super.init(frame: NSRect(origin: .zero, size: Theme.Metrics.referenceWindow))
        for view in [splitter, sourceFrame, trackFrame, titleBar, controlBar, bottomBar] as [NSView] {
            addSubview(view)
        }
        splitter.onDrag = { [weak self] width in self?.setSourceWidth(width, persist: false) }
        splitter.onDragEnd = { [weak self] in self?.persistSourceWidth() }
        splitter.currentWidth = { [weak self] in self?.effectiveSourceWidth ?? Theme.Metrics.sourcePaneWidth }
        layoutChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    /// Opaque views default to NOT moving the window; the metal is the window's background, so
    /// dragging it must move the window like 2005 metal did.
    override var mouseDownCanMoveWindow: Bool { true }

    // MARK: - Layout (§7.2, window-relative points, origin top-left)

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        layoutChrome()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    /// The source width actually shown: the stored width, narrowed if the window is too small to
    /// give the track pane its minimum.
    var effectiveSourceWidth: CGFloat {
        let range = Theme.Metrics.sourcePaneWidthRange
        let fixed = Self.paneLeft + Self.paneGapAndBorders + Self.trackRightInset + Self.minimumTrackWidth
        return max(range.lowerBound, min(sourceWidth, bounds.width - fixed))
    }

    /// Source content starts at x 17: window border at x 0, gutter x 1..15, pane border x 16 (§7.2).
    static let paneLeft: CGFloat = 17
    /// Border + 9 pt splitter + border between the two content areas (175 → 186).
    static let paneGapAndBorders: CGFloat = 11
    /// Track content ends 16 pt from the right edge (740 → 756).
    static let trackRightInset: CGFloat = 16
    static let paneTop: CGFloat = 93
    /// Pane content ends at y 464 for a 500 pt window: 36 pt above the bottom.
    static let paneBottomInset: CGFloat = 36

    func layoutChrome() {
        let w = bounds.width, h = bounds.height
        titleBar.frame = NSRect(x: 0, y: 0, width: w, height: Theme.Metrics.titleBarHeight + 1)
        controlBar.frame = NSRect(x: 0, y: Theme.Metrics.titleBarHeight + 1, width: w,
                                  height: Theme.Metrics.controlBarHeight)
        bottomBar.frame = NSRect(x: 0, y: h - Theme.Metrics.bottomBarHeight - 1, width: w,
                                 height: Theme.Metrics.bottomBarHeight + 1)

        let paneHeight = max(0, h - Self.paneTop - Self.paneBottomInset)
        let sw = effectiveSourceWidth
        let source = NSRect(x: Self.paneLeft, y: Self.paneTop, width: sw, height: paneHeight)
        let trackX = source.maxX + Self.paneGapAndBorders
        let track = NSRect(x: trackX, y: Self.paneTop, width: max(0, w - Self.trackRightInset - trackX),
                           height: paneHeight)
        sourceFrame.contentRect = source
        trackFrame.contentRect = track
        splitter.frame = NSRect(x: source.maxX, y: Self.paneTop - 1, width: Self.paneGapAndBorders,
                                height: paneHeight + 2)
        splitter.needsDisplay = true
    }

    func setSourceWidth(_ width: CGFloat, persist: Bool) {
        let range = Theme.Metrics.sourcePaneWidthRange
        sourceWidth = min(max(width.rounded(), range.lowerBound), range.upperBound)
        layoutChrome()
        if persist { persistSourceWidth() }
    }

    private func persistSourceWidth() {
        UserDefaults.standard.set(Double(sourceWidth), forKey: Self.sourceWidthDefaultsKey)
    }

    // MARK: - Drawing

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        metalImage = nil
        needsDisplay = true
    }

    /// Light ↔ dark. The next draw sees the new appearance and rebuilds the metal for it.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let image = currentMetal() else { return }
        ctx.saveGState()
        // This view is flipped; a CGImage draws bottom-up, so flip back for the blit.
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(origin: .zero, size: bounds.size))
        ctx.restoreGState()
    }

    /// The cached metal, rebuilt only when the device-pixel size or the appearance changes.
    /// Called from `draw`, so the theme colors the texture reads resolve for this view.
    private func currentMetal() -> CGImage? {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let pw = Int((bounds.width * scale).rounded()), ph = Int((bounds.height * scale).rounded())
        let dark = Theme.isDark
        if let metalImage, metalPixelSize.width == pw, metalPixelSize.height == ph, metalIsDark == dark {
            return metalImage
        }
        let start = DispatchTime.now().uptimeNanoseconds
        metalImage = ChromeMetalTexture.make(pixelWidth: pw, pixelHeight: ph, scale: scale)
        lastMetalBuildSeconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        metalPixelSize = (pw, ph)
        metalIsDark = dark
        metalBuildCount += 1
        return metalImage
    }
}
