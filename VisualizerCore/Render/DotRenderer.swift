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
//  Changed for oldTunes, 2026: the DotRenderer class of dot_renderer.js (Geiss HDR v335), ported
//  from JavaScript and WebGPU to Swift and Metal.

import Metal

/// dot_renderer.js: the engine's dots (waveform, beat dots, chasers), one instanced quad each, added
/// into the red channel of the new frame (the high byte of the 16-bit index), so a dot brightens the
/// palette entry and never touches the low byte.
///
/// Each instance is (x, y, size_px, alpha) in pixel-centre coordinates. The original rewrites one
/// GPU buffer with `queue.writeBuffer` every step; here each of the three frames that can be in
/// flight has its own buffer, and every step in a frame takes the next part of it, so the CPU never
/// writes where the GPU may still be reading.
@MainActor
final class DotRenderer {
    /// gpu_warp.js: `this.dots.init(32768)`.
    nonisolated static let maxPoints = 32_768
    nonisolated static let frameSlots = 3

    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private let cornerBuffer: MTLBuffer
    private var instanceBuffers: [MTLBuffer?] = Array(repeating: nil, count: DotRenderer.frameSlots)
    private var usedBytes = [Int](repeating: 0, count: DotRenderer.frameSlots)

    /// Dots drawn by the last call.
    private(set) var lastCount = 0
    /// Dots past `maxPoints`, summed over every call.
    private(set) var droppedPoints = 0

    init(device: MTLDevice, library: MTLLibrary, targetFormat: MTLPixelFormat = .rgba8Unorm) throws {
        self.device = device

        // Corner buffer: 4 vertices for triangle strip quad.
        let corners: [Float] = [-1, -1, +1, -1, -1, +1, +1, +1]
        guard let cornerBuffer = device.makeBuffer(bytes: corners, length: corners.count * 4, options: .storageModeShared) else {
            throw MetalRendererError.allocation("dot corner buffer")
        }
        cornerBuffer.label = "visualizer dot corners"
        self.cornerBuffer = cornerBuffer

        let vertices = MTLVertexDescriptor()
        vertices.attributes[0].format = .float2
        vertices.attributes[0].offset = 0
        vertices.attributes[0].bufferIndex = 0
        vertices.attributes[1].format = .float4
        vertices.attributes[1].offset = 0
        vertices.attributes[1].bufferIndex = 1
        vertices.layouts[0].stride = 8
        vertices.layouts[0].stepFunction = .perVertex
        vertices.layouts[1].stride = 16
        vertices.layouts[1].stepFunction = .perInstance
        vertices.layouts[1].stepRate = 1

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "visualizer dots"
        descriptor.vertexFunction = try Shaders.function(Shaders.dotsVertex, in: library)
        descriptor.fragmentFunction = try Shaders.function(Shaders.dotsFragment, in: library)
        descriptor.vertexDescriptor = vertices
        let target = descriptor.colorAttachments[0]!
        target.pixelFormat = targetFormat
        target.isBlendingEnabled = true
        target.rgbBlendOperation = .add
        target.sourceRGBBlendFactor = .one
        target.destinationRGBBlendFactor = .one
        target.alphaBlendOperation = .add
        target.sourceAlphaBlendFactor = .one
        target.destinationAlphaBlendFactor = .one
        // Only accumulate into RED.
        target.writeMask = .red
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// Starts a frame's use of its slot's buffer. The caller holds the slot: the frame that last used
    /// it has finished on the GPU.
    func beginFrame(slot: Int) {
        usedBytes[slot % Self.frameSlots] = 0
    }

    /// `upload_points(points_f32)` and `draw(encoder, target_view)`, into an encoder whose target is
    /// the `width × height` frame. Returns how many dots it drew.
    @discardableResult
    func draw(points: [Float], into encoder: MTLRenderCommandEncoder, width: Int, height: Int, slot: Int) -> Int {
        let available = points.count / 4
        let count = min(available, Self.maxPoints)
        droppedPoints += available - count
        lastCount = count
        guard count > 0 else { return 0 }

        let slot = slot % Self.frameSlots
        let bytes = count * 16
        var buffer = instanceBuffers[slot]
        if buffer == nil || usedBytes[slot] + bytes > buffer!.length {
            // A new, larger buffer for the rest of this frame. Steps already encoded keep the old one:
            // their command buffer holds on to it until the GPU is done.
            let length = max(Self.maxPoints * 16, bytes, (buffer?.length ?? 0) * 2)
            buffer = device.makeBuffer(length: length, options: .storageModeShared)
            buffer?.label = "visualizer dots \(slot)"
            instanceBuffers[slot] = buffer
            usedBytes[slot] = 0
        }
        guard let buffer else { return 0 }
        let offset = usedBytes[slot]
        points.withUnsafeBytes { raw in
            if let base = raw.baseAddress { (buffer.contents() + offset).copyMemory(from: base, byteCount: bytes) }
        }
        usedBytes[slot] = offset + bytes

        // width, height, pad, pad
        var uniforms = SIMD4<Float>(Float(width), Float(height), 0, 0)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(cornerBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(buffer, offset: offset, index: 1)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.size, index: 2)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
        return count
    }
}
