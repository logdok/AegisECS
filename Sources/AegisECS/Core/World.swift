import Foundation

/// Entity allocator and component-store registry. Port of `EcsWorld`.
///
/// An entity is just an integer index. It holds no data of its own: the data
/// lives in component stores, and the entity is only the key they are indexed
/// by.
///
/// The world does not grow by itself. Capacity is fixed at construction and the
/// rare explicit growth goes through `reserveCapacity()` at a loading barrier.
///
/// **THE DESTRUCTION MODEL IS THE MOST IMPORTANT THING HERE.** Nothing is ever
/// destroyed in place. `queueDestroy()` only MARKS an entity; the real removal
/// happens in `flushDestroyQueue()`, which must run at ONE known point in the
/// frame — normally from the last system in the pipeline (`ReaperSystem`).
///
/// Why: if destruction were immediate, system A could read entity E and hold
/// its dense slot, system B could destroy E, and swap-remove would hand that
/// slot to a DIFFERENT entity. A would then read someone else's data — a
/// use-after-free that never crashes and silently returns wrong values.
public final class World {
    /// World tags are handed out process-wide so a handle minted by one world
    /// can never resolve in another.
    nonisolated(unsafe) private static var nextWorldTag: Int32 = 1

    public private(set) var capacity: Int32 = 0

    /// Monotonic diagnostic counter of creation, destruction, reset, store
    /// registration and explicit capacity growth.
    public private(set) var structuralVersion: Int64 = 0

    private var alive = ContiguousArray<UInt8>()
    private var freeIDs = ContiguousArray<Int32>()
    private var freeCount: Int32 = 0
    private var liveCount: Int32 = 0

    private var stores: [ComponentStore] = []
    private var storesByType: [Int32: ComponentStore] = [:]
    private var schemaLocked = false

    // The destroy queue carries a generation stamp beside each raw id so a
    // stale entry cannot resurrect an already-recycled slot.
    private var destroyQueue = ContiguousArray<Int32>()
    private var destroyGeneration = ContiguousArray<Int32>()
    private var destroyFlag = ContiguousArray<UInt8>()
    private var destroyCount: Int32 = 0
    private var generations = ContiguousArray<Int32>()
    private var retired = ContiguousArray<UInt8>()
    private var retiredCount: Int32 = 0
    private var worldTag: Int32 = 0

    /// `entityCapacity` is the number of simultaneously live entities. Buffers
    /// are allocated up front; there is no automatic growth in the hot path.
    public init(entityCapacity: Int32) {
        if entityCapacity < 1 || entityCapacity > kMaximumCapacity {
            AegisDiagnostics.report(
                "World: initial capacity \(entityCapacity) outside 1..\(kMaximumCapacity); "
                + "created a safe world of capacity 1")
            capacity = 1
        } else {
            capacity = entityCapacity
        }
        if World.nextWorldTag > Int32(kHandleWorldMask) {
            AegisDiagnostics.report("World: world tags exhausted in this process; handles unavailable")
            worldTag = 0
        } else {
            worldTag = World.nextWorldTag
            World.nextWorldTag += 1
        }
        let n = Int(capacity)
        alive = ContiguousArray(repeating: 0, count: n)
        freeIDs = ContiguousArray(repeating: 0, count: n)
        destroyQueue = ContiguousArray(repeating: 0, count: n)
        destroyGeneration = ContiguousArray(repeating: 0, count: n)
        destroyFlag = ContiguousArray(repeating: 0, count: n)
        generations = ContiguousArray(repeating: 0, count: n)
        retired = ContiguousArray(repeating: 0, count: n)
        reset()
    }

    // --- stores ------------------------------------------------------------

    /// Registers a store under `typeID` and initialises it. The world does not
    /// take ownership. Every store must be registered exactly once, before the
    /// first entity is created.
    @discardableResult
    public func registerStore(_ store: ComponentStore, typeID: Int32) -> Bool {
        if schemaLocked {
            AegisDiagnostics.report("World: schema locked by the first createEntity(); register stores earlier")
            return false
        }
        if storesByType[typeID] != nil {
            AegisDiagnostics.report("World: component type \(typeID) is already registered")
            return false
        }
        if stores.contains(where: { $0 === store }) || store.isInitialized {
            AegisDiagnostics.report("World: store is already registered under another type or in another world")
            return false
        }
        if !store.initialize(typeID: typeID, capacity: capacity, ownerWorld: self) { return false }
        stores.append(store)
        storesByType[typeID] = store
        structuralVersion += 1
        return true
    }

