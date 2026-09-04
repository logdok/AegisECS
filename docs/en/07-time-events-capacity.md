[← Finding entities](06-finding-entities.md) | [Contents](README.md) | [Spatial search →](08-spatial-search.md)

---

# 7. Time, events, capacity

Three tools that cover typical simulation needs: a controlled time rate, a
reaction to entities appearing and disappearing, and world growth for an
unpredictable population.

---

## 7.1. SimulationClock — fixed step and time scale

### The problem

Passing the frame's raw `delta` straight into the simulation is fine only as long
as that delta is small. The moment the player can **speed time up**, everything
breaks: at a scale of 50×, a 16 ms frame turns into an 800 ms step.

And then anything that advances by a threshold **jumps over** several thresholds
in a single update:

- a cell that divides at age 10, in one step lives through age 0 → 12 and divides
  once instead of twice;
- a projectile "teleports" through its target, because a point hit test does not
  see the intermediate positions;
- a 0.2 s cooldown fires once instead of four times.

The simulation does not just run faster — it **produces a different result**. And
on a slower machine, a different one again, because delta is larger there.

### The solution

`SimulationClock` accumulates real time, multiplies it by the scale and reports
how many **identical** fixed-size segments fit into it.

```swift
let clock = SimulationClock()
clock.fixedStep = 1.0 / 60.0      // the length of one simulation segment
clock.timeScale = 4.0             // speed-up
clock.maxSubsteps = 8             // safety valve (this is the default)
```

### Using it with phases (recommended)

```swift
func tick(delta: Float) {
    let steps = clock.advance(realDelta: delta)

    scheduler.beginFrame()
    for _ in 0..<steps {
        scheduler.executePhase(Phase.simulation, delta: clock.fixedStep)
    }
    // Presentation — exactly once per frame, with the REAL delta.
    scheduler.executePhase(Phase.presentation, delta: delta)
}
```

**Notice the two different deltas.** The simulation gets `fixedStep`,
presentation gets the frame's real time. Running the whole pipeline through the
sub-step loop would mean doing the rendering work N times per frame for no
benefit.

When `steps == 0` (pause, or less than one segment accumulated), the presentation
phase still runs — that is exactly what keeps the app drawn.

### Using it without phases

```swift
let steps = clock.advance(realDelta: delta)
if steps == 0 {
    scheduler.executeAll(delta: 0)                 // only systems without requiresTime
} else {
    for _ in 0..<steps {
        scheduler.executeAll(delta: clock.fixedStep)
    }
}
```

