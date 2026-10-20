import AppKit

/// Settings (⌘,): the Appearance choice, in a 10.4 pinstriped dialog built from the same Aqua
/// pieces as Get Info. iTunes 4.9 called this window Preferences, but macOS renames the menu item
/// to "Settings…" whatever the app asks for, so the window carries the name the menu gives it.
/// iTunes' Preferences had Cancel and OK, so this does too: picking an appearance shows it at
/// once, OK keeps it, and Cancel, Escape or the close button put back what was showing when the
/// window opened.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: SettingsWindowController?

    /// Brings the window up, making it the first time.
    static func show() {
        let controller = shared ?? SettingsWindowController()
        shared = controller
        controller.present()
    }

    /// The open window's controller, for the harness.
    static var current: SettingsWindowController? { shared?.window?.isVisible == true ? shared : nil }

    /// Where AppKit saves the window's frame in UserDefaults; the appearance harness puts it back.
    static let frameDefaultsKey = "NSWindow Frame \(frameName)"
    private static let frameName = "OldTunesSettings"

    private let aquaWindow: AquaWindow
    private let radios: [(mode: AppearanceMode, button: AquaRadioButton)]
    let okButton = AquaButton(title: "OK", isDefault: true)
    let cancelButton = AquaButton(title: "Cancel")
    /// What was applied when the window opened; Cancel goes back to it.
    private var modeAtOpen: AppearanceMode = .system
    private(set) var picked: AppearanceMode = .system

    // Flipped window points, in the Get Info window's proportions (GetInfoLayout).
    private static let width = GetInfoLayout.windowWidth
    private static let boxTop: CGFloat = 40
    private static let labelRight: CGFloat = 146
    private static let radioLeft: CGFloat = 156
    private static let radioPitch: CGFloat = 22

    private init() {
        let L = GetInfoLayout.self
        radios = AppearanceMode.allCases.map { ($0, AquaRadioButton(title: $0.title)) }

        let firstRadioY = Self.boxTop + 18
        let noteX = Self.radioLeft + AquaRadioButton.diameter + 6
        let noteWidth = Self.width - L.boxInsetX - 16 - noteX
        let note = FormKit.label("Follows System Settings ▸ Appearance, and switches when your Mac does.",
                                 color: AquaStyle.noteText)
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 0
        note.preferredMaxLayoutWidth = noteWidth
        let noteY = firstRadioY + CGFloat(radios.count - 1) * Self.radioPitch + 19
        let noteHeight = ceil(note.sizeThatFits(NSSize(width: noteWidth, height: 200)).height)
        let boxBottom = noteY + noteHeight + 16
        let buttonsY = boxBottom + 14
        let size = NSSize(width: Self.width, height: buttonsY + AquaButton.height + L.bottomMargin + 2)
        aquaWindow = AquaWindow(contentSize: size, title: "Settings")
        super.init(window: aquaWindow)
        aquaWindow.delegate = self

        guard let face = aquaWindow.contentView else { return }
        let box = AquaBoxView(frame: NSRect(x: L.boxInsetX, y: Self.boxTop, width: size.width - 2 * L.boxInsetX,
                                            height: boxBottom - Self.boxTop))
        face.addSubview(box)

        let label = FormKit.label("Appearance:", font: AquaStyle.controlFont, alignment: .right)
        label.frame = NSRect(x: L.boxInsetX + 8, y: firstRadioY, width: Self.labelRight - L.boxInsetX - 8, height: 17)
        face.addSubview(label)
        for (i, entry) in radios.enumerated() {
            let button = entry.button
            button.setFrameOrigin(NSPoint(x: Self.radioLeft, y: firstRadioY + CGFloat(i) * Self.radioPitch))
            button.onPick = { [weak self] in self?.pick(entry.mode) }
            face.addSubview(button)
        }
        note.frame = NSRect(x: noteX, y: noteY, width: noteWidth, height: noteHeight)
        face.addSubview(note)

        let okW = max(80, AquaButton.width(for: okButton.title))
        let cancelW = max(80, AquaButton.width(for: cancelButton.title))
        okButton.frame = NSRect(x: size.width - L.boxInsetX - okW, y: buttonsY, width: okW, height: AquaButton.height)
        cancelButton.frame = NSRect(x: okButton.frame.minX - L.buttonGap - cancelW, y: buttonsY,
                                    width: cancelW, height: AquaButton.height)
        okButton.onPress = { [weak self] in self?.okPressed() }
        cancelButton.onPress = { [weak self] in self?.cancelPressed() }
        face.addSubview(cancelButton)
        face.addSubview(okButton)

        aquaWindow.onReturn = { [weak self] in self?.okPressed() }
        aquaWindow.onEscape = { [weak self] in self?.cancelPressed() }
        aquaWindow.center()
        aquaWindow.setFrameAutosaveName(Self.frameName)
    }

    required init?(coder: NSCoder) { nil }

    func radio(for mode: AppearanceMode) -> AquaRadioButton? { radios.first { $0.mode == mode }?.button }

    private func present() {
        if !(window?.isVisible ?? false) {
            modeAtOpen = AppearancePreference.current
            show(picked: AppearancePreference.saved)
        }
        showWindow(nil)
        aquaWindow.makeKeyAndOrderFront(nil)
        aquaWindow.makeFirstResponder(nil)
    }

    private func show(picked mode: AppearanceMode) {
        picked = mode
        for entry in radios { entry.button.isOn = entry.mode == mode }
    }

    /// A radio was clicked: show that appearance now, saving nothing yet.
    private func pick(_ mode: AppearanceMode) {
        show(picked: mode)
        AppearancePreference.choose(mode, save: false)
    }

    private func okPressed() {
        AppearancePreference.choose(picked, save: true)
        aquaWindow.orderOut(nil)
    }

    private func cancelPressed() {
        AppearancePreference.choose(modeAtOpen, save: false)
        aquaWindow.orderOut(nil)
    }

    // MARK: NSWindowDelegate

    /// The close button and ⌘W mean Cancel, as in any 10.4 dialog.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancelPressed()
        return false
    }
}
