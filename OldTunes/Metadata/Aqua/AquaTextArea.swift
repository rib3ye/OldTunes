import AppKit

/// The multi-line Comments box: same bezel and glow as `AquaTextField`, around an NSTextView.
/// Tab and Shift-Tab move between fields instead of typing a tab, Return is OK, Option-Return
/// types a newline.
@MainActor
final class AquaTextArea: NSView, NSTextViewDelegate {
    let textView = FocusReportingTextView()
    private let scroll = SquareScrollView()
    var onChange: (() -> Void)?

    private var isFocused = false { didSet { needsDisplay = true } }

    var stringValue: String {
        get { textView.string }
        set { textView.string = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.font = AquaStyle.smallFont
        textView.textColor = AquaStyle.text
        textView.insertionPointColor = AquaStyle.text
        textView.selectedTextAttributes = [.backgroundColor: AquaStyle.textSelection]
        textView.textContainerInset = NSSize(width: 0, height: 1)
        textView.textContainer?.lineFragmentPadding = 2
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.delegate = self
        textView.onFocusChange = { [weak self] focused in self?.isFocused = focused }
        scroll.documentView = textView
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    func setBezelFrame(_ rect: NSRect) {
        let m = AquaTextField.ringMargin
        frame = rect.insetBy(dx: -m, dy: -m)
        let inner = NSRect(x: m + 3, y: m + 2, width: rect.width - 6, height: rect.height - 4)
        scroll.frame = inner
        textView.frame = NSRect(x: 0, y: 0, width: inner.width, height: inner.height)
        textView.minSize = NSSize(width: 0, height: inner.height)
        textView.maxSize = NSSize(width: inner.width, height: .greatestFiniteMagnitude)
    }

    override func draw(_ dirtyRect: NSRect) {
        let m = AquaTextField.ringMargin
        let bezel = bounds.insetBy(dx: m, dy: m)
        AquaStyle.drawFieldBezel(in: bezel, flipped: true)
        if isFocused { AquaStyle.drawFocusRing(around: bezel) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(textView)
    }

    func textDidChange(_ notification: Notification) { onChange?() }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertTab(_:)):
            window?.selectNextKeyView(nil)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            window?.selectPreviousKeyView(nil)
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            textView.insertText("\n", replacementRange: textView.selectedRange())
            return true
        default:
            return AquaKeyRouting.route(selector, in: window)
        }
    }
}

@MainActor
final class FocusReportingTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocusChange?(false) }
        return ok
    }
}

/// macOS 27 rounds an in-window scroll view's corners on its own (RESEARCH.md §8.1), which would
/// nick the square 2005 bezel; opting out of the corner configuration keeps it square.
@MainActor
final class SquareScrollView: NSScrollView {
    @available(macOS 27.0, *)
    override var cornerConfiguration: NSViewCornerConfiguration? { nil }
}
