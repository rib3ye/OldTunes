import Foundation
import Darwin
import SFBAudioEngine

/// Requirement (c): for every fixture, write all 15 fields plus artwork through `TagEditor`,
/// read them back, prove the file's identity survived the atomic swap, then remove the artwork.
@MainActor
enum HarnessRoundTrip {
    /// What the safe-write procedure must preserve (RESEARCH.md §6.4).
    struct FileFacts: Equatable, CustomStringConvertible {
        var created: Date?
        var mode: Int
        var xattrs: [String: Data]
        var description: String {
            "created=\(created.map { "\($0.timeIntervalSince1970)" } ?? "nil") mode=\(String(mode, radix: 8)) xattrs=\(xattrs.keys.sorted())"
        }
    }

    static let probeXattr = "com.noahtsutsui.oldtunes.probe"

    static func facts(_ url: URL) -> FileFacts {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        return FileFacts(created: attrs[.creationDate] as? Date,
                         mode: (attrs[.posixPermissions] as? Int) ?? -1,
                         xattrs: xattrs(url))
    }

    static func xattrs(_ url: URL) -> [String: Data] {
        var out: [String: Data] = [:]
        let path = url.path
        let size = listxattr(path, nil, 0, 0)
        guard size > 0 else { return out }
        var names = [CChar](repeating: 0, count: size)
        guard listxattr(path, &names, size, 0) == size else { return out }
        let all = names.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
        for name in all {
            let len = getxattr(path, name, nil, 0, 0, 0)
            guard len >= 0 else { continue }
            var buf = [UInt8](repeating: 0, count: len)
            if len > 0 { _ = getxattr(path, name, &buf, len, 0, 0) }
            out[name] = Data(buf)
        }
        return out
    }

    /// The 15 fields every format must round-trip. Year 2005 is the §6.2 trap.
    static func fullPatch(label: String, artwork: Data) -> TagPatch {
        var p = TagPatch()
        p.title = "OldTunes ✓ \(label)"
        p.artist = "Artïst Ünicode"
        p.album = "Album of 2005"
        p.albumArtist = "Album Artist"
        p.composer = "Composer"
        p.genre = "Harness Rock"
        p.grouping = "Grouping"
        p.comments = "Comment written by the OldTunes metadata harness"
        p.year = 2005
        p.trackNumber = 3
        p.trackCount = 12
        p.discNumber = 1
        p.discCount = 2
        p.bpm = 128
        p.isCompilation = true
        p.artwork = artwork
        return p
    }

    static func run(_ fixtures: [HarnessFixtures.Fixture], editor: TagEditor, tally: HarnessTally) async -> [String: (Int, Int)] {
        var perFormat: [String: (Int, Int)] = [:]
        for (n, fixture) in fixtures.enumerated() {
            let before = tally.passed, beforeFail = tally.failed
            await roundTrip(fixture, index: n, editor: editor, tally: tally)
            perFormat[fixture.label] = (tally.passed - before, tally.failed - beforeFail)
        }
        return perFormat
    }

