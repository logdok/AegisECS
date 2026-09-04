[← Spatial search](08-spatial-search.md) | [Contents](README.md) | [Common mistakes →](10-common-mistakes.md)

---

# 9. Performance

---

## 9.1. Struct-of-arrays, not object-per-entity

This is the idea everything else in this chapter follows from, and it is
independent of any one language: a component is never an object living
somewhere on the heap, one per entity. Its data lives in flat columns — a
`PackedStore`'s raw allocated buffers, or a hand-written `ComponentStore`
subclass's own `ContiguousArray`s — indexed by dense slot, all packed
contiguously from `0` to `count - 1` ([chapter 4](04-components-and-stores.md)).
Iterating a store's live population means walking flat memory in order, which
is cache-friendly regardless of what language is doing the walking.

```swift
let x = store.columnF32(0)!
let vx = store.columnF32(1)!
for slot in 0..<Int(store.count) {
    x[slot] += vx[slot] * delta
}
```

Hoisting the column pointers once, before the loop, matters here for the same
reason it matters in any language: `columnF32(_:)` re-validates the index and
the column's declared type on every call. Fetch it once, then index the raw
pointer directly inside the loop.

---

## 9.2. Release builds compile differently — and that is the point

`Package.swift` builds the `AegisECS` target with

```swift
.unsafeFlags(["-Ounchecked"], .when(configuration: .release))
```

In a release build this switches off Swift's array-bounds and integer-overflow
checks inside the library. It is exactly why the hot accessors —
`ComponentStore.has(_:)`, `indexOf(_:)`, `entityAt(_:)`, all doc-commented as
"deliberately unchecked hot-loop primitives" — can run at raw-pointer speed: in
a debug build the same calls still carry Swift's normal safety checks, so a
misuse is caught as a crash during development instead of silently reading
garbage in production.

