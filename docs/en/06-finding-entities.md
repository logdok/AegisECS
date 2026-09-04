[← Systems](05-systems-and-scheduler.md) | [Contents](README.md) | [Time and events →](07-time-events-capacity.md)

---

# 6. Finding the entities you want

A typical system processes not all entities but those that have a certain set of
components: "everyone who has a position AND a velocity but is NOT stunned".

Aegis has three levels for this, from fastest to most convenient. This is not a
"bad, medium and good way" — it is three different trade-offs, and each is right
in its own place.

---

## 6.1. Level 1: the direct loop (fastest)

The idea is simple: **drive the iteration by the dense array of the smallest
store**, and fetch the rest of the components through `sparseIndex`.

```swift
final class MovementSystem: System {
    private var velocities: PackedStore!
    private var positions: PackedStore!

    override func setup(world: World, context: Any?) {
        velocities = world.getStore(ComponentType.velocity.rawValue) as? PackedStore
        positions = world.getStore(ComponentType.position.rawValue) as? PackedStore
    }

    override func execute(delta: Float) {
        guard let velocities, let positions,
              let vx = velocities.columnF32(0), let px = positions.columnF32(0) else { return }

        // Local aliases — hoisted once, before the loop.
        let owners = velocities.denseEntities
        let posSlots = positions.sparseIndex

        for dense in 0..<Int(velocities.count) {
            let slot = posSlots[Int(owners[dense])]
            if slot < 0 { continue }               // this entity has no position
            px[Int(slot)] += vx[dense] * delta
        }
    }
}
```

`sparseIndex` and `denseEntities` are public (read-only from outside the store)
precisely so a system can take them into locals like this. `columnF32` hands back
a raw pointer into a `PackedStore` column, valid until the world's capacity
changes — see [chapter 4](04-components-and-stores.md).

**Why drive by the smallest store.** If 300 entities have a velocity but 10,000
have a position, iterating velocities gives 300 iterations, and iterating
positions gives 10,000 with 9,700 wasted checks.

**When to use it.** In the hottest systems with a schema known in advance. This
is the library's main working tool. `has(_:)`, `indexOf(_:)` and `entityAt(_:)`
are declared `@inline(__always)` — the source calls them "deliberately unchecked
hot-loop primitives" on purpose, matching this pattern.

There is deliberately no query abstraction in the core precisely because it
would show up in the profile of the hottest systems.

---

## 6.2. Level 2: `View` (no allocations)

When the set of components is more complex than "two specific stores", or when
you need **exclusions**, it is more convenient to describe the condition
declaratively.

```swift
final class MovementSystem: System {
    private let moving = View()

    override func setup(world: World, context: Any?) {
        _ = moving.configure(
            world: world,
            required: [ComponentType.position.rawValue, ComponentType.velocity.rawValue],
            excluded: [ComponentType.stunned.rawValue],
            ownerSystem: self)                     // owner, for validation
    }

    override func execute(delta: Float) {
        moving.refreshDriver()                     // pick the smallest store
        guard let driver = moving.candidateStore else { return }

        for dense in 0..<Int(driver.count) {
            let entity = driver.entityAt(Int32(dense))
            if !moving.matches(entity) { continue }
            // ...
        }
    }
}
```

`View` **materializes nothing and allocates nothing**. `configure()` is a cold
operation (once, in `setup`), `refreshDriver()` picks the smallest of the
required stores, and `matches(_:)` does direct sparse-set checks.

### A faster variant: inline the check

`matches(_:)` is a call for every candidate. In a hot system it is better to take
only the **resolved sparse arrays** from the `View` and inline the check into
your own loop:

```swift
moving.refreshDriver()
guard let driver = moving.candidateStore,
      let positionSlots = moving.requiredSparse(0),
      let stunnedSlots = moving.excludedSparse(0) else { return }

for dense in 0..<Int(driver.count) {
    let entity = driver.entityAt(Int32(dense))
    if positionSlots[Int(entity)] == -1 || stunnedSlots[Int(entity)] != -1 { continue }
    // ...
}
```

This way you get the convenience of the declarative description and the speed of
the direct loop at the same time. `driverRequiredIndex` tells you which required
store `refreshDriver()` picked to drive — you do not need to also test that one,
membership in it is guaranteed by the iteration itself.

---

## 6.3. Level 3: `Query` (cached result)

`Query` **materializes** the intersection into a pre-allocated buffer and
rebuilds it only when the membership actually changed.

