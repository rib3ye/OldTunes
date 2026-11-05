//  Geiss HDR
//  Copyright (c) 2026 Ryan Geiss
//  www.geisswerks.com/geiss_hdr
//
//  License: Apache-2.0 - see VisualizerCore/LICENSE.txt
//
//  Attribution Notice: see VisualizerCore/NOTICE.txt
//    Derivative works and redistributions must retain this NOTICE file.
//
//  Naming / Branding Notice: see VisualizerCore/NOTICE.txt
//    "Geiss" and "Geiss HDR" are reserved names for the original Geiss HDR project.
//    The Apache-2.0 license does not grant permission to use those names, or
//    confusingly similar names, for derivative works except as needed to describe
//    the origin of the work or reproduce the content of the NOTICE file.
//
//  Output permissions (for still images and still image sequences generated
//    using this software): see VisualizerCore/OUTPUTS.txt
//
//  Changed for oldTunes, 2026: the WebGPUPresenter class of webgpu_present.js (Geiss HDR v335),
//  ported from JavaScript and WebGPU to Swift and Metal, with frames batched and paced for a
//  CAMetalLayer.

import AppKit
import Metal
import QuartzCore
import os

/// webgpu_present.js: owns the GPU warp, turns the 16-bit index frame into colour through the
/// palette, and shows it in a `CAMetalLayer`.
///
/// **Frames.** The engine calls `warpAndDrawWaveform` once per step, and the render loop calls
/// `draw()` once per screen refresh: on a 60 Hz screen that is two steps, then one draw. Everything
/// from a frame's first step to its draw goes in one command buffer. At most three frames are in
/// flight on the GPU; when a fourth would start, the presenter drops that frame's steps and draw
/// instead of waiting, so the main thread never blocks on the GPU. `draw()` gets its drawable from
/// the layer, which can wait for the compositor; `draw(to:)` takes one a `CAMetalDisplayLink` hands out.
///
/// **Size.** Chrome sizes the original's canvas to the window in CSS pixels (`canvas.width =
/// innerWidth`) and scales it up with crisp pixels. Here `resize(width:height:)` takes the view's size
/// in points, the drawable gets one pixel per point, and the layer magnifies it nearest-neighbour.
/// The feedback buffer is that size times `oversample`, which q and Q change in main.js.
///
/// **HDR.** `attach(_:hdr:)` sets the layer up the way the original sets up its canvas:
/// HDR is `rgba16Float` in extended sRGB with EDR on (Chrome's `toneMapping: "extended"`), SDR is
/// `bgra8Unorm` in sRGB. In SDR the driver remaps the palette before uploading it, as main.js does.
@MainActor
public final class Presenter: WarpRendering {
    nonisolated public static let maxFramesInFlight = 3

    public let device: MTLDevice
    /// The original's `presenter.gpu_warp`.
    public let gpuWarp: GPUWarp
    public private(set) var layer: CAMetalLayer?
    public private(set) var usesHDR = false
    /// cw × ch: the view in points, which is also the drawable in pixels.
    public private(set) var presentWidth: Int
    public private(set) var presentHeight: Int
    public private(set) var oversample: Double
    /// How long the shaders took to compile at start-up.
    public let shaderCompileSeconds: Double

    public var indexWidth: Int { gpuWarp.width }
    public var indexHeight: Int { gpuWarp.height }
    /// Frames committed and not yet finished by the GPU.
    public var framesInFlight: Int { book.inFlight }

