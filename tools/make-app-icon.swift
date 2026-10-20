// Draws OldTunes' app icon: the iTunes 7–9 icon (September 2006 to September 2010), a silver CD
// with a rainbow sheen behind a glossy blue double note, set on a dark grey tile. It is drawn from
// shapes, like the rest of the 2005 chrome, so no Apple artwork is copied into the repo.
//
// Run on a Mac, from the repo root:
//     swift tools/make-app-icon.swift
// It rewrites OldTunes/App/Assets.xcassets/AppIcon.appiconset. Pass a folder to write there instead.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Tile
//
// macOS 26 and later shrink any app icon that isn't a rounded square onto a light gray tile, so
// the disc sits on its own tile, cut to Apple's icon grid: an 824 px square with 185.4 px
// continuous corners, 100 px in from each edge of the 1024 px canvas. Shares of the canvas below.

let tileInset: CGFloat = 100 / 1024
let tileRadius: CGFloat = 185.4 / 1024

// MARK: - Disc and note
//
// Everything is in a 180-unit square with y growing downward. The numbers were measured off the
// 2006 icon, so adjust the picture here rather than in the drawing code.

let unit: CGFloat = 180
/// Share of the canvas the disc picture spans, centred on the tile.
let fill: CGFloat = 0.68
let deg = CGFloat.pi / 180

/// An ellipse turned by `tilt` (clockwise on screen, since y grows downward).
struct Oval {
    var center: CGPoint
    var a: CGFloat      // radius along the tilt
    var b: CGFloat      // radius across it
    var tilt: CGFloat

    func path(dx: CGFloat = 0, dy: CGFloat = 0, grow: CGFloat = 0) -> CGPath {
        var t = CGAffineTransform(translationX: center.x + dx, y: center.y + dy).rotated(by: tilt)
        return CGPath(ellipseIn: CGRect(x: -a - grow, y: -b - grow, width: 2 * (a + grow), height: 2 * (b + grow)),
                      transform: &t)
    }

    /// A ring of the same shape around the same centre: the hub and hole of a tilted disc.
    func ring(_ radius: CGFloat) -> Oval { Oval(center: center, a: radius, b: radius * b / a, tilt: tilt) }
}

/// The CD is seen a little from below and to the left, so its face is an ellipse, its hub sits
/// nearer the far (upper right) edge, and its thickness and shadow show on the near side.
let face = Oval(center: CGPoint(x: 90, y: 88.5), a: 88.5, b: 75.5, tilt: 24 * deg)
let edge = CGVector(dx: -0.8, dy: 2.9)  // how far the disc's back edge shows past its face
let hub = Oval(center: CGPoint(x: 93, y: 84), a: 28.5, b: 28.5 * 75.5 / 88.5, tilt: 24 * deg)
let clearRadius: CGFloat = 24.5         // clear plastic inside the mirror band
let grooveRadii: [CGFloat] = [19.5, 14.8]
let holeRadius: CGFloat = 10.2

/// The beam rises 9.4° to the right; its top and bottom edges are parallel.
let beamSlope: CGFloat = 0.1659
func beamTop(_ x: CGFloat) -> CGFloat { 14.3 - (x - 79) * beamSlope }
func beamBottom(_ x: CGFloat) -> CGFloat { 49.6 - (x - 88.5) * beamSlope }
/// Where the beam's dark upper face meets its lit front: a swoop from the top right corner down
/// into the left stem.
let swoopStart = CGPoint(x: 166, y: 9), swoopEnd = CGPoint(x: 86, y: 52)
let swoopControls = (CGPoint(x: 140, y: 28), CGPoint(x: 96, y: 34))
/// Stems end at their right edges, which line up with the right ends of the heads.
let stemWidth: CGFloat = 9.5
let leftStemRight: CGFloat = 88.5, rightStemRight: CGFloat = 161
let leftHead = Oval(center: CGPoint(x: 69.2, y: 130.5), a: 21, b: 16.3, tilt: -18 * deg)
let rightHead = Oval(center: CGPoint(x: 141, y: 118.5), a: 21, b: 16.3, tilt: -18 * deg)

