[← Components](04-components-and-stores.md) | [Contents](README.md) | [Finding entities →](06-finding-entities.md)

---

# 5. Systems and the scheduler

---

## 5.1. Anatomy of a system

```swift
final class MovementSystem: System {
    private var context: Context!      // your own class

    override init() {
        super.init()
        systemName = "Movement"        // shows up in profiling
        requiresTime = true            // do not run when time is stopped
    }

    override func setup(world: World, context: Any?) {
        self.context = context as? Context   // cache the reference once
    }

    override func execute(delta: Float) {
        // work with data
    }
}
```

### `setup()`

Called **once**, when all stores are registered and the whole pipeline is
assembled. This is the right place to store a reference to the context or to
specific stores.

Caching a reference here is not a violation of the "systems keep no data"
principle: what is cached is a **reference** to an existing store, not a copy of
the data.

The `context` parameter is deliberately typed `Any?`: the library knows nothing
about your game. Downcast it once in `setup` and keep a typed field — from then
on you work with static typing.

### `execute()`

Called once per frame, in the order the scheduler defines.

### `teardown()`

Called by `scheduler.teardownAll()` in the **reverse** order of registration —
resources are torn down like a stack relative to `setup()`.

---

## 5.2. Registration order is a contract

```swift
scheduler.addSystem(SpawnSystem())                     // 1
scheduler.addSystem(MovementSystem())                  // 2
scheduler.addSystem(SpatialIndexSystem())               // 3
scheduler.addSystem(CollisionSystem())                  // 4
scheduler.addSystem(DamageSystem())                     // 5
scheduler.addSystem(ReaperSystem(world: world))          // 6
```

The scheduler **never sorts systems**. Registration order is the complete
specification of behaviour.

The rule: **if system B reads what system A writes in the same frame, A is
registered earlier.**

In the example above the neighbour index (3) is rebuilt **after** movement (2)
and **before** collision search (4). Swap 2 and 3 and collisions are looked for
against last frame's positions. There will be no error; there will be a
different game.

Treat this list as an algorithm, not as formatting. In a serious project it is
worth writing a comment next to each line explaining why the system sits exactly
there.

---

## 5.3. Pause and `requiresTime`

Pause in this library is a **zero step**, not a skipped frame:

```swift
scheduler.executeAll(delta: 0)      // pause
```

This way rendering, the camera, the HUD and input keep working while the
simulation stands still.

To keep a time-dependent system from running while paused, declare it once:

```swift
override init() {
    super.init()
    systemName = "Movement"
    requiresTime = true
}
```

The scheduler skips the call entirely.

| `requiresTime` | What for |
|---|---|
| `true` | Movement, timers, cooldowns, ageing, AI, physics — anything measured in seconds |
| `false` (default) | Rendering, the camera, the HUD, input, buffer uploads, **the reaper** |

> **`ReaperSystem` deliberately leaves `requiresTime` at its default `false`.**
> Entities marked for destruction before the pause must still be cleaned up,
> otherwise they hang in the queue and in every store for the entire duration of
> the pause.

---

## 5.4. Phases

A phase is a **label and a filter**, not a way to order things. The scheduler
does not sort systems, phases or not.

```swift
enum Phase: Int32 {
    case input = 100
    case simulation = 200
    case presentation = 300
}

scheduler.addSystem(InputSystem(), phase: Phase.input.rawValue)
scheduler.addSystem(MovementSystem(), phase: Phase.simulation.rawValue)
scheduler.addSystem(CollisionSystem(), phase: Phase.simulation.rawValue)
scheduler.addSystem(RenderUploadSystem(), phase: Phase.presentation.rawValue)
```

An ordinary frame:

```swift
scheduler.executeAll(delta: delta)
```

A fixed-step frame, where the simulation runs several times and presentation runs
once (see [chapter 7](07-time-events-capacity.md)):

```swift
scheduler.beginFrame()                                          // close the previous frame
for _ in 0..<substeps {
    scheduler.executePhase(Phase.simulation.rawValue, delta: clock.fixedStep)
}
scheduler.executePhase(Phase.presentation.rawValue, delta: delta)
```

`beginFrame()` is mandatory before a series of `executePhase()` calls: it ends the
previous frame's measurement and zeroes the counters. `executeAll()` calls it
itself, as its very first step.

**Timing measurements accumulate** between two `beginFrame()` calls. So a frame
with four sub-steps shows the total cost of those four calls — that is, exactly
what actually landed in the frame budget.

### Switches

```swift
scheduler.setSystemEnabled(index, false)          // disable one system
scheduler.setPhaseEnabled(Phase.simulation.rawValue, false)   // disable a whole group
let index = scheduler.findSystem("Movement")
```

