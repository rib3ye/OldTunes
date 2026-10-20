import Foundation

/// OLDTUNES_VIS_MODE=cycles — fifty on/off cycles, then a leak check. Written in M5 (verification); see docs/VISUALIZER.md.
extension VisualizerHarness {
    static func cycles(_ bench: VisualizerBench) async {
        bench.check("cycles bench", false, "not written yet: M5 (verification)")
    }
}
