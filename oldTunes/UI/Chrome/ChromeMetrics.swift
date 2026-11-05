import AppKit

/// Text baselines (window y, points) and the LCD end buttons, re-measured from the reference
/// screenshot itunes_old_big.jpg by scanning its ink, because RESEARCH.md §7.2 disagrees with the
/// picture by 1–2 pt. With §7.2's 57 the LCD's second line sat 2.5 pt above the scrubber; the
/// reference leaves 5. Everything else in the chrome comes from Theme.Metrics.
/// (Reported as a contract request: Theme should carry these values.)
@MainActor
enum ChromeMetrics {
    /// "iTunes": cap top y 8, baseline 17.
    static let titleBaseline: CGFloat = 17
    /// "Brushfire Fairytales": §7.2 says 43.
    static let lcdLine1Baseline: CGFloat = 42
    /// "Elapsed Time: 0:45": §7.2 says 57.
    static let lcdLine2Baseline: CGFloat = 55
    /// "Search" and "Browse": §7.2 says 78.
    static let labelBaseline: CGFloat = 80
    /// "3293 songs, …" in a 500 pt window, so 13 pt above the bottom edge: §7.2 says 488.
    static let summaryBaselineFromBottom: CGFloat = 13
    /// The LCD's round end buttons: ink spans 11 px (x 239…249, y 47…57 in the 1x screenshot),
    /// centred 10.5 pt in from each end of the capsule. §7.2 says 13, which drew them visibly
    /// larger and heavier than the reference.
    static let lcdEndButtonDiameter: CGFloat = 11
    static let lcdEndButtonInset: CGFloat = 10.5
}
