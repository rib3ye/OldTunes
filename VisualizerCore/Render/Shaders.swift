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
//  Changed for OldTunes, 2026: the WGSL shaders of gpu_warp.js, dot_renderer.js, webgpu_present.js
//  and draw_palette.js (Geiss HDR v335), translated to the Metal Shading Language.

import Metal

/// The visualizer's nine shader entry points, as Metal Shading Language source.
///
/// They are compiled when the app runs, the way the original compiles its WGSL strings, so building
/// OldTunes needs no Metal toolchain. Fast math is off: the warp rounds, wraps and decays 16-bit
/// values, and should do it the way the WGSL does.
///
/// The translation keeps the original's names, order and arithmetic, so a later Geiss HDR version can
/// be compared line by line. Where Metal and WebGPU differ, the code says so: WGSL saturates when it
/// turns a float into an int and clamps out-of-range texture loads, Metal leaves both undefined, so
/// the port clamps first. Experiments the original leaves commented out are not carried over.
enum Shaders {
    static let warpVertex = "warp_vs"
    static let warpFragment = "warp_fs"
    static let exposureKernel = "exposure_cs"
    static let dotsVertex = "dots_vs"
    static let dotsFragment = "dots_fs"
    static let presentVertex = "present_vs"
    static let presentFragment = "present_fs"
    static let paletteVertex = "palette_vs"
    static let paletteFragment = "palette_fs"