/// Angle around the hub (degrees, clockwise from 3 o'clock) → colour of the pressed surface. The
/// two rainbow bands sit half a turn apart, the way light splits off a real CD.
let sheen: [(CGFloat, UInt32)] = [
    (0, 0xE2DAB4), (14, 0xCBDD8E), (28, 0x7EDC9E), (43, 0x4CC2CF), (58, 0x6A93DD), (74, 0xA3A2D6),
    (90, 0xB5C0CD), (110, 0xCFDCE7), (135, 0xF0F9FD), (150, 0xE0EBF1), (165, 0xCFDAE0),
    (180, 0xE2CFC3), (195, 0xE0CF9C), (210, 0xA0EE90), (225, 0x72DBD2), (240, 0x95ABE4),
    (256, 0xDAD8E8), (272, 0xD5DFE4), (290, 0xE2EDF3), (315, 0xFFFFFF), (332, 0xDCE5EA),
    (347, 0xD9CDD0), (360, 0xE2DAB4),
]

// MARK: - Helpers

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255,
                                           CGFloat(hex & 0xFF) / 255, alpha])!
}

func gradient(_ stops: [(CGFloat, UInt32, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: stops.map { color($0.1, $0.2) } as CFArray, locations: stops.map(\.0))!
}

func gradient(_ stops: [(CGFloat, UInt32)]) -> CGGradient { gradient(stops.map { ($0.0, $0.1, 1) }) }

func rect(_ r: CGRect) -> CGPath { CGPath(rect: r, transform: nil) }
let everywhere = rect(CGRect(x: -unit, y: -unit, width: 3 * unit, height: 3 * unit))

extension CGContext {
    func clip(to path: CGPath) { addPath(path); clip() }
    func fill(_ path: CGPath, _ c: CGColor) { setFillColor(c); addPath(path); fillPath() }
    func stroke(_ path: CGPath, _ c: CGColor, width: CGFloat) {
        setStrokeColor(c); setLineWidth(width); addPath(path); strokePath()
    }
    func linear(_ g: CGGradient, _ from: CGPoint, _ to: CGPoint) {
        drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
}

/// The rainbow surface as a bitmap the size of the canvas: Core Graphics has no conic gradient.
/// `muted` pulls it toward silver, so the note stays readable at the smallest sizes.
func sheenImage(px: Int, toDevice: CGAffineTransform, muted: CGFloat) -> CGImage {
    let toDesign = toDevice.inverted()
    var bytes = [UInt8](repeating: 0, count: px * px * 4)
    for row in 0..<px {
        for col in 0..<px {
            let p = CGPoint(x: CGFloat(col) + 0.5, y: CGFloat(px - row) - 0.5).applying(toDesign)
            var angle = atan2(p.y - hub.center.y, p.x - hub.center.x) / deg
            if angle < 0 { angle += 360 }
            let i = sheen.lastIndex { $0.0 <= angle } ?? 0
            let (a0, c0) = sheen[i], (a1, c1) = sheen[min(i + 1, sheen.count - 1)]
            let f = a1 > a0 ? (angle - a0) / (a1 - a0) : 0
            let o = (row * px + col) * 4
            for (k, shift) in [16, 8, 0].enumerated() {
                let v0 = CGFloat((c0 >> UInt32(shift)) & 0xFF), v1 = CGFloat((c1 >> UInt32(shift)) & 0xFF)
                let v = v0 + (v1 - v0) * f
                bytes[o + k] = UInt8((v + (0xDC - v) * muted).rounded())
            }
            bytes[o + 3] = 255
        }
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(width: px, height: px, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: px * 4, space: sRGB,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                   decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

// MARK: - Drawing

/// A rounded square with continuous corners, the curve Apple's icons use: each corner is three
/// cubics running from 1.53 radii along one edge to 1.53 radii along the next.
func squircle(_ r: CGRect, radius: CGFloat) -> CGPath {
    let k = min(radius, min(r.width, r.height) / 2 / 1.52866483)
    let p = CGMutablePath()
    p.move(to: CGPoint(x: r.minX + 1.52866483 * k, y: r.minY))
    // `back` points from the corner along the edge just drawn, `on` along the edge to come.
    for (corner, back, on) in [(CGPoint(x: r.maxX, y: r.minY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: 1)),
                               (CGPoint(x: r.maxX, y: r.maxY), CGVector(dx: 0, dy: -1), CGVector(dx: -1, dy: 0)),
                               (CGPoint(x: r.minX, y: r.maxY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: -1)),
                               (CGPoint(x: r.minX, y: r.minY), CGVector(dx: 0, dy: 1), CGVector(dx: 1, dy: 0))] {
        func at(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
            CGPoint(x: corner.x + (back.dx * u + on.dx * v) * k, y: corner.y + (back.dy * u + on.dy * v) * k)
        }
        p.addLine(to: at(1.52866483, 0))
        p.addCurve(to: at(0.66993427, 0.06549600), control1: at(1.08849323, 0), control2: at(0.86840689, 0))
        p.addCurve(to: at(0.06549600, 0.66993427), control1: at(0.37282392, 0.16905380),
                   control2: at(0.16905380, 0.37282392))
        p.addCurve(to: at(0, 1.52866483), control1: at(0, 0.86840689), control2: at(0, 1.08849323))
    }
    p.closeSubpath()
    return p
}

/// The dark grey tile, in device pixels (y up): lighter at the top, a soft light behind the disc,
/// a hairline highlight along the top edge, and the drop shadow every macOS icon has.
func drawTile(in ctx: CGContext, px: Int) {
    let size = CGFloat(px)
    let box = CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: size * tileInset, dy: size * tileInset)
    let tile = squircle(box, radius: size * tileRadius)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.01), blur: size * 0.02, color: color(0x000000, 0.35))
    ctx.fill(tile, color(0x1C1C1F))
    ctx.restoreGState()

    ctx.saveGState()
    ctx.clip(to: tile)
    ctx.linear(gradient([(0, 0x48484D), (1, 0x1A1A1D)]), CGPoint(x: 0, y: box.maxY), CGPoint(x: 0, y: box.minY))
    let glow = CGPoint(x: box.midX, y: box.midY + box.height * 0.08)
    ctx.drawRadialGradient(gradient([(0, 0xFFFFFF, 0.09), (1, 0xFFFFFF, 0)]), startCenter: glow, startRadius: 0,
                           endCenter: glow, endRadius: box.width * 0.55, options: [])
    ctx.addPath(tile)
    ctx.setLineWidth(max(1, size * 0.006))
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.linear(gradient([(0, 0xFFFFFF, 0.28), (0.5, 0xFFFFFF, 0)]), CGPoint(x: 0, y: box.maxY), CGPoint(x: 0, y: box.minY))
    ctx.restoreGState()
}

/// The note's stems, widened leftward at small sizes so each stays at least a pixel and a bit wide.
struct Stems {
    var left: ClosedRange<CGFloat>
    var right: ClosedRange<CGFloat>

    init(pixelsPerUnit s: CGFloat) {
        let width = max(stemWidth, min(stemWidth + 6, 1.6 / s))
        left = (leftStemRight - width)...leftStemRight
        right = (rightStemRight - width)...rightStemRight
    }

    /// One stroke of the beam and both stems, with rounded outer corners and filleted inner ones.
    var body: CGPath {
        let p = CGMutablePath()
        let leftFoot = leftHead.center.y - 2, rightFoot = rightHead.center.y - 2
        p.move(to: CGPoint(x: left.lowerBound, y: leftFoot))
        p.addArc(tangent1End: CGPoint(x: left.lowerBound, y: beamTop(left.lowerBound)),
                 tangent2End: CGPoint(x: right.upperBound, y: beamTop(right.upperBound)), radius: 2.5)
        p.addArc(tangent1End: CGPoint(x: right.upperBound, y: beamTop(right.upperBound)),
                 tangent2End: CGPoint(x: right.upperBound, y: rightFoot), radius: 3)
        p.addLine(to: CGPoint(x: right.upperBound, y: rightFoot))
        p.addLine(to: CGPoint(x: right.lowerBound, y: rightFoot))
        p.addArc(tangent1End: CGPoint(x: right.lowerBound, y: beamBottom(right.lowerBound)),
                 tangent2End: CGPoint(x: left.upperBound, y: beamBottom(left.upperBound)), radius: 3)
        p.addArc(tangent1End: CGPoint(x: left.upperBound, y: beamBottom(left.upperBound)),
                 tangent2End: CGPoint(x: left.upperBound, y: leftFoot), radius: 9)
        p.addLine(to: CGPoint(x: left.upperBound, y: leftFoot))
        p.closeSubpath()
        return p
    }
}

func drawDisc(in ctx: CGContext, px: Int) {
    let s = CGFloat(px) / unit * fill     // device pixels per design unit
    let fine = s > 0.3                    // thin lines only where there are pixels to hold them
    let toDevice = CGAffineTransform(translationX: CGFloat(px) / 2, y: CGFloat(px) / 2)
        .scaledBy(x: s, y: -s)
        .translatedBy(x: -unit / 2, y: -unit / 2)
    ctx.concatenate(toDevice)
    let sheenBitmap = sheenImage(px: px, toDevice: toDevice, muted: px <= 16 ? 0.45 : px <= 32 ? 0.25 : 0)
    func drawSheen() {
        ctx.saveGState()
        ctx.concatenate(toDevice.inverted())
        ctx.draw(sheenBitmap, in: CGRect(x: 0, y: 0, width: px, height: px))
        ctx.restoreGState()
    }
    // Shadow offsets and blur are in device pixels, with y up.
    func shadow(dx: CGFloat, dy: CGFloat, blur: CGFloat, _ c: CGColor) {
        ctx.setShadow(offset: CGSize(width: dx * s, height: -dy * s), blur: blur * s, color: c)
    }
    // At the smallest sizes a line has to be about a pixel wide to show at all.
    func line(_ units: CGFloat) -> CGFloat { max(units, 0.7 / s) }

    // The disc's back edge, and the shadow it casts down and to the left.
    let back = face.path(dx: edge.dx, dy: edge.dy, grow: 0.4)
    ctx.saveGState()
    shadow(dx: -2, dy: 3, blur: 5.5, color(0x000000, 0.55))
    ctx.fill(back, color(0xB8BEC5))
    ctx.restoreGState()
    ctx.saveGState()
    ctx.clip(to: back)
    ctx.linear(gradient([(0, 0xF6F8FA), (1, 0xAEB4BB)]), CGPoint(x: 90, y: 130), CGPoint(x: 90, y: 172))
    ctx.restoreGState()
    if fine { ctx.stroke(face.path(dx: edge.dx / 2, dy: edge.dy / 2, grow: 0.2), color(0xC4C8CD), width: 0.5) }
    ctx.stroke(back, color(0x8C9299), width: line(0.8))

    // The face: the rainbow sheen, a bright lip just inside the edge, then the edge itself.
    ctx.saveGState()
    ctx.clip(to: face.path())
    drawSheen()
    if fine { ctx.stroke(face.path(), color(0xFFFFFF, 0.9), width: 2.4) }
    ctx.restoreGState()
    ctx.stroke(face.path(), color(0xA0A6AD), width: line(0.8))

    // The hub: a darker mirror band, clear plastic with two moulded rings, and the hole.
    ctx.saveGState()
    ctx.clip(to: hub.path())
    ctx.fill(everywhere, color(0x000000, 0.3))
    ctx.restoreGState()
    ctx.stroke(hub.path(), color(0x8F949B, 0.6), width: 0.6)
    let plastic = hub.ring(clearRadius).path()
    let hole = hub.ring(holeRadius).path()
    ctx.saveGState()
    ctx.setBlendMode(.clear)
    ctx.fill(plastic, color(0x000000))
    ctx.restoreGState()
    ctx.fill(plastic.subtracting(hole), color(0xD9DDE1, 0.9))
    if fine {
        for r in grooveRadii {
            ctx.stroke(hub.ring(r + 0.6).path(), color(0xFFFFFF, 0.8), width: 0.5)
            ctx.stroke(hub.ring(r).path(), color(0xA3A9B1, 0.85), width: 0.55)
        }
    }
    ctx.stroke(plastic, color(0x8C9097, 0.7), width: 0.5)
    ctx.stroke(hole, color(0xAEB3BA, 0.9), width: 0.6)

    // The note.
    let stems = Stems(pixelsPerUnit: s)
    let body = stems.body
    let note = body.union(leftHead.path()).union(rightHead.path())

    // A soft blue shadow on the disc. The shape is drawn far off the canvas so only its shadow lands.
    ctx.saveGState()
    ctx.clip(to: face.path().subtracting(hole))
    let away: CGFloat = 1000
    ctx.translateBy(x: -away, y: 0)
    shadow(dx: away - 1.5, dy: 2.5, blur: 4, color(0x1A3C9A, 0.4))
    ctx.fill(note, color(0x000000))
    ctx.restoreGState()

    ctx.saveGState()
    ctx.clip(to: body)
    // The beam's lit front: dark just under the swoop, brightening toward the bottom edge.
    let across = CGVector(dx: beamSlope, dy: 1)
    let len = (across.dx * across.dx + across.dy * across.dy).squareRoot()
    let thickness = (beamBottom(120) - beamTop(120)) / len
    func acrossBeam(_ f: CGFloat) -> CGPoint {
        CGPoint(x: 120 + across.dx / len * thickness * f, y: beamTop(120) + across.dy / len * thickness * f)
    }
    ctx.linear(gradient([(0.3, 0x0A50C4), (0.62, 0x055DCA), (0.8, 0x0373DE), (0.93, 0x0281EB), (1, 0x0A62D2)]),
               acrossBeam(0), acrossBeam(1))
    // The beam's upper face, darker, above the swoop.
    let upper = CGMutablePath()
    upper.move(to: CGPoint(x: 60, y: -10))
    upper.addLine(to: CGPoint(x: 190, y: -10))
    upper.addLine(to: CGPoint(x: 190, y: swoopStart.y))
    upper.addLine(to: swoopStart)
    upper.addCurve(to: swoopEnd, control1: swoopControls.0, control2: swoopControls.1)
    upper.addLine(to: CGPoint(x: 60, y: swoopEnd.y))
    upper.closeSubpath()
    ctx.saveGState()
    ctx.clip(to: upper)
    ctx.linear(gradient([(0, 0x1C55C0), (0.35, 0x2263C8), (0.7, 0x3381D7), (0.9, 0x3A8ADC)]),
               acrossBeam(0), acrossBeam(1))
    ctx.restoreGState()
    // Stems: round bars lit from the left, starting under the beam. The left stem's lit side runs
    // on up through the beam, fading out where its shaded side would meet the beam's faces.
    let stemShade: [(CGFloat, UInt32)] = [(0, 0x1652BA), (0.12, 0x0F48B5), (0.3, 0x4797E2), (0.5, 0x3280D7),
                                          (0.7, 0x0545A8), (0.86, 0x00368F), (1, 0x062C80)]
    let leftSplit = beamBottom(stems.left.upperBound) + 2, rightSplit = beamBottom(stems.right.upperBound) - 4
    for (stem, split) in [(stems.left, leftSplit), (stems.right, rightSplit)] {
        let column = CGRect(x: stem.lowerBound, y: 0, width: stem.upperBound - stem.lowerBound, height: unit)
        ctx.saveGState()
        ctx.clip(to: rect(column.divided(atDistance: split, from: .minYEdge).remainder))
        ctx.linear(gradient(stemShade), CGPoint(x: stem.lowerBound, y: 0), CGPoint(x: stem.upperBound, y: 0))
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.clip(to: rect(CGRect(x: stems.left.lowerBound, y: 0, width: stems.left.upperBound - stems.left.lowerBound,
                             height: leftSplit)))
    ctx.linear(gradient([(0, 0x1652BA, 1), (0.12, 0x0F48B5, 1), (0.3, 0x4797E2, 1), (0.5, 0x3280D7, 0.7),
                         (0.75, 0x2A70D0, 0)]),
               CGPoint(x: stems.left.lowerBound, y: 0), CGPoint(x: stems.left.upperBound, y: 0))
    ctx.restoreGState()
    if fine {
        let inset: CGFloat = 0.9
        let top = CGMutablePath()
        top.move(to: CGPoint(x: stems.left.lowerBound + 2.5, y: beamTop(stems.left.lowerBound + 2.5) + inset))
        top.addLine(to: CGPoint(x: stems.right.upperBound - 3, y: beamTop(stems.right.upperBound - 3) + inset))
        ctx.stroke(top, color(0x9CCBF2, 0.9), width: 1.0)
    }
    ctx.stroke(body, color(0x0A3A9A, 0.8), width: 1.6)
    ctx.restoreGState()

    // Heads: glossy gel, brightest in the middle, with a soft sky-blue cap across the top.
    for (head, stem) in [(leftHead, stems.left), (rightHead, stems.right)] {
        ctx.saveGState()
        ctx.clip(to: head.path())
        ctx.saveGState()
        ctx.translateBy(x: head.center.x, y: head.center.y)
        ctx.rotate(by: head.tilt)
        let glow = CGPoint(x: 0, y: head.b * 0.25)
        ctx.drawRadialGradient(gradient([(0, 0x0E9AF5), (0.45, 0x048AF6), (0.75, 0x0570E2), (0.92, 0x0553CA),
                                         (1, 0x0848B5)]),
                               startCenter: glow, startRadius: 0, endCenter: glow, endRadius: head.a * 1.1,
                               options: [.drawsAfterEndLocation])
        let cap = Oval(center: CGPoint(x: -head.a * 0.05, y: -head.b * 0.3), a: head.a * 0.78, b: head.b * 0.55, tilt: 0)
        ctx.clip(to: cap.path())
        ctx.linear(gradient([(0, 0xC4E6FA, 0.92), (1, 0x7CC0F0, 0)]),
                   CGPoint(x: 0, y: cap.center.y - cap.b), CGPoint(x: 0, y: cap.center.y + cap.b))
        ctx.restoreGState()
        // A dark rim, except where the stem runs into the head.
        let join = rect(CGRect(x: stem.lowerBound, y: 0, width: stem.upperBound - stem.lowerBound, height: head.center.y))
        ctx.clip(to: everywhere.subtracting(join))
        ctx.stroke(head.path(), color(0x0A3796, 0.85), width: 1.6)
        ctx.restoreGState()
    }

    // A crisp outline around the whole note.
    ctx.stroke(note, color(0x0B2E80, 0.55), width: line(0.7))
}

func render(px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    drawTile(in: ctx, px: px)
    // The disc gets a layer of its own, so its hole is cut out of the disc and not out of the tile.
    ctx.saveGState()
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    drawDisc(in: ctx, px: px)
    ctx.endTransparencyLayer()
    ctx.restoreGState()
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(url.path)") }
}

// MARK: - Output

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first
              ?? "OldTunes/App/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

var entries: [String] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        writePNG(render(px: points * scale), to: out.appendingPathComponent(name))
        entries.append("""
            { "filename" : "\(name)", "idiom" : "mac", "scale" : "\(scale)x", "size" : "\(points)x\(points)" }
        """)
    }
}
let contents = """
{
  "images" : [
\(entries.joined(separator: ",\n"))
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}

"""
try contents.write(to: out.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("Wrote \(entries.count) icons to \(out.path)")
