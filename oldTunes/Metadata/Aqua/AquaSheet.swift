import AppKit

/// A 10.4 alert sheet, hand-drawn because NSAlert's buttons are Liquid Glass: disc icon at the
/// left, bold message, small informative text, an optional scrolling detail box, an optional
/// checkbox, and gel buttons along the bottom right with the default one in blue.
///
/// `run(on:)` slides it out of a window; `runModal()` shows the same alert app-modal when there
/// is no window to hang it on. Code outside Get Info should use `RetroAlert`, which picks.
@MainActor
final class AquaSheet {
    struct Result: Sendable { var buttonIndex: Int; var checkboxOn: Bool }

    /// The alert on screen, so the harness can photograph it and press its buttons.
    private(set) static var presented: AquaSheet?

    let window: AquaWindow
    /// What the sheet says and offers, so the harness can tell which sheet came up.
    let message: String
    let informative: String
    let buttonTitles: [String]
    private let checkbox: AquaCheckbox?
    private var buttons: [AquaButton] = []
    private var continuation: CheckedContinuation<Result, Never>?
    private weak var parent: NSWindow?
    /// True while `runModal()` is waiting.
    private var isRunningModal = false

    private static let width: CGFloat = 440

    /// `buttons` read left to right; the LAST one is the default (Return), and `cancelIndex`
    /// (if any) answers Escape.
    init(message: String, informative: String, details: String? = nil,
         checkboxTitle: String? = nil, buttons titles: [String], cancelIndex: Int? = nil) {
        let textX: CGFloat = 86
        let textWidth = Self.width - textX - 22
        let messageAttrs = AquaStyle.attributes(AquaStyle.titleBold13, lineBreak: .byWordWrapping)
        let infoAttrs = AquaStyle.attributes(AquaStyle.smallFont, lineBreak: .byWordWrapping)
        let messageHeight = Self.height(of: message, attrs: messageAttrs, width: textWidth)
        let infoHeight = informative.isEmpty ? 0 : Self.height(of: informative, attrs: infoAttrs, width: textWidth)

        var y: CGFloat = 20
        let messageFrame = NSRect(x: textX, y: y, width: textWidth, height: messageHeight)
        y += messageHeight + 8
        let infoFrame = NSRect(x: textX, y: y, width: textWidth, height: infoHeight)
        y += infoHeight + (informative.isEmpty ? 0 : 10)

        var detailsFrame: NSRect?
        if let details, !details.isEmpty {
            let h = min(140, max(40, Self.height(of: details, attrs: infoAttrs, width: textWidth - 12) + 10))
            detailsFrame = NSRect(x: textX, y: y, width: textWidth, height: h)
            y += h + 12
        }

        var checkboxFrame: NSRect?
        var box: AquaCheckbox?
        if let checkboxTitle {
            let c = AquaCheckbox(title: checkboxTitle)
            checkboxFrame = NSRect(x: textX, y: y, width: c.fittingSize.width, height: c.fittingSize.height)
            box = c
            y += c.fittingSize.height + 12
        }
        y = max(y, 20 + 64 + 8)
        let buttonY = y + 6
        let height = buttonY + AquaButton.height + 18

        window = AquaWindow(contentSize: NSSize(width: Self.width, height: height), title: message)
        // 10.4 alerts had no close box, and ⌘W closing one would strand whoever waits on it.
        window.styleMask.remove(.closable)
        self.message = message
        self.informative = informative
        buttonTitles = titles
        checkbox = box
        let face = window.contentView as? AquaWindowView
        face?.showsTitleBar = false

        let content = AlertContentView(frame: NSRect(x: 0, y: 0, width: Self.width, height: height))
        content.message = (message, messageFrame, messageAttrs)
        content.informative = (informative, infoFrame, infoAttrs)
        content.iconFrame = NSRect(x: 18, y: 18, width: 56, height: 56)
        content.autoresizingMask = [.width, .height]
        face?.addSubview(content)

        if let detailsFrame, let details {
            let area = AquaTextArea()
            area.setBezelFrame(detailsFrame)
            area.stringValue = details
            area.textView.isEditable = false
            face?.addSubview(area)
        }
        if let box, let checkboxFrame {
            box.frame = checkboxFrame
            face?.addSubview(box)
        }

        var x = Self.width - 20
        for (index, title) in titles.enumerated().reversed() {
            let w = AquaButton.width(for: title)
            x -= w
            let button = AquaButton(title: title, isDefault: index == titles.count - 1)
            button.frame = NSRect(x: x, y: buttonY, width: w, height: AquaButton.height)
            button.onPress = { [weak self] in self?.finish(index) }
            face?.addSubview(button)
            buttons.insert(button, at: 0)
            x -= 12
        }
        window.onReturn = { [weak self] in self?.finish(titles.count - 1) }
        if let cancelIndex { window.onEscape = { [weak self] in self?.finish(cancelIndex) } }
    }

