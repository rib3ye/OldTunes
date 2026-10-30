import AppKit

/// Values the lists need that Theme.swift does not name. Theme is shared and owned elsewhere, so
/// these live here; each is derived from a Theme token or was sampled from
/// scratchpad/itunes_refs/itunes_old_big.jpg where Theme's tokens cannot describe the shape
/// (the scroller gel is a five-stop profile; Theme has three knob tokens). Dark values are the
/// Graphite theme's (RESEARCH.md §7.7): same shapes, set into the darker wells.
@MainActor
enum ListsPalette {

    // MARK: Rules and separators

    /// Horizontal rules above and below every header row: Theme's rule (#666666–#676767 at
    /// y 93 and y 109 across both panes).
    static let headerRule = Theme.rule
    /// The faint line above a recessed pane's top rule. Same value as the chrome frame's
    /// (ChromePalette.recessShadow), repeated here so the lists never depend on the chrome module.
    static let recessShadow = Theme.color(.black.withAlphaComponent(0.13), dark: .black.withAlphaComponent(0.35))
    /// Vertical column lines running down through the track rows, under each header separator.
    /// Sampled #D9D9D9–#DDDDDD on white and #D6D9E0 on the stripe at x 203, 479, 538, 663.
    static let rowColumnLine = Theme.hex(0xD9D9D9, dark: 0x2C2E33)
    /// The same line over a selected row: the selection darkened, sampled #3982C7 over the blue.
    static func rowColumnLine(onSelection color: NSColor) -> NSColor {
        color.blended(withFraction: 0.14, of: .black) ?? color
    }

    /// The column-header sort triangle. Sampled #344A62 over the blue header; on the dark blue
    /// header it turns pale, the same contrast the other way round.
    static let sortTriangle = Theme.hex(0x344A62, dark: 0xD5E2F2)
    /// Disclosure triangles in the source list ("Kermit" row in the reference).
    static let disclosure = Theme.hex(0x6E6E6E, dark: 0x9A9CA0)
    /// Unfocused source selection's 1 px top edge, sampled #7D7D7D above the #939393 → #676767
    /// gradient (the reference's Library row). Its bottom has no separate edge.
    static let sourceSelectionOffEdgeTop = Theme.hex(0x7D7D7D, dark: 0x4E5054)
    /// The cloud badge on cloud-only rows; the same gray as the reference's row arrow circles.
    static let cloudBadge = Theme.hex(0x9A9A9A, dark: 0x7A7C81)
    /// The badge while Music downloads the song: the same cloud in blue. iTunes 4.9 never
    /// downloaded, so there is no reference for it; this is OldTunes's stand-in (RESEARCH.md
    /// §7.4). By day the 4.9 selection blue, Theme.trkSel. By night the checked box's own blue,
    /// AquaStyle.blueGel's band above its middle: trkSel's night value, drawn this small, read
    /// more violet than the checked box beside it and the sorted column above it (RESEARCH.md §7.7).
    static let cloudRequested = Theme.hex(0x3C80DF, dark: 0x4A84D0)

    // MARK: Drop feedback

    /// The 2 pt outline round a playlist while songs are dragged over it. No 4.9 reference shows
    /// one, so it is OldTunes's stand-in too, in the same blues as `cloudRequested` (RESEARCH.md
    /// §7.4, §7.7).
    static let sourceDropOutline = Theme.hex(0x3C80DF, dark: 0x4A84D0)

    // MARK: Aqua scroller

    /// Trough, across its thickness (left→right vertical, top→bottom horizontal). Sampled at
    /// x 737..751: #B9 #C8 #DD #EA #F6 #FC (70%) #F9 #EF — Theme's edge and centre at the ends.
    static var trough: NSGradient { troughs.current }
    private static let troughs = Theme.Themed(
        light: gradient([Theme.scrollTroughEdge, Theme.hex(0xD2D2D2), Theme.hex(0xEAEAEA),
                         Theme.scrollTroughCenter, Theme.hex(0xEFEFEF)], [0, 0.2, 0.43, 0.72, 1]),
        dark: gradient([Theme.scrollTroughEdge, Theme.hex(0x1A1B1E), Theme.hex(0x232528),
                        Theme.scrollTroughCenter, Theme.hex(0x26282B)], [0, 0.2, 0.43, 0.72, 1]))
    /// What shows outside the trough's rounded ends.
    static let troughOuter = Theme.hex(0xEFEFEF, dark: 0x1E1F22)
    /// The shade in the trough's rounded ends, darkest at the very end.
    static let troughEndShade = Theme.color(.black.withAlphaComponent(0.22), dark: .black.withAlphaComponent(0.45))

