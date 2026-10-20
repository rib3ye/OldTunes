import AppKit

/// A 10.4 push button: a 21 pt gel capsule. White normally, blue while pressed (Aqua turned a
/// pressed button blue), and blue at rest when it is the default button — OK in Get Info. The
/// default button breathes in the key window, the slow pulse every 2005 dialog had.
@MainActor
final class AquaButton: NSControl {
    var title: String { didSet { needsDisplay = true } }
    var isDefault = false { didSet { needsDisplay = true; updatePulse() } }
    var onPress: (() -> Void)?

    private var isPressed = false { didSet { needsDisplay = true } }
    private var pulseTimer: Timer?
    /// Seconds per breath. Chosen by eye to match the remembered 10.4 rhythm, not measured.
    private static let pulsePeriod: Double = 1.6
    /// Pulse timers still scheduled; the harness checks closed windows leave none behind.
    private(set) static var livePulseTimers = 0

    static let height: CGFloat = 21

    init(title: String, isDefault: Bool = false, onPress: (() -> Void)? = nil) {
        self.title = title
        self.isDefault = isDefault
        self.onPress = onPress
        super.init(frame: NSRect(x: 0, y: 0, width: 80, height: Self.height))
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var isEnabled: Bool { didSet { needsDisplay = true } }
    /// Tiger's default keyboard access ("text boxes and lists only") skipped buttons and
    /// checkboxes, and nothing here draws a focus ring, so Tab would otherwise vanish into it.
    override var acceptsFirstResponder: Bool { false }

    /// The width a 10.4 button would take for its title: 13 pt Lucida Grande plus 18 pt of
    /// padding a side, never narrower than 69 pt (the HIG minimum then).
    static func width(for title: String) -> CGFloat {
        let w = (title as NSString).size(withAttributes: [.font: AquaStyle.controlFont]).width
        return max(69, (w + 36).rounded())
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = NSRect(x: 0.5, y: 0, width: bounds.width - 1, height: Self.height - 1)
        let gel: AquaStyle.Gel
        if !isEnabled { gel = AquaStyle.disabledGel }
        else if isPressed { gel = AquaStyle.bluePressedGel }
        else if isDefault { gel = AquaStyle.blueGel.blended(with: AquaStyle.blueGelBright, fraction: pulseFraction) }
        else { gel = AquaStyle.whiteGel }
        AquaStyle.drawGel(in: rect, radius: rect.height / 2, gel: gel, flipped: true)

        let color = isEnabled ? AquaStyle.text : AquaStyle.textDisabled
        let attrs = AquaStyle.engravedAttributes(AquaStyle.controlFont, color: color, alignment: .center)
        let textRect = NSRect(x: 6, y: 2.5, width: bounds.width - 12, height: 16)
        (title as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin], attributes: attrs)
    }

    // MARK: Pulse

    private var pulseFraction: CGFloat {
        guard pulseTimer != nil, window?.isKeyWindow == true else { return 0 }
        let phase = Date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.pulsePeriod) / Self.pulsePeriod
        return CGFloat((1 - cos(phase * 2 * .pi)) / 2) * 0.8
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updatePulse()
    }

    private func updatePulse() {
        let wanted = isDefault && window != nil
        if wanted, pulseTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
                // A released window detaches its views, so viewDidMoveToWindow(nil) normally stops
                // this (measured: 20 of 20). The run loop would keep an outliving timer forever,
                // so one that finds its button gone ends itself as a backstop.
                let buttonAlive = MainActor.assumeIsolated { () -> Bool in
                    guard let self else {
                        AquaButton.livePulseTimers -= 1
                        return false
                    }
                    if self.window?.isKeyWindow == true, self.isEnabled { self.needsDisplay = true }
                    return true
                }
                if !buttonAlive { timer.invalidate() }
            }
            RunLoop.main.add(timer, forMode: .common)
            pulseTimer = timer
            Self.livePulseTimers += 1
        } else if !wanted, let timer = pulseTimer {
            timer.invalidate()
            pulseTimer = nil
            Self.livePulseTimers -= 1
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let window else { return }
        isPressed = true
        // Classic button tracking: pressed only while the pointer is inside.
        while true {
            guard let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            let inside = bounds.contains(convert(next.locationInWindow, from: nil))
            if next.type == .leftMouseUp {
                isPressed = false
                if inside { performClick(nil) }
                return
            }
            isPressed = inside
        }
        isPressed = false
    }

    override func performClick(_ sender: Any?) {
        guard isEnabled else { return }
        onPress?()
        if let action { NSApp.sendAction(action, to: target, from: self) }
    }

    override func accessibilityPerformPress() -> Bool {
        performClick(nil)
        return true
    }
}
