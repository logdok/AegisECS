[← Performance](09-performance.md) | [Contents](README.md) | [Full example →](11-full-example.md)

---

# 10. Common mistakes

A reference in "symptom → cause → fix" format. Most of the mistakes in §10.1
**produce no diagnostic at all** — which is exactly why this chapter exists;
§10.2 covers the ones the library *does* report through `AegisDiagnostics`.

---

## 10.1. Silent bugs and unguarded crashes (the most dangerous)

### Data got mixed up after a removal

**Symptom.** Entities are alive, components are in place, but the values
belong to the wrong ones — an enemy has someone else's health, a projectile
flies the wrong way. No errors.

**Cause.** A hand-written `ComponentStore` subclass's `relocateDense(from:to:)`
override forgot a field. On swap-remove the last element moved into the
removed one's place, but that one field's payload stayed where it was.

**Fix.**

```swift
override func relocateDense(from: Int32, to: Int32) {
    // EVERY field, no exceptions
    health[Int(to)] = health[Int(from)]
    armor[Int(to)] = armor[Int(from)]
}
```

**How not to step on it again.** Use `PackedStore` — its schema-driven
columns implement relocation for you, and this specific mistake becomes
structurally impossible. If a store must be hand-written, write a dedicated
test for it: create two entities with **distinguishable** values in every
field, remove the first, check the second (see
`Tests/AegisECSTests/StoreTests.swift`'s `CountingStore` for the pattern).

---

### A cached column pointer went stale

**Symptom.** After the population grows past its original size, writes
through a previously-fetched `PackedStore` column pointer corrupt unrelated
memory or silently vanish.

**Cause.** `PackedStore.columnF32(_:)` (and its siblings) hand back a raw
pointer that is only valid **until the world's capacity grows**
(`World.reserveCapacity()` reallocates every column). A pointer cached across
that call is a use-after-free.

```swift
// WRONG: fetched once outside execute(), reused across many frames
let x = store.columnF32(0)!
func execute(delta: Float) {
    // ... a growth happened between frames; x now points at freed memory
}

// RIGHT: fetch fresh at the top of every execute()
override func execute(delta: Float) {
    let x = store.columnF32(0)!
    // ...
}
```

---

### A system reads last frame's data

**Symptom.** Collisions fire with a delay, targeting "lags" by a frame, a
spatial index reports stale positions.

**Cause.** The system is in **the wrong place** in the registration order.

```swift
// WRONG: the index is built from old positions
scheduler.addSystem(SpatialIndexSystem())
scheduler.addSystem(MovementSystem())

// RIGHT
scheduler.addSystem(MovementSystem())
scheduler.addSystem(SpatialIndexSystem())
```

**Registration order is behaviour** ([chapter 5](05-systems-and-scheduler.md)).
There will be no error; there will be a different game.

---

### Use-after-free within a frame

**Symptom.** Occasionally — "once every hundred frames" — data belongs to the
wrong entity.

**Cause.** A dense slot was cached **across** a structural change.

```swift
// WRONG
let slot = positions.indexOf(entity)
world.flushDestroyQueue()               // swap-remove could have moved data
positions.columnF32(0)![Int(slot)] = 0  // writing into someone else's component
```

**Fix.** Re-fetch the slot after any structural change. And keep
`flushDestroyQueue()` at **exactly one point in the frame** — use
`ReaperSystem`, registered last (see [chapter 3](03-world-entities-lifecycle.md)).

> A `Handle` cures a stale **entity reference**, but not a stale **slot**.

---

### An iteration fell apart mid-flight

**Symptom.** Some entities are skipped, counters do not add up.

**Cause.** A store's membership is changed **in the middle of iterating that
same store**.

```swift
// WRONG
for dense in 0..<Int(positions.count) {
    if shouldDie(dense) {
        positions.detach(positions.entityAt(Int32(dense)))   // the array shifted
    }
}
```

**Fix.** Mark, and remove later, at the sync point:

```swift
for dense in 0..<Int(positions.count) {
    if shouldDie(dense) {
        world.queueDestroy(positions.entityAt(Int32(dense)))
    }
}
```

---

### A force-unwrapped column crashes on a schema mismatch

**Symptom.** A crash (trapped `nil` unwrap) instead of a diagnostic message,
usually right after a refactor that reordered a store's `schema`.

**Cause.** `PackedStore.columnF32(_:)` and its siblings return `nil` for
**any** mismatch — wrong index *or* wrong `ColumnType` — not only an
out-of-range index. `store.columnF32(0)!` turns a recoverable schema bug into
a hard crash with no context about which store or column was wrong.

**Fix.** `guard let`/`if let` around the accessor, and check
`columnType(_:)`/`columnCount` while debugging a mismatch.

---

## 10.2. Mistakes the library reports through `AegisDiagnostics`

### `createEntity()` returned `-1`

**Cause.** The world is full: `getFreeCount() == 0`. `-1` is `kInvalidEntity`.

**Fix.** Either raise the initial capacity, use
[`CapacityPolicySystem`](07-time-events-capacity.md#73-capacity-and-growth-policy)
to grow proactively, or destroy more aggressively. And **always check the
result against `kInvalidEntity`** — this is not an exceptional situation but a
normal state the API is designed around.

---

### `registerStore()` returned `false`

Three possible causes, each with its own message:

| Message | Cause |
|---|---|
| `"World: schema locked by the first createEntity(); register stores earlier"` | The store is registered **after** the first entity was created. Register every store before creating anything. |
| `"World: component type N is already registered"` | A duplicated type id constant. |
| `"World: store is already registered under another type or in another world"` | The same store object is being registered a second time. |

---

### `reserveCapacity()` returned `false`

**Cause.** Either the requested capacity is not larger than the current one,
or some registered store does not advertise `.growDense` in its `hooks`.

**Fix.** Add the hook to the hand-written store:

```swift
override var hooks: Hooks { [.growDense] }
override func growDense(previousCapacity: Int32, newCapacity: Int32) {
    while values.count < Int(newCapacity) { values.append(0) }
}
```

`PackedStore` and `TagStore` always advertise `.growDense`. Check at runtime:
`store.supportsCapacityGrowth`.

---

### `"clearRelocated without releaseDense"`

**Cause.** A hand-written store's `hooks` advertises `.clearRelocated` but not
`.releaseDense`. You implemented clearing the duplicate slot the move leaves
behind, but never freeing what the removed slot itself owned — this almost
always means a **resource leak**.

**Fix.** Implement both together — see
[§4 on components that own resources](04-components-and-stores.md).

---

### `"one instance cannot be registered in two schedulers"` / `"the same system object was registered twice"`

**Cause.** One `System` instance was added to two different `Scheduler`s (the
first message, from `System.assignPhase`), or the same instance was added
twice to one scheduler (the second, from `Scheduler.addSystem`).

**Fix.** Create a separate instance per pipeline; register each instance once.

---

### `"system X did not finish describing its access"` / `"did not declare access to type N"`

**Cause.** `View.validateOwnerAccess`/`Query.validateOwnerAccess` — a
metadata-only diagnostic with **no effect on execution** — found a system that
either never called `completeAccessMetadata()`, or used a type through a
`View`/`Query` it never declared with `declareRead`/`declareWrite`/
`declareStructuralWrite`.

**Fix.** Chain `.completeAccessMetadata()` after declaring access, and declare
every type a system's views actually touch — or simply do not call the
validation methods if you are not using this tooling.

---

### `"PackedStore: no columns declared"`

**Cause.** `PackedStore(schema: [])` — an empty schema.

**Fix.** Use `TagStore` for a component that carries no payload at all.

---

## 10.3. Performance problems

### The frame "dips" exactly when many things die

**Cause.** Destruction costs `O(victims × stores)` ([chapter 9](09-performance.md)).

**Fix.**
- Merge small, specialised stores where it makes sense.
- Spread a mass death over several frames.
- For a full wipe use `World.reset()`, not a mass `queueDestroy` + flush.

---

### The grid rebuild eats the whole frame

**Cause.** A bad `cellSize`: the cost is `O(entries + CELLS)`.

**Fix.** `UniformSpatialGrid.suggestCellSize()`, flat mode for a game on a
plane, separate grids for populations of very different size. See
[§8.4](08-spatial-search.md#84-the-one-that-matters-most-choosing-cellsize).

---

### `Query` rebuilds every frame

**Cause.** Some participating store changes its membership every frame —
often a tag that something attaches and detaches each frame.

**Check:**

```swift
print(query.rebuildCountValue)   // growing by 1 every frame?
```

**Fix.** Either remove the volatile type from the query's required/excluded
set, or move to `View` / a direct loop — a cache that always misses only adds
work on top of the thing it was meant to avoid.

---

### Iteration is slower than expected

**Cause.** Calling into a column accessor or `View.matches(_:)` inside the
loop instead of hoisting a pointer/sparse array once before it.

**Fix.** See [§9.1](09-performance.md#91-struct-of-arrays-not-object-per-entity)
and [§9.6](09-performance.md#96-view-and-query-do-not-allocate-on-the-hot-path).

---

## 10.4. Mistakes when speeding time up

### The simulation "jumps over" events at high speed

**Symptom.** At `timeScale = 50` things that should happen periodically happen
less often than they should; fast projectiles fly through targets.

**Cause.** Raw per-frame `delta` multiplied by the scale gives one huge
simulation step instead of many small ones.

**Fix.** [`SimulationClock`](07-time-events-capacity.md#71-simulationclock--fixed-step-and-time-scale) —
call `advance(realDelta:)` and run one fixed-size step per substep it returns.

---

### The game hangs when sped up

**Cause.** The "death spiral": each substep takes real time to compute, so a
large enough `timeScale` makes every frame produce more substeps than the
previous one finished, without bound.

**Fix.** `clock.maxSubsteps` (`8` by default) caps this. Watch
`clock.droppedSubsteps` — if it keeps growing, the machine genuinely cannot
keep up with the requested `timeScale`.

---

### Something still moves while paused

**Cause.** The system never set `requiresTime = true`, so `Scheduler` still
calls it on a zero-length step.

**Fix.**

```swift
final class MovementSystem: System {
    override init() {
        super.init()
        systemName = "Movement"
        requiresTime = true
    }
}
```

---

### Entities pile up in the queue during a pause

**Cause.** `ReaperSystem` was given `requiresTime = true`.

**Fix.** Do not do that. `ReaperSystem` deliberately does **not** set
`requiresTime` — entities queued for destruction before a pause still need to
be cleaned up while the game is paused.

---

## 10.5. Quick diagnosis

When it is unclear what is even happening:

```swift
// 1. Is the world intact?
assert(world.validateIntegrity(), "world integrity check failed")

// 2. What about the population?
print("live=\(world.getLiveCount()) free=\(world.getFreeCount()) "
    + "pending=\(world.getPendingDestroyCount()) load=\(world.getLoadFactor())")

// 3. Are the stores consistent with the world?
print("positions=\(positions.count) hostiles=\(hostileTag.count)")

// 4. Where does the time go?
for i in 0..<scheduler.systemCount {
    print("\(scheduler.getSystemName(i))  \(Int(scheduler.getAverageTimingUsec(i))) us")
}

// 5. Is the pipeline assembled correctly?
scheduler.validatePipeline(world: world)
```

---

## Checklist before looking for a bug somewhere else

- [ ] Do hand-written stores implement `relocateDense(from:to:)` for **every**
      field?
- [ ] Is `flushDestroyQueue()` called in **exactly one place** — a single
      `ReaperSystem`, registered last?
- [ ] Is data indexed by the **dense slot**, not the entity id?
- [ ] Does the system order match the data-dependency order?
- [ ] Are dense slots and `PackedStore` column pointers never cached across a
      structural change or a `reserveCapacity()` growth?
- [ ] Is a store's membership left unchanged while iterating that same store?
- [ ] Is `createEntity()`'s result checked against `kInvalidEntity`?
- [ ] Do time-dependent systems set `requiresTime = true`?

---

[← Performance](09-performance.md) | [Contents](README.md) | [Full example →](11-full-example.md)
