import Foundation

/// Angle helpers — everything needed to smoothly turn something toward a
/// desired direction. Port of `AngleMath`. Independent of the ECS.
public enum AngleMath {
    /// Wraps `value` into `[min, max)` — the float `wrapf` the original relies
    /// on to bring an angle difference to its shortest equivalent.
    @inline(__always)
    public static func wrap(_ value: Float, _ minValue: Float, _ maxValue: Float) -> Float {
        let range = maxValue - minValue
        if range <= 0 { return minValue }
        var result = (value - minValue).truncatingRemainder(dividingBy: range)
        if result < 0 { result += range }
        return result + minValue
    }

    /// Moves `current` toward `desired` by at most `maxStep`, always the
    /// shortest way round the circle. Naively clamping `desired - current`
    /// breaks across ±π; wrapping the difference first fixes it.
    public static func approach(_ current: Float, _ desired: Float, _ maxStep: Float) -> Float {
        current + min(max(wrap(desired - current, -.pi, .pi), -maxStep), maxStep)
    }

    /// Absolute shortest angular distance between two angles, in radians
    /// (always non-negative).
    public static func shortestDelta(_ from: Float, _ to: Float) -> Float {
        abs(wrap(to - from, -.pi, .pi))
    }
}
