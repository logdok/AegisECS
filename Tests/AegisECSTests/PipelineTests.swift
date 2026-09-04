import XCTest
@testable import AegisECS

/// Appends its own name to a shared log every time it runs, so the tests can
/// assert on the exact execution order rather than on side effects.
final class RecordingSystem: System {
    let log: Log
    var setupCalls = 0
    var lastDelta: Float = -1

    final class Log { var entries: [String] = [] }

    init(_ log: Log, _ name: String, needsTime: Bool = false) {
        self.log = log
        super.init()
        systemName = name
        requiresTime = needsTime
        _ = completeAccessMetadata()
    }

    override func setup(world: World, context: Any?) { setupCalls += 1 }
    override func teardown() { log.entries.append("teardown:\(systemName)") }
    override func execute(delta: Float) { log.entries.append(systemName); lastDelta = delta }
}

final class PipelineTests: XCTestCase {
    private let oneFloat: [ColumnType] = [.float32]

    func testRegistrationOrderIsBehaviour() {
        let world = World(entityCapacity: 8)
        let scheduler = Scheduler()
        let log = RecordingSystem.Log()
        let first = RecordingSystem(log, "first")
        let second = RecordingSystem(log, "second")
        let third = RecordingSystem(log, "third")
        scheduler.addSystem(first); scheduler.addSystem(second); scheduler.addSystem(third)
        XCTAssertEqual(scheduler.systemCount, 3)
        _ = scheduler.addSystem(first)
        XCTAssertEqual(scheduler.systemCount, 3, "registering the same object twice is refused")

        scheduler.setupAll(world: world, context: nil)
        XCTAssertEqual(first.setupCalls, 1)
        XCTAssertEqual(third.setupCalls, 1, "setupAll reaches every system")

        scheduler.executeAll(delta: 1.0 / 60.0)
        XCTAssertEqual(log.entries, ["first", "second", "third"], "systems run in the order they were added")
        XCTAssertEqual(scheduler.findSystem("second"), 1)

        log.entries.removeAll()
        scheduler.teardownAll()
        XCTAssertEqual(log.entries, ["teardown:third", "teardown:second", "teardown:first"],
                       "teardown runs in reverse registration order")
    }

    func testPauseIsZeroStep() {
        let world = World(entityCapacity: 8)
        let scheduler = Scheduler()
        let log = RecordingSystem.Log()
        let always = RecordingSystem(log, "always", needsTime: false)
        let timed = RecordingSystem(log, "timed", needsTime: true)
        scheduler.addSystem(always); scheduler.addSystem(timed)
        scheduler.setupAll(world: world, context: nil)

        scheduler.executeAll(delta: 0)
        XCTAssertEqual(log.entries, ["always"], "a zero step skips systems that declared requiresTime")
        XCTAssertTrue(scheduler.wasSystemExecuted(0))
        XCTAssertFalse(scheduler.wasSystemExecuted(1))

        log.entries.removeAll()
        scheduler.executeAll(delta: 0.5)
        XCTAssertEqual(log.entries.count, 2, "both run again once time advances")
        XCTAssertEqual(timed.lastDelta, 0.5, "delta is passed through untouched")
    }

    func testSwitchesAndPhases() {
        let world = World(entityCapacity: 8)
        let scheduler = Scheduler()
        let log = RecordingSystem.Log()
        let simulation = RecordingSystem(log, "simulation")
        let presentation = RecordingSystem(log, "presentation")
        scheduler.addSystem(simulation, phase: 0)
        scheduler.addSystem(presentation, phase: 1)
        scheduler.setupAll(world: world, context: nil)

        scheduler.setSystemEnabled(0, false)
        scheduler.executeAll(delta: 0.016)
        XCTAssertEqual(log.entries, ["presentation"], "a disabled system is skipped")
        XCTAssertEqual(scheduler.getTimingUsec(0), 0, "and reports no time")
        scheduler.setSystemEnabled(0, true)

        log.entries.removeAll()
        scheduler.setPhaseEnabled(1, false)
        scheduler.executeAll(delta: 0.016)
        XCTAssertEqual(log.entries, ["simulation"], "a disabled phase is skipped")
        XCTAssertTrue(scheduler.isSystemEnabled(1))
        XCTAssertFalse(scheduler.isPhaseAllowed(1), "the system's own switch and its phase are reported separately")
        scheduler.setPhaseEnabled(1, true)

        log.entries.removeAll()
        scheduler.beginFrame()
        scheduler.executePhase(1, delta: 0.016)
        XCTAssertEqual(log.entries, ["presentation"], "a single phase can run alone")
        XCTAssertTrue(scheduler.validatePipeline(world: world, reportErrors: false))
    }

