import AVFoundation
import Foundation

/// Reads one audio file's tags and properties with AVFoundation, for added-folder tracks.
///
/// Each field is looked up in the iTunes (MP4) key space first, then ID3, then Vorbis comments,
/// then AVFoundation's common key space, because the same tag lives under a different identifier
/// in each format. FLAC's tags appear only as `vorb/…` items (upper-cased keys) with nothing in
/// the common space, so without those lookups a FLAC album indexes as bare file names.
enum AudioFileReader {
    static func record(for file: FolderScanner.FileInfo, addedAt: Int64) async -> SongRecord {
        let url = URL(fileURLWithPath: file.path)
        var r = SongRecord(origin: .folder)
        r.bucket = .local
        r.locationType = 1   // ITLibMediaItemLocationType.file
        r.locationPath = file.path
        r.fileSize = file.size
        r.fileMtime = file.mtime
        r.addedAt = addedAt

        let asset = AVURLAsset(url: url)
        let tags = await Tags(asset)
        r.title = await tags.string(.iTunesMetadataSongName, .id3MetadataTitleDescription, .vorbis("TITLE"),
                                    .commonIdentifierTitle) ?? ""
        r.artist = await tags.string(.iTunesMetadataArtist, .id3MetadataLeadPerformer, .vorbis("ARTIST"),
                                     .commonIdentifierArtist) ?? ""
        r.album = await tags.string(.iTunesMetadataAlbum, .id3MetadataAlbumTitle, .vorbis("ALBUM"),
                                    .commonIdentifierAlbumName) ?? ""
        r.albumArtist = await tags.string(.iTunesMetadataAlbumArtist, .id3MetadataBand, .vorbis("ALBUMARTIST"),
                                          .vorbis("ALBUM ARTIST")) ?? ""
        r.composer = await tags.string(.iTunesMetadataComposer, .id3MetadataComposer, .vorbis("COMPOSER")) ?? ""
        r.genre = await genre(tags) ?? ""
        r.comments = await tags.string(.iTunesMetadataUserComment, .id3MetadataComments, .vorbis("COMMENT"),
                                       .vorbis("DESCRIPTION")) ?? ""
        r.grouping = await tags.string(.iTunesMetadataGrouping, .id3MetadataContentGroupDescription,
                                       .vorbis("GROUPING")) ?? ""

        (r.trackNumber, r.trackCount) = await numberPair(tags, mp4: .iTunesMetadataTrackNumber,
                                                         text: [.id3MetadataTrackNumber, .vorbis("TRACKNUMBER")],
                                                         total: [.vorbis("TRACKTOTAL"), .vorbis("TOTALTRACKS")])
        (r.discNumber, r.discCount) = await numberPair(tags, mp4: .iTunesMetadataDiscNumber,
                                                       text: [.id3MetadataPartOfASet, .vorbis("DISCNUMBER")],
                                                       total: [.vorbis("DISCTOTAL"), .vorbis("TOTALDISCS")])
        r.year = await year(tags)
        r.bpm = await tags.integer(.iTunesMetadataBeatsPerMin, .id3MetadataBeatsPerMinute, .vorbis("BPM")) ?? 0
        r.isCompilation = (await tags.integer(.iTunesMetadataDiscCompilation, AVMetadataIdentifier("id3/TCMP"),
                                              .vorbis("COMPILATION")) ?? 0) != 0
        r.hasArtwork = tags.has(Self.artworkIdentifiers)

        // Files carry their own sort tags too (MP4 sonm/soar/soal/soaa, ID3 TSOT/TSOP/TSOA/TSO2).
        r.titleSortSource = await tags.string(AVMetadataIdentifier("itsk/sonm"), AVMetadataIdentifier("id3/TSOT"),
                                              .vorbis("TITLESORT")) ?? ""
        r.artistSortSource = await tags.string(AVMetadataIdentifier("itsk/soar"), AVMetadataIdentifier("id3/TSOP"),
                                               .vorbis("ARTISTSORT")) ?? ""
        r.albumSortSource = await tags.string(AVMetadataIdentifier("itsk/soal"), AVMetadataIdentifier("id3/TSOA"),
                                              .vorbis("ALBUMSORT")) ?? ""
        r.albumArtistSortSource = await tags.string(AVMetadataIdentifier("itsk/soaa"), AVMetadataIdentifier("id3/TSO2"),
                                                    .vorbis("ALBUMARTISTSORT")) ?? ""

        // iTunes named an untagged import after its file, and searching should find it that way.
        if r.title.trimmingCharacters(in: .whitespaces).isEmpty {
            r.title = url.deletingPathExtension().lastPathComponent
        }
        if r.titleSortSource.isEmpty { r.titleSortSource = r.title }
        if r.artistSortSource.isEmpty { r.artistSortSource = r.artist }
        if r.albumSortSource.isEmpty { r.albumSortSource = r.album }
        if r.albumArtistSortSource.isEmpty { r.albumArtistSortSource = r.albumArtist }

        if let duration = try? await asset.load(.duration), duration.isNumeric {
            r.totalTimeMs = Int64((duration.seconds * 1000).rounded())
        }
        await readAudioFormat(asset, url: url, into: &r)
        // Get Info showed an average rate for every file; AVFoundation reports none for lossless.
        if r.bitRate == 0, r.totalTimeMs > 0 {
            r.bitRate = Int((Double(r.fileSize) * 8 / Double(r.totalTimeMs)).rounded())
        }
        r.contentHash = r.computeContentHash()
        return r
    }

