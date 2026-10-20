/// What the ported engine uses in place of JavaScript's `Math.random()`: doubles in [0, 1).
///
/// The app uses a fast generator. Benches use mulberry32, the generator `tools/visualizer-fixtures.js`
/// puts in place of `Math.random` in the browser, so a seeded Swift run sees exactly the numbers the
/// original saw. Callers keep the original order of random calls (docs/VISUALIZER.md).
public struct RandomSource: Sendable {
    private enum Generator: Sendable {
        case mulberry32(UInt32)
        case splitMix64(UInt64)
    }

    private var generator: Generator

    private init(_ generator: Generator) {
        self.generator = generator
    }

    /// mulberry32, as the fixture tool writes it in JavaScript:
    /// `s = (s + 0x6D2B79F5) >>> 0; t = s; t = Math.imul(t ^ (t >>> 15), t | 1);`
    /// `t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296`.
    public static func mulberry32(seed: UInt32) -> RandomSource {
        RandomSource(.mulberry32(seed))
    }

    /// SplitMix64: fast, statistically good enough for visuals, 53 random bits per double.
    public static func fast(seed: UInt64) -> RandomSource {
        RandomSource(.splitMix64(seed))
    }

    /// A fast generator seeded from the system's random numbers.
    public static func fast() -> RandomSource {
        var system = SystemRandomNumberGenerator()
        return fast(seed: system.next())
    }

    /// The next number in [0, 1).
    public mutating func next() -> Double {
        switch generator {
        case .mulberry32(var s):
            s &+= 0x6D2B_79F5
            var t = s
            t = (t ^ (t >> 15)) &* (t | 1)
            t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
            generator = .mulberry32(s)
            return Double(t ^ (t >> 14)) / 4_294_967_296.0
        case .splitMix64(var s):
            s &+= 0x9E37_79B9_7F4A_7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            generator = .splitMix64(s)
            return Double(z >> 11) * 0x1.0p-53
        }
    }
}
