[← Common mistakes](10-common-mistakes.md) | [Contents](README.md) | [API reference →](12-api-reference.md)

---

# 11. Full example: a colony in a Petri dish

This chapter walks through one representative simulation, assembled to exercise
**everything** the earlier chapters describe. It is a teaching example, written
out in full below — not a script shipped in this repository the way the
original GDScript add-on's `colony_example.gd` was; drop it into an executable
target or a throwaway `XCTestCase` of your own if you want to actually run it.

Cells wander, spend energy, push each other apart, divide when well-fed and die
when starving.

| What is used | Why it is here |
|---|---|
| `PackedStore` | payload with no boilerplate |
| `TagStore` | a "ready to divide" trait with no data |
| `UniformSpatialGrid` | "who is nearby", in flat mode |
| `SimulationClock` | speeding time up without desync |
| the change log | reacting to birth and death |
| `CapacityPolicySystem` | the population can double in seconds |
| `ReaperSystem` | the single point of destruction |
| phases | simulation sub-steps vs once-per-frame work |

A plausible run looks like this:

```
grid: cellSize=6.00, cells=441, flat=true
seeded 200 cells

frame  population  births  deaths  capacity
    0         200     200       0       512
   60         584     584       0      1024
  120        1210    1210       0      2048
  180        1416    1418       2      2048
  240        1401    1474      73      2048
  300        1332    1533     201      2048

--- result ---
simulated 48.0 s of colony time in 360 rendered frames (timeScale 8)
population 1322, peak 1440, births 1600, deaths 278
capacity grew 2 times, now 2048
dropped substeps: 0
```

Growth → capacity grows twice → saturation with mortality → stabilization. Not
a single dropped sub-step.

---

## 11.1. Components

```swift
enum ComponentType: Int32 {
    case cell, dividing
}

final class ColonyCellStore: PackedStore {
    private enum Column: Int32 {
        case position, heading, energy, age, crowding
    }

    init() {
        super.init(schema: [.vec3, .float32, .float32, .float32, .float32])
    }

    var position: UnsafeMutablePointer<SIMDVector3> {
        columnData(Column.position.rawValue)!.assumingMemoryBound(to: SIMDVector3.self)
    }
    var heading: UnsafeMutablePointer<Float> { columnF32(Column.heading.rawValue)! }
    var energy: UnsafeMutablePointer<Float> { columnF32(Column.energy.rawValue)! }
    var age: UnsafeMutablePointer<Float> { columnF32(Column.age.rawValue)! }
    var crowding: UnsafeMutablePointer<Float> { columnF32(Column.crowding.rawValue)! }
}

let cells = ColonyCellStore()
let dividing = TagStore()
world.registerStore(cells, typeID: ComponentType.cell.rawValue)
world.registerStore(dividing, typeID: ComponentType.dividing.rawValue)
```

**Why everything is in one store.** These five columns are read **together**,
every step, by the same systems. Splitting them across five stores would mean
adding four `sparseIndex` lookups to the hottest loop, for no gain (chapter 4).

**Why `crowding` is a column, not an on-the-spot computation.** A spatial query
is expensive. The movement system already asks the grid about neighbours, so it
writes the count down; the metabolism system just reads a number. **The
expensive operation is paid for exactly once.** This is a typical and very
profitable technique in ECS: one system prepares data for another through a
component.

**Why a tag and not a `Bool` column.** The tag gives the division system a
**dense list of exactly the cells that are ready** — `dividing.count` and
`dividing.denseEntities`. With a `Bool` column it would have to scan all ~1400
cells to find the dozen that are ready.

The subclass's computed properties (`position`, `heading`, ...) each re-resolve
their base pointer on every access — a cheap pointer lookup, not a search — so
they stay correct across a capacity growth without any caching discipline on
the caller's part (chapter 4's pointer-lifetime rule).

---

## 11.2. System order — and why it is exactly this

```swift
enum Phase: Int32 {
    case simulation, statistics
}

scheduler.addSystem(ColonyMovementSystem(),      phase: Phase.simulation.rawValue)
scheduler.addSystem(ColonySpatialIndexSystem(),  phase: Phase.simulation.rawValue)
scheduler.addSystem(ColonyMetabolismSystem(),    phase: Phase.simulation.rawValue)
scheduler.addSystem(ColonyDivisionSystem(),      phase: Phase.simulation.rawValue)
scheduler.addSystem(ReaperSystem(world: world),  phase: Phase.simulation.rawValue)
scheduler.addSystem(policy,                      phase: Phase.simulation.rawValue)
scheduler.addSystem(ColonyStatisticsSystem(),    phase: Phase.statistics.rawValue)
```

Read this list as an algorithm — that is what it is:

1. **Movement** — everyone moved and learned their own crowding.
2. **SpatialIndex** — the index is rebuilt from **the new** positions. If it
   stood before movement, every query in the next step would work from stale
   data.
