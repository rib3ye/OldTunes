import AppKit

/// What an arrow key does when the focused view has no use for it, as in iTunes (Apple's iTunes
/// keyboard shortcuts; ↑ and ↓ as in iTunes 4's visualizer). The lists keep the arrows they use:
/// ↑ and ↓ move the selection, and ← and → open and close source-list folders. A text field keeps
/// them all. AppController performs these.
enum ArrowCommand: Equatable {
    /// ← and →: the Previous and Next buttons.
    case previousSong, nextSong
    /// ⌥← and ⌥→.
    case previousAlbum, nextAlbum
    /// ⌥⌘← and ⌥⌘→: back or ahead within the song, a step per press and per key repeat.
    case scan(seconds: TimeInterval)
    /// ↑ and ↓ in the visualizer, which has no selection for them to move.
    case volumeUp, volumeDown

    static let scanStep: TimeInterval = 5

    init?(event: NSEvent, inVisualizer: Bool) {
        guard event.type == .keyDown else { return nil }
        // Arrow keys also carry .numericPad and .function; only these four say which command.
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (event.keyCode, modifiers) {
        case (123, []): self = .previousSong            // ←
        case (124, []): self = .nextSong                // →
        case (123, .option): self = .previousAlbum
        case (124, .option): self = .nextAlbum
        case (123, [.option, .command]): self = .scan(seconds: -Self.scanStep)
        case (124, [.option, .command]): self = .scan(seconds: Self.scanStep)
        case (126, []) where inVisualizer: self = .volumeUp      // ↑
        case (125, []) where inVisualizer: self = .volumeDown    // ↓
        default: return nil
        }
    }
}