This connects directly to [chapter 5](05-systems-and-scheduler.md#pause): pause
is `delta == 0`, and that is exactly what `advance(realDelta:)` produces when
`timeScale == 0` — zero substeps, so `executeAll`/`executePhase` never even see a
non-zero delta for that frame.

### The safety valve against the "death spiral"

`maxSubsteps` is not just a limit. It is protection against a known pathology:
if one frame was slow, more time accumulated; running all the accumulated time
makes the frame even slower, which accumulates even more — and the app hangs
forever.

Beyond `maxSubsteps` the surplus is **discarded**, not banked: the simulation
briefly runs in slow motion instead of locking up.

```swift
clock.droppedSubsteps     // how many segments were dropped in total
clock.isSaturated()       // is it hitting the limit right now
```

A constantly growing `droppedSubsteps` means the machine cannot keep up with the
requested `timeScale`. This is an honest signal, not an error.

### Interpolation

If the simulation rate is lower than the frame rate, movement looks steppy.
`getAlpha()` returns the fraction of the unspent segment in `[0, 1)`:

```swift
let alpha = clock.getAlpha()
let drawnPosition = previousPosition.lerp(currentPosition, alpha)
```

### The full API

```swift
clock.advance(realDelta:) -> Int32     // call EXACTLY once per frame
clock.fixedStep                        // the segment length
clock.timeScale                        // 0 = stop, 1 = real time, 50 = fast
clock.maxSubsteps                      // safety valve
clock.paused                           // freeze without losing the accumulator
clock.getLastSubsteps()
clock.getAlpha()
clock.isSaturated()
clock.getEffectiveTimeScale(realDelta:) // actual vs requested rate
clock.elapsedSimulated                 // the exact sum, with no drift
clock.totalSubsteps
clock.droppedSubsteps
clock.reset()                          // on a level restart
```

> `elapsedSimulated` grows by exactly `fixedStep` per segment, so it is
> **exact**, unlike the sum of fractional deltas, which accumulates error.

---

## 7.2. The change log — reacting to birth and death

The library deliberately has no "component added / removed" events: a
notification per structural change at tens of thousands of entities would cost
more than the work itself.

Instead there is a **structural change log**, enabled per store — it lives on
`ComponentStore` itself, so it works the same for a `PackedStore`, a `TagStore`
or a hand-written store.

```swift
enemies.trackChanges = true
```

While the flag is off (the default), it costs **one branch per structural
operation**, that is, effectively nothing. Turning it on lazily allocates the
log arrays the first time.

### Reading the log

```swift
final class DeathEffectSystem: System {
    private var context: Context!

    override init() {
        super.init()
        systemName = "DeathEffects"
        _ = completeAccessMetadata()
    }

    override func setup(world: World, context: Any?) {
        self.context = context as? Context
    }

    override func execute(delta: Float) {
        let enemies = context.enemies

        for i in 0..<Int(enemies.addedCount) {
            spawnAppearEffect(enemies.addedEntities[i])
        }
        for i in 0..<Int(enemies.removedCount) {
            spawnDeathEffect(enemies.removedEntities[i])
        }

        context.world.clearChangeLogs()
    }
}
```

### Where to put the reader system

**Right after `ReaperSystem`.** At that point:

- `addedEntities` holds everything that appeared this frame;
- `removedEntities` holds everything that died this frame (the reaper has
  already run).

```swift
scheduler.addSystem(SpawnSystem())
scheduler.addSystem(CombatSystem())
scheduler.addSystem(ReaperSystem(world: world))
scheduler.addSystem(DeathEffectSystem())     // ← reads the log and clears it
```

### Rules

- The valid prefixes are `0..<addedCount` and `0..<removedCount`. The arrays
  themselves may be larger; the rest is garbage.
- **The order is undefined.** Do not rely on it.
- An entity created and destroyed in the same frame lands in **both** logs. This
  is correct.
- `clear()` and `world.reset()` **do not write** individual removals — they
  raise the `changeLogOverflowed` flag instead. Running the whole population
  through the log on a level restart is not what the calling code wants; a
  reader must check this flag and treat it as "assume everything changed"
  rather than trusting an incomplete `removedEntities`.
- `world.clearChangeLogs()` clears the logs of every store that has tracking
  enabled.

### Cost

Enabling it allocates two buffers that grow by doubling until they reach the
size of typical per-frame churn. After that — constant memory and one array
write per structural operation.

---

## 7.3. Capacity and growth policy

### Explicit growth

```swift
if world.reserveCapacity(200_000) {
    resizeMyRenderBuffers(200_000)
}
```

The world and **all** registered stores grow together; existing raw ids, handles
and dense slots stay valid.

This is an **allocating barrier**. Call it on a loading screen or at an explicit
phase boundary — never in the middle of a system pass.

If at least one registered store does not advertise the `.growDense` hook (see
[chapter 4](04-components-and-stores.md)), the call returns `false` **without
changing anything**. `PackedStore` and `TagStore` support it always.

> The library can grow only its **own** buffers. Everything your app allocated
> alongside — a render buffer, physics batches, network arrays — is your
> responsibility; `CapacityPolicySystem.onCapacityGrown` is exactly the hook to
> resize those from.

### The automatic policy

For a simulation with explosive population growth — cell division, a chain
reaction, waves — waiting for `world.createEntity() == -1` is too late: spawns
have already started being lost.

```swift
let policy = CapacityPolicySystem(world: world)
policy.growThreshold = 0.8          // grow at 80% fill
policy.growthFactor = 1.5           // new capacity = old × 1.5
policy.maximumCapacity = 500_000    // ceiling; 0 = no limit
policy.checkIntervalFrames = 30
policy.onCapacityGrown = { previous, next in
    renderBuffer.resize(next)
    print("world grew: \(previous) → \(next)")
}

scheduler.addSystem(ReaperSystem(world: world))
scheduler.addSystem(policy)          // ← RIGHT after the reaper
```

**Register it right after the reaper**, or on another explicit phase boundary:
growth reallocates every buffer, so no system may be holding a dense slot or an
array alias across that call.

A forced check, if you know a spike is coming:

```swift
policy.growNow()
```

Diagnostics: `policy.growthCount`, `policy.lastGrowthCapacity`.

### How much capacity to take upfront

Memory per entity, read off the actual field widths:

- **the world:** 19 bytes of bookkeeping per entity (`alive` + `destroyFlag` +
  `retired` are 1 byte each; `freeIDs`, `destroyQueue`, `destroyGeneration`,
  `generations` are 4 bytes each);
- **each store:** 8 bytes (`sparseIndex` + `denseEntities`, 4 bytes each) plus
  the payload size.

For 100,000 entities and 10 stores with a 16-byte payload each (four `float32`
columns), this is about `100k × (19 + 10 × (8 + 16)) ≈ 25.9 MB`. Allocating more
than you need upfront is almost always cheaper than growing during play.

---

## Chapter summary

1. `SimulationClock` makes the simulation **reproducible** at any time rate; raw
   delta does not.
2. The simulation gets `fixedStep`, presentation gets the real `delta`.
3. `maxSubsteps` is the safety valve against the death spiral; dropped segments
   are visible via `droppedSubsteps`.
4. The change log (`trackChanges` on `ComponentStore`) is your "birth and death
   events"; the reader goes right after the reaper and clears the log itself.
5. `reserveCapacity()` is an allocating barrier; only at a safe boundary.
6. `CapacityPolicySystem` grows **ahead of time**, not after spawns are lost.

---

[← Finding entities](06-finding-entities.md) | [Contents](README.md) | [Spatial search →](08-spatial-search.md)
