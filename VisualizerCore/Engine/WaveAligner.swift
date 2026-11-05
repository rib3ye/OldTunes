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
//  Changed for oldTunes, 2026: wave_align.js (Geiss HDR v335), ported to Swift. Out-of-range reads
//  give NaN where the original reads `undefined`.

/// Multiscale waveform alignment. Each frame, it picks the window of the new wave (and of its three
/// flips) that best matches the previous frame's aligned window, so a steady tone holds still.
///
/// The caller gives ORIG_SAMPLE_COUNT; the window is floor(ORIG_SAMPLE_COUNT · align_frac) samples.
/// A lower align_frac aligns better but draws fewer samples, and too low makes the wave snap to the
/// previous frame and repeat for several frames: the AnalyserNode's window moves in 128-sample quanta.
public struct WaveAligner: Sendable {
    private var origSampleCount = 0
    private var alignedSampleCount = 0
    private var maxOffset = 0
    private var levels = 0
    private var prevAligned: [Float]?
    private var tmpOrig: [Float]?

    public init() {}

    /// `alignFromF(waveF, align_frac, ORIG_SAMPLE_COUNT)`. The original throws for a count ≤ 0 or a
    /// wave shorter than the count; this returns an empty wave instead.
    public mutating func align(_ wave: [Float], alignFraction: Double, sampleCount: Int) -> [Float] {
        alignedSampleCount = Int((Double(sampleCount) * alignFraction).rounded(.down))

        // The search range. Note this uses the count from the previous call, as the original does:
        // on the first call it is 0, so the first window starts at 0, not in the middle.
        maxOffset = origSampleCount - alignedSampleCount
        if maxOffset < 0 { maxOffset = 0 }
        levels = Self.chooseLevels(original: origSampleCount, aligned: alignedSampleCount)

        guard sampleCount > 0, wave.count >= sampleCount, alignedSampleCount >= 0 else { return [] }

        // Start over if the count changed.
        if origSampleCount != sampleCount || tmpOrig?.count != sampleCount {
            origSampleCount = sampleCount
            prevAligned = nil
            tmpOrig = [Float](repeating: 0, count: sampleCount)
        }
        let orig = Array(wave[0..<sampleCount])
        tmpOrig = orig

        // First frame after a (re)start: the window at MAX_OFF / 2.
        guard let prevAligned else {
            let out = Self.window(orig, offset: maxOffset >> 1, count: alignedSampleCount)
            self.prevAligned = out
            return out
        }

        let templates = Self.buildPyramid(prevAligned, levels: levels)
        // Weights for the template, downsampled to match.
        var weights = [Self.buildWeightsQ4(templates[0].count)]
        for level in 1..<templates.count {
            weights.append(Self.downsample2Q4(weights[level - 1]))
        }

        // Align against all four flips of the new wave; it helps big, very low bass waves line up.
        let n = orig.count
        var flipped = [[Float]](repeating: [Float](repeating: 0, count: n), count: 4)
        for i in 0..<n {
            flipped[0][i] = orig[i]
            flipped[1][i] = orig[n - 1 - i]
            flipped[2][i] = -orig[i]
            flipped[3][i] = -orig[n - 1 - i]
        }

        var bestFlip = -1
        var bestScore = -Double.infinity
        var bestOffset = -1
        for flip in 0..<4 {
            let sources = Self.buildPyramid(flipped[flip], levels: levels)
            let result = Self.findBestOffset(sources: sources, templates: templates, weights: weights, maxOffset: maxOffset)
            if result.score > bestScore {
                bestFlip = flip
                bestScore = result.score
                bestOffset = result.offset
            }
        }
        // Only all-NaN scores leave no winner; the original would throw there.
        if bestFlip < 0 {
            bestFlip = 0
            bestOffset = 0
        }

        let out = Self.window(flipped[bestFlip], offset: bestOffset, count: alignedSampleCount)
        self.prevAligned = out
        return out
    }