    private static func roundTrip(_ fixture: HarnessFixtures.Fixture, index: Int, editor: TagEditor, tally: HarnessTally) async {
        let url = fixture.url
        let tag = "[\(fixture.label)]"
        // Give the file a non-default mode and a custom xattr so "survived" means something.
        _ = chmod(url.path, 0o640)
        let probe = Data("keep-me-\(fixture.label)".utf8)
        _ = probe.withUnsafeBytes { setxattr(url.path, probeXattr, $0.baseAddress, probe.count, 0, 0) }
        let factsBefore = facts(url)
        Log.info("\(tag) before: \(factsBefore)")

        let track = HarnessFixtures.folderTrack(id: Track.ID(9000 + index), url: url)
        let art = HarnessFixtures.artworkPNG(label: fixture.label)
        let patch = fullPatch(label: fixture.label, artwork: art)

        let r1 = await editor.apply(patch, to: [track])
        tally.check(r1.succeeded == [track.id] && r1.failed.isEmpty, "\(tag) apply all 15 fields + artwork",
                    detail: r1.failed.map(\.reason).joined(separator: "; "))

        do {
            let f = try await editor.readFields(of: track)
            let expected = TagFields().applying(patch)
            let checks: [(String, Bool, String)] = [
                ("title", f.title == expected.title, f.title),
                ("artist", f.artist == expected.artist, f.artist),
                ("album", f.album == expected.album, f.album),
                ("albumArtist", f.albumArtist == expected.albumArtist, f.albumArtist),
                ("composer", f.composer == expected.composer, f.composer),
                ("genre", f.genre == expected.genre, f.genre),
                ("grouping", f.grouping == expected.grouping, f.grouping),
                ("comments", f.comments == expected.comments, f.comments),
                ("year", f.year == 2005, "\(f.year)"),
                ("trackNumber", f.trackNumber == 3, "\(f.trackNumber)"),
                ("trackCount", f.trackCount == 12, "\(f.trackCount)"),
                ("discNumber", f.discNumber == 1, "\(f.discNumber)"),
                ("discCount", f.discCount == 2, "\(f.discCount)"),
                ("bpm", f.bpm == 128, "\(f.bpm)"),
                ("isCompilation", f.isCompilation, "\(f.isCompilation)"),
            ]
            for (field, ok, got) in checks { tally.check(ok, "\(tag) \(field)", detail: "read back \"\(got)\"") }
        } catch {
            tally.check(false, "\(tag) read back", detail: error.localizedDescription)
        }
        let artBack = FileTagIO.readArtwork(at: url)
        tally.check(artBack == art, "\(tag) artwork (\(art.count) bytes PNG)",
                    detail: "read back \(artBack?.count ?? 0) bytes")

        let factsAfter = facts(url)
        Log.info("\(tag) after:  \(factsAfter)")
        tally.check(factsAfter.created == factsBefore.created && factsBefore.created != nil, "\(tag) creation date survived",
                    detail: "\(String(describing: factsBefore.created)) -> \(String(describing: factsAfter.created))")
        tally.check(factsAfter.mode == factsBefore.mode && factsBefore.mode == 0o640, "\(tag) mode 640 survived",
                    detail: "\(String(factsBefore.mode, radix: 8)) -> \(String(factsAfter.mode, radix: 8))")
        tally.check(factsAfter.xattrs == factsBefore.xattrs && factsAfter.xattrs[probeXattr] == probe,
                    "\(tag) xattrs survived (\(factsBefore.xattrs.count))",
                    detail: "\(factsBefore.xattrs.keys.sorted()) -> \(factsAfter.xattrs.keys.sorted())")
        tally.check(leftovers(near: url).isEmpty, "\(tag) no temp file left", detail: leftovers(near: url).joined(separator: ","))

        // Second patch: artwork removal only.
        var remove = TagPatch()
        remove.removeArtwork = true
        let r2 = await editor.apply(remove, to: [track])
        tally.check(r2.failed.isEmpty, "\(tag) apply remove-artwork", detail: r2.failed.map(\.reason).joined(separator: "; "))
        tally.check(FileTagIO.readArtwork(at: url) == nil, "\(tag) artwork removed")
        if let f = try? await editor.readFields(of: track) {
            tally.check(f.title == patch.title && f.year == 2005, "\(tag) fields intact after artwork removal",
                        detail: "title=\(f.title) year=\(f.year)")
        }
        tally.check(facts(url).created == factsBefore.created && facts(url).xattrs == factsBefore.xattrs,
                    "\(tag) identity intact after second write")
    }

    static func leftovers(near url: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []
        return names.filter { $0.contains(".tagtmp") }
    }

    // MARK: - The year trap, measured

