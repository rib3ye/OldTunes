import AppKit

/// iTunes 4.9 (mid-2005, brushed metal). Every light value is from docs/RESEARCH.md §7, which
/// measured them from a real screenshot. Change a value here, never inline in a view.
///
/// Each color also has a dark value: "Graphite", the night version 2005 never shipped
/// (RESEARCH.md §7.7). The pair is one dynamic NSColor that AppKit resolves for whichever
/// appearance is drawing, so views keep naming `Theme.listBG` and never ask which mode is on.
/// A blend resolves a dynamic color once, and a gradient is not documented to re-resolve its
/// colors, so both are built once per appearance instead (`Themed`).
@MainActor
enum Theme {

    // MARK: - Colors (§7.1 light, §7.7 dark)

    // Brushed metal and window frame. Dark: smoked graphite, the black iPod nano's aluminum.
    static let metalEdge        = hex(0xA4A4A4, dark: 0x36373A)
    static let metalCenter      = hex(0xCECECE, dark: 0x505256)
    static let winBorderLeft    = hex(0x959595, dark: 0x1C1D1F)
    static let winBorderRight   = hex(0x999999, dark: 0x1E1F21)
    /// Dark: the chamfer along the top edge still catches the light.
    static let winTopHighlight  = hex(0xF3F3F3, dark: 0x6A6C70)
    static let rule             = hex(0x666666, dark: 0x121315)

    // Traffic lights: lit gel, the same in both.
    static let tlRed    = hex(0xD4594A)
    static let tlYellow = hex(0xF7AB3C)
    static let tlGreen  = hex(0x61A029)

    // Transport buttons (interiors are darker at the TOP — the opposite of modern gloss).
    // Dark: graphite gel with light glyphs, like the black iPod's click wheel. A clear step lighter
    // than the metal around it, as the day buttons are, or the cap reads as a hole in the metal.
    static let btnRing       = hex(0x6C6C6C, dark: 0x0C0D0E)
    static let btnPlayTop    = hex(0xE6E6E6, dark: 0x46484C)
    static let btnPlayBottom = hex(0xF3F3F3, dark: 0x6C6E72)
    static let btnStepTop    = hex(0xE5E5E5, dark: 0x45474B)
    static let btnStepBottom = hex(0xF6F6F6, dark: 0x6D6F73)
    static let btnGlyph      = hex(0x3B3B3B, dark: 0xDCDDDF)

    // Volume slider
    static let volGlyph        = hex(0x3F3F3F, dark: 0xC9CACD)
    static let volGrooveTop    = hex(0x616161, dark: 0x0B0C0D)
    static let volGrooveBottom = hex(0xE4E4E4, dark: 0x5E6064)
    static let volKnobDimple   = hex(0x4D4D4D, dark: 0x232426)
    static let volKnobRim      = hex(0x626262, dark: 0x111213)
    static let volKnobTop      = hex(0xDADADA, dark: 0x5C5E62)
    static let volKnobBottom   = hex(0xECECEC, dark: 0x74767A)
    /// The knob's lowest row, where its curve faces the light.
    static let volKnobGlint    = hex(0xFFFFFF, dark: 0x8E9094)

    // LCD status display. Dark is the panel's night mode: a negative LCD, dark olive glass with
    // the characters lit, and the light the characters give off is the light panel's own sage.
    static let lcdBG             = hex(0xD7DBC0, dark: 0x181B12)
    static let lcdBorderTop      = hex(0x7F8173, dark: 0x040503)
    static let lcdBorderSide     = hex(0x999C8B, dark: 0x23261B)
    static let lcdInnerHighlight = hex(0xE6E8DA, dark: 0x3E4334)
    static let lcdOuterBottom    = hex(0xBDBCC1, dark: 0x5A5C61)
    static let lcdScrubOutline   = hex(0x161810, dark: 0xC5CBA6)
    /// The LCD's text. Light: the chrome's text color. Dark: `lcdBG`'s light value, lit.
    static let lcdInk            = hex(0x1A1A1A, dark: 0xD7DBC0)

    // Search capsule. Dark: a hole down to the lists' level.
    static let searchFill        = hex(0xFFFFFF, dark: 0x1C1D20)
    static let searchBorderTop   = hex(0x686868, dark: 0x08090A)
    static let searchBorderBottom = hex(0xADADAD, dark: 0x5A5C60)
    static let searchInnerTop    = hex(0xE4E4E4, dark: 0x111214)
    static let searchInnerBottom = hex(0xE3E3E3, dark: 0x1F2023)

