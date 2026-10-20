import Foundation

/// OLDTUNES_VIS_MODE=render — the Metal renderer in HDR and SDR. Written in M3 (Metal renderer); see docs/VISUALIZER.md.
extension VisualizerHarness {
    static func render(_ bench: VisualizerBench) async {
        bench.check("render bench", false, "not written yet: M3 (Metal renderer)")
    }
}
