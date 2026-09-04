import Foundation

/// Abstract sparse-set component store. Port of `EcsComponentStore`.
///
/// Two parallel arrays map both ways:
///
///     sparseIndex[entity] -> dense slot, or -1 when the entity has none
///     denseEntities[slot] -> the entity owning that slot
///
/// The payload lives in the subclass, in arrays addressed by the SAME dense
/// slot. Removal is swap-remove, so the dense order is NOT stable and no system
/// may depend on it.
///
/// The hot fields are `public` on purpose, exactly as in the original: a system
/// takes them into locals once (`withUnsafeBufferPointer`) and indexes them
/// directly inside its loop.
open class ComponentStore {
    /// Optional hooks a subclass may implement.
    ///
    /// The original detected these with `has_method()`, which was exact because
    /// the base class did not declare them. Swift has no such reflection, so a
    /// subclass advertises them by overriding `hooks`. The property worth
    /// preserving is preserved: an unadvertised hook costs one bit test per
    /// operation, never a call.
    public struct Hooks: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        /// Enables `World.reserveCapacity()`.
        public static let growDense = Hooks(rawValue: 1 << 0)
        /// Batched swap-remove payload moves.
        public static let relocateBatch = Hooks(rawValue: 1 << 1)
        /// Store owns a resource per slot.
        public static let releaseDense = Hooks(rawValue: 1 << 2)
        /// Clear the duplicate left in the source slot.
        public static let clearRelocated = Hooks(rawValue: 1 << 3)
        /// Bulk teardown on `clear()`.
        public static let clearDense = Hooks(rawValue: 1 << 4)
    }

    /// Bitwise OR of the hooks this subclass implements.
    open var hooks: Hooks { [] }

    // --- hot-path data, public on purpose ----------------------------------

    public internal(set) var sparseIndex = ContiguousArray<Int32>()
    public internal(set) var denseEntities = ContiguousArray<Int32>()
    public internal(set) var count: Int32 = 0

    /// Bumped whenever membership or the dense layout changes. Writing payload
    /// does not touch it. `Query` uses it to skip rebuilding an unchanged set.
    public internal(set) var structuralVersion: Int64 = 0

    public internal(set) var typeID: Int32 = -1

    /// Optional human-readable name for tools. Empty falls back to "type N".
    public var debugName: String = ""

    // --- optional change log ---------------------------------------------------

    /// While enabled, every entity that gains the component is appended to
    /// `addedEntities` and every entity that loses it to `removedEntities`,
    /// until `clearChangeLog()`. Disabled it costs one branch per structural op.
    public var trackChanges: Bool = false {
        didSet {
            if trackChanges && addedEntities.isEmpty {
                addedEntities = ContiguousArray(repeating: 0, count: Int(Self.changeLogMinCapacity))
                removedEntities = ContiguousArray(repeating: 0, count: Int(Self.changeLogMinCapacity))
            }
        }
    }

    /// Valid prefix is `0..<addedCount`. Cleared by `clearChangeLog()`.
    public internal(set) var addedEntities = ContiguousArray<Int32>()
    public internal(set) var addedCount: Int32 = 0

    /// Valid prefix is `0..<removedCount`. Cleared by `clearChangeLog()`.
    public internal(set) var removedEntities = ContiguousArray<Int32>()
    public internal(set) var removedCount: Int32 = 0

    /// Raised when `clear()` or `World.reset()` emptied the store while the log
    /// was on. Individual removals are NOT logged in that case: a level restart
    /// would otherwise push the whole population through the log.
    public internal(set) var changeLogOverflowed = false

    // --- private state -------------------------------------------------------

    static let changeLogMinCapacity: Int32 = 64

    private(set) var capacityValue: Int32 = 0
    private(set) var initialized = false

    /// Identity only; never owned. A store must not keep its world alive.
    private weak var ownerWorld: World?

    /// Resolved once in `initialize()` so the hot paths test bits, not calls.
    private(set) var cachedHooks: Hooks = []

    private var moveFrom = ContiguousArray<Int32>()
    private var moveTo = ContiguousArray<Int32>()

    public init() {}

    // --- lifecycle -----------------------------------------------------------

    /// Called by `World.registerStore()`. Never call it directly.
    @discardableResult
    func initialize(typeID: Int32, capacity: Int32, ownerWorld: World) -> Bool {
        if initialized {
            AegisDiagnostics.report("ComponentStore: initialize() called twice")
            return false
        }
        self.typeID = typeID
        self.ownerWorld = ownerWorld
        self.capacityValue = capacity

        cachedHooks = hooks
        if cachedHooks.contains(.clearRelocated) && !cachedHooks.contains(.releaseDense) {
            AegisDiagnostics.report(
                "ComponentStore(type \(typeID)): clearRelocated without releaseDense — the source "
                + "slot will be cleared but the removed data will never be released")
        }

        sparseIndex = ContiguousArray(repeating: -1, count: Int(capacity))
        denseEntities = ContiguousArray(repeating: 0, count: Int(capacity))
        count = 0
        reserveDense(capacity)
        structuralVersion += 1
        initialized = true
        return true
    }

    /// True when the subclass advertises `growDense`, which is what makes it
    /// safe for `World.reserveCapacity()`.
    public var supportsCapacityGrowth: Bool { cachedHooks.contains(.growDense) }

    public var capacity: Int32 { capacityValue }

    func canGrowCapacity(to newCapacity: Int32, from world: World) -> Bool {
        ownerWorld === world && newCapacity > capacityValue && supportsCapacityGrowth
    }

    func commitCapacityGrowth(to newCapacity: Int32) {
        // World runs one complete pre-check before touching any buffer; this
        // commit deliberately does not re-check, so a stateful hook cannot
        // produce a partially applied transaction.
        let previous = capacityValue
        sparseIndex.reserveCapacity(Int(newCapacity))
        while sparseIndex.count < Int(newCapacity) { sparseIndex.append(-1) }
        denseEntities.reserveCapacity(Int(newCapacity))
        while denseEntities.count < Int(newCapacity) { denseEntities.append(0) }
        capacityValue = newCapacity
        growDense(previousCapacity: previous, newCapacity: newCapacity)
        structuralVersion += 1
    }

    // --- required overrides -------------------------------------------------

    /// **Required.** Size the subclass payload arrays to `capacity`.
    open func reserveDense(_ capacity: Int32) {
        fatalError("ComponentStore subclass must override reserveDense")
    }

    /// **Required.** Copy component DATA from one dense slot to another; the
    /// base class moves the entity ids itself. Forgetting a field here is the
    /// classic silent-corruption bug; `PackedStore` removes the possibility.
    open func relocateDense(from: Int32, to: Int32) {
        fatalError("ComponentStore subclass must override relocateDense")
    }

    // --- optional overrides -----------------------------------------------

    /// Advertise `.growDense`. `resize` must preserve the live prefix.
    open func growDense(previousCapacity: Int32, newCapacity: Int32) {}

    /// Advertise `.relocateBatch`. Applying moves in recorded order is exactly
    /// equivalent to interleaving them, but lets the subclass hoist its
    /// per-field array lookups out of the per-move loop.
    open func relocateDenseBatch(from: UnsafePointer<Int32>, to: UnsafePointer<Int32>, moveCount: Int32) {}

    /// Advertise `.releaseDense`. Free whatever the slot owns.
    open func releaseDense(_ slot: Int32) {}

    /// Advertise `.clearRelocated`. Clear the duplicate the move left in the
    /// source slot.
    open func clearRelocatedDense(_ slot: Int32) {}

    /// Advertise `.clearDense`. Bulk teardown for `clear()`.
    open func clearDense(activeCount: Int32) {}

    // --- structural operations --------------------------------------------

    /// Attaches the component and returns its dense slot. Idempotent: an entity
    /// that already has one gets the existing slot back. Returns -1 when
    /// capacity is exhausted or the id is out of range.
    @discardableResult
    public func attach(_ entity: Entity) -> Int32 {
        if entity < 0 || entity >= capacityValue {
            AegisDiagnostics.report("ComponentStore(type \(typeID)): entity \(entity) is outside capacity")
            return -1
        }
        let existing = sparseIndex[Int(entity)]
        if existing != -1 { return existing }
        if count >= capacityValue {
            AegisDiagnostics.report("ComponentStore(type \(typeID)): dense capacity exhausted")
            return -1
        }
        // A new slot is always appended to the END of the dense array — that is
        // what keeps it contiguous from 0 to count - 1.
        let slot = count
        sparseIndex[Int(entity)] = slot
        denseEntities[Int(slot)] = entity
        count = slot + 1
        structuralVersion += 1
        if trackChanges { pushAdded(entity) }
        return slot
    }

    /// Attaches to `entities` in one pass; returns how many gained the
    /// component for the first time. New components occupy dense slots
    /// `oldCount ..< oldCount + attached` in argument order.
    @discardableResult
    public func attachMany(_ entities: UnsafePointer<Entity>, count entityCount: Int32) -> Int32 {
        if entityCount <= 0 { return 0 }
        var live = self.count
        let limit = capacityValue
        var attached: Int32 = 0
        let logChanges = trackChanges
        if logChanges { reserveAdded(addedCount + entityCount) }
        var logged = addedCount

        sparseIndex.withUnsafeMutableBufferPointer { sparse in
            denseEntities.withUnsafeMutableBufferPointer { dense in
                addedEntities.withUnsafeMutableBufferPointer { log in
                    for i in 0..<Int(entityCount) {
                        let entity = entities[i]
                        if entity < 0 || entity >= limit {
                            AegisDiagnostics.report("ComponentStore(type \(typeID)): entity \(entity) is outside capacity")
                            continue
                        }
                        if sparse[Int(entity)] != -1 { continue }
                        if live >= limit {
                            AegisDiagnostics.report("ComponentStore(type \(typeID)): dense capacity exhausted")
                            break
                        }
                        sparse[Int(entity)] = live
                        dense[Int(live)] = entity
                        live += 1
                        attached += 1
                        if logChanges {
                            log[Int(logged)] = entity
                            logged += 1
                        }
                    }
                }
            }
        }

        count = live
        addedCount = logged
        if attached > 0 { structuralVersion += 1 }
        return attached
    }

    @discardableResult
    public func attachMany(_ entities: [Entity], count entityCount: Int32) -> Int32 {
        entities.withUnsafeBufferPointer { attachMany($0.baseAddress!, count: entityCount) }
    }

    /// Detaches the component. A no-op when the entity does not have one.
    ///
    /// SWAP-REMOVE: the last element is moved into the freed slot so the dense
    /// array keeps no holes and the tail is never shifted. O(1), at the price
    /// of an unstable dense order.
    public func detach(_ entity: Entity) {
        if entity < 0 || entity >= capacityValue { return }
        let slot = sparseIndex[Int(entity)]
        if slot == -1 { return }
        let last = count - 1
        if cachedHooks.contains(.releaseDense) { releaseDense(slot) }
        if slot != last {
            relocateDense(from: last, to: slot)
            if cachedHooks.contains(.clearRelocated) { clearRelocatedDense(last) }
            let moved = denseEntities[Int(last)]
            denseEntities[Int(slot)] = moved
            sparseIndex[Int(moved)] = slot
        }
        sparseIndex[Int(entity)] = -1
        count = last
        structuralVersion += 1
        if trackChanges { pushRemoved(entity) }
    }

    /// Detaches from `entities` in one pass; returns how many components were
    /// removed. Semantics are identical to calling `detach` for each in order.
    @discardableResult
    open func detachMany(_ entities: UnsafePointer<Entity>, count entityCount: Int32) -> Int32 {
        if entityCount <= 0 || count == 0 { return 0 }
        let limit = capacityValue
        var live = count
        var removed: Int32 = 0
        let logChanges = trackChanges
        if logChanges { reserveRemoved(removedCount + entityCount) }
        var logged = removedCount

        if cachedHooks.contains(.releaseDense) {
            // Owned data must be released BEFORE anything overwrites it, so the
            // moves stay interleaved with the mapping updates.
            let clearRelocated = cachedHooks.contains(.clearRelocated)
            sparseIndex.withUnsafeMutableBufferPointer { sparse in
                denseEntities.withUnsafeMutableBufferPointer { dense in
                    removedEntities.withUnsafeMutableBufferPointer { log in
                        for i in 0..<Int(entityCount) {
                            let entity = entities[i]
                            if entity < 0 || entity >= limit { continue }
                            let slot = sparse[Int(entity)]
                            if slot == -1 { continue }
                            live -= 1
                            releaseDense(slot)
                            if slot != live {
                                relocateDense(from: live, to: slot)
                                if clearRelocated { clearRelocatedDense(live) }
                                let moved = dense[Int(live)]
                                dense[Int(slot)] = moved
                                sparse[Int(moved)] = slot
                            }
                            sparse[Int(entity)] = -1
                            removed += 1
                            if logChanges { log[Int(logged)] = entity; logged += 1 }
                        }
                    }
                }
            }
        } else if cachedHooks.contains(.relocateBatch) {
            // No ownership hooks means nothing reads the payload during the
            // loop, so every move can be recorded and applied in one pass.
            reserveMoveScratch(entityCount)
            var moves: Int32 = 0
            sparseIndex.withUnsafeMutableBufferPointer { sparse in
                denseEntities.withUnsafeMutableBufferPointer { dense in
                    removedEntities.withUnsafeMutableBufferPointer { log in
                        moveFrom.withUnsafeMutableBufferPointer { mf in
                            moveTo.withUnsafeMutableBufferPointer { mt in
                                for i in 0..<Int(entityCount) {
                                    let entity = entities[i]
                                    if entity < 0 || entity >= limit { continue }
                                    let slot = sparse[Int(entity)]
                                    if slot == -1 { continue }
                                    live -= 1
                                    if slot != live {
                                        mf[Int(moves)] = live
                                        mt[Int(moves)] = slot
                                        moves += 1
                                        let moved = dense[Int(live)]
                                        dense[Int(slot)] = moved
                                        sparse[Int(moved)] = slot
                                    }
                                    sparse[Int(entity)] = -1
                                    removed += 1
                                    if logChanges { log[Int(logged)] = entity; logged += 1 }
                                }
                            }
                        }
                    }
                }
            }
            if moves > 0 {
                moveFrom.withUnsafeBufferPointer { mf in
                    moveTo.withUnsafeBufferPointer { mt in
                        relocateDenseBatch(from: mf.baseAddress!, to: mt.baseAddress!, moveCount: moves)
                    }
                }
            }
        } else {
            sparseIndex.withUnsafeMutableBufferPointer { sparse in
                denseEntities.withUnsafeMutableBufferPointer { dense in
                    removedEntities.withUnsafeMutableBufferPointer { log in
                        for i in 0..<Int(entityCount) {
                            let entity = entities[i]
                            if entity < 0 || entity >= limit { continue }
                            let slot = sparse[Int(entity)]
                            if slot == -1 { continue }
                            live -= 1
                            if slot != live {
                                relocateDense(from: live, to: slot)
                                let moved = dense[Int(live)]
                                dense[Int(slot)] = moved
                                sparse[Int(moved)] = slot
                            }
                            sparse[Int(entity)] = -1
                            removed += 1
                            if logChanges { log[Int(logged)] = entity; logged += 1 }
                        }
                    }
                }
            }
        }

        count = live
        removedCount = logged
        if removed > 0 { structuralVersion += 1 }
        return removed
    }

    @discardableResult
    public func detachMany(_ entities: [Entity], count entityCount: Int32) -> Int32 {
        entities.withUnsafeBufferPointer { detachMany($0.baseAddress!, count: entityCount) }
    }

    /// Detaches every entity whose byte in `flags` is non-zero; returns how
    /// many components were removed.
    ///
    /// Costs O(count) rather than O(victims), which is why
    /// `World.flushDestroyQueue()` picks whichever list is shorter. It also
    /// performs the theoretical minimum of moves: flagged elements are trimmed
    /// off the tail first, so destroying an entire population moves nothing.
    @discardableResult
    open func detachFlagged(_ flags: UnsafePointer<UInt8>) -> Int32 {
        if count == 0 { return 0 }
        var live = count
        var removed: Int32 = 0
        let owns = cachedHooks.contains(.releaseDense)
        let clearRelocated = cachedHooks.contains(.clearRelocated)
        let logChanges = trackChanges
        if logChanges { reserveRemoved(removedCount + live) }
        var logged = removedCount

        sparseIndex.withUnsafeMutableBufferPointer { sparse in
            denseEntities.withUnsafeMutableBufferPointer { dense in
                removedEntities.withUnsafeMutableBufferPointer { log in
                    var slot: Int32 = 0
                    while slot < live {
                        // Trim flagged elements off the tail first. Nothing
                        // moves into their place, so each costs a sparse write.
                        while live > slot {
                            let tail = dense[Int(live - 1)]
                            if flags[Int(tail)] == 0 { break }
                            live -= 1
                            if owns { releaseDense(live) }
                            sparse[Int(tail)] = -1
                            removed += 1
                            if logChanges { log[Int(logged)] = tail; logged += 1 }
                        }
                        if slot >= live { break }

                        let entity = dense[Int(slot)]
                        if flags[Int(entity)] == 0 { slot += 1; continue }

                        // Doomed slot, surviving tail element: a real move.
                        live -= 1
                        if owns { releaseDense(slot) }
                        relocateDense(from: live, to: slot)
                        if clearRelocated { clearRelocatedDense(live) }
                        let moved = dense[Int(live)]
                        dense[Int(slot)] = moved
                        sparse[Int(moved)] = slot
                        sparse[Int(entity)] = -1
                        removed += 1
                        if logChanges { log[Int(logged)] = entity; logged += 1 }
                        slot += 1
                    }
                }
            }
        }

        count = live
        removedCount = logged
        if removed > 0 { structuralVersion += 1 }
        return removed
    }

    /// Empties the store without allocating: `sparseIndex` is reset and `count`
    /// goes to zero. Payload stays physically in place but becomes unreachable.
    public func clear() {
        let hadComponents = count > 0
        if hadComponents && cachedHooks.contains(.clearDense) { clearDense(activeCount: count) }
        for i in sparseIndex.indices { sparseIndex[i] = -1 }
        count = 0
        if hadComponents {
            structuralVersion += 1
            if trackChanges {
                changeLogOverflowed = true
                addedCount = 0
                removedCount = 0
            }
        }
    }

    public func clearChangeLog() {
        addedCount = 0
        removedCount = 0
        changeLogOverflowed = false
    }

    // --- queries ---------------------------------------------------------

    /// Deliberately unchecked: hot-loop primitives, matching the original.
    @inline(__always) public func has(_ entity: Entity) -> Bool { sparseIndex[Int(entity)] != -1 }
    @inline(__always) public func indexOf(_ entity: Entity) -> Int32 { sparseIndex[Int(entity)] }
    @inline(__always) public func entityAt(_ slot: Int32) -> Entity { denseEntities[Int(slot)] }

    /// Name for diagnostics. Cold path only.
    public func getDebugName() -> String {
        debugName.isEmpty ? "type \(typeID)" : debugName
    }

    public var isInitialized: Bool { initialized }

    /// Expensive development-time invariant check. Pass a nil `alive` span to
    /// skip the "attached to a live entity" half.
    public func validateIntegrity(alive: UnsafePointer<UInt8>?, aliveSize: Int32, reportErrors: Bool = true) -> Bool {
        var valid = true
        if count < 0 || count > capacityValue {
            valid = false
            if reportErrors {
                AegisDiagnostics.report("ComponentStore(type \(typeID)): count \(count) outside capacity \(capacityValue)")
            }
        }
        if sparseIndex.count != Int(capacityValue) || denseEntities.count != Int(capacityValue) {
            if reportErrors {
                AegisDiagnostics.report("ComponentStore(type \(typeID)): sparse/dense size does not match capacity")
            }
            return false
        }
        let checkAlive = alive != nil && aliveSize > 0
        if checkAlive && aliveSize != capacityValue {
            if reportErrors {
                AegisDiagnostics.report("ComponentStore(type \(typeID)): alive size does not match capacity")
            }
            return false
        }

        let checked = min(max(count, 0), capacityValue)
        for slot in 0..<Int(checked) {
            let entity = denseEntities[slot]
            if entity < 0 || entity >= capacityValue {
                valid = false
                if reportErrors {
                    AegisDiagnostics.report("ComponentStore(type \(typeID)): dense slot \(slot) holds invalid entity \(entity)")
                }
                continue
            }
            if sparseIndex[Int(entity)] != Int32(slot) {
                valid = false
                if reportErrors {
                    AegisDiagnostics.report("ComponentStore(type \(typeID)): dense->sparse broken for entity \(entity)")
                }
            }
            if checkAlive, alive![Int(entity)] == 0 {
                valid = false
                if reportErrors {
                    AegisDiagnostics.report("ComponentStore(type \(typeID)): component attached to dead entity \(entity)")
                }
            }
        }

        for entity in 0..<Int(capacityValue) {
            let slot = sparseIndex[entity]
            if slot == -1 { continue }
            if slot < 0 || slot >= count || slot >= capacityValue {
                valid = false
                if reportErrors {
                    AegisDiagnostics.report("ComponentStore(type \(typeID)): sparse slot \(slot) outside count for entity \(entity)")
                }
                continue
            }
            if denseEntities[Int(slot)] != Int32(entity) {
                valid = false
                if reportErrors {
                    AegisDiagnostics.report("ComponentStore(type \(typeID)): sparse->dense broken for entity \(entity)")
                }
            }
        }
        return valid
    }

    // --- change-log plumbing (accessible to specialised subclasses) --------

    func pushAdded(_ entity: Entity) {
        reserveAdded(addedCount + 1)
        addedEntities[Int(addedCount)] = entity
        addedCount += 1
    }

    func pushRemoved(_ entity: Entity) {
        reserveRemoved(removedCount + 1)
        removedEntities[Int(removedCount)] = entity
        removedCount += 1
    }

    func reserveAdded(_ required: Int32) {
        if Int32(addedEntities.count) >= required { return }
        var size = max(Int32(addedEntities.count), Self.changeLogMinCapacity)
        while size < required { size *= 2 }
        while Int32(addedEntities.count) < size { addedEntities.append(0) }
    }

    func reserveRemoved(_ required: Int32) {
        if Int32(removedEntities.count) >= required { return }
        var size = max(Int32(removedEntities.count), Self.changeLogMinCapacity)
        while size < required { size *= 2 }
        while Int32(removedEntities.count) < size { removedEntities.append(0) }
    }

    private func reserveMoveScratch(_ required: Int32) {
        if Int32(moveFrom.count) >= required { return }
        while Int32(moveFrom.count) < required { moveFrom.append(0); moveTo.append(0) }
    }
}
