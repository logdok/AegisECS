[← Contents](README.md)

---

# Aegis ECS architecture

This document describes the extended Aegis model for a large game. The core
principle has not changed from the original GDScript design this package is
ported from: the fastest path is still a plain loop over dense, flat columns.
Safety and generality are added as separate cold-path APIs, so a particle or a
projectile does not pay for features it does not use.

This is a **decision reference**, not a tutorial. If you are looking for "how to
use this", start with the [guide](README.md).

## Layers

```text
World
  ├─ raw-id allocator + deferred destroy queue
  ├─ batched createEntities() / queueDestroyMany()
  ├─ generation + world tag → a safe cross-frame Handle
  ├─ registry of ComponentStore sparse sets
  └─ explicit capacity barriers and integrity checks

Stores
  ComponentStore            sparse set, hooks advertised explicitly
    ├─ PackedStore          declarative: a ColumnType schema — and nothing else
    └─ TagStore             no payload, specialised batch removal

Iteration
  ├─ direct sparse loop     fastest, joined by hand
  ├─ View                   a live filter with no allocations
  └─ Query                  a pre-allocated membership cache

Execution
  Scheduler
    ├─ registration order is behaviour
    ├─ system/phase switches, requiresTime skipping
    ├─ read/write metadata and conflict analysis
    └─ profiling (per-frame accumulation + a smoothed average)

Ready-made systems
  ├─ ReaperSystem            the single point of destruction
  └─ CapacityPolicySystem    grows before the world fills up

Helpers
  ├─ SimulationClock        fixed step, time scale, safety valve
  ├─ UniformSpatialGrid     broadphase on counting sort, flat mode
  └─ AngleMath              turn an angle along the shortest path

UI (separate product)
  AegisECSInspectorUI
    └─ InspectorPanelView    SwiftUI panel over Inspector — see chapter 13
```

## Raw id and the generational handle

A raw `Entity` (`Int32`) is an index from `0` to `capacity - 1`. It directly
addresses `sparseIndex`, so it stays the cheapest representation in the hot
loop.

A raw id must not be treated as a stable reference across a structural sync
point. After destruction, the same index can be handed to a different entity.
For a target, an owner, a UI selection, a scheduled callback and an external
queue, a positive 63-bit `Handle` (`Int64`) is used instead:

```text
bits  0..23  raw entity id     (up to 16,777,216 slots)
bits 24..47  generation        (up to 16,777,215 lives per slot)
bits 48..62  in-process world tag
bit      63  0
```

```swift
let entity = world.createEntity()
let handle = world.makeHandle(entity)

// Many frames later:
let resolved = world.entityFromHandle(handle)
guard resolved != kInvalidEntity else { return }
```

A handle is rejected if the world tag, the generation, the range or the "alive"
state does not match. On generation overflow the slot becomes **retired** and
is never handed out again: an old handle cannot come back to life even in
theory. World tags are not reused; `World.nextWorldTag` is a process-wide
counter, so after 32,767 worlds created in one process, new worlds work with
raw ids but `makeHandle`/`entityFromHandle` report an error (`kInvalidHandle` /
`kInvalidEntity`) instead of resolving.

A runtime handle is **not** a save/network ID: the world tag is scoped to one
process run and is not stable across a relaunch. Between runs, use your own
domain-stable key.

## Lifecycle and structural epochs

```text
FREE → ALIVE → PENDING_DESTROY → FREE
                              ↘ RETIRED on generation overflow
```

`queueDestroy*()` does not change any store. A marked entity and its handle
stay valid until `flushDestroyQueue()`. The flush is a structural sync point:

1. re-checks the generation-stamped key recorded in the queue;
2. detaches the entity from every store;
3. performs swap-remove and cleanup hooks;
4. marks the entity dead;
5. advances the generation (`nextGeneration`);
6. and only then returns the raw id to the free stack — or retires the slot if
   the generation counter is exhausted.

The flush can sit at several phase boundaries. It cannot run in the middle of a
system, nor can a system keep a dense slot across that boundary. A generational
handle cures a stale entity reference, but not a stale dense slot or a stale
`PackedStore` column pointer.

`reset()` invalidates the handles of all active and marked entities, clears the
stores and the queue, but keeps the registrations and the capacity. The schema
is locked by the first successful `createEntity()`; all stores must be
registered in advance.

## Stores and reference cleanup

