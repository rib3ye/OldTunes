import AppKit

/// The menu a right-click (or a click and hold) on OldTunes's Dock icon opens, as in iTunes: the
/// song playing, then the playback controls. macOS adds its own items (Options, Show All Windows,
/// Hide, Quit) below them.
///
/// The Dock shows a copy of the menu taken as it opens and never validates it again, so each
/// right-click builds a new one from the state at that moment, its titles and checkmarks already set.
@MainActor
enum DockMenu {
    static func make(for state: PlaybackState, target: AppController) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let track = state.nowPlaying {
            menu.addItem(label("Now Playing"))
            menu.addItem(label(shortened(track.displayTitle), indent: 1))
            if !track.artist.isEmpty { menu.addItem(label(shortened(track.artist), indent: 1)) }
            menu.addItem(.separator())
        }
        // The Controls menu's own actions, except Previous Song. Past 3 s into a song, that one
        // restarts it and goes back a song only if pressed again within 3 s, which reopening the
        // Dock menu takes longer than. So here it always goes back a song.
        menu.addItem(command(state.isPlaying ? "Pause" : "Play", #selector(AppController.playPauseAction(_:)), target))
        menu.addItem(command("Next Song", #selector(AppController.nextAction(_:)), target))
        menu.addItem(command("Previous Song", #selector(AppController.previousSongAction(_:)), target))
        menu.addItem(.separator())

        let shuffle = command("Shuffle", #selector(AppController.toggleShuffle(_:)), target)
        shuffle.state = state.isShuffling ? .on : .off
        menu.addItem(shuffle)
        // A submenu rather than the Controls menu's one item that cycles: the Dock can't retitle
        // an item after a click, so each mode gets its own, with a check on the current one.
        let modes = NSMenu(title: "Repeat")
        modes.autoenablesItems = false
        for (title, mode) in [("Off", RepeatMode.off), ("All", .all), ("One", .one)] {
            let choice = command(title, #selector(AppController.chooseRepeat(_:)), target)
            choice.representedObject = mode
            choice.state = state.repeatMode == mode ? .on : .off
            modes.addItem(choice)
        }
        let repeatItem = NSMenuItem(title: "Repeat", action: nil, keyEquivalent: "")
        repeatItem.submenu = modes
        menu.addItem(repeatItem)
        return menu
    }

    /// The longest song or artist line, in characters. A menu grows as wide as its longest item:
    /// in a 15,900-song library, 135 titles run past 60 characters (the longest to 175), and one
    /// artist to 255 (measured).
    static let maxLineLength = 60

    static func shortened(_ text: String) -> String {
        guard text.count > maxLineLength else { return text }
        return text.prefix(maxLineLength - 1).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// A line of text that can't be clicked.
    private static func label(_ title: String, indent: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.indentationLevel = indent
        return item
    }

    private static func command(_ title: String, _ action: Selector, _ target: AppController) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        return item
    }
}