    static func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
        let options = MTLCompileOptions()
        if #available(macOS 15.0, *) {
            options.mathMode = .safe
            options.mathFloatingPointFunctions = .precise
        } else {
            options.fastMathEnabled = false
        }
        return try device.makeLibrary(source: source, options: options)
    }

    static func function(_ name: String, in library: MTLLibrary) throws -> MTLFunction {
        guard let function = library.makeFunction(name: name) else { throw MetalRendererError.missingFunction(name) }
        return function
    }

    static let source = """
#include <metal_stdlib>
using namespace metal;

// ====================================================================================================
// Shared helpers
// ====================================================================================================

// WGSL turns an out-of-range float into the nearest int; Metal leaves it undefined. Clamping first
// keeps a wild warp vector in range, and wrap_i32 then brings it onto the texture.
static int to_i32(float x) {
  return int(clamp(x, -2147483648.0f, 2147483520.0f));
}

// Decode packed u16 from RG of an rgba8unorm read. c.r and c.g are floats in [0..1].
static uint decode_u16_from_rg(float4 c) {
  // Round to nearest byte.
  uint hi = uint(clamp(floor(c.r * 255.0f + 0.5f), 0.0f, 255.0f));
  uint lo = uint(clamp(floor(c.g * 255.0f + 0.5f), 0.0f, 255.0f));
  return (hi << 8) | lo;
}

// A full-screen triangle; the warp and the present pass both draw one.
struct FullscreenVertexOut {
  float4 position [[position]];
};

// ====================================================================================================
// gpu_warp.js: kUniforms, kWarpWGSL (warp_vs, warp_fs) and kAutoExposureWGSL (exposure_cs)
// ====================================================================================================

struct WarpUniforms {
  // strengths for each warp map (kMaxActiveWarps)
  float w0;
  float w1;
  float w2;
  float w3;

  // Optional global shift in pixels (can leave 0)
  float shift_x;
  float shift_y;

  // dimensions (float for convenience)
  float warp_width;
  float warp_height;
  float index_width;
  float index_height;
  float index_width_inv;
  float index_height_inv;
  float x0x1;
  float y0y1;
  float inv_x0x1;
  float inv_y0y1;

  float noise_offset_x;
  float noise_offset_y;
  float darkening;  // [-1..1]
  float time;
};

struct ExposureOut {
  float decay;
  float _pad0;
  float _pad1;
  float _pad2;
};

vertex FullscreenVertexOut warp_vs(uint vid [[vertex_id]]) {
  const float2 pos[3] = { float2(-1.0f, -1.0f), float2(-1.0f, 3.0f), float2(3.0f, -1.0f) };
  FullscreenVertexOut out;
  out.position = float4(pos[vid], 0.0f, 1.0f);
  return out;
}

// Encode u16 (0..65535) into RG bytes in [0..1] for rgba8unorm output.
static float4 encode_rg_from_u16(uint v) {
  uint hi = (v >> 8) & 255u;
  uint lo =  v       & 255u;
  return float4(float(hi) * (1.0f / 255.0f),
                float(lo) * (1.0f / 255.0f),
                0.0f,
                1.0f);
}

// Wrap an integer into [0..n-1] (works for negative too).
static int wrap_i32(int x, int n) {
  // % keeps the sign of x, so fix negatives.
  int r = x % n;
  return (r < 0) ? r + n : r;
}

// Manual bilinear sampling from old_tex for packed-u16 scalar, with WRAP on all edges.
// Caller is responsible for biasing pixel coords by (+0.5, +0.5) before calling.
static float sample_old_u16_bilinear(texture2d<float, access::read> old_tex,
                                     constant WarpUniforms& u, float2 src_pos) {
  int w = int(u.index_width);
  int h = int(u.index_height);

  // Floor to get base texel (can be negative / outside).
  float x0f = floor(src_pos.x);
  float y0f = floor(src_pos.y);

  // Fraction within the cell [0..1).
  float fx = src_pos.x - x0f;
  float fy = src_pos.y - y0f;

  // Wrap base texel and its neighbor.
  int x0 = wrap_i32(to_i32(x0f), w);
  int y0 = wrap_i32(to_i32(y0f), h);
  int x1 = wrap_i32(x0 + 1, w);
  int y1 = wrap_i32(y0 + 1, h);

  float4 c00 = old_tex.read(uint2(x0, y0));
  float4 c01 = old_tex.read(uint2(x1, y0));
  float4 c10 = old_tex.read(uint2(x0, y1));
  float4 c11 = old_tex.read(uint2(x1, y1));

  float v00 = float(decode_u16_from_rg(c00));
  float v01 = float(decode_u16_from_rg(c01));
  float v10 = float(decode_u16_from_rg(c10));
  float v11 = float(decode_u16_from_rg(c11));

  // Bilinear lerp.
  float a0 = v00 + (v01 - v00) * fx;
  float a1 = v10 + (v11 - v10) * fx;
  return a0 + (a1 - a0) * fy;
}

// p.xy : the output coordinates in [0..index_width - 1, 0 .. index_height - 1], at pixel centres.
fragment float4 warp_fs(FullscreenVertexOut in                     [[stage_in]],
                        texture2d<float, access::read>   old_tex   [[texture(0)]],  // rgba8unorm
                        texture2d<float, access::sample> warp0     [[texture(1)]],  // rg16float
                        texture2d<float, access::sample> warp1     [[texture(2)]],
                        texture2d<float, access::sample> warp2     [[texture(3)]],
                        texture2d<float, access::sample> warp3     [[texture(4)]],
                        texture2d<float, access::read>   noise_tex [[texture(5)]],  // r8unorm
                        constant WarpUniforms&           u         [[buffer(0)]],
                        device const ExposureOut&        exposure  [[buffer(1)]]) {
  // The warp maps' filtering sampler (GPUWarp.init): bilinear, clamp to edge.
  constexpr sampler samp(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::nearest);
  float4 p = in.position;

  // Destination pixel coords in the index texture space (assume 1:1 for now).
  float dx = p.x;  // [0 .. u.index_width - 1]
  float dy = p.y;  // [0 .. u.index_height - 1]

  // UV in [0..1] for sampling warp maps with bilinear.
  // General conversion formula:  (screen [0..W]x[0..H] -> normalized [-1..1])
  //   fx [-1..1] = (dx * inv_W - 0.5) * x0x1
  //   fy [-1..1] = (dy * inv_H - 0.5) * y0y1
  float2 uv = float2(dx * (1.0f / (u.index_width - 1.0f)),
                     dy * (1.0f / (u.index_height - 1.0f)));  // [0..1]
  uv = (uv - 0.5f) * float2(u.x0x1, u.y0y1);  // -> Now in normalized coordinate space.
  uv = uv * 0.5f + 0.5f;                      // -> Now go back to [0..1] UV sampling space.
  uv += float2(0.5f / u.warp_width, 0.5f / u.warp_height);  // (Doesn't really matter)

  // Sample 4 warp maps (rg16float), bilinear.  (kMaxActiveWarps)
  float2 wv0 = warp0.sample(samp, uv, level(0.0f)).xy;
  float2 wv1 = warp1.sample(samp, uv, level(0.0f)).xy;
  float2 wv2 = warp2.sample(samp, uv, level(0.0f)).xy;
  float2 wv3 = warp3.sample(samp, uv, level(0.0f)).xy;

  // Combined warp vector.  (kMaxActiveWarps)
  float2 warp_vec =
      (wv0 * u.w0 +
       wv1 * u.w1 +
       wv2 * u.w2 +
       wv3 * u.w3);

  // General conversion formula:  (normalized [-1..1] -> screen [0..W]x[0..H])
  //   dx [0..W]  = (fx * inv_x0x1 * 0.5 + 0.5) * W
  //   dy [0..H]  = (fy * inv_y0y1 * 0.5 + 0.5) * H
  // (The original's TODO: this *0.5 should not be here; see the similar TODO in AdvectPoint().)
  warp_vec = warp_vec
       * float2(u.inv_x0x1 * 0.5f * u.index_width,
                u.inv_y0y1 * 0.5f * u.index_height);

  // Source position -- in pixel space.
  float2 src_pos =
      float2(dx, dy)
      + warp_vec
      + float2(u.shift_x, u.shift_y)
      - float2(0.5f, 0.5f);

  // Sample old image (packed u16) manually with bilinear.
  float v = sample_old_u16_bilinear(old_tex, u, src_pos);

  // Round to nearest u16 and write back packed into RG.
  float v_u = clamp(floor(v + 0.5f), 0.0f, 65535.0f);

  // Add noise.
  // Tiny unfiltered noise (read). Wrap by & (size-1) since size is 256.
  // p.xy are pixel coords in the output render target space.
  uint nx = (uint(p.x) + uint(u.noise_offset_x)) & (256u - 1u);
  uint ny = (uint(p.y) + uint(u.noise_offset_y)) & (256u - 1u);
  float n01 = noise_tex.read(uint2(nx, ny)).r;  // [0,1]
  float noise = n01 * 2.0f - 1.0f;               // [-1,1]

  // Sprinkle: pick a *tiny* scale.
  const float kNoiseStrength = 1.015f;
  v_u *= pow(kNoiseStrength, noise);

  float decay = exposure.decay;
  v_u *= decay;

  uint rounded = uint(max(0.0f, min(65535.0f, v_u + 0.5f)));

  return encode_rg_from_u16(rounded);
}

// Simple integer hash (good enough for sampling coords)
static uint hash_u32(uint x) {
  uint v = x;
  v ^= v >> 16u;
  v *= 0x7feb352du;
  v ^= v >> 15u;
  v *= 0x846ca68bu;
  v ^= v >> 16u;
  return v;
}

constant uint kWG = 256u;
constant uint kSamplesPerThread = 16u;  // 256*16 = 4096 samples total

kernel void exposure_cs(texture2d<float, access::read> old_tex      [[texture(0)]],
                        constant WarpUniforms&         u            [[buffer(0)]],
                        device ExposureOut&            out_exposure [[buffer(1)]],
                        uint                           tid          [[thread_position_in_threadgroup]]) {
  threadgroup float wg_sum[256];

  uint w = uint(u.index_width);
  uint h = uint(u.index_height);

  // Seed from tid + per-frame noise offsets (updated every step).
  uint sx_seed = uint(u.noise_offset_x);
  uint sy_seed = uint(u.noise_offset_y);
  uint seed = hash_u32(tid ^ (sx_seed * 1315423911u) ^ (sy_seed * 2654435761u));

  float sum = 0.0f;

  // Strided random samples
  for (uint i = 0u; i < kSamplesPerThread; i++) {
    seed = hash_u32(seed + 0x9e3779b9u);

    // Derive coords from seed
    uint x = (seed      ) % w;
    uint y = (seed >> 16) % h;

    float4 c = old_tex.read(uint2(x, y));
    float v_u16 = float(decode_u16_from_rg(c));
    sum += v_u16;
  }

  wg_sum[tid] = sum;
  threadgroup_barrier(mem_flags::mem_threadgroup);

  // Reduce within workgroup
  uint stride = 128u;
  while (stride > 0u) {
    if (tid < stride) {
      wg_sum[tid] += wg_sum[tid + stride];
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    stride >>= 1u;
  }

  // Thread 0 writes final average and converts to decay
  if (tid == 0u) {
    float total_samples = float(kWG * kSamplesPerThread);
    float avg_u16 = wg_sum[0] / total_samples;  // [0..65535]ish

    float avg8 = avg_u16 * (1.0f / 256.0f);  // [0..255]
    // Tune this first, to the decay you want when the image is already dark.
    const float base_decay = 0.997f;
    const float fast_decay = 0.990f;
    float exp_base = (u.darkening >= 0.0f) ? fast_decay : base_decay;
    float adj_base_decay = base_decay * pow(exp_base, u.darkening);

    float min_level_for_extra_decay = 30.0f * (1.0f - u.darkening);  // [0..255]
    // Lower divisor -> quicker decay to black *of very bright stuff* over time
    const float extra_decay_strength = 0.000075f;
    float prev_avg_clamped = max(avg8 - min_level_for_extra_decay, 0.0f);
    float decay = max(0.0f, adj_base_decay - (prev_avg_clamped * extra_decay_strength));

    out_exposure.decay = decay;
  }
}

// ====================================================================================================
// dot_renderer.js: kDotPassWGSL (dots_vs, dots_fs)
// ====================================================================================================

// If the point size is 1.0 or less, this just draws a plain white square for each "dot".
// If the point size is >= 3, an antialiased circle is drawn, circumscribed within a square quad.
// It expects (x, y, rad, alpha) per instance and draws the dots as RGB (1,0,0,alpha), additively.

struct DotUniforms {
  float width;
  float height;
  float _pad0;
  float _pad1;
};

// The radial distance over which the dots will fade from opaque to transparent,
// relative to the dot radius.  (Applies to 3x3 or larger dots only.)
// Range: [0..1]
// At 0, a crisp dot of the desired radius is drawn.
// At 1, a blurry dot of double that radius is drawn.
constant float kRadiusFade = 0.5f;

struct DotVertexIn {
  float2 corner_unit [[attribute(0)]];  // (-1,-1),(+1,-1),(-1,+1),(+1,+1)
  float4 inst        [[attribute(1)]];  // (center_x_pc, center_y_pc, size_px, alpha)
};

// The values are the same at all four corners; [[flat]] passes them on without interpolating.
struct DotVertexOut {
  float4 pos       [[position]];
  float  a         [[flat]];
  float  r1        [[flat]];  // inner radius
  float  r2        [[flat]];  // outer radius
  float2 center_pc [[flat]];
};

vertex DotVertexOut dots_vs(DotVertexIn in [[stage_in]], constant DotUniforms& u [[buffer(2)]]) {
  float2 center_pc = in.inst.xy;  // pixel-center coords (integer = pixel center)
  float size_px = max(in.inst.z, 1.0f);
  float a = in.inst.w;

  // size_px:  quad size:   half_extent_pc:   circle_r:
  // 1         1x1          0.5               4
  // 2         2x2          1                 4
  // 3         5x5          2.5               3
  // 4         6x6          3                 4
  // 5         7x7          3.5               5

  // A size of 1 means cover exactly one pixel: center_pc +/- 0.5 in pixel-center coords.
  float half_extent_pc = 0.5f * size_px;

  // Circle radius of the white part of the dot, for the fragment shader.
  // - If point size is 1x1: force very large so it fully covers the square.
  // - Otherwise use the circle with the same area as the NxN-pixel square dot.
  float r1 = 4.0f;
  float r2 = 5.0f;
  if (size_px >= 1.0001f) {
    // Find the exact circle radius that would have the exact same square area
    // as the NxN-pixel square dot.
    float square_area = size_px * size_px;
    float ideal_r = pow(square_area / 3.1415927f, 0.5f);

    r1 = ideal_r * (1.0f - kRadiusFade);
    r2 = ideal_r * (1.0f + kRadiusFade);
    // Make the square cover the whole antialiased edge.
    half_extent_pc = ceil(r2);
  }

  // Quad corners in pixel-center coords.
  float2 p_pc = center_pc + in.corner_unit * half_extent_pc;

  // Convert pixel-center coords -> pixel coords used for NDC mapping:
  // pixel center x corresponds to pixel coord x+0.5
  float2 p_px = p_pc + 0.5f;

  float ndc_x = (p_px.x / u.width) * 2.0f - 1.0f;
  float ndc_y = 1.0f - (p_px.y / u.height) * 2.0f;

  DotVertexOut out;
  out.pos = float4(ndc_x, ndc_y, 0.0f, 1.0f);
  out.a = a;
  out.r1 = r1;
  out.r2 = r2;
  out.center_pc = center_pc;
  return out;
}

fragment float4 dots_fs(DotVertexOut in [[stage_in]]) {
  // Fragment position in pixel-center coords (integer means pixel center)
  float2 pc = in.pos.xy - 0.5f;

  // Distance from dot center in pixel-center coords.
  float r = length(pc - in.center_pc);

  // 1 inside r1, 0 outside r2, fading in between.
  float coverage = 1.0f - (r - in.r1) / (in.r2 - in.r1 + 0.000001f);
  coverage = max(0.0f, min(1.0f, coverage));

  return float4(max(0.0f, min(1.0f, in.a)) * coverage, 0.0f, 0.0f, 1.0f);
}

// ====================================================================================================
// webgpu_present.js: shaderWGSL (present_vs, present_fs)
// ====================================================================================================

struct PresentUniforms {
  float4 oversample;  // .x = oversample, .y = 1.0/oversample

  float title_left_px;
  float title_top_px;
  float title_width_px;
  float title_height_px;

  float present_w;
  float present_h;
  float title_intensity;
  float _pad_title3;
};

vertex FullscreenVertexOut present_vs(uint vid [[vertex_id]]) {
  // Fullscreen triangle
  const float2 pos[3] = { float2(-1.0f, -1.0f), float2(-1.0f, 3.0f), float2(3.0f, -1.0f) };
  FullscreenVertexOut out;
  out.position = float4(pos[vid], 0.0f, 1.0f);
  return out;
}

// Returns [0..1]. The song-title overlay is not ported: Presenter binds a blank texture here and
// leaves title_intensity at 0.
static float overlay_title(float2 frag_px, constant PresentUniforms& u,
                           texture2d<float, access::sample> title_tex) {
  if (u.title_intensity <= 0.0f) {
    return 0.0f;
  }

  float left   = u.title_left_px * u.oversample.y;
  float top    = u.title_top_px * u.oversample.y;
  float right  = left + u.title_width_px * u.oversample.y;
  float bottom = top  + u.title_height_px * u.oversample.y;

  if (frag_px.x < left || frag_px.x >= right || frag_px.y < top || frag_px.y >= bottom) {
    return 0.0f;
  }

  float2 uv = float2(
    (frag_px.x - left) * (1.0f / max(u.title_width_px  * u.oversample.y, 1.0f)),
    (frag_px.y - top ) * (1.0f / max(u.title_height_px * u.oversample.y, 1.0f))
  );

  constexpr sampler title_samp(coord::normalized, address::clamp_to_edge, filter::linear);
  float a = title_tex.sample(title_samp, uv, level(0.0f)).a * u.title_intensity;
  return a;
}

fragment float4 present_fs(FullscreenVertexOut in                       [[stage_in]],
                           texture2d<float, access::read>   indexTex    [[texture(0)]],
                           texture2d<float, access::read>   paletteTex  [[texture(1)]],
                           texture2d<float, access::sample> title_tex   [[texture(2)]],
                           constant PresentUniforms&        u           [[buffer(0)]]) {
  float4 p = in.position;
  // p.xy is in pixel coordinates of the render target
  int x = int(p.x);
  int y = int(p.y);

  int sx = int(float(x) * u.oversample.x);
  int sy = int(float(y) * u.oversample.x);  // [sic] - scale is just one value.

  // Load packed RG from rgba8unorm. 16-bit index = R * 256 + G.
  // Red channel has the 8 MSBs, green channel has the 8 LSBs.

  // Oversampling-friendly version. WGSL's round() rounds halves to even, as rint() does.
  // WebGPU clamps an out-of-range textureLoad onto the texture; Metal leaves it undefined.
  uint sum = 0u;
  int ss = int(max(1.0f, rint(u.oversample.x)));
  int max_x = int(indexTex.get_width()) - 1;
  int max_y = int(indexTex.get_height()) - 1;
  for (int yy = 0; yy < ss; yy++) {
    for (int xx = 0; xx < ss; xx++) {
      uint2 c = uint2(clamp(sx + xx, 0, max_x), clamp(sy + yy, 0, max_y));
      sum += decode_u16_from_rg(indexTex.read(c));  // [0..65535]
    }
  }

  uint avg = uint(float(sum) * (1.0f / float(ss * ss)));  // [0..65535]

  // Add in title overlay.
  avg = min(65535u, avg + uint(overlay_title(p.xy, u, title_tex) * 65535.0f));

  uint hi = (avg >> 8) & 255u;
  uint lo =  avg       & 255u;

  uint v = hi;                            // [0..255]
  float t = float(lo) * (1.0f / 256.0f);  // [0..1]

  int max_palette_x_coord = int(paletteTex.get_width()) - 1;

  // Perform manual linear interpolation between 2 entries in the palette.
  uint2 uv1 = uint2(int(v) + 0, 0);
  uint2 uv2 = uint2(min(max_palette_x_coord, int(v) + 1), 0);
  float4 col1 = paletteTex.read(uv1);  // [0..1]
  float4 col2 = paletteTex.read(uv2);

  float4 col = col1 * (1.0f - t) + t * col2;

  // Square it, to make up for palette packed with kPower == 0.5.
  // SEE ALSO: Same formula repeated in palette_fs.
  col = col * col;
  col *= 3.0f;  // kHeadroom

  return col;
}

// ====================================================================================================
// draw_palette.js: kPaletteOverlayWGSL (palette_vs, palette_fs)
// ====================================================================================================

struct UiUniforms {
  float screen_w;
  float screen_h;
  float rect_w;
  float rect_h;
  float margin_x;
  float margin_y;
  float palette_swatch_count;
  float _pad;
};

struct PaletteVertexOut {
  float4 pos [[position]];
  float2 uv;
};

// Two triangles (6 verts) with UVs spanning [0..1].
// We place the rect in pixel space then convert to NDC.
vertex PaletteVertexOut palette_vs(uint vid [[vertex_id]], constant UiUniforms& ui [[buffer(0)]]) {
  // 6 vertices => (0,0)(1,0)(0,1) and (0,1)(1,0)(1,1)
  float2 p;
  switch (vid) {
    case 0u: p = float2(0.0f, 0.0f); break;
    case 1u: p = float2(1.0f, 0.0f); break;
    case 2u: p = float2(0.0f, 1.0f); break;
    case 3u: p = float2(0.0f, 1.0f); break;
    case 4u: p = float2(1.0f, 0.0f); break;
    default: p = float2(1.0f, 1.0f); break;  // vid == 5
  }

  // Lower-right anchored rect in pixels.
  // Pixel origin assumed top-left; NDC origin is center with +Y up.
  float x0 = ui.screen_w - ui.margin_x - ui.rect_w;
  float y0 = ui.screen_h - ui.margin_y - ui.rect_h;
  float px = x0 + p.x * ui.rect_w;
  float py = y0 + p.y * ui.rect_h;

  // Convert pixel coords to NDC.
  float ndc_x = (px / ui.screen_w) * 2.0f - 1.0f;
  float ndc_y = 1.0f - (py / ui.screen_h) * 2.0f;

  PaletteVertexOut out;
  out.pos = float4(ndc_x, ndc_y, 0.0f, 1.0f);
  out.uv  = p;
  return out;
}

fragment float4 palette_fs(PaletteVertexOut in                         [[stage_in]],
                           texture2d<float, access::read> palette_tex [[texture(0)]],
                           constant UiUniforms&           ui          [[buffer(0)]]) {
  int dims_x = int(palette_tex.get_width());

  // if swatch_count is 8, we want samples at:
  // 0.0   0.14  0.28  0.42  0.56  0.71  0.85  1.0
  float t = in.uv.x;
  t = floor(t * (ui.palette_swatch_count)) *
      (1.0f / (ui.palette_swatch_count - 1.0f));

  int xi = clamp(to_i32(t * float(dims_x - 1)), 0, dims_x - 1);
  float4 col = palette_tex.read(uint2(xi, 0));

  // SEE ALSO: Same formula repeated in present_fs.
  col = col * col;
  col *= 3.0f;  // kHeadroom

  return float4(col.rgb, 1.0f);
}
"""
}

/// What can go wrong setting up the renderer. Every case means the visualizer can't run on this Mac.
public enum MetalRendererError: Error, CustomStringConvertible {
    case noDevice
    case missingFunction(String)
    case allocation(String)
    case uploadSize(String)

    public var description: String {
        switch self {
        case .noDevice: return "no Metal device"
        case .missingFunction(let name): return "shader entry point \(name) is missing"
        case .allocation(let what): return "could not allocate the \(what)"
        case .uploadSize(let what): return "the \(what) upload is too small for its textures"
        }
    }
}
