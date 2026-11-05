import AppKit

/// The sage "LCD" status display (RESEARCH.md §7.4): a recessed capsule with two centred lines,
/// a scrubber, and two small round end buttons. In the dark appearance it is the same panel in
/// its night mode (§7.7): a negative display, dark olive glass with the characters lit in the
/// day panel's sage, glowing faintly.
///
/// Line 1 is the title. Line 2 starts on "Elapsed Time: m:ss", as in both iTunes 4.9 references
/// (itunes_old_big.jpg, vm_49.jpg); clicking it, or the left end button, cycles to "Remaining
/// Time: m:ss" (no minus sign, as vm_49.jpg shows it) and then "Artist — Album". While a cloud
/// song is being prepared line 2 says "Loading…" rather than a clock stuck at 0:00, and when
/// playback reports a new error line 2 shows it for `messageDuration` seconds before going back to
/// what it was showing. Dragging the scrubber suspends state-driven position updates until
/// mouse-up, then seeks once.
@MainActor
final class ChromeLCDView: NSView {
    enum DetailMode: CaseIterable { case elapsed, remaining, artistAlbum }
    enum EndButton { case left, right }

    var onSeek: ((TimeInterval) -> Void)?
    /// The right end button: iTunes' "snap back" to the playing song. Fires on mouse-up inside the
    /// button, like any push button; the button draws pressed while held.
    var onRevealNowPlaying: (() -> Void)?

    /// How long a new playback error stays on line 2.
    static let messageDuration: TimeInterval = 4
    static let loadingText = "Loading…"

    private(set) var state = PlaybackState()
    private(set) var detailMode: DetailMode = .elapsed
    /// The playback error line 2 is showing, if any. Set when `lastError` changes to a new
    /// non-nil value; cleared after `messageDuration`, when `lastError` clears, or on a click.
    private(set) var message: String?
    private var messageExpiry: Task<Void, Never>?
    /// The end button the mouse went down on, and whether it is drawn pressed (the mouse is
    /// still over it).
    private var trackedButton: EndButton?
    private(set) var pressedButton: EndButton?
    private(set) var isScrubbing = false
    /// How many times the LCD has drawn, so the chrome harness can see that an expiring message
    /// redraws it with no state update to prompt one.
    private(set) var drawCount = 0
    private var idleLines = (line1: "oldTunes", line2: "")
    private var scrubFraction: Double = 0
    /// The song the drag started on. If playback moves to another song (or stops) mid-drag, the
    /// drag is dropped on mouse-up rather than seeking into the wrong song.
    private var scrubTrackID: Track.ID?
    /// After a seek the player takes a moment to report the new position; hold the thumb on the
    /// target until it does, so it does not flick back to the old spot.
    private var pendingSeek: (target: TimeInterval, until: Date)?

    // Window-relative values (§7.2, text baselines re-measured in ChromeMetrics), made local to
    // the LCD's top at window y 28.
    static let line1Baseline = ChromeMetrics.lcdLine1Baseline - Theme.Metrics.lcdTop
    static let line2Baseline = ChromeMetrics.lcdLine2Baseline - Theme.Metrics.lcdTop
    static let scrubberTop = Theme.Metrics.scrubberTop - Theme.Metrics.lcdTop
    /// The scrubber is 73 pt shorter than the LCD (313 vs 240), at every LCD width.
    static let scrubberInset = Theme.Metrics.lcdSize.width - Theme.Metrics.scrubberSize.width
    /// End-button size and centre inset, re-measured from the reference (see ChromeMetrics).
    static let endButtonDiameter = ChromeMetrics.lcdEndButtonDiameter
    static let endButtonInset = ChromeMetrics.lcdEndButtonInset
    /// Text stays clear of the end buttons.
    static let textInset: CGFloat = 26

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    /// Acts on the first click even in an inactive window, as Aqua window and media buttons did.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - State

