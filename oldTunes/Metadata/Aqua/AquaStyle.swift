import AppKit

/// Mac OS X 10.4 "Aqua" for the Get Info window, which in iTunes 4.9 was a plain pinstriped
/// dialog, not brushed metal. Every stock control on macOS 27 draws as Liquid Glass with no
/// opt-out (RESEARCH.md §8.1), so the gel buttons, tabs, checkboxes and field bezels are all
/// painted here. Colors live in this one place so the look can be tuned without hunting.
///
/// Dark values are Graphite (RESEARCH.md §7.7): charcoal pinstripes, graphite gel where 10.4 had
/// white gel, and Aqua blue kept for what is chosen, pressed or default.
@MainActor
enum AquaStyle {

    // MARK: - Window

    /// Pinstripes: 2 pt light, 2 pt dark — 4 px at 1x, which is what 2005 eyes remember.
    static let stripeLight = Theme.hex(0xEEEEEE, dark: 0x2B2C2F)
    static let stripeDark  = Theme.hex(0xE7E7E7, dark: 0x27282B)
    static let titleBarHeight: CGFloat = 22
    static let titleTop    = Theme.hex(0xEDEDED, dark: 0x48494D)
    static let titleBottom = Theme.hex(0xD3D3D3, dark: 0x343538)
    static let titleRule   = Theme.hex(0xA9A9A9, dark: 0x131416)
    /// The 1 pt highlight along the title bar's top edge, and the faint stripes through it.
    static let titleTopEdge = Theme.hex(0xF8F8F8, dark: 0x5C5E62)
    static let titleStripe = Theme.color(.white.withAlphaComponent(0.18), dark: .white.withAlphaComponent(0.035))
    /// The title bar's disabled traffic lights: hollow pale gel, or hollow graphite.
    static let orbDisabled = Theme.hex(0xD9D9D9, dark: 0x55575B)
    static let orbDisabledRim = Theme.hex(0x9E9E9E, dark: 0x2A2B2E)
    /// The title-bar orbs' shadow, a shade lighter than the controls' `gelShadow`.
    static let orbShadow = Theme.color(NSColor(white: 0, alpha: 0.12), dark: NSColor(white: 0, alpha: 0.3))
    /// How far a disabled orb's lower half glows toward white, and its specular cap's alpha.
    /// Graphite orbs glow less, or they read as lit marbles.
    static var orbDisabledGlow: CGFloat { Theme.isDark ? 0.18 : 0.5 }
    static var orbDisabledCap: CGFloat { Theme.isDark ? 0.4 : 0.85 }
    static let titleFont   = NSFont(name: "LucidaGrande", size: 13) ?? .systemFont(ofSize: 13)

    // MARK: - Type

    static let controlFont = NSFont(name: "LucidaGrande", size: 13) ?? .systemFont(ofSize: 13)
    static let smallFont   = Theme.font                                  // Lucida Grande 11
    static let smallBold   = Theme.boldFont
    static let titleBold13 = NSFont(name: "LucidaGrande-Bold", size: 13) ?? .boldSystemFont(ofSize: 13)
    static let tinyFont    = NSFont(name: "LucidaGrande", size: 10) ?? .systemFont(ofSize: 10)
    static let text        = Theme.textPrimary
    static let textDisabled = Theme.hex(0x9A9A9A, dark: 0x6A6C70)
    static let noteText    = Theme.hex(0x4A4A4A, dark: 0xA3A5A9)

    // MARK: - Boxes and fields

    static let boxFillLight  = Theme.hex(0xE5E5E5, dark: 0x232427)
    static let boxFillDark   = Theme.hex(0xDFDFDF, dark: 0x202124)
    static let boxBorder     = Theme.hex(0x9B9B9B, dark: 0x111214)
    static let boxBorderTop  = Theme.hex(0x868686, dark: 0x0B0C0D)
    static let boxInnerShade = Theme.hex(0xCFCFCF, dark: 0x0D0E0F)
    static let fieldFill     = Theme.hex(0xFFFFFF, dark: 0x17181A)
    static let fieldBorder   = Theme.hex(0xA0A0A0, dark: 0x4A4C50)
    static let fieldBorderTop = Theme.hex(0x777777, dark: 0x08090A)
    static let fieldInnerTop = Theme.hex(0xDDDDDD, dark: 0x0F1012)
    static let focusRing     = Theme.hex(0x5F94DA, dark: 0x4C8FEA)
    static let textSelection = Theme.hex(0xB5D5FF, dark: 0x2E5A92)
    static let etchDark      = Theme.hex(0xA8A8A8, dark: 0x141517)
    static let etchLight     = Theme.hex(0xFAFAFA, dark: 0x3F4145)
    /// The soft shadow every gel casts on the window, 1 pt down.
    static let gelShadow     = Theme.color(NSColor(white: 0, alpha: 0.13), dark: NSColor(white: 0, alpha: 0.35))