3. **Metabolism** — energy spending depends on the crowding just measured by
   step 1. Marks the starving for destruction, the well-fed with a tag.
4. **Division** — divides the marked ones.
5. **Reaper** — the **single point of destruction**, and it is last among those
   that touch the world's membership.
6. **CapacityPolicy** — right after the reaper, because growth reallocates all
   buffers and requires that nobody is holding a dense slot or a cached column
   pointer.
7. **Statistics** — after the reaper, so it sees both the births and the deaths
   of this step.

---

## 11.3. The spatial query inside the movement loop

```swift
final class ColonyMovementSystem: System {
    let cells: ColonyCellStore
    let grid: UniformSpatialGrid

    init(cells: ColonyCellStore, grid: UniformSpatialGrid) {
        self.cells = cells
        self.grid = grid
        super.init()
        systemName = "Movement"
        _ = declareRead(ComponentType.cell.rawValue).declareWrite(ComponentType.cell.rawValue)
            .completeAccessMetadata()
    }

    override func execute(delta: Float) {
        let position = cells.position, heading = cells.heading
        let energy = cells.energy, crowding = cells.crowding

        for slot in 0..<Int(cells.count) {
            let me = cells.entityAt(Int32(slot))
            let point = position[slot]
            let neighbours = grid.querySphere(center: point, radius: crowdRadius, resultLimit: maxNeighbours)
            crowding[slot] = Float(max(neighbours - 1, 0))

            if neighbours > 1 {
                var away = SIMDVector3(0, 0, 0)
                for i in 0..<neighbours {
                    if grid.queryBuffer[i] == me { continue }   // that's me
                    let other = grid.queryPointBuffer[i]
                    away = SIMDVector3(away.x + point.x - other.x, 0, away.z + point.z - other.z)
                }
                if away.x * away.x + away.z * away.z > 0.0001 {
                    let desired = atan2(away.x, away.z)
                    heading[slot] = AngleMath.approach(heading[slot], desired, 4.0 * delta)
                }
            }

            position[slot] = SIMDVector3(point.x + sin(heading[slot]) * speed * delta, 0,
                                          point.z + cos(heading[slot]) * speed * delta)
        }
    }
}
```

Three things worth noticing:

- **`grid.storeQueryPoints = true`** is set once when the grid is configured,
  and then `grid.queryPointBuffer` hands back positions along with the
  identifiers in `grid.queryBuffer`. Without it you would have to go back into
  the store via `cells.indexOf(_:)` for every neighbour.
- **You must filter yourself out explicitly** — the grid does not know who is
  asking.
- **`maxNeighbours` (16 here)** bounds the work in the densest spots. A cell in
  a crush does not need every neighbour to figure out which way to push off.

---

## 11.4. Division: creating entities in the middle of a frame

```swift
final class ColonyDivisionSystem: System {
    let cells: ColonyCellStore
    let dividing: TagStore
    var spawnBuffer: [Entity]

    override func execute(delta: Float) {
        let parents = min(Int(dividing.count), spawnBuffer.count)
        guard parents > 0 else { return }
        let born = Int(world.createEntities(Int32(parents), into: &spawnBuffer))
        guard born > 0 else { return }

        let firstSlot = cells.count
        cells.attachMany(spawnBuffer, count: Int32(born))

        for i in 0..<born {
            let parent = dividing.entityAt(Int32(i))
            let parentSlot = cells.indexOf(parent)
            guard parentSlot != -1 else { continue }
            let childSlot = Int(firstSlot) + i
            cells.position[childSlot] = cells.position[Int(parentSlot)]
            cells.energy[childSlot] = cells.energy[Int(parentSlot)] * 0.5
            cells.energy[Int(parentSlot)] *= 0.5
        }

        dividing.clear()
    }
}
```

> **Why creating entities mid-frame is safe, but destroying them is not.**
>
> `attach()`/`attachMany()` only **append** to the end of the dense array. They
> relocate nothing, so no slot already obtained goes bad, and a loop already in
> progress does not lose its place.
>
> `detach()`, on the contrary, does a **swap-remove** — it moves the last
> element into the freed slot. That is why destruction is deferred (through
> `queueDestroy` + `ReaperSystem`) but creation is not.

The child cells' slots are contiguous from `firstSlot`, read **before**
`attachMany()`. That is the contract that makes batched spawning convenient.

`dividing.clear()` empties the tag **with no allocation** — it fills
`sparseIndex` with -1 and zeroes `count`. Much cheaper than calling `detach()`
once per cell.

---

## 11.5. Fixed step

```swift
let clock = SimulationClock()
clock.fixedStep = 1.0 / 30.0
clock.timeScale = 8.0
clock.maxSubsteps = 12
```

```swift
for _ in 0..<360 {
    let frameDelta: Float = 1.0 / 60.0
    let substeps = clock.advance(realDelta: frameDelta)

    scheduler.beginFrame()
    for _ in 0..<substeps {
        scheduler.executePhase(Phase.simulation.rawValue, delta: clock.fixedStep)
    }
    scheduler.executePhase(Phase.statistics.rawValue, delta: frameDelta)
}
```