A store is a sparse set with a bidirectional mapping:

```text
sparseIndex[entity]  → dense slot or -1
denseEntities[slot]  → entity
payload[slot]        → component data
```

A subclass always implements `reserveDense(_:)` and `relocateDense(from:to:)` —
`ComponentStore` declares them as required overrides, and the base
implementation calls `fatalError()` if a subclass omits either, so forgetting
one is caught immediately rather than silently. If the payload owns a
reference-counted resource, the store advertises the matching hooks:

```swift
final class OwningStore: ComponentStore {
    var resources: [SomeManagedResource?] = []

    override var hooks: Hooks { [.growDense, .releaseDense, .clearRelocated] }

    override func releaseDense(_ slot: Int32) {
        resources[Int(slot)] = nil   // ARC releases it; no manual free needed
    }

    override func clearRelocatedDense(_ slot: Int32) {
        resources[Int(slot)] = nil   // ownership already moved; do not release again
    }
}
```

Detach first calls `releaseDense(removedSlot)`, then relocates the last payload
and calls `clearRelocatedDense(lastSlot)`. These two must not be mixed up:
otherwise the removed resource leaks (never set to `nil`) or the relocated one
gets released twice. Without the hooks, the store's own dense array keeps
holding a strong reference to every removed element's old resource forever —
ARC alone does not save you here, because the array slot itself is still
"holding" it.

`structuralVersion` changes on a new attach, a successful detach, a non-empty
clear and capacity growth. A payload write does not change it: query membership
stays the same.

## Choosing between the direct loop, View and Query

### The direct loop

Use it in the hottest systems with a known schema. The smallest store is chosen
as the driver, and the rest of the components are checked via sparse arrays.

```swift
let entities = velocities.denseEntities
let positionSlots = positions.sparseIndex
for velocitySlot in 0..<Int(velocities.count) {
    let entity = entities[velocitySlot]
    let positionSlot = positionSlots[Int(entity)]
    if positionSlot == -1 { continue }
    // ...
}
```

### `View`

`View` resolves the required/excluded type IDs once. `refreshDriver()` picks
the smallest required store, `matches(_:)` reads the current sparse sets. After
`configure()` the steady-state API builds no result array and allocates
nothing.

A `View` is more convenient than joining by hand, but `matches(_:)` remains a
method call per candidate. For the hottest systems, take the sparse arrays from
the view (`requiredSparse(_:)`/`excludedSparse(_:)`) and inline the check into
your own loop — resolving the arrays once and testing them directly is what
actually removes the per-candidate call.

### `Query`

`Query` materializes entity ids into a pre-allocated buffer. By default its
size equals `world.capacity`; an optional `maximumResults` limits the buffer
for a query with a known upper bound. `Query` tracks each tracked store's
`structuralVersion` and skips the rebuild if none changed (`isCurrent`).

```swift
if query.refresh() {
    // membership really changed
}
query.withEntities { buf in
    for index in 0..<Int(query.count) {
        let entity = buf[index]
    }
}
```

The rebuild lifts every participating sparse array into a local before the loop
and — when there is nothing to test beyond the driver store — copies straight
from the driver's dense array with no `matches()` call at all.

With a bounded buffer, `count` never exceeds `maximumResults`, and
`isTruncated` reports that there were more matching entities. Without a limit,
the result memory is roughly `4 bytes × world.capacity` per `Query` (an `Entity`
is an `Int32`): 100 full queries at a capacity of 1,000,000 would take about
381 MiB.

`withEntities { buf in ... }` removes the per-element method call, but the
buffer is read-only and must not be kept across `refresh()` or
`world.reserveCapacity()`.

`View`/`Query` require at least one required type: the world deliberately does
not keep a second dense list of "everyone alive" just for a component-less
query.

## The scheduler, phases and metadata

The scheduler never sorts systems. Registration order remains the complete
specification of behaviour. A phase is a filter and metadata:

```swift
scheduler.addSystem(InputSystem(), phase: 100)
scheduler.addSystem(MovementSystem(), phase: 200)
scheduler.addSystem(RenderUploadSystem(), phase: 300)
scheduler.addSystem(ReaperSystem(world: world), phase: 400)
```

An ordinary frame uses `executeAll(delta:)` — it calls `beginFrame()` for you as
its first step. If phases are instead called from different places in your own
code, close the previous frame once yourself:

