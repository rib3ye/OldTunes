import Foundation

/// OLDTUNES_VIS_MODE=parity — the ported engine against numbers from the original JavaScript. Written in M2 (engine port); see docs/VISUALIZER.md.
extension VisualizerHarness {
    static func parity(_ bench: VisualizerBench) async {
        bench.check("parity bench", false, "not written yet: M2 (engine port)")
    }
}
