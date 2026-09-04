[← Full example](11-full-example.md) | [Contents](README.md)

---

# 12. API reference

The complete list of the public API. The "why it is this way" explanations are
in the relevant chapters, with links added.

---

## `World`

The identifier allocator and store registry. See
[chapter 3](03-world-entities-lifecycle.md).

### Constants

| Constant | Value |
|---|---|
| `kInvalidEntity` | `-1` |
| `kInvalidHandle` | `0` |
| `kMaximumCapacity` | `16_777_216` (2²⁴ — what the handle layout can address) |

### Assembly

| Member | Description |
|---|---|
| `init(entityCapacity:)` | Set the capacity and allocate all buffers at once |
| `registerStore(_:typeID:) -> Bool` | Register a store **before** the first entity |
| `getStore(_ typeID:) -> ComponentStore?` | Lookup by type. For assembly and debugging, **not for the hot loop** |
| `hasStore(_:) -> Bool` | |
| `storeCount: Int32` | |
| `getStore(at:) -> ComponentStore?` | |
| `isSchemaLocked: Bool` | Whether entities have been created yet |

### Creation

| Member | Description |
|---|---|
| `createEntity() -> Entity` | A new id, or **`kInvalidEntity`** if the world is full |
| `createEntities(_:into:capacity:) -> Int32` | Batched into a raw buffer; returns how many were actually created |
| `createEntities(_:into: inout [Entity]) -> Int32` | Batched into a Swift array |
| `createEntityHandle() -> Handle` | Create and get a handle at once |

### Handles

| Member | Description |
|---|---|
| `makeHandle(_:) -> Handle` | A safe reference that survives across frames |
| `entityFromHandle(_:) -> Entity` | Resolve, or `kInvalidEntity` |
| `isHandleAlive(_:) -> Bool` | |
| `getGeneration(_:) -> Int32` | |
| `tag: Int32` | This world's process-wide tag |
| `queueDestroyHandle(_:) -> Bool` | |
| `isHandlePendingDestroy(_:) -> Bool` | |

### Destruction

| Member | Description |
|---|---|
| `queueDestroy(_:) -> Bool` | Mark. Idempotent |
| `queueDestroyMany(_:count:) -> Int32` | Batched; returns how many were newly queued |
| `flushDestroyQueue() -> Int32` | **Structural sync point.** At exactly one point in the frame |
| `isPendingDestroy(_:) -> Bool` | |
| `isAlive(_:) -> Bool` | With a bounds check |

### Capacity and reset

| Member | Description |
|---|---|
| `reserveCapacity(_:) -> Bool` | An explicit allocating barrier. `false` if some store does not support growth |
| `reset()` | Clear the world **with no allocations**; invalidates all handles |
| `capacity: Int32` | Current capacity (read-only) |

### Diagnostics

| Member | Description |
|---|---|
| `getLiveCount()` / `getFreeCount()` / `getRetiredCount()` | |
| `getPendingDestroyCount()` | |
| `getLoadFactor() -> Float` | `live / capacity`, in `0...1` |
| `structuralVersion: Int64` | A monotonic counter of structural changes |
| `validateIntegrity(reportErrors:) -> Bool` | A full check. **Not for a production frame** |
| `clearChangeLogs()` | Clear the logs of every store that has them enabled |

---

## `ComponentStore`

The abstract sparse-set store (`open class`, subclassed). See
[chapter 4](04-components-and-stores.md).

### Public fields

| Field | Description |
|---|---|
| `typeID: Int32` | The type identifier it is registered under |
| `debugName: String` | Optional name for tooling; falls back to `"type N"` |
| `sparseIndex: ContiguousArray<Int32>` | `entity → slot`, or -1. **Read-only from outside** |
| `denseEntities: ContiguousArray<Int32>` | `slot → entity`. **Read-only from outside** |
| `count: Int32` | The number of components = the length of the dense array |
| `structuralVersion: Int64` | Changes only when membership/layout changes |

### The change log ([section 7.2](07-time-events-capacity.md))

| Member | Description |
|---|---|
| `trackChanges: Bool` | Enable the log. `false` by default |
| `addedEntities`, `addedCount` | Valid prefix `0..<addedCount` |
| `removedEntities`, `removedCount` | Valid prefix `0..<removedCount` |
| `changeLogOverflowed: Bool` | `clear()`/`World.reset()` did not log removals element by element |
| `clearChangeLog()` | Clear both logs |

