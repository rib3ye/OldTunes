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
//  Changed for oldTunes, 2026: the GPUWarp class of gpu_warp.js and noise_textures.js
//  (Geiss HDR v335), ported from JavaScript and WebGPU to Swift and Metal.

import Accelerate
import Metal

/// The feedback loop on the GPU (gpu_warp.js): each step warps the old frame into the new one, then
/// draws the dots on top.
///
/// The frame is a 16-bit index into the palette, held in two `rgba8Unorm` textures that take turns
/// (ping-pong): R is the high byte, which picks the palette entry, and G the low byte, which blends
/// towards the next one. Four 512² `rg16Float` warp maps say where each pixel comes from; four 256²
/// noise textures and an auto-exposure pass make the image fade.
///
/// WebGPU's `queue.writeTexture` happens in queue order. To keep that order, every upload here goes
/// through a staging buffer and a blit on the same command queue, and a warp map waits for the next
/// step's command buffer. Textures are private (`.private` also works on Intel Macs, where textures
/// can't be shared), and readbacks for the bench go through a blit too.
@MainActor
public final class GPUWarp {
    /// const.js: `kWarpMapSize`, `kNoiseTexSize`, `kNoiseTexCount`, `kMaxActiveWarps`.
    nonisolated public static let warpMapSize = 512
    nonisolated public static let noiseTextureSize = 256
    nonisolated public static let noiseTextureCount = 4
    nonisolated public static let maxActiveWarps = 4

    public let device: MTLDevice
    /// Feedback-buffer size in pixels (the original's `W` and `H`).
    public private(set) var width: Int
    public private(set) var height: Int

    /// Where the per-step noise offsets, the noise textures and the start-up noise come from:
    /// `Math.random` in the original. A number in [0, 1).
    public var random: () -> Double

    /// `frame_index`: picks this step's noise texture. The bench sets it.
    public var frameIndex = 0
    /// The noise offsets of the last `setParams`, for the bench's reference.
    public private(set) var lastNoiseOffset = SIMD2<Float>(0, 0)
    /// Dots drawn by the last step, after the 32,768 cap.
    public var lastDotCount: Int { dots.lastCount }
    /// Dots past the cap, summed over every step: the original logs a warning each time.
    public var droppedDots: Int { dots.droppedPoints }

    private let queue: MTLCommandQueue
    private var indexTextures: [MTLTexture]
    private var ping = 0  // old = ping, new = ping ^ 1
    private let warpTextures: [MTLTexture]
    private var warpFieldIDs: [UInt64?] = Array(repeating: nil, count: GPUWarp.maxActiveWarps)
    /// Converted warp maps waiting for the next step's command buffer, by slot.
    private var pendingWarpUploads: [Int: MTLBuffer] = [:]
    private let noiseTextures: [MTLTexture]
    private let exposureBuffer: MTLBuffer
    private let warpPipeline: MTLRenderPipelineState
    private let exposurePipeline: MTLComputePipelineState
    let dots: DotRenderer
    private var uniforms: WarpUniforms