    /// Slides the sheet out of `parent` and waits for a button.
    func run(on parent: NSWindow) async -> Result {
        self.parent = parent
        Self.presented = self
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            parent.beginSheet(window)
            // Nothing in an alert starts focused; otherwise the detail box would wear a glow.
            window.makeFirstResponder(nil)
        }
    }

    /// The same alert as a free-standing window, app-modal like `NSAlert.runModal()`: it blocks
    /// until a button is pressed. Placed as 10.4 placed alerts, centred across the screen and a
    /// third of the way down.
    func runModal() -> Result {
        Self.presented = self
        isRunningModal = true
        window.level = .modalPanel
        if let screen = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame {
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: (screen.midX - size.width / 2).rounded(),
                                          y: (screen.maxY - screen.height / 3 - size.height / 2).rounded()))
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)
        let response = NSApp.runModal(for: window)
        isRunningModal = false
        window.orderOut(nil)
        if Self.presented === self { Self.presented = nil }
        return Result(buttonIndex: response.rawValue, checkboxOn: checkbox?.isOn ?? false)
    }

    /// Presses a button as if clicked. Used by the harness after it photographs the sheet.
    func press(_ index: Int) {
        guard buttons.indices.contains(index) else { return }
        buttons[index].performClick(nil)
    }

    func setCheckbox(_ on: Bool) { checkbox?.isOn = on }

    private func finish(_ index: Int) {
        if isRunningModal {
            guard NSApp.modalWindow === window else { return }
            NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: index))
            // The modal loop only notices the stop after an event; a press that came from a timer
            // or a task rather than a click would otherwise wait for the next mouse move.
            if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                             timestamp: 0, windowNumber: 0, context: nil,
                                             subtype: 0, data1: 0, data2: 0) {
                NSApp.postEvent(wake, atStart: true)
            }
            return
        }
        guard let continuation else { return }
        self.continuation = nil
        parent?.endSheet(window)
        window.orderOut(nil)
        if Self.presented === self { Self.presented = nil }
        continuation.resume(returning: Result(buttonIndex: index, checkboxOn: checkbox?.isOn ?? false))
    }

    private static func height(of text: String, attrs: [NSAttributedString.Key: Any], width: CGFloat) -> CGFloat {
        ceil((text as NSString).boundingRect(with: NSSize(width: width, height: 10_000),
                                             options: [.usesLineFragmentOrigin], attributes: attrs).height)
    }
}

/// The static part of an alert: icon and wrapped text.
@MainActor
private final class AlertContentView: NSView {
    var message: (String, NSRect, [NSAttributedString.Key: Any]) = ("", .zero, [:])
    var informative: (String, NSRect, [NSAttributedString.Key: Any]) = ("", .zero, [:])
    var iconFrame = NSRect.zero

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        AquaIcons.drawDisc(in: iconFrame)
        (message.0 as NSString).draw(with: message.1, options: [.usesLineFragmentOrigin], attributes: message.2)
        (informative.0 as NSString).draw(with: informative.1, options: [.usesLineFragmentOrigin], attributes: informative.2)
    }
}
