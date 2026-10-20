import AppKit

/// Settings (⌘,): the Appearance choice, Sound Check and the visualizer's HDR switch, in a 10.4
/// pinstriped dialog built from the same Aqua pieces as Get Info. iTunes 4.9 called this window Preferences, but macOS renames
/// the menu item to "Settings…" whatever the app asks for, so the window carries the name the menu
/// gives it. iTunes' Preferences had Cancel and OK, so this does too: picking an appearance or
/// clicking a checkbox takes effect at once, OK keeps it, and Cancel, Escape or the close button
/// put back what was on when the window opened.
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
    /// Music's own words, from its Settings ▸ Playback.
    let soundCheckBox = AquaCheckbox(title: "Sound Check", font: AquaStyle.controlFont)
    /// Visualizer ▸ HDR. Only on macOS 14.2 and later, where the visualizer exists.
    let hdrCheckbox = AquaCheckbox(title: "Use HDR when the screen supports it", font: AquaStyle.controlFont)
    let okButton = AquaButton(title: "OK", isDefault: true)
    let cancelButton = AquaButton(title: "Cancel")
    /// What was applied when the window opened; Cancel goes back to it.
    private var modeAtOpen: AppearanceMode = .system
    private var soundCheckAtOpen = false
    private var hdrAtOpen = true
    private(set) var picked: AppearanceMode = .system

    // Flipped window points, in the Get Info window's proportions (GetInfoLayout).
    private static let width = GetInfoLayout.windowWidth
    private static let boxTop: CGFloat = 40
    private static let labelRight: CGFloat = 146
    private static let radioLeft: CGFloat = 156
    private static let radioPitch: CGFloat = 22
    /// From a row's top to the top of the note under it.
    private static let noteOffset: CGFloat = 19
    /// Between one row's note and the next row.
    private static let groupGap: CGFloat = 14

    private init() {
        let L = GetInfoLayout.self
        radios = AppearanceMode.allCases.map { ($0, AquaRadioButton(title: $0.title)) }

        let firstRadioY = Self.boxTop + 18
        let noteX = Self.radioLeft + AquaRadioButton.diameter + 6
        let noteWidth = Self.width - L.boxInsetX - 16 - noteX
        let note = Self.note("Follows System Settings ▸ Appearance, and switches when your Mac does.", width: noteWidth)
        let noteY = firstRadioY + CGFloat(radios.count - 1) * Self.radioPitch + Self.noteOffset
        let soundCheckY = noteY + note.frame.height + Self.groupGap
        let soundCheckNote = Self.note("Automatically adjusts song playback volume to the same level.", width: noteWidth)
        let soundCheckNoteY = soundCheckY + Self.noteOffset
        let showsVisualizer = VisualizerController.isSupported
        let visualizerY = soundCheckNoteY + soundCheckNote.frame.height + Self.groupGap
        let boxBottom = showsVisualizer ? visualizerY + hdrCheckbox.frame.height + 16
                                        : soundCheckNoteY + soundCheckNote.frame.height + 16
        let buttonsY = boxBottom + 14
        let size = NSSize(width: Self.width, height: buttonsY + AquaButton.height + L.bottomMargin + 2)
        aquaWindow = AquaWindow(contentSize: size, title: "Settings")
        super.init(window: aquaWindow)
        aquaWindow.delegate = self

        guard let face = aquaWindow.contentView else { return }
        let box = AquaBoxView(frame: NSRect(x: L.boxInsetX, y: Self.boxTop, width: size.width - 2 * L.boxInsetX,
                                            height: boxBottom - Self.boxTop))
        face.addSubview(box)

        addLabel("Appearance:", y: firstRadioY, to: face)
        for (i, entry) in radios.enumerated() {
            let button = entry.button
            button.setFrameOrigin(NSPoint(x: Self.radioLeft, y: firstRadioY + CGFloat(i) * Self.radioPitch))
            button.onPick = { [weak self] in self?.pick(entry.mode) }
            face.addSubview(button)
        }
        note.setFrameOrigin(NSPoint(x: noteX, y: noteY))
        face.addSubview(note)

        // Music keeps Sound Check under Playback; so does this.
        addLabel("Playback:", y: soundCheckY, to: face)
        soundCheckBox.setFrameOrigin(NSPoint(x: Self.radioLeft, y: soundCheckY))
        soundCheckBox.onToggle = { on in SoundCheckPreference.choose(on, save: false) }
        face.addSubview(soundCheckBox)
        soundCheckNote.setFrameOrigin(NSPoint(x: noteX, y: soundCheckNoteY))
        face.addSubview(soundCheckNote)

        if showsVisualizer {
            addLabel("Visualizer:", y: visualizerY, to: face)
            hdrCheckbox.setFrameOrigin(NSPoint(x: Self.radioLeft, y: visualizerY))
            hdrCheckbox.onToggle = { on in VisualizerPreference.chooseHDR(on, save: false) }
            face.addSubview(hdrCheckbox)
        }

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

    /// A grey wrapping note under a control, sized to its text.
    private static func note(_ text: String, width: CGFloat) -> NSTextField {
        let note = FormKit.label(text, color: AquaStyle.noteText)
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 0
        note.preferredMaxLayoutWidth = width
        note.setFrameSize(NSSize(width: width, height: ceil(note.sizeThatFits(NSSize(width: width, height: 200)).height)))
        return note
    }

    /// A row's label, right-aligned against the controls.
    private func addLabel(_ text: String, y: CGFloat, to face: NSView) {
        let L = GetInfoLayout.self
        let label = FormKit.label(text, font: AquaStyle.controlFont, alignment: .right)
        label.frame = NSRect(x: L.boxInsetX + 8, y: y, width: Self.labelRight - L.boxInsetX - 8, height: 17)
        face.addSubview(label)
    }

    func radio(for mode: AppearanceMode) -> AquaRadioButton? { radios.first { $0.mode == mode }?.button }

    private func present() {
        if !(window?.isVisible ?? false) {
            modeAtOpen = AppearancePreference.current
            show(picked: AppearancePreference.saved)
            soundCheckAtOpen = SoundCheckPreference.current
            soundCheckBox.isOn = soundCheckAtOpen
            hdrAtOpen = VisualizerPreference.currentHDR
            hdrCheckbox.isOn = VisualizerPreference.savedHDR
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
        SoundCheckPreference.choose(soundCheckBox.isOn, save: true)
        // Saved only when changed, so an OK that touched nothing writes nothing new to the defaults.
        if VisualizerController.isSupported, hdrCheckbox.isOn != VisualizerPreference.savedHDR {
            VisualizerPreference.chooseHDR(hdrCheckbox.isOn, save: true)
        }
        aquaWindow.orderOut(nil)
    }

    private func cancelPressed() {
        AppearancePreference.choose(modeAtOpen, save: false)
        SoundCheckPreference.choose(soundCheckAtOpen, save: false)
        if VisualizerController.isSupported { VisualizerPreference.chooseHDR(hdrAtOpen, save: false) }
        aquaWindow.orderOut(nil)
    }

    // MARK: NSWindowDelegate

    /// The close button and ⌘W mean Cancel, as in any 10.4 dialog.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancelPressed()
        return false
    }
}