### Operations

| Member | Description |
|---|---|
| `attach(_:) -> Int32` | Attach; idempotent; -1 on overflow |
| `attachMany(_:count:) -> Int32` | Batched; new slots are contiguous from the old `count` |
| `detach(_:)` | Safe, even if there is no component |
| `detachMany(_:count:) -> Int32` | Batched by a list of victims |
| `detachFlagged(_:) -> Int32` | Batched by byte flags; minimum relocations |
| `has(_:) -> Bool` | **No bounds check**, `@inline(__always)` |
| `indexOf(_:) -> Int32` | Slot or -1. **No bounds check**, `@inline(__always)` |
| `entityAt(_:) -> Entity` | **No bounds check**, `@inline(__always)` |
| `clear()` | Empty with no allocations |
| `getDebugName() -> String` | Name for tooling; `debugName`, then `"type N"` |
| `capacity: Int32` | |
| `isInitialized: Bool` | |
| `supportsCapacityGrowth: Bool` | Whether `.growDense` is advertised |
| `validateIntegrity(alive:aliveSize:reportErrors:) -> Bool` | Check the sparse↔dense bijection |

### Required overrides

| Method | Description |
|---|---|
| `reserveDense(_:)` | Allocate your payload arrays |
| `relocateDense(from:to:)` | Relocate data on swap-remove |

### `Hooks` (`OptionSet`) — optional overrides

Advertised by overriding `var hooks: Hooks`. The base class implements none of
them, and calls the matching override only when the bit is set — an
unadvertised hook costs one bit test, never a call.

| Bit | Enables | Override |
|---|---|---|
| `.growDense` | `World.reserveCapacity()` | `growDense(previousCapacity:newCapacity:)` |
| `.relocateBatch` | Batched relocation | `relocateDenseBatch(from:to:moveCount:)` |
| `.releaseDense` | Ownership release before overwrite | `releaseDense(_:)` |
| `.clearRelocated` | Clear the duplicate left behind by a move | `clearRelocatedDense(_:)` |
| `.clearDense` | Bulk cleanup on `clear()` | `clearDense(activeCount:)` |

---

## `PackedStore`

`final class PackedStore: ComponentStore` — the declarative store. Implements
`reserveDense`, `growDense`, `relocateDense` and `relocateDenseBatch`
generically over a schema of `ColumnType`. See [chapter 4](04-components-and-stores.md).

| Member | Description |
|---|---|
| `init(schema: [ColumnType])` | One entry per column, in order |
| `columnCount: Int32` | |
| `columnType(_:) -> ColumnType?` | |
| `columnData(_:) -> UnsafeMutableRawPointer?` | Raw base pointer of a column |
| `columnF32/columnF64/columnI32/columnI64/columnU8(_:) -> UnsafeMutablePointer<T>?` | Typed accessors; `nil` on index or type mismatch |
| `clearSlot(_:)` | Zero every column at a dense slot |

