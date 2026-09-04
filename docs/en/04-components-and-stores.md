[← World and entities](03-world-entities-lifecycle.md) | [Contents](README.md) | [Systems →](05-systems-and-scheduler.md)

---

# 4. Components and stores

A store is a container for one component type's data across all entities. This is
where all the memory layout that ECS exists for lives.

---

## 4.1. How a store is built

Every store is a **sparse set** of two arrays running in opposite directions:

```
sparseIndex[entity]  → dense slot, or -1 if there is no component
denseEntities[slot]  → which entity this slot belongs to
```

Plus the arrays of **the data itself**, indexed by **the same dense slot**.

```swift
let slot = positions.indexOf(entity)      // entity 42 → slot 5
if slot != -1 {
    print(positionX[Int(slot)])           // look up data by 5, not by 42
}
```

> **The most common beginner mistake:** indexing the data array by the entity
> identifier. `positionX[42]` is almost always someone else's component or
> garbage. Data is addressed by the **slot**, not the id.

Three fields on the base `ComponentStore` are deliberately `public internal(set)`:
`sparseIndex`, `denseEntities` and `count`. The library can only write them, but any
caller can read them directly — exactly so a system can hoist them into a local
once (or open them with `withUnsafeBufferPointer`) and index straight into the
buffer inside its hot loop, with no method call and no extra indirection per
element. Outside the module, treat them as **read-only**.

---

## 4.2. `PackedStore` — the recommended way

```swift
enum EnemyColumn: Int32 { case position, health, speed, tint }

let enemies = PackedStore(schema: [.vec3, .float32, .float32, .vec4])
world.registerStore(enemies, typeID: ComponentType.enemy.rawValue)
```

That is all. You declare a **schema of column types** once — allocation, capacity
growth and data relocation on removal are all implemented by the base class.

Swift has no field-name reflection the way the original GDScript `track(&"name")`
did, so a column is identified by **index**, not by name. Give the indices names
of your own with an `enum: Int32` as above, and pass its `rawValue` wherever an
index is expected.

**Supported column types** (`ColumnType`):

| Case | Storage | Size |
|---|---|---|
| `.uint8` | 1 byte | 1 |
| `.int32` / `.float32` | 4 bytes | 4 |
| `.int64` / `.float64` / `.vec2` | 8 bytes | 8 |
| `.vec3` | 3 × float32 | 12 |
| `.vec4` | 4 × float32 — also the shape of a colour | 16 |