    // Lists. Dark stripes keep the light stripe's blue cast.
    static let listBG     = hex(0xFFFFFF, dark: 0x1E1F22)
    static let rowStripe  = hex(0xECF3FE, dark: 0x24272E)

    // Source list selection: vertical gradient
    static let srcSelTop        = hex(0x69A7EE, dark: 0x4F8CDB)
    static let srcSelBottom     = hex(0x2972D8, dark: 0x1E58B5)
    static let srcSelEdgeTop    = hex(0x5D8DC6, dark: 0x3E73BC)
    static let srcSelEdgeBottom = hex(0x3A6EBD, dark: 0x18478F)
    static let srcSelOffTop     = hex(0x989898, dark: 0x5B5D61)
    static let srcSelOffBottom  = hex(0x666666, dark: 0x3B3D41)

    // Track list selection: FLAT, with a 1 px bottom edge
    static let trkSel        = hex(0x3C80DF, dark: 0x2C6BCB)
    static let trkSelEdge    = hex(0x7CADE7, dark: 0x4F86D6)
    /// Chosen, not measured (RESEARCH.md §10-R9).
    static let trkSelOff     = hex(0x8E8E8E, dark: 0x46484C)
    static let trkSelOffEdge = hex(0xA8A8A8, dark: 0x57595D)

    // Headers, panes, splitter
    static let colSep         = hex(0xC0C0C0, dark: 0x26272A)
    static let paneBorderSrcL = hex(0x666666, dark: 0x111214)
    static let paneBorderSrcR = hex(0x646464, dark: 0x111214)
    static let paneBorderTrkL = hex(0x65666A, dark: 0x111215)
    static let paneBorderTrkR = hex(0x686868, dark: 0x121315)
    static let splitterCore   = hex(0xAFB0B4, dark: 0x24262C)

    // Aqua scroller. The knob stays Aqua blue in the dark, a little deeper.
    static let scrollTroughEdge   = hex(0xBFBFBD, dark: 0x111214)
    static let scrollTroughCenter = hex(0xFCFCFC, dark: 0x2E3033)
    static let scrollKnobRim      = hex(0x2462B5, dark: 0x1A4C92)
    static let scrollKnobMid      = hex(0x2976DE, dark: 0x2A6FD0)
    static let scrollKnobHi       = hex(0x72B7FF, dark: 0x5FA4F2)

    // Bottom bar
    static let footHighlight = hex(0xF0F0F0, dark: 0x5E6064)
    static let bevelBorder   = hex(0x666666, dark: 0x111214)
    static let bevelFill     = hex(0xCCCCCC, dark: 0x4A4C50)

    // Text
    static let textPrimary     = hex(0x1A1A1A, dark: 0xDEDFE1)
    static let textOnSelection = hex(0xFFFFFF)
    static let textDimmed      = hex(0x999999, dark: 0x85878B)

    // MARK: - Gradients (§7.1, §7.3)

    /// Brushed metal is HORIZONTAL: dark edges, light centre, identical at every y.
    /// Draw across the full window width with `draw(in:angle: 0)`.
    static var metal: NSGradient { metals.current }
    private static let metals = themed {
        NSGradient(colors: [metalEdge, metalCenter, metalEdge], atLocations: [0, 0.5, 1], colorSpace: .sRGB)!
    }

    /// Source / Genre / Artist / Album pane headers, top to bottom.
    static var paneHeader: NSGradient { paneHeaders.current }
    private static let paneHeaders = Themed(light: NSGradient(starting: hex(0xE9E9E9), ending: hex(0x8C8C8C))!,
                                            dark: NSGradient(starting: hex(0x56585C), ending: hex(0x2B2C2F))!)

    /// Track column header, normal: bright, dipping at 50%, bright again. Top to bottom.
    static var columnHeader: NSGradient { columnHeaders.current }
    private static let columnHeaders = Themed(
        light: stops([0xFFFFFF, 0xF5F5F5, 0xF1F1F1, 0xEFEFEF, 0xE9E9E9, 0xF2F2F2, 0xFDFDFD, 0xFEFEFE],
                     [0, 0.14, 0.28, 0.42, 0.5, 0.64, 0.82, 1]),
        dark: stops([0x4C4E52, 0x46484C, 0x434549, 0x414347, 0x3C3E42, 0x424448, 0x494B4F, 0x4B4D51],
                    [0, 0.14, 0.28, 0.42, 0.5, 0.64, 0.82, 1]))