    init(device: MTLDevice, queue: MTLCommandQueue, library: MTLLibrary, width: Int, height: Int,
         random: @escaping () -> Double) throws {
        let w = max(1, width), h = max(1, height)
        self.device = device
        self.queue = queue
        self.width = w
        self.height = h
        self.random = random
        uniforms = WarpUniforms(width: w, height: h)

        indexTextures = try (0..<2).map { _ in try Self.makeIndexTexture(device, w, h) }
        warpTextures = try (0..<Self.maxActiveWarps).map { slot in
            try Self.makeTexture(device, .rg16Float, Self.warpMapSize, Self.warpMapSize, [.shaderRead], "warp map \(slot)")
        }
        noiseTextures = try (0..<Self.noiseTextureCount).map { i in
            try Self.makeTexture(device, .r8Unorm, Self.noiseTextureSize, Self.noiseTextureSize, [.shaderRead], "noise \(i)")
        }
        // 16 bytes (4 floats) to keep it aligned and match ExposureOut. Shared, so the bench can read it.
        guard let exposure = device.makeBuffer(length: 16, options: .storageModeShared) else {
            throw MetalRendererError.allocation("exposure buffer")
        }
        exposure.label = "visualizer exposure"
        exposure.contents().storeBytes(of: SIMD4<Float>(0.997, 0, 0, 0), as: SIMD4<Float>.self)
        exposureBuffer = exposure

        let pipeline = MTLRenderPipelineDescriptor()
        pipeline.label = "visualizer warp"
        pipeline.vertexFunction = try Shaders.function(Shaders.warpVertex, in: library)
        pipeline.fragmentFunction = try Shaders.function(Shaders.warpFragment, in: library)
        pipeline.colorAttachments[0].pixelFormat = .rgba8Unorm
        warpPipeline = try device.makeRenderPipelineState(descriptor: pipeline)
        exposurePipeline = try device.makeComputePipelineState(function: try Shaders.function(Shaders.exposureKernel, in: library))
        dots = try DotRenderer(device: device, library: library)

        // WebGPU zero-fills new textures; Metal leaves private ones undefined. Zero warp maps mean no
        // motion until the engine sends real ones.
        try upload(Data(count: Self.warpMapSize * Self.warpMapSize * 4 * Self.maxActiveWarps),
                   bytesPerRow: Self.warpMapSize * 4, to: warpTextures, label: "zero warp maps")
        try fillNoiseTextures()
        try fillIndexWithNoise()
    }

    // MARK: - gpu_warp.js

    /// `resize(iw, ih)`: new ping-pong textures at the new size, filled with fresh noise. The warp maps
    /// stay as they are.
    func resize(width newWidth: Int, height newHeight: Int) throws {
        let w = max(1, newWidth), h = max(1, newHeight)
        if w == width, h == height { return }
        // Make the new textures first, so a failure leaves the old size and frame working.
        let textures = try (0..<2).map { _ in try Self.makeIndexTexture(device, w, h) }
        width = w
        height = h
        ping = 0
        indexTextures = textures
        try fillIndexWithNoise()
    }

    /// `fill_index_u8_with_noise`: a dim random start, high byte 0…39.
    func fillIndexWithNoise() throws {
        let count = width * height
        var bytes = [UInt8](repeating: 0, count: count * 4)
        for i in 0..<count {
            bytes[i * 4] = UInt8(clamping: Self.truncatedInt(random() * 40))  // R = hi byte
            bytes[i * 4 + 3] = 255                                           // A
        }
        try uploadToBothIndexTextures(bytes)
    }