There is **no object/reference column type**. A component that needs to own a
class instance, a resource, or anything else with identity cannot be a
`PackedStore` field — see [4.6](#46-components-that-own-resources) for that case.

### Why this is not slower

```swift
let hp = enemies.columnF32(EnemyColumn.health.rawValue)!
for slot in 0..<enemies.count {
    hp[Int(slot)] -= poisonDamage
}
```

`columnF32` (and its siblings `columnF64`, `columnI32`, `columnI64`, `columnU8`)
hand back a raw pointer to that column's storage — fetching it is an array index
into the small internal column list, not a search, so calling it once at the top
of `execute()` and indexing the pointer for the rest of the loop costs nothing
extra. Each returns `nil` if the index is out of range **or** the column is not
actually of that type, so a schema mismatch surfaces as `nil` you can check,
rather than silently reinterpreted bytes — force-unwrapping (`!`) is safe only
once you are sure the schema matches.

`vec2`/`vec3`/`vec4` columns have no dedicated typed accessor yet. Reach them
through the untyped `columnData(_:)` pointer and bind it yourself:

```swift
let position = enemies.columnData(EnemyColumn.position.rawValue)!
    .assumingMemoryBound(to: SIMDVector3.self)
position[Int(slot)] = SIMDVector3(x, y, z)
```

The generic work happens only during allocation and removal, and even there
`PackedStore` does not lose to a hand-written store: it advertises the
`.relocateBatch` hook, so a batched destruction resolves every column's storage
**once** for the whole operation rather than once per moved element (see
[4.5](#45-optional-hooks)).

### Useful members

```swift
store.columnCount              // how many columns the schema declared
store.columnType(_ index:)     // ColumnType? for that column
store.clearSlot(_ slot:)       // writes a zero into every column of this slot
```

Call `clearSlot()` right after `attach()` if the store has columns the creation
path does not always fill: slots are reused, so a freshly attached component
would otherwise start life holding whatever its previous occupant left behind.

---

## 4.3. `TagStore` — a component with no data

Sometimes a system does not need to know anything about an entity except the fact
that it belongs to a category: "this is an enemy", "this is a projectile", "this
can be picked up".

```swift
let hostileTag = TagStore()
world.registerStore(hostileTag, typeID: ComponentType.hostile.rawValue)

hostileTag.attach(entity)
if hostileTag.has(entity) { /* ... */ }

// The most valuable part — dense iteration over the whole category:
for i in 0..<hostileTag.count {
    let enemy = hostileTag.entityAt(i)
}
```

A tag has no payload arrays, so removal relocates nothing at all. `TagStore` goes
further and overrides `detachMany`/`detachFlagged` directly with a version that
never calls `relocateDense` even once — it is the cheapest store in the library.

---

## 4.4. `ComponentStore` — a hand-written store

The lower level. You need it when the layout is non-standard: a component that
owns a class instance (4.6), a bit-packed field, or a payload that must relocate
non-trivially.

The subclass **must** override two methods. Both default to `fatalError` on the
base class, so forgetting either one is not silent — it is a hard crash the first
time the store is used:

```swift
final class CountingStore: ComponentStore {
    var values = ContiguousArray<Float>()

    // 1. Allocate your storage for the world's capacity.
    override func reserveDense(_ capacity: Int32) {
        values = ContiguousArray(repeating: 0, count: Int(capacity))
    }

    // 2. Relocate data on swap-remove.
    override func relocateDense(from: Int32, to: Int32) {
        values[Int(to)] = values[Int(from)]
    }
}
```

This is the shape `Tests/AegisECSTests/StoreTests.swift` itself uses for a
hand-written store: its `CountingStore` is exactly this, plus a relocation
counter bumped inside `relocateDense` so the tests can assert on precisely how
much data moved for a given operation.

> **A subtler version of the classic mistake still survives.** Omitting
> `relocateDense` entirely crashes immediately and unmistakably. But a
> hand-written store with several fields that overrides `relocateDense` and
> forgets to copy just one of them fails exactly like the old bug always did:
> swap-remove silently leaves that one field's stale value behind, with nothing
> printed anywhere. This is precisely the mistake `PackedStore` (4.2) removes by
> construction — it generates `relocateDense` from the schema, so there is no
> per-field code left to forget.

---

## 4.5. Optional hooks

Swift has no `has_method()`-style reflection, so a subclass **advertises** which
optional hooks it implements by overriding `var hooks: Hooks` — an `OptionSet`:

```swift
final class CustomStore: ComponentStore {
    override var hooks: Hooks { [.growDense, .relocateBatch] }
    // ...
}
```

| Hook | Purpose | Override |
|---|---|---|
| `.growDense` | Enables `world.reserveCapacity()`. Must preserve all data in `0..<count`. | `growDense(previousCapacity:newCapacity:)` |
| `.relocateBatch` | Batched relocation: resolve storage once for the whole operation instead of once per move. | `relocateDenseBatch(from:to:moveCount:)` |
| `.releaseDense` | Release whatever the slot owns, before it is overwritten. | `releaseDense(_:)` |
| `.clearRelocated` | Clear the duplicate left in the slot the data moved from. | `clearRelocatedDense(_:)` |
| `.clearDense` | Bulk teardown on `clear()` / `world.reset()`. | `clearDense(activeCount:)` |

`PackedStore` already advertises `.growDense` and `.relocateBatch`; `TagStore`
advertises `.growDense`. Neither needs anything further from you to support
`world.reserveCapacity()`.

> **A real diagnostic, not a style suggestion.** Advertising `.clearRelocated`
> without `.releaseDense` is reported the moment the store is registered: the
> source slot would be cleared but whatever it owned would never actually be
> released.

### Capacity growth for a hand-written store

```swift
override func growDense(previousCapacity: Int32, newCapacity: Int32) {
    while packedFlags.count < Int(newCapacity) { packedFlags.append(0) }   // preserves [0, count)
}
```

Check support with:

```swift
if store.supportsCapacityGrowth { /* ... */ }
```

If even one registered store does not advertise `.growDense`, `world.reserveCapacity()`
returns `false` having touched nothing.

---

## 4.6. Components that own resources

`PackedStore`'s schema only holds primitive numeric and vector columns (4.2), so a
component that must own a class instance, a file handle, or anything else with
identity needs a hand-written `ComponentStore`. Swift's ARC releases a reference
the moment nothing points to it, so "freeing" a slot is just assigning `nil` — but
the **order** those assignments happen in still matters exactly as much as it did
for a manually-freed resource:

```swift
final class TextureStore: ComponentStore {
    private var textures: [CGImage?] = []

    override var hooks: Hooks { [.growDense, .releaseDense, .clearRelocated, .clearDense] }

    override func reserveDense(_ capacity: Int32) {
        textures = Array(repeating: nil, count: Int(capacity))
    }
    override func growDense(previousCapacity: Int32, newCapacity: Int32) {
        while textures.count < Int(newCapacity) { textures.append(nil) }
    }
    override func relocateDense(from: Int32, to: Int32) {
        textures[Int(to)] = textures[Int(from)]
    }

    // Called on the slot being REMOVED, BEFORE the data is relocated.
    override func releaseDense(_ slot: Int32) {
        textures[Int(slot)] = nil
    }
    // Called on the slot the data moved FROM.
    // Here we ONLY clear the duplicate — ownership already moved elsewhere.
    override func clearRelocatedDense(_ slot: Int32) {
        textures[Int(slot)] = nil
    }
    // Bulk teardown on clear() / world.reset().
    override func clearDense(activeCount: Int32) {
        for slot in 0..<Int(activeCount) { textures[slot] = nil }
    }
}
```

**Order matters.** `detach()` first calls `releaseDense()` on the slot being
removed, and only then relocates the payload from the last slot and calls
`clearRelocatedDense()`. Swapping these means either a leaked reference (never
nilled out, so ARC never releases it) or clearing a slot before its data actually
moved. Forgetting `releaseDense` for a slot that briefly held a strong reference
keeps that object alive for as long as some unrelated later component happens to
land in the recycled slot — a real, hard-to-spot leak.

---

## 4.7. Core operations

```swift
let slot = store.attach(entity)     // idempotent; -1 on overflow or an out-of-range id
store.detach(entity)                // safe, even if there is no component

store.has(entity)                   // Bool
store.indexOf(entity)               // slot or -1
store.entityAt(slot)                // the entity that owns the slot
store.count                         // how many components
store.clear()                       // empty with no allocation
```

> `has`, `indexOf` and `entityAt` are marked `@inline(__always)` and
> **deliberately do not check bounds** — they are hot-loop primitives. Passing
> the id of a non-existent entity here is a bug in the calling code. Structural
> entry points (`attach`, `detach` and their batched forms) do check bounds,
> because they run far less often.

### Batched operations

```swift
let first = store.count
let attached = store.attachMany(ids, count: idCount)
// new slots: [first, first + attached)

let removed = store.detachMany(ids, count: idCount)
```

`attachMany` skips entities that already have the component, so `attached` can be
less than `idCount`.

---

## 4.8. How to split data across stores

A practical question: one big store or many small ones?

**Keep together what is read together.** If the movement system reads position
and velocity every frame, it makes sense to put them in one store: then no
`sparseIndex` lookup is needed and iteration goes over a single dense array.

**Separate what is used rarely or on its own.** A component that every tenth
entity has would, in a shared store, force the other nine to carry unfilled
columns — and, worse, take up space in the hot loop's cache lines.

**Move flag-like traits into tags.** "Stunned", "invulnerable", "in water" are a
`TagStore`, not a `Bool` column in a big store: a tag gives you a dense list of
exactly those it applies to.

An example layout for a game:

| Store | Columns | Who reads it |
|---|---|---|
| `Transform` | position, yaw | almost every system |
| `Locomotion` | velocity, speed | movement, targeting |
| `Health` | current, max | damage, death |
| `MissileLauncher` | cooldown, range | only the shooting system (few entities) |
| `HostileTag` | — | spawning, target search |
| `StunnedTag` | — | movement (exclusion) |

---

## Chapter summary

1. Data is addressed by the **dense slot**, not the entity id.
2. For ordinary data use **`PackedStore`** — declare a schema of column types, no
   boilerplate and no speed loss.
3. `TagStore` is for traits with no data.
4. A hand-written `ComponentStore` **must** override `reserveDense` and
   `relocateDense` — skipping either crashes immediately (`fatalError`), but a
   partially-correct override can still corrupt data silently.
5. Optional hooks are **advertised**, not detected: override `var hooks` and the
   base class calls exactly what you declared.
6. Stores that own a resource implement `.releaseDense` **and**
   `.clearRelocated` — the order they run in is critical, and `PackedStore` has
   no column type for this case at all.
7. Read together — store together; move the rare and the separate out.

---

[← World and entities](03-world-entities-lifecycle.md) | [Contents](README.md) | [Systems →](05-systems-and-scheduler.md)
