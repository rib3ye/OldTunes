import Foundation

/// OLDTUNES_VIS_MODE=audio — the tap, the AnalyserNode emulation and the silence watchdog. Written in M1 (audio feed); see docs/VISUALIZER.md.
extension VisualizerHarness {
    static func audio(_ bench: VisualizerBench) async {
        bench.check("audio bench", false, "not written yet: M1 (audio feed)")
    }
}