    func update(_ newState: PlaybackState) {
        if let pending = pendingSeek,
           Date() > pending.until || abs(newState.position - pending.target) < 1.5
            || newState.nowPlaying?.id != state.nowPlaying?.id {
            pendingSeek = nil
            // The thumb was drawn at the target; it must move back to the player's position
            // even when this state is identical to the last one.
            needsDisplay = true
        }
        guard newState != state else { return }
        let previousError = state.lastError
        state = newState
        if newState.lastError != previousError {
            if let error = newState.lastError { show(message: error) } else { dismissMessage() }
        }
        refreshToolTip()
        needsDisplay = true
    }

    /// Puts `text` on line 2 for `messageDuration` seconds, restarting the time if a message was
    /// already up. The expiry redraws by itself, so it also clears while paused, when no state
    /// updates arrive.
    private func show(message text: String) {
        message = text
        messageExpiry?.cancel()
        messageExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.messageDuration))
            guard !Task.isCancelled else { return }
            self?.dismissMessage()
        }
        refreshToolTip()
        needsDisplay = true
    }

    private func dismissMessage() {
        messageExpiry?.cancel()
        messageExpiry = nil
        guard message != nil else { return }
        message = nil
        refreshToolTip()
        needsDisplay = true
    }

    /// The LCD truncates a long reason, so whenever line 2 shows one the tooltip holds all of it.
    private func refreshToolTip() {
        let reason = message ?? (state.nowPlaying == nil ? state.lastError : nil)
        if toolTip != reason { toolTip = reason }
    }

    func setIdleText(_ line1: String, _ line2: String) {
        idleLines = (line1, line2)
        if state.nowPlaying == nil { needsDisplay = true }
    }

    /// The position the thumb shows: the drag, then a pending seek, then the player.
    var displayedPosition: TimeInterval {
        if isScrubbing { return scrubFraction * state.duration }
        if let pendingSeek { return pendingSeek.target }
        return state.position
    }

    var lines: (String, String) {
        guard let track = state.nowPlaying else {
            if let message { return (idleLines.line1, message) }
            if state.isLoading { return (idleLines.line1, Self.loadingText) }
            // With nothing playing, the reason the last song could not play stays up.
            return (idleLines.line1, state.lastError ?? idleLines.line2)
        }
        let title = track.displayTitle
        // A drag shows where it will land; it is the user's own action, so it wins over the rest.
        if isScrubbing { return (title, "Elapsed Time: \(Self.clock(displayedPosition))") }
        if let message { return (title, message) }
        if state.isLoading { return (title, Self.loadingText) }
        switch detailMode {
        case .elapsed:
            return (title, "Elapsed Time: \(Self.clock(displayedPosition))")
        case .remaining:
            return (title, "Remaining Time: \(Self.clock(max(0, state.duration - displayedPosition)))")
        case .artistAlbum:
            return (title, [track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " — "))
        }
    }

    func cycleDetailMode() {
        let all = DetailMode.allCases
        detailMode = all[((all.firstIndex(of: detailMode) ?? 0) + 1) % all.count]
        needsDisplay = true
    }

    /// A click on line 2 or the left end button: dismisses an error that is showing, otherwise
    /// moves to the next detail mode.
    private func lineClicked() {
        if message != nil { dismissMessage() } else { cycleDetailMode() }
    }

    /// iTunes time format: m:ss, or h:mm:ss past an hour.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    // MARK: - Geometry

    /// The capsule itself; the view is 1 pt taller to hold the lip underneath.
    var panelRect: NSRect { NSRect(x: 0, y: 0, width: bounds.width, height: Theme.Metrics.lcdSize.height) }

    var scrubberRect: NSRect {
        let w = max(40, bounds.width - Self.scrubberInset)
        return NSRect(x: ((bounds.width - w) / 2).rounded(), y: Self.scrubberTop,
                      width: w, height: Theme.Metrics.scrubberSize.height)
    }

    private var line2Rect: NSRect {
        NSRect(x: Self.textInset, y: Self.line1Baseline + 3, width: bounds.width - 2 * Self.textInset,
               height: Self.scrubberTop - Self.line1Baseline - 3)
    }

    private func endButtonCenter(left: Bool) -> NSPoint {
        NSPoint(x: left ? Self.endButtonInset : bounds.width - Self.endButtonInset, y: panelRect.midY)
    }

    /// The end button under `p`, with a point of slack around each.
    private func endButton(at p: NSPoint) -> EndButton? {
        let d = Self.endButtonDiameter / 2 + 1
        for (button, left) in [(EndButton.left, true), (.right, false)] {
            let c = endButtonCenter(left: left)
            if hypot(p.x - c.x, p.y - c.y) <= d { return button }
        }
        return nil
    }

    private var canScrub: Bool { state.nowPlaying != nil && state.duration > 0 }

    private func fraction(atX x: CGFloat) -> Double {
        let r = scrubberRect
        return Double(min(max((x - r.minX - 1) / (r.width - 2), 0), 1))
    }

    // MARK: - Mouse

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        let r = panelRect.height / 2
        return NSBezierPath(roundedRect: panelRect, xRadius: r, yRadius: r).contains(p) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if canScrub, scrubberRect.insetBy(dx: -4, dy: -3).contains(p) {
            isScrubbing = true
            scrubTrackID = state.nowPlaying?.id
            scrubFraction = fraction(atX: p.x)
            needsDisplay = true
        } else if let button = endButton(at: p) {
            // Push buttons act on release, so a press can still be dragged off and abandoned.
            trackedButton = button
            pressedButton = button
            needsDisplay = true
        } else if state.nowPlaying != nil || message != nil, line2Rect.contains(p) {
            lineClicked()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let button = trackedButton {
            let pressed = endButton(at: p) == button ? button : nil
            if pressed != pressedButton {
                pressedButton = pressed
                needsDisplay = true
            }
            return
        }
        guard isScrubbing else { return }
        scrubFraction = fraction(atX: p.x)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let button = trackedButton {
            trackedButton = nil
            pressedButton = nil
            needsDisplay = true
            guard endButton(at: p) == button else { return }
            switch button {
            case .left: lineClicked()
            case .right: onRevealNowPlaying?()
            }
            return
        }
        guard isScrubbing else { return }
        isScrubbing = false
        needsDisplay = true
        guard canScrub, state.nowPlaying?.id == scrubTrackID else { return }
        scrubFraction = fraction(atX: p.x)
        let target = scrubFraction * state.duration
        pendingSeek = (target, Date().addingTimeInterval(1.5))
        onSeek?(target)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        drawCount += 1
        drawCapsule()
        drawEndButtons()

        let (line1, line2) = lines
        let textWidth = bounds.width - 2 * Self.textInset
        let glow = ChromePalette.lcdGlow
        ChromeDraw.text(line1, centerX: bounds.midX, baseline: Self.line1Baseline, maxWidth: textWidth,
                        color: Theme.lcdInk, glow: glow)
        ChromeDraw.text(line2, centerX: bounds.midX, baseline: Self.line2Baseline, maxWidth: textWidth,
                        color: Theme.lcdInk, glow: glow)

        if state.nowPlaying != nil { drawScrubber() }
    }

    /// Recessed capsule: darkest along the top, `lcdBorderSide` down the sides, a light inner
    /// bottom row, and a cool row under the outside (§7.4).
    private func drawCapsule() {
        let full = panelRect
        let radius = full.height / 2
        let lip = full.offsetBy(dx: 0, dy: 1)
        Theme.lcdOuterBottom.setFill()
        NSBezierPath(roundedRect: lip, xRadius: radius, yRadius: radius).fill()

        let rim = NSBezierPath(roundedRect: full, xRadius: radius, yRadius: radius)
        let h = full.height
        ChromeDraw.fill(rim, with: ChromeDraw.gradient(
            [Theme.lcdBorderTop, Theme.lcdBorderSide, Theme.lcdBorderSide, Theme.lcdInnerHighlight],
            [0, 2 / h, 0.8, 1]), top: full.minY, bottom: full.maxY)

        let inner = full.insetBy(dx: 1, dy: 1)
        let innerPath = NSBezierPath(roundedRect: inner, xRadius: inner.height / 2, yRadius: inner.height / 2)
        Theme.lcdBG.setFill()
        innerPath.fill()
        if let backlight = ChromePalette.lcdBacklight {
            // A circle the panel's width, squashed to an ellipse 1.5 panel-heights tall.
            NSGraphicsContext.saveGraphicsState()
            innerPath.addClip()
            let squash = NSAffineTransform()
            squash.translateX(by: inner.midX, yBy: inner.midY)
            squash.scaleX(by: 1, yBy: 1.5 * inner.height / inner.width)
            squash.concat()
            backlight.draw(fromCenter: .zero, radius: 0, toCenter: .zero, radius: inner.width / 2, options: [])
            NSGraphicsContext.restoreGraphicsState()
        }
        // Inner shadow under the top edge, so the panel reads as sunk into the metal.
        ChromeDraw.fill(innerPath, with: ChromeDraw.gradient(
            [ChromePalette.lcdInnerShadow, Theme.lcdBG.withAlphaComponent(0)], [0, 1]),
            top: inner.minY, bottom: inner.minY + 3)
    }

    private func drawEndButtons() {
        let r = Self.endButtonDiameter / 2
        // The glyphs were drawn for a 13 pt button; scale them with the button.
        let k = Self.endButtonDiameter / 13
        for left in [true, false] {
            let c = endButtonCenter(left: left)
            let pressed = pressedButton == (left ? .left : .right)
            (pressed ? ChromePalette.lcdEndButtonPressed : ChromePalette.lcdEndButton).setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)).fill()
            Theme.lcdBG.setFill()
            Theme.lcdBG.setStroke()
            if left {
                let play = NSBezierPath()
                play.move(to: NSPoint(x: c.x - 1.8 * k, y: c.y - 3.4 * k))
                play.line(to: NSPoint(x: c.x + 3.4 * k, y: c.y))
                play.line(to: NSPoint(x: c.x - 1.8 * k, y: c.y + 3.4 * k))
                play.close()
                play.fill()
            } else {
                // Snap-back arrow: a hook curling over the top to an arrowhead at the left.
                let hook = NSBezierPath()
                hook.lineWidth = 1.4 * k
                hook.move(to: NSPoint(x: c.x + 1.2 * k, y: c.y + 3.3 * k))
                hook.curve(to: NSPoint(x: c.x - 0.6 * k, y: c.y - 1.6 * k),
                           controlPoint1: NSPoint(x: c.x + 4.6 * k, y: c.y + 1.6 * k),
                           controlPoint2: NSPoint(x: c.x + 2.6 * k, y: c.y - 2.6 * k))
                hook.stroke()
                let head = NSBezierPath()
                head.move(to: NSPoint(x: c.x - 3.6 * k, y: c.y - 1.3 * k))
                head.line(to: NSPoint(x: c.x - 0.2 * k, y: c.y - 4.2 * k))
                head.line(to: NSPoint(x: c.x + 0.2 * k, y: c.y + 1.2 * k))
                head.close()
                head.fill()
            }
        }
    }

    /// A 1 pt outline and a diamond thumb. The interior stays the panel's `lcdBG` on both sides of
    /// the thumb, with no fill for the played part: §7.4, and both iTunes 4.9 references
    /// (itunes_old_big.jpg reads the same green, 219, left and right of the thumb). At night the
    /// outline and thumb are lit like the text.
    private func drawScrubber() {
        let r = scrubberRect
        let fraction = state.duration > 0 ? min(max(displayedPosition / state.duration, 0), 1) : 0
        let thumbX = r.minX + 1 + CGFloat(fraction) * (r.width - 2)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        ChromePalette.lcdScrubberGlow?.set()
        Theme.lcdScrubOutline.setStroke()
        let outline = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1
        outline.stroke()

        let half = Theme.Metrics.scrubberThumb / 2
        let diamond = NSBezierPath()
        diamond.move(to: NSPoint(x: thumbX, y: r.midY - half - 0.5))
        diamond.line(to: NSPoint(x: thumbX + half, y: r.midY))
        diamond.line(to: NSPoint(x: thumbX, y: r.midY + half + 0.5))
        diamond.line(to: NSPoint(x: thumbX - half, y: r.midY))
        diamond.close()
        Theme.lcdScrubOutline.setFill()
        diamond.fill()
    }
}