    /// Registered store for a type id, or nil. Meant for world building,
    /// debugging and tools — a system's hot loop should hold a typed reference.
    public func getStore(_ typeID: Int32) -> ComponentStore? { storesByType[typeID] }
    public func hasStore(_ typeID: Int32) -> Bool { storesByType[typeID] != nil }
    public var storeCount: Int32 { Int32(stores.count) }
    public func getStore(at index: Int32) -> ComponentStore? {
        guard index >= 0 && index < Int32(stores.count) else { return nil }
        return stores[Int(index)]
    }
    public var isSchemaLocked: Bool { schemaLocked }

    /// Clears the change log of every registered store that has one enabled.
    public func clearChangeLogs() {
        for store in stores where store.trackChanges { store.clearChangeLog() }
    }

    // --- creation --------------------------------------------------------

    /// Allocates an entity id, or -1 when the world is full. Callers must check
    /// rather than assume creation succeeds.
    @discardableResult
    public func createEntity() -> Entity {
        if freeCount == 0 { return kInvalidEntity }
        schemaLocked = true
        freeCount -= 1
        let entity = freeIDs[Int(freeCount)]
        alive[Int(entity)] = 1
        liveCount += 1
        structuralVersion += 1
        return entity
    }

    /// Allocates up to `entityCount` entities in one pass, writing their ids
    /// into `out`, and returns how many were actually created.
    @discardableResult
    public func createEntities(_ entityCount: Int32, into out: UnsafeMutablePointer<Entity>, capacity outCapacity: Int32) -> Int32 {
        if entityCount <= 0 { return 0 }
        var available = min(entityCount, freeCount)
        if available > outCapacity {
            AegisDiagnostics.report("World: createEntities() output buffer holds \(outCapacity) but \(available) were needed")
            available = outCapacity
        }
        if available <= 0 { return 0 }
        schemaLocked = true
        var fc = freeCount
        alive.withUnsafeMutableBufferPointer { a in
            freeIDs.withUnsafeBufferPointer { f in
                for i in 0..<Int(available) {
                    fc -= 1
                    let entity = f[Int(fc)]
                    a[Int(entity)] = 1
                    out[i] = entity
                }
            }
        }
        freeCount = fc
        liveCount += available
        structuralVersion += 1
        return available
    }

    @discardableResult
    public func createEntities(_ entityCount: Int32, into out: inout [Entity]) -> Int32 {
        out.withUnsafeMutableBufferPointer { createEntities(entityCount, into: $0.baseAddress!, capacity: Int32($0.count)) }
    }

    /// Creates an entity and returns a handle safe to hold across frames.
    public func createEntityHandle() -> Handle {
        if worldTag == 0 { return kInvalidHandle }
        let entity = createEntity()
        return entity >= 0 ? makeHandle(entity) : kInvalidHandle
    }

    // --- handles --------------------------------------------------------

    /// Packs a raw id and its current generation into a positive 64-bit value.
    /// Returns `kInvalidHandle` when the entity is not alive.
    public func makeHandle(_ entity: Entity) -> Handle {
        if worldTag == 0 || !isAlive(entity) { return kInvalidHandle }
        return (Handle(worldTag) << kHandleWorldShift)
            | (Handle(generations[Int(entity)]) << kHandleGenerationShift)
            | Handle(entity)
    }

    /// Resolves a handle to its current raw id, or `kInvalidEntity` when stale.
    public func entityFromHandle(_ handle: Handle) -> Entity {
        if handle <= kInvalidHandle || worldTag == 0 { return kInvalidEntity }
        let tag = Int32((handle >> kHandleWorldShift) & kHandleWorldMask)
        if tag != worldTag { return kInvalidEntity }
        let entity = Entity(handle & kHandleEntityMask)
        if entity < 0 || entity >= capacity || alive[Int(entity)] == 0 { return kInvalidEntity }
        let generation = Int32((handle >> kHandleGenerationShift) & kHandleGenerationMask)
        if generation == 0 || generations[Int(entity)] != generation { return kInvalidEntity }
        return entity
    }

    public func isHandleAlive(_ handle: Handle) -> Bool { entityFromHandle(handle) != kInvalidEntity }