```swift
scheduler.beginFrame()
scheduler.executePhase(100, delta: delta)
scheduler.executePhase(200, delta: delta)
scheduler.executePhase(300, delta: delta)
scheduler.executePhase(400, delta: delta)
```

Measurements **accumulate** between two `beginFrame()` calls, so a fixed-step
frame that runs the simulation phase four times reports the total cost of
those four sub-steps — that is, what actually landed in the frame budget. The
smoothed average is folded once per frame, not per sub-step.

`enabled` and phase toggling do not remove systems, so the profiler indices are
stable. A disabled system gets timing `0` and `wasSystemExecuted(_:) == false`.

### `requiresTime` skipping

Pause is a zero step, not a skipped frame. Without this, every time-dependent
system would have to begin with `if delta <= 0 { return }`, and forgetting that
line is a silent bug. Instead a system sets `requiresTime = true`, typically in
`init()`, and the scheduler skips the call entirely — which is both safer and
avoids the call.

`ReaperSystem` deliberately leaves `requiresTime == false`: entities marked for
destruction before the pause must still be cleaned up, otherwise they hang in
the queue and in every store for the whole duration of the pause.

### Access metadata

Declared once, typically in `init()`:

```swift
_ = declareRead(ComponentType.input.rawValue)
    .declareWrite(ComponentType.position.rawValue)
    .declareStructuralWrite(ComponentType.sleeping.rawValue)
writesWorldStructure = true   // create/destroy/reset
_ = completeAccessMetadata()
```

The metadata does not change execution order and adds no runtime checks during
`execute()`. It is used by `validatePipeline(world:)`, by `View`/`Query`'s
`validateOwnerAccess(reportErrors:)`, and by `systemsConflict(_:_:)`. The
latter conservatively answers whether two systems could enter a future
parallel batch. Until a system has called `completeAccessMetadata()`, its
access is considered unknown and it conflicts with any other — so a system
that never opted in cannot accidentally end up judged safe for an unsafe
parallel batch. The current scheduler remains sequential.
`writesWorldStructure` always conflicts with every system: create/destroy/reset
change the validity of raw ids and of every `View`, even for a system with no
declarations of its own.

A system's `systemPhase` is frozen the moment `addSystem(_:phase:)` assigns it
— there is no method to move a registered system to a different phase
afterward; register it under the right phase the first time. One system
instance cannot be shared between two schedulers, or registered twice in the
same one — both are refused with a diagnostic.

`teardownAll()` calls the systems in reverse order — resources are torn down
like a stack relative to `setup`.

## Capacity growth

The steady-state frame never grows automatically. If the forecast changed:

```swift
// loading screen / stopped pipeline
world.reserveCapacity(200_000)
```

The world and all registered stores grow together; existing raw ids, handles
and dense slots are preserved (but not cached `PackedStore` column pointers —
re-fetch those after any growth). The app's own external buffers (a render
batch, a physics broadphase, a network array) the library cannot grow — that is
the loading code's job. `Query` adapts its cache on the next `refresh()`.

Growth support for a custom store is opt-in, declared explicitly:

```swift
override var hooks: Hooks { [.growDense] }

override func growDense(previousCapacity: Int32, newCapacity: Int32) {
    positions.reserveCapacity(Int(newCapacity))
    while positions.count < Int(newCapacity) { positions.append(0) }   // preserve [0, count)
}
```

There is no separate boolean flag: a store supports growth if and only if it
advertises `.growDense` in its overridden `hooks`. Unlike the original
GDScript add-on — which detected an override via `has_method()` reflection at
registration time, because the base class deliberately did not declare the
method — Swift has no equivalent runtime reflection, so the check is explicit
and compile-time-shaped: `ComponentStore.initialize()` reads `hooks` exactly
once and caches the result in `cachedHooks`, a private `OptionSet`. Every hot
path afterward (`detach`, `detachMany`, `detachFlagged`) tests a bit in that
cached value — `cachedHooks.contains(.releaseDense)` and so on — never a
dynamic dispatch or a reflection call. Publicly the state is available as
`store.supportsCapacityGrowth`. `PackedStore` always advertises `.growDense`
(and `.relocateBatch`); `TagStore` advertises `.growDense` alone, since it has
no payload to preserve.

