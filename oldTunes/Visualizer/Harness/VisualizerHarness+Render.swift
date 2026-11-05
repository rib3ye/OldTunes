import Accelerate
import AppKit
import Metal
import QuartzCore
import VisualizerCore

/// OLDTUNES_VIS_MODE=render — the Metal renderer (milestone M3 in docs/VISUALIZER.md).
///
/// 1. GPU readbacks against CPU references written here, on tiny textures:
///    - the warp shader with known warp maps, noise and decay, wide and tall;
///    - the auto-exposure's decay, dark and bright, with darkening up and down;
///    - the dots adding into the high byte only, alone and inside a real step;
///    - the present shader's palette lookup into HDR and SDR formats, oversampled, with swatches;
///    - the Float16 warp-map conversion, the 32,768-dot cap, and skipping a frame (not waiting)
///      when three are in flight.
/// 2. A 1512×982-point window showing made-up content only (two zoom-and-rotate warp maps, a ring of
///    dots with random sparkles, a fire palette): 10 s in HDR, then 10 s in SDR, driven by the view's
///    display link; then 10 s in HDR driven by a CAMetalDisplayLink. Logs GPU time per step, steps
///    per second, main-thread time (and how much of it waits for a drawable) and the layer's set-up.
/// Launch with MTL_DEBUG_LAYER=1: Metal then checks every call and stops the app at the first error.
/// OLDTUNES_VIS_RENDER_SNAPSHOT=/abs/path.png also writes the SDR window's last frame.
extension VisualizerHarness {
    static func render(_ bench: VisualizerBench) async {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            bench.check("Metal device", false, "MTLCreateSystemDefaultDevice gave nothing")
            return
        }
        RenderBench.validationCheck(bench, device)
        let random = RenderBench.Mulberry32(seed: 12345)
        let presenter: Presenter
        do {
            presenter = try Presenter(device: device, width: 16, height: 8, random: { random.next() })
        } catch {
            bench.check("renderer set-up", false, "\(error)")
            return
        }
        bench.check("shaders compile when the app runs", true,
                    String(format: "9 entry points, fast math off, %.0f ms", presenter.shaderCompileSeconds * 1000))

        let checks = RenderBench(bench: bench, presenter: presenter, queue: queue)
        checks.warpExact()
        checks.warpTall()
        checks.exposure()
        checks.dotsAlone()
        checks.dotsInStep()
        checks.stepsInOneFrame()
        checks.present()
        checks.swatches()
        checks.float16()
        checks.dotCap()
        checks.skipsInsteadOfWaiting()
        await checks.window()
    }
}

/// The render bench's checks and the CPU references they compare against.
@MainActor
private final class RenderBench {
    let bench: VisualizerBench
    let presenter: Presenter
    let queue: MTLCommandQueue
    var warp: GPUWarp { presenter.gpuWarp }
    private var nextFieldID: UInt64 = 1000

    init(bench: VisualizerBench, presenter: Presenter, queue: MTLCommandQueue) {
        self.bench = bench
        self.presenter = presenter
        self.queue = queue
    }

    static func validationCheck(_ bench: VisualizerBench, _ device: MTLDevice) {
        let requested = ProcessInfo.processInfo.environment["MTL_DEBUG_LAYER"] ?? "unset"
        let kind = String(describing: type(of: device))
        bench.note("Metal device \(device.name) (\(kind)), MTL_DEBUG_LAYER=\(requested)")
        if requested == "1" {
            bench.check("Metal API validation is on", kind.contains("Debug"), "device class \(kind)")
        }
    }

    // MARK: - Warp

    /// Four uniform warp maps whose sums land on exact quarter pixels, so the bilinear fractions are
    /// exact and every value can be checked: wrap on both edges, the warp weights, the shift, the
    /// noise texture and offsets, the decay and the rounding.
    func warpExact() {
        let w = 16, h = 8
        let random = Mulberry32(seed: 1)
        presenter.resize(width: w, height: h)
        let noise = (0..<4).map { _ in (0..<65_536).map { _ in UInt8(random.next() * 256) } }
        let old = (0..<w * h).map { _ in UInt16(random.next() * 65_536) }
        // 0.125 × 0.5 (inv_x0x1) × 0.5 × 16 = 0.5 px across; 2 × −0.0625 × 1 × 0.5 × 8 = −0.5 px down.
        let fields = [uniformField(0.125, 0), uniformField(0, -0.0625),
                      randomField(random, scale: 0.2), randomField(random, scale: 0.2)]
        let weights = SIMD4<Float>(1, 2, 0, 0)
        let shift = SIMD2<Float>(0.25, -0.25)
        guard let result = runStep(old: old, noise: noise, fields: fields, weights: weights, shift: shift,
                                   frameIndex: 0, darkening: 0) else { return }
        let expected = Self.warpReference(old: old, width: w, height: h, fields: fields.map(\.halfValues),
                                          weights: weights, shift: shift, noise: noise[0],
                                          noiseOffset: result.noiseOffset, decay: result.decay)
        compare("warp, uniform maps (16×8, wraps both edges)", result.values, expected, tolerance: 1)
    }

    /// A zoom map, sampled bilinearly, on a tall frame: the warp-map coordinates (x0x1 narrower than 2)
    /// and the noise texture chosen by the frame index.
    func warpTall() {
        let w = 24, h = 40
        let random = Mulberry32(seed: 2)
        presenter.resize(width: w, height: h)
        let noise = (0..<4).map { _ in (0..<65_536).map { _ in UInt8(random.next() * 256) } }
        let old = (0..<w * h).map { i in UInt16(1000 + 400 * (i % w) + 300 * (i / w)) }
        let zoom = field { x, y in (-0.06 * x, -0.06 * y) }
        let fields = [zoom, uniformField(0, 0), uniformField(0, 0), uniformField(0, 0)]
        let weights = SIMD4<Float>(1, 0, 0, 0)
        guard let result = runStep(old: old, noise: noise, fields: fields, weights: weights, shift: .zero,
                                   frameIndex: 5, darkening: 0) else { return }
        let expected = Self.warpReference(old: old, width: w, height: h, fields: fields.map(\.halfValues),
                                          weights: weights, shift: .zero, noise: noise[1],
                                          noiseOffset: result.noiseOffset, decay: result.decay)
        compare("warp, bilinear zoom map (24×40, noise texture 5 & 3 = 1)", result.values, expected, tolerance: 1)
    }

    /// exposure_cs: 4,096 hashed samples of the old frame, then the decay formula.
    func exposure() {
        let w = 64, h = 32
        let random = Mulberry32(seed: 3)
        presenter.resize(width: w, height: h)
        let noise = (0..<4).map { _ in [UInt8](repeating: 128, count: 65_536) }
        let fields = (0..<4).map { _ in uniformField(0, 0) }
        let bright = (0..<w * h).map { _ in UInt16(12_000 + random.next() * 40_000) }
        let dark = (0..<w * h).map { _ in UInt16(random.next() * 7_000) }
        for (name, image, darkening) in [("bright", bright, Float(0)), ("bright, darkening 0.5", bright, 0.5),
                                         ("bright, darkening −0.5", bright, -0.5), ("dark", dark, 0)] {
            guard let result = runStep(old: image, noise: noise, fields: fields, weights: SIMD4(1, 0, 0, 0),
                                       shift: .zero, frameIndex: 0, darkening: darkening) else { return }
            let expected = Self.exposureReference(old: image, width: w, height: h,
                                                  noiseOffset: result.noiseOffset, darkening: darkening)
            let ok = abs(result.decay - expected) <= 2e-6 && (name != "dark" || result.decay == Float(0.997))
            bench.check("auto-exposure, \(name)", ok,
                        String(format: "decay %.7f, CPU %.7f", result.decay, expected))
        }
    }