```swift
final class DamageSystem: System {
    private let query = Query()

    override func setup(world: World, context: Any?) {
        _ = query.configure(
            world: world,
            required: [ComponentType.position.rawValue, ComponentType.health.rawValue],
            excluded: [ComponentType.invulnerable.rawValue],
            ownerSystem: self)
    }

    override func execute(delta: Float) {
        query.refresh()                             // rebuilds only if needed
        query.withEntities { entities in
            for index in 0..<Int(query.count) {
                let entity = entities[index]
                // ...
            }
        }
    }
}
```

`refresh()` returns `true` if the cache was rebuilt and `false` if the membership
did not change. It tracks the `structuralVersion` of every participating store
(`isCurrent` exposes the same check without triggering a rebuild).

**What invalidates the cache:** `attach`, `detach`, `clear`, capacity growth.
**What does NOT invalidate it:** writing to the payload. Changed health — the
query membership is the same.

That is the point of `Query`: if the intersection is read by several systems or
changes rarely, the rebuild simply does not happen. A cache hit is a handful of
version comparisons; a miss walks the driver store the same way a `View` would.
`rebuildCountValue` exposes how many rebuilds have happened, for diagnostics.

### Limiting the buffer size

By default the result is allocated at `world.capacity`. For a narrow query this
is wasteful:

```swift
_ = query.configure(world: world, required: required, excluded: excluded,
                     ownerSystem: self, maximumResults: 256)   // at most 256 results

query.refresh()
if query.isTruncated {
    // more entities matched than the 256-entry buffer holds
}
```

`maximumResults: -1` (the default) means "as large as the world"; any other
value must be positive and caps the materialized set. Without a limit, each
query takes roughly `4 bytes × world.capacity`. For a large schema, either set
limits or use a `View` / the direct loop.

### Fast access to the buffer

```swift
query.withEntities { entities in
    for index in 0..<Int(query.count) {
        let entity = entities[index]
        // ...
    }
}
```

`withEntities` hands the closure an `UnsafeBufferPointer<Entity>` — no
per-element method call. The buffer is **read-only**, and it must not be kept
across `refresh()` or `world.reserveCapacity()`.

---

## 6.4. How to choose

| | Direct loop | `View` | `Query` |
|---|---|---|---|
| Iteration speed | highest | high | highest (over the buffer) |
| Preparation cost | none | `refreshDriver()` | `refresh()`, sometimes a rebuild |
| Allocations | none | none | the buffer, once |
| Component exclusions | by hand | yes | yes |
| When to take it | hot system, fixed schema | changing schema, exclusions | intersection read several times or rarely changing |

Practical advice: **start with the direct loop**. Move to a `View` when the
condition becomes complex and the code stops being readable; to a `Query` when
the profiler shows the same intersection being built several times per frame.

---

## 6.5. A limitation shared by View and Query

Both require **at least one required type**. `View.configure` refuses an empty
`required` list outright. The world deliberately does not keep a second dense
list of "everyone alive" just for a component-less query.

If you need to iterate literally everyone — set up a tag every entity has (see
[`TagStore`](04-components-and-stores.md)) and drive the iteration by it.

---

## 6.6. A safety rule

**Do not change the membership of participating stores in the middle of an
active iteration.**

```swift
// WRONG
for dense in 0..<Int(positions.count) {
    let entity = positions.entityAt(Int32(dense))
    if shouldRemove(entity) {
        positions.detach(entity)      // swap-remove shifted the array under your feet
    }
}
```

Correct — mark and remove later:

```swift
for dense in 0..<Int(positions.count) {
    let entity = positions.entityAt(Int32(dense))
    if shouldRemove(entity) {
        world.queueDestroy(entity)    // ReaperSystem destroys it at end of frame
    }
}
```

If you need to remove exactly the **component**, not the entity, collect the
victims into an array and call `detachMany(_:count:)` after the loop.

---

## Chapter summary

1. **The direct loop** is the main tool; drive the iteration by the smallest
   store.
2. **`View`** is a declarative description with no allocations; for speed take
   the sparse arrays from it (`requiredSparse`/`excludedSparse`) and inline the
   check yourself.
3. **`Query`** is for when the intersection is read many times or rarely
   changes; a hit is a version check, a miss is a full rebuild.
4. Writing to the payload does **not** invalidate a query's cache;
   `attach`/`detach` does.
5. Never change a store's membership in the middle of an iteration.

---

[← Systems](05-systems-and-scheduler.md) | [Contents](README.md) | [Time and events →](07-time-events-capacity.md)