Before changing any array, the world checks the capacity and growth support of
every store. If at least one is not opted in, `reserveCapacity(_:)` returns
`false` without changing either the world or any store. There is no direct
public growth of an individual store: its capacity cannot be desynchronized
from its owner through the standard API.

## Hooks are resolved once, not detected per call

The same mechanism applies to every optional store hook:

```text
.growDense          -> enables World.reserveCapacity()
.relocateBatch       -> enables batched payload relocation
.releaseDense         -> enables the ownership path of detach
.clearRelocated        -> clearing the moved-from duplicate
.clearDense             -> bulk cleanup on clear()/reset()
```

A subclass advertises the bits it implements by overriding `var hooks: Hooks`.
Because the base class overrides nothing implicit and `cachedHooks` is resolved
once at `initialize()` rather than probed per call, there is no runtime cost
difference between "this hook is declared" and "this hook is not" beyond the
single bit test already needed to branch. This removes the whole class of bug
the original's `has_method()` scheme was built to avoid in the first place: a
boolean flag that can be set wrong (forgot to set it → a resource quietly
leaks; set it needlessly → you pay for an unused path). In this port there is
no separate flag to get out of sync with the overrides at all — `hooks` and the
overrides are the same declaration.

## Batched destruction

`flushDestroyQueue()` is the most expensive structural operation: destroying
one entity means detaching it from **every** registered store. With 12 stores
and 10,000 entities that is 120,000 pairs to consider.

The implementation is store-major, not entity-major, and adaptive:

```text
1. Re-check the generation-stamped keys from the queue and compact the
   survivors into the front of that same array — it then serves directly as
   the list of victims; there is no separate scratch buffer.
2. For each store, pick the cheaper traversal:
      count <= reaped * 2   -> detachFlagged(flags)      — O(count)
      otherwise              -> detachMany(queue, count: reaped) — O(reaped)
3. Finish the lifecycle: alive = 0, generation = nextGeneration(...), return
   the id to the free stack (or retire the slot).
```

**Why store-major.** `detachMany`/`detachFlagged` resolve `sparseIndex` and
`denseEntities` into local buffer pointers once, outside the entity loop
(`withUnsafeMutableBufferPointer`), so a store/entity pair with no component
costs one bounds-free array read instead of a property access routed through
`self`. A typical entity has only some of the components, so it is this skip
path that dominates the total cost.

**Why adaptive.** A store holding a single entity (a turret, the player) should
not scan 10,000 victims to find it. Walking its own dense array with a byte-
flag check costs `O(count)`, which is what `detachFlagged` does — and `count`
is small for such a store regardless of how large the destroy queue is.

**Why `detachFlagged()` is faster on a mass death.** Knowing in advance which
elements are doomed, it does not move a doomed element into a just-freed slot
only to remove it the next step: flagged elements are trimmed off the tail
first — they need no relocation at all — and only then do the survivors fill
the remaining holes. Destroying the whole population performs **zero**
relocations instead of one per removal (verified directly by the test suite:
`StoreTests.testDetachFlaggedMovesTheMinimum` wipes 64 of 64 entities and
asserts exactly zero calls to `relocateDense`).

The threshold `count <= reaped * 2` is a real constant in `World.swift`, not
just documentation: the store's own doc comment explains the trade-off it
encodes — "the store wins while it is not much larger than the victim list;
past roughly twice the size the extra iterations outweigh the saved moves." A
conservative 2x is taken rather than tuned per store.

`detachMany()` (driven by an explicit victim list, not flags) cannot relocate
less: given only the list of victims, it has no cheap way to answer "is the
tail element also doomed?" without the flag array `detachFlagged` has access
to.

### Batched payload relocation

When a store has no ownership hooks, nothing reads the payload while the loop
runs, so every relocation can be recorded and applied afterward, in one pass,
in the same order — equivalent to interleaving them, but letting the subclass
resolve its arrays once for the whole operation instead of once per move. This
is exactly what `PackedStore.relocateDenseBatch` does:

```swift
public override func relocateDenseBatch(from: UnsafePointer<Int32>, to: UnsafePointer<Int32>, moveCount: Int32) {
    for column in columns {
        let base = column.storage.baseAddress!
        let stride = column.stride
        for move in 0..<Int(moveCount) {
            memcpy(base.advanced(by: Int(to[move]) * stride),
                   base.advanced(by: Int(from[move]) * stride), stride)
        }
    }
}
```