    // MARK: - Dots

    /// The dots pass alone on a known frame: red rises by alpha × coverage × 255 and saturates; green,
    /// blue and alpha, and red outside every dot, stay exactly as they were.
    func dotsAlone() {
        let w = 32, h = 16
        let random = Mulberry32(seed: 4)
        presenter.resize(width: w, height: h)
        presenter.waitUntilIdle()
        let old = (0..<w * h).map { _ in UInt16(random.next() * 25_600) }
        let points = Self.benchDots
        do {
            try warp.replaceIndex(old)
            let before = try warp.readIndexBytes()
            try warp.drawDotsForTesting(points)
            let after = try warp.readIndexBytes()
            checkDots("dots add into the high byte only", before: before, after: after, points: points, width: w, height: h)
        } catch {
            bench.check("dots add into the high byte only", false, "\(error)")
        }
    }

    /// The same dots inside a real step (one render pass with the warp): the step with dots against the
    /// same step without them, from the same frame, noise and random numbers.
    func dotsInStep() {
        let w = 32, h = 16
        let random = Mulberry32(seed: 5)
        presenter.resize(width: w, height: h)
        let noise = (0..<4).map { _ in (0..<65_536).map { _ in UInt8(random.next() * 256) } }
        let old = (0..<w * h).map { _ in UInt16(random.next() * 25_600) }
        let fields = [uniformField(0.125, 0), uniformField(0, -0.0625), uniformField(0, 0), uniformField(0, 0)]
        let points = Self.benchDots
        guard let plain = runStep(old: old, noise: noise, fields: fields, weights: SIMD4(1, 1, 0, 0), shift: .zero,
                                  frameIndex: 0, darkening: 0, seed: 99),
              let dotted = runStep(old: old, noise: noise, fields: fields, weights: SIMD4(1, 1, 0, 0), shift: .zero,
                                   frameIndex: 0, darkening: 0, seed: 99, points: points) else { return }
        checkDots("dots in a step add into the high byte only", before: plain.bytes, after: dotted.bytes,
                  points: points, width: w, height: h)
    }

    /// (x, y, size, alpha): single pixels, a saturating one, round dots, one cut by the corner with
    /// alpha above 1, one with negative alpha, and two on the same pixel.
    static let benchDots: [Float] = [
        3, 2, 1, 0.5,
        10, 8, 1, 1.0,
        20, 7, 5, 0.8,
        0, 0, 3, 2.0,
        28, 12, 1, -1.0,
        6, 12, 1, 0.3,
        6, 12, 1, 0.3,
        15, 3, 2, 0.6,
    ]

    private func checkDots(_ name: String, before: [UInt8], after: [UInt8], points: [Float], width: Int, height: Int) {
        let coverage = Self.dotReference(points: points, width: width, height: height)
        var otherChannels = 0, untouchedRed = 0, worst = 0, touched = 0, saturated = 0
        for i in 0..<width * height {
            if before[i * 4 + 1] != after[i * 4 + 1] || before[i * 4 + 2] != after[i * 4 + 2]
                || before[i * 4 + 3] != after[i * 4 + 3] { otherChannels += 1 }
            let adds = coverage[i]
            if adds.isEmpty {
                if before[i * 4] != after[i * 4] { untouchedRed += 1 }
                continue
            }
            touched += 1
            var red = Double(before[i * 4])
            for add in adds { red = (min(1, red / 255 + Double(add)) * 255).rounded(.toNearestOrEven) }
            if red >= 255 { saturated += 1 }
            worst = max(worst, abs(Int(after[i * 4]) - Int(red)) - (adds.count - 1))
        }
        bench.check(name, otherChannels == 0 && untouchedRed == 0 && worst <= 1 && saturated > 0,
                    "\(touched) pixels lit (\(saturated) at 255), red off by at most \(max(0, worst)) per dot; "
                    + "\(otherChannels) pixels changed green/blue/alpha, \(untouchedRed) changed red outside the dots")
    }

    // MARK: - Present

    /// The present shader: a known frame and palette into HDR's rgba16Float and SDR's bgra8Unorm, at
    /// oversample 1, 2 (2×2 average) and 0.5.
    func present() {
        let random = Mulberry32(seed: 6)
        var palette = (0..<1024).map { _ in Float(random.next() * 3.7 - 0.2) }
        palette[5] = .nan
        palette[9] = .infinity
        palette[13] = -.infinity
        let packed = Self.packPalette(palette)
        presenter.uploadPalette(palette)

        let w = 40, h = 20
        var index = (0..<w * h).map { _ in UInt16(random.next() * 65_536) }
        index[0] = 0xFFFF  // the last entry: no next one to blend towards
        index[1] = 0x00FF
        index[2] = 0x0100
        index[3] = 0x8080

        // Oversample 1: one index pixel per drawable pixel.
        presenter.resize(width: w, height: h, oversample: 1)
        try? warp.replaceIndex(index)
        let expected1 = (0..<w * h).map { Self.presentReference(UInt32(index[$0]), packed) }
        if let hdr = render(.rgba16Float, w, h) { compareColours("present into rgba16Float (HDR)", hdr, expected1, hdr: true) }
        if let sdr = render(.bgra8Unorm, w, h) { compareColours("present into bgra8Unorm (SDR)", sdr, expected1, hdr: false) }

        // Oversample 2: each drawable pixel averages a 2×2 block.
        presenter.resize(width: w / 2, height: h / 2, oversample: 2)
        try? warp.replaceIndex(index)
        let expected2 = (0..<(w / 2) * (h / 2)).map { i -> SIMD4<Float> in
            let x = (i % (w / 2)) * 2, y = (i / (w / 2)) * 2
            let sum = UInt32(index[y * w + x]) + UInt32(index[y * w + x + 1])
                + UInt32(index[(y + 1) * w + x]) + UInt32(index[(y + 1) * w + x + 1])
            return Self.presentReference(UInt32(Float(sum) * (1.0 / 4.0)), packed)
        }
        if let hdr = render(.rgba16Float, w / 2, h / 2) {
            compareColours("present, oversample 2 (2×2 average)", hdr, expected2, hdr: true)
        }

        // Oversample 0.5: the feedback buffer is half size, each of its pixels drawn 2×2.
        presenter.resize(width: w, height: h, oversample: 0.5)
        let small = Array(index.prefix((w / 2) * (h / 2)))
        try? warp.replaceIndex(small)
        let expected3 = (0..<w * h).map { i in Self.presentReference(UInt32(small[(i / w / 2) * (w / 2) + (i % w) / 2]), packed) }
        if let hdr = render(.rgba16Float, w, h) {
            compareColours("present, oversample 0.5 (feedback \(warp.width)×\(warp.height))", hdr, expected3, hdr: true)
        }
    }