    /// Track column header, sorted column: same shape in blue. Top to bottom.
    static var columnHeaderSorted: NSGradient { columnHeadersSorted.current }
    private static let columnHeadersSorted = Themed(
        light: stops([0xCFE1F5, 0x97C1E5, 0x8FB9E9, 0x86B9E6, 0x6FA6E6, 0x7DBBF4, 0x86C7FF, 0x9DD7FF, 0xB4EDFA],
                     [0, 0.12, 0.25, 0.37, 0.5, 0.62, 0.75, 0.87, 1]),
        dark: stops([0x5279AA, 0x34619B, 0x305E9C, 0x2E5D9A, 0x26518F, 0x2D60A3, 0x3369AE, 0x3D76BA, 0x4985C6],
                    [0, 0.12, 0.25, 0.37, 0.5, 0.62, 0.75, 0.87, 1]))

    static var sourceSelection: NSGradient { sourceSelections.current }
    private static let sourceSelections = themed { NSGradient(starting: srcSelTop, ending: srcSelBottom)! }
    static var sourceSelectionOff: NSGradient { sourceSelectionsOff.current }
    private static let sourceSelectionsOff = themed { NSGradient(starting: srcSelOffTop, ending: srcSelOffBottom)! }

    // MARK: - Metrics in points (§7.2)

    enum Metrics {
        static let referenceWindow = NSSize(width: 756, height: 500)
        static let minimumWindow   = NSSize(width: 640, height: 400)
        static let windowCornerRadius: CGFloat = 5

        static let titleBarHeight: CGFloat   = 27   // y 1..27
        static let controlBarHeight: CGFloat = 64   // y 28..91
        static let headerHeight: CGFloat     = 92   // title + control bar, then a 1 px rule

        static let trafficLightDiameter: CGFloat = 14
        static let trafficLightCentersX: [CGFloat] = [16.5, 37.5, 58.5]
        static let trafficLightCenterY: CGFloat = 12.5

        static let transportCenterY: CGFloat  = 47
        static let backButton    = (diameter: CGFloat(29), centerX: CGFloat(42))
        static let playButton    = (diameter: CGFloat(37), centerX: CGFloat(79))
        static let forwardButton = (diameter: CGFloat(29), centerX: CGFloat(116))
        static let pauseBarWidth: CGFloat = 6
        static let pauseBarGap: CGFloat   = 3

        static let volumeCenterY: CGFloat = 75
        static let volumeGrooveX: ClosedRange<CGFloat> = 39...116
        static let volumeGrooveHeight: CGFloat = 6
        static let volumeKnobDiameter: CGFloat = 12

        /// Centred horizontally on the window. 313 is the narrowest it gets with room to spare;
        /// ControlBarView widens it with the window (RESEARCH.md errata, 7.2).
        static let lcdSize = NSSize(width: 313, height: 48)
        static let lcdTop: CGFloat = 28
        static let lcdLine1Baseline: CGFloat = 43
        static let lcdLine2Baseline: CGFloat = 57
        static let lcdEndButtonDiameter: CGFloat = 13
        static let scrubberSize = NSSize(width: 240, height: 9)
        static let scrubberTop: CGFloat = 60
        static let scrubberThumb: CGFloat = 7

        /// 103 is the narrowest; ControlBarView widens it with the window, leftward from its right end.
        static let searchSize = NSSize(width: 103, height: 22)
        static let searchTop: CGFloat = 38
        /// Distance from the window's right edge to the search field's right edge (756 - 677).
        static let searchRightInset: CGFloat = 79
        static let searchLabelBaseline: CGFloat = 78
        /// Browse button: centre is this far from the window's right edge (756 - 711).
        static let browseButton = (diameter: CGFloat(37), rightInsetToCenter: CGFloat(45))

        static let leftGutter: CGFloat  = 15
        static let rightGutter: CGFloat = 14
        static let sourcePaneWidth: CGFloat = 158
        static let sourcePaneWidthRange: ClosedRange<CGFloat> = 120...400
        static let splitterWidth: CGFloat = 9

        static let columnHeaderHeight: CGFloat = 15
        static let sourceRowHeight: CGFloat = 18
        static let trackRowHeight: CGFloat  = 17
        static let intercellSpacing = NSSize(width: 3, height: 0)
        static let sourceIconSize: CGFloat = 16
        static let sourceIconLeft: CGFloat = 14   // from the pane's left edge
        static let sourceTextLeft: CGFloat = 33   // from the pane's left edge
        static let indicatorColumnWidth: CGFloat = 18

        static let scrollerWidth: CGFloat = 15
        static let scrollArrowPairHeight: CGFloat = 32