`ColumnType`: `.uint8`, `.int32`, `.int64`, `.float32`, `.float64`, `.vec2`
(2×f32), `.vec3` (3×f32), `.vec4` (4×f32, also a colour's shape).

> Every column pointer is valid **until the world's capacity next grows**
> (`World.reserveCapacity()`) — do not cache one across frames or across a
> growth. See chapter 4's safety rule.

---

## `TagStore`

`final class TagStore: ComponentStore` — a data-less marker component. The
whole API is inherited from `ComponentStore`; `detachMany`/`detachFlagged` are
overridden with specialised versions that perform no relocation at all, since
there is no payload to move.

---

## `View`

A store intersection with no materialization. See
[chapter 6](06-finding-entities.md).

| Member | Description |
|---|---|
| `configure(world:required:excluded:ownerSystem:) -> Bool` | A cold operation, once |
| `refreshDriver()` | Pick the smallest of the required stores |
| `candidateStore: ComponentStore?` | The driver store |
| `candidateCount: Int32` | |
| `driverRequiredIndex: Int32` | The driver's index among the required |
| `matches(_:) -> Bool` | Membership check — a real call per candidate |
| `requiredCount` / `requiredStore(_:)` / `requiredSparse(_:)` | |
| `excludedCount` / `excludedStore(_:)` / `excludedSparse(_:)` | |
| `isConfigured: Bool` | |
| `validateOwnerAccess(reportErrors:) -> Bool` | Metadata-only check against the owner system's declared access |

---

## `Query`

A materialized cache on top of `View`. See [chapter 6](06-finding-entities.md).

| Member | Description |
|---|---|
| `configure(world:required:excluded:ownerSystem:maximumResults:) -> Bool` | `maximumResults: -1` = as large as the world |
| `refresh() -> Bool` | `true` if the cache was rebuilt |
| `isCurrent: Bool` | Whether the cache is up to date, with no rebuild |
| `count: Int32` | The result size |
| `entityAt(_:) -> Entity` | |
| `withEntities<R>(_:) -> R` | Safe unchecked access to the valid `0..<count` prefix |
| `resultCapacity: Int32` | |
| `isTruncated: Bool` | More matched than the buffer holds |
| `rebuildCountValue: Int32` | How many times it was rebuilt |
| `underlyingView: View` | |
| `validateOwnerAccess(reportErrors:) -> Bool` | |

---

## `System`

`open class System`, subclassed. A unit of logic. See
[chapter 5](05-systems-and-scheduler.md).

| Member | Description |
|---|---|
| `systemName: String` | Set in `init()`; shows up in profiling |
| `systemPhase: Int32` | Frozen after `addSystem()` |
| `enabled: Bool` | Runtime switch |
| `requiresTime: Bool` | `true` → the scheduler skips the system when `delta <= 0` |
| `readComponentTypes` / `writeComponentTypes` / `structuralWriteComponentTypes` | Metadata |
| `writesWorldStructure: Bool` | `create`/`destroy`/`reset` |
| `accessMetadataComplete: Bool` | |

| Method | Description |
|---|---|
| `setup(world:context:)` | Once, when everything is ready. Cache references here |
| `execute(delta:)` | Once per frame |
| `teardown()` | In reverse registration order |
| `declareRead(_:)` / `declareWrite(_:)` / `declareStructuralWrite(_:)` | Chainable, `@discardableResult` |
| `hasDeclaredAccess(_:) -> Bool` | |
| `completeAccessMetadata()` | Confirm the description is complete |

---

## `Scheduler`

See [chapter 5](05-systems-and-scheduler.md).

| Member | Description |
|---|---|
| `addSystem(_:phase:) -> System` | Registration order = execution order |
| `setupAll(world:context:) -> Bool` | |
| `teardownAll()` | In reverse order |
| `executeAll(delta:)` | The whole pipeline |
| `beginFrame()` | Close the previous frame's measurements |
| `executePhase(_:delta:)` | One phase; timings **accumulate** until the next `beginFrame()` |
| `setSystemEnabled(_:_:)` / `isSystemEnabled(_:)` | |
| `setPhaseEnabled(_:_:)` / `isPhaseEnabled(_:)` | |
| `isPhaseAllowed(_:) -> Bool` | Whether the system's phase allows it to run |
| `systemCount: Int32` / `getSystemName(_:)` / `getSystem(_:)` / `getSystemPhase(_:)` | |
| `findSystem(_:) -> Int32` | Index or -1 |
| `wasSystemExecuted(_:) -> Bool` | |
| `getTimingUsec(_:) -> Float` | Last frame |
| `getAverageTimingUsec(_:) -> Float` | Smoothed; weight `Scheduler.averageSmoothing = 0.1` |
| `getTotalTimingUsec() -> Float` | |
| `resetProfiling()` | |
| `profilingEnabled: Bool` | Turn measurement off |
| `validatePipeline(world:reportErrors:) -> Bool` | |
| `systemsConflict(_:_:) -> Bool` | Conservative dependency analysis |

---

## `ReaperSystem`

`final class ReaperSystem: System`. The single point of destruction. Register
it **last**.

| Member | Description |
|---|---|
| `init(world:name:)` | Defaults: `world: nil`, `name: "Reaper"` |
| `lastReaped: Int32` | Destroyed this frame |
| `totalReaped: Int64` | Destroyed in total |

Has `requiresTime == false` deliberately: the queue must be drained while
paused too.

---

## `CapacityPolicySystem`

`final class CapacityPolicySystem: System`. Automatic world growth. Register it
**right after the reaper**.

| Member | Description |
|---|---|
| `init(world:name:)` | Defaults: `world: nil`, `name: "CapacityPolicy"` |
| `growThreshold: Float` | Fill fraction to grow at. `0.85` by default |
| `growthFactor: Float` | New capacity multiplier. `1.5` by default |
| `maximumCapacity: Int32` | Ceiling; `0` = no extra limit |
| `checkIntervalFrames: Int32` | `30` by default |
| `onCapacityGrown: ((Int32, Int32) -> Void)?` | `(previous, new)` after growth |
| `growNow() -> Bool` | Force it, ignoring the interval |
| `growthCount`, `lastGrowthCapacity` | Diagnostics |

---

## `SimulationClock`

Fixed step and time scale. See [chapter 7](07-time-events-capacity.md).

| Member | Description |
|---|---|
| `advance(realDelta:) -> Int32` | How many sub-steps to run. **Exactly once per frame** |
| `fixedStep: Float` | The length of a simulation segment |
| `timeScale: Float` | `0` = stop, `1` = real time |
| `maxSubsteps: Int32` | The safety valve against the "death spiral". `8` by default |
| `paused: Bool` | Freeze without losing the accumulator |
| `getLastSubsteps() -> Int32` | |
| `getAlpha() -> Float` | The fraction of the unspent segment, for interpolation |
| `isSaturated() -> Bool` | Whether it is hitting `maxSubsteps` |
| `getEffectiveTimeScale(realDelta:) -> Float` | The actual rate |
| `elapsedSimulated: Float` | The exact sum, with no drift |
| `totalSubsteps: Int64`, `droppedSubsteps: Int64` | |
| `reset()` | |

---

## `UniformSpatialGrid`

A broadphase built on counting sort. See [chapter 8](08-spatial-search.md).

| Constant | Value |
|---|---|
| `UniformSpatialGrid.maxQueryResults` | `2048` |

| Member | Description |
|---|---|
| `configure(arenaRadius:verticalExtent:cellSize:entryCapacity:)` | `verticalExtent: 0` → flat mode |
| `static suggestCellSize(arenaRadius:verticalExtent:expectedEntries:typicalQueryRadius:) -> Float` | A reasoned starting point |
| `rebuild(entityIDs:points:entryCount:)` | A full rebuild (raw-pointer or `[Int32]`/`[SIMDVector3]` overloads) |
| `queryNearest(center:radius:) -> Int32` | The nearest id, or -1. No allocations |
| `querySphere(center:radius:resultLimit:) -> Int` | The count; the ids are in `queryBuffer` |
| `getCellStart(_:)` / `getCellEnd(_:)` | A cell's bounds in the sorted arrays |
| `getEntryCount()` / `getCellCount()` / `getCellSize()` | |
| `getDimensions() -> (Int, Int, Int)` | Cells per axis; `y == 1` in flat mode |
| `isFlat() -> Bool` | |

| Field | Description |
|---|---|
| `queryBuffer: ContiguousArray<Int32>` | The result of the last `querySphere`. **Overwritten by the next query** |
| `queryPointBuffer: ContiguousArray<SIMDVector3>` | Positions; filled only when `storeQueryPoints == true` |
| `storeQueryPoints: Bool` | `false` by default |
| `sortedEntities`, `sortedPoints` | Sorted by cell. **Read-only** |

`SIMDVector3` — this library's own value type: `struct SIMDVector3 { var x, y, z: Float }`.

---

## `AngleMath`

Free functions, independent of the ECS. Radians throughout.

| Method | Description |
|---|---|
| `static wrap(_:_:_:) -> Float` | Wrap a value into `[min, max)` |
| `static approach(_:_:_:) -> Float` | Turn `current` toward `desired` by at most `maxStep`, the short way |
| `static shortestDelta(_:_:) -> Float` | Absolute shortest angular distance, always non-negative |

---

## `Entity`, `Handle` and errors

| Symbol | Description |
|---|---|
| `typealias Entity = Int32` | A raw dense index; not stable across a structural change |
| `typealias Handle = Int64` | Generation + world tag + entity id; safe across frames |
| `kInvalidEntity: Entity` | `-1` |
| `kInvalidHandle: Handle` | `0` |
| `kMaximumCapacity: Int32` | `16_777_216` |
| `AegisDiagnostics.setErrorHandler(_:)` | Install a custom sink for library-reported misuse; `nil` restores stderr |

The library never throws and never traps on misuse: it reports through
`AegisDiagnostics` and returns a sentinel (`-1`, `false`, `nil`) instead.

---

## The debug part

Fully described in [chapter 13](13-inspector.md). `AegisECS` (this whole
reference) contains everything except the panel; `AegisECSInspectorUI` is a
separate library product that adds only `InspectorPanelView`.

### `Inspector`

The single point of attachment.

| Member | Description |
|---|---|
| `static attach(scheduler:world:options:) -> Inspector` | Never returns an optional |
| `capture()` | **As the last line of the frame.** Also measures wall-clock time |
| `refreshNow()` | Recompute aggregates and diagnostics immediately |
| `addCounterSection(_:provider:)` | Application counters |
| `registerQuery(_:_:)` / `registerGrid(_:_:)` / `setClock(_:)` | Objects for diagnostics |
| `getFindings() -> [Diagnostics.Finding]` | Findings, worst first |
| `printReport()` | The text report, to the console |
| `detach()` | Stop collecting; sets `mode = .off` |
| `mode: Inspector.Mode` | `.off` / `.telemetry` / `.inspector` / `.dev` |
| `statsRefreshHz`, `diagnosticsRefreshHz` | Recompute rates |
| `recorder`, `stats`, `diagnostics` | Direct access to the parts |
| `getWorld()` / `getScheduler()` / `getClock()` / `getQueries()` / `getGrids()` | |

`Inspector.Options`: `mode`, `frames`, `budgetUsec`, `clock`, `queries`, `grids`.

### `FrameRecorder`

A ring buffer of frames. Allocates nothing after `configure()`.

| Member | Description |
|---|---|
| `configure(scheduler:world:frames:) -> Bool` | `frames` defaults to `FrameRecorder.defaultFrameCapacity` (240) |
| `capture(substeps:wallFrameUsec:)` | |
| `clear()` | Forget the window without reallocating |
| `frameCount` / `framesSeenCount` | |
| `newestSlot` / `oldestSlot` / `slotInOrder(_:)` / `slotFromNewest(age:)` | |
| `frameTotalUsec(_:)` / `frameWallUsec(_:)` / `frameSubstepsCount(_:)` | |
| `frameLiveCount(_:)` / `framePendingDestroy(_:)` / `frameStructuralDelta(_:)` | |
| `timingUsec(slot:system:)` / `status(slot:system:)` | |
| `systemName(_:)` / `systemPhase(_:)` / `systemRequiresTime(_:)` | |
| `lastCaptureUsec` / `memoryUsage()` | The cost of observing |
| `Status` | `.executed` / `.skippedPaused` / `.disabled` / `.phaseOff` |

### `FrameStats`

| Member | Description |
|---|---|
| `analyse(_:) -> Bool` | Cold path: sorts the window |
| `frameMedianUsec()` / `frameP95Usec()` / `frameMaxUsec()` / `frameAverageUsec()` | |
| `worstFrameSlot() -> Int` | The slot of the worst frame |
| `spikeFrameCount()` / `spikeRatio()` | Are there spikes |
| `systemMedianUsec(_:)` / `systemP95Usec(_:)` / `systemMaxUsec(_:)` | |
| `systemSharePercent(_:)` | Fraction of ECS time |
| `systemVolatility(_:)` | `max / median` — who causes spikes |
| `systemExcessShare(_:)` | Fraction of the excess in slow frames |
| `spikeContributor(_ rank:)` / `spikeContributorCount()` | Ranking of the culprits |
| `liveMin()` / `liveMax()` / `capacityChangeCount()` / `peakPendingDestroy()` | |
| `spikeFactor`, `highPercentile` | Settings |

### `Diagnostics`

| Member | Description |
|---|---|
| `inspect(recorder:stats:world:extras:) -> [Finding]` | Findings, worst first |
| `reset()` | Forget the query rebuild counters |
| `frameBudgetUsec`, `volatilityWarning`, `loadFactorWarning`, `storeFillWarning`, `spikeRatioWarning`, `dominantSharePercent`, `excessShareWarning` | Thresholds |
| `Diagnostics.Finding` | `severity`, `source`, `title`, `detail`, `hint`, `formatted()` |
| `Diagnostics.Extras` | `clock`, `queries`, `grids` — passed into `inspect()` |

### `Report`

| Method | Description |
|---|---|
| `static text(recorder:stats:world:findings:) -> String` | The full report, ready for a console or a ticket |

This is a trimmed port: the original's per-frame JSON/CSV writers are not
included — write your own against `FrameRecorder`'s and `FrameStats`' public
accessors if you need one.

---

[← Full example](11-full-example.md) | [Contents](README.md) | [Inspector →](13-inspector.md)