    /// draw_palette.js: eight swatches 32 px square in the lower-right corner, each the palette entry at
    /// k/7 of the way along, squared and times 3; the frame shows through everywhere else.
    func swatches() {
        let random = Mulberry32(seed: 7)
        let palette = (0..<1024).map { _ in Float(random.next() * 3) }
        let packed = Self.packPalette(palette)
        presenter.uploadPalette(palette)
        let w = 300, h = 64
        presenter.resize(width: w, height: h, oversample: 1)
        guard let target = makeTarget(.rgba16Float, w, h), let index = try? warp.readIndex() else {
            bench.check("palette swatches", false, "no target")
            return
        }
        presenter.presentForTesting(into: target, paletteSwatchCount: 8)
        let colours = readColours(target)
        var worst: Float = 0
        for k in 0..<8 {
            let x = 36 + 32 * k + 16, y = 24 + 16
            let t = Float(k) * (1.0 / 7.0)
            let xi = min(255, max(0, Int(t * 255)))
            var want = SIMD4<Float>(Float(packed[xi * 4]), Float(packed[xi * 4 + 1]), Float(packed[xi * 4 + 2]), 0) / 255
            want = want * want * 3
            want.w = 1
            worst = max(worst, Self.colourError(colours[y * w + x], want))
        }
        // Just left of the swatches, the frame itself.
        let outside = Self.colourError(colours[40 * w + 35], Self.presentReference(UInt32(index[40 * w + 35]), packed))
        bench.check("palette swatches (draw_palette.js)", worst <= 1 && outside <= 1,
                    String(format: "8 swatches off by %.2f half-float steps at most, frame beside them %.2f", worst, outside))
    }

    /// A 60 Hz screen runs two steps per frame, in one command buffer. Two steps in one frame must give
    /// exactly the frame the same two steps give in two frames. 20,000 dots a step also outgrow the
    /// frame's dot buffer (32,768 dots) halfway, so the frame moves to a bigger one.
    func stepsInOneFrame() {
        let w = 48, h = 24
        let random = Mulberry32(seed: 9)
        presenter.resize(width: w, height: h)
        let noise = (0..<4).map { _ in (0..<65_536).map { _ in UInt8(random.next() * 256) } }
        let old = (0..<w * h).map { _ in UInt16(random.next() * 25_600) }
        let fields = [field { x, y in (0.03 * y, -0.03 * x) }, uniformField(0.125, 0), uniformField(0, 0), uniformField(0, 0)]
        var dots: [[Float]] = []
        for _ in 0..<2 {
            var points = [Float](repeating: 0, count: 20_000 * 4)
            for i in 0..<20_000 {
                points[i * 4] = Float(random.next() * Double(w))
                points[i * 4 + 1] = Float(random.next() * Double(h))
                points[i * 4 + 2] = Float(1 + random.next() * 3)
                points[i * 4 + 3] = Float(random.next() * 0.02)
            }
            dots.append(points)
        }
        func run(framePerStep: Bool) -> (bytes: [UInt8], stats: FrameStats)? {
            do {
                presenter.waitUntilIdle()
                _ = presenter.takeFrameStats()
                let seeded = Mulberry32(seed: 77)
                warp.random = { seeded.next() }
                try warp.replaceNoise(noise)
                try warp.replaceIndex(old)
                for (slot, field) in fields.enumerated() { presenter.setWarpMap(slot: slot, field: field.field) }
                warp.frameIndex = 0
                for points in dots {
                    presenter.warpAndDrawWaveform(weights: SIMD4(1, 0.5, 0, 0), shift: SIMD2(0.3, -0.2), points: points,
                                                  darkening: 0.2, time: 0)
                    if framePerStep { presenter.draw() }
                }
                if !framePerStep { presenter.draw() }
                presenter.waitUntilIdle()
                return (try warp.readIndexBytes(), presenter.takeFrameStats())
            } catch {
                return nil
            }
        }
        guard let together = run(framePerStep: false), let apart = run(framePerStep: true) else {
            bench.check("two steps in one frame", false, "readback failed")
            return
        }
        let differing = zip(together.bytes, apart.bytes).filter { $0 != $1 }.count
        bench.check("two steps in one frame match two frames", differing == 0
                        && together.stats.framesCommitted == 1 && together.stats.stepsEncoded == 2
                        && apart.stats.framesCommitted == 2 && warp.lastDotCount == 20_000,
                    "\(differing) of \(together.bytes.count) bytes differ; one frame held \(together.stats.stepsEncoded) steps "
                    + "and 40,000 dots, the other run \(apart.stats.framesCommitted) frames")
    }

    // MARK: - Uploads, caps and pacing

    /// vImage's Float32 → Float16 against known bit patterns, and a round trip of random values.
    func float16() {
        presenter.resize(width: 16, height: 8)
        let cases: [(Float, UInt16)] = [
            (0, 0x0000), (1, 0x3C00), (-1, 0xBC00), (65504, 0x7BFF), (1e-8, 0x0000), (0.1, 0x2E66),
            (1.0 / 3.0, 0x3555), (70000, 0x7C00), (-0.0, 0x8000), (6.103515625e-05, 0x0400),
            (5.960464477539063e-08, 0x0001), (3.0517578125e-05, 0x0200), (2049, 0x6800), (2051, 0x6802),
            (.infinity, 0x7C00),
        ]
        let random = Mulberry32(seed: 8)
        var values = [Float](repeating: 0, count: GPUWarp.warpMapSize * GPUWarp.warpMapSize * 2)
        for (i, item) in cases.enumerated() { values[i] = item.0 }
        values[cases.count] = .nan
        let roundTripStart = cases.count + 1
        for i in roundTripStart..<roundTripStart + 10_000 { values[i] = Float(random.next() * 8 - 4) }
        presenter.setWarpMap(slot: 3, field: makeField(values).field)
        presenter.warpAndDrawWaveform(weights: SIMD4(0, 0, 0, 0), shift: .zero, points: [], darkening: 0, time: 0)
        presenter.draw()
        presenter.waitUntilIdle()
        guard let bits = try? warp.readWarpMapBits(slot: 3) else {
            bench.check("Float16 warp maps", false, "readback failed")
            return
        }
        let wrong = cases.enumerated().filter { bits[$0.offset] != $0.element.1 }
            .map { String(format: "%g → %04X (want %04X)", $0.element.0, bits[$0.offset], $0.element.1) }
        let nanBits = bits[cases.count]
        let nanOK = nanBits & 0x7C00 == 0x7C00 && nanBits & 0x03FF != 0
        let back = Self.floatsFromHalf(Array(bits[roundTripStart..<roundTripStart + 10_000]))
        var worst: Float = 0
        for (i, value) in back.enumerated() {
            let x = values[roundTripStart + i]
            worst = max(worst, abs(value - x) / max(abs(x), 6.1e-5))
        }
        bench.check("Float16 warp maps (vImage, round to nearest even)", wrong.isEmpty && nanOK && worst <= 1.0 / 2048,
                    "\(cases.count + 1) known values " + (wrong.isEmpty && nanOK ? "exact" : "wrong: \(wrong), NaN \(String(nanBits, radix: 16))")
                    + String(format: "; 10,000 random within %.2e relative", worst))
    }

