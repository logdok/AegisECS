import Foundation

/// Reads the numbers for you. Port of `EcsDiagnostics`.
///
/// Each rule matches a documented, real failure that produces no error message
/// of its own: a query whose cache never hits; a destroy queue that is not
/// drained because the reaper sits in the wrong place; a spatial grid whose
/// cell size makes the rebuild mostly a walk through empty space. Each is
/// obvious once you know where to look, and none is obvious while you are
/// staring at a wall of microseconds.
public final class Diagnostics {
    public struct Finding: Sendable {
        public enum Severity: Int, Sendable, Comparable {
            case info = 0, warning = 1, critical = 2
            public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
            public var label: String {
                switch self { case .critical: return "CRITICAL"; case .warning: return "WARNING"; case .info: return "INFO" }
            }
        }
        public var severity: Severity
        public var source: String
        public var title: String
        public var detail: String
        public var hint: String

        public func formatted() -> String {
            var text = "[\(severity.label)] \(source): \(title)"
            if !detail.isEmpty { text += "\n    " + detail }
            if !hint.isEmpty { text += "\n    -> " + hint }
            return text
        }
    }

    /// Frame budget that p95 is compared against. 16600 us is 60 Hz.
    public var frameBudgetUsec: Float = 16600
    /// A system taking more than this fraction of the frame is named aloud.
    public var dominantSharePercent: Float = 40
    /// max/median ratio above which a system is a spike source.
    public var volatilityWarning: Float = 5
    /// Minimum excess share before an unstable system is reported.
    public var excessShareWarning: Float = 15
    public var loadFactorWarning: Float = 0.85
    public var storeFillWarning: Float = 0.90
    public var spikeRatioWarning: Float = 2.0

    private var queryRebuilds: [String: Int32] = [:]
    private var queryFrames: [String: Int] = [:]

    public init() {}

    public struct Extras {
        public var clock: SimulationClock?
        public var queries: [String: Query]
        public var grids: [String: UniformSpatialGrid]
        public init(clock: SimulationClock? = nil, queries: [String: Query] = [:], grids: [String: UniformSpatialGrid] = [:]) {
            self.clock = clock; self.queries = queries; self.grids = grids
        }
    }

    /// Runs every rule and returns the findings, worst first.
    public func inspect(recorder: FrameRecorder?, stats: FrameStats?, world: World?, extras: Extras = Extras()) -> [Finding] {
        var findings: [Finding] = []
        if let world {
            checkWorld(&findings, world)
            checkStores(&findings, world)
        }
        if let recorder, let stats, stats.isAnalysed {
            checkFrameBudget(&findings, stats)
            checkSystems(&findings, recorder, stats)
            checkDestroyQueue(&findings, stats)
        }
        checkQueries(&findings, extras.queries, recorder)
        checkGrids(&findings, extras.grids)
        if let clock = extras.clock { checkClock(&findings, clock) }
        findings.sort { $0.severity > $1.severity }
        return findings
    }

    public func reset() {
        queryRebuilds.removeAll()
        queryFrames.removeAll()
    }

    private func checkWorld(_ findings: inout [Finding], _ world: World) {
        let load = world.getLoadFactor()
        if load >= 1.0 {
            findings.append(Finding(severity: .critical, source: "World", title: "Entity capacity exhausted",
                detail: "live \(world.getLiveCount()) of \(world.capacity); createEntity() is returning -1",
                hint: "Raise the initial capacity, or register a CapacityPolicySystem right after the reaper."))
        } else if load >= loadFactorWarning {
            findings.append(Finding(severity: .warning, source: "World", title: "Entity capacity nearly full",
                detail: String(format: "live %d of %d (%.0f%%)", Int(world.getLiveCount()), Int(world.capacity), load * 100),
                hint: "Grow before it fills: CapacityPolicySystem, or a larger initial capacity."))
        }
    }

    private func checkStores(_ findings: inout [Finding], _ world: World) {
        for index in 0..<world.storeCount {
            guard let store = world.getStore(at: index) else { continue }
            let capacity = store.capacity
            if capacity <= 0 { continue }
            let fill = Float(store.count) / Float(capacity)
            if fill >= 1.0 {
                findings.append(Finding(severity: .critical, source: "Store", title: "'\(store.getDebugName())' is full",
                    detail: "\(store.count) of \(capacity) slots used; the next attach() will return -1",
                    hint: "Grow the world, or check whether this store is leaking components."))
            } else if fill >= storeFillWarning {
                findings.append(Finding(severity: .warning, source: "Store", title: "'\(store.getDebugName())' is nearly full",
                    detail: String(format: "%d of %d slots used (%.0f%%)", Int(store.count), Int(capacity), fill * 100), hint: ""))
            }
            if store.changeLogOverflowed {
                findings.append(Finding(severity: .info, source: "Store", title: "'\(store.getDebugName())' change log overflowed",
                    detail: "clear() or world.reset() wiped the store, so individual removals were not logged",
                    hint: "Expected after a restart; call clearChangeLog() to reset the flag."))
            }
        }
    }

    private func checkFrameBudget(_ findings: inout [Finding], _ stats: FrameStats) {
        let p95 = stats.frameP95Usec()
        if p95 > frameBudgetUsec {
            findings.append(Finding(severity: .critical, source: "Frame", title: "ECS exceeds the frame budget",
                detail: String(format: "p95 %.2f ms against a %.2f ms budget (median %.2f ms)",
                               p95 / 1000, frameBudgetUsec / 1000, stats.frameMedianUsec() / 1000),
                hint: "Most frames are already over budget before rendering. Start with the top spike contributor."))
        }
        let ratio = stats.spikeRatio()
        if ratio >= spikeRatioWarning && stats.spikeFrameCount() > 0 {
            findings.append(Finding(severity: .warning, source: "Frame", title: "Uneven frame cost",
                detail: String(format: "worst frame is %.1fx the median (%d of %d frames ran long)",
                               ratio, Int(stats.spikeFrameCount()), Int(stats.frameCount)),
                hint: "An uneven frame is felt as stutter even when the average looks fine."))
        }
    }

