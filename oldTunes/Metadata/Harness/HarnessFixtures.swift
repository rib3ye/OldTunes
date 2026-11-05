import AppKit

/// Builds the audio files the round-trip test edits. Everything lands in the evidence
/// directory; the only thing read from ~/Music is the five real local files, copied byte for
/// byte and never opened for writing.
@MainActor
enum HarnessFixtures {
    struct Fixture: Sendable {
        var label: String
        var url: URL
        /// One of the real files from Noah's library (a copy), rather than a generated one.
        var isRealCopy: Bool
    }

    /// A song added from a folder, shaped like the index makes one. Only these rows have their
    /// tags written straight into the file; a Music-library song (even one with a file on this
    /// Mac) is saved through Music, so every file fixture the harness edits directly is one.
    nonisolated static func folderTrack(id: Track.ID, url: URL?, bucket: Track.Bucket = .local) -> Track {
        var t = Track.blank(id: id)
        t.origin = .folder
        t.fileURL = url
        t.bucket = bucket
        return t
    }

    /// R1 (RESEARCH.md §10): can the signed app read the real local files? Reads each one,
    /// logs its byte count, and copies it into `dir`.
    static func copyRealFiles(_ items: [HarnessLibrarySample.Item], into dir: URL, tally: HarnessTally) -> [Fixture] {
        var copies: [Fixture] = []
        Log.info("R1: \(items.count) song(s) in the library are local files")
        for (n, item) in items.enumerated() {
            guard let src = item.location else {
                tally.check(false, "R1 file \(n + 1) has a location", detail: item.title)
                continue
            }
            let readable = FileManager.default.isReadableFile(atPath: src.path)
            let data = FileManager.default.contents(atPath: src.path)
            tally.check(data != nil, "R1 read \(src.lastPathComponent)",
                        detail: "isReadable=\(readable) path=\(src.path)")
            guard let data else { continue }
            let dst = dir.appendingPathComponent("real\(n + 1)-\(src.lastPathComponent)")
            try? FileManager.default.removeItem(at: dst)
            do {
                try FileManager.default.copyItem(at: src, to: dst)
                let copied = (try? FileManager.default.attributesOfItem(atPath: dst.path)[.size] as? Int) ?? -1
                Log.info("R1 copy \(n + 1): \"\(item.title)\" \(src.path) -> \(dst.lastPathComponent) " +
                         "read=\(data.count) bytes copied=\(copied) bytes kind=\(item.kind)")
                tally.check(copied == data.count, "R1 copy \(src.lastPathComponent) byte count matches (\(data.count))")
                // The copy keeps the original's mode; make sure the round trip can write it.
                try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dst.path)
                copies.append(Fixture(label: "real\(n + 1).\(src.pathExtension.lowercased())", url: dst, isRealCopy: true))
            } catch {
                tally.check(false, "R1 copy \(src.lastPathComponent)", detail: error.localizedDescription)
            }
        }
        return copies
    }

    /// say → AIFF, then afconvert to AAC, ALAC, WAV and FLAC, and the lame CLI for MP3
    /// (afconvert cannot write MP3, and MP3 is the format with the year trap).
    static func generate(into dir: URL, tally: HarnessTally) async -> [Fixture] {
        let aiff = dir.appendingPathComponent("gen.aiff")
        let jobs: [(String, String, [String])] = [
            ("gen-aac.m4a", "/usr/bin/afconvert", ["-f", "m4af", "-d", "aac"]),   // say writes 22 kHz mono; 128k is out of range
            ("gen-alac.m4a", "/usr/bin/afconvert", ["-f", "m4af", "-d", "alac"]),
            ("gen.wav", "/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16"]),
            ("gen.flac", "/usr/bin/afconvert", ["-f", "flac", "-d", "flac"]),
        ]
        let result = await Task.detached { () -> [String: String] in
            var log: [String: String] = [:]
            let fm = FileManager.default
            for name in ["gen.aiff"] + jobs.map(\.0) + ["gen.mp3"] {
                try? fm.removeItem(at: dir.appendingPathComponent(name))
            }
            log["gen.aiff"] = run("/usr/bin/say", ["-o", aiff.path, "oldTunes fixture. Testing tags, two thousand five."])
            for (name, tool, args) in jobs {
                log[name] = run(tool, args + [aiff.path, dir.appendingPathComponent(name).path])
            }
            // SFBAudioEngine's bundled LAME hits a debug assertion (psymodel.c calc_energy) on say's
            // 22 kHz mono output and takes the process down, so MP3 comes from the lame CLI when
            // it is installed; the real library MP3 (copied in R1) covers the format regardless.
            let lame = "/opt/homebrew/bin/lame"
            if fm.isExecutableFile(atPath: lame) {
                log["gen.mp3"] = run(lame, ["--quiet", "-b", "128", dir.appendingPathComponent("gen.wav").path,
                                            dir.appendingPathComponent("gen.mp3").path])
            } else {
                log["gen.mp3"] = "skipped: no lame CLI"
            }
            return log
        }.value

        var fixtures: [Fixture] = []
        for name in ["gen.aiff"] + jobs.map(\.0) + ["gen.mp3"] {
            let url = dir.appendingPathComponent(name)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if result[name]?.hasPrefix("skipped") == true {
                Log.info("fixture \(name): \(result[name] ?? "")")
                continue
            }
            tally.check(size > 0, "fixture \(name) generated (\(size) bytes)", detail: result[name] ?? "")
            if size > 0 { fixtures.append(Fixture(label: name, url: url, isRealCopy: false)) }
        }
        return fixtures
    }

    nonisolated private static func run(_ tool: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return p.terminationStatus == 0 ? "ok" : "exit \(p.terminationStatus): \(msg)"
        } catch {
            return "error: \(error.localizedDescription)"
        }
    }

    /// A 600×600 PNG that is unmistakably test artwork: Aqua-blue gradient, a disc, and a label.
    static func artworkPNG(label: String, hue: CGFloat = 0.58) -> Data {
        let size = 600
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return Data() }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        NSGradient(starting: NSColor(hue: hue, saturation: 0.55, brightness: 1, alpha: 1),
                   ending: NSColor(hue: hue, saturation: 0.9, brightness: 0.55, alpha: 1))?.draw(in: rect, angle: -90)
        NSColor(white: 1, alpha: 0.25).setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: 110, dy: 110)).fill()
        NSColor(white: 1, alpha: 0.6).setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: 260, dy: 260)).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "LucidaGrande-Bold", size: 54) ?? NSFont.boldSystemFont(ofSize: 54),
            .foregroundColor: NSColor.white]
        let text = label as NSString
        let ts = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: (CGFloat(size) - ts.width) / 2, y: 40), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }
}