    /// Embedded cover art for an added-folder track.
    static func artwork(at url: URL) async -> Data? {
        let tags = await Tags(AVURLAsset(url: url))
        return await tags.data(Self.artworkIdentifiers)
    }

    /// FLAC's picture block arrives as `vorb/METADATA_BLOCK_PICTURE`, already unwrapped to image bytes.
    private static let artworkIdentifiers: [AVMetadataIdentifier] = [
        .commonIdentifierArtwork, .iTunesMetadataCoverArt, .id3MetadataAttachedPicture, .vorbis("METADATA_BLOCK_PICTURE"),
    ]

    // MARK: - Fields that need parsing

    private static func genre(_ tags: Tags) async -> String? {
        if let text = await tags.string(.iTunesMetadataUserGenre, .vorbis("GENRE")) { return text }
        // iTunes stored standard genres as `gnre`: a big-endian ID3v1 index plus one.
        if let data = await tags.data(.iTunesMetadataPredefinedGenre), data.count >= 2 {
            let index = Int(data[data.startIndex]) << 8 | Int(data[data.startIndex + 1])
            if let name = ID3Genres.name(at: index - 1) { return name }
        }
        guard let text = await tags.string(.id3MetadataContentType, .commonIdentifierType) else { return nil }
        return ID3Genres.resolve(text)
    }

