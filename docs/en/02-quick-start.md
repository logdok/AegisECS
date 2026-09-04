[← Introduction to ECS](01-intro-to-ecs.md) | [Contents](README.md) | [World and entities →](03-world-entities-lifecycle.md)

---

# 2. Quick start

---

## 2.1. Installation

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/logdok/AegisECS.git", from: "1.0.0"),
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "AegisECS", package: "AegisECS"),
        ]
    ),
]
```

Then `import AegisECS`. That is it — there is nothing to enable, no plugin
list, no project setting: Swift Package Manager resolves and builds the
dependency, and every public type in the module is available the moment you
import it.

To verify everything landed:

```bash
swift build
swift test
```

`swift test` runs the package's own XCTest suite
(`Tests/AegisECSTests/*.swift`) against the exact same code you depend on —
useful in CI as-is.

### About name collisions

Swift types are scoped by module, not registered globally the way some
engines' scripting languages do. `import AegisECS` brings `World`, `System`,
`Scheduler`, `ComponentStore` and the rest into scope under your own file; if
your app already declares a type with one of those names, disambiguate with
the fully qualified `AegisECS.World` rather than renaming anything in the
library.

### Two products, one dependency to add

The package exposes two SwiftPM products from one dependency:

| Product | What's inside | Depends on |
|---|---|---|
| `AegisECS` | Core (world, stores, systems, scheduler, `ReaperSystem`, `CapacityPolicySystem`), spatial search, the fixed-step clock, angle math, and the headless debug/diagnostics layer | nothing |
| `AegisECSInspectorUI` | The SwiftUI dev-panel view described in [chapter 13](13-inspector.md) | `AegisECS` |

A headless target — a server, a CI budget check — depends on plain
`AegisECS` and never links SwiftUI. Add `AegisECSInspectorUI` as well only
where you actually want to show the panel.

---

## 2.2. A full working example

Here is a simulation in its entirety. 500 particles fly out from the centre;
those that cross a boundary are destroyed. This works as-is — drop it into a
`main.swift` of an executable SwiftPM target and run it.

```swift
import AegisECS

// --- 1. The component store -------------------------------------------------
// PackedStore generates the storage, growth and swap-remove relocation for
// the columns you declare; you only choose their types.

final class Particles: PackedStore {
    init() { super.init(schema: [.float32, .float32, .float32, .float32]) } // x, y, vx, vy
    var x: UnsafeMutablePointer<Float> { columnF32(0)! }
    var y: UnsafeMutablePointer<Float> { columnF32(1)! }
    var vx: UnsafeMutablePointer<Float> { columnF32(2)! }
    var vy: UnsafeMutablePointer<Float> { columnF32(3)! }
}

// --- 2. The context ----------------------------------------------------------
// The library knows nothing about your app: it simply hands this object to
// every system's setup(world:context:), untyped. Keep references to stores
// and shared state here.

final class Context {
    let world: World
    let particles: Particles
    var escaped = 0
    init(world: World, particles: Particles) {
        self.world = world
        self.particles = particles
    }
}

// --- 3. Systems ----------------------------------------------------------

final class MovementSystem: System {
    private var context: Context!

    override init() {
        super.init()
        systemName = "Movement"
        requiresTime = true          // do not run while paused
    }

    override func setup(world: World, context: Any?) {
        self.context = context as? Context
    }

    override func execute(delta: Float) {
        let p = context.particles
        let x = p.x, y = p.y, vx = p.vx, vy = p.vy
        for slot in 0..<Int(p.count) {
            x[slot] += vx[slot] * delta
            y[slot] += vy[slot] * delta
        }
    }
}

final class BoundsSystem: System {
    private var context: Context!

    override init() {
        super.init()
        systemName = "Bounds"
        requiresTime = true
    }

    override func setup(world: World, context: Any?) {
        self.context = context as? Context
    }

    override func execute(delta: Float) {
        let p = context.particles
        let x = p.x
        for slot in 0..<Int(p.count) {
            if abs(x[slot]) > 100.0 {
                // Only marks. The entity lives until the end of the frame, so
                // the iteration will not fall apart mid-flight.
                context.world.queueDestroy(p.entityAt(Int32(slot)))
                context.escaped += 1
            }
        }
    }
}

// --- 4. Assembly and run -----------------------------------------------

enum ComponentType: Int32 { case particle }

let world = World(entityCapacity: 1000)          // initial capacity

let particles = Particles()
world.registerStore(particles, typeID: ComponentType.particle.rawValue)

let context = Context(world: world, particles: particles)

// Registration order = execution order = behaviour.
let scheduler = Scheduler()
scheduler.addSystem(MovementSystem())
scheduler.addSystem(BoundsSystem())
scheduler.addSystem(ReaperSystem(world: world))   // always last
scheduler.setupAll(world: world, context: context)

// Batched creation: one call instead of 500.
var ids = [Entity](repeating: kInvalidEntity, count: 500)
let spawned = world.createEntities(500, into: &ids)

let firstSlot = Int(particles.count)
particles.attachMany(ids, count: spawned)

var seed: UInt64 = 12345
func nextRandom(_ lo: Float, _ hi: Float) -> Float {
    seed = seed &* 6364136223846793005 &+ 1
    return lo + (hi - lo) * Float(seed >> 40) / Float(1 << 24)
}
for i in 0..<Int(spawned) {
    let slot = firstSlot + i
    particles.x[slot] = 0
    particles.y[slot] = 0
    particles.vx[slot] = nextRandom(-40, 40)
    particles.vy[slot] = nextRandom(-40, 40)
}

for _ in 0..<600 {
    scheduler.executeAll(delta: 1.0 / 60.0)
}

print("remaining: \(world.getLiveCount()), escaped: \(context.escaped)")
```

Run it with `swift run` from the package that declares this as an executable
target.

---

## 2.3. Walk-through: what just happened

### Step 1 — the store

```swift
final class Particles: PackedStore {
    init() { super.init(schema: [.float32, .float32, .float32, .float32]) }
    var x: UnsafeMutablePointer<Float> { columnF32(0)! }
    ...
}
```

`PackedStore` is the recommended base for ordinary data stores. You declare a
schema of column types and get back typed pointers by index. Everything
else — allocating memory for the world's capacity, growth, relocating data on
swap-remove — is done for you.

The named computed properties (`x`, `y`, `vx`, `vy`) are a thin, optional
convenience over `columnF32(_:)`; the pointer itself is stable **until the
world's capacity grows**, so it is safe to read once at the top of a system's
`execute(delta:)` and index it directly in the loop, at full speed. **There
is no fee for the convenience.**

> There is a lower level too — `ComponentStore`, where `reserveDense` and
> `relocateDense` are written by hand. You need it for exotic layouts; for
> ordinary data use `PackedStore`. Details in
> [chapter 4](04-components-and-stores.md).

### Step 2 — the context

The library **knows nothing about your app**. `System.setup(world:context:)`
receives `context` as `Any?`, and that is where you keep references to
stores — cast it once, in `setup`, and hold the typed reference.

This is deliberate: it is what lets the package move between apps with no
edits to the library itself.

### Step 3 — systems

Three things worth noticing:

1. **`systemName`** is set in the initializer — it shows up in profiling and
   in the [inspector panel](13-inspector.md).
2. **`requiresTime = true`** means "do not run me when time is stopped".
   Pause in this library is a zero-length step, not a skipped call, so
   rendering and other time-independent systems keep working.
3. **Column pointers taken once per `execute` call**, not stored across
   frames. `PackedStore`'s underlying buffers can move when the world's
   capacity grows (`CapacityPolicySystem`, or an explicit
   `world.reserveCapacity(_:)`), so a pointer held across that boundary is
   stale.

### Step 4 — assembly

```swift
scheduler.addSystem(MovementSystem())
scheduler.addSystem(BoundsSystem())
scheduler.addSystem(ReaperSystem(world: world))
```

`ReaperSystem` is that same "one point of destruction" from
[section 1.7](01-intro-to-ecs.md#17-why-destruction-is-deferred), wrapped as
a ready-made class. **Put it last and exactly once** in the pipeline.

### Batched creation

```swift
let spawned = world.createEntities(500, into: &ids)
let firstSlot = Int(particles.count)
particles.attachMany(ids, count: spawned)
```

`createEntities(_:into:)` and `attachMany(_:count:)` do in one call what
would otherwise take 500 calls each.

The slots of the newly attached components are contiguous, starting at the
`count` value taken **before** the call — so you can write the data right
away at index `firstSlot + i`.

---

## 2.4. A frame in a real app

In the example above the frame spins in a `for` loop. `AegisECS` owns no run
loop of its own — your app calls `scheduler.executeAll(delta:)` once per
tick from wherever its own loop already lives: a game engine's per-frame
callback, a `CADisplayLink`, a `Timer`, a SwiftUI `TimelineView`, or a
server's tick.

```swift
final class GameLoop {
    let context: Context
    let scheduler: Scheduler
    var isPaused = false

    func tick(delta: Float) {
        let step = isPaused ? Float(0) : min(delta, 0.1)
        scheduler.executeAll(delta: step)
    }
}
```

Two notes:

- **Pause is `0`, not a skipped call.** The scheduler skips systems with
  `requiresTime = true` on its own, while rendering and anything else that
  does not declare `requiresTime` keeps going.
- **`min(delta, 0.1)`** clamps the step: if the app stalled for a second,
  without this clamp every object teleports. For a serious simulation take
  `SimulationClock` instead — see [chapter 7](07-time-events-capacity.md).

---

## 2.5. Where to go next

- Unclear why an entity is a number, and what a handle is →
  [chapter 3](03-world-entities-lifecycle.md)
- You need a store with more complex data, or hand-written relocation →
  [chapter 4](04-components-and-stores.md)
- You need to process not all entities but only those with a certain set of
  components → [chapter 6](06-finding-entities.md)
- You need to speed time up or slow it down without desync →
  [chapter 7](07-time-events-capacity.md)
- You need to search for neighbours ("who is nearby") →
  [chapter 8](08-spatial-search.md)

---

[← Introduction to ECS](01-intro-to-ecs.md) | [Contents](README.md) | [World and entities →](03-world-entities-lifecycle.md)