    private func checkSystems(_ findings: inout [Finding], _ recorder: FrameRecorder, _ stats: FrameStats) {
        for index in 0..<stats.systemCount {
            let share = stats.systemSharePercent(index)
            let volatility = stats.systemVolatility(index)
            let excessShare = stats.systemExcessShare(index)
            if share >= dominantSharePercent {
                findings.append(Finding(severity: .info, source: "System", title: "'\(recorder.systemName(index))' dominates the frame",
                    detail: String(format: "%.0f%% of ECS time, median %d us (stable: %.1fx)",
                                   share, Int(stats.systemMedianUsec(index)), volatility),
                    hint: "Steady cost, not a stutter source. Optimise it to lower the baseline."))
            }
            if volatility >= volatilityWarning && excessShare >= excessShareWarning {
                findings.append(Finding(severity: .warning, source: "System", title: "'\(recorder.systemName(index))' causes slow frames",
                    detail: String(format: "median %d us but peaks at %d us (%.0fx); accounts for %.0f%% of the excess in slow frames",
                                   Int(stats.systemMedianUsec(index)), Int(stats.systemMaxUsec(index)), volatility, excessShare),
                    hint: "A system that is usually cheap and occasionally expensive is what stutter feels like. Look for work that happens in bursts."))
            }
        }
    }

    private func checkDestroyQueue(_ findings: inout [Finding], _ stats: FrameStats) {
        let peak = stats.peakPendingDestroy()
        if peak > 0 {
            findings.append(Finding(severity: .critical, source: "Lifecycle", title: "Destroy queue is not being drained",
                detail: "up to \(peak) entities were still queued at the end of a frame",
                hint: "flushDestroyQueue() is not running, or it runs before the systems that queue destruction. Register a ReaperSystem LAST."))
        }
    }

    private func checkQueries(_ findings: inout [Finding], _ queries: [String: Query], _ recorder: FrameRecorder?) {
        let framesNow = recorder?.framesSeenCount ?? 0
        for (name, query) in queries {
            if query.isTruncated {
                findings.append(Finding(severity: .warning, source: "Query", title: "'\(name)' result is truncated",
                    detail: "more entities matched than the \(query.resultCapacity)-entry buffer holds",
                    hint: "Raise maximumResults, or narrow the query."))
            }
            let rebuildsNow = query.rebuildCountValue
            if let prevRebuilds = queryRebuilds[name], let prevFrames = queryFrames[name] {
                let rebuildDelta = Int(rebuildsNow - prevRebuilds)
                let frameDelta = framesNow - prevFrames
                if frameDelta >= 30 && rebuildDelta >= frameDelta {
                    findings.append(Finding(severity: .warning, source: "Query", title: "'\(name)' rebuilds every frame",
                        detail: "\(rebuildDelta) rebuilds over \(frameDelta) frames - the cache never hits",
                        hint: "Some participating store changes membership every frame. Drop the volatile component, or use a direct loop."))
                }
            }
            queryRebuilds[name] = rebuildsNow
            queryFrames[name] = framesNow
        }
    }

    private func checkGrids(_ findings: inout [Finding], _ grids: [String: UniformSpatialGrid]) {
        for (name, grid) in grids {
            let cells = grid.getCellCount()
            let entries = grid.getEntryCount()
            if cells <= 0 { continue }
            if entries > 0 && cells > entries * 8 {
                findings.append(Finding(severity: .warning, source: "Grid", title: "'\(name)' has far more cells than objects",
                    detail: "\(cells) cells for \(entries) entries - the rebuild is mostly iterating empty cells",
                    hint: "Increase cellSize, or use UniformSpatialGrid.suggestCellSize()."))
            } else if entries > 0 && entries > cells * 32 {
                findings.append(Finding(severity: .warning, source: "Grid", title: "'\(name)' cells are overcrowded",
                    detail: "\(entries) entries across only \(cells) cells (~\(entries / cells) per cell)",
                    hint: "Queries have to distance-check too many candidates. Decrease cellSize."))
            }
            if !grid.isFlat() && grid.getDimensions().1 <= 2 {
                findings.append(Finding(severity: .info, source: "Grid", title: "'\(name)' is 3D but almost flat",
                    detail: "only \(grid.getDimensions().1) vertical layers",
                    hint: "If the world is a plane, pass verticalExtent = 0 for flat mode and cut the cell count."))
            }
        }
    }

    private func checkClock(_ findings: inout [Finding], _ clock: SimulationClock) {
        if clock.droppedSubsteps > 0 {
            findings.append(Finding(severity: .warning, source: "Clock", title: "Simulation cannot keep up",
                detail: String(format: "%d substeps discarded; requested timeScale %.1f", Int(clock.droppedSubsteps), clock.timeScale),
                hint: "The machine is not producing the requested speed-up. Lower timeScale, raise fixedStep, or make the simulation cheaper."))
        } else if clock.isSaturated() {
            findings.append(Finding(severity: .info, source: "Clock", title: "Substep cap reached",
                detail: "the frame used all \(clock.maxSubsteps) allowed substeps", hint: ""))
        }
    }
}
