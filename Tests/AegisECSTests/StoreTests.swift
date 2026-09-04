import XCTest
@testable import AegisECS

/// Hand-written store in the classic shape: the two required overrides, plus a
/// relocation counter so the tests can assert on how much data actually moved.
final class CountingStore: ComponentStore {
    var values = ContiguousArray<Float>()
    var relocations = 0

    override var hooks: Hooks { [.growDense] }

    override func reserveDense(_ capacity: Int32) {
        values = ContiguousArray(repeating: 0, count: Int(capacity))
    }
    override func growDense(previousCapacity: Int32, newCapacity: Int32) {
        while values.count < Int(newCapacity) { values.append(0) }
    }
    override func relocateDense(from: Int32, to: Int32) {
        values[Int(to)] = values[Int(from)]
        relocations += 1
    }

    func snapshot() -> [(Entity, Float)] {
        (0..<Int(count)).map { (denseEntities[$0], values[$0]) }.sorted { $0.0 < $1.0 }
    }
}

final class StoreTests: XCTestCase {
    private let twoColumns: [ColumnType] = [.float32, .int32]

    func testSwapRemove() {
        let world = World(entityCapacity: 8)
        let store = CountingStore()
        world.registerStore(store, typeID: 0)
        var entities: [Entity] = []
        for i in 0..<4 {
            let e = world.createEntity()
            entities.append(e)
            let slot = store.attach(e)
            store.values[Int(slot)] = Float(i) * 10
        }
        XCTAssertEqual(store.attach(entities[0]), 0, "attach is idempotent and returns the same slot")
        XCTAssertEqual(store.count, 4, "an idempotent attach does not grow the store")

        // Remove from the middle: the LAST element must be moved into the hole.
        store.detach(entities[1])
        XCTAssertEqual(store.count, 3, "detach shrinks the dense array")
        XCTAssertFalse(store.has(entities[1]))
        XCTAssertEqual(store.indexOf(entities[3]), 1, "the last element took the freed slot")
        XCTAssertEqual(store.values[1], 30, "swap-remove carried the payload with it")
        XCTAssertTrue(store.validateIntegrity(alive: nil, aliveSize: 0, reportErrors: false))

        store.detach(entities[1])
        XCTAssertEqual(store.count, 3, "detaching what is not attached is a no-op")
    }

    func testBatchAttachIsContiguous() {
        let world = World(entityCapacity: 16)
        let store = CountingStore()
        world.registerStore(store, typeID: 0)
        var ids = [Entity](repeating: kInvalidEntity, count: 6)
        let made = world.createEntities(6, into: &ids)

        let first = store.count
        let attached = store.attachMany(ids, count: made)
        XCTAssertEqual(attached, 6)
        XCTAssertEqual(first, 0)
        for i in 0..<6 {
            XCTAssertEqual(store.indexOf(ids[i]), first + Int32(i), "new components occupy [old_count, old_count+attached) in order")
        }
        XCTAssertEqual(store.attachMany(ids, count: made), 0, "re-attaching the same entities adds none")
    }

    func testDetachManyMatchesRepeatedDetach() {
        var victims: [Entity] = []
        let refWorld = World(entityCapacity: 32)
        let reference = CountingStore()
        refWorld.registerStore(reference, typeID: 0)
        let batchWorld = World(entityCapacity: 32)
        let batched = CountingStore()
        batchWorld.registerStore(batched, typeID: 0)

        for i in 0..<32 {
            let a = refWorld.createEntity()
            reference.values[Int(reference.attach(a))] = Float(i)
            let b = batchWorld.createEntity()
            batched.values[Int(batched.attach(b))] = Float(i)
            if i % 3 == 0 { victims.append(a) }
        }

        for v in victims { reference.detach(v) }
        let removed = batched.detachMany(victims, count: Int32(victims.count))

        XCTAssertEqual(removed, Int32(victims.count), "detachMany removed every victim")
        XCTAssertEqual(reference.count, batched.count, "both paths leave the same number of components")
        XCTAssertEqual(reference.snapshot().map(\.0), batched.snapshot().map(\.0))
        XCTAssertEqual(reference.snapshot().map(\.1), batched.snapshot().map(\.1),
                       "both paths leave identical (entity, payload) contents")
    }

