import XCTest
@testable import AegisECS

final class SpatialAndTimeTests: XCTestCase {
    func testGridRebuildAndQuery() {
        var rng = SplitMix64(seed: 12345)
        let n = 4000
        var ids = [Int32](repeating: 0, count: n)
        var points = [SIMDVector3](repeating: SIMDVector3(0, 0, 0), count: n)
        for i in 0..<n {
            ids[i] = Int32(i)
            points[i] = SIMDVector3(rng.range(-130, 130), 0, rng.range(-130, 130))
        }

        let grid = UniformSpatialGrid()
        grid.configure(arenaRadius: 130, verticalExtent: 0, cellSize: 6, entryCapacity: n)
        grid.rebuild(entityIDs: ids, points: points, entryCount: n)
        XCTAssertEqual(grid.getEntryCount(), n, "every entry is indexed")
        XCTAssertTrue(grid.isFlat())

        // Reference: brute-force nearest for a handful of query points must
        // match the grid's answer.
        for q in stride(from: 0, to: n, by: 397) {
            let center = points[q]
            let radius: Float = 12
            var bestBrute: Int32 = -1
            var bestD = radius * radius
            for i in 0..<n {
                let d = points[i].distanceSquared(to: center)
                if d < bestD { bestD = d; bestBrute = ids[i] }
            }
            XCTAssertEqual(grid.queryNearest(center: center, radius: radius), bestBrute,
                           "grid nearest matches brute force at q=\(q)")
        }

        // querySphere returns exactly the in-radius set.
        let center = points[100]
        let radius: Float = 20
        var brute = Set<Int32>()
        for i in 0..<n where points[i].distanceSquared(to: center) <= radius * radius {
            brute.insert(ids[i])
        }
        let written = grid.querySphere(center: center, radius: radius, resultLimit: UniformSpatialGrid.maxQueryResults)
        var got = Set<Int32>()
        for i in 0..<written { got.insert(grid.queryBuffer[i]) }
        XCTAssertEqual(got, brute, "querySphere returns exactly the in-radius entities")
    }

    func testSuggestCellSize() {
        let flat = UniformSpatialGrid.suggestCellSize(arenaRadius: 130, verticalExtent: 0, expectedEntries: 10000, typicalQueryRadius: 12)
        XCTAssertGreaterThanOrEqual(flat, 24, "the floor is twice the query radius")
    }

    func testFixedStepClock() {
        let clock = SimulationClock()
        clock.fixedStep = 1.0 / 60.0

        XCTAssertEqual(clock.advance(realDelta: 1.0 / 120.0), 0, "half a step accumulates without firing")
        XCTAssertEqual(clock.advance(realDelta: 1.0 / 120.0), 1, "the other half completes one step")
        XCTAssertEqual(clock.getLastSubsteps(), 1)

        clock.reset()
        clock.timeScale = 50
        let steps = clock.advance(realDelta: 1.0 / 60.0)
        XCTAssertEqual(steps, clock.maxSubsteps, "the fuse caps a fast-forward burst")
        XCTAssertTrue(clock.isSaturated())
        XCTAssertGreaterThan(clock.droppedSubsteps, 0, "excess time is dropped, not banked")

        clock.reset()
        clock.timeScale = 0
        XCTAssertEqual(clock.advance(realDelta: 1.0 / 60.0), 0, "a zero time scale freezes the simulation")
    }

    func testAngleMath() {
        // The wrap-around case the naive clamp gets wrong: 3.1 and -3.1 are
        // only ~0.083 rad apart the short way, not 6.2. A small step must move
        // toward -3.1, not away from it across the whole circle.
        let gap = AngleMath.shortestDelta(3.1, -3.1)
        XCTAssertLessThan(gap, 0.1, "the short way round is tiny")
        let smallStep = AngleMath.approach(3.1, -3.1, 0.02)
        XCTAssertEqual(AngleMath.shortestDelta(smallStep, -3.1), gap - 0.02, accuracy: 1e-4,
                       "a step shorter than the gap closes it by exactly maxStep, the short way")
        // A step longer than the gap lands on the target angle. The original
        // does not re-normalise the result, so it comes back as -3.1 + 2π
        // (3.183) — the same angle — which is why the check is on the delta.
        XCTAssertEqual(AngleMath.shortestDelta(AngleMath.approach(3.1, -3.1, 0.2), -3.1), 0, accuracy: 1e-4)
        XCTAssertEqual(AngleMath.shortestDelta(0, .pi / 2), .pi / 2, accuracy: 1e-5)
    }
}

/// Small, portable, exactly reproducible generator for the spatial test.
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Float { Float(next() >> 40) * (1.0 / Float(1 << 24)) }
    mutating func range(_ lo: Float, _ hi: Float) -> Float { lo + (hi - lo) * unit() }
}
