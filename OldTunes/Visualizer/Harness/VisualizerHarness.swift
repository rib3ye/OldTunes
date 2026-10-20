import AppKit

/// OLDTUNES_HARNESS=visualizer — test bench for the visualizer (docs/VISUALIZER.md).
///
/// OLDTUNES_VIS_MODE picks one part; each lives in its own file:
///   core    the shared pieces: the sample ring and host-clock maths (VisualizerHarness+Core)
///   parity  the ported engine against numbers from the original JavaScript (+Parity)
///   audio   the tap, the AnalyserNode emulation and the silence watchdog (+Audio)
///   render  the Metal renderer, HDR and SDR (+Render)
///   ui      the button, menu, full screen, keys and Settings (+UI)
///   cycles  fifty on/off cycles, then a leak check (+Cycles)
/// Benches tap muted unless OLDTUNES_VIS_AUDIBLE=1, so a run never plays music out loud.
@MainActor
enum VisualizerHarness {
    static func run() async {
        let mode = ProcessInfo.processInfo.environment["OLDTUNES_VIS_MODE"] ?? "core"
        let bench = VisualizerBench(mode: mode)
        switch mode {
        case "core":   core(bench)
        case "parity": await parity(bench)
        case "audio":  await audio(bench)
        case "render": await render(bench)
        case "ui":     await ui(bench)
        case "cycles": await cycles(bench)
        default:
            bench.check("mode", false, "unknown OLDTUNES_VIS_MODE \(mode); use core, parity, audio, render, ui or cycles")
        }
        bench.finish()
        Log.flush()
        NSApp.terminate(nil)
    }

    /// Whether this run may make sound (OLDTUNES_VIS_AUDIBLE=1).
    static var audible: Bool { ProcessInfo.processInfo.environment["OLDTUNES_VIS_AUDIBLE"] == "1" }
}

/// PASS/FAIL bookkeeping for one bench run, in the log's usual shape.
@MainActor
final class VisualizerBench {
    let mode: String
    private(set) var passed = 0
    private(set) var failed = 0

    init(mode: String) {
        self.mode = mode
        Log.info("visualizer \(mode): start")
    }

    func check(_ name: String, _ ok: Bool, _ detail: String) {
        if ok { passed += 1 } else { failed += 1 }
        let line = "visualizer \(mode): \(ok ? "PASS" : "FAIL") \(name): \(detail)"
        if ok { Log.info(line) } else { Log.error(line) }
    }

    func note(_ message: String) {
        Log.info("visualizer \(mode): \(message)")
    }

    func finish() {
        Log.info("VISUALIZER \(mode.uppercased()) RESULT: \(passed) PASS, \(failed) FAIL")
    }
}
