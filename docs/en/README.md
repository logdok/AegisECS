# Aegis ECS — user guide

Aegis ECS is a compact **ECS engine in pure Swift**, distributed as a Swift
Package. It is a from-scratch Swift port of an ECS engine originally written
in pure GDScript for Godot 4 — the design (sparse-set stores, swap-remove,
deferred destruction, a fixed registration-order scheduler) carries over
unchanged; only the language and the platform integration are new. It is built
for simulations where thousands to tens of thousands of objects update every
frame: units, projectiles, gameplay particles, crowds, bullet hell, population
simulations.

- **No dependencies.** Pure Swift, built with Swift Package Manager — no
  third-party packages.
- **No hidden allocations** in the steady-state frame loop. Memory grows only
  through an explicit barrier.
- **No class instance per game object.** Data lives in flat, contiguous
  columns (`PackedStore`).
- **No boilerplate.** `PackedStore` generates the entire store's storage,
  growth and swap-remove relocation from a column schema.
- **Batched structural operations.** Spawn and destroy are one call, not N.
- **Built-in inspector.** Frame statistics, spike-culprit attribution and
  diagnostics for common mistakes — wired in with a couple of lines, with an
  optional SwiftUI panel in a separate product.
- **Safe references.** Packed generational handles guard against ABA.
- **Runs anywhere Swift runs.** No platform-specific code in the core; today's
  floor is iOS 16 / macOS 13 (see [Package.swift](../../Package.swift)).

---

## How to read this guide

The chapters are ordered so you can read them front to back, but each one stands
on its own.

**If you have never heard of ECS** — start with chapter 1. It explains not "how
to call this library's methods" but **why** the approach exists at all and which
problem it solves. It is the most important chapter: without it, the rest will
look like a strange way to write ordinary code.

**If you have worked with ECS before** (Unity DOTS, EnTT, flecs, bevy) — jump
straight to chapter 2, then to chapter 4: stores here are built as a sparse set,
and that is where all the specifics of this implementation live.

**If you are in a hurry** — chapter 2 has a fully working example you can drop
straight into an executable target.

| # | Chapter | About |
|---|---|---|
| 1 | [Introduction to ECS](01-intro-to-ecs.md) | What ECS is, which problem it solves, when you need it and when it is harmful |
| 2 | [Quick start](02-quick-start.md) | Installation via Swift Package Manager and a first working world |
| 3 | [World, entities, lifecycle](03-world-entities-lifecycle.md) | Entity as a number, the handle, deferred destruction |
| 4 | [Components and stores](04-components-and-stores.md) | Sparse set, `PackedStore`, hand-written stores, resource ownership |
| 5 | [Systems and the scheduler](05-systems-and-scheduler.md) | Order as a contract, phases, pause, profiling |
| 6 | [Finding the entities you want](06-finding-entities.md) | Direct loop, `View`, `Query` — and how to choose |
| 7 | [Time, events, capacity](07-time-events-capacity.md) | `SimulationClock`, the change log, the growth policy |
| 8 | [Spatial search](08-spatial-search.md) | `UniformSpatialGrid`, picking the cell size, `AngleMath` |
| 9 | [Performance](09-performance.md) | The Swift cost model, what to measure, how not to optimize blind |
| 10 | [Common mistakes](10-common-mistakes.md) | Symptom → cause → fix |
| 11 | [Full example](11-full-example.md) | A worked mini-simulation from start to finish |
| 12 | [API reference](12-api-reference.md) | Every type and method in tables |
| 13 | [Inspector](13-inspector.md) | The debug panel: collected frame statistics, spike attribution, diagnostics |

### Additional

| Document | About |
|---|---|
| [Architecture](ARCHITECTURE.md) | A decision reference: handle bit layout, hook declaration, the batched destruction design, capacity growth |

---

## Six safety rules

A short reminder. Each rule is expanded in its own chapter, and the symptoms of
breaking them are collected in [chapter 10](10-common-mistakes.md).

1. **A raw `Entity` (`Int32`) is for the hot loop; a `Handle` (`Int64`) is for
   references across frames.** A handle must not be written into save/network
   data as a stable identifier — its world tag is scoped to one process run.
