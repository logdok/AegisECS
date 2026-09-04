import Foundation

/// Fixed-step accumulator with a time scale — determinism that survives fast
/// forward. Port of `SimulationClock`.
///
/// The library's pause convention (a zero-length step) says nothing about the
/// SIZE of the step, and feeding raw frame delta straight into the simulation
/// is only safe while that delta is small. Once time can be sped up, threshold
/// crossings jump, and the simulation gives a DIFFERENT result — and a
/// different one again on a slower machine. A fixed step removes frame rate
/// from the equation.
public final class SimulationClock {
    /// Length of one simulation slice, in seconds. 1/60 is a good default.
    public var fixedStep: Float = 1.0 / 60.0 {
        didSet { fixedStep = max(fixedStep, 0.000_001) }
    }

    /// Real-time multiplier. 0 freezes the simulation, 1 is real time, 50 is
    /// fast forward. Negatives are treated as zero.
    public var timeScale: Float = 1.0

    /// Upper bound on substeps one `advance` may return — the anti
    /// death-spiral fuse. Excess time beyond this is DISCARDED.
    public var maxSubsteps: Int32 = 8

    /// Freezes the clock without losing the accumulator or the time scale.
    public var paused: Bool = false

    public private(set) var elapsedSimulated: Float = 0
    public private(set) var totalSubsteps: Int64 = 0
    public private(set) var droppedSubsteps: Int64 = 0

    private var accumulator: Float = 0
    private var lastSubsteps: Int32 = 0

    public init() {}

    /// Accepts one real frame and returns how many fixed slices to run now.
    /// Call exactly once per frame.
    @discardableResult
    public func advance(realDelta: Float) -> Int32 {
        lastSubsteps = 0
        if paused || realDelta <= 0 || timeScale <= 0 { return 0 }
        accumulator += realDelta * timeScale
        var steps = Int32(accumulator / fixedStep)
        if steps <= 0 { return 0 }
        if steps > maxSubsteps {
            let discarded = steps - maxSubsteps
            droppedSubsteps += Int64(discarded)
            accumulator -= Float(discarded) * fixedStep
            steps = maxSubsteps
        }
        accumulator -= Float(steps) * fixedStep
        lastSubsteps = steps
        totalSubsteps += Int64(steps)
        elapsedSimulated += Float(steps) * fixedStep
        return steps
    }

    public func getLastSubsteps() -> Int32 { lastSubsteps }

    /// Fraction of a slice currently unspent in the accumulator, in `0..<1` —
    /// the interpolation factor for smooth rendering.
    public func getAlpha() -> Float { min(max(accumulator / fixedStep, 0), 1) }

    /// True while the fuse is discarding time.
    public func isSaturated() -> Bool { lastSubsteps >= maxSubsteps }

    /// Seconds of simulation produced per second of real time at the current
    /// settings.
    public func getEffectiveTimeScale(realDelta: Float) -> Float {
        realDelta <= 0 ? 0 : Float(lastSubsteps) * fixedStep / realDelta
    }

    public func reset() {
        accumulator = 0
        lastSubsteps = 0
        elapsedSimulated = 0
        totalSubsteps = 0
        droppedSubsteps = 0
    }
}