    /// `upload_warp_map(slot, warp_f32_xy)`: uploads only when the slot holds a different map, as the
    /// original compares the Float32Array it was given last. The Float16 conversion is vImage's,
    /// which rounds to nearest even like Chrome's Float16Array, and runs on Intel Macs too.
    public func uploadWarpMap(slot: Int, field: WarpField) {
        guard (0..<Self.maxActiveWarps).contains(slot), warpFieldIDs[slot] != field.id else { return }
        // The textures are kWarpMapSize², as motion.js forces every map to be.
        guard field.size == Self.warpMapSize,
              let staging = device.makeBuffer(length: field.dxy.count * 2, options: .storageModeShared) else { return }
        staging.label = "visualizer warp map upload"
        let ok = field.dxy.withUnsafeBufferPointer { src -> Bool in
            guard let base = src.baseAddress else { return false }
            let rowFloats = field.size * 2
            var from = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: base), height: vImagePixelCount(field.size),
                                     width: vImagePixelCount(rowFloats), rowBytes: rowFloats * 4)
            var to = vImage_Buffer(data: staging.contents(), height: vImagePixelCount(field.size),
                                   width: vImagePixelCount(rowFloats), rowBytes: rowFloats * 2)
            return vImageConvert_PlanarFtoPlanar16F(&from, &to, vImage_Flags(kvImageNoFlags)) == kvImageNoError
        }
        guard ok else { return }
        warpFieldIDs[slot] = field.id
        pendingWarpUploads[slot] = staging
    }

    /// `set_params({w0…w3, shift_x, shift_y, darkening, time})`: this step's uniforms. The noise
    /// offsets are new random numbers every step.
    public func setParams(weights: SIMD4<Float>, shift: SIMD2<Float>, darkening: Float, time: Float) {
        let noiseX = Float(Self.truncatedInt(random() * Double(Self.noiseTextureSize - 1)))
        let noiseY = Float(Self.truncatedInt(random() * Double(Self.noiseTextureSize - 1)))
        uniforms = WarpUniforms(width: width, height: height)
        uniforms.w0 = weights[0]
        uniforms.w1 = weights[1]
        uniforms.w2 = weights[2]
        uniforms.w3 = weights[3]
        uniforms.shiftX = shift.x
        uniforms.shiftY = shift.y
        uniforms.noiseOffsetX = noiseX
        uniforms.noiseOffsetY = noiseY
        uniforms.darkening = darkening
        uniforms.time = time
        lastNoiseOffset = SIMD2(noiseX, noiseY)
    }

    /// `step(waveform)`: auto-exposure from the old frame, the warp of old into new, then the dots
    /// into the new frame, and swap. `points` is (x, y, size_px, alpha) per dot in pixel-centre
    /// coordinates. The warp and the dots share one render pass: same target, drawn in order, which
    /// on Apple GPUs saves storing and reloading the frame between them.
    func step(points: [Float], commandBuffer: MTLCommandBuffer, dotSlot: Int) {
        flushWarpUploads(commandBuffer)
        let oldIndex = ping, newIndex = ping ^ 1

        // Autoexposure compute pass (old -> exposure buffer)
        if let compute = commandBuffer.makeComputeCommandEncoder() {
            compute.label = "visualizer auto-exposure"
            compute.setComputePipelineState(exposurePipeline)
            compute.setTexture(indexTextures[oldIndex], index: 0)
            compute.setBytes(&uniforms, length: MemoryLayout<WarpUniforms>.size, index: 0)
            compute.setBuffer(exposureBuffer, offset: 0, index: 1)
            compute.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
            compute.endEncoding()
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = indexTextures[newIndex]
        // The warp's full-screen triangle writes every pixel, so the old contents needn't be loaded.
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "visualizer warp and dots"

        // get_noise_index_for_frame: kNoiseTexCount is a power of two.
        let noiseIndex = frameIndex & (Self.noiseTextureCount - 1)
        frameIndex += 1

        encoder.setRenderPipelineState(warpPipeline)
        encoder.setFragmentTexture(indexTextures[oldIndex], index: 0)
        for (slot, texture) in warpTextures.enumerated() { encoder.setFragmentTexture(texture, index: 1 + slot) }
        encoder.setFragmentTexture(noiseTextures[noiseIndex], index: 5)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WarpUniforms>.size, index: 0)
        encoder.setFragmentBuffer(exposureBuffer, offset: 0, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // Dots: draw into the warped buffer (new)
        dots.draw(points: points, into: encoder, width: width, height: height, slot: dotSlot)
        encoder.endEncoding()

        // Swap
        ping = newIndex
    }

    /// `get_current_index_texture()`: the latest frame, for presenting.
    var currentIndexTexture: MTLTexture { indexTextures[ping] }

    private func flushWarpUploads(_ commandBuffer: MTLCommandBuffer) {
        guard !pendingWarpUploads.isEmpty, let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.label = "visualizer warp map upload"
        for (slot, staging) in pendingWarpUploads.sorted(by: { $0.key < $1.key }) {
            Self.copy(staging, bytesPerRow: Self.warpMapSize * 4, to: warpTextures[slot], blit)
        }
        blit.endEncoding()
        pendingWarpUploads.removeAll()
    }

    // MARK: - noise_textures.js

    /// `create_noise_textures`: each byte the average of three random numbers, so the noise is
    /// roughly Gaussian and centred on 128.
    private func fillNoiseTextures() throws {
        let size = Self.noiseTextureSize
        let bytesPerTexture = size * size
        var all = Data(count: bytesPerTexture * Self.noiseTextureCount)
        all.withUnsafeMutableBytes { raw in
            for i in 0..<raw.count {
                let t = (random() + random() + random()) * (1.0 / 3.0)
                raw[i] = UInt8(clamping: Self.truncatedInt(t * 255 + 0.5))
            }
        }
        try upload(all, bytesPerRow: size, to: noiseTextures, label: "noise")
    }

    // MARK: - Bench access

    /// Puts `values` (row-major, `width × height`) in both ping-pong textures: R = high byte, G = low.
    public func replaceIndex(_ values: [UInt16]) throws {
        let count = width * height
        var bytes = [UInt8](repeating: 0, count: count * 4)
        for i in 0..<min(count, values.count) {
            bytes[i * 4] = UInt8(values[i] >> 8)
            bytes[i * 4 + 1] = UInt8(values[i] & 0xFF)
            bytes[i * 4 + 3] = 255
        }
        try uploadToBothIndexTextures(bytes)
    }

    /// Replaces the four noise textures with `textures` (256² bytes each).
    public func replaceNoise(_ textures: [[UInt8]]) throws {
        let bytesPerTexture = Self.noiseTextureSize * Self.noiseTextureSize
        var all = Data(count: bytesPerTexture * Self.noiseTextureCount)
        for (i, texture) in textures.prefix(Self.noiseTextureCount).enumerated() {
            all.replaceSubrange(i * bytesPerTexture ..< i * bytesPerTexture + min(texture.count, bytesPerTexture),
                                with: texture.prefix(bytesPerTexture))
        }
        try upload(all, bytesPerRow: Self.noiseTextureSize, to: noiseTextures, label: "bench noise")
    }

    /// Draws `points` on the latest frame with no warp before them, and waits. Call it with no frames
    /// in flight: it borrows frame slot 0's dot buffer.
    public func drawDotsForTesting(_ points: [Float]) throws {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = currentIndexTexture
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw MetalRendererError.allocation("dots pass")
        }
        commandBuffer.label = "visualizer bench dots"
        dots.beginFrame(slot: 0)
        dots.draw(points: points, into: encoder, width: width, height: height, slot: 0)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    /// The latest frame's raw RGBA bytes, after every command buffer committed so far.
    public func readIndexBytes() throws -> [UInt8] {
        try read(currentIndexTexture, bytesPerPixel: 4)
    }

    /// The latest frame as 16-bit values.
    public func readIndex() throws -> [UInt16] {
        let bytes = try readIndexBytes()
        return (0..<width * height).map { UInt16(bytes[$0 * 4]) << 8 | UInt16(bytes[$0 * 4 + 1]) }
    }

    /// One slot's warp map as Float16 bit patterns, (dx, dy) interleaved.
    public func readWarpMapBits(slot: Int) throws -> [UInt16] {
        let bytes = try read(warpTextures[slot], bytesPerPixel: 4)
        return stride(from: 0, to: bytes.count, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 }
    }

    /// The decay the last step's auto-exposure worked out.
    public func readExposureDecay() -> Float {
        exposureBuffer.contents().load(as: Float.self)
    }

    // MARK: - Helpers

    /// JavaScript's `x | 0` for the values used here: NaN and infinities become 0.
    private static func truncatedInt(_ x: Double) -> Int {
        guard x.isFinite, abs(x) < 2_147_483_648 else { return 0 }
        return Int(x)
    }

    private static func makeIndexTexture(_ device: MTLDevice, _ width: Int, _ height: Int) throws -> MTLTexture {
        try makeTexture(device, .rgba8Unorm, width, height, [.shaderRead, .renderTarget], "index")
    }

    private static func makeTexture(_ device: MTLDevice, _ format: MTLPixelFormat, _ width: Int, _ height: Int,
                                    _ usage: MTLTextureUsage, _ label: String) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = usage
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw MetalRendererError.allocation("\(label) texture (\(width)×\(height))")
        }
        texture.label = "visualizer \(label)"
        return texture
    }

    private static func copy(_ buffer: MTLBuffer, offset: Int = 0, bytesPerRow: Int, to texture: MTLTexture,
                             _ blit: MTLBlitCommandEncoder) {
        blit.copy(from: buffer, sourceOffset: offset, sourceBytesPerRow: bytesPerRow,
                  sourceBytesPerImage: bytesPerRow * texture.height,
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                  to: texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
    }

    private func uploadToBothIndexTextures(_ bytes: [UInt8]) throws {
        try upload(Data(bytes) + Data(bytes), bytesPerRow: width * 4, to: indexTextures, label: "index")
    }

    /// Copies `data`, one equal part per texture, through a staging buffer, in its own command buffer
    /// on the shared queue, so it lands before any later step.
    func upload(_ data: Data, bytesPerRow: Int, to textures: [MTLTexture], label: String) throws {
        let part = data.count / max(1, textures.count)
        guard textures.allSatisfy({ bytesPerRow * $0.height <= part }) else { throw MetalRendererError.uploadSize(label) }
        guard let staging = data.withUnsafeBytes({ raw in
                  raw.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: raw.count, options: .storageModeShared) }
              }),
              let commandBuffer = queue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw MetalRendererError.allocation("\(label) upload")
        }
        commandBuffer.label = "visualizer \(label) upload"
        for (i, texture) in textures.enumerated() {
            Self.copy(staging, offset: i * part, bytesPerRow: bytesPerRow, to: texture, blit)
        }
        blit.endEncoding()
        commandBuffer.commit()
    }

    /// Reads a texture back after everything committed so far.
    private func read(_ texture: MTLTexture, bytesPerPixel: Int) throws -> [UInt8] {
        let bytesPerRow = texture.width * bytesPerPixel
        let length = bytesPerRow * texture.height
        guard let buffer = device.makeBuffer(length: length, options: .storageModeShared),
              let commandBuffer = queue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw MetalRendererError.allocation("readback")
        }
        commandBuffer.label = "visualizer readback"
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: bytesPerRow,
                  destinationBytesPerImage: length)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return [UInt8](UnsafeRawBufferPointer(start: buffer.contents(), count: length))
    }
}