    // MARK: - Gel

    /// The two halves of an Aqua gel: a bright upper lobe and a deeper lower band that glows
    /// again at the bottom edge, plus a separate specular highlight. Values picked against
    /// period screenshots; the hard step at 50% is the signature, so it is kept sharp.
    struct Gel {
        var rimTop: NSColor, rimBottom: NSColor
        var top: NSColor, midTop: NSColor, midBottom: NSColor, bottom: NSColor
        var highlight: CGFloat

        func blended(with other: Gel, fraction f: CGFloat) -> Gel {
            guard f > 0 else { return self }
            func mix(_ a: NSColor, _ b: NSColor) -> NSColor { a.blended(withFraction: f, of: b) ?? a }
            return Gel(rimTop: mix(rimTop, other.rimTop), rimBottom: mix(rimBottom, other.rimBottom),
                       top: mix(top, other.top), midTop: mix(midTop, other.midTop),
                       midBottom: mix(midBottom, other.midBottom), bottom: mix(bottom, other.bottom),
                       highlight: highlight + (other.highlight - highlight) * f)
        }
    }

    /// Six hex values (rim top, rim bottom, body top, mid top, mid bottom, body bottom) and the
    /// highlight's alpha.
    private static func gel(_ v: [Int], _ highlight: CGFloat) -> Gel {
        let c = v.map(Theme.hex)
        return Gel(rimTop: c[0], rimBottom: c[1], top: c[2], midTop: c[3], midBottom: c[4], bottom: c[5],
                   highlight: highlight)
    }

    /// The plain control gel. In the dark it is graphite: darker glass that catches less light.
    static var whiteGel: Gel { whiteGels.current }
    private static let whiteGels = Theme.Themed(
        light: gel([0x939393, 0x6B6B6B, 0xFFFFFF, 0xF3F3F3, 0xE2E2E2, 0xFDFDFD], 0.55),
        dark: gel([0x18191B, 0x0C0D0E, 0x6C6E72, 0x57595D, 0x46484C, 0x5F6165], 0.22))
    static var blueGel: Gel { blueGels.current }
    private static let blueGels = Theme.Themed(
        light: gel([0x3F6FB4, 0x1D4C98, 0xB4D6F8, 0x76AFEE, 0x4B91E6, 0xA6DCFF], 0.75),
        dark: gel([0x1F4C8C, 0x0F3066, 0x86B0E2, 0x4A84D0, 0x2C68C2, 0x76ADE8], 0.5))
    /// Aqua blue on a wide gel: the default button at rest and the selected tab. By day it is
    /// `blueGel`. At night `blueGel` on a shape that wide is mostly shine, and it read paler than a
    /// checked box or the sorted column beside it, so these take a deeper gel with less shine
    /// (RESEARCH.md §7.7).
    static var wideBlueGel: Gel { wideBlueGels.current }
    private static let wideBlueGels = Theme.Themed(
        light: blueGels.light,
        dark: gel([0x1A4078, 0x0C2652, 0x6690CA, 0x366BB5, 0x2257A6, 0x4B8AD4], 0.4))
    /// The top of the default button's breath. At night it brightens but keeps its color, so the
    /// breath stays the same blue.
    static var blueGelBright: Gel { blueGelsBright.current }
    private static let blueGelsBright = Theme.Themed(
        light: gel([0x5583C4, 0x2E5FAA, 0xD6EAFD, 0xA3CDF7, 0x7AB8F3, 0xCDEFFF], 0.85),
        dark: gel([0x1F4C8C, 0x0F3066, 0x80AADD, 0x4C84CD, 0x3069BF, 0x64A2E6], 0.45))
    /// At night a clear step below `wideBlueGel`, so pressing OK still darkens it.
    static var bluePressedGel: Gel { bluePressedGels.current }
    private static let bluePressedGels = Theme.Themed(
        light: gel([0x274E8A, 0x14376F, 0x86B4E8, 0x4D88D8, 0x2C6BC6, 0x76B8F0], 0.6),
        dark: gel([0x0F2E5C, 0x081C42, 0x4D78B0, 0x24538B, 0x164384, 0x4677B5], 0.3))
    static var disabledGel: Gel { disabledGels.current }
    private static let disabledGels = Theme.Themed(
        light: gel([0xB5B5B5, 0xA2A2A2, 0xFAFAFA, 0xF1F1F1, 0xEAEAEA, 0xF7F7F7], 0.35),
        dark: gel([0x2C2D30, 0x222326, 0x45474B, 0x3E4044, 0x393B3E, 0x424448], 0.08))

