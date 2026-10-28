import AudioToolbox
import CoreAudio
import Foundation

/// OLDTUNES_PLAYBACK_MODE=permission — harness-only: SystemAudioProbe against this Mac's real
/// System Audio Recording setting, and a cheaper check a developer reported but Apple hasn't
/// confirmed: writing `kAudioTapPropertyDescription` back to a tap fails with
/// `kAudioDevicePermissionsError` ('hog!') when the permission is off. Never changes TCC, so it
/// only sees the answers for the setting this build has. Logs a PASS or FAIL line per check:
/// - the probe hears its tone, three times, with how long each took;
/// - with silence simulated, the probe answers denied;
/// - writing a tap's description back succeeds, for a muted tap of OldTunes and for an unmuted
///   global tap, and how long that takes.
@available(macOS 14.2, *)
@MainActor
enum PermissionBench {
    private static var passed = 0
    private static var failed = 0

    static func run() async {
        for attempt in 1...3 {
            let began = ContinuousClock.now
            let answer = await SystemAudioProbe.run()
            check("probe \(attempt) of 3 finds System Audio Recording on", answer == .granted,
                  "\(answer.rawValue) in \(ms(began.duration(to: .now))) ms")
        }
        let began = ContinuousClock.now
        let simulated = await SystemAudioProbe.run(simulatingMissingPermission: true)
        check("with silence simulated, the probe answers denied", simulated == .denied,
              "\(simulated.rawValue) in \(ms(began.duration(to: .now))) ms")

        // The probe has played through OldTunes, so it has a process object to tap.
        let me = HAL.processObject(getpid())
        if me != HAL.unknown {
            let own = CATapDescription(stereoMixdownOfProcesses: [me])
            own.muteBehavior = .mutedWhenTapped
            writeBack("OldTunes, muted", own)
        } else {
            fail("a tap of OldTunes to write back to", "OldTunes has no audio process object")
        }
        let global = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        global.muteBehavior = .unmuted
        writeBack("every process, unmuted", global)
        Log.info("PERMISSION SUMMARY \(passed) passed, \(failed) failed")
    }

    /// Makes a private tap from `description`, reads its description back and writes it again,
    /// then writes it renamed.
    private static func writeBack(_ label: String, _ description: CATapDescription) {
        description.name = "OldTunes permission bench"
        description.isPrivate = true
        var tap = HAL.unknown
        let made = AudioHardwareCreateProcessTap(description, &tap)
        guard made == noErr, tap != HAL.unknown else {
            fail("a tap of \(label) to write back to", "making it failed: \(HAL.describe(made))")
            return
        }
        defer { AudioHardwareDestroyProcessTap(tap) }
        var address = HAL.address(kAudioTapPropertyDescription)
        var settable: DarwinBoolean = false
        let askedSettable = AudioObjectIsPropertySettable(tap, &address, &settable)

        var size = UInt32(MemoryLayout<Unmanaged<CATapDescription>>.size)
        var read: Unmanaged<CATapDescription>?
        let got = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &read)
        guard got == noErr, let current = read?.takeRetainedValue() else {
            fail("the tap of \(label) gives its description back", "reading it failed: \(HAL.describe(got))")
            return
        }
        let began = ContinuousClock.now
        let same = SystemAudioProbe.writeBack(current, to: tap)
        let took = ms(began.duration(to: .now))
        // CATapDescription has no copy(): it isn't NSCopying, and copy() throws.
        current.name = "OldTunes permission bench, renamed"
        let changed = SystemAudioProbe.writeBack(current, to: tap)
        check("writing the description back to a tap of \(label) succeeds with the permission on",
              same == noErr && changed == noErr,
              "settable \(settable.boolValue) (asking: \(HAL.describe(askedSettable))); the same description: \(HAL.describe(same)) "
              + "in \(took) ms; renamed: \(HAL.describe(changed)); 'hog!' would mean no permission")
    }

    private static func check(_ name: String, _ ok: Bool, _ detail: String) {
        if ok {
            passed += 1
            Log.info("PERMISSION PASS \(name): \(detail)")
        } else {
            fail(name, detail)
        }
    }

    private static func fail(_ name: String, _ detail: String) {
        failed += 1
        Log.error("PERMISSION FAIL \(name): \(detail)")
    }

    private static func ms(_ duration: Duration) -> Int {
        Int(Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15)
    }
}