    /// gpu_warp.js makes the dot renderer with room for 32,768 points; more are left out.
    func dotCap() {
        presenter.resize(width: 16, height: 8)
        let before = warp.droppedDots
        let points = [Float]((0..<40_000).map { _ -> [Float] in [-50, -50, 1, 1] }.joined())
        presenter.warpAndDrawWaveform(weights: SIMD4(0, 0, 0, 0), shift: .zero, points: points, darkening: 0, time: 0)
        presenter.draw()
        presenter.waitUntilIdle()
        bench.check("dots capped at 32,768 per step", warp.lastDotCount == 32_768 && warp.droppedDots - before == 7_232,
                    "40,000 sent: \(warp.lastDotCount) drawn, \(warp.droppedDots - before) left out")
    }

    /// With three frames held on the GPU, the fourth frame's step and draw are dropped at once.
    func skipsInsteadOfWaiting() {
        presenter.resize(width: 64, height: 32)
        presenter.waitUntilIdle()
        _ = presenter.takeFrameStats()
        guard let event = presenter.device.makeSharedEvent() else {
            bench.check("skips a frame instead of waiting", false, "no shared event")
            return
        }
        presenter.holdFramesForTesting(until: event, value: 1)
        var slowest = 0.0
        for _ in 0..<4 {
            let start = CACurrentMediaTime()
            presenter.warpAndDrawWaveform(weights: SIMD4(0, 0, 0, 0), shift: .zero, points: [], darkening: 0, time: 0)
            presenter.draw()
            slowest = max(slowest, CACurrentMediaTime() - start)
        }
        let held = presenter.framesInFlight
        event.signaledValue = 1
        presenter.holdFramesForTesting(until: nil)
        presenter.waitUntilIdle()
        let stats = presenter.takeFrameStats()
        bench.check("skips a frame instead of waiting (3 in flight)",
                    held == 3 && stats.framesCommitted == 3 && stats.framesSkipped == 1 && stats.stepsSkipped == 1
                        && slowest < 0.05 && presenter.framesInFlight == 0,
                    String(format: "4 frames asked for: %d in flight, %d committed, %d skipped (%d step); slowest call %.1f ms; %d left after release",
                           held, stats.framesCommitted, stats.framesSkipped, stats.stepsSkipped, slowest * 1000,
                           presenter.framesInFlight))
    }

    // MARK: - Running steps

    struct StepResult {
        var values: [UInt16]
        var bytes: [UInt8]
        var decay: Float
        var noiseOffset: SIMD2<Float>
    }

    /// One real step through the presenter from a known frame, then its result read back.
    private func runStep(old: [UInt16], noise: [[UInt8]], fields: [BenchField], weights: SIMD4<Float>,
                         shift: SIMD2<Float>, frameIndex: Int, darkening: Float, seed: UInt32 = 42,
                         points: [Float] = []) -> StepResult? {
        do {
            presenter.waitUntilIdle()
            let random = Mulberry32(seed: seed)
            warp.random = { random.next() }
            try warp.replaceNoise(noise)
            try warp.replaceIndex(old)
            for (slot, field) in fields.enumerated() { presenter.setWarpMap(slot: slot, field: field.field) }
            warp.frameIndex = frameIndex
            presenter.warpAndDrawWaveform(weights: weights, shift: shift, points: points, darkening: darkening, time: 0)
            presenter.draw()
            presenter.waitUntilIdle()
            let bytes = try warp.readIndexBytes()
            let values = (0..<warp.width * warp.height).map { UInt16(bytes[$0 * 4]) << 8 | UInt16(bytes[$0 * 4 + 1]) }
            return StepResult(values: values, bytes: bytes, decay: warp.readExposureDecay(), noiseOffset: warp.lastNoiseOffset)
        } catch {
            bench.check("step readback", false, "\(error)")
            return nil
        }
    }

    private func compare(_ name: String, _ got: [UInt16], _ want: [UInt16], tolerance: Int) {
        var exact = 0, worst = 0
        for (g, e) in zip(got, want) {
            let d = abs(Int(g) - Int(e))
            if d == 0 { exact += 1 }
            worst = max(worst, d)
        }
        bench.check(name, got.count == want.count && worst <= tolerance,
                    "\(exact)/\(want.count) exact, off by at most \(worst)")
    }

    // MARK: - Warp maps for the bench

    /// A warp map with the Float16 values the GPU sees, for the CPU reference.
    struct BenchField {
        var field: WarpField
        var halfValues: [Float]
    }

    private func makeField(_ dxy: [Float]) -> BenchField {
        nextFieldID += 1
        return BenchField(field: WarpField(id: nextFieldID, size: GPUWarp.warpMapSize, dxy: dxy),
                          halfValues: Self.floatsFromHalf(Self.halfBits(dxy)))
    }

    private func uniformField(_ dx: Float, _ dy: Float) -> BenchField {
        makeField((0..<GPUWarp.warpMapSize * GPUWarp.warpMapSize).flatMap { _ in [dx, dy] })
    }

    private func randomField(_ random: Mulberry32, scale: Double) -> BenchField {
        makeField((0..<GPUWarp.warpMapSize * GPUWarp.warpMapSize * 2).map { _ in Float((random.next() * 2 - 1) * scale) })
    }

    /// A map from a function of the texel's normalized position, i/256 − 1 across and down.
    private func field(_ f: (Double, Double) -> (Double, Double)) -> BenchField {
        let n = GPUWarp.warpMapSize
        var dxy = [Float](repeating: 0, count: n * n * 2)
        for j in 0..<n {
            for i in 0..<n {
                let (dx, dy) = f(Double(i) / 256 - 1, Double(j) / 256 - 1)
                dxy[(j * n + i) * 2] = Float(dx)
                dxy[(j * n + i) * 2 + 1] = Float(dy)
            }
        }
        return makeField(dxy)
    }

    // MARK: - CPU references