    // MARK: - Painting

    /// Pinstripes keyed to the view's own coordinates, so adjacent views line up.
    static func drawPinstripes(in rect: NSRect, light: NSColor = stripeLight, dark: NSColor = stripeDark) {
        light.setFill()
        rect.fill()
        dark.setFill()
        let period: CGFloat = 4
        var y = (rect.minY / period).rounded(.down) * period + 2
        while y < rect.maxY {
            NSRect(x: rect.minX, y: y, width: rect.width, height: 2).intersection(rect).fill()
            y += period
        }
    }

    /// A gel shape: soft drop shadow, darker rim, two-lobe body, specular highlight.
    /// `rect` is the outer bounds; `radius` the outer corner radius (height/2 for a capsule).
    /// Works in flipped and unflipped views: the gradient runs from the visual top.
    static func drawGel(in rect: NSRect, radius: CGFloat, gel: Gel, flipped: Bool, shadow: Bool = true) {
        let down: CGFloat = flipped ? 1 : -1
        if shadow {
            let s = NSBezierPath(roundedRect: rect.offsetBy(dx: 0, dy: down), xRadius: radius, yRadius: radius)
            gelShadow.setFill()
            s.fill()
        }
        let outer = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        let rimAngle: CGFloat = flipped ? 90 : -90
        NSGradient(starting: gel.rimTop, ending: gel.rimBottom)?.draw(in: outer, angle: rimAngle)

        let bodyRect = rect.insetBy(dx: 1, dy: 1)
        let bodyRadius = max(0, radius - 1)
        let body = NSBezierPath(roundedRect: bodyRect, xRadius: bodyRadius, yRadius: bodyRadius)
        let bodyGradient = NSGradient(colors: [gel.top, gel.midTop, gel.midBottom, gel.bottom],
                                      atLocations: [0, 0.5, 0.5, 1], colorSpace: .sRGB)
        bodyGradient?.draw(in: body, angle: rimAngle)

        // Specular highlight: a narrower lozenge across the upper half.
        let hInsetX = min(bodyRadius * 0.6 + 1.5, bodyRect.width / 4)
        let hHeight = bodyRect.height * 0.46
        let hRect = NSRect(x: bodyRect.minX + hInsetX,
                           y: flipped ? bodyRect.minY + 0.5 : bodyRect.maxY - 0.5 - hHeight,
                           width: bodyRect.width - 2 * hInsetX, height: hHeight)
        let hRadius = min(hHeight / 2, bodyRadius)
        let highlight = NSBezierPath(roundedRect: hRect, xRadius: hRadius, yRadius: hRadius)
        NSGradient(starting: NSColor(white: 1, alpha: gel.highlight),
                   ending: NSColor(white: 1, alpha: 0.04))?.draw(in: highlight, angle: rimAngle)
    }