        static let bottomBarHeight: CGFloat = 34
        static let bottomButtonSize = NSSize(width: 31, height: 22)
        static let bottomButtonPitch: CGFloat = 39
        static let bottomButtonTopInset: CGFloat = 7   // y 472 - 465
        static let bottomLeftGroupFirstX: CGFloat = 22
        static let bottomRightGroupRightInset: CGFloat = 31 // 756 - 725
        static let resizeGripSize = NSSize(width: 27, height: 26)

        static let browserSplitterHeight: CGFloat = 11
        static let browserDefaultFraction: CGFloat = 0.4
    }

    // MARK: - Typography (§7.5)

    /// Lucida Grande 11: rows, headers, LCD, labels, summary.
    static let font = makeFont("LucidaGrande", 11)
    /// Lucida Grande Bold 11: "All (N …)" browser rows and emphasis.
    static let boldFont = makeFont("LucidaGrande-Bold", 11)
    /// Lucida Grande 11, regular: Source / Genre / Artist / Album pane headers. iTunes 4.9 drew them
    /// in regular weight (pixel-checked against the reference during review).
    static let paneHeaderFont = makeFont("LucidaGrande", 11)
    /// Lucida Grande 13, regular: window title. Measured against the 1x reference, where "iTunes"
    /// inks 40x10 px; regular 13 renders 40x10, regular 12 and bold 12 do not.
    static let titleFont = makeFont("LucidaGrande", 13)
    /// Monaco 11: Get Info technical block.
    static let monoFont = NSFont(name: "Monaco", size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .regular)

    /// There is NO Lucida Grande italic. Never request one.
    private static func makeFont(_ name: String, _ size: CGFloat) -> NSFont {
        NSFont(name: name, size: size)
            ?? NSFont(name: name.hasSuffix("Bold") ? "HelveticaNeue-Bold" : "HelveticaNeue", size: size)
            ?? (name.hasSuffix("Bold") ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size))
    }

    static func textAttributes(_ font: NSFont = Theme.font, color: NSColor = Theme.textPrimary,
                               alignment: NSTextAlignment = .left) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byTruncatingTail
        return [.font: font, .foregroundColor: color, .paragraphStyle: style]
    }

    // MARK: - Light and dark

    /// True while drawing for the dark appearance. Inside `draw(_:)` AppKit has made the view's
    /// own appearance current. Anywhere else this may not follow the app: launched with `open`,
    /// it stays the Mac's own appearance even after `NSApp.appearance` is set (seen on macOS 27).
    /// Outside drawing, read a window's `effectiveAppearance`, and resolve Theme colors inside
    /// its `performAsCurrentDrawingAppearance`.
    static var isDark: Bool { NSAppearance.currentDrawing().isDark }

    /// One value per appearance, for what a dynamic color cannot carry: gradients (macOS 27
    /// happens to re-resolve their colors at draw time; nothing documents it) and other drawing
    /// parameters.
    @MainActor
    struct Themed<Value> {
        let light: Value
        let dark: Value
        var current: Value { Theme.isDark ? dark : light }
    }

    /// Builds `build` once under each appearance, so the theme colors it reads (and anything
    /// that resolves them, like `blended(withFraction:of:)`) come out right for each.
    static func themed<Value>(_ build: () -> Value) -> Themed<Value> {
        var light: Value?, dark: Value?
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance { light = build() }
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance { dark = build() }
        guard let light, let dark else { preconditionFailure("the Aqua appearances are always present") }
        return Themed(light: light, dark: dark)
    }

    /// A color worked out from other theme colors (a blend, a shade), as a dynamic color.
    /// `blended(withFraction:of:)` resolves a dynamic color once, so it is run once per appearance.
    static func derived(_ build: () -> NSColor) -> NSColor {
        let pair = themed { build().usingColorSpace(.sRGB) ?? build() }
        return color(pair.light, dark: pair.dark)
    }

    /// The same value in both appearances.
    nonisolated static func hex(_ value: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    /// A light value and a dark one, as one color AppKit resolves at draw time.
    nonisolated static func hex(_ light: Int, dark: Int) -> NSColor {
        color(hex(light), dark: hex(dark))
    }

    nonisolated static func color(_ light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.isDark ? dark : light }
    }

    private static func stops(_ colors: [Int], _ locations: [CGFloat]) -> NSGradient {
        var locations = locations
        return NSGradient(colors: colors.map(hex), atLocations: &locations, colorSpace: .sRGB)!
    }

    /// One device pixel, so hairlines stay hairlines on Retina.
    static func hairline(for view: NSView) -> CGFloat {
        1 / (view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
    }
}

extension NSAppearance {
    /// Dark Aqua, or a high-contrast or vibrant variant of it.
    nonisolated var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}