    private let queue: MTLCommandQueue
    private let presentVertex: MTLFunction
    private let presentFragment: MTLFunction
    private var presentPipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    private let paletteOverlay: PaletteOverlay
    /// 256×1 `rgba8Unorm`, each channel √(min(1, v/3)) so the present shader can square it back.
    private let paletteTexture: MTLTexture
    /// One 1 KB part per frame slot: the CPU fills a part only while its frame holds that slot.
    private let paletteStaging: MTLBuffer
    private var palettePacked = [UInt8](repeating: 0, count: Presenter.paletteBytes)
    private var paletteChanged = true
    /// gpu_text_overlay.js isn't ported. The present shader still takes its texture, so it gets a
    /// blank one, and the overlay's intensity stays 0.
    private let titleTexture: MTLTexture
    private let book = FrameBook()
    private var frame = FrameState.idle
    /// Frames opened so far; picks each frame's slot in the per-frame buffers.
    private var frameSerial = 0
    private var lastCommitted: MTLCommandBuffer?
    private var gate: (event: MTLSharedEvent, value: UInt64)?

    private static let paletteBytes = 256 * 4

    private enum FrameState {
        case idle
        case open(commandBuffer: MTLCommandBuffer, slot: Int, steps: Int)
        case skipped
    }

    /// `random` stands in for the original's `Math.random` (noise textures, noise offsets, the
    /// starting frame); by default a fast generator seeded from the system's.
    public init(device: MTLDevice? = nil, width: Int = 1, height: Int = 1, oversample: Double = 1,
                random: (() -> Double)? = nil) throws {
        guard let device = device ?? MTLCreateSystemDefaultDevice() else { throw MetalRendererError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw MetalRendererError.allocation("command queue") }
        queue.label = "visualizer"
        self.device = device
        self.queue = queue
        let cw = max(1, width), ch = max(1, height), scale = oversample > 0 ? oversample : 1
        presentWidth = cw
        presentHeight = ch
        self.oversample = scale

        let compileStart = ContinuousClock.now
        let library = try Shaders.makeLibrary(device: device)
        let compileTime = ContinuousClock.now - compileStart
        shaderCompileSeconds = Double(compileTime.components.seconds) + Double(compileTime.components.attoseconds) * 1e-18
        presentVertex = try Shaders.function(Shaders.presentVertex, in: library)
        presentFragment = try Shaders.function(Shaders.presentFragment, in: library)
        paletteOverlay = try PaletteOverlay(device: device, library: library)

        // Palette texture (256x1 RGBA)
        let palette = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 256, height: 1, mipmapped: false)
        palette.usage = [.shaderRead]
        palette.storageMode = .private
        let title = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        title.usage = [.shaderRead]
        title.storageMode = .private
        guard let paletteTexture = device.makeTexture(descriptor: palette),
              let titleTexture = device.makeTexture(descriptor: title),
              let paletteStaging = device.makeBuffer(length: Self.paletteBytes * Self.maxFramesInFlight,
                                                     options: .storageModeShared) else {
            throw MetalRendererError.allocation("palette")
        }
        paletteTexture.label = "visualizer palette"
        titleTexture.label = "visualizer blank title"
        paletteStaging.label = "visualizer palette uploads"
        self.paletteTexture = paletteTexture
        self.titleTexture = titleTexture
        self.paletteStaging = paletteStaging