    /// Evidence for the time-zone half of the §6.2 trap: the spec's literal midnight-UTC
    /// timestamp versus the noon-UTC one TagEditor writes, straight through SFBAudioEngine.
    static func yearTrapProbe(source: URL?, dir: URL, tally: HarnessTally) {
        guard let source else { return }
        let tz = TimeZone.current.identifier
        for (name, value) in [("midnight", "2005-01-01T00:00:00Z"), ("noon", FileTagIO.releaseDate(forYear: 2005))] {
            let url = dir.appendingPathComponent("yeartrap-\(name).\(source.pathExtension)")
            try? FileManager.default.removeItem(at: url)
            do {
                try FileManager.default.copyItem(at: source, to: url)
                let f = try AudioFile(readingPropertiesAndMetadataFrom: url)
                f.metadata.releaseDate = value
                try f.writeMetadata()
                let back = try FileTagIO.readFields(at: url).year
                Log.info("year trap probe (\(source.pathExtension), TZ \(tz)): wrote \(value) -> reads back \(back)")
                if name == "noon" { tally.check(back == 2005, "noon-UTC timestamp keeps 2005 in \(tz)") }
            } catch {
                Log.error("year trap probe \(name): \(error.localizedDescription)")
            }
        }
    }

    /// A save that does not touch the year must not change it — the realistic case: Noah's real
    /// MP3, title edited, year left alone.
    static func untouchedYear(original: URL?, dir: URL, editor: TagEditor, tally: HarnessTally) async {
        guard let original else { return }
        let url = dir.appendingPathComponent("untouched-year.\(original.pathExtension)")
        try? FileManager.default.removeItem(at: url)
        guard (try? FileManager.default.copyItem(at: original, to: url)) != nil,
              let before = try? FileTagIO.readFields(at: url) else {
            tally.check(false, "untouched-year copy")
            return
        }
        let t = HarnessFixtures.folderTrack(id: 9400, url: url)
        var patch = TagPatch()
        patch.title = before.title + " (edited)"
        let r = await editor.apply(patch, to: [t])
        let after = try? FileTagIO.readFields(at: url)
        Log.info("untouched year: \(original.lastPathComponent) year before=\(before.year) after=\(after?.year ?? -1)")
        tally.check(r.failed.isEmpty && after?.year == before.year && after?.artist == before.artist
                    && after?.album == before.album && after?.trackNumber == before.trackNumber,
                    "title-only edit of the real \(original.pathExtension) keeps year \(before.year) and the other tags")
    }

    // MARK: - Refusals and failed writes

