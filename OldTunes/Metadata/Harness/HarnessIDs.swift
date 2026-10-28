import Foundation

/// Requirement (d): the persistent-ID hex conversion, and the Music.app checks that need no
/// Apple Event. The live read is behind OLDTUNES_METADATA_LIVE_MUSIC=1 and stays off by default
/// because it can raise the Automation prompt.
@MainActor
enum HarnessIDs {
    static func run(sample: HarnessLibrarySample, tally: HarnessTally) async {
        // Fixed vectors, including the sign boundary the Int64 storage introduces.
        let vectors: [(Int64, String)] = [
            (0, "0000000000000000"),
            (1, "0000000000000001"),
            (255, "00000000000000FF"),
            (0x0123_4567_89AB_CDEF, "0123456789ABCDEF"),
            (Int64.max, "7FFFFFFFFFFFFFFF"),
            (Int64.min, "8000000000000000"),
            (-1, "FFFFFFFFFFFFFFFF"),
            (Int64(bitPattern: 0xA1B2_C3D4_E5F6_0718), "A1B2C3D4E5F60718"),
        ]
        for (value, hex) in vectors {
            let got = MusicPersistentID.hex(value)
            tally.check(got == hex && MusicPersistentID.bitPattern(fromHex: hex) == value,
                        "pid vector \(value) <-> \(hex)", detail: "got \(got)")
        }
        tally.check(MusicPersistentID.bitPattern(fromHex: "-123") == nil
                    && MusicPersistentID.bitPattern(fromHex: "0123456789ABCDEG") == nil
                    && MusicPersistentID.bitPattern(fromHex: "123") == nil,
                    "pid parser rejects malformed ids")

        // Every real song: the Int64 the index stores must render as the 16-digit uppercase
        // hex of the UInt64 iTunesLibrary reports, and round-trip.
        var mismatches = 0
        var negatives = 0
        for raw in sample.allPersistentIDs {
            let stored = Int64(bitPattern: raw)
            if stored < 0 { negatives += 1 }
            let hex = MusicPersistentID.hex(stored)
            let reference = String(format: "%016llX", raw)
            if hex != reference || hex.count != 16 || MusicPersistentID.bitPattern(fromHex: hex) != stored {
                mismatches += 1
            }
        }
        tally.check(mismatches == 0 && !sample.allPersistentIDs.isEmpty,
                    "pid conversion over \(sample.allPersistentIDs.count) real songs (\(negatives) negative as Int64)",
                    detail: "\(mismatches) mismatches")
        for item in sample.cloudSamples.prefix(4) {
            let stored = Int64(bitPattern: item.persistentID)
            Log.info("pid sample: \"\(item.title)\" UInt64=\(item.persistentID) Int64=\(stored) AppleScript=\(MusicPersistentID.hex(stored))")
        }
        crossCheckWithLibraryXML(sample: sample, tally: tally)
        await automationProbe()
        await liveProbe(sample: sample, tally: tally)
    }

    /// If Music shares its library XML, its "Persistent ID" strings are the same format
    /// AppleScript uses — an independent check of the conversion. Read-only.
    private static func crossCheckWithLibraryXML(sample: HarnessLibrarySample, tally: HarnessTally) {
        // The real home: in the sandbox, homeDirectoryForCurrentUser is the app's container.
        let home = getpwuid(getuid()).map { URL(fileURLWithPath: String(cString: $0.pointee.pw_dir)) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        let candidates = ["Music/Music/Library.xml", "Music/iTunes/iTunes Music Library.xml",
                          "Music/iTunes/iTunes Library.xml"].map { home.appendingPathComponent($0) }
        if let unreadable = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path)
                                                         && !FileManager.default.isReadableFile(atPath: $0.path) }) {
            Log.info("pid XML cross-check: \(unreadable.path) is there but OldTunes may not read it; skipped")
            return
        }
        guard let url = candidates.first(where: { FileManager.default.isReadableFile(atPath: $0.path) }),
              let data = FileManager.default.contents(atPath: url.path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let tracks = plist["Tracks"] as? [String: Any] else {
            Log.info("pid XML cross-check: no shared library XML found (Music ▸ Settings ▸ Advanced ▸ Share Library XML is off); skipped")
            return
        }
        let xmlIDs = Set(tracks.values.compactMap { ($0 as? [String: Any])?["Persistent ID"] as? String })
        let ours = sample.allPersistentIDs.map { MusicPersistentID.hex(Int64(bitPattern: $0)) }
        let hits = ours.filter(xmlIDs.contains).count
        tally.check(hits > 0 && Double(hits) / Double(max(1, ours.count)) > 0.95,
                    "pid hex matches library XML for \(hits)/\(ours.count) songs (\(url.lastPathComponent))")
    }

    /// Reads the Automation grant without asking. `AEDeterminePermissionToAutomateTarget` with
    /// askIfNeeded=false sends no Apple Event and cannot show a prompt. Only done when Music is
    /// already running, so the harness never launches Music.
    private static func automationProbe() async {
        guard MusicAutomation.isMusicRunning else {
            Log.info("automation probe: Music not running; skipped (the harness never launches it)")
            return
        }
        let status = await MusicAutomation.permission(askIfNeeded: false)
        Log.info("automation probe (no event sent, no prompt): OldTunes -> Music status = \(status)")
    }

    /// OLDTUNES_METADATA_LIVE_MUSIC=1: read one cloud song's name from Music by persistent ID.
    /// Sends real Apple Events and may show the Automation prompt, so it needs a person present.
    private static func liveProbe(sample: HarnessLibrarySample, tally: HarnessTally) async {
        guard ProcessInfo.processInfo.environment["OLDTUNES_METADATA_LIVE_MUSIC"] == "1" else {
            Log.info("live Music probe: skipped (set OLDTUNES_METADATA_LIVE_MUSIC=1 with someone present to answer the prompt)")
            return
        }
        guard let item = sample.cloudSamples.first else {
            tally.check(false, "live probe has a cloud song")
            return
        }
        let writer = MusicAppTagWriter()
        var status = await writer.permission(askIfNeeded: false)
        Log.info("live Music probe: permission before = \(status)")
        if status == .undetermined { status = await writer.permission(askIfNeeded: true) }
        Log.info("live Music probe: permission = \(status)")
        do {
            let name = try await writer.name(persistentID: Int64(bitPattern: item.persistentID))
            tally.check(name == item.title, "live Music read of \(MusicPersistentID.hex(Int64(bitPattern: item.persistentID)))",
                        detail: "Music says \(name ?? "nil"), library says \(item.title)")
        } catch {
            tally.check(false, "live Music read", detail: error.localizedDescription)
        }
    }
}
