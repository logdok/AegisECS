import Foundation

/// One object that ties recording, statistics and diagnostics together. Port of
/// `EcsInspector` — minus the Godot panel, which the client renders itself in
/// SwiftUI from the same recorder/stats/findings.
///
/// Collection is cheap enough to leave on in a release build; the analysis and
/// diagnostics run at their own low rate, not every frame.
public final class Inspector {
    public enum Mode: Int, Sendable {
        case off = 0
        /// Recording + diagnostics, no UI. Cheap enough for a release build.
        case telemetry = 1
        /// The client shows a read-only panel.
        case inspector = 2
        /// The client also exposes controls that change the simulation.
        case dev = 3
    }

    public var mode: Mode = .telemetry

    /// How often aggregates are recomputed, in Hz. Deliberately slower than the
    /// draw rate: a median over hundreds of frames barely moves in a tenth of a
    /// second. Recording still happens every frame.
    public var statsRefreshHz: Float = 2.0
    /// How often diagnostics run, in Hz. Slower still.
    public var diagnosticsRefreshHz: Float = 0.5

    public let recorder = FrameRecorder()
    public let stats = FrameStats()
    public let diagnostics = Diagnostics()

    private weak var scheduler: Scheduler?
    private weak var world: World?
    private var clock: SimulationClock?
    private var queries: [String: Query] = [:]
    private var grids: [String: UniformSpatialGrid] = [:]
    private var counterSections: [(title: String, provider: () -> [(String, String)])] = []
    private var findings: [Diagnostics.Finding] = []
    private var lastCaptureNanos: UInt64 = 0
    private var statsDueNanos: UInt64 = 0
    private var diagnosticsDueNanos: UInt64 = 0
    private var attached = false

    public struct Options {
        public var mode: Mode = .telemetry
        public var frames: Int = FrameRecorder.defaultFrameCapacity
        public var budgetUsec: Float?
        public var clock: SimulationClock?
        public var queries: [String: Query] = [:]
        public var grids: [String: UniformSpatialGrid] = [:]
        public init() {}
    }

    private init() {}

    /// Builds the inspector. Always returns an object — never nil — so the
    /// caller needs no branching.
    public static func attach(scheduler: Scheduler, world: World, options: Options = Options()) -> Inspector {
        let inspector = Inspector()
        inspector.mode = options.mode
        if options.mode == .off { return inspector }
        if !inspector.recorder.configure(scheduler: scheduler, world: world, frames: options.frames) {
            inspector.mode = .off
            return inspector
        }
        inspector.scheduler = scheduler
        inspector.world = world
        inspector.clock = options.clock
        inspector.queries = options.queries
        inspector.grids = options.grids
        if let budget = options.budgetUsec { inspector.diagnostics.frameBudgetUsec = budget }
        inspector.attached = true
        inspector.lastCaptureNanos = DispatchTime.now().uptimeNanoseconds
        return inspector
    }

    /// Records the frame that just finished. Call it as the last thing in the
    /// frame, after every phase has run.
    public func capture() {
        guard attached else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let wall = Float(now - lastCaptureNanos) / 1000.0
        lastCaptureNanos = now

        let substeps = clock.map { max($0.getLastSubsteps(), 1) } ?? 1
        recorder.capture(substeps: substeps, wallFrameUsec: wall)

        if now >= statsDueNanos {
            statsDueNanos = now + UInt64(1_000_000_000.0 / Double(max(statsRefreshHz, 0.01)))
            stats.analyse(recorder)
            if now >= diagnosticsDueNanos {
                diagnosticsDueNanos = now + UInt64(1_000_000_000.0 / Double(max(diagnosticsRefreshHz, 0.01)))
                findings = diagnostics.inspect(recorder: recorder, stats: stats, world: world, extras: extras())
            }
        }
    }

    /// Forces an immediate recompute, ignoring the refresh rates.
    public func refreshNow() {
        guard attached else { return }
        stats.analyse(recorder)
        findings = diagnostics.inspect(recorder: recorder, stats: stats, world: world, extras: extras())
    }

    public func getFindings() -> [Diagnostics.Finding] { findings }

    /// Registers a group of app counters shown at the top of the panel. The
    /// library knows nothing about your app, so it cannot show "live enemies"
    /// itself; the provider returns `[(label, value)]`. Called at panel-refresh
    /// rate, not every frame.
    public func addCounterSection(_ title: String, provider: @escaping () -> [(String, String)]) {
        counterSections.append((title, provider))
    }

    public var counterSectionCount: Int { counterSections.count }
    public func counterSectionTitle(_ index: Int) -> String { counterSections[index].title }
    public func counterSectionRows(_ index: Int) -> [(String, String)] { counterSections[index].provider() }

    public func registerQuery(_ name: String, _ query: Query) { queries[name] = query }
    public func registerGrid(_ name: String, _ grid: UniformSpatialGrid) { grids[name] = grid }
    public func setClock(_ clock: SimulationClock?) { self.clock = clock }
    public func getClock() -> SimulationClock? { clock }
    public func getQueries() -> [String: Query] { queries }
    public func getGrids() -> [String: UniformSpatialGrid] { grids }
    public func getWorld() -> World? { world }
    public func getScheduler() -> Scheduler? { scheduler }

    /// Prints the full text report. Works in any mode except `.off`.
    public func printReport() {
        refreshNow()
        print(Report.text(recorder: recorder, stats: stats, world: world, findings: findings))
    }

    public func detach() {
        attached = false
        mode = .off
    }

    private func extras() -> Diagnostics.Extras {
        Diagnostics.Extras(clock: clock, queries: queries, grids: grids)
    }
}
