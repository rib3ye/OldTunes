import AppKit

/// Shades the chrome derives from Theme. Theme holds what was measured; these are the in-between
/// tones the 2005 art used for gloss, emboss and pressed states, which the measurement could not
/// isolate as single values. Each one is a blend of a Theme color (or plain white/black light and
/// shadow), so changing Theme carries through.
///
/// The dark values keep the 2005 lighting: one light, from above. Graphite reflects less of it,
/// so every highlight is fainter and every shadow deeper, but they fall in the same places.
@MainActor
enum ChromePalette {
    /// The light lip under anything raised or recessed into the metal. 2005 metal was lit from
    /// above, so every edge facing down caught a highlight.
    static let emboss = Theme.color(.white.withAlphaComponent(0.5), dark: .white.withAlphaComponent(0.11))
    /// The lip that made 2005 labels on metal ("Search", "Browse", the title, the summary) look
    /// engraved. Light: a faint light line 1 pt under dark letters — a lip, not a second copy of
    /// the text. Dark: light letters cannot take a light lip, so the groove's other wall shows
    /// instead, a dark line 1 pt above (`engraveOffset`).
    static let engrave = Theme.color(.white.withAlphaComponent(0.4), dark: .black.withAlphaComponent(0.55))
    /// Which way the engraving lip sits from the letters, in flipped points: below, or above.
    static var engraveOffset: CGFloat { Theme.isDark ? -1 : 1 }
    /// The dark line above a recessed pane, the counterpart of `emboss`.
    static let recessShadow = Theme.color(.black.withAlphaComponent(0.13), dark: .black.withAlphaComponent(0.35))
    /// Side highlights of the recessed panes read a little dimmer than the bottom one (§7.1 gives
    /// only the bottom: `footHighlight`).
    static let paneSideHighlight = Theme.footHighlight.withAlphaComponent(0.8)

    /// Lit toggle glyphs (shuffle, repeat, equalizer) were Aqua blue. On graphite the knob's mid
    /// blue is too dark to read as lit, so the dark glyph is a brighter Aqua.
    static let lit = Theme.color(Theme.scrollKnobMid, dark: Theme.hex(0x5AA4FF))
    /// The Tiger focus ring was a soft Aqua-blue glow, not a modern hard ring.
    static let focusGlow = Theme.scrollKnobHi

    /// The LCD's two end buttons are a darker olive than the recess rim. At night the panel is
    /// negative, so they are a dimmer sage than the lit text, with glyphs cut in the glass color.
    static let lcdEndButton = Theme.derived {
        Theme.isDark ? Theme.hex(0x8E9478) : mix(Theme.lcdBorderTop, .black, 0.15)
    }
    /// Held down, they darken like the gel buttons do.
    static let lcdEndButtonPressed = Theme.derived { mix(lcdEndButton, .black, pressedDarkening) }
    /// The shade just under the LCD's top rim, so the panel reads as sunk into the metal.
    static let lcdInnerShadow = Theme.color(Theme.lcdBorderSide.withAlphaComponent(0.75),
                                            dark: .black.withAlphaComponent(0.7))
    /// The night LCD's lit characters bleed a little light into the glass around them, the way
    /// a backlit negative display does. Light mode has no glow: the panel itself is the light.
    static var lcdGlow: NSShadow? { Theme.isDark ? lcdGlows.text : nil }
    /// The scrubber's 1 pt outline glows less, so the line stays a line.
    static var lcdScrubberGlow: NSShadow? { Theme.isDark ? lcdGlows.scrubber : nil }
    private static let lcdGlows = (text: glow(alpha: 0.9, blur: 3.5), scrubber: glow(alpha: 0.45, blur: 2))
    /// The night glass is lit from behind, a little more in the middle than at the ends, like any
    /// backlit panel. Drawn as an ellipse the width of the panel; nil by day.
    static var lcdBacklight: NSGradient? { Theme.isDark ? lcdBacklights : nil }
    private static let lcdBacklights = NSGradient(colors: [Theme.hex(0x2A2F1F).withAlphaComponent(0.85),
                                                           Theme.hex(0x2A2F1F).withAlphaComponent(0)],
                                                  atLocations: [0, 1], colorSpace: .sRGB)

