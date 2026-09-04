import Foundation

/// A component with no payload. Port of `EcsTagStore`.
///
/// Sometimes a system needs to know nothing about an entity beyond the fact
/// that it belongs to a category. Membership is already fully described by the
/// sparse set holding an entry for that entity, so payload arrays would be
/// redundant.
///
/// The overrides are explicit no-ops, not silently inherited, so "this store
/// deliberately carries no data" is visible here.
public final class TagStore: ComponentStore {
    /// Advertised so the base class knows a tag survives
    /// `world.reserveCapacity()`: it has no data of its own to carry over.
    public override var hooks: Hooks { [.growDense] }

    public override func reserveDense(_ capacity: Int32) {}
    public override func relocateDense(from: Int32, to: Int32) {}

    /// Specialised batch removal. With no payload there is nothing to move, so
    /// neither the per-move call nor the recorded-move pass is needed.
    @discardableResult
    public override func detachMany(_ entities: UnsafePointer<Entity>, count entityCount: Int32) -> Int32 {
        if entityCount <= 0 || count == 0 { return 0 }
        let limit = capacity
        var live = count
        var removed: Int32 = 0
        let logChanges = trackChanges
        if logChanges { reserveRemoved(removedCount + entityCount) }
        var logged = removedCount

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

        count = live
        removedCount = logged
        if removed > 0 { structuralVersion += 1 }
        return removed
    }

    @discardableResult
    public override func detachFlagged(_ flags: UnsafePointer<UInt8>) -> Int32 {
        if count == 0 { return 0 }
        var live = count
        var removed: Int32 = 0
        let logChanges = trackChanges
        if logChanges { reserveRemoved(removedCount + live) }
        var logged = removedCount

        sparseIndex.withUnsafeMutableBufferPointer { sparse in
            denseEntities.withUnsafeMutableBufferPointer { dense in
                removedEntities.withUnsafeMutableBufferPointer { log in
                    var slot: Int32 = 0
                    while slot < live {
                        while live > slot {
                            let tail = dense[Int(live - 1)]
                            if flags[Int(tail)] == 0 { break }
                            live -= 1
                            sparse[Int(tail)] = -1
                            removed += 1
                            if logChanges { log[Int(logged)] = tail; logged += 1 }
                        }
                        if slot >= live { break }
                        let entity = dense[Int(slot)]
                        if flags[Int(entity)] == 0 { slot += 1; continue }
                        live -= 1
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
}