    @discardableResult
    public func queueDestroyHandle(_ handle: Handle) -> Bool {
        let entity = entityFromHandle(handle)
        if entity == kInvalidEntity { return false }
        return queueDestroy(entity)
    }

    public func isHandlePendingDestroy(_ handle: Handle) -> Bool {
        let entity = entityFromHandle(handle)
        return entity != kInvalidEntity && destroyFlag[Int(entity)] == 1
    }

    public func getGeneration(_ entity: Entity) -> Int32 {
        (entity < 0 || entity >= capacity) ? 0 : generations[Int(entity)]
    }

    public var tag: Int32 { worldTag }

    // --- destruction --------------------------------------------------

    public func isAlive(_ entity: Entity) -> Bool {
        (entity < 0 || entity >= capacity) ? false : alive[Int(entity)] == 1
    }

    /// Marks an entity for destruction. Does NOT remove it. Idempotent.
    @discardableResult
    public func queueDestroy(_ entity: Entity) -> Bool {
        if entity < 0 || entity >= capacity { return false }
        if alive[Int(entity)] == 0 || destroyFlag[Int(entity)] == 1 { return false }
        destroyFlag[Int(entity)] = 1
        destroyQueue[Int(destroyCount)] = entity
        destroyGeneration[Int(destroyCount)] = generations[Int(entity)]
        destroyCount += 1
        return true
    }

    /// Marks `entities` and returns how many were newly queued.
    @discardableResult
    public func queueDestroyMany(_ entities: UnsafePointer<Entity>, count entityCount: Int32) -> Int32 {
        if entityCount <= 0 { return 0 }
        var queued: Int32 = 0
        let limit = capacity
        var write = destroyCount
        alive.withUnsafeBufferPointer { a in
            destroyFlag.withUnsafeMutableBufferPointer { flags in
                destroyQueue.withUnsafeMutableBufferPointer { queue in
                    destroyGeneration.withUnsafeMutableBufferPointer { stamps in
                        generations.withUnsafeBufferPointer { gens in
                            for i in 0..<Int(entityCount) {
                                let entity = entities[i]
                                if entity < 0 || entity >= limit { continue }
                                if a[Int(entity)] == 0 || flags[Int(entity)] == 1 { continue }
                                flags[Int(entity)] = 1
                                queue[Int(write)] = entity
                                stamps[Int(write)] = gens[Int(entity)]
                                write += 1
                                queued += 1
                            }
                        }
                    }
                }
            }
        }
        destroyCount = write
        return queued
    }

    @discardableResult
    public func queueDestroyMany(_ entities: [Entity], count entityCount: Int32) -> Int32 {
        entities.withUnsafeBufferPointer { queueDestroyMany($0.baseAddress!, count: entityCount) }
    }

    public func isPendingDestroy(_ entity: Entity) -> Bool {
        entity >= 0 && entity < capacity && destroyFlag[Int(entity)] == 1
    }