    private static func glow(alpha: CGFloat, blur: CGFloat) -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = Theme.hex(0xC8D38E).withAlphaComponent(alpha)
        shadow.shadowOffset = .zero
        shadow.shadowBlurRadius = blur
        return shadow
    }

    /// Gel interiors darken this much while the mouse is down.
    static let pressedDarkening: CGFloat = 0.2

    // MARK: Buttons on graphite
    //
    // Brushed metal is matte, so at night its lips and lines go faint. Gel and bevel buttons are
    // glossy, and dark gloss shows its reflections MORE, not less (the black iPod nano): reflected
    // light does not depend on the color under it, and on a dark base it has more contrast. So by
    // night the buttons keep strong gloss and sit in a visible well, while the metal stays quiet.
    // Every value below is the 2005 one by day, or nil where 2005 drew nothing.

    /// The light sweep across a round gel button's lower half (top and bottom of the sweep,
    /// at rest and pressed).
    static var gelSweep: (top: CGFloat, bottom: CGFloat, pressedTop: CGFloat, pressedBottom: CGFloat) {
        Theme.isDark ? (0.22, 0.05, 0.09, 0.02) : (0.6, 0.2, 0.25, 0.1)
    }
    /// The rim light: the top edge of a dark gel cap catching the light above it, a crescent inside
    /// the ring that fades out toward the cap's middle (white alpha at rest and pressed).
    static var gelRimLight: (rest: CGFloat, pressed: CGFloat)? { Theme.isDark ? (0.34, 0.12) : nil }
    /// The lip under a button's well. By day it is `emboss`.
    static let buttonLip = Theme.color(.white.withAlphaComponent(0.5), dark: .white.withAlphaComponent(0.2))
    /// The well's upper wall, in shadow above each button.
    static var buttonWellShadow: NSColor? { Theme.isDark ? .black.withAlphaComponent(0.45) : nil }
    /// Light glyphs on a graphite button are engraved like graphite labels: a dark line 1 pt above.
    static var glyphEngrave: NSColor? { Theme.isDark ? .black.withAlphaComponent(0.4) : nil }

    /// The Browse button's eye is a picture, not chrome, so it keeps its own ink in both modes;
    /// at night only its white is dimmed, so it does not glare out of the graphite.
    static let eyeWhite = Theme.hex(0xFFFFFF, dark: 0xE2E2E2)
    static let eyeInk = Theme.hex(0x1A1A1A)
    static let eyeIrisRim = Theme.hex(0x3B3B3B).withAlphaComponent(0.55)

    /// The splitter's dimple: dark upper-left, mid, bright lower-right.
    static let dimpleShadow = Theme.hex(0x1A1A1A, dark: 0x050506)
    static let dimpleLight = Theme.hex(0xFFFFFF, dark: 0x6E7074)

    /// Bottom-bar bevel button interior, top to bottom, from the reference: a white lip under the
    /// border, then a soft ramp down to `bevelFill`, then a darker band just above the bottom border.
    /// Graphite keeps the shape and a bright lip: like the gel, the bevel is glossy (see above).
    static var bevelInterior: NSGradient? { bevelInteriors.current }
    static var bevelInteriorPressed: NSGradient? { bevelInteriorsPressed.current }
    private static let bevelInteriors = Theme.themed { makeBevelInterior(pressed: false) }
    private static let bevelInteriorsPressed = Theme.themed { makeBevelInterior(pressed: true) }

    private static func makeBevelInterior(pressed: Bool) -> NSGradient? {
        let fill = Theme.bevelFill
        let colors = Theme.isDark
            ? [mix(fill, .white, 0.42), mix(fill, .white, 0.2), mix(fill, .white, 0.04), mix(fill, .black, 0.22),
               mix(fill, .black, 0.38)]
            : [mix(fill, .white, 0.9), mix(fill, .white, 0.55), fill, mix(fill, .black, 0.15), mix(fill, .black, 0.27)]
        let shaded = pressed ? colors.map { mix($0, .black, pressedDarkening) } : colors
        return NSGradient(colors: shaded, atLocations: [0, 0.14, 0.78, 0.92, 1], colorSpace: .sRGB)
    }

    /// Resolves both colors for the appearance drawing now. Call it while drawing, or inside
    /// `Theme.derived`/`Theme.themed`, never to make a stored color.
    static func mix(_ color: NSColor, _ other: NSColor, _ fraction: CGFloat) -> NSColor {
        let target = other.usingColorSpace(.sRGB) ?? other
        return color.usingColorSpace(.sRGB)?.blended(withFraction: fraction, of: target) ?? color
    }
}