        gpuWarp = try GPUWarp(device: device, queue: queue, library: library,
                              width: Self.indexSize(cw, scale), height: Self.indexSize(ch, scale),
                              random: random ?? Self.seededRandom())
        try gpuWarp.upload(Data(count: 4), bytesPerRow: 4, to: [titleTexture], label: "blank title")
    }

    // MARK: - Showing frames

    /// True when `screen` can show values above SDR white.
    public static func screenSupportsHDR(_ screen: NSScreen?) -> Bool {
        (screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1
    }

    /// `configure_canvas(attempt_hdr)`: makes `layer` show this presenter's frames, in HDR or SDR.
    /// Pick HDR only where `screenSupportsHDR` says so.
    public func attach(_ layer: CAMetalLayer, hdr: Bool) {
        endOpenFrame()
        layer.device = device
        layer.framebufferOnly = true
        layer.isOpaque = true  // alphaMode: "opaque"
        layer.magnificationFilter = .nearest  // image-rendering: pixelated
        // While a CAMetalDisplayLink exists on the layer this setter throws (CAMetalLayerInvalidOperation),
        // even with the same value, and the exception corrupts Swift on its way out. So it is set only when
        // it differs: the first attach, before any link. The other settings may change under a link.
        if layer.maximumDrawableCount != Self.maxFramesInFlight {
            layer.maximumDrawableCount = Self.maxFramesInFlight
        }
        if hdr {
            layer.pixelFormat = .rgba16Float
            layer.colorspace = CGColorSpace(name: CGColorSpace.extendedSRGB)
            layer.wantsExtendedDynamicRangeContent = true
        } else {
            layer.pixelFormat = .bgra8Unorm
            layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            layer.wantsExtendedDynamicRangeContent = false
        }
        layer.drawableSize = CGSize(width: presentWidth, height: presentHeight)
        // Build the pipelines now rather than in the middle of a frame.
        _ = try? presentPipeline(for: layer.pixelFormat)
        _ = try? paletteOverlay.pipeline(for: layer.pixelFormat)
        self.layer = layer
        usesHDR = hdr
    }

    public func detach() {
        endOpenFrame()
        layer = nil
        usesHDR = false
    }

    /// `resize(cw, ch, iw, ih, oversample)`, with iw × ih worked out as main.js does:
    /// `max(1, floor(cw × oversample))`. A new size starts the frame over from noise.
    public func resize(width: Int, height: Int, oversample: Double = 1) {
        endOpenFrame()
        presentWidth = max(1, width)
        presentHeight = max(1, height)
        self.oversample = oversample > 0 ? oversample : 1
        // An allocation failure keeps the old frame; the next resize tries again.
        try? gpuWarp.resize(width: Self.indexSize(presentWidth, self.oversample),
                            height: Self.indexSize(presentHeight, self.oversample))
        layer?.drawableSize = CGSize(width: presentWidth, height: presentHeight)
    }

    /// `draw(palette_swatch_count)`: shows the latest frame through the palette, and ends the frame.
    /// `paletteSwatchCount` > 0 adds the debug swatches (draw_palette.js) in the lower-right corner.
    ///
    /// This asks the layer for a drawable, and `nextDrawable()` waits when none is free: a few
    /// milliseconds a frame in HDR, and up to a second while the window is covered. The wait is in
    /// `FrameStats.drawableWaitSeconds`. `draw(to:)` avoids it.
    public func draw(paletteSwatchCount: Int = 0) {
        guard let (commandBuffer, slot) = openFrame() else {
            frame = .idle
            return
        }
        encodePaletteUpload(commandBuffer, staging: paletteStaging, offset: slot * Self.paletteBytes)
        var drawable: CAMetalDrawable?
        if let layer {
            let size = CGSize(width: presentWidth, height: presentHeight)
            if layer.drawableSize != size { layer.drawableSize = size }
            let waitStart = CACurrentMediaTime()
            drawable = layer.nextDrawable()
            book.waitedForDrawable(CACurrentMediaTime() - waitStart)
        }
        finish(commandBuffer, drawable: drawable, swatches: paletteSwatchCount, wantedDrawable: layer != nil)
    }

    /// `draw()` into a drawable the caller already holds. A `CAMetalDisplayLink` hands one to each
    /// update when one is free, so the main thread never waits in `nextDrawable()`.
    public func draw(to drawable: CAMetalDrawable, paletteSwatchCount: Int = 0) {
        guard let (commandBuffer, slot) = openFrame() else {
            frame = .idle
            return
        }
        encodePaletteUpload(commandBuffer, staging: paletteStaging, offset: slot * Self.paletteBytes)
        finish(commandBuffer, drawable: drawable, swatches: paletteSwatchCount, wantedDrawable: true)
    }

    private func finish(_ commandBuffer: MTLCommandBuffer, drawable: CAMetalDrawable?, swatches: Int, wantedDrawable: Bool) {
        if let drawable {
            encodePresent(into: drawable.texture, format: drawable.texture.pixelFormat, commandBuffer, swatches: swatches)
            commandBuffer.present(drawable)
        }
        commit(commandBuffer, shown: drawable != nil, wantedDrawable: wantedDrawable)
    }

    // MARK: - WarpRendering

    public func setWarpMap(slot: Int, field: WarpField) {
        gpuWarp.uploadWarpMap(slot: slot, field: field)
    }

    /// `warpAndDrawWaveform(w0, w1, w2, w3, shift_x, shift_y, waveform, darkening, time)`.
    public func warpAndDrawWaveform(weights: SIMD4<Float>, shift: SIMD2<Float>, points: [Float],
                                    darkening: Float, time: Float) {
        guard let (commandBuffer, slot) = openFrame() else {
            book.stepSkipped()
            return
        }
        gpuWarp.setParams(weights: weights, shift: shift, darkening: darkening, time: time)
        gpuWarp.step(points: points, commandBuffer: commandBuffer, dotSlot: slot)
        if case .open(_, _, let steps) = frame { frame = .open(commandBuffer: commandBuffer, slot: slot, steps: steps + 1) }
    }

    /// `uploadPaletteRGBA8UNorm(palette_rgba_f32)`: 256 RGBA entries, 0…3 where 1 is SDR white, packed
    /// as √(min(1, v/3)) into bytes. It reaches the GPU with the next `draw()`. A missing or NaN entry
    /// packs as 0, as JavaScript's `NaN | 0` does.
    public func uploadPalette(_ rgba: [Float]) {
        // Leave headroom for HDR values > 1: map [0 .. kHeadroom] to [0..255].
        let kHeadroom = 3.0
        // Pack values in a cheap gamma-space so we get roughly as much detail in the highlights as in
        // the shadows.
        let kPower = 0.5
        for i in 0..<Self.paletteBytes {
            let x = i < rgba.count ? Double(rgba[i]) * (1.0 / kHeadroom) : .nan
            var v = x.isNaN ? x : max(0.0, min(1.0, x))
            v = pow(v, kPower)
            v *= 255
            // Round to nearest integer for slightly better quantization.
            let rounded = v + 0.5
            palettePacked[i] = rounded.isFinite ? UInt8(clamping: Int(rounded)) : 0
        }
        paletteChanged = true
    }

    // MARK: - Frames

    /// The frame in progress, opening one if none is. Nil when this frame is being skipped.
    private func openFrame() -> (MTLCommandBuffer, Int)? {
        switch frame {
        case .open(let commandBuffer, let slot, _):
            return (commandBuffer, slot)
        case .skipped:
            return nil
        case .idle:
            guard book.tryBegin(limit: Self.maxFramesInFlight) else {
                frame = .skipped
                return nil
            }
            guard let commandBuffer = queue.makeCommandBuffer() else {
                book.abandon()
                frame = .skipped
                return nil
            }
            commandBuffer.label = "visualizer frame"
            if let gate { commandBuffer.encodeWaitForEvent(gate.event, value: gate.value) }
            let slot = frameSerial % Self.maxFramesInFlight
            frameSerial += 1
            gpuWarp.dots.beginFrame(slot: slot)
            frame = .open(commandBuffer: commandBuffer, slot: slot, steps: 0)
            return (commandBuffer, slot)
        }
    }

    /// Commits whatever the frame in progress holds, without showing it: before anything that changes
    /// what later steps draw into.
    private func endOpenFrame() {
        if case .open(let commandBuffer, _, _) = frame {
            commit(commandBuffer, shown: false, wantedDrawable: false)
        }
        frame = .idle
    }

    private func commit(_ commandBuffer: MTLCommandBuffer, shown: Bool, wantedDrawable: Bool) {
        let steps: Int
        if case .open(_, _, let count) = frame { steps = count } else { steps = 0 }
        let book = self.book
        commandBuffer.addCompletedHandler { buffer in
            book.completed(seconds: buffer.gpuEndTime - buffer.gpuStartTime, steps: steps, failed: buffer.error != nil)
        }
        commandBuffer.commit()
        book.committed(steps: steps, shown: shown, missedDrawable: wantedDrawable && !shown)
        lastCommitted = commandBuffer
        frame = .idle
    }

    private func presentPipeline(for format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        if let pipeline = presentPipelines[format] { return pipeline }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "visualizer present"
        descriptor.vertexFunction = presentVertex
        descriptor.fragmentFunction = presentFragment
        descriptor.colorAttachments[0].pixelFormat = format
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        presentPipelines[format] = pipeline
        return pipeline
    }

    private func encodePaletteUpload(_ commandBuffer: MTLCommandBuffer, staging: MTLBuffer, offset: Int) {
        guard paletteChanged, let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.label = "visualizer palette upload"
        palettePacked.withUnsafeBytes { raw in
            if let base = raw.baseAddress { (staging.contents() + offset).copyMemory(from: base, byteCount: raw.count) }
        }
        blit.copy(from: staging, sourceOffset: offset, sourceBytesPerRow: Self.paletteBytes,
                  sourceBytesPerImage: Self.paletteBytes, sourceSize: MTLSize(width: 256, height: 1, depth: 1),
                  to: paletteTexture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
        blit.endEncoding()
        paletteChanged = false
    }

    private func encodePresent(into target: MTLTexture, format: MTLPixelFormat, _ commandBuffer: MTLCommandBuffer,
                               swatches: Int) {
        guard let pipeline = try? presentPipeline(for: format) else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "visualizer present"
        // updateGlobals(): oversample, 1/oversample, then the title rect (unused), then cw, ch.
        let uniforms: [Float] = [Float(oversample), Float(1.0 / oversample), 0, 0,
                                 0, 0, 0, 0,
                                 Float(presentWidth), Float(presentHeight), 0, 0]
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(gpuWarp.currentIndexTexture, index: 0)
        encoder.setFragmentTexture(paletteTexture, index: 1)
        encoder.setFragmentTexture(titleTexture, index: 2)
        encoder.setFragmentBytes(uniforms, length: uniforms.count * 4, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        if swatches > 0 {
            paletteOverlay.draw(into: encoder, format: format, palette: paletteTexture,
                                screenWidth: presentWidth, screenHeight: presentHeight, swatchCount: swatches,
                                rectWidth: swatches * 32, rectHeight: 32, marginX: 8, marginY: 8)
        }
        encoder.endEncoding()
    }

    // MARK: - Measuring and bench access

    /// What happened since the last call, including GPU times of finished frames.
    public func takeFrameStats() -> FrameStats { book.take() }

    /// Ends the frame in progress and waits until the GPU has finished every frame.
    public func waitUntilIdle() {
        endOpenFrame()
        lastCommitted?.waitUntilCompleted()
        // Completion handlers run just after; give them a moment.
        let deadline = ContinuousClock.now + .seconds(2)
        while book.inFlight > 0, ContinuousClock.now < deadline { usleep(500) }
    }

    /// Draws the present pass into `target` (its size should be `presentWidth × presentHeight`) and
    /// waits for it, outside the frame cycle. For the bench and for still pictures.
    public func presentForTesting(into target: MTLTexture, paletteSwatchCount: Int = 0) {
        endOpenFrame()
        guard let commandBuffer = queue.makeCommandBuffer(),
              let staging = device.makeBuffer(length: Self.paletteBytes, options: .storageModeShared) else { return }
        commandBuffer.label = "visualizer offscreen present"
        encodePaletteUpload(commandBuffer, staging: staging, offset: 0)
        encodePresent(into: target, format: target.pixelFormat, commandBuffer, swatches: paletteSwatchCount)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    /// Makes every frame from now on wait on the GPU for `event` to reach `value`, so frames stay in
    /// flight until the bench lets them go. Nil turns that off.
    public func holdFramesForTesting(until event: MTLSharedEvent?, value: UInt64 = 1) {
        gate = event.map { ($0, value) }
    }

    // MARK: - Helpers

    private static func indexSize(_ points: Int, _ oversample: Double) -> Int {
        let size = (Double(points) * oversample).rounded(.down)
        return size.isFinite ? max(1, Int(size)) : 1
    }

    /// SplitMix64, seeded from the system generator: fast enough for the start-up noise (four
    /// textures × 65,536 × 3 numbers).
    private static func seededRandom() -> () -> Double {
        var state = UInt64.random(in: .min ... .max)
        return {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Double(z >> 11) * (1.0 / 9_007_199_254_740_992.0)
        }
    }
}

/// What the presenter did since the last `takeFrameStats()`.
public struct FrameStats: Sendable {
    public struct GPUFrame: Sendable {
        /// Command buffer start to end on the GPU.
        public var seconds: Double
        public var steps: Int
    }

    /// Frames committed to the GPU, and of those the ones shown in the layer.
    public var framesCommitted = 0
    public var framesShown = 0
    /// Frames committed without being shown, because the layer had no drawable to give.
    public var framesMissingDrawable = 0
    /// Frames not drawn at all, because three were already in flight.
    public var framesSkipped = 0
    public var stepsEncoded = 0
    public var stepsSkipped = 0
    /// Frames and steps the GPU finished, and frames it reported an error for.
    public var framesCompleted = 0
    public var stepsCompleted = 0
    public var framesFailed = 0
    /// Main-thread time spent in `nextDrawable()`, summed and the longest single wait.
    public var drawableWaitSeconds = 0.0
    public var drawableWaitLongest = 0.0
    /// Each finished frame's GPU time, oldest first; at most `maxSamples`.
    public var gpuFrames: [GPUFrame] = []

    public static let maxSamples = 8192
}

/// Frames in flight and their GPU times. Metal's completion handlers write to it from their own
/// thread, so it sits behind a lock.
final class FrameBook: Sendable {
    private struct Ledger: Sendable {
        var inFlight = 0
        var stats = FrameStats()
    }

    private let ledger = OSAllocatedUnfairLock(initialState: Ledger())

    var inFlight: Int { ledger.withLock { $0.inFlight } }

    /// Takes a place for a new frame, if fewer than `limit` are in flight; counts a skip if not.
    func tryBegin(limit: Int) -> Bool {
        ledger.withLock { ledger in
            guard ledger.inFlight < limit else {
                ledger.stats.framesSkipped += 1
                return false
            }
            ledger.inFlight += 1
            return true
        }
    }

    /// Gives back a place taken by `tryBegin` for a frame that never reached the GPU.
    func abandon() {
        ledger.withLock { $0.inFlight -= 1 }
    }

    func stepSkipped() {
        ledger.withLock { $0.stats.stepsSkipped += 1 }
    }

    func waitedForDrawable(_ seconds: Double) {
        ledger.withLock { ledger in
            ledger.stats.drawableWaitSeconds += seconds
            ledger.stats.drawableWaitLongest = max(ledger.stats.drawableWaitLongest, seconds)
        }
    }

    func committed(steps: Int, shown: Bool, missedDrawable: Bool) {
        ledger.withLock { ledger in
            ledger.stats.framesCommitted += 1
            ledger.stats.stepsEncoded += steps
            if shown { ledger.stats.framesShown += 1 }
            if missedDrawable { ledger.stats.framesMissingDrawable += 1 }
        }
    }

    func completed(seconds: Double, steps: Int, failed: Bool) {
        ledger.withLock { ledger in
            ledger.inFlight -= 1
            ledger.stats.framesCompleted += 1
            ledger.stats.stepsCompleted += steps
            if failed { ledger.stats.framesFailed += 1 }
            if ledger.stats.gpuFrames.count < FrameStats.maxSamples {
                ledger.stats.gpuFrames.append(FrameStats.GPUFrame(seconds: seconds, steps: steps))
            }
        }
    }

    func take() -> FrameStats {
        ledger.withLock { ledger in
            let stats = ledger.stats
            ledger.stats = FrameStats()
            return stats
        }
    }
}