2. **Structural changes happen only at defined sync points.** Not in the
   middle of a system; you cannot cache a dense slot, or a `PackedStore`
   column pointer, across that boundary.
3. **Implement `relocateDense(from:to:)`** in a hand-written store — a
   forgotten field silently mixes data up. Or use `PackedStore`, where you
   cannot get it wrong.
4. **A `PackedStore` column pointer is valid only until the world's capacity
   next grows.** Fetch it fresh inside `execute()` rather than caching it
   across frames.
5. **`View`/`Query` refresh before a structural change is read**, and a
   store's membership cannot be changed in the middle of iterating that same
   store.
6. **Pause is `delta == 0`**, not a skipped frame. Declare `requiresTime =
   true`.

---

## Verifying it works

```bash
swift build
swift test
```

`swift test` runs the package's own `XCTest` suite
(`Tests/AegisECSTests/*.swift`) — the same tests the port's behaviour is pinned
by: swap-remove leaves the dense array unordered, `detachFlagged` performs the
theoretical minimum of moves, an exhausted generation retires a slot forever,
and so on (see [ARCHITECTURE.md](ARCHITECTURE.md#validation-and-testing) for
what each test file covers). It is usable in CI as-is, with no separate
headless flag to remember.

[Chapter 11](11-full-example.md) walks through a full worked simulation,
dissected piece by piece; it is written out in the guide rather than shipped as
a runnable example target, so read it rather than execute it as-is.

---

## The two products, and what you can add or leave out

The package exposes two library products from one Swift Package dependency:

| Product | What's inside | Depends on |
|---|---|---|
| `AegisECS` | Core (`World`, stores, systems, `Scheduler`, `ReaperSystem`, `CapacityPolicySystem`), spatial search, the fixed-step clock, angle math, and the headless debug/diagnostics layer | nothing |
| `AegisECSInspectorUI` | `InspectorPanelView`, the SwiftUI dev panel from [chapter 13](13-inspector.md) | `AegisECS` |

A headless target — a server, a CI budget check, a background simulation —
depends on plain `AegisECS` and never links SwiftUI. Add
`AegisECSInspectorUI` only where you actually want to show the panel; a target
that never adds it never compiles a reference to `InspectorPanelView` at all,
so there is nothing to strip.

Unlike the original add-on, whose modules were independent files you could
delete folder by folder from a Godot project, `AegisECS`'s core is a single
compiled Swift module: `Core/`, `Debug/`, `Math/`, `Spatial/` and `Time/` build
together as one target. If your app genuinely never touches the spatial grid or
the fixed-step clock, the unused code still compiles in — but it is a few
small, dependency-free files, and the linker still drops unreferenced symbols
from your binary.

### About name collisions

Swift types are scoped by module, not registered in a single global namespace
the way the original add-on's `class_name` declarations were. `import AegisECS`
brings `World`, `System`, `Scheduler`, `ComponentStore` and the rest into scope
under your file; if your own app already declares a type with one of those
names, disambiguate with the fully qualified `AegisECS.World` rather than
renaming anything in the library.

---

## Glossary

Terms that show up across all the chapters.

| Term | Meaning |
|---|---|
| **Entity** | Just an integer — an identifier. Not an object, not a node, not a class. |
| **Component** | Pure data attached to an entity. Position, health, velocity. |
| **System** | Pure logic that reads and writes components. No state of its own. |
| **World** | The allocator of entity identifiers and the registry of stores. |
| **Store** | A container for one component type's data across all entities. |
| **Dense slot** | An index inside a store's dense array. Not equal to the entity id. |
| **Sparse set** | A two-array structure that gives both dense iteration and O(1) lookup. |
| **Swap-remove** | O(1) removal: the last element moves into the removed one's place. |
| **Structural change** | A change of membership: create, destroy, attach, detach. |
| **Handle** | A safe reference to an entity that survives across frames. |
| **Broadphase** | A structure for answering "who is nearby" quickly. |

---

## License and compatibility

- **Swift 6.0+ toolchain.** Platform floor: iOS 16, macOS 13 (see
  [Package.swift](../../Package.swift); a plain, non-UI target could go lower,
  but the package sets one floor for both products).
- **License:** MIT — see [LICENSE](../../LICENSE). Copyright (c) 2026 Vitalii
  Yurchenko.