    /// Performs the REAL destruction of everything in the queue and returns how
    /// many entities were destroyed. This is a structural sync point.
    ///
    /// The loop runs over stores, not entities: with a dozen stores most
    /// entities lack most components, and it is the "no such component" path
    /// that decides the total cost.
    @discardableResult
    public func flushDestroyQueue() -> Int32 {
        let queued = destroyCount
        destroyCount = 0
        if queued == 0 { return 0 }

        var reaped: Int32 = 0
        destroyQueue.withUnsafeMutableBufferPointer { queue in
            destroyGeneration.withUnsafeBufferPointer { stamps in
                destroyFlag.withUnsafeMutableBufferPointer { flags in
                    generations.withUnsafeBufferPointer { gens in
                        alive.withUnsafeBufferPointer { a in
                            for i in 0..<Int(queued) {
                                let entity = queue[i]
                                if entity < 0 || entity >= capacity || a[Int(entity)] == 0
                                    || stamps[i] == 0 || gens[Int(entity)] != stamps[i] {
                                    if entity >= 0 && entity < capacity { flags[Int(entity)] = 0 }
                                    continue
                                }
                                queue[Int(reaped)] = entity
                                reaped += 1
                            }
                        }
                    }
                }
            }
        }
        if reaped == 0 { return 0 }

        // Victim flags stay set for the whole pass so each store can pick the
        // cheaper of the two traversals. The store wins while it is not much
        // larger than the victim list; past roughly twice the size the extra
        // iterations outweigh the saved moves.
        let flaggedLimit = reaped * 2
        destroyFlag.withUnsafeBufferPointer { flags in
            destroyQueue.withUnsafeBufferPointer { queue in
                for store in stores {
                    let held = store.count
                    if held == 0 { continue }
                    if held <= flaggedLimit {
                        _ = store.detachFlagged(flags.baseAddress!)
                    } else {
                        _ = store.detachMany(queue.baseAddress!, count: reaped)
                    }
                }
            }
        }

        var fc = freeCount
        var rc = retiredCount
        destroyQueue.withUnsafeBufferPointer { queue in
            alive.withUnsafeMutableBufferPointer { a in
                destroyFlag.withUnsafeMutableBufferPointer { flags in
                    generations.withUnsafeMutableBufferPointer { gens in
                        retired.withUnsafeMutableBufferPointer { ret in
                            freeIDs.withUnsafeMutableBufferPointer { free in
                                for i in 0..<Int(reaped) {
                                    let entity = queue[i]
                                    a[Int(entity)] = 0
                                    flags[Int(entity)] = 0
                                    let next = nextGeneration(gens[Int(entity)])
                                    if next == 0 {
                                        ret[Int(entity)] = 1
                                        rc += 1
                                    } else {
                                        gens[Int(entity)] = next
                                        free[Int(fc)] = entity
                                        fc += 1
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        freeCount = fc
        retiredCount = rc
        liveCount -= reaped
        structuralVersion += 1
        return reaped
    }

    // --- counters -------------------------------------------------------

    public func getLiveCount() -> Int32 { liveCount }
    public func getFreeCount() -> Int32 { freeCount }
    public func getRetiredCount() -> Int32 { retiredCount }
    public func getPendingDestroyCount() -> Int32 { destroyCount }

    /// Fraction of the world occupied by live entities, in `0...1`.
    public func getLoadFactor() -> Float { Float(liveCount) / Float(capacity) }

    // --- capacity and reset -------------------------------------------

    /// Explicitly grows every world and store buffer. Existing raw ids, handles
    /// and dense slots stay valid. This allocates: call it only at a safe
    /// loading barrier, never during a system pass. Returns false, having
    /// touched nothing, when any registered store cannot grow.
    @discardableResult
    public func reserveCapacity(_ entityCapacity: Int32) -> Bool {
        if entityCapacity <= capacity { return false }
        if entityCapacity > kMaximumCapacity {
            AegisDiagnostics.report("World: capacity exceeds what the handle layout can address")
            return false
        }
        for store in stores {
            if store.capacity != capacity || !store.canGrowCapacity(to: entityCapacity, from: self) {
                AegisDiagnostics.report(
                    "World: store of type \(store.typeID) cannot safely grow to \(entityCapacity) — it needs the growDense hook")
                return false
            }
        }
        let previous = capacity
        let n = Int(entityCapacity)
        func grow(_ arr: inout ContiguousArray<UInt8>) { while arr.count < n { arr.append(0) } }
        func grow(_ arr: inout ContiguousArray<Int32>) { while arr.count < n { arr.append(0) } }
        grow(&alive); grow(&freeIDs); grow(&destroyQueue); grow(&destroyGeneration)
        grow(&destroyFlag); grow(&generations); grow(&retired)
        for entity in Int(previous)..<n {
            alive[entity] = 0
            destroyFlag[entity] = 0
            generations[entity] = 1
            retired[entity] = 0
            freeIDs[Int(freeCount)] = Int32(entity)
            freeCount += 1
        }
        for store in stores { store.commitCapacityGrowth(to: entityCapacity) }
        capacity = entityCapacity
        structuralVersion += 1
        return true
    }

    /// Fully resets the world without allocating: every entity dies and every
    /// store is cleared, but the buffers are reused. Store registrations
    /// survive, so `registerStore()` must not be called again.
    public func reset() {
        destroyCount = 0
        freeCount = 0
        retiredCount = 0
        // The free list is filled descending so ids come out ascending (LIFO).
        // A slot whose generation is exhausted stays retired forever.
        for i in 0..<Int(capacity) {
            let entity = Int(capacity) - 1 - i
            if retired[entity] == 1 { retiredCount += 1; continue }
            if generations[entity] == 0 {
                generations[entity] = 1
            } else if alive[entity] == 1 {
                let next = nextGeneration(generations[entity])
                if next == 0 {
                    alive[entity] = 0
                    destroyFlag[entity] = 0
                    retired[entity] = 1
                    retiredCount += 1
                    continue
                }
                generations[entity] = next
            }
            alive[entity] = 0
            destroyFlag[entity] = 0
            freeIDs[Int(freeCount)] = Int32(entity)
            freeCount += 1
        }
        liveCount = 0
        for store in stores { store.clear() }
        structuralVersion += 1
    }

    /// Expensive development-time check of the allocator, the destroy queue and
    /// every sparse set. Never call it from a production frame.
    @discardableResult
    public func validateIntegrity(reportErrors: Bool = true) -> Bool {
        var valid = true
        let n = Int(capacity)
        if alive.count != n || freeIDs.count != n || destroyQueue.count != n
            || destroyGeneration.count != n || destroyFlag.count != n
            || generations.count != n || retired.count != n {
            if reportErrors { AegisDiagnostics.report("World: lifecycle buffer sizes do not match capacity") }
            return false
        }
        if liveCount < 0 || freeCount < 0 || retiredCount < 0
            || liveCount + freeCount + retiredCount != capacity {
            valid = false
            if reportErrors { AegisDiagnostics.report("World: live/free/retired counters do not add up to capacity") }
        }
        if destroyCount < 0 || destroyCount > capacity {
            valid = false
            if reportErrors { AegisDiagnostics.report("World: destroyCount outside capacity") }
        }

        var freeSeen = [UInt8](repeating: 0, count: n)
        for index in 0..<Int(min(max(freeCount, 0), capacity)) {
            let entity = freeIDs[index]
            if entity < 0 || entity >= capacity {
                valid = false
                if reportErrors { AegisDiagnostics.report("World: free list holds invalid entity \(entity)") }
                continue
            }
            if freeSeen[Int(entity)] == 1 || alive[Int(entity)] == 1 {
                valid = false
                if reportErrors { AegisDiagnostics.report("World: duplicate or live entity \(entity) in the free list") }
            }
            freeSeen[Int(entity)] = 1
        }

        var destroySeen = [UInt8](repeating: 0, count: n)
        for index in 0..<Int(min(max(destroyCount, 0), capacity)) {
            let entity = destroyQueue[index]
            if entity < 0 || entity >= capacity {
                valid = false
                if reportErrors { AegisDiagnostics.report("World: destroy queue holds invalid entity \(entity)") }
                continue
            }
            if destroySeen[Int(entity)] == 1 || alive[Int(entity)] == 0 || destroyFlag[Int(entity)] == 0 {
                valid = false
                if reportErrors { AegisDiagnostics.report("World: inconsistent entity \(entity) in the destroy queue") }
            }
            destroySeen[Int(entity)] = 1
        }

        var countedAlive: Int32 = 0
        for entity in 0..<n {
            if generations[entity] <= 0 {
                valid = false
                if reportErrors { AegisDiagnostics.report("World: zero generation on entity \(entity)") }
            }
            if alive[entity] == 1 {
                if retired[entity] == 1 {
                    valid = false
                    if reportErrors { AegisDiagnostics.report("World: retired entity \(entity) is marked alive") }
                }
                countedAlive += 1
            } else if freeSeen[entity] == 0 && retired[entity] == 0 {
                valid = false
                if reportErrors { AegisDiagnostics.report("World: dead entity \(entity) is missing from the free list") }
            }
            if destroyFlag[entity] != destroySeen[entity] {
                valid = false
                if reportErrors { AegisDiagnostics.report("World: destroy flag disagrees with the queue for entity \(entity)") }
            }
            if retired[entity] == 1 && freeSeen[entity] == 1 {
                valid = false
                if reportErrors { AegisDiagnostics.report("World: retired entity \(entity) is present in the free list") }
            }
        }
        if countedAlive != liveCount {
            valid = false
            if reportErrors { AegisDiagnostics.report("World: alive flags do not match liveCount") }
        }

        for store in stores {
            let ok = alive.withUnsafeBufferPointer {
                store.capacity == capacity && store.validateIntegrity(alive: $0.baseAddress, aliveSize: capacity, reportErrors: reportErrors)
            }
            if !ok { valid = false }
        }
        return valid
    }
}
