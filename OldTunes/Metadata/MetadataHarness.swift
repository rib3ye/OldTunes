import AppKit

/// OLDTUNES_HARNESS=metadata — test bench for tag reading/writing and the Get Info window,
/// run against Noah's real library (read-only) and fixture files in an evidence directory.
///
///   OLDTUNES_METADATA_EVIDENCE=/abs/dir   where fixtures, logs and PNGs go
///   OLDTUNES_METADATA_STEPS=ui            only the Get Info part (reuses existing fixtures)
///   OLDTUNES_METADATA_STEPS=verify        only the pointer/race checks (reuses existing fixtures)
///   OLDTUNES_METADATA_STEPS=routing       only the review-fix checks: origin routing, the
///                                         compilation box, one post per save, and the ingest
///                                         round trip (reuses existing fixtures)
///   OLDTUNES_DB_PATH=/abs/index.sqlite    a private index for the ingest round trip; without
///                                         it that step is skipped, so the real index is never
///                                         written
///   OLDTUNES_METADATA_LIVE_MUSIC=1        also read one song's name from Music by persistent
///                                         ID — sends Apple Events; needs a person present
///
/// No step sends an Apple Event unless OLDTUNES_METADATA_LIVE_MUSIC=1: every cloud write in
/// the harness goes to a recording stand-in for Music.app.
@MainActor
enum MetadataHarness {
    /// The settings the steps clear or set so each sheet check starts from a known state: the
    /// file warning's "Don't show again" box. The harness runs with the app's own bundle id, so
    /// these are the user's settings; run() puts them back before quitting. A step that starts
    /// touching another setting adds its key here.
    static let settingsKeys = [GetInfoPrompts.suppressFileWarningKey]

    static func run() async {
        let defaults = UserDefaults.standard
        let saved = settingsKeys.map { ($0, defaults.object(forKey: $0)) }
        let env = ProcessInfo.processInfo.environment
        let evidence = URL(fileURLWithPath: env["OLDTUNES_METADATA_EVIDENCE"]
                           ?? NSTemporaryDirectory() + "oldtunes-metadata-evidence", isDirectory: true)
        let fixtures = evidence.appendingPathComponent("fixtures", isDirectory: true)
        try? FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        let steps = env["OLDTUNES_METADATA_STEPS"] ?? "all"
        let uiOnly = steps == "ui" || steps == "verify" || steps == "routing"
        let tally = HarnessTally()
        let started = Date()
        // AppDelegate quits when the last window closes, and AppKit makes that check a moment
        // after a close. An invisible window held for the whole run keeps one step's last close
        // from ending the steps after it.
        let anchor = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: .borderless,
                              backing: .buffered, defer: false)
        anchor.alphaValue = 0
        anchor.ignoresMouseEvents = true
        anchor.isReleasedWhenClosed = false
        anchor.orderBack(nil)
        defer { anchor.orderOut(nil) }
        Log.info("metadata harness: evidence=\(evidence.path) steps=\(steps)")

        let sample = await HarnessLibrarySample.load()
        if let error = sample.error {
            tally.check(false, "iTunesLibrary loads", detail: error)
        } else {
            Log.info("library: \(sample.songCount) songs, \(sample.localFiles.count) local files, " +
                     "\(sample.cloudSamples.count) cloud samples with artwork")
        }

        // The harness's TagEditor can never reach Music: cloud writes go to a recorder.
        let editor = TagEditor(cloud: RecordingCloudWriter(answers: [.denied]))

        if !uiOnly {
            // (a) R1: read and copy the real local files.
            let realCopies = HarnessFixtures.copyRealFiles(sample.localFiles, into: fixtures, tally: tally)
            // (b) Generated fixtures.
            let generated = await HarnessFixtures.generate(into: fixtures, tally: tally)
            // (c) Round trip every fixture.
            let all = realCopies + generated
            let perFormat = await HarnessRoundTrip.run(all, editor: editor, tally: tally)
            for fixture in all {
                let (pass, fail) = perFormat[fixture.label] ?? (0, 0)
                Log.info("FORMAT \(fixture.label)\(fixture.isRealCopy ? " (copy of a real library file)" : ""): " +
                         "\(pass) PASS, \(fail) FAIL")
            }
            await HarnessRoundTrip.refusals(in: fixtures, source: generated.first { $0.label == "gen-aac.m4a" }?.url,
                                            editor: editor, tally: tally)
            HarnessRoundTrip.yearTrapProbe(source: generated.first { $0.label == "gen.mp3" }?.url, dir: fixtures, tally: tally)
            HarnessRoundTrip.yearTrapProbe(source: generated.first { $0.label == "gen.aiff" }?.url, dir: fixtures, tally: tally)
            await HarnessRoundTrip.untouchedYear(original: sample.localFiles.first { $0.location?.pathExtension.lowercased() == "mp3" }?.location,
                                                 dir: fixtures, editor: editor, tally: tally)
            await HarnessRoundTrip.cloudRouting(sample: sample, tally: tally)
            // (d) Persistent IDs.
            await HarnessIDs.run(sample: sample, tally: tally)
        }

        // (e) The Get Info window.
        if steps == "all" || steps == "ui" {
            await HarnessGetInfo.run(sample: sample, fixturesDir: fixtures, evidence: evidence, tally: tally)
        }
        // Pointer routing and the races a person can hit (added in verification).
        if steps != "routing" {
            await HarnessVerify.run(fixturesDir: fixtures, evidence: evidence, tally: tally)
        }
        // Review findings 1, 2 and 8: where a save goes, the compilation box, one post per save.
        if steps == "all" || steps == "routing" {
            await HarnessRouting.run(sample: sample, fixturesDir: fixtures, evidence: evidence, tally: tally)
            await HarnessRouting.ingestRoundTrip(fixturesDir: fixtures, evidence: evidence, tally: tally)
            // The retro alert AppController uses in place of NSAlert.
            await HarnessAlert.run(evidence: evidence, tally: tally)
        }

        // Every step returns here, early returns included, so this is the one place to put the
        // user's settings back; the ingest round trip clears one and has no restore of its own.
        // Not in a defer: terminate() never returns.
        for (key, value) in saved {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        let restored = saved.allSatisfy { key, value in
            (defaults.object(forKey: key) as? NSObject) == (value as? NSObject)
        }
        func describe(_ value: Any?) -> String { value.map { "\($0)" } ?? "absent" }
        tally.check(restored, "settings: the user's own settings are put back "
                    + "(\(saved.filter { $0.1 != nil }.count) of \(saved.count) keys were set before the run)",
                    detail: saved.map { "\($0.0) was \(describe($0.1)), now \(describe(defaults.object(forKey: $0.0)))" }
                        .joined(separator: "; "))

        let seconds = Date().timeIntervalSince(started)
        Log.info(String(format: "metadata harness: %d PASS, %d FAIL in %.1f s", tally.passed, tally.failed, seconds))
        if !tally.failures.isEmpty { Log.error("metadata harness failures: \(tally.failures.joined(separator: " | "))") }
        Log.info(tally.failed == 0 ? "METADATA HARNESS: ALL PASS" : "METADATA HARNESS: FAILURES")
        Log.flush()
        NSApp.terminate(nil)
    }
}
