import Foundation

extension TagFields {
    /// The index already holds every tag of a Music-library song (ingested from iTunesLibrary),
    /// so Get Info reads from here instead of asking Music.app, which would need an Apple Event.
    /// "Part of a compilation" comes from `Track.isCompilation` (ITLibAlbum.isCompilation), so a
    /// compilation starts checked and unticking it is a real change that clears the flag.
    init(track: Track) {
        self.init()
        title = track.title
        artist = track.artist
        album = track.album
        albumArtist = track.albumArtist
        composer = track.composer
        genre = track.genre
        grouping = track.grouping
        comments = track.comments
        year = track.year
        trackNumber = track.trackNumber
        trackCount = track.trackCount
        discNumber = track.discNumber
        discCount = track.discCount
        bpm = track.bpm
        isCompilation = track.isCompilation
    }

    /// The values the sheet should show after `patch` has been saved.
    func applying(_ patch: TagPatch) -> TagFields {
        var f = self
        if let v = patch.title { f.title = v }
        if let v = patch.artist { f.artist = v }
        if let v = patch.album { f.album = v }
        if let v = patch.albumArtist { f.albumArtist = v }
        if let v = patch.composer { f.composer = v }
        if let v = patch.genre { f.genre = v }
        if let v = patch.grouping { f.grouping = v }
        if let v = patch.comments { f.comments = v }
        if let v = patch.year { f.year = v }
        if let v = patch.trackNumber { f.trackNumber = v }
        if let v = patch.trackCount { f.trackCount = v }
        if let v = patch.discNumber { f.discNumber = v }
        if let v = patch.discCount { f.discCount = v }
        if let v = patch.bpm { f.bpm = v }
        if let v = patch.isCompilation { f.isCompilation = v }
        return f
    }
}

extension TagPatch {
    /// A patch that changes exactly the fields where `edited` differs from `original`, so an
    /// untouched field is never rewritten (and never re-encoded by taglib) just because the
    /// sheet was open.
    init(from original: TagFields, to edited: TagFields) {
        self.init()
        if edited.title != original.title { title = edited.title }
        if edited.artist != original.artist { artist = edited.artist }
        if edited.album != original.album { album = edited.album }
        if edited.albumArtist != original.albumArtist { albumArtist = edited.albumArtist }
        if edited.composer != original.composer { composer = edited.composer }
        if edited.genre != original.genre { genre = edited.genre }
        if edited.grouping != original.grouping { grouping = edited.grouping }
        if edited.comments != original.comments { comments = edited.comments }
        if edited.year != original.year { year = edited.year }
        if edited.trackNumber != original.trackNumber { trackNumber = edited.trackNumber }
        if edited.trackCount != original.trackCount { trackCount = edited.trackCount }
        if edited.discNumber != original.discNumber { discNumber = edited.discNumber }
        if edited.discCount != original.discCount { discCount = edited.discCount }
        if edited.bpm != original.bpm { bpm = edited.bpm }
        if edited.isCompilation != original.isCompilation { isCompilation = edited.isCompilation }
    }

    /// Field names that are set, for logs.
    var changedFieldNames: [String] {
        var names: [String] = []
        if title != nil { names.append("title") }
        if artist != nil { names.append("artist") }
        if album != nil { names.append("album") }
        if albumArtist != nil { names.append("albumArtist") }
        if composer != nil { names.append("composer") }
        if genre != nil { names.append("genre") }
        if grouping != nil { names.append("grouping") }
        if comments != nil { names.append("comments") }
        if year != nil { names.append("year") }
        if trackNumber != nil { names.append("trackNumber") }
        if trackCount != nil { names.append("trackCount") }
        if discNumber != nil { names.append("discNumber") }
        if discCount != nil { names.append("discCount") }
        if bpm != nil { names.append("bpm") }
        if isCompilation != nil { names.append("isCompilation") }
        if artwork != nil { names.append("artwork") }
        if removeArtwork { names.append("removeArtwork") }
        return names
    }
}