    /// "3/12", or the MP4 binary form: 2 pad bytes, number and count as big-endian UInt16.
    /// Vorbis comments usually keep the count in a tag of its own (TRACKTOTAL).
    private static func numberPair(_ tags: Tags, mp4: AVMetadataIdentifier, text: [AVMetadataIdentifier],
                                   total: [AVMetadataIdentifier]) async -> (Int, Int) {
        if let data = await tags.data([mp4]), data.count >= 6 {
            let b = [UInt8](data)
            return (Int(b[2]) << 8 | Int(b[3]), Int(b[4]) << 8 | Int(b[5]))
        }
        guard let value = await tags.string([mp4] + text) else { return (0, 0) }
        let parts = value.split(separator: "/").map { Int($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
        let count = parts.count > 1 ? parts[1] : (await tags.integer(total) ?? 0)
        return (parts.first ?? 0, count)
    }

    private static func year(_ tags: Tags) async -> Int {
        let text = await tags.string(.iTunesMetadataReleaseDate, .id3MetadataYear, .id3MetadataRecordingTime,
                                     .id3MetadataReleaseTime, .vorbis("DATE"), .vorbis("YEAR"), .commonIdentifierCreationDate)
        guard let text else { return 0 }
        return Int(text.prefix(4)) ?? 0
    }

    private static func readAudioFormat(_ asset: AVURLAsset, url: URL, into r: inout SongRecord) async {
        let ext = url.pathExtension.lowercased()
        var codec: FourCharCode = 0
        if let track = try? await asset.loadTracks(withMediaType: .audio).first,
           let (rate, formats) = try? await track.load(.estimatedDataRate, .formatDescriptions) {
            r.bitRate = Int((rate / 1000).rounded())
            if let format = formats.first {
                codec = CMFormatDescriptionGetMediaSubType(format)
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
                    r.sampleRate = Int(asbd.mSampleRate)
                    // PCM (AIFF, WAV, CAF) has no estimated rate; iTunes showed the exact one (1,411 kbps for CD audio).
                    if r.bitRate == 0, asbd.mFormatID == kAudioFormatLinearPCM, asbd.mBitsPerChannel > 0 {
                        r.bitRate = Int((asbd.mSampleRate * Double(asbd.mBitsPerChannel * asbd.mChannelsPerFrame) / 1000).rounded())
                    }
                }
            }
        }
        r.kind = kind(extension: ext, codec: codec)
    }

    /// The Get Info "Kind" string iTunes showed.
    private static func kind(extension ext: String, codec: FourCharCode) -> String {
        switch ext {
        case "mp3": "MPEG audio file"
        case "m4a": codec == kAudioFormatAppleLossless ? "Apple Lossless audio file" : "AAC audio file"
        case "aac": "AAC audio file"
        case "aif", "aiff", "aifc": "AIFF audio file"
        case "wav": "WAV audio file"
        case "caf": "CAF audio file"
        case "flac": "FLAC audio file"
        default: "Audio file"
        }
    }
}

/// All of one asset's metadata items, with lookups that try several identifiers in order.
private struct Tags {
    private var items: [AVMetadataIdentifier: [AVMetadataItem]] = [:]

    init(_ asset: AVURLAsset) async {
        let loaded = (try? await asset.load(.metadata)) ?? []
        let common = (try? await asset.load(.commonMetadata)) ?? []
        for item in loaded + common {
            guard let identifier = item.identifier else { continue }
            items[identifier, default: []].append(item)
        }
    }

    func has(_ identifiers: [AVMetadataIdentifier]) -> Bool {
        identifiers.contains { items[$0] != nil }
    }

    func string(_ identifiers: AVMetadataIdentifier...) async -> String? { await string(identifiers) }
    func integer(_ identifiers: AVMetadataIdentifier...) async -> Int? { await integer(identifiers) }
    func data(_ identifiers: AVMetadataIdentifier...) async -> Data? { await data(identifiers) }

    func string(_ identifiers: [AVMetadataIdentifier]) async -> String? {
        for identifier in identifiers {
            for item in items[identifier] ?? [] {
                if let value = try? await item.load(.stringValue) {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
            }
        }
        return nil
    }

    func integer(_ identifiers: [AVMetadataIdentifier]) async -> Int? {
        for identifier in identifiers {
            for item in items[identifier] ?? [] {
                if let number = try? await item.load(.numberValue) { return number.intValue }
                if let text = try? await item.load(.stringValue),
                   let value = Int(text.trimmingCharacters(in: .whitespaces)) { return value }
            }
        }
        return nil
    }

    func data(_ identifiers: [AVMetadataIdentifier]) async -> Data? {
        for identifier in identifiers {
            for item in items[identifier] ?? [] {
                if let data = try? await item.load(.dataValue), !data.isEmpty { return data }
            }
        }
        return nil
    }
}

private extension AVMetadataIdentifier {
    /// A Vorbis comment (FLAC). AVFoundation upper-cases the field name ("title=" → `vorb/TITLE`).
    static func vorbis(_ field: String) -> AVMetadataIdentifier { AVMetadataIdentifier("vorb/\(field)") }
}