    /// warp_fs on the CPU, in Float, in the shader's order of operations.
    static func warpReference(old: [UInt16], width: Int, height: Int, fields: [[Float]], weights: SIMD4<Float>,
                              shift: SIMD2<Float>, noise: [UInt8], noiseOffset: SIMD2<Float>, decay: Float) -> [UInt16] {
        let fw = Float(width), fh = Float(height)
        let spans = WarpSpans(width: width, height: height)
        var out = [UInt16](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let dx = Float(x) + 0.5, dy = Float(y) + 0.5
                var u = dx * (1 / (fw - 1)), v = dy * (1 / (fh - 1))
                u = (u - 0.5) * spans.x0x1
                v = (v - 0.5) * spans.y0y1
                u = u * 0.5 + 0.5
                v = v * 0.5 + 0.5
                u += 0.5 / 512
                v += 0.5 / 512
                var wx: Float = 0, wy: Float = 0
                for slot in 0..<4 {
                    let s = sampleField(fields[slot], u, v)
                    wx += s.0 * weights[slot]
                    wy += s.1 * weights[slot]
                }
                wx *= spans.invX0x1 * 0.5 * fw
                wy *= spans.invY0y1 * 0.5 * fh
                let sx = dx + wx + shift.x - 0.5, sy = dy + wy + shift.y - 0.5
                let x0f = sx.rounded(.down), y0f = sy.rounded(.down)
                let fx = sx - x0f, fy = sy - y0f
                let x0 = wrap(Int(x0f), width), y0 = wrap(Int(y0f), height)
                let x1 = wrap(x0 + 1, width), y1 = wrap(y0 + 1, height)
                let v00 = Float(old[y0 * width + x0]), v01 = Float(old[y0 * width + x1])
                let v10 = Float(old[y1 * width + x0]), v11 = Float(old[y1 * width + x1])
                let a0 = v00 + (v01 - v00) * fx
                let a1 = v10 + (v11 - v10) * fx
                let value = a0 + (a1 - a0) * fy
                var vu = min(max((value + 0.5).rounded(.down), 0), 65_535)
                let nx = (x + Int(noiseOffset.x)) & 255, ny = (y + Int(noiseOffset.y)) & 255
                let n01 = Float(noise[ny * 256 + nx]) / 255
                vu *= powf(1.015, n01 * 2 - 1)
                vu *= decay
                out[y * width + x] = UInt16(max(0, min(65_535, vu + 0.5)))
            }
        }
        return out
    }

    /// Bilinear, clamp to edge, texel centres at (i + 0.5) / 512. Four equal texels give their value
    /// exactly, as the GPU's filter does.
    static func sampleField(_ f: [Float], _ u: Float, _ v: Float) -> (Float, Float) {
        let n = GPUWarp.warpMapSize
        let tx = u * Float(n) - 0.5, ty = v * Float(n) - 0.5
        let x0f = tx.rounded(.down), y0f = ty.rounded(.down)
        let fx = tx - x0f, fy = ty - y0f
        let x0 = min(max(Int(x0f), 0), n - 1), x1 = min(max(Int(x0f) + 1, 0), n - 1)
        let y0 = min(max(Int(y0f), 0), n - 1), y1 = min(max(Int(y0f) + 1, 0), n - 1)
        func at(_ x: Int, _ y: Int) -> (Float, Float) { (f[(y * n + x) * 2], f[(y * n + x) * 2 + 1]) }
        let a = at(x0, y0), b = at(x1, y0), c = at(x0, y1), d = at(x1, y1)
        if a == b, a == c, a == d { return a }
        let top = (a.0 + (b.0 - a.0) * fx, a.1 + (b.1 - a.1) * fx)
        let bottom = (c.0 + (d.0 - c.0) * fx, c.1 + (d.1 - c.1) * fx)
        return (top.0 + (bottom.0 - top.0) * fy, top.1 + (bottom.1 - top.1) * fy)
    }

    /// exposure_cs on the CPU: the same hash, the same 256 × 16 samples, the decay in Float.
    static func exposureReference(old: [UInt16], width: Int, height: Int, noiseOffset: SIMD2<Float>,
                                  darkening: Float) -> Float {
        func hash(_ x: UInt32) -> UInt32 {
            var v = x
            v ^= v >> 16
            v = v &* 0x7FEB_352D
            v ^= v >> 15
            v = v &* 0x846C_A68B
            v ^= v >> 16
            return v
        }
        let sx = UInt32(noiseOffset.x), sy = UInt32(noiseOffset.y)
        var total = 0.0
        for tid in UInt32(0)..<256 {
            var seed = hash(tid ^ (sx &* 1_315_423_911) ^ (sy &* 2_654_435_761))
            for _ in 0..<16 {
                seed = hash(seed &+ 0x9E37_79B9)
                let x = Int(seed % UInt32(width)), y = Int((seed >> 16) % UInt32(height))
                total += Double(old[y * width + x])
            }
        }
        let avg8 = Float(total / 4096) * (1 / 256)
        let expBase: Float = darkening >= 0 ? 0.990 : 0.997
        let adjusted = 0.997 * powf(expBase, darkening)
        let extra = max(avg8 - 30 * (1 - darkening), 0)
        return max(0, adjusted - extra * 0.000075)
    }

    /// dots_vs and dots_fs on the CPU: for each pixel, the alpha × coverage each dot adds, in order.
    static func dotReference(points: [Float], width: Int, height: Int) -> [[Float]] {
        var adds = [[Float]](repeating: [], count: width * height)
        for d in 0..<points.count / 4 {
            let cx = points[d * 4], cy = points[d * 4 + 1], a = points[d * 4 + 3]
            let size = max(points[d * 4 + 2], 1)
            var half = 0.5 * size, r1: Float = 4, r2: Float = 5
            if size >= 1.0001 {
                let ideal = powf(size * size / 3.1415927, 0.5)
                r1 = ideal * 0.5
                r2 = ideal * 1.5
                half = r2.rounded(.up)
            }
            for y in 0..<height {
                for x in 0..<width {
                    // The pixel centre x + 0.5 against the quad's edges, cx ± half + 0.5.
                    let px = Float(x) + 0.5, py = Float(y) + 0.5
                    guard px > cx - half + 0.5, px < cx + half + 0.5, py > cy - half + 0.5, py < cy + half + 0.5 else { continue }
                    let r = ((Float(x) - cx) * (Float(x) - cx) + (Float(y) - cy) * (Float(y) - cy)).squareRoot()
                    var coverage = 1 - (r - r1) / (r2 - r1 + 0.000001)
                    coverage = max(0, min(1, coverage))
                    let add = max(0, min(1, a)) * coverage
                    if add > 0 { adds[y * width + x].append(add) }
                }
            }
        }
        return adds
    }

    /// uploadPaletteRGBA8UNorm on the CPU: √(min(1, v/3)) × 255, rounded; NaN gives 0.
    static func packPalette(_ rgba: [Float]) -> [UInt8] {
        rgba.map { value in
            let v = Double(value) / 3
            if v.isNaN { return 0 }
            return UInt8(min(1, max(0, v)).squareRoot() * 255 + 0.5)
        }
    }

    /// present_fs for one averaged index value.
    static func presentReference(_ avg: UInt32, _ packed: [UInt8]) -> SIMD4<Float> {
        let hi = Int((avg >> 8) & 255), lo = avg & 255
        let t = Float(lo) * (1.0 / 256.0)
        func entry(_ i: Int) -> SIMD4<Float> {
            SIMD4(Float(packed[i * 4]), Float(packed[i * 4 + 1]), Float(packed[i * 4 + 2]), Float(packed[i * 4 + 3])) / 255
        }
        var col = entry(hi) * (1 - t) + t * entry(min(255, hi + 1))
        col = col * col
        return col * 3
    }

    /// The largest difference between two colours, in half-float steps at the colour's size
    /// (2⁻¹⁰ relative above 1, 2⁻¹⁰ absolute below).
    static func colourError(_ got: SIMD4<Float>, _ want: SIMD4<Float>) -> Float {
        var worst: Float = 0
        for c in 0..<4 { worst = max(worst, abs(got[c] - want[c]) / (max(abs(want[c]), 1) / 1024)) }
        return worst
    }

    private func compareColours(_ name: String, _ got: [SIMD4<Float>], _ want: [SIMD4<Float>], hdr: Bool) {
        var worst: Float = 0, over1 = 0
        for (g, e) in zip(got, want) {
            if hdr {
                worst = max(worst, Self.colourError(g, e))
                if e.x > 1 || e.y > 1 || e.z > 1 { over1 += 1 }
            } else {
                // SDR stores 0…1 in 8 bits: one step is 1/255.
                for c in 0..<3 { worst = max(worst, abs(g[c] - min(1, max(0, e[c]))) * 255) }
            }
        }
        let unit = hdr ? "half-float steps" : "8-bit steps"
        bench.check(name, got.count == want.count && worst <= 1,
                    String(format: "%d pixels, off by %.2f %@ at most", want.count, worst, unit)
                    + (hdr ? ", \(over1) brighter than SDR white" : ""))
    }

    // MARK: - Offscreen targets

    private func makeTarget(_ format: MTLPixelFormat, _ width: Int, _ height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .private
        return presenter.device.makeTexture(descriptor: descriptor)
    }

    /// The present pass into a fresh `format` texture, read back as RGBA floats.
    private func render(_ format: MTLPixelFormat, _ width: Int, _ height: Int) -> [SIMD4<Float>]? {
        guard let target = makeTarget(format, width, height) else { return nil }
        presenter.presentForTesting(into: target)
        return readColours(target)
    }

    func readColours(_ texture: MTLTexture) -> [SIMD4<Float>] {
        let bytesPerPixel = texture.pixelFormat == .rgba16Float ? 8 : 4
        let bytes = readBytes(texture, bytesPerPixel: bytesPerPixel)
        let count = texture.width * texture.height
        if texture.pixelFormat == .rgba16Float {
            let halves = (0..<count * 4).map { UInt16(bytes[$0 * 2]) | UInt16(bytes[$0 * 2 + 1]) << 8 }
            let floats = Self.floatsFromHalf(halves)
            return (0..<count).map { SIMD4(floats[$0 * 4], floats[$0 * 4 + 1], floats[$0 * 4 + 2], floats[$0 * 4 + 3]) }
        }
        // bgra8Unorm
        return (0..<count).map { i in
            SIMD4(Float(bytes[i * 4 + 2]), Float(bytes[i * 4 + 1]), Float(bytes[i * 4]), Float(bytes[i * 4 + 3])) / 255
        }
    }

    func readBytes(_ texture: MTLTexture, bytesPerPixel: Int) -> [UInt8] {
        let bytesPerRow = texture.width * bytesPerPixel
        let length = bytesPerRow * texture.height
        guard let buffer = presenter.device.makeBuffer(length: length, options: .storageModeShared),
              let commandBuffer = queue.makeCommandBuffer(), let blit = commandBuffer.makeBlitCommandEncoder() else { return [] }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: length)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return [UInt8](UnsafeRawBufferPointer(start: buffer.contents(), count: length))
    }

    // MARK: - Small helpers

    static func wrap(_ x: Int, _ n: Int) -> Int {
        let r = x % n
        return r < 0 ? r + n : r
    }

    /// Float → Float16 bits through vImage, as the uploader does.
    static func halfBits(_ values: [Float]) -> [UInt16] {
        var out = [UInt16](repeating: 0, count: values.count)
        values.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                var from = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.baseAddress!), height: 1,
                                         width: vImagePixelCount(values.count), rowBytes: values.count * 4)
                var to = vImage_Buffer(data: dst.baseAddress!, height: 1, width: vImagePixelCount(values.count),
                                       rowBytes: values.count * 2)
                _ = vImageConvert_PlanarFtoPlanar16F(&from, &to, vImage_Flags(kvImageNoFlags))
            }
        }
        return out
    }

    static func floatsFromHalf(_ bits: [UInt16]) -> [Float] {
        var out = [Float](repeating: 0, count: bits.count)
        bits.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                var from = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.baseAddress!), height: 1,
                                         width: vImagePixelCount(bits.count), rowBytes: bits.count * 2)
                var to = vImage_Buffer(data: dst.baseAddress!, height: 1, width: vImagePixelCount(bits.count),
                                       rowBytes: bits.count * 4)
                _ = vImageConvert_Planar16FtoPlanarF(&from, &to, vImage_Flags(kvImageNoFlags))
            }
        }
        return out
    }

    /// coords.js's spans for a frame, the way GPUWarp fills the uniforms (Double, stored as Float).
    struct WarpSpans {
        var x0x1: Float, y0y1: Float, invX0x1: Float, invY0y1: Float

        init(width: Int, height: Int) {
            let aspect = Double(width) / Double(height)
            var x0 = -1.0, x1 = 1.0, y0 = -1.0, y1 = 1.0
            if aspect > 1 {
                y0 /= aspect
                y1 /= aspect
            } else {
                x0 *= aspect
                x1 *= aspect
            }
            x0x1 = Float(x1 - x0)
            y0y1 = Float(y1 - y0)
            invX0x1 = Float(1 / (x1 - x0))
            invY0y1 = Float(1 / (y1 - y0))
        }
    }

    /// mulberry32, the generator tools/visualizer-fixtures.js puts in place of Math.random.
    final class Mulberry32 {
        private var state: UInt32
        init(seed: UInt32) { state = seed }

        func next() -> Double {
            state = state &+ 0x6D2B_79F5
            var t = state
            t = (t ^ (t >> 15)) &* (t | 1)
            t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
            return Double(t ^ (t >> 14)) / 4_294_967_296
        }
    }
}

