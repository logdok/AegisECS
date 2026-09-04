import Foundation

/// An entity is a raw dense index, nothing more. It carries no data and no
/// type; the component stores hold data, keyed by this integer.
public typealias Entity = Int32

/// A generational handle: entity id plus the generation current when it was
/// made, plus a tag identifying the world. Safe to hold across frames — a raw
/// `Entity` is not, because destroy recycles ids.
public typealias Handle = Int64

public let kInvalidEntity: Entity = -1
public let kInvalidHandle: Handle = 0

/// Handle bit layout, identical to the original: 15 bits of world tag, 24 bits
/// of generation, 24 bits of entity id. The sign bit stays clear, so a valid
/// handle is always a positive integer.
let kHandleEntityMask: Handle = 0xFF_FFFF
let kHandleGenerationMask: Handle = 0xFF_FFFF
let kHandleWorldMask: Handle = 0x7FFF
let kHandleGenerationShift: Handle = 24
let kHandleWorldShift: Handle = 48

/// Largest entity capacity the handle layout can address.
public let kMaximumCapacity: Int32 = Int32(kHandleEntityMask) + 1

@inline(__always)
func nextGeneration(_ current: Int32) -> Int32 {
    let next = current &+ 1
    return (next <= 0 || next > Int32(kHandleGenerationMask)) ? 0 : next
}
