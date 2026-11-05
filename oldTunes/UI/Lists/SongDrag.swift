import AppKit

extension NSPasteboard.PasteboardType {
    /// Songs dragged from the track list: one pasteboard item per song, holding its Track.ID.
    /// oldTunes's own type and nothing else, no file URLs and no text, so a drag means nothing to
    /// Finder or another app, and the name box over a source-list row never takes one.
    static let oldTunesSongs = NSPasteboard.PasteboardType("com.noahtsutsui.oldtunes.songs")
}

/// The songs a drag carries, between the track list and the source list's playlists
/// (RESEARCH.md §6.10). The track list writes one item per dragged row, in row order, which
/// NSTableView keeps on the drag pasteboard; the source list reads them back on a drop. Only ever
/// the drag pasteboard, never the general one.
enum SongDrag {
    static func item(for id: Track.ID) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(String(id), forType: .oldTunesSongs)
        return item
    }

    /// The dragged songs, in the order they were written. Items without the type are skipped.
    static func ids(on pasteboard: NSPasteboard) -> [Track.ID] {
        (pasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: .oldTunesSongs).flatMap { Track.ID($0) } }
    }

    /// A dragged row's picture. `draw` paints it in a flipped space `size` points big, with the
    /// theme's colors resolved for `appearance`, into a clear image of `scale` pixels to the
    /// point. Shown at 75%, as Mac OS X showed what was being dragged, so the drop outline under
    /// the pointer still shows through.
    @MainActor
    static func picture(size: NSSize, scale: CGFloat, appearance: NSAppearance, draw: () -> Void) -> NSImage? {
        let wide = Int((size.width * scale).rounded(.up)), high = Int((size.height * scale).rounded(.up))
        guard wide > 0, high > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: wide, pixelsHigh: high, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)?
                .retagging(with: .sRGB) else { return nil }
        // Set before the context is made, which then works in points.
        rep.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        let cg = context.cgContext
        cg.clear(CGRect(origin: .zero, size: size))
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        cg.setAlpha(0.75)
        cg.beginTransparencyLayer(auxiliaryInfo: nil)
        appearance.performAsCurrentDrawingAppearance(draw)
        cg.endTransparencyLayer()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }
}

/// One entry of the track list's Add to Playlist ▸ menu, from the source list's tree
/// (`SourceListViewController.playlistTree`): a plain playlist, or a folder and what it holds.
struct PlaylistMenuEntry: Sendable, Equatable {
    var playlist: PlaylistInfo
    /// A folder's plain playlists and folders, in the source list's order. Empty for a playlist.
    var children: [PlaylistMenuEntry]
}