// MARK: - The on-screen runs

extension RenderBench {
    /// 10 s in HDR, then 10 s in SDR, in a borderless 1512×982-point window (a 14-inch MacBook Pro's
    /// screen at its default size), driven by the view's display link as the plan has it; then 10 s
    /// more in HDR driven by a CAMetalDisplayLink, which hands each update a free drawable, to compare
    /// how long the main thread waits.
    func window() async {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            bench.check("bench window", false, "no screen")
            return
        }
        let size = CGSize(width: min(1512, screen.frame.width), height: min(982, screen.frame.height))
        // Whole points, so the view is exactly this size.
        let frame = NSRect(x: (screen.frame.midX - size.width / 2).rounded(.down),
                           y: (screen.frame.midY - size.height / 2).rounded(.down),
                           width: size.width, height: size.height)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.hasShadow = false
        let view = RenderBenchView(frame: NSRect(origin: .zero, size: size))
        window.contentView = view
        window.orderFrontRegardless()
        NSApp.activate()

        let random = Mulberry32(seed: 2026)
        warp.random = { random.next() }
        presenter.resize(width: Int(view.bounds.width), height: Int(view.bounds.height), oversample: 1)
        let scene = RenderBenchScene(random: random)
        bench.note(String(format: "window %d×%d pt on a %.0f×%.0f pt screen at %.0f×, feedback buffer %d×%d px; "
                          + "screen EDR: potential %.2f, now %.2f, reference %.2f",
                          Int(view.bounds.width), Int(view.bounds.height), screen.frame.width, screen.frame.height,
                          screen.backingScaleFactor, presenter.indexWidth, presenter.indexHeight,
                          screen.maximumPotentialExtendedDynamicRangeColorComponentValue,
                          screen.maximumExtendedDynamicRangeColorComponentValue,
                          screen.maximumReferenceExtendedDynamicRangeColorComponentValue))

        let hdr = Presenter.screenSupportsHDR(screen)
        if hdr {
            await run(hdr: true, metalLink: false, view: view, window: window, scene: scene, screen: screen)
        } else {
            bench.note("this screen can't show HDR (maximumPotentialExtendedDynamicRangeColorComponentValue ≤ 1): HDR runs skipped")
        }
        await run(hdr: false, metalLink: false, view: view, window: window, scene: scene, screen: screen)
        if hdr {
            await run(hdr: true, metalLink: true, view: view, window: window, scene: scene, screen: screen)
        }