    func testDetachFlaggedMovesTheMinimum() {
        let world = World(entityCapacity: 64)
        let store = CountingStore()
        world.registerStore(store, typeID: 0)
        for _ in 0..<64 { store.attach(world.createEntity()) }

        // Wiping out the whole population must move nothing at all.
        for i in 0..<64 { _ = world.queueDestroy(Entity(i)) }
        store.relocations = 0
        let reaped = world.flushDestroyQueue()
        XCTAssertEqual(reaped, 64, "the whole population was reaped")
        XCTAssertEqual(store.count, 0, "the store is empty")
        XCTAssertEqual(store.relocations, 0, "destroying everything performs zero relocations")
    }

    func testFlushPicksCheaperTraversal() {
        let world = World(entityCapacity: 1024)
        let large = CountingStore()
        let small = CountingStore()
        world.registerStore(large, typeID: 0)
        world.registerStore(small, typeID: 1)
        var entities: [Entity] = []
        for i in 0..<1024 {
            let e = world.createEntity()
            entities.append(e)
            large.values[Int(large.attach(e))] = Float(i)
            if i < 8 { small.attach(e) }
        }
        for i in 0..<16 { _ = world.queueDestroy(entities[i]) }
        _ = world.flushDestroyQueue()

        XCTAssertEqual(large.count, 1008, "the large store lost exactly the victims it held")
        XCTAssertEqual(small.count, 0, "the small store lost the victims it held")
        XCTAssertTrue(world.validateIntegrity(reportErrors: false))
    }

    func testChangeLog() {
        let world = World(entityCapacity: 8)
        let store = CountingStore()
        world.registerStore(store, typeID: 0)
        store.trackChanges = true

        let a = world.createEntity()
        let b = world.createEntity()
        store.attach(a); store.attach(b)
        XCTAssertEqual(store.addedCount, 2, "attaches are logged")
        XCTAssertEqual(store.removedCount, 0)

        _ = world.queueDestroy(a)
        _ = world.flushDestroyQueue()
        XCTAssertEqual(store.removedCount, 1)
        XCTAssertEqual(store.removedEntities[0], a, "the reaped entity is logged as removed")

        store.clearChangeLog()
        XCTAssertEqual(store.addedCount, 0)
        XCTAssertEqual(store.removedCount, 0)

        store.clear()
        XCTAssertTrue(store.changeLogOverflowed, "a bulk clear raises the overflow flag")
    }

    func testTagStore() {
        let world = World(entityCapacity: 16)
        let tags = TagStore()
        world.registerStore(tags, typeID: 0)
        var entities: [Entity] = []
        for i in 0..<16 {
            let e = world.createEntity()
            entities.append(e)
            if i % 2 == 0 { tags.attach(e) }
        }
        XCTAssertEqual(tags.count, 8, "a tag stores membership and nothing else")
        XCTAssertTrue(tags.has(entities[0]))
        XCTAssertFalse(tags.has(entities[1]))

        let victims = [entities[0], entities[2]]
        XCTAssertEqual(tags.detachMany(victims, count: 2), 2, "the specialised batch removal works")
        XCTAssertEqual(tags.count, 6)
        XCTAssertTrue(tags.validateIntegrity(alive: nil, aliveSize: 0, reportErrors: false))
        XCTAssertTrue(tags.supportsCapacityGrowth, "a tag always survives capacity growth")
    }

    func testPackedStoreRelocationCoversEveryColumn() {
        let world = World(entityCapacity: 8)
        let store = PackedStore(schema: twoColumns)
        world.registerStore(store, typeID: 0)
        XCTAssertEqual(store.columnCount, 2, "the schema is what was declared")
        XCTAssertNil(store.columnF32(1), "a typed accessor refuses a mismatched column")
        XCTAssertNotNil(store.columnI32(1), "and accepts the right one")

        var entities: [Entity] = []
        for i in 0..<4 {
            let e = world.createEntity()
            entities.append(e)
            let slot = store.attach(e)
            store.columnF32(0)![Int(slot)] = Float(i) + 0.25
            store.columnI32(1)![Int(slot)] = Int32(i) * 100
        }

        store.detach(entities[0])
        let moved = store.indexOf(entities[3])
        XCTAssertEqual(moved, 0, "the tail moved into the freed slot")
        XCTAssertEqual(store.columnF32(0)![Int(moved)], 3.25, "column 0 was carried across")
        XCTAssertEqual(store.columnI32(1)![Int(moved)], 300, "column 1 was carried across too")

        let survivor = store.indexOf(entities[1])
        store.clearSlot(survivor)
        XCTAssertEqual(store.columnF32(0)![Int(survivor)], 0)
        XCTAssertEqual(store.columnI32(1)![Int(survivor)], 0, "clearSlot zeroes every column")
    }
}
