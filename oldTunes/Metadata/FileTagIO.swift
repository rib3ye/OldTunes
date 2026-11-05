import Foundation
import SFBAudioEngine

/// A user-facing reason a tag read or write (or another request to Music) did not happen.
struct TagEditError: LocalizedError, Sendable {
    var message: String
    /// The Apple Event error number, when Music's reply carried one.
    var code: Int? = nil
    /// oldTunes found the command missing from Music's scripting dictionary before sending
    /// anything. Its code is -1708 (errAEEventNotHandled) like the other such checks, but Music
    /// answers one request it won't carry out with -1708 too, and only this one means no request
    /// of that kind can work (`MusicScriptingSession.stopsBatch`).
    var missingCommand = false
    var errorDescription: String? { message }
}

/// Reads and writes tags in audio files with SFBAudioEngine (RESEARCH.md §6.2–6.4).
///
/// Everything here is synchronous and touches only its arguments, so `TagEditor` can call it on
/// its own executor; SFBAudioEngine's Objective-C objects never leave these functions.
enum FileTagIO {

    // MARK: - What can be edited

    /// Nil when the file can be edited, otherwise the sentence to show the user.
    /// FairPlay and audiobook files are named explicitly because "unsupported" alone would read
    /// like a bug for a song that plays fine in Music.
    static func problem(with url: URL) -> String? {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "m4p":
            return "“\(name)” is a protected (FairPlay) file. Its information can only be changed in Music."
        case "m4b":
            return "“\(name)” is an audiobook file (.m4b). oldTunes can’t change audiobook information."
        default:
            break
        }
        guard !ext.isEmpty, AudioFile.handlesPaths(withExtension: ext) else {
            return "oldTunes can’t change the information in “\(name)” because it doesn’t edit \(ext.isEmpty ? "files without an extension" : ".\(ext) files")."
        }
        return nil
    }

    // MARK: - Reading

    static func readFields(at url: URL) throws -> TagFields {
        if let problem = problem(with: url) { throw TagEditError(message: problem) }
        let metadata = try AudioFile(readingPropertiesAndMetadataFrom: url).metadata
        var f = TagFields()
        f.title = metadata.title ?? ""
        f.artist = metadata.artist ?? ""
        f.album = metadata.albumTitle ?? ""
        f.albumArtist = metadata.albumArtist ?? ""
        f.composer = metadata.composer ?? ""
        f.genre = metadata.genre ?? ""
        f.grouping = metadata.grouping ?? ""
        f.comments = metadata.comment ?? ""
        f.year = year(fromReleaseDate: metadata.releaseDate)
        f.trackNumber = metadata.trackNumber ?? 0
        f.trackCount = metadata.trackTotal ?? 0
        f.discNumber = metadata.discNumber ?? 0
        f.discCount = metadata.discTotal ?? 0
        f.bpm = metadata.bpm ?? 0
        f.isCompilation = metadata.isCompilation ?? false
        return f
    }

    /// The front cover if the file has one, else any embedded picture (MP4 `covr` atoms carry no
    /// picture type, so a strict front-cover lookup would miss most AAC artwork).
    static func readArtwork(at url: URL) -> Data? {
        guard problem(with: url) == nil,
              let metadata = try? AudioFile(readingPropertiesAndMetadataFrom: url).metadata else { return nil }
        if let front = metadata.attachedPictures(ofType: .frontCover).first { return front.imageData }
        return metadata.attachedPictures.first?.imageData
    }

    /// Release dates come back as "2005", "2005-06-01" or a full timestamp depending on the
    /// format; the Year box only ever wants the leading four digits.
    static func year(fromReleaseDate date: String?) -> Int {
        guard let date, date.count >= 4 else { return 0 }
        let digits = date.prefix(4)
        guard digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { return 0 }
        return Int(digits) ?? 0
    }

    /// The year trap (RESEARCH.md §6.2), which has two halves. taglib's ID3v2 writer deletes
    /// TDRC and only re-adds it when the value parses as a FULL ISO-8601 timestamp, so a bare
    /// "2005" silently erases the year from MP3, AIFF and WAV. And SFBAudioEngine then takes the
    /// year from that timestamp with the *local* calendar: §6.2's "2005-01-01T00:00:00Z" is still
    /// 31 December 2004 in California, and the harness read back 2004 on this Mac. Noon UTC on
    /// 1 January is 1 or 2 January in every time zone, so the year survives everywhere.
    static func releaseDate(forYear year: Int) -> String {
        String(format: "%04d-01-01T12:00:00Z", year)
    }

    /// Formats SFBAudioEngine tags with ID3v2, where both halves of the trap apply.
    private static let id3v2Extensions: Set<String> = ["mp3", "aif", "aiff", "wav", "wave", "dsf", "dff"]

    /// Whether SFBAudioEngine would write this existing date back with the same year. False for
    /// a bare "1998" (most MP3s), which a save that never touched the year would otherwise delete.
    static func survivesID3v2Write(_ date: String) -> Bool {
        guard let parsed = ISO8601DateFormatter().date(from: date) else { return false }
        // Same calendar and time zone SFBAudioEngine uses ([NSCalendar initWithCalendarIdentifier:]).
        return Calendar(identifier: .gregorian).component(.year, from: parsed) == year(fromReleaseDate: date)
    }

    // MARK: - Writing

    /// Applies `patch` with the safe-write procedure of RESEARCH.md §6.4: taglib rewrites files
    /// in place by shifting their bytes, so a crash or full disk mid-save would corrupt the
    /// song. Instead the change goes into a sibling copy (same directory, so same volume) that
    /// is swapped in atomically. If anything fails before the swap, the original is untouched
    /// and the copy is removed.
    static func write(_ patch: TagPatch, to url: URL) throws {
        if let problem = problem(with: url) { throw TagEditError(message: problem) }
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw TagEditError(message: "The file “\(url.lastPathComponent)” could not be found.")
        }

        let tmp = temporarySibling(for: url)
        // A leftover from a crashed save would make copyItem fail; it is ours to discard.
        if fm.fileExists(atPath: tmp.path) { try fm.removeItem(at: tmp) }
        // copyItem carries extended attributes and the resource fork; Data.write would drop them.
        try fm.copyItem(at: url, to: tmp)
        do {
            let file = try AudioFile(readingPropertiesAndMetadataFrom: tmp)
            apply(patch, to: file.metadata, id3v2: id3v2Extensions.contains(url.pathExtension.lowercased()))
            try file.writeMetadata()
            // Verified (§6.4) to keep creation date, POSIX mode, xattrs and the resource fork.
            // The modification date changes, which is the honest signal that the file was edited.
            _ = try fm.replaceItemAt(url, withItemAt: tmp, backupItemName: nil, options: [])
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    /// `.Song.tagtmp.mp3`: hidden, beside the original, and still ending in the real extension.
    /// §6.4 names it `.Song.mp3.tagtmp`, but SFBAudioEngine scores formats partly by extension
    /// and needs a score above its threshold, so a format whose content sniff is inconclusive
    /// would fail to open with the extension moved off the end.
    static func temporarySibling(for url: URL) -> URL {
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        return url.deletingLastPathComponent().appendingPathComponent(".\(stem).tagtmp.\(ext)")
    }

    private static func apply(_ patch: TagPatch, to m: AudioMetadata, id3v2: Bool) {
        // An emptied box removes the tag instead of writing an empty frame.
        if let v = patch.title { m.title = v.nilIfEmpty }
        if let v = patch.artist { m.artist = v.nilIfEmpty }
        if let v = patch.album { m.albumTitle = v.nilIfEmpty }
        if let v = patch.albumArtist { m.albumArtist = v.nilIfEmpty }
        if let v = patch.composer { m.composer = v.nilIfEmpty }
        if let v = patch.genre { m.genre = v.nilIfEmpty }
        if let v = patch.grouping { m.grouping = v.nilIfEmpty }
        if let v = patch.comments { m.comment = v.nilIfEmpty }
        if let v = patch.year {
            m.releaseDate = v > 0 ? releaseDate(forYear: v) : nil
        } else if id3v2, let existing = m.releaseDate, !survivesID3v2Write(existing) {
            // Every save rewrites every frame, so an untouched year must be re-expressed in a
            // form that survives, or editing a title would erase it.
            let y = year(fromReleaseDate: existing)
            if y > 0 { m.releaseDate = releaseDate(forYear: y) }
        }
        if let v = patch.trackNumber { m.trackNumber = v > 0 ? v : nil }
        if let v = patch.trackCount { m.trackTotal = v > 0 ? v : nil }
        if let v = patch.discNumber { m.discNumber = v > 0 ? v : nil }
        if let v = patch.discCount { m.discTotal = v > 0 ? v : nil }
        if let v = patch.bpm { m.bpm = v > 0 ? v : nil }
        if let v = patch.isCompilation { m.isCompilation = v }

        // New artwork replaces every embedded picture: MP4 artwork has no picture type, so
        // removing only front covers would leave the old image beside the new one.
        if patch.removeArtwork || patch.artwork != nil { m.removeAllAttachedPictures() }
        if let image = patch.artwork {
            m.attachPicture(AttachedPicture(imageData: image, type: .frontCover, description: "cover"))
        }
    }

    // MARK: - Messages

    /// Turns a write failure into one sentence for the per-song failure list.
    static func reason(for error: Error, url: URL) -> String {
        if let e = error as? TagEditError { return e.message }
        let name = url.lastPathComponent
        if let cocoa = error as? CocoaError {
            switch cocoa.code {
            case .fileWriteOutOfSpace:
                return "There isn’t enough disk space to save “\(name)”. The original file was not changed."
            case .fileWriteNoPermission, .fileReadNoPermission, .fileWriteVolumeReadOnly:
                return "oldTunes doesn’t have permission to change “\(name)”. The original file was not changed."
            case .fileNoSuchFile, .fileReadNoSuchFile:
                return "The file “\(name)” could not be found."
            default:
                break
            }
        }
        return "“\(name)” couldn’t be saved: \(error.localizedDescription) The original file was not changed."
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