        if let path = ProcessInfo.processInfo.environment["OLDTUNES_VIS_RENDER_SNAPSHOT"], !path.isEmpty {
            snapshot(to: URL(fileURLWithPath: path))
        }
        presenter.detach()
        window.orderOut(nil)
    }

    private func run(hdr: Bool, metalLink: Bool, view: RenderBenchView, window: NSWindow, scene: RenderBenchScene,
                     screen: NSScreen) async {
        let mode = (hdr ? "HDR" : "SDR") + (metalLink ? " via CAMetalDisplayLink" : "")
        let layer = view.metalLayer
        window.orderFrontRegardless()
        presenter.attach(layer, hdr: hdr)
        scene.palette = RenderBenchScene.firePalette(hdr: hdr)
        let loop = RenderBenchLoop(presenter: presenter, scene: scene, window: window)
        let stopLink: () -> Void
        let range = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        if metalLink {
            let link = CAMetalDisplayLink(metalLayer: layer)
            link.preferredFrameRateRange = range
            link.preferredFrameLatency = 2
            link.delegate = loop
            link.add(to: .main, forMode: .common)
            stopLink = { link.invalidate() }
        } else {
            let link = view.displayLink(target: loop, selector: #selector(RenderBenchLoop.tick(_:)))
            link.preferredFrameRateRange = range
            link.add(to: .main, forMode: .common)
            stopLink = { link.invalidate() }
        }

        // A second to settle, then ten measured.
        try? await Task.sleep(for: .seconds(1))
        _ = presenter.takeFrameStats()
        loop.resetCounts()
        let start = CACurrentMediaTime()
        try? await Task.sleep(for: .seconds(10))
        let elapsed = CACurrentMediaTime() - start
        let stats = presenter.takeFrameStats()
        let counts = loop.counts
        stopLink()
        presenter.waitUntilIdle()
        _ = presenter.takeFrameStats()

        let colourSpace = (layer.colorspace?.name as String?) ?? "none"
        let formatName = layer.pixelFormat == .rgba16Float ? "rgba16Float" : layer.pixelFormat == .bgra8Unorm ? "bgra8Unorm"
            : "raw \(layer.pixelFormat.rawValue)"
        let setUpOK = hdr
            ? layer.pixelFormat == .rgba16Float && colourSpace == (CGColorSpace.extendedSRGB as String) && layer.wantsExtendedDynamicRangeContent
            : layer.pixelFormat == .bgra8Unorm && colourSpace == (CGColorSpace.sRGB as String) && !layer.wantsExtendedDynamicRangeContent
        bench.check("\(mode) layer set-up", setUpOK,
                    "\(formatName), \(colourSpace), EDR \(layer.wantsExtendedDynamicRangeContent), drawable "
                    + "\(Int(layer.drawableSize.width))×\(Int(layer.drawableSize.height)) px in "
                    + "\(Int(layer.bounds.width))×\(Int(layer.bounds.height)) pt at \(layer.contentsScale)×, "
                    + "magnification \(layer.magnificationFilter.rawValue), opaque \(layer.isOpaque)")

        let withSteps = stats.gpuFrames.filter { $0.steps > 0 }
        let gpuTotal = withSteps.reduce(0) { $0 + $1.seconds }
        let stepTotal = withSteps.reduce(0) { $0 + $1.steps }
        let perStep = stepTotal > 0 ? gpuTotal / Double(stepTotal) * 1000 : .infinity
        let perStepSamples = withSteps.map { $0.seconds / Double($0.steps) * 1000 }.sorted()
        let p95 = perStepSamples.isEmpty ? .infinity : perStepSamples[min(perStepSamples.count - 1, perStepSamples.count * 95 / 100)]
        let worst = perStepSamples.last ?? .infinity
        let stepsPerSecond = Double(stats.stepsEncoded) / elapsed
        let frameRate = Double(counts.callbacks) / elapsed
        let cpu = counts.cpuSeconds.sorted()
        let cpuMean = cpu.isEmpty ? 0 : cpu.reduce(0, +) / Double(cpu.count) * 1000
        let cpuP95 = cpu.isEmpty ? 0 : cpu[min(cpu.count - 1, cpu.count * 95 / 100)] * 1000
        let stepMean = counts.stepSeconds.reduce(0, +) / Double(max(1, counts.stepSeconds.count)) * 1000
        let drawMean = counts.drawSeconds.reduce(0, +) / Double(max(1, counts.drawSeconds.count)) * 1000
        let waitMean = stats.drawableWaitSeconds / Double(max(1, stats.framesCommitted)) * 1000
        let fullSize = presenter.indexWidth == 1512 && presenter.indexHeight == 982
        bench.check("\(mode) GPU time per step ≤ 2 ms", perStep <= 2,
                    String(format: "%.3f ms mean, %.3f ms p95, %.3f ms worst over %d steps in %d frames, at %d×%d px%@",
                           perStep, p95, worst, stepTotal, withSteps.count, presenter.indexWidth, presenter.indexHeight,
                           fullSize ? "" : " (not 1512×982: this screen is smaller)"))
        bench.check("\(mode) steps per second", abs(stepsPerSecond - 120) <= 2,
                    String(format: "%.1f steps/s over %.2f s; display link %.1f Hz, steps per frame %@; "
                           + "main thread %.2f ms mean, %.2f ms p95 per frame (steps %.2f, draw %.2f, of which "
                           + "waiting for a drawable %.2f, longest %.1f)",
                           stepsPerSecond, elapsed, frameRate, counts.stepsPerFrameText, cpuMean, cpuP95,
                           stepMean, drawMean, waitMean, stats.drawableWaitLongest * 1000)
                    + (counts.coveredFrames > 0 ? "; window covered for \(counts.coveredFrames) frames" : ""))
        bench.check("\(mode) frames reach the screen", stats.framesFailed == 0 && stats.framesShown > 0,
                    "\(stats.framesShown) shown, \(stats.framesSkipped) skipped (3 in flight), "
                    + "\(stats.framesMissingDrawable) without a drawable, \(stats.framesFailed) GPU errors; "
                    + "window covered for \(counts.coveredFrames) of \(counts.callbacks) frames, "
                    + String(format: "screen EDR now %.2f", screen.maximumExtendedDynamicRangeColorComponentValue))
    }

    /// The SDR window's last frame as a PNG (made-up content only).
    private func snapshot(to url: URL) {
        let w = presenter.presentWidth, h = presenter.presentHeight
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .private
        guard let target = presenter.device.makeTexture(descriptor: descriptor) else { return }
        presenter.presentForTesting(into: target)
        let bytes = readBytes(target, bytesPerPixel: 4)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32),
              let data = rep.bitmapData else { return }
        for i in 0..<w * h {
            data[i * 4] = bytes[i * 4 + 2]
            data[i * 4 + 1] = bytes[i * 4 + 1]
            data[i * 4 + 2] = bytes[i * 4]
            data[i * 4 + 3] = 255
        }
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try png.write(to: url)
            bench.note("snapshot written: \(url.path) (\(w)×\(h) px, made-up content)")
        } catch {
            bench.note("snapshot NOT written to \(url.path): \(error.localizedDescription)")
        }
    }
}

/// A view whose layer is a CAMetalLayer, as the app's visualizer view will be.
private final class RenderBenchView: NSView {
    let metalLayer = CAMetalLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func makeBackingLayer() -> CALayer { metalLayer }
}