    func testReaperSystem() {
        let world = World(entityCapacity: 16)
        let store = PackedStore(schema: oneFloat)
        world.registerStore(store, typeID: 0)
        for _ in 0..<16 { store.attach(world.createEntity()) }

        let scheduler = Scheduler()
        let reaper = ReaperSystem(world: world, name: "Reaper")
        scheduler.addSystem(reaper)
        scheduler.setupAll(world: world, context: nil)

        _ = world.queueDestroy(3)
        _ = world.queueDestroy(9)
        XCTAssertEqual(store.count, 16, "nothing is removed before the reaper runs")
        scheduler.executeAll(delta: 1.0 / 60.0)
        XCTAssertEqual(reaper.lastReaped, 2)
        XCTAssertEqual(store.count, 14, "and the store really lost them")
        XCTAssertEqual(reaper.totalReaped, 2)

        _ = world.queueDestroy(4)
        scheduler.executeAll(delta: 0)
        XCTAssertEqual(reaper.lastReaped, 1, "the reaper still runs while paused")
    }

    func testCapacityPolicySystem() {
        let world = World(entityCapacity: 16)
        let store = PackedStore(schema: oneFloat)
        world.registerStore(store, typeID: 0)

        let scheduler = Scheduler()
        let policy = CapacityPolicySystem(world: world, name: "CapacityPolicy")
        policy.growThreshold = 0.5
        policy.growthFactor = 2.0
        policy.checkIntervalFrames = 1
        var grownFrom: Int32 = 0
        var grownTo: Int32 = 0
        var grownCalls = 0
        policy.onCapacityGrown = { previous, next in grownFrom = previous; grownTo = next; grownCalls += 1 }
        scheduler.addSystem(policy)
        scheduler.setupAll(world: world, context: nil)

        for _ in 0..<4 { store.attach(world.createEntity()) }
        scheduler.executeAll(delta: 0.016)
        XCTAssertEqual(world.capacity, 16, "below the threshold nothing grows")

        for _ in 0..<6 { store.attach(world.createEntity()) }
        scheduler.executeAll(delta: 0.016)
        XCTAssertEqual(world.capacity, 32, "crossing the threshold grows the world")
        XCTAssertEqual(grownCalls, 1)
        XCTAssertEqual(grownFrom, 16)
        XCTAssertEqual(grownTo, 32, "the callback reports the old and new capacity")
        XCTAssertEqual(store.capacity, 32, "the store grew with it")
        XCTAssertTrue(world.validateIntegrity(reportErrors: false))

        policy.maximumCapacity = 32
        XCTAssertFalse(policy.growNow(), "the hard ceiling stops further growth")
    }

    func testViewSmallestStoreDrives() {
        let world = World(entityCapacity: 64)
        let big = PackedStore(schema: oneFloat)
        let few = TagStore()
        world.registerStore(big, typeID: 0)
        world.registerStore(few, typeID: 1)
        for i in 0..<64 {
            let e = world.createEntity()
            big.attach(e)
            if i < 4 { few.attach(e) }
        }

        let view = View()
        XCTAssertTrue(view.configure(world: world, required: [0, 1]))
        XCTAssertTrue(view.candidateStore === few, "the smallest required store is chosen to drive")
        XCTAssertEqual(view.candidateCount, 4, "so only four candidates are walked, not 64")
        XCTAssertTrue(view.matches(0))
        XCTAssertFalse(view.matches(10))

        let broken = View()
        XCTAssertFalse(broken.configure(world: world, required: [0, 7]), "an unregistered type is refused")
    }

    func testQueryMaterialisedCache() {
        let world = World(entityCapacity: 100)
        let a = PackedStore(schema: oneFloat)
        let b = PackedStore(schema: oneFloat)
        let excluded = TagStore()
        world.registerStore(a, typeID: 0)
        world.registerStore(b, typeID: 1)
        world.registerStore(excluded, typeID: 2)
        for i in 0..<100 {
            let e = world.createEntity()
            a.attach(e); b.attach(e)
            if i % 5 == 0 { excluded.attach(e) }
        }

        let query = Query()
        XCTAssertTrue(query.configure(world: world, required: [0, 1], excluded: [2]))
        XCTAssertTrue(query.refresh(), "the first refresh rebuilds")
        XCTAssertEqual(query.count, 80, "the intersection excludes every fifth entity")
        XCTAssertFalse(query.refresh(), "an unchanged set is a cache hit, not a rebuild")
        XCTAssertEqual(query.rebuildCountValue, 1)

        a.detach(a.denseEntities[Int(a.count) - 1])
        XCTAssertTrue(query.refresh(), "a membership change invalidates the cache")
        XCTAssertEqual(query.rebuildCountValue, 2)

        var allValid = true
        query.withEntities { buf in
            for i in 0..<Int(query.count) {
                let e = buf[i]
                if !a.has(e) || !b.has(e) || excluded.has(e) { allValid = false }
            }
        }
        XCTAssertTrue(allValid, "every entity in the result satisfies required and excluded")

        let capped = Query()
        XCTAssertTrue(capped.configure(world: world, required: [0, 1], maximumResults: 10))
        capped.refresh()
        XCTAssertEqual(capped.count, 10)
        XCTAssertTrue(capped.isTruncated, "the cap is honoured and reported as truncation")
        XCTAssertFalse(capped.configure(world: world, required: [0, 1], maximumResults: 0), "a zero cap is rejected")
    }
}
