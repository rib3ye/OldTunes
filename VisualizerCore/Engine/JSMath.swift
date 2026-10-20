import Foundation

// The few JavaScript number rules the ported engine leans on (docs/VISUALIZER.md, "Porting rules").
// JavaScript keeps going where Swift would trap or quietly differ, so the port spells them out.

/// `x | 0`: ECMAScript ToInt32. NaN and ±infinity become 0, the rest truncates toward zero and wraps
/// modulo 2³², the way JavaScript does. `Int(x)` would trap on NaN.
@inline(__always)
func toInt32(_ x: Double) -> Int {
    if abs(x) < 2_147_483_648.0 { return Int(x) }
    guard x.isFinite else { return 0 }
    let wrapped = x.rounded(.towardZero).truncatingRemainder(dividingBy: 4_294_967_296.0)
    return Int(Int32(truncatingIfNeeded: Int64(wrapped)))
}

/// `Math.min(a, b)`: NaN if either is NaN (Swift's `min` would return the other one), −0 before +0.
@inline(__always)
func jsMin(_ a: Double, _ b: Double) -> Double {
    if a.isNaN || b.isNaN { return .nan }
    if a == b { return a.sign == .minus ? a : b }
    return a < b ? a : b
}

/// `Math.max(a, b)`: NaN if either is NaN, +0 before −0.
@inline(__always)
func jsMax(_ a: Double, _ b: Double) -> Double {
    if a.isNaN || b.isNaN { return .nan }
    if a == b { return a.sign == .minus ? b : a }
    return a > b ? a : b
}

/// `Math.round(x)`: halves round up, toward +∞ (Swift's `.rounded()` rounds them away from zero).
@inline(__always)
func jsRound(_ x: Double) -> Double {
    guard x.isFinite else { return x }
    let down = x.rounded(.down)
    let up = x - down >= 0.5 ? down + 1 : down
    // Math.round keeps the sign of a zero result for −0.5 ≤ x < 0.
    return up == 0 && x < 0 ? -0.0 : up
}

/// `!x` for a number: true for 0 and NaN, false for anything else.
@inline(__always)
func jsNot(_ x: Double) -> Bool {
    x == 0 || x.isNaN
}

extension Array where Element == Float {
    /// A read the way JavaScript reads a Float32Array: out of range gives `undefined`, which arithmetic
    /// turns into NaN. Lets the port keep going where Swift's subscript would trap.
    @inline(__always)
    func js(_ index: Int) -> Double {
        index >= 0 && index < count ? Double(self[index]) : .nan
    }
}
