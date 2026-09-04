import XCTest
@testable import AegisECS

/// A system that burns a controllable amount of wall time, so the recorder and
/// stats have something real to measure.
private final class BurnSystem: System {
    var microseconds: Double = 0
    init(_ name: String) { super.init(); systemName = name; _ = completeAccessMetadata() }
    override func execute(delta: Float) {
        guard microseconds > 0 else { return }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(microseconds * 1000)
        while DispatchTime.now().uptimeNanoseconds < deadline { _ = sin(Double.random(in: 0...1)) }
    }
}

final class DebugTests: XCTestCase {
    func testRecorderAndStats() {
        let world = World(entityCapacity: 64)
        let scheduler = Scheduler()
        let steady = BurnSystem("steady")
        let spiky = BurnSystem("spiky")
        scheduler.addSystem(steady)
        scheduler.addSystem(spiky)
        scheduler.setupAll(world: world, context: nil)

        let recorder = FrameRecorder()
        XCTAssertTrue(recorder.configure(scheduler: scheduler, world: world, frames: 120))

        steady.microseconds = 40
        for frame in 0..<120 {
            // spiky is cheap most frames, expensive on a few — the shape spike
            // attribution is meant to catch.
            spiky.microseconds = (frame % 25 == 0) ? 400 : 5
            scheduler.executeAll(delta: 1.0 / 60.0)
            recorder.capture()
        }
        XCTAssertEqual(recorder.frameCount, 120, "the window filled")
        XCTAssertGreaterThan(recorder.framesSeenCount, 0)

        let stats = FrameStats()
        XCTAssertTrue(stats.analyse(recorder))
        XCTAssertEqual(stats.systemCount, 2)

        let steadyIdx = 0, spikyIdx = 1
        XCTAssertGreaterThan(stats.systemMedianUsec(steadyIdx), 0, "the steady system has a real median")
        XCTAssertGreaterThan(stats.systemVolatility(spikyIdx), stats.systemVolatility(steadyIdx),
                             "the spiky system is measurably more volatile")
        // The spiky system should own the lion's share of slow-frame excess.
        XCTAssertEqual(stats.spikeContributor(0), spikyIdx, "spike attribution blames the bursty system, not the steady one")
        XCTAssertGreaterThan(stats.systemExcessShare(spikyIdx), 50, "and by a clear margin")
    }

    func testDiagnosticsRules() {
        // A world filled to the brim must produce the capacity-exhausted
        // finding — the exact rule vcr's panel surfaced.
        let world = World(entityCapacity: 8)
        let store = PackedStore(schema: [.float32])
        store.debugName = "Particles"
        world.registerStore(store, typeID: 0)
        for _ in 0..<8 { store.attach(world.createEntity()) }

        let diag = Diagnostics()
        let findings = diag.inspect(recorder: nil, stats: nil, world: world)
        XCTAssertTrue(findings.contains { $0.source == "World" && $0.title == "Entity capacity exhausted" })
        XCTAssertTrue(findings.contains { $0.source == "Store" && $0.title == "'Particles' is full" })
        XCTAssertEqual(findings.first?.severity, .critical, "the worst finding sorts first")
    }

    func testInspectorFacade() {
        let world = World(entityCapacity: 32)
        let scheduler = Scheduler()
        scheduler.addSystem(BurnSystem("only"))
        scheduler.setupAll(world: world, context: nil)

        var opts = Inspector.Options()
        opts.mode = .dev
        opts.budgetUsec = 16_600
        let inspector = Inspector.attach(scheduler: scheduler, world: world, options: opts)
        inspector.addCounterSection("Room") { [("particles", "\(world.getLiveCount())")] }

        for _ in 0..<10 {
            scheduler.executeAll(delta: 1.0 / 60.0)
            inspector.capture()
        }
        inspector.refreshNow()
        XCTAssertEqual(inspector.counterSectionCount, 1)
        XCTAssertEqual(inspector.counterSectionTitle(0), "Room")
        XCTAssertFalse(Report.text(recorder: inspector.recorder, stats: inspector.stats,
                                   world: world, findings: inspector.getFindings()).isEmpty)
        inspector.detach()
        XCTAssertEqual(inspector.mode, .off)
    }
}
