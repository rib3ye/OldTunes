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
//  Changed for oldTunes, 2026: the PaletteOverlayPass class of draw_palette.js (Geiss HDR v335),
//  ported from JavaScript and WebGPU to Swift and Metal.

import Metal

/// draw_palette.js: the debug swatches. A row of the current palette's colours in the lower-right
/// corner, drawn inside the present pass after the frame (main.js shows it with the F8 debug view).
/// It reads the presenter's packed palette texture the same way the present shader does.
@MainActor
final class PaletteOverlay {
    private let device: MTLDevice
    private let vertexFunction: MTLFunction
    private let fragmentFunction: MTLFunction
    /// One pipeline per drawable format: HDR and SDR draw into different ones.
    private var pipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]

    init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        vertexFunction = try Shaders.function(Shaders.paletteVertex, in: library)
        fragmentFunction = try Shaders.function(Shaders.paletteFragment, in: library)
    }

    func pipeline(for format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        if let pipeline = pipelines[format] { return pipeline }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "visualizer palette swatches"
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        // No blending: the swatches are opaque.
        descriptor.colorAttachments[0].pixelFormat = format
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        pipelines[format] = pipeline
        return pipeline
    }

    /// `update_ui_uniforms(screen_w, screen_h, palette_swatch_count, rect_w, rect_h, margin_x,
    /// margin_y)` then `draw(render_pass_encoder)`, inside a pass that draws into `format`.
    func draw(into encoder: MTLRenderCommandEncoder, format: MTLPixelFormat, palette: MTLTexture,
              screenWidth: Int, screenHeight: Int, swatchCount: Int,
              rectWidth: Int, rectHeight: Int, marginX: Int = 8, marginY: Int = 8) {
        guard swatchCount > 0, let pipeline = try? pipeline(for: format) else { return }
        // 7 floats padded to 8 (32 bytes), as the original packs them.
        let uniforms: [Float] = [Float(screenWidth), Float(screenHeight), Float(rectWidth), Float(rectHeight),
                                 Float(marginX), Float(marginY), Float(swatchCount), 0]
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(uniforms, length: uniforms.count * 4, index: 0)
        encoder.setFragmentBytes(uniforms, length: uniforms.count * 4, index: 0)
        encoder.setFragmentTexture(palette, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)  // 6 verts, 1 instance
    }
}
