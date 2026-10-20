import Foundation
import iTunesLibrary

/// What the metadata harness needs from Noah's real library, read once through iTunesLibrary
/// (read-only; nothing here can write to the library).
struct HarnessLibrarySample: Sendable {
    struct Item: Sendable {
        var title = "", artist = "", album = "", albumArtist = "", composer = "", genre = ""
        var grouping = "", comments = "", kind = ""
        var year = 0, trackNumber = 0, trackCount = 0, discNumber = 0, discCount = 0, bpm = 0
        var persistentID: UInt64 = 0
        var location: URL?
        var bitRate = 0, sampleRate = 0, playCount = 0
        var fileSize: Int64 = 0
        var seconds: Double = 0
        var added: Date?
        var isCloud = false
        var locationType = 0
        var isCompilation = false
        var artwork: Data?
    }

    var localFiles: [Item] = []
    /// A handful of cloud-only songs with artwork, for the fake cloud Track and the ID checks.
    var cloudSamples: [Item] = []
    /// A cloud-only song on a compilation album (ITLibAlbum.isCompilation), for the Get Info
    /// compilation checks.
    var compilationSample: Item?
    /// Every song's persistent ID, for the hex-conversion checks.
    var allPersistentIDs: [UInt64] = []
    var songCount = 0
    var error: String?

    static func load() async -> HarnessLibrarySample {
        await Task.detached(priority: .userInitiated) { () -> HarnessLibrarySample in
            var sample = HarnessLibrarySample()
            do {
                let library = try ITLibrary(apiVersion: "1.0", options: .lazyLoadData)
                let songs = library.allMediaItems.filter { $0.mediaKind == .kindSong }
                sample.songCount = songs.count
                sample.allPersistentIDs = songs.map { $0.persistentID.uint64Value }
                sample.localFiles = songs.filter { $0.locationType == .file }.map { item(from: $0, withArtwork: false) }
                sample.cloudSamples = songs
                    .filter { $0.locationType == .remote && $0.isCloud && $0.hasArtworkAvailable && !$0.title.isEmpty
                             && $0.addedDate != nil && $0.playCount > 0 }
                    .prefix(6)
                    .map { item(from: $0, withArtwork: true) }
                sample.compilationSample = songs
                    .first { $0.locationType == .remote && $0.isCloud && $0.album.isCompilation && !$0.title.isEmpty }
                    .map { item(from: $0, withArtwork: false) }
            } catch {
                sample.error = "\(error)"
            }
            return sample
        }.value
    }

    private static func item(from m: ITLibMediaItem, withArtwork: Bool) -> Item {
        var i = Item()
        i.title = m.title
        i.artist = m.artist?.name ?? ""
        i.album = m.album.title ?? ""
        i.albumArtist = m.album.albumArtist ?? ""
        i.composer = m.composer
        i.genre = m.genre
        i.grouping = m.grouping ?? ""
        i.comments = m.comments ?? ""
        i.kind = m.kind ?? ""
        i.year = m.year
        i.trackNumber = m.trackNumber
        i.trackCount = m.album.trackCount
        i.discNumber = m.album.discNumber
        i.discCount = m.album.discCount
        i.bpm = m.beatsPerMinute
        i.persistentID = m.persistentID.uint64Value
        i.location = m.location
        i.bitRate = m.bitrate
        i.sampleRate = m.sampleRate
        i.playCount = m.playCount
        i.fileSize = Int64(clamping: m.fileSize)
        i.seconds = Double(m.totalTime) / 1000
        i.added = m.addedDate
        i.isCloud = m.isCloud
        i.locationType = Int(m.locationType.rawValue)
        i.isCompilation = m.album.isCompilation
        if withArtwork { i.artwork = m.artwork?.imageData }
        return i
    }

    /// A `Track` shaped like the index would make it, for driving Get Info without the
    /// Library module.
    static func track(from i: Item, id: Track.ID, fileURL: URL? = nil) -> Track {
        var t = Track.blank(id: id)
        t.origin = .musicLibrary
        t.persistentID = Int64(bitPattern: i.persistentID)
        t.title = i.title; t.artist = i.artist; t.album = i.album; t.albumArtist = i.albumArtist
        t.composer = i.composer; t.genre = i.genre; t.grouping = i.grouping; t.comments = i.comments
        t.year = i.year; t.trackNumber = i.trackNumber; t.trackCount = i.trackCount
        t.discNumber = i.discNumber; t.discCount = i.discCount; t.bpm = i.bpm
        t.duration = i.seconds; t.dateAdded = i.added; t.playCount = i.playCount; t.kind = i.kind
        t.bitRate = i.bitRate; t.sampleRate = i.sampleRate; t.fileSize = i.fileSize
        t.hasArtwork = i.artwork != nil
        t.isCloud = i.isCloud
        t.locationType = i.locationType
        t.isCompilation = i.isCompilation
        t.fileURL = fileURL
        t.bucket = fileURL == nil ? .cloud : .local
        return t
    }
}
