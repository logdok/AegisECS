import XCTest
@testable import AegisECS

/// Ported from the addon's GDScript self-tests via the C++ port. These pin the
/// behaviour that must match, including the parts that look like quirks.
final class WorldTests: XCTestCase {
    private let oneFloat: [ColumnType] = [.float32]

    func testAllocation() {
        let world = World(entityCapacity: 4)
        XCTAssertEqual(world.capacity, 4, "capacity is what was asked for")
        XCTAssertEqual(world.getFreeCount(), 4, "every id starts free")
        // The free list is filled descending so ids come out ascending.
        XCTAssertEqual(world.createEntity(), 0)
        XCTAssertEqual(world.createEntity(), 1, "ids are handed out ascending")
        _ = world.createEntity(); _ = world.createEntity()
        XCTAssertEqual(world.createEntity(), kInvalidEntity, "a full world reports exhaustion, not a crash")
        XCTAssertEqual(world.getLiveCount(), 4, "live count tracks creation")
    }

    func testBatchCreationMatchesOneAtATime() {
        let sequential = World(entityCapacity: 8)
        var expected: [Entity] = []
        for _ in 0..<8 { expected.append(sequential.createEntity()) }

        let batched = World(entityCapacity: 8)
        var actual = [Entity](repeating: kInvalidEntity, count: 8)
        let made = batched.createEntities(8, into: &actual)
        XCTAssertEqual(made, 8, "createEntities reports what it created")
        XCTAssertEqual(actual, expected, "batch creation hands out the same ids in the same order")

        var overflow = [Entity](repeating: kInvalidEntity, count: 4)
        let small = World(entityCapacity: 2)
        XCTAssertEqual(small.createEntities(4, into: &overflow), 2, "createEntities stops at the free count")
    }

    func testDeferredDestruction() {
        let world = World(entityCapacity: 8)
        let store = PackedStore(schema: oneFloat)
        XCTAssertTrue(world.registerStore(store, typeID: 0), "store registers before the first entity")
        var entities: [Entity] = []
        for _ in 0..<8 {
            let e = world.createEntity()
            entities.append(e)
            store.attach(e)
        }
        XCTAssertFalse(world.registerStore(store, typeID: 1), "the schema locks once entities exist")

        XCTAssertTrue(world.queueDestroy(entities[2]), "queueDestroy marks an entity")
        XCTAssertFalse(world.queueDestroy(entities[2]), "queueDestroy is idempotent")
        XCTAssertTrue(world.isPendingDestroy(entities[2]), "the mark is visible before the flush")
        XCTAssertTrue(world.isAlive(entities[2]), "marking does not destroy anything by itself")
        XCTAssertEqual(store.count, 8, "and does not touch the stores")

        XCTAssertEqual(world.flushDestroyQueue(), 1, "the flush destroys exactly what was queued")
        XCTAssertFalse(world.isAlive(entities[2]), "the entity is gone after the flush")
        XCTAssertEqual(store.count, 7, "the store lost its component too")
        XCTAssertEqual(world.getLiveCount(), 7)
        XCTAssertEqual(world.getFreeCount(), 1, "live and free counts stay in step")
        XCTAssertEqual(world.flushDestroyQueue(), 0, "an empty flush is safe to repeat")
        XCTAssertTrue(world.validateIntegrity(reportErrors: false), "the world is internally consistent")
    }

    func testGenerationalHandles() {
        let world = World(entityCapacity: 4)
        let entity = world.createEntity()
        let handle = world.makeHandle(entity)
        XCTAssertNotEqual(handle, kInvalidHandle, "a live entity yields a handle")
        XCTAssertEqual(world.entityFromHandle(handle), entity, "the handle resolves back")
        XCTAssertTrue(world.isHandleAlive(handle))

        _ = world.queueDestroy(entity)
        XCTAssertTrue(world.isHandlePendingDestroy(handle), "a handle sees the pending destroy")
        _ = world.flushDestroyQueue()
        XCTAssertEqual(world.entityFromHandle(handle), kInvalidEntity, "the handle goes stale once the entity dies")

        let recycled = world.createEntity()
        XCTAssertEqual(recycled, entity, "the raw id really is reused")
        XCTAssertEqual(world.entityFromHandle(handle), kInvalidEntity, "a recycled id does not resurrect the old handle")
        XCTAssertNotEqual(world.makeHandle(recycled), handle, "the new handle differs from the old one")

        let other = World(entityCapacity: 4)
        _ = other.createEntity()
        XCTAssertEqual(other.entityFromHandle(world.makeHandle(recycled)), kInvalidEntity,
                       "a handle from another world never resolves here")
    }

    func testCapacityGrowth() {
        let world = World(entityCapacity: 4)
        let store = PackedStore(schema: oneFloat)
        world.registerStore(store, typeID: 0)
        var entities: [Entity] = []
        for i in 0..<4 {
            let e = world.createEntity()
            entities.append(e)
            store.attach(e)
            store.columnF32(0)![Int(store.indexOf(e))] = Float(i) + 0.5
        }
        let before = world.makeHandle(entities[1])

        XCTAssertFalse(world.reserveCapacity(4), "growing to the current capacity is a no-op")
        XCTAssertTrue(world.reserveCapacity(16), "the world grows when every store can")
        XCTAssertEqual(world.capacity, 16)
        XCTAssertEqual(store.capacity, 16, "world and store capacities stay equal")
        XCTAssertEqual(world.entityFromHandle(before), entities[1], "handles survive growth")
        XCTAssertEqual(store.columnF32(0)![Int(store.indexOf(entities[1]))], 1.5, "payload survives growth")
        XCTAssertEqual(world.getFreeCount(), 12, "the new ids joined the free list")
        XCTAssertNotEqual(world.createEntity(), kInvalidEntity, "the grown world can create again")
        XCTAssertTrue(world.validateIntegrity(reportErrors: false))
    }

    func testReset() {
        let world = World(entityCapacity: 4)
        let store = PackedStore(schema: oneFloat)
        world.registerStore(store, typeID: 0)
        let entity = world.createEntity()
        store.attach(entity)
        let handle = world.makeHandle(entity)

        world.reset()
        XCTAssertEqual(world.getLiveCount(), 0, "reset kills every entity")
        XCTAssertEqual(world.getFreeCount(), 4, "and returns every id to the free list")
        XCTAssertEqual(store.count, 0, "and clears every store")
        XCTAssertEqual(world.entityFromHandle(handle), kInvalidEntity, "a handle taken before the reset does not survive it")
        XCTAssertTrue(world.validateIntegrity(reportErrors: false))
    }
}
