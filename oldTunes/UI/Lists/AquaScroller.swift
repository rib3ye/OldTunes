import AppKit

/// The Mac OS X 10.4 scroller: 15 pt, never an overlay, inset trough, blue gel knob, and the arrow
/// pair together at the bottom (or right) end. RESEARCH.md §8.3. RetroScrollView hides it when
/// there is nothing to scroll.
///
/// Modern NSScroller has no arrows at all — `rect(for:)` returns zero for them and
/// `trackScrollButtons` is never called — so this class owns its geometry, hit-testing and the
/// whole mouse-tracking loop, and scrolls the enclosing scroll view's clip view directly.
final class AquaScroller: NSScroller {

    /// Each arrow button is half of the 32 pt pair (§7.2).
    static let arrowLength: CGFloat = Theme.Metrics.scrollArrowPairHeight / 2
    /// Below this the knob stops shrinking; the reference's 3,293-song knob is about 20 pt.
    static let minimumKnobLength: CGFloat = 20
    /// Press-and-hold timing, close to the classic Aqua key-repeat feel.
    static let repeatDelay: TimeInterval = 0.35
    static let repeatInterval: TimeInterval = 0.05

    /// The scroller's regions. NSScroller.Part's arrow cases are deprecated ("Scroller arrows
    /// are not used anymore"), so the arrows get names of their own.
    enum Region: Equatable { case none, arrowBack, arrowForward, knob, pageBack, pageForward }

    /// Which arrow or page area is held down, for the pressed look.
    private var pressedRegion: Region?

    // MARK: Legacy mode

    /// FALSE pins the scroll view to legacy scrollers, which take their own room and never fade,
    /// whatever the user's preference is (§8.3: setting `.overlay` explicitly was refused once
    /// this is false).
    override class var isCompatibleWithOverlayScrollers: Bool { false }

    override class func scrollerWidth(for controlSize: NSControl.ControlSize,
                                      scrollerStyle: NSScroller.Style) -> CGFloat {
        Theme.Metrics.scrollerWidth
    }

    override var doubleValue: Double { didSet { needsDisplay = true } }
    override var knobProportion: CGFloat { didSet { needsDisplay = true } }

    override var isOpaque: Bool { true }

    /// AppKit decides orientation from the frame shape too.
    var isVertical: Bool { bounds.height >= bounds.width }

    // MARK: Geometry (the scroller is flipped: y = 0 is the top)

    private var length: CGFloat { isVertical ? bounds.height : bounds.width }