A disabled system keeps its index in the profiler (so the table does not "jump")
and shows zero time.

**A system's phase is fixed for good the moment `addSystem(_:phase:)` runs** —
there is no method to change it afterwards at all, not even through the
scheduler. If a system needs a different phase, register a fresh instance; one
`System` instance belongs to **one** scheduler for its whole lifetime, and
registering the same object in a second scheduler is refused.

---

## 5.5. Profiling

The main performance-diagnostics tool — right on the device.

```swift
for i in 0..<scheduler.systemCount {
    let name = scheduler.getSystemName(i)
    print("\(name)  \(Int(scheduler.getTimingUsec(i))) us  (avg \(Int(scheduler.getAverageTimingUsec(i))))")
}
```

- `getTimingUsec(i)` — time for the **last frame**. Jumps around.
- `getAverageTimingUsec(i)` — an exponentially smoothed value (weight
  `Scheduler.averageSmoothing = 0.1`). This is the one to put on an on-screen
  overlay: it is readable.
- `getTotalTimingUsec()` — the per-frame sum.
- `wasSystemExecuted(i)` — whether the system ran (disabled, or skipped via
  `requiresTime`, returns `false`).
- `resetProfiling()` — zero everything.

The measurement is in **microseconds**, not milliseconds, on purpose: cheap
systems fit into single-digit microseconds, and a millisecond report would be all
zeros.

The measurement itself costs two clock reads per system per frame. If you need to
squeeze out the last bit:

```swift
scheduler.profilingEnabled = false
```

### The shape of a report

Illustrative only — run your own scene through `swift test` or your app's own
build to get real numbers for it:

```
  EnemySpawn                              0   avg      0
  SpatialIndex                          338   avg    336     ← dominates the frame
  MissileSpatialIndex                     6   avg      6
  TurretTargeting                        41   avg     34
  ProjectileImpact                       54   avg     55
  EntityReaper                            1   avg      4
```

The point of a per-system table like this is exactly what it looks like: not to
guess where the frame goes, but to see it directly.

---

## 5.6. Access metadata

An optional description of what a system reads and writes. **It affects neither
the order nor the speed** — it is used by tooling.

```swift
override init() {
    super.init()
    systemName = "Movement"
    requiresTime = true
    _ = declareRead(ComponentType.velocity.rawValue)
        .declareWrite(ComponentType.position.rawValue)
        .declareStructuralWrite(ComponentType.sleeping.rawValue)   // attach/detach of this type
        .completeAccessMetadata()                                  // "the description is complete"
    writesWorldStructure = true                                    // create/destroy/reset
}
```

`declareRead`, `declareWrite`, `declareStructuralWrite` and
`completeAccessMetadata` all return `Self`, so they chain.

What for:

```swift
scheduler.validatePipeline(world: world)   // are all types registered, do phases not run backwards
scheduler.systemsConflict(a, b)            // could these run in parallel
view.validateOwnerAccess()                 // did the system declare what it reads through the View
```

`systemsConflict()` is a conservative dependency analysis. Until a system has
called `completeAccessMetadata()`, its access is considered **unknown**, and it
conflicts with everything — so old code cannot accidentally end up in an unsafe
parallel batch.

`writesWorldStructure = true` always conflicts with everything: creation and
destruction change the validity of raw ids and of every `View`.

> The current scheduler is **sequential**. The metadata is prepared ground, not
> working multithreading. Do not count on automatic parallelisation.

---

## 5.7. Ready-made systems

### `ReaperSystem`

That same "one point of destruction":

```swift
let reaper = ReaperSystem(world: world)
scheduler.addSystem(reaper)      // last

// after the frame:
reaper.lastReaped      // how many were destroyed this frame
reaper.totalReaped     // how many in total
```

`lastReaped` is handy for triggering a death sound or effect: it tells you how
many entities died without making you count them by hand.

### `CapacityPolicySystem`

Automatic world growth — see [chapter 7](07-time-events-capacity.md).

---

## Chapter summary

1. `setup()` — cache references; `execute()` — work; `teardown()` — in reverse
   order.
2. **Registration order is behaviour**, not formatting.
3. Pause is `delta == 0`; a system sets `requiresTime = true` and the scheduler
   skips it on its own.
4. Phases are a filter and a label; no sorting ever happens, and a system's phase
   is fixed for good once it is registered.
5. Measurements accumulate between `beginFrame()` calls, so sub-steps sum up
   correctly.
6. Access metadata changes nothing in execution — it is for validation.
7. `ReaperSystem` — last, and exactly one.

---

[← Components](04-components-and-stores.md) | [Contents](README.md) | [Finding entities →](06-finding-entities.md)
