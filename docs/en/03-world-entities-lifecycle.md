[← Quick start](02-quick-start.md) | [Contents](README.md) | [Components →](04-components-and-stores.md)

---

# 3. World, entities, lifecycle

`World` is the allocator of entity identifiers and the registry of stores.
It does not hold game data; it answers the questions "which entities are
alive" and "which stores exist".

---

## 3.1. Creating a world

```swift
let world = World(entityCapacity: 10000)   // capacity: 10,000 simultaneously live entities
```

The capacity is set once, and all internal buffers are allocated
**immediately**. The world **does not grow on its own** — this is a
deliberate decision. A hidden allocation in the hot loop with tens of
thousands of entities causes a hitch on a weak device, and a hitch that
happens once every few minutes at a random moment is almost impossible to
debug.

If capacity might run out, read about explicit growth and the automatic
policy in
[section 7.3](07-time-events-capacity.md#73-capacity-and-growth-policy).

### The order of building a world

```swift
let world = World(entityCapacity: 10000)

// 1. First ALL the stores.
world.registerStore(positions, typeID: ComponentType.position.rawValue)
world.registerStore(velocities, typeID: ComponentType.velocity.rawValue)
world.registerStore(enemyTag, typeID: ComponentType.enemy.rawValue)

// 2. Then the systems.
scheduler.addSystem(...)
scheduler.setupAll(world: world, context: context)

// 3. And only now — entities.
let entity = world.createEntity()
```

The schema is **locked by the first `createEntity()`**: after it,
`registerStore(_:typeID:)` returns `false` and reports a diagnostic. This is
deliberate — a store registered later would not know about the already
created entities, and its sparse array would be inconsistent.

The type identifier (`ComponentType.position.rawValue` and so on) is any
`Int32` you like — the idiom from [chapter 2](02-quick-start.md) is a small
`enum ComponentType: Int32` with one case per component type. The world uses
it only for `getStore(_:)` and diagnostics; it does not affect speed.

---

## 3.2. An entity is a number

```swift
let entity = world.createEntity()
if entity < 0 {
    return            // the world is full — checking is MANDATORY
}
```

`createEntity()` returns **`kInvalidEntity` (`-1`)** when there are no free
identifiers left. This is not a thrown error — `Entity` is a plain
`Int32` typealias and the library never throws — it is the normal state of a
full world, and the calling code is obliged to check for it.

The identifier is a dense index in the range `[0, capacity)`. It directly
addresses each store's `sparseIndex`, so it stays the cheapest
representation in the hot loop: no decoding, no checks.

### Batched creation

When many entities are born in one frame — a wave of enemies, an explosion
into particles, cell division — paying the per-call overhead is not worth
it:

```swift
var ids = [Entity](repeating: kInvalidEntity, count: 256)   // once, ahead of time
let spawned = world.createEntities(64, into: &ids)
// spawned can be less than 64 if the world is almost full
```

That same buffer is then handed to the stores:

```swift
let firstSlot = Int(positions.count)      // TAKE IT BEFORE the call
positions.attachMany(ids, count: spawned)
for i in 0..<Int(spawned) {
    positions.columnF32(0)![firstSlot + i] = 0.0
}
```

The new components occupy slots `[firstSlot, firstSlot + attached)` **in the
same order** the entities were in the buffer.

---

## 3.3. The handle: a reference that survives across frames

A raw identifier is safe **only within a structural epoch** — that is, until
`flushDestroyQueue()` or `reset()` is called. After destruction, the same
number can be handed to a different entity.

So for everything that lives between frames — a turret's target, an effect's
owner, a UI element, a deferred callback, an external queue — there is a
**generational handle**:

```swift
let handle = world.makeHandle(entity)

// ...many frames later:
let current = world.entityFromHandle(handle)
if current == kInvalidEntity {
    return          // the target died; the handle is stale
}
// here `current` can be used as an ordinary Entity again
```

A `Handle` (an `Int64` typealias) is a positive number that packs three
things:

```
bits  0..23  raw entity id      (up to 16,777,216 slots)
bits 24..47  generation
bits 48..62  world tag
```

**The generation** is a counter that increases every time a slot is freed.
So an old handle to a reused slot does not match on generation and is
rejected. This is protection against the classic **ABA problem**: "the same
number, but a different entity now".

If a single slot were destroyed and recreated enough times to exhaust the
24-bit generation counter, the slot does not wrap back to generation 0 and
get reused — it **retires forever** instead (see `getRetiredCount()` in
[section 3.6](#36-diagnostics)). Reusing a wrapped generation would silently
reintroduce the same ABA bug the handle exists to prevent, so the library
gives up that one slot's capacity rather than risk it. At roughly sixteen
million recycles of one slot this is not a practical concern for almost any
app, but an extremely long-running world is trading a small amount of
capacity for that guarantee.

**The world tag** protects against a handle from one world accidentally
resolving in another (relevant if you have several independent
simulations — see [section 3.7](#37-multiple-worlds)).

### The choice rule

| Situation | What to store |
|---|---|
| Within one frame, inside a system | a raw `Entity` |
| A target, an owner, a subscription, UI, a timer, async work | a `Handle` |
| Saving to disk, networking | **your own stable identifier**, not a handle |

A handle is **not** a stable identifier between runs of the app: the world
tag is handed out from a process-wide counter (`World`'s internal
`nextWorldTag`, starting at 1) that resets to 1 every time the process
starts, and the generation is likewise specific to that run. A handle
written to disk in one run is not guaranteed to resolve to the same entity,
or safely, in a later run.

### Helper methods

```swift
world.createEntityHandle()               // create and get a handle at once
world.isHandleAlive(handle)              // without resolving to an id
world.queueDestroyHandle(handle)         // safe destruction by handle
world.isHandlePendingDestroy(handle)
```

---

## 3.4. Destruction: the most important rule

Once more, because this is the place where every ECS beginner breaks.

```swift
world.queueDestroy(entity)     // ONLY marks
world.flushDestroyQueue()      // actually destroys
```

`queueDestroy(_:)` is **idempotent**: if several systems in one frame
independently decide to kill the same entity, it lands in the queue once.

`flushDestroyQueue()` is a **structural sync point**. It:

1. checks the generation stamped alongside every queue entry;
2. detaches the entity from every registered store;
3. performs swap-remove and cleanup hooks;
4. marks the entity dead;
5. advances the generation (or retires the slot — see
   [3.3](#33-the-handle-a-reference-that-survives-across-frames));
6. and only then returns the id to the free pool.

### Where to call it

Use the ready-made `ReaperSystem`, registered **last**:

```swift
scheduler.addSystem(MovementSystem())
scheduler.addSystem(CombatSystem())
scheduler.addSystem(ReaperSystem(world: world))    // ← last
```

Technically the flush can sit at several explicit phase boundaries. But
**never** inside a system, and you can **never** cache a dense slot across
that boundary:

```swift
// WRONG
let slot = positions.indexOf(entity)
world.flushDestroyQueue()            // swap-remove could have moved data here
positions.columnF32(0)![Int(slot)] = 0.0   // writing into someone else's component
```

A handle cures a stale **entity reference**, but not a stale **dense slot**.
The slot must be taken again after any structural change.

### Batched marking

```swift
world.queueDestroyMany(entities, count: entityCount)
```

---

## 3.5. Reset: restarting a level with no allocations

```swift
world.reset()
```

All entities "die", all stores are cleared — **with no allocations**: the
buffers are simply refilled. Store registrations are kept; you must not, and
cannot, call `registerStore(_:typeID:)` again.

`reset()` invalidates all active handles: the generation of every live
entity advances (or the slot retires, per the same rule as
[3.3](#33-the-handle-a-reference-that-survives-across-frames)).

---

## 3.6. Diagnostics

```swift
world.getLiveCount()             // how many entities are alive
world.getFreeCount()             // how many ids are left
world.getRetiredCount()          // slots with an exhausted generation
world.getPendingDestroyCount()   // how many are waiting in the queue
world.getLoadFactor()            // live / capacity, in 0...1
world.capacity
world.structuralVersion          // a monotonic counter of structural changes
```

### Integrity check

```swift
if !world.validateIntegrity() {
    assertionFailure()
}
```

A full check of the allocator, the destroy queue and all sparse sets:
whether the counters add up, whether there are duplicates in the free list,
whether the sparse↔dense mappings are bijective, whether a component is
attached to a dead entity.

The check is **linear in capacity** and creates temporary buffers. It is a
development tool: call it from tests, from a debug panel or in a fuzz loop,
but **not from a production frame**.

`validateIntegrity(reportErrors: false)` does not report diagnostics and
only returns a `Bool` — handy for tests (see `WorldTests.swift`).

---

## 3.7. Multiple worlds

Nothing stops you from having several independent `World` instances — for
example, one per match, per level or per parallel simulation. The world tag
in the handle guarantees that a reference from one world will not resolve in
another.

Limitation: there are enough tags for 32,767 worlds created over the
process's lifetime (they are not reused). Once exhausted, worlds keep
working with raw ids, but the handle API reports a diagnostic and returns
`kInvalidHandle`. In practice this is an unreachable limit unless you create
a new world every frame.

---

## Chapter summary

1. Capacity is fixed at creation; the world does not grow on its own.
2. All stores are registered **before** the first entity.
3. `createEntity()` can return **`kInvalidEntity` (-1)** — always check.
4. A raw `Entity` is for within the frame; a **`Handle`** is for across
   frames; **your own stable identifier** is for a file.
5. `queueDestroy()` marks, `flushDestroyQueue()` destroys — at **exactly one
   point in the frame**, usually via `ReaperSystem`.
6. Do not cache a dense slot across a structural change.

---

[← Quick start](02-quick-start.md) | [Contents](README.md) | [Components →](04-components-and-stores.md)