/// gpu_warp.js's `WarpUniforms`, field for field: 20 floats, 80 bytes, passed with `setBytes`.
struct WarpUniforms {
    var w0: Float = 1
    var w1: Float = 0
    var w2: Float = 0
    var w3: Float = 0
    var shiftX: Float = 0
    var shiftY: Float = 0
    var warpWidth: Float
    var warpHeight: Float
    var indexWidth: Float
    var indexHeight: Float
    var indexWidthInv: Float
    var indexHeightInv: Float
    var x0x1: Float
    var y0y1: Float
    var invX0x1: Float
    var invY0y1: Float
    var noiseOffsetX: Float = 0
    var noiseOffsetY: Float = 0
    var darkening: Float = 0
    var time: Float = 0

    /// The size-dependent fields, worked out in Double and stored as Float, as the original's
    /// Float32Array does. x0x1 and y0y1 are coords.js's TransformHelper: the window fitted inside the
    /// [-1, 1] square, so the shorter side spans less than 2.
    init(width: Int, height: Int) {
        let w = Double(width), h = Double(height)
        let aspect = w / h
        var x0 = -1.0, x1 = 1.0, y0 = -1.0, y1 = 1.0
        if aspect > 1 {
            y0 /= aspect
            y1 /= aspect
        } else {
            x0 *= aspect
            x1 *= aspect
        }
        warpWidth = Float(GPUWarp.warpMapSize)
        warpHeight = Float(GPUWarp.warpMapSize)
        indexWidth = Float(w)
        indexHeight = Float(h)
        indexWidthInv = Float(1 / w)
        indexHeightInv = Float(1 / h)
        x0x1 = Float(x1 - x0)
        y0y1 = Float(y1 - y0)
        invX0x1 = Float(1 / (x1 - x0))
        invY0y1 = Float(1 / (y1 - y0))
    }
}