The practical consequence: **a debug-build timing tells you almost nothing
about production performance.** Always measure with `swift build -c release`
(or Xcode's Release configuration) before drawing any conclusion about where
time actually goes.

---

## 9.3. Per-entity data pays no ARC cost

`World`, `ComponentStore`, `Scheduler` and `System` are classes — but every one
of them is a single long-lived object: one world, one store per component
type, one scheduler. Swift's automatic reference counting (ARC) charges a
retain/release pair on every reference-counted assignment, but that cost is
paid **once per object**, not once per entity per frame, because no per-entity
data is ever a class instance here. A component's fields are plain `Float`,
`Int32` and similar value types sitting in a store's columns — nothing to
retain, nothing to release, no matter how many entities carry it.

Contrast this with a naive "one class instance per game object" design, where
every read of "the enemy's position" would be a reference dereference with ARC
traffic behind it, scaling with entity count. The struct-of-arrays layout from
§9.1 is also what makes this possible: there is simply nothing per-entity for
ARC to have an opinion about.

---

## 9.4. Why destruction is the most expensive structural operation

Destroying one entity means detaching it from **every** store it participates
in — and `World.flushDestroyQueue()` (the only place real destruction happens;
see [chapter 3](03-world-entities-lifecycle.md)) has to do this for every
queued victim, across every registered store. With many stores and many
victims that is a lot of "entity × store" pairs to resolve, so the library
applies three deliberate optimizations, all visible directly in
`World.swift`/`ComponentStore.swift`:

**1. Iterate by store, not by entity.** `flushDestroyQueue()` hands each store
the *entire* victim list (or its own flagged victims) in one call —
`detachMany(_:count:)` or `detachFlagged(_:)` — rather than asking, for every
victim, "does store A have this? does store B?" one at a time. This keeps each
store's sparse/dense arrays resolved once per call instead of once per pair.

**2. Pick the cheaper traversal per store.** `flushDestroyQueue()` computes
`flaggedLimit = reaped * 2` and, for each store, walks the *store's own*
dense array (`detachFlagged`) when the store holds no more than that many
live components, or walks the *victim list* (`detachMany`) otherwise. A store
much larger than the current victim batch is cheaper to address by victim
list; a small, specialised store is cheaper to just scan outright.

**3. Minimum relocations.** `detachFlagged` trims doomed entries off the
**tail** of the dense array first, so nothing is ever moved into a slot only
to be swap-removed again a moment later. Destroying an entire population moves
**zero** elements — verified directly by the test suite
(`StoreTests.testDetachFlaggedMovesTheMinimum` wipes 64 of 64 entities and
asserts exactly zero relocations).

### What this means for your code

- **Fewer stores — cheaper destruction.** Twenty small, specialised stores
  cost more to tear an entity out of than five merged ones, even when a
  profiler attributes the time to whichever store happened to run last.
- **Spread mass deaths across frames** if the frame budget cannot absorb them
  all at once — queue a bounded batch per frame rather than everything in one
  shot.
- **`World.reset()` is cheaper than a mass `queueDestroy` + flush** when you
  genuinely need to remove everything: `reset()` clears every store directly
  (one `structuralVersion` bump total) instead of running the swap-remove
  machinery for each entity.

---

## 9.5. Batch creation and attachment

`World.createEntities(_:into:)` and `ComponentStore.attachMany(_:count:)`
process a whole run of entities in one call instead of one `createEntity()` +
`attach(_:)` pair at a time. Beyond the obvious savings (one
`structuralVersion` bump for the whole batch instead of one per entity, one
change-log capacity check instead of many), batch attachment guarantees new
components land in **contiguous** dense slots in argument order — useful if
you are about to initialise them by walking that same range.

---

## 9.6. `View` and `Query` do not allocate on the hot path

Covered in full in [chapter 6](06-finding-entities.md), but worth restating
here: `View` never materialises anything — `refreshDriver()` just picks which
required store is currently smallest to drive iteration from. `Query` only
reallocates its result buffer when `maximumResults` or the world's capacity
actually changes; an ordinary `refresh()` call either finds nothing changed
(no-op) or rebuilds into the existing buffer.

**In the hottest systems, skip `View.matches(_:)` entirely** — it is a call
per candidate. `View.requiredSparse(_:)`/`excludedSparse(_:)` hand back the
resolved sparse arrays once; inline the membership test into your own loop
instead.

---

## 9.7. How to measure

Two different tools for two different questions:

- **"Where does my frame's time go, over time?"** — the `Inspector`
  ([chapter 13](13-inspector.md)). It records every frame's per-system cost
  into a rolling window with no allocation after setup, and reports median,
  p95 and — critically — which systems are merely expensive versus which ones
  actually cause the slow frames. A single frame's number, read live, is not
  a reliable guide to anything; the distribution is.
- **"Why is this one call slow?"** — Instruments' Time Profiler on a
  **release** build (§9.2), or a throwaway `XCTest` that brackets the call
  with `DispatchTime.now()` the way the library's own test doubles do
  (`Tests/AegisECSTests/DebugTests.swift`'s `BurnSystem` is exactly this
  pattern turned into a controllable fixture).

### The questions in the right order

1. **Can this work be avoided entirely?** The cheapest operation is the one
   that does not run. Rebuild a spatial grid less often. Skip recomputing
   what has not changed.
2. **Are the parameters set correctly?** A bad `cellSize` costs more than any
   micro-optimisation of code around it (see
   [§8.4](08-spatial-search.md#84-the-one-that-matters-most-choosing-cellsize)).
3. **Can fewer entities be processed?** Drive iteration by the smallest
   required store ([chapter 6](06-finding-entities.md)); move rare traits out
   into `TagStore`s so they can drive small views.
4. **Can indirection be removed from the loop?** Hoisted column pointers and
   sparse arrays, not a `matches()` call per candidate.
5. **Only then** — micro-optimise the arithmetic itself.

### Verify across several runs

A simulation is chaotic: one run proves nothing. Drive several seeds through
an `XCTest` (or a small command-line harness) and compare final counters
across runs, not a single "it looked faster" impression.

---

## 9.8. What the library deliberately does not do

- **Does not bounds-check the hot primitives in release.**
  `has(_:)`/`indexOf(_:)`/`entityAt(_:)` are unchecked under `-Ounchecked` — a
  deliberate, clearly-named trade of safety for speed (§9.2).
- **Does not grow on its own.** `World.reserveCapacity()` is an explicit,
  allocating operation you call at a safe barrier; a hidden allocation inside
  a frame would be a stutter at an unpredictable moment. See
  [`CapacityPolicySystem`](05-systems-and-scheduler.md) for growing
  proactively, on your own schedule, instead.
- **Does not parallelise.** `Scheduler` runs systems strictly sequentially. A
  system's `declareRead`/`declareWrite`/`declareStructuralWrite` access
  metadata and `Scheduler.systemsConflict(_:_:)` exist as groundwork for
  future tooling — they describe which systems *could* safely overlap — but
  nothing in this package actually runs systems concurrently today.

---

## Chapter summary

1. Component data lives in flat columns indexed by dense slot, never as one
   object per entity — that is what makes iteration cache-friendly, in any
   language.
2. Release builds compile with `-Ounchecked`; only release-build numbers mean
   anything.
3. Per-entity data pays no ARC cost — only a handful of long-lived objects
   (the world, each store, the scheduler) are classes at all.
4. Destruction cost is proportional to victims × stores, and the library
   minimises it by iterating per store, choosing the cheaper traversal, and
   moving the theoretical minimum number of elements.
5. Batch creation and attachment over one-at-a-time whenever you can.
6. Measure with the `Inspector` in-app (chapter 13) and Instruments for
   micro-profiling — never trust a single live number, and never trust a
   debug build's timings.

---

[← Spatial search](08-spatial-search.md) | [Contents](README.md) | [Common mistakes →](10-common-mistakes.md)