    /// Arrow buttons, across: a bright band, a soft crease at the centre line, bright again.
    /// Sampled at y 432: #B9 #D2 #F3 #FC #F6 | #E0 | #EC #FB #FD #F0.
    static var arrowFill: NSGradient { arrowFills.current }
    static var arrowFillPressed: NSGradient { arrowFillsPressed.current }
    private static let arrowStops: [CGFloat] = [0, 0.14, 0.3, 0.5, 0.72, 0.86, 1]
    private static let arrowFills = Theme.Themed(
        light: gradient([0xB9B9B9, 0xF3F3F3, 0xFCFCFC, 0xE2E2E2, 0xFBFBFB, 0xFDFDFD, 0xF0F0F0].map(Theme.hex), arrowStops),
        dark: gradient([0x2B2C2F, 0x45474B, 0x4D4F53, 0x3B3D41, 0x4A4C50, 0x4E5054, 0x424448].map(Theme.hex), arrowStops))
    private static let arrowFillsPressed = Theme.Themed(
        light: gradient([0x8C8C8C, 0xB4B4B4, 0xBEBEBE, 0xA8A8A8, 0xBCBCBC, 0xBEBEBE, 0xB2B2B2].map(Theme.hex), arrowStops),
        dark: gradient([0x1E1F22, 0x2F3134, 0x353739, 0x2A2C2F, 0x333538, 0x353739, 0x2E3033].map(Theme.hex), arrowStops))
    /// Between the two arrows (#9D9D9D at y 434) and at the bottom end (#BEBEBE at y 450).
    static let arrowSeparator = Theme.hex(0x9D9D9D, dark: 0x141517)
    static let arrowGlyph = Theme.hex(0x444444, dark: 0xCDCED1)

    /// The gel knob, across its thickness: a pale band, a sharp dip to the mid blue just before
    /// the centre, then a glow toward the far edge. Sampled at y 250, x 739..749:
    /// #80A7EA #90BBE3 #92BDE8 #8CB5EA | #5196E4 | #62A3F5 #72B7FF #83C4FC #8ED5FF #9EDFFF #98D8FE.
    /// #72B7FF is Theme.scrollKnobHi exactly; the dip is Theme's mid lifted toward it. The dark
    /// knob is the same gel a step deeper, so it reads as lit without glaring out of the trough.
    static var knobGel: NSGradient { knobGels.current }
    private static let knobStops: [CGFloat] = [0, 0.2, 0.33, 0.42, 0.58, 0.75, 0.9, 1]
    private static let knobGels = Theme.themed {
        let dip = Theme.scrollKnobMid.blended(withFraction: 0.4, of: Theme.scrollKnobHi) ?? Theme.scrollKnobMid
        let band = Theme.isDark ? [0x5A82C6, 0x6A95D2, 0x668FD2] : [0x80A7EA, 0x92BDE8, 0x8CB5EA]
        let glow = Theme.isDark ? [0x6CB0F0, 0x7ABDF2, 0x76B7EE] : [0x8ED5FF, 0x9EDFFF, 0x98D8FE]
        return gradient(band.map(Theme.hex) + [dip, Theme.scrollKnobHi] + glow.map(Theme.hex), knobStops)
    }
    static let knobRim = Theme.scrollKnobRim
    /// Faint Aqua pinstripes across the knob, every 4 pt along its length.
    static let knobPinstripe = Theme.color(.white.withAlphaComponent(0.07), dark: .white.withAlphaComponent(0.05))

    // MARK: Headers

    /// Pane headers ("Source", "Genre", …) use Theme.paneHeader; this is their text color.
    static let paneHeaderText = Theme.textPrimary

    // MARK: Browser splitter

    /// Its recessed dimple, like the 10.4 split-view knob: dark upper-left, light lower-right.
    static let splitterDimpleTop = Theme.hex(0x6E6E6E, dark: 0x0E0F10)
    static let splitterDimpleBottom = Theme.hex(0xD8D8D8, dark: 0x5A5C60)
    static let splitterDimpleRim = Theme.hex(0x8A8A8A, dark: 0x1A1B1D)

    // MARK: Formatting

    /// m:ss under an hour, h:mm:ss over, like iTunes' Time column.
    nonisolated static func time(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// One formatter for every Date Added cell; DateFormatter is expensive to create.
    static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()

    private static func gradient(_ colors: [NSColor], _ locations: [CGFloat]) -> NSGradient {
        var locations = locations
        return NSGradient(colors: colors, atLocations: &locations, colorSpace: .sRGB)!
    }
}