    /// `new Float32Array(count)` filled from `source.subarray(offset, offset + count)`: short at the
    /// end, zeros fill the rest.
    static func window(_ source: [Float], offset: Int, count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: max(0, count))
        let start = max(0, min(offset, source.count))
        let end = max(start, min(offset + count, source.count))
        for i in start..<end { out[i - start] = source[i] }
        return out
    }

    /// `Blur(wave, radius)`: a box blur over ±radius samples; the window shrinks near the ends. Returns
    /// the wave itself when the radius is ≤ 0 or too big for it.
    public static func blur(_ wave: [Float], radius: Int) -> [Float] {
        let n = wave.count
        let r = radius
        if r <= 0 { return wave }
        if n <= r { return wave }
        let fullW = 2 * r + 1
        // A full window never fits.
        if fullW >= n { return wave }

        var ret = [Float](repeating: 0, count: n)
        var sum = 0.0

        // Ramp up (the window grows) for i = 0 … r.
        for j in 0...r {
            sum += Double(wave[j])
        }
        ret[0] = Float(sum / Double(r + 1))
        for i in stride(from: 1, through: r, by: 1) {
            sum += Double(wave[i + r])
            ret[i] = Float(sum / Double(i + r + 1))
        }

        // Steady state, the full window, for i = r + 1 … N − r − 1.
        let invFullW = 1.0 / Double(fullW)
        if r + 1 <= n - r - 1 {
            for i in (r + 1)...(n - r - 1) {
                sum += Double(wave[i + r]) - Double(wave[i - r - 1])
                ret[i] = Float(sum * invFullW)
            }
        }

        // Ramp down (the window shrinks) for i = N − r … N − 1.
        for i in (n - r)..<n {
            sum -= Double(wave[i - r - 1])
            ret[i] = Float(sum / Double(n - i + r))
        }
        return ret
    }

    /// `weightQ4(t)`: how much the match counts at position t ∈ [0, 1] of the window, 0 … 15.
    static func weightQ4(_ t: Double) -> Double {
        let pyramid = 1.0 - abs(t - 0.5) * 2  // [0 … 1 … 0]
        let exag = pyramid * 5 - 2
        return jsMax(0, jsMin(15, exag * 15))
    }

    static func downsample2(_ src: [Float]) -> [Float] {
        let n2 = src.count >> 1
        var dst = [Float](repeating: 0, count: n2)
        var i = 0
        for j in 0..<n2 {
            dst[j] = Float((Double(src[i]) + Double(src[i + 1])) * 0.5)
            i += 2
        }
        return dst
    }

    /// `corrAt(S, T, Wq4, off)`.
    static func correlation(_ s: [Float], _ t: [Float], _ w: [UInt8], offset: Int) -> Double {
        var acc = 0.0
        for i in 0..<t.count {
            acc += s.js(offset + i) * Double(t[i]) * (i < w.count ? Double(w[i]) : .nan)
        }
        return acc
    }

    static func buildPyramid(_ a: [Float], levels: Int) -> [[Float]] {
        var pyramid = [a]
        if levels >= 1 {
            for i in 1...levels { pyramid.append(downsample2(pyramid[i - 1])) }
        }
        return pyramid
    }

    static func buildWeightsQ4(_ count: Int) -> [UInt8] {
        (0..<count).map { i in
            let rel = (Double(i) + 0.5) / Double(count)  // centre of the sample
            return UInt8(toInt32(weightQ4(rel)) & 15)
        }
    }

    static func downsample2Q4(_ src: [UInt8]) -> [UInt8] {
        let n2 = src.count >> 1
        var dst = [UInt8](repeating: 0, count: n2)
        var i = 0
        for j in 0..<n2 {
            // Average the pair, keeping it in 0 … 15.
            dst[j] = UInt8(((Int(src[i]) + Int(src[i + 1]) + 1) >> 1) & 15)
            i += 2
        }
        return dst
    }

    /// `findBestOffsetMultiscale`: brute force at the coarsest level, then ±1 at each finer one.
    static func findBestOffset(sources: [[Float]], templates: [[Float]], weights: [[UInt8]],
                               maxOffset: Int) -> (offset: Int, score: Double) {
        let levels = templates.count - 1
        let s = sources[levels]
        let t = templates[levels]
        let w = weights[levels]
        let maxOffCoarse = s.count - t.count

        var bestOffset = 0
        var bestScore = -Double.infinity
        if maxOffCoarse >= 0 {
            for offset in 0...maxOffCoarse {
                let score = correlation(s, t, w, offset: offset)
                if score > bestScore {
                    bestScore = score
                    bestOffset = offset
                }
            }
        }

        if levels >= 1 {
            for level in stride(from: levels - 1, through: 0, by: -1) {
                let s2 = sources[level]
                let t2 = templates[level]
                let w2 = weights[level]
                let maxOff = s2.count - t2.count
                let predicted = bestOffset << 1
                var o0 = predicted - 1
                var o1 = predicted
                var o2 = predicted + 1
                if o0 < 0 { o0 = 0 }
                if o2 > maxOff { o2 = maxOff }
                if o1 < 0 { o1 = 0 }
                if o1 > maxOff { o1 = maxOff }

                var best = o1
                var scoreBest = correlation(s2, t2, w2, offset: o1)
                if o0 != o1 {
                    let score = correlation(s2, t2, w2, offset: o0)
                    if score > scoreBest {
                        scoreBest = score
                        best = o0
                    }
                }
                if o2 != o1 && o2 != o0 {
                    let score = correlation(s2, t2, w2, offset: o2)
                    if score > scoreBest {
                        scoreBest = score
                        best = o2
                    }
                }
                bestOffset = best
                bestScore = scoreBest
            }
        }

        if bestOffset < 0 { bestOffset = 0 }
        if bestOffset > maxOffset { bestOffset = maxOffset }
        return (bestOffset, bestScore)
    }

    /// `chooseLevels`: up to four halvings, while the coarsest window keeps at least 48 samples.
    static func chooseLevels(original: Int, aligned: Int) -> Int {
        var levels = 0
        var a = aligned
        while levels < 4 && (a >> 1) >= 48 && (original >> 1) > (aligned >> 1) {
            levels += 1
            a >>= 1
        }
        return levels
    }
}
