import AppKit

/// The window's brushed metal as one bitmap at device-pixel size (RESEARCH.md §7.3).
///
/// The gradient is HORIZONTAL and keyed to the window width, so the bitmap is rebuilt whenever the
/// window changes size; a tiled pattern would leave the centre highlight behind as the window grew.
/// The grain is one brightness offset per device-pixel row, constant across the scanline, from a
/// fixed seed: the original was a fixed asset, so the texture must not shimmer between launches
/// or while resizing. Rows are counted from the window TOP, which stays put during a resize.
@MainActor
enum ChromeMetalTexture {
    /// §7.3: stdev of per-row means measured 2.3–3.2 levels; clamped so no row becomes a stripe.
    nonisolated static let grainStdDev = 3.0
    nonisolated static let grainClamp = 7
    nonisolated private static let seed: UInt64 = 0x0049_2005_1D7E_A11C

    /// Brightness offset in 8-bit levels for one device-pixel row, counted from the window top.
    nonisolated static func grainOffset(row: Int) -> Int {
        var state = seed ^ (UInt64(truncatingIfNeeded: row) &* 0x9E37_79B9_7F4A_7C15)
        let u1 = max(unitDouble(&state), .leastNonzeroMagnitude)
        let u2 = unitDouble(&state)
        let gaussian = (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        let level = Int((gaussian * grainStdDev).rounded())
        return min(max(level, -grainClamp), grainClamp)
    }

    /// SplitMix64: tiny, fast, and identical on every run, which is all the grain needs.
    nonisolated private static func unitDouble(_ state: inout UInt64) -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE5_E9B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }

    /// Builds the metal for a window of `pixelWidth` × `pixelHeight` device pixels.
    /// `scale` places the 1 pt-high top highlight at its point row (y = 1 pt, §7.1).
    ///
    /// Every scanline is the same gradient row shifted by its grain level, so the 15 possible rows
    /// (levels −7…+7) are built once, frame columns included, and each scanline is one memory copy.
    /// That keeps a rebuild to a few milliseconds even in a Debug build, which matters because a
    /// live resize rebuilds on every frame.
    static func make(pixelWidth w: Int, pixelHeight h: Int, scale: CGFloat) -> CGImage? {
        let rowBytes = w * 4
        let levels = 2 * grainClamp + 1
        let info = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard w > 2, h > 2, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: rowBytes,
                                  space: space, bitmapInfo: info),
              let data = ctx.data,
              let variants = gradientVariants(width: w, levels: levels, space: space, bitmapInfo: info),
              let rows = variants.data else { return nil }

        // Row 0 of bitmap memory is the window's top row.
        for row in 0..<h {
            let level = grainOffset(row: row) + grainClamp
            (data + row * rowBytes).copyMemory(from: rows + level * rowBytes, byteCount: rowBytes)
        }

        // The top highlight at y = 1 pt, one device pixel tall, between the frame columns.
        let highlight = bytes(Theme.winTopHighlight)
        let highlightIndex = min(h - 1, max(1, Int(scale.rounded())))
        let highlightRow = data.assumingMemoryBound(to: UInt8.self) + highlightIndex * rowBytes
        for column in 1..<(w - 1) {
            for c in 0..<3 { highlightRow[column * 4 + c] = highlight[c] }
        }
        return ctx.makeImage()
    }

    /// A `levels`-row bitmap: row i is the horizontal gradient brightened by (i − clamp) levels,
    /// with the 1 px window frame in its first and last columns. The gradient is computed exactly
    /// (no dithering, which CGGradient applies) and the brightness shift uses additive blending:
    /// plusLighter adds the source; plusDarker computes dst + src − 1, so (1 − d) subtracts d.
    private static func gradientVariants(width w: Int, levels: Int, space: CGColorSpace,
                                          bitmapInfo: UInt32) -> CGContext? {
        let rowBytes = w * 4
        guard let ctx = CGContext(data: nil, width: w, height: levels, bitsPerComponent: 8, bytesPerRow: rowBytes,
                                  space: space, bitmapInfo: bitmapInfo),
              let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let edge = components(Theme.metalEdge), centre = components(Theme.metalCenter)
        for x in 0..<w {
            let k = 1 - abs(2 * (Double(x) + 0.5) / Double(w) - 1)     // 0 at the edges, 1 at the centre
            for c in 0..<3 { data[x * 4 + c] = clampByte(edge[c] + (centre[c] - edge[c]) * k) }
            data[x * 4 + 3] = 255
        }
        for level in 1..<levels { (data + level * rowBytes).update(from: data, count: rowBytes) }

        for level in 0..<levels where level != grainClamp {
            let shift = CGFloat(abs(level - grainClamp)) / 255
            let brighter = level > grainClamp
            ctx.setBlendMode(brighter ? .plusLighter : .plusDarker)
            let v = brighter ? shift : 1 - shift
            ctx.setFillColor(CGColor(srgbRed: v, green: v, blue: v, alpha: 1))
            ctx.fill(CGRect(x: 0, y: CGFloat(levels - 1 - level), width: CGFloat(w), height: 1))
        }
        ctx.setBlendMode(.normal)

        let left = bytes(Theme.winBorderLeft), right = bytes(Theme.winBorderRight)
        for level in 0..<levels {
            for c in 0..<3 {
                data[level * rowBytes + c] = left[c]
                data[level * rowBytes + (w - 1) * 4 + c] = right[c]
            }
        }
        return ctx
    }

    /// 0...255 sRGB components.
    private static func components(_ color: NSColor) -> [Double] {
        guard let c = color.usingColorSpace(.sRGB) else { return [0, 0, 0] }
        return [c.redComponent, c.greenComponent, c.blueComponent].map { Double($0) * 255 }
    }

    private static func bytes(_ color: NSColor) -> [UInt8] { components(color).map(clampByte) }

    nonisolated private static func clampByte(_ value: Double) -> UInt8 {
        UInt8(min(max(value.rounded(), 0), 255))
    }
}
