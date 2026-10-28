import AppKit

/// The volume slider under the transport buttons: a recessed groove, a round knob with a dimple,
/// and a speaker glyph at each end (§7.2: groove x 39..116, y 73..78; knob 12 pt; glyphs x 26..38
/// and 117..132). Click anywhere on the groove to jump there, then drag; clicking the small
/// speaker mutes and the big one goes to full, as iTunes did. Disabled, it draws dimmed and
/// ignores the mouse and the scroll wheel.
@MainActor
final class ChromeVolumeSlider: NSView {
    /// Called continuously while the user drags, 0...1.
    var onChange: ((Float) -> Void)?
    var value: Float = 0.75 { didSet { if value != oldValue { needsDisplay = true } } }
    /// True between mouse-down and mouse-up; state-driven updates must not move the knob then.
    private(set) var isDragging = false
    /// False during an iCloud song OldTunes can't set the level of (PlaybackState.isVolumeEnabled).
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            if !isEnabled { isDragging = false }
            needsDisplay = true
        }
    }

    /// Window x of this view's left edge; everything below is relative to it.
    static let originX: CGFloat = 24
    static let frameInControlBar = NSRect(x: originX, y: 38, width: 112, height: 18)

    private var grooveMinX: CGFloat { Theme.Metrics.volumeGrooveX.lowerBound - Self.originX }
    private var grooveLength: CGFloat {
        Theme.Metrics.volumeGrooveX.upperBound - Theme.Metrics.volumeGrooveX.lowerBound + 1
    }
    private var knob: CGFloat { Theme.Metrics.volumeKnobDiameter }
    /// Window y 75 is the slider's centre line.
    private var centerY: CGFloat { Theme.Metrics.volumeCenterY - ControlBarView.windowY - Self.frameInControlBar.minY }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    /// Acts on the first click even in an inactive window, as Aqua window and media buttons did.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func knobCenterX(for value: Float) -> CGFloat {
        grooveMinX + knob / 2 + CGFloat(value) * (grooveLength - knob)
    }

    private func value(atX x: CGFloat) -> Float {
        Float(min(max((x - grooveMinX - knob / 2) / (grooveLength - knob), 0), 1))
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let p = convert(event.locationInWindow, from: nil)
        if p.x < grooveMinX - 1 {
            set(0)
        } else if p.x > grooveMinX + grooveLength + 1 {
            set(1)
        } else {
            isDragging = true
            set(value(atX: p.x))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        set(value(atX: convert(event.locationInWindow, from: nil).x))
    }

    override func mouseUp(with event: NSEvent) { isDragging = false }

    override func scrollWheel(with event: NSEvent) {
        guard isEnabled else { return }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 200 : event.scrollingDeltaY / 20
        guard delta != 0 else { return }
        set(min(max(value + Float(delta), 0), 1))
    }

    private func set(_ newValue: Float) {
        value = newValue
        onChange?(newValue)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Disabled, the slider fades as one piece, as a disabled bevel button does, so the groove
        // doesn't show through the knob.
        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.saveGState()
        if !isEnabled { ctx?.setAlpha(0.55) }
        ctx?.beginTransparencyLayer(auxiliaryInfo: nil)
        defer {
            ctx?.endTransparencyLayer()
            ctx?.restoreGState()
        }
        let h = Theme.Metrics.volumeGrooveHeight
        let groove = NSRect(x: grooveMinX, y: centerY - h / 2, width: grooveLength, height: h)
        ChromePalette.emboss.setFill()
        NSBezierPath(roundedRect: groove.offsetBy(dx: 0, dy: 0.75), xRadius: h / 2, yRadius: h / 2).fill()
        let mid = ChromePalette.mix(Theme.volGrooveTop, Theme.volGrooveBottom, 0.45)
        ChromeDraw.fill(NSBezierPath(roundedRect: groove, xRadius: h / 2, yRadius: h / 2),
                        with: ChromeDraw.gradient([Theme.volGrooveTop, mid, Theme.volGrooveBottom], [0, 0.5, 1]),
                        top: groove.minY, bottom: groove.maxY)

        drawSpeaker(left: 2, waves: 1)
        drawSpeaker(left: Theme.Metrics.volumeGrooveX.upperBound + 1 - Self.originX, waves: 3)

        let cx = knobCenterX(for: value)
        let k = NSRect(x: cx - knob / 2, y: centerY - knob / 2, width: knob, height: knob)
        // The knob is a cap like the buttons, so it takes their lip; it rides in the groove, not a well.
        ChromeDraw.buttonWell(wall: nil, lip: NSBezierPath(ovalIn: k.offsetBy(dx: 0, dy: 0.75)))
        Theme.volKnobRim.setFill()
        NSBezierPath(ovalIn: k).fill()
        let body = k.insetBy(dx: 1, dy: 1)
        ChromeDraw.fill(NSBezierPath(ovalIn: body),
                        with: ChromeDraw.gradient([Theme.volKnobTop, Theme.volKnobBottom, Theme.volKnobGlint],
                                                  [0, 0.6, 1]),
                        top: body.minY, bottom: body.maxY)
        let d: CGFloat = 4
        let dimple = NSRect(x: cx - d / 2, y: centerY - d / 2, width: d, height: d)
        ChromePalette.emboss.setFill()
        NSBezierPath(ovalIn: dimple.offsetBy(dx: 0, dy: 0.5)).fill()
        Theme.volKnobDimple.setFill()
        NSBezierPath(ovalIn: dimple).fill()
    }

    /// A speaker cone with `waves` sound arcs, 12 pt wide for one wave and 16 pt for three.
    private func drawSpeaker(left x: CGFloat, waves: Int) {
        let cy = centerY
        Theme.volGlyph.setFill()
        NSRect(x: x, y: cy - 2, width: 3, height: 4).fill()
        let cone = NSBezierPath()
        cone.move(to: NSPoint(x: x + 2.5, y: cy - 2))
        cone.line(to: NSPoint(x: x + 6.5, y: cy - 5.5))
        cone.line(to: NSPoint(x: x + 6.5, y: cy + 5.5))
        cone.line(to: NSPoint(x: x + 2.5, y: cy + 2))
        cone.close()
        cone.fill()
        Theme.volGlyph.setStroke()
        for i in 0..<waves {
            let r = 2.6 + CGFloat(i) * 2.4
            let arc = NSBezierPath()
            arc.lineWidth = 1.1
            arc.appendArc(withCenter: NSPoint(x: x + 6.5, y: cy), radius: r, startAngle: -48, endAngle: 48)
            arc.stroke()
        }
    }
}
