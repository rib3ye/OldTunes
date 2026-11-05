import AppKit

/// An inset white well that shows artwork scaled to fit, or a placeholder. Optionally clickable
/// (the multiple-song window opens the image picker from it).
@MainActor
final class ArtworkWell: NSView {
    enum Placeholder { case disc, text(String) }

    var image: NSImage? { didSet { needsDisplay = true } }
    var placeholder: Placeholder = .text("No Artwork") { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        AquaStyle.drawFieldBezel(in: bounds, flipped: true)
        let inner = bounds.insetBy(dx: 3, dy: 3)
        if let image, image.size.width > 0, image.size.height > 0 {
            let scale = min(inner.width / image.size.width, inner.height / image.size.height)
            let size = NSSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
            let rect = NSRect(x: inner.midX - size.width / 2, y: inner.midY - size.height / 2,
                              width: size.width, height: size.height)
            NSGraphicsContext.current?.imageInterpolation = .high
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return
        }
        switch placeholder {
        case .disc:
            AquaIcons.drawDisc(in: inner.insetBy(dx: inner.width * 0.12, dy: inner.height * 0.12))
        case .text(let text):
            let attrs = AquaStyle.attributes(AquaStyle.smallFont, color: Theme.textDimmed, alignment: .center)
            (text as NSString).draw(in: NSRect(x: inner.minX, y: inner.midY - 7, width: inner.width, height: 15),
                                    withAttributes: attrs)
        }
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}