    /// The flat white field with a 1 px inset border: darker along the top, with a faint
    /// shadow row just inside it, like a 10.4 NSTextField bezel.
    static func drawFieldBezel(in rect: NSRect, flipped: Bool, enabled: Bool = true) {
        fieldFill.setFill()
        rect.fill()
        let px = 1 / (NSScreen.main?.backingScaleFactor ?? 2)
        let one: CGFloat = 1
        (enabled ? fieldBorder : boxBorder.withAlphaComponent(0.6)).setFill()
        NSRect(x: rect.minX, y: rect.minY, width: one, height: rect.height).fill()
        NSRect(x: rect.maxX - one, y: rect.minY, width: one, height: rect.height).fill()
        let topY = flipped ? rect.minY : rect.maxY - one
        let bottomY = flipped ? rect.maxY - one : rect.minY
        NSRect(x: rect.minX, y: bottomY, width: rect.width, height: one).fill()
        fieldBorderTop.setFill()
        NSRect(x: rect.minX, y: topY, width: rect.width, height: one).fill()
        fieldInnerTop.setFill()
        NSRect(x: rect.minX + one, y: flipped ? topY + one : topY - px * 2,
               width: rect.width - 2 * one, height: px * 2).fill()
    }

    /// The 10.4 keyboard focus glow: three soft rings fading outward.
    static func drawFocusRing(around rect: NSRect, radius: CGFloat = 0) {
        for (i, alpha) in [0.85, 0.5, 0.22].enumerated() {
            let r = rect.insetBy(dx: -CGFloat(i) - 0.5, dy: -CGFloat(i) - 0.5)
            let path = radius > 0
                ? NSBezierPath(roundedRect: r, xRadius: radius + CGFloat(i), yRadius: radius + CGFloat(i))
                : NSBezierPath(rect: r)
            path.lineWidth = 1
            focusRing.withAlphaComponent(alpha).setStroke()
            path.stroke()
        }
    }

    /// A horizontal etched separator: dark line with a light line beneath.
    static func drawEtchedLine(from x0: CGFloat, to x1: CGFloat, y: CGFloat, flipped: Bool) {
        etchDark.setFill()
        NSRect(x: x0, y: y, width: x1 - x0, height: 1).fill()
        etchLight.setFill()
        NSRect(x: x0, y: flipped ? y + 1 : y - 1, width: x1 - x0, height: 1).fill()
    }

    /// The recessed box behind tab content and grouped controls.
    static func drawBox(in rect: NSRect, flipped: Bool) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        drawPinstripes(in: rect, light: boxFillLight, dark: boxFillDark)
        // A soft inner shade along the top edge sells the recess.
        let shade = NSRect(x: rect.minX, y: flipped ? rect.minY : rect.maxY - 4, width: rect.width, height: 4)
        NSGradient(starting: boxInnerShade.withAlphaComponent(0.8), ending: boxInnerShade.withAlphaComponent(0))?
            .draw(in: shade, angle: flipped ? 90 : -90)
        NSGraphicsContext.restoreGraphicsState()
        let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4.5, yRadius: 4.5)
        border.lineWidth = 1
        boxBorder.setStroke()
        border.stroke()
    }

    static func attributes(_ font: NSFont, color: NSColor = text, alignment: NSTextAlignment = .left,
                           lineBreak: NSLineBreakMode = .byTruncatingTail) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = lineBreak
        return [.font: font, .foregroundColor: color, .paragraphStyle: style]
    }

    /// Engraved control text: a faint white shadow one point below, as 10.4 drew it. Graphite's
    /// light text takes the groove's dark wall instead, one point above (ChromePalette.engrave).
    /// Call while drawing: the lip is chosen for the appearance drawing now.
    static func engravedAttributes(_ font: NSFont, color: NSColor = text,
                                   alignment: NSTextAlignment = .center) -> [NSAttributedString.Key: Any] {
        var attrs = attributes(font, color: color, alignment: alignment)
        attrs[.shadow] = engraving.current
        return attrs
    }

    private static let engraving = Theme.Themed(light: lip(NSColor(white: 1, alpha: 0.55), up: false),
                                                dark: lip(NSColor(white: 0, alpha: 0.6), up: true))

    /// A hard 1 pt text shadow. NSShadow offsets ignore flipping: positive height is up.
    private static func lip(_ color: NSColor, up: Bool) -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = color
        shadow.shadowOffset = NSSize(width: 0, height: up ? 1 : -1)
        shadow.shadowBlurRadius = 0
        return shadow
    }
}

/// The recessed box behind a dialog's controls (Get Info's panes, Settings).
@MainActor
final class AquaBoxView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        AquaStyle.drawBox(in: bounds, flipped: true)
    }
}