Resolving each column's base pointer once and then walking every move, instead
of once per move, is where the batched destruction path gets most of its
speed advantage over a naive per-entity `relocateDense` loop.

A store with ownership uses the interleaved path instead: `releaseDense(_:)`
is obliged to run **before** the payload is overwritten, so relocation cannot
be deferred and batched the same way — `ComponentStore.detachMany` branches on
exactly this (`.releaseDense` present → interleaved; `.relocateBatch` present
and no ownership → batched; neither → per-move fallback).

## Validation and testing

`world.validateIntegrity(reportErrors:)` checks:

- `live + free + retired == capacity`;
- uniqueness of the free list and the destroy queue;
- that the destroy flags match the queue;
- the "alive" state of every entity referenced by a store;
- the sparse↔dense bijection and slot bounds, in every store;
- equal capacity between the world and every store.

The check is linear and allocates temporary debug buffers, so it must not run
every production frame.

```bash
swift test
```

runs the whole suite; `swift test --filter <TestCaseName>` runs one. The suite
that plays the role of the original add-on's structural self-checks:

- **`WorldTests`** — allocation and exhaustion, batch creation matching
  one-at-a-time creation, deferred destruction, the generational-handle ABA
  guard (a recycled raw id does not resurrect an old handle; a handle from one
  `World` never resolves in another), capacity growth (handles and payload
  both survive it), and `reset()`.
- **`StoreTests`** — swap-remove, batched attach contiguity, and — the
  differential check the original relied on — `testDetachManyMatchesRepeatedDetach`
  runs the same removals through `detach()` one at a time on one store and
  through `detachMany()` on an identical twin store, then asserts the final
  entity → payload mapping is identical between the two. The optimized path is
  obliged to be indistinguishable from the naive one; a differential test
  against the naive path is the reliable way to check that.
- **`PipelineTests`** — registration order as behaviour, pause as a zero step,
  system/phase switches, `ReaperSystem`, `CapacityPolicySystem`, `View`'s
  smallest-store driver selection, `Query`'s materialized cache and cache-hit
  detection.
- **`SpatialAndTimeTests`**, **`DebugTests`** — the spatial grid against a
  brute-force reference, the fixed-step clock, angle math, and the
  recorder/stats/diagnostics pipeline (chapters 8, 7, 13).

`relocateDense(from:to:)` cannot be checked once and for all for an arbitrary
payload — every custom store needs its own relocation test with
distinguishable values in every field, the way `StoreTests`' `CountingStore`
uses recognisable float values specifically so a misrouted move is visible in
an assertion.

## Recommended structure for a large game

- One `World` per independent simulation/match, not a global singleton.
- Type IDs are a single module-level enum (`enum ComponentType: Int32`),
  registered before the first entity.
- Hot, cohesive data may be kept in one store; optional traits and rare
  subsystems are moved out into separate stores/tags.
- Raw ids do not leave systems; public services, UI and callbacks get a
  `Handle` or a domain-specific stable id.
- Structural writers are grouped into clear phase boundaries.
- Direct loops are used after profiling, not by default everywhere.
- `validateIntegrity(reportErrors: false)` runs in CI/fuzz and on a debug-panel
  command.
- The save/network layer serializes the domain schema, not the internal dense
  slots.
- Data-only stores extend `PackedStore`; a hand-written `ComponentStore`
  remains for non-standard layouts or owned resources.
- Destruction goes through a single `ReaperSystem`, registered last;
  `CapacityPolicySystem` right after it.
- Time-dependent systems declare `requiresTime = true` instead of a manual
  `delta <= 0` check.
- A reaction to appearance/death goes through the store's opt-in change log,
  not through ad-hoc callbacks scattered across systems: the reader sits right
  after the reaper.
- A controlled time rate goes through `SimulationClock` with a fixed step; a
  raw `delta × timeScale` desynchronizes the simulation across thresholds.

## Deliberate limitations

Aegis provides no archetype chunks, no automatic parallel scheduler, no
rollback/snapshot protocol and no universal serialization. Reactivity exists,
but as an explicit opt-in log of structural changes rather than an event/
callback system: the cost of enabling it is visible, and a disabled log costs
one branch per structural operation.

The newer APIs give a safe foundation for a large game without turning the
compact core into a hidden runtime with unpredictable cost.

---

[← Contents](README.md)