/// The display link's target, for an NSView display link or a CAMetalDisplayLink: each refresh runs
/// the steps the original would (one at 120 Hz, two at 60 Hz), uploads the palette and draws.
@MainActor
private final class RenderBenchLoop: NSObject {
    struct Counts {
        var callbacks = 0
        /// Refreshes with the window not visible (covered by another window, or off screen).
        var coveredFrames = 0
        var cpuSeconds: [Double] = []
        var stepSeconds: [Double] = []
        var drawSeconds: [Double] = []
        var stepsPerFrame: [Int: Int] = [:]

        var stepsPerFrameText: String {
            stepsPerFrame.keys.sorted().map { "\($0)×\(stepsPerFrame[$0] ?? 0)" }.joined(separator: " ")
        }
    }

    let presenter: Presenter
    let scene: RenderBenchScene
    private weak var window: NSWindow?
    private(set) var counts = Counts()
    private var lastPresentation: CFTimeInterval = 0

    init(presenter: Presenter, scene: RenderBenchScene, window: NSWindow) {
        self.presenter = presenter
        self.scene = scene
        self.window = window
    }

    func resetCounts() { counts = Counts() }

    @objc func tick(_ link: CADisplayLink) {
        frame(interval: link.targetTimestamp - link.timestamp, drawable: nil)
    }

    fileprivate func update(_ update: CAMetalDisplayLink.Update) {
        let target = update.targetPresentationTimestamp
        let interval = lastPresentation > 0 ? target - lastPresentation : 1.0 / 120
        lastPresentation = target
        frame(interval: interval, drawable: update.drawable)
    }

    private func frame(interval: CFTimeInterval, drawable: CAMetalDrawable?) {
        let start = CACurrentMediaTime()
        let hz = interval > 0 ? 1 / interval : 120
        // main.js frame(): below 65% of 120 Hz, round(120 / hz − 0.25) steps per frame, at most 10.
        let steps = hz < 120 * 0.65 ? min(10, max(1, Int((120 / hz - 0.25).rounded()))) : 1
        for _ in 0..<steps { scene.step(presenter) }
        let stepped = CACurrentMediaTime()
        presenter.uploadPalette(scene.palette)
        if let drawable { presenter.draw(to: drawable) } else { presenter.draw() }
        let end = CACurrentMediaTime()
        counts.callbacks += 1
        if window?.occlusionState.contains(.visible) != true { counts.coveredFrames += 1 }
        counts.stepsPerFrame[steps, default: 0] += 1
        counts.cpuSeconds.append(end - start)
        counts.stepSeconds.append(stepped - start)
        counts.drawSeconds.append(end - stepped)
    }
}

/// CAMetalDisplayLink calls its delegate on the run loop it was added to: the main one here.
extension RenderBenchLoop: @preconcurrency CAMetalDisplayLinkDelegate {
    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        self.update(update)
    }
}

/// Made-up content for the window: two zoom-and-rotate warp maps turning opposite ways, crossfaded
/// every few seconds (one of them swapped for a variant every 2.5 s, so maps upload mid-run), a
/// wobbling ring of dots like a waveform, random sparkles, and a fire palette that goes to 3× SDR
/// white in HDR.
@MainActor
private final class RenderBenchScene {
    let random: RenderBench.Mulberry32
    var palette: [Float] = []
    private var stepIndex = 0
    private let clockwise: WarpField
    private let counterClockwise: WarpField
    private let counterClockwiseFaster: WarpField
    private let still: WarpField

    init(random: RenderBench.Mulberry32) {
        self.random = random
        clockwise = Self.zoomRotate(id: 1, zoom: 1.004, degrees: 0.12)
        counterClockwise = Self.zoomRotate(id: 2, zoom: 1.003, degrees: -0.10)
        counterClockwiseFaster = Self.zoomRotate(id: 3, zoom: 1.005, degrees: -0.16)
        still = WarpField(id: 4, size: GPUWarp.warpMapSize,
                          dxy: [Float](repeating: 0, count: GPUWarp.warpMapSize * GPUWarp.warpMapSize * 2))
    }

    func step(_ presenter: Presenter) {
        let t = Double(stepIndex) / 120
        presenter.setWarpMap(slot: 0, field: clockwise)
        presenter.setWarpMap(slot: 1, field: Int(t / 2.5) % 2 == 0 ? counterClockwise : counterClockwiseFaster)
        presenter.setWarpMap(slot: 2, field: still)
        presenter.setWarpMap(slot: 3, field: still)
        let mix = Float(0.5 + 0.5 * cos(t * 2 * .pi / 8))
        presenter.warpAndDrawWaveform(weights: SIMD4(mix, 1 - mix, 0, 0), shift: .zero,
                                      points: dots(t, width: presenter.indexWidth, height: presenter.indexHeight),
                                      darkening: 0, time: Float(t))
        stepIndex += 1
    }

    private func dots(_ t: Double, width: Int, height: Int) -> [Float] {
        let ring = 1024, sparkles = 32
        var points = [Float](repeating: 0, count: (ring + sparkles) * 4)
        let cx = Double(width) / 2, cy = Double(height) / 2, radius = 0.28 * Double(min(width, height))
        for k in 0..<ring {
            let a = Double(k) / Double(ring) * 2 * .pi
            let r = radius * (1 + 0.15 * sin(5 * a + 3 * t) + 0.08 * sin(9 * a - 5 * t))
            points[k * 4] = Float(cx + r * cos(a))
            points[k * 4 + 1] = Float(cy + r * sin(a))
            points[k * 4 + 2] = 2
            points[k * 4 + 3] = 0.5
        }
        for k in ring..<ring + sparkles {
            points[k * 4] = Float(random.next() * Double(width))
            points[k * 4 + 1] = Float(random.next() * Double(height))
            points[k * 4 + 2] = Float(1 + random.next() * 3)
            points[k * 4 + 3] = Float(0.3 + random.next() * 0.7)
        }
        return points
    }

    /// src = R(θ) · dst / zoom in normalized coordinates. The shader turns a map value into half that in
    /// normalized units (its TODO about the extra × 0.5), so the map holds twice the offset.
    static func zoomRotate(id: UInt64, zoom: Double, degrees: Double) -> WarpField {
        let n = GPUWarp.warpMapSize
        let angle = degrees * .pi / 180, c = cos(angle), s = sin(angle)
        var dxy = [Float](repeating: 0, count: n * n * 2)
        for j in 0..<n {
            for i in 0..<n {
                let x = Double(i) / 256 - 1, y = Double(j) / 256 - 1
                let sx = (c * x - s * y) / zoom, sy = (s * x + c * y) / zoom
                dxy[(j * n + i) * 2] = Float(2 * (sx - x))
                dxy[(j * n + i) * 2 + 1] = Float(2 * (sy - y))
            }
        }
        return WarpField(id: id, size: n, dxy: dxy)
    }

    /// Black → red → orange → yellow → white; in HDR the top quarter climbs to 3× SDR white.
    static func firePalette(hdr: Bool) -> [Float] {
        (0..<256).flatMap { i -> [Float] in
            let t = Double(i) / 255
            let r = min(1, t * 3), g = min(1, max(0, t * 3 - 1)), b = min(1, max(0, t * 3 - 2))
            let boost = hdr ? 1 + 2 * pow(t, 4) : 1
            return [Float(r * boost), Float(g * boost), Float(b * boost), 1]
        }
    }
}