    /// Everything but the arrow pair.
    var slotRect: NSRect {
        let arrows = min(Theme.Metrics.scrollArrowPairHeight, length)
        return isVertical
            ? NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - arrows)
            : NSRect(x: 0, y: 0, width: bounds.width - arrows, height: bounds.height)
    }

    /// Top/left arrow of the pair (it scrolls back toward the start).
    var decrementArrowRect: NSRect {
        let a = Self.arrowLength
        return isVertical
            ? NSRect(x: 0, y: bounds.height - 2 * a, width: bounds.width, height: a)
            : NSRect(x: bounds.width - 2 * a, y: 0, width: a, height: bounds.height)
    }

    var incrementArrowRect: NSRect {
        let a = Self.arrowLength
        return isVertical
            ? NSRect(x: 0, y: bounds.height - a, width: bounds.width, height: a)
            : NSRect(x: bounds.width - a, y: 0, width: a, height: bounds.height)
    }

    /// The knob travels inside the slot with a 1 pt margin all round.
    var knobRect: NSRect {
        let slot = slotRect.insetBy(dx: 1, dy: 1)
        let slotLength = isVertical ? slot.height : slot.width
        guard slotLength > Self.minimumKnobLength, knobProportion > 0, knobProportion < 1, isEnabled else {
            return .zero
        }
        let knobLength = max(Self.minimumKnobLength, (slotLength * knobProportion).rounded())
        let offset = ((slotLength - knobLength) * CGFloat(min(max(doubleValue, 0), 1))).rounded()
        return isVertical
            ? NSRect(x: slot.minX, y: slot.minY + offset, width: slot.width, height: knobLength)
            : NSRect(x: slot.minX + offset, y: slot.minY, width: knobLength, height: slot.height)
    }

    func rect(for region: Region) -> NSRect {
        switch region {
        case .none: return .zero
        case .knob: return knobRect
        case .arrowBack: return decrementArrowRect
        case .arrowForward: return incrementArrowRect
        case .pageBack, .pageForward:
            let knob = knobRect, slot = slotRect
            guard knob != .zero else { return .zero }
            if isVertical {
                return region == .pageBack
                    ? NSRect(x: 0, y: slot.minY, width: slot.width, height: knob.minY - slot.minY)
                    : NSRect(x: 0, y: knob.maxY, width: slot.width, height: slot.maxY - knob.maxY)
            }
            return region == .pageBack
                ? NSRect(x: slot.minX, y: 0, width: knob.minX - slot.minX, height: slot.height)
                : NSRect(x: knob.maxX, y: 0, width: slot.maxX - knob.maxX, height: slot.height)
        }
    }

    /// AppKit's own view of the parts, for anything that still asks (accessibility, legacy
    /// drawing paths). Its arrow cases are deprecated, so arrows are not reported here.
    override func rect(for part: NSScroller.Part) -> NSRect {
        switch part {
        case .knob: knobRect
        case .knobSlot: slotRect
        case .decrementPage: rect(for: Region.pageBack)
        case .incrementPage: rect(for: Region.pageForward)
        default: .zero
        }
    }

    /// `point` is in window coordinates, as NSScroller's own contract says.
    override func testPart(_ point: NSPoint) -> NSScroller.Part {
        switch region(atLocal: convert(point, from: nil)) {
        case .knob: .knob
        case .pageBack: .decrementPage
        case .pageForward: .incrementPage
        case .none, .arrowBack, .arrowForward: .noPart
        }
    }

    func region(atLocal p: NSPoint) -> Region {
        guard bounds.contains(p) else { return .none }
        for region: Region in [.arrowBack, .arrowForward, .knob, .pageBack, .pageForward]
            where rect(for: region).contains(p) {
            return region
        }
        return .none
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        drawKnobSlot(in: slotRect, highlight: false)
        drawArrow(decrementArrowRect, region: .arrowBack)
        drawArrow(incrementArrowRect, region: .arrowForward)
        drawKnob()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        ListsPalette.troughOuter.setFill()
        slotRect.fill()
        guard slotRect.width > 2, slotRect.height > 2 else { return }
        let radius = (isVertical ? slotRect.width : slotRect.height) / 2
        let capsule = NSBezierPath(roundedRect: slotRect, xRadius: radius, yRadius: radius)
        ListsPalette.trough.draw(in: capsule, angle: isVertical ? 0 : 90)

        // The rounded ends read as inset because they are shaded, darkest at the very end.
        NSGraphicsContext.saveGraphicsState()
        capsule.addClip()
        let shade = NSGradient(starting: ListsPalette.troughEndShade, ending: .clear)
        let depth: CGFloat = 8
        if isVertical {
            shade?.draw(in: NSRect(x: slotRect.minX, y: slotRect.minY, width: slotRect.width, height: depth), angle: 90)
            shade?.draw(in: NSRect(x: slotRect.minX, y: slotRect.maxY - depth, width: slotRect.width, height: depth), angle: -90)
        } else {
            shade?.draw(in: NSRect(x: slotRect.minX, y: slotRect.minY, width: depth, height: slotRect.height), angle: 0)
            shade?.draw(in: NSRect(x: slotRect.maxX - depth, y: slotRect.minY, width: depth, height: slotRect.height), angle: 180)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    override func drawKnob() {
        let knob = knobRect
        guard knob.width > 4, knob.height > 4 else { return }
        let radius = (isVertical ? knob.width : knob.height) / 2
        let rim = NSBezierPath(roundedRect: knob, xRadius: radius, yRadius: radius)
        ListsPalette.knobRim.setFill()
        rim.fill()

        let inner = knob.insetBy(dx: 1, dy: 1)
        let innerRadius = max(radius - 1, 0)
        let body = NSBezierPath(roundedRect: inner, xRadius: innerRadius, yRadius: innerRadius)
        ListsPalette.knobGel.draw(in: body, angle: isVertical ? 0 : 90)

        // Faint Aqua pinstripes across the knob, every 4 pt along its length.
        NSGraphicsContext.saveGraphicsState()
        body.addClip()
        ListsPalette.knobPinstripe.setFill()
        if isVertical {
            var y = inner.minY + 2
            while y < inner.maxY { NSRect(x: inner.minX, y: y, width: inner.width, height: 1).fill(); y += 4 }
        } else {
            var x = inner.minX + 2
            while x < inner.maxX { NSRect(x: x, y: inner.minY, width: 1, height: inner.height).fill(); x += 4 }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawArrow(_ rect: NSRect, region: Region) {
        guard rect.width > 0, rect.height > 0 else { return }
        let pressed = pressedRegion == region
        (pressed ? ListsPalette.arrowFillPressed : ListsPalette.arrowFill).draw(in: rect, angle: isVertical ? 0 : 90)

        // A hairline between the two buttons (the trough's shaded end marks the top of the pair).
        if region == .arrowForward {
            ListsPalette.arrowSeparator.setFill()
            if isVertical {
                NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1).fill()
            } else {
                NSRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height).fill()
            }
        }

        let c = NSPoint(x: rect.midX, y: rect.midY + (isVertical ? 0.5 : 0))
        let w: CGFloat = 7, h: CGFloat = 5
        let path = NSBezierPath()
        switch (isVertical, region == .arrowBack) {
        case (true, true):   // up (flipped: smaller y is up)
            path.move(to: NSPoint(x: c.x - w / 2, y: c.y + h / 2))
            path.line(to: NSPoint(x: c.x + w / 2, y: c.y + h / 2))
            path.line(to: NSPoint(x: c.x, y: c.y - h / 2))
        case (true, false):  // down
            path.move(to: NSPoint(x: c.x - w / 2, y: c.y - h / 2))
            path.line(to: NSPoint(x: c.x + w / 2, y: c.y - h / 2))
            path.line(to: NSPoint(x: c.x, y: c.y + h / 2))
        case (false, true):  // left
            path.move(to: NSPoint(x: c.x + h / 2, y: c.y - w / 2))
            path.line(to: NSPoint(x: c.x + h / 2, y: c.y + w / 2))
            path.line(to: NSPoint(x: c.x - h / 2, y: c.y))
        case (false, false): // right
            path.move(to: NSPoint(x: c.x - h / 2, y: c.y - w / 2))
            path.line(to: NSPoint(x: c.x - h / 2, y: c.y + w / 2))
            path.line(to: NSPoint(x: c.x + h / 2, y: c.y))
        }
        path.close()
        ListsPalette.arrowGlyph.setFill()
        path.fill()
    }

    // MARK: Mouse tracking

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch region(atLocal: p) {
        case .arrowBack: trackRepeating(.arrowBack, from: p) { $0.scrollLines(-1) }
        case .arrowForward: trackRepeating(.arrowForward, from: p) { $0.scrollLines(1) }
        case .pageBack: trackRepeating(.pageBack, from: p) { $0.scrollPage(-1) }
        case .pageForward: trackRepeating(.pageForward, from: p) { $0.scrollPage(1) }
        case .knob: trackKnobDrag(from: p)
        case .none: break
        }
    }

    /// One step now, then repeats while the button stays down and the pointer stays on the part.
    /// Periodic events (not a Timer) so it runs inside this modal loop like AppKit's own tracking.
    /// Page areas shrink as the knob moves, so the part is re-tested before every repeat: paging
    /// stops when the knob arrives under the pointer, as it did in Aqua.
    private func trackRepeating(_ region: Region, from start: NSPoint, step: (AquaScroller) -> Void) {
        pressedRegion = region
        needsDisplay = true
        step(self)
        NSEvent.startPeriodicEvents(afterDelay: Self.repeatDelay, withPeriod: Self.repeatInterval)
        defer {
            NSEvent.stopPeriodicEvents()
            pressedRegion = nil
            needsDisplay = true
        }
        var pointer = start
        while let event = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged, .periodic]) {
            switch event.type {
            case .leftMouseUp:
                return
            case .leftMouseDragged:
                pointer = convert(event.locationInWindow, from: nil)
                pressedRegion = self.region(atLocal: pointer) == region ? region : nil
                needsDisplay = true
            case .periodic:
                if self.region(atLocal: pointer) == region { step(self) }
            default:
                break
            }
        }
    }

    private func trackKnobDrag(from start: NSPoint) {
        let startValue = doubleValue
        let slot = slotRect.insetBy(dx: 1, dy: 1)
        let knob = knobRect
        let travel = isVertical ? slot.height - knob.height : slot.width - knob.width
        guard travel > 0 else { return }
        while let event = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            let p = convert(event.locationInWindow, from: nil)
            let delta = isVertical ? p.y - start.y : p.x - start.x
            scroll(toFraction: min(max(startValue + Double(delta / travel), 0), 1))
            if event.type == .leftMouseUp { break }
        }
    }

    // MARK: Scrolling the enclosing scroll view

    private var scrollView: NSScrollView? { (superview as? NSScrollView) ?? enclosingScrollView }

    /// Moves by whole lines (the scroll view's line scroll: one 17 or 18 pt row).
    func scrollLines(_ count: Int) {
        guard let sv = scrollView else { return }
        let line = isVertical ? sv.verticalLineScroll : sv.horizontalLineScroll
        scroll(by: CGFloat(count) * max(line, 1))
    }

    /// Moves by a screenful less one line, so the reader keeps context. The screenful excludes
    /// the header and scrollers laid over the clip view (its contentInsets).
    func scrollPage(_ direction: Int) {
        guard let sv = scrollView else { return }
        let clip = sv.contentView, insets = clip.contentInsets
        let visible = isVertical ? clip.bounds.height - insets.top - insets.bottom
                                 : clip.bounds.width - insets.left - insets.right
        let line = isVertical ? sv.verticalLineScroll : sv.horizontalLineScroll
        scroll(by: CGFloat(direction) * max(visible - line, line))
    }

    private func scroll(by delta: CGFloat) {
        guard let sv = scrollView else { return }
        let clip = sv.contentView
        var origin = clip.bounds.origin
        if isVertical { origin.y += delta } else { origin.x += delta }
        apply(origin, in: sv)
    }

    /// 0 = start of the document, 1 = end.
    func scroll(toFraction fraction: Double) {
        guard let sv = scrollView else { return }
        let clip = sv.contentView
        let size = clip.bounds.size
        let lo = clip.constrainBoundsRect(NSRect(origin: NSPoint(x: -1e9, y: -1e9), size: size)).origin
        let hi = clip.constrainBoundsRect(NSRect(origin: NSPoint(x: 1e9, y: 1e9), size: size)).origin
        var origin = clip.bounds.origin
        if isVertical {
            origin.y = lo.y + (hi.y - lo.y) * CGFloat(fraction)
        } else {
            origin.x = lo.x + (hi.x - lo.x) * CGFloat(fraction)
        }
        apply(origin, in: sv)
    }

    private func apply(_ origin: NSPoint, in sv: NSScrollView) {
        let clip = sv.contentView
        let constrained = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin
        let rounded = NSPoint(x: constrained.x.rounded(), y: constrained.y.rounded())
        guard rounded != clip.bounds.origin else { return }
        clip.scroll(to: rounded)
        sv.reflectScrolledClipView(clip)
    }
}