    static func refusals(in dir: URL, source: URL?, editor: TagEditor, tally: HarnessTally) async {
        guard let source else {
            tally.check(false, "refusal tests have a source fixture")
            return
        }
        let fm = FileManager.default
        var patch = TagPatch()
        patch.title = "Must not be written"

        let cases: [(String, String)] = [
            ("protected.m4p", "FairPlay"),
            ("audiobook.m4b", "audiobook"),
            ("notes.txt", ".txt files"),
        ]
        for (n, (name, needle)) in cases.enumerated() {
            let url = dir.appendingPathComponent(name)
            try? fm.removeItem(at: url)
            try? fm.copyItem(at: source, to: url)
            let bytesBefore = fm.contents(atPath: url.path)
            let t = HarnessFixtures.folderTrack(id: Track.ID(9100 + n), url: url)
            let r = await editor.apply(patch, to: [t])
            let reason = r.failed.first?.reason ?? ""
            tally.check(r.succeeded.isEmpty && reason.contains(needle), "refuse \(name) with a clear reason",
                        detail: "reason=\(reason)")
            Log.info("refusal \(name): \(reason)")
            tally.check(fm.contents(atPath: url.path) == bytesBefore, "refused \(name) left untouched")
        }

        // A file that claims to be FLAC but is not: the temp copy fails to open, so the original
        // must come through byte-identical and no temp file may remain. (Junk named .mp3 is no
        // good here: taglib happily prepends an ID3 tag to any bytes.)
        let broken = dir.appendingPathComponent("broken.flac")
        let junk = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 2654435761 >> 7) })
        try? junk.write(to: broken)
        let bt = HarnessFixtures.folderTrack(id: 9200, url: broken)
        let rb = await editor.apply(patch, to: [bt])
        Log.info("broken.flac: \(rb.failed.first?.reason ?? "no failure?")")
        tally.check(rb.succeeded.isEmpty && !rb.failed.isEmpty, "broken.flac write fails")
        tally.check(fm.contents(atPath: broken.path) == junk, "broken.flac original byte-identical after failed write")
        tally.check(leftovers(near: broken).isEmpty, "broken.flac temp copy cleaned up")

        // A read-only directory: the sibling temp copy cannot be created, so nothing may change.
        let lockedDir = dir.appendingPathComponent("locked")
        try? fm.createDirectory(at: lockedDir, withIntermediateDirectories: true)
        _ = chmod(lockedDir.path, 0o755)
        let locked = lockedDir.appendingPathComponent("locked.m4a")
        try? fm.removeItem(at: locked)
        try? fm.copyItem(at: source, to: locked)
        let lockedBefore = fm.contents(atPath: locked.path)
        _ = chmod(lockedDir.path, 0o555)
        let lt = HarnessFixtures.folderTrack(id: 9201, url: locked)
        let rl = await editor.apply(patch, to: [lt])
        _ = chmod(lockedDir.path, 0o755)
        Log.info("locked dir: \(rl.failed.first?.reason ?? "no failure?")")
        tally.check(rl.succeeded.isEmpty && (rl.failed.first?.reason.contains("permission") ?? false),
                    "read-only folder write fails with a permission reason")
        tally.check(fm.contents(atPath: locked.path) == lockedBefore, "read-only folder original byte-identical")
    }

    // MARK: - Cloud routing (no Apple Events)

    static func cloudRouting(sample: HarnessLibrarySample, tally: HarnessTally) async {
        guard let item = sample.cloudSamples.first else {
            tally.check(false, "cloud routing has a real cloud-only song")
            return
        }
        let track = HarnessLibrarySample.track(from: item, id: 9300)
        let hex = MusicPersistentID.hex(Int64(bitPattern: item.persistentID))
        var patch = TagPatch()
        patch.comments = "routed"
        patch.year = 2005

        let granted = RecordingCloudWriter(answers: [.granted])
        let editor = TagEditor(cloud: granted)
        let fields = try? await editor.readFields(of: track)
        let asksAfterRead = await granted.asks()
        tally.check(fields == TagFields(track: track) && asksAfterRead.isEmpty,
                    "cloud readFields comes from the Track, no Music call")
        let r = await editor.apply(patch, to: [track])
        let writes = await granted.recordedWrites()
        tally.check(r.succeeded == [track.id] && writes.count == 1 && writes.first?.hex == hex && writes.first?.patch == patch,
                    "cloud-only song routed to Music writer by persistent ID \(hex)")

        let denied = RecordingCloudWriter(answers: [.denied])
        let rd = await TagEditor(cloud: denied).apply(patch, to: [track])
        let reason = rd.failed.first?.reason ?? ""
        let deniedWrites = await denied.recordedWrites()
        tally.check(reason.contains("System Settings ▸ Privacy & Security ▸ Automation ▸ OldTunes ▸ Music")
                    && deniedWrites.isEmpty,
                    "denied Automation fails with where-to-enable reason", detail: reason)
        Log.info("denied reason: \(reason)")

        let undetermined = RecordingCloudWriter(answers: [.undetermined, .granted])
        let ru = await TagEditor(cloud: undetermined).apply(patch, to: [track])
        let asks = await undetermined.asks()
        tally.check(asks == [false, true] && ru.succeeded == [track.id],
                    "undetermined Automation: checks silently, then asks once", detail: "asks=\(asks)")

        var mixed = [track]
        var noHome = Track.blank(id: 9301)
        noHome.title = "No home"
        mixed.append(noHome)
        let rm = await TagEditor(cloud: RecordingCloudWriter(answers: [.granted])).apply(patch, to: mixed)
        tally.check(rm.succeeded == [track.id] && rm.failed.map(\.id) == [9301],
                    "partial failure reported per song", detail: rm.failed.map(\.reason).joined())
    }
}