At `timeScale = 8` and a 1/60 frame, 8/60 s accumulates — that is **four** steps
of 1/30. The simulation phase runs four times, the statistics phase once.

Without a fixed step the simulation step would be 8/60 ≈ 0.133 s, and a cell
with a division threshold of `age >= 1.0` would cross it unevenly, depending on
the frame rate. With a fixed step the result is **reproducible**: the same seed
sequence gives the same colony on any machine.

`droppedSubsteps == 0` at the end confirms the safety valve never fired — the
machine keeps up with `timeScale = 8`.

---

## 11.6. The change log instead of events

```swift
cells.trackChanges = true
```

```swift
final class ColonyStatisticsSystem: System {
    let world: World
    let cells: ColonyCellStore
    var births = 0
    var deaths = 0
    var peakPopulation: Int32 = 0

    override func execute(delta: Float) {
        births += Int(cells.addedCount)
        deaths += Int(cells.removedCount)
        peakPopulation = max(peakPopulation, world.getLiveCount())
        world.clearChangeLogs()
    }
}
```

The system sits **after the reaper** (and after division, which is also before
the reaper in this pipeline), so at that moment `addedCount` holds everything
born this step and `removedCount` holds everything that died. Having read the
log, it clears it.

In a real game this is where a death sound, particles or a UI update would
fire.

---

## 11.7. Capacity growth

```swift
policy.onCapacityGrown = { previous, next in
    context.resizeScratch(to: next)
    context.grid.configure(arenaRadius: dishRadius, verticalExtent: 0, cellSize: cellSize, entryCapacity: Int(next))
}
```

This is the single most important line of the whole example from the standpoint
of common mistakes.

**The library grows only its own buffers.** Everything the app allocated
alongside — scratch arrays for the index, the grid itself, a render batch, a
network buffer — you have to grow yourself. Forgetting this means that after
the world grows, the index is built only from the first N cells, and the rest
become invisible to neighbour search. There will be no error.

In the sample output above, the callback fired twice: 512 → 1024 → 2048.

---

## 11.8. What the profile might show

Attach an `Inspector` (chapter 13) and a representative frame's system table
could look like this:

```
Movement          13743      ← 82% of the frame
SpatialIndex       1417
Metabolism          612
Division             10
Reaper               11
CapacityPolicy        1
Statistics            3
```

Movement eats the majority. This is expected: it does a **spatial query per
cell per sub-step** — roughly 1300 cells × 4 steps ≈ 5200 queries per frame.

If this needed optimizing, the order of actions is (chapter 9):

1. **Do not do the work.** Update crowding not every step but once every 4
   steps — cells do not move far enough for it to matter more often.
2. **Parameters.** Reduce `maxNeighbours` from 16 to 6.
3. **Fewer entities.** Query only for cells close to the division threshold.
4. **And only then** — micro-optimizing the loop itself.

A profile here does not point at `Division` or `Metabolism`, no matter how
complex they look in the code. That is the point: **measure, do not guess**.

---

## 11.9. Things to try on your own

This example is a handy sandbox. A few exercises:

1. **Predators.** Add a second cell "type" (its own tag or store) and a
   `predator` tag. A predator finds the nearest prey via
   `grid.queryNearest(center:radius:)`, chases it and eats it (`queueDestroy` +
   its own energy gain). Where in the system list do you put the hunt?
2. **Food patches.** Replace a constant food rate with a second
   `UniformSpatialGrid` of nutrient patches. What `cellSize` does it need for
   30 patches against 1300 cells? (Hint: chapter 8, on choosing `cellSize`.)
3. **Mutations.** Add a `divisionThreshold` column and give a child cell the
   parent's value ± a little noise. Come back after a few minutes and see which
   value won.
4. **Speed-up.** Set `timeScale = 100`. What does `droppedSubsteps` show? What
   changes if you raise `maxSubsteps` to 40?
5. **Pause.** Add a render-facing system without `requiresTime = true` and
   check that it still runs while paused (`delta == 0`), but the simulation
   phase (whose systems declare `requiresTime = true`) stands still.

---

## Chapter summary

1. Keep together what is read together; pay for an expensive query once and
   store the result in a component.
2. A tag gives a dense list of candidates — cheaper than a flag in a store.
3. **Creating** entities mid-frame is safe (append); **destroying** them is not
   (swap-remove) — that asymmetry is why destruction goes through a deferred
   queue and creation does not.
4. A fixed step makes the simulation reproducible at any speed-up.
5. On capacity growth, **your own buffers are your responsibility** —
   `World.reserveCapacity()` (via `CapacityPolicySystem` here) only grows what
   the library itself owns.
6. The profiler tells you what to optimize. Intuition does not.

---

[← Common mistakes](10-common-mistakes.md) | [Contents](README.md) | [API reference →](12-api-reference.md)
