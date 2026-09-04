[← API reference](12-api-reference.md) | [Contents](README.md)

---

# 13. The inspector: how to look at a frame

---

## 13.1. The main idea

The most common way to look at performance is to print numbers on the screen and
watch them jump. This gives you almost nothing, and here is why.

At 240 frames per second, a number that updates every frame is **physically
impossible to read**. And the frame that is actually interesting — the one that
dipped and caused a hitch — is long gone by the time you shift your gaze to it.
You are looking at a random frame and drawing conclusions from it.

The inspector is built around the opposite approach: **collect every frame, and
show the distribution**.

| Question | Live numbers | Collected statistics |
|---|---|---|
| How much does a frame cost? | a flickering number | median, p95, max |
| Are there spikes? | occasionally something flashes | how many frames ran long and by how much |
| Who is to blame for the spikes? | **impossible to tell** | a ranked list with shares |
| What was in that frame? | it is already gone | a full breakdown, after the fact |

A worked, illustrative example. A live overlay would show that `SpatialIndex`
takes 75% of the frame — and that is true. But the collected statistics say
something more useful:

```
SpatialIndex      median 337 us, max 374   spread x1.1   ← just expensive
TurretTargeting   median   3 us, max  44   spread x14.7  ← here are the spikes
EntityReaper      median   1 us, max  25   spread x25.0  ← and here
```

`SpatialIndex` is expensive **evenly**, so it does not cause spikes — it only
raises the baseline frame cost. The spikes are caused by two systems that are
almost always free and occasionally explode. A live overlay would have led the
optimization in the wrong direction.

---

## 13.2. Quick start

`Inspector` lives in the core `AegisECS` module; the SwiftUI panel that renders
it lives in a separate product, `AegisECSInspectorUI` (see 13.3 for why they are
split).

```swift
import AegisECS
import AegisECSInspectorUI   // only where you actually draw the panel

var options = Inspector.Options()
options.mode = .dev

let inspector = Inspector.attach(scheduler: scheduler, world: world, options: options)
```

Somewhere in your view hierarchy:

```swift
InspectorPanelView(inspector: inspector)
```

And once per frame, after everything else has run:

```swift
scheduler.executeAll(delta: delta)
// ...presentation...
inspector.capture()                // as the LAST line of the frame
```

**Why `capture()` last.** It measures the wall-clock time between two calls, so
the whole frame must fall inside that interval, not just the scheduler. The
difference between the wall time and the sum of the systems is rendering,
physics and everything else outside ECS — and it is exactly what answers the
question "whose problem is this".

**Why the call is explicit, not automatic.** `Inspector.attach` never reaches
into your run loop; it has no way to know when your frame is actually finished.
An explicit line goes exactly where the frame ends, and that is visible in the
code — there is no scene-graph traversal order to reason about.

`Inspector.attach` always returns a real object, never `nil`: if `mode` is
`.off`, or configuration fails, you get back an inert `Inspector` whose
`capture()` is a no-op, so the call site never needs a branch.

---

## 13.3. Modes: development vs release

```swift
Inspector.Mode.off         // nothing runs
Inspector.Mode.telemetry   // recording + diagnostics, no UI
Inspector.Mode.inspector   // + a read-only panel
Inspector.Mode.dev         // + controls that change the simulation
```

The typical choice:

```swift
#if DEBUG
options.mode = .dev
#else
options.mode = .telemetry
#endif
```

In release, `.telemetry` still records every frame and can print a full report
on command (13.8) — the app draws nothing, but a QA build can still tell you
exactly what happened.

### How the UI is kept out of a release build

This is where the Swift port genuinely differs from the original addon, and for
the better: instead of a runtime `has_panel()` check backed by loading a file by
path, the split is a **compile-time one, at the package level**. `AegisECS`
(everything in `Core/`, `Debug/`, `Math/`, `Spatial/`, `Time/`) has no SwiftUI
dependency at all; `AegisECSInspectorUI` is a second library product that
depends on it and adds exactly one SwiftUI view.

```swift
.library(name: "AegisECS", targets: ["AegisECS"]),
.library(name: "AegisECSInspectorUI", targets: ["AegisECSInspectorUI"]),
```

A headless target — a server, a CI budget check, a background simulation — adds
only `AegisECS` as a dependency. `AegisECSInspectorUI` is then simply never
compiled into it: there is no dead code to strip, because it was never linked in
the first place. A client that does want the panel adds both products, and can
still gate the `import AegisECSInspectorUI` line and the view itself behind
`#if DEBUG` if it wants the symbol gone from release binaries too.

`Inspector.Mode.telemetry` (recording + diagnostics) has no UI dependency either
way — it is plain `AegisECS`, cheap enough to leave on in every build.

---

## 13.4. How to read the systems table

The panel's main screen is not the current frame but the distribution over the
window (`FrameRecorder.defaultFrameCapacity` = 240 frames, about 4 seconds at 60
Hz by default).

```
system                     median      p95      max   share  spread
SpatialIndex                  337      347      374   76.1%    1.1x
ProjectileImpact                54       61       73   11.4%    1.4x
TurretTargeting                  3       40       44    3.3%   14.7x
EntityReaper                     1       20       25    0.8%   25.0x
```

| Column | Where it comes from | What it means |
|---|---|---|
| **median** | `FrameStats.systemMedianUsec(i)` | The typical cost. This number, not the mean: one OS stall drags the mean along, the median not |
| **p95** | `FrameStats.systemP95Usec(i)` | What most frames stay under |
| **max** | `FrameStats.systemMaxUsec(i)` | The worst case over the window |
| **share** | `FrameStats.systemSharePercent(i)` | The fraction of all ECS time |
| **spread** | `FrameStats.systemVolatility(i)` | `max / median`. How uneven the system is |

**`spread` is the most important column, and it is in no ordinary overlay.** A
value near 1 means an even cost every frame: such a system raises the baseline
but causes no spikes. A large value means the system is usually free and
occasionally explodes — and that is exactly what feels like stutter.

---

## 13.5. Who makes the slow frames slow

The section everything was built for, backed by `FrameStats.systemExcessShare(i)`
and `FrameStats.spikeContributor(rank)`.

```
excess over each system's own median, across the slowest 12 frames

51.5%  TurretTargeting          ██████████
       median 3 us, peaks at 44 us
26.5%  EntityReaper             █████
       median 1 us, peaks at 25 us
 9.2%  ProjectileImpact         █
       median 54 us, peaks at 73 us
```

How this is computed (`FrameStats.analyse`):

1. The slow tail of the window is taken — frames above p95.
2. For each such frame, every system is attributed **how much it exceeded its
   own median** that frame.
3. The totals are ranked, worst contributor first.

The logic is simple: a system that is expensive **always** never exceeds its own
median, so it never appears in this list at all. Only the one that deviates from
its own norm appears — that is, exactly the spike culprit.

So `SpatialIndex`, with its 76% of frame time, is third here at 0%, while
`TurretTargeting`, with its 3.3%, is first at 51.5%.

---

## 13.6. Your game's counters

The library knows nothing about your enemies, your core or your projectiles. So
the application declares them:

```swift
inspector.addCounterSection("Combat") {
    [
        ("Enemies", "\(context.hostileCount) / \(context.targetPopulation)"),
        ("Projectiles", "\(context.projectileCount)"),
        ("Core", String(format: "%.0f%%", context.coreHealth / context.coreMaxHealth * 100)),
    ]
}

inspector.addCounterSection("Totals") {
    [
        ("Killed", "\(context.killCount)"),
        ("Intercepted", "\(context.interceptCount)"),
        ("Shots fired", "\(context.shotsFired)"),
    ]
}
```

One closure that returns `[(String, String)]` label → value pairs. It runs at
the **panel's own redraw rate, not every frame** (`InspectorPanelView.Options.
refreshHz`, 6 Hz by default), so even an expensive computation inside it does
not touch the frame budget. Sections are shown in registration order.

Objects the world does not know about are registered the same way — the
diagnostics need them:

```swift
inspector.registerGrid("enemies", enemyGrid)
inspector.registerQuery("targets", targetQuery)
inspector.setClock(simulationClock)
```

---

## 13.7. Diagnostics

The panel does not just show numbers — `Diagnostics.inspect(...)` catches the
documented pitfalls from [chapter 10](10-common-mistakes.md) and explains what
to do. These are the actual messages the library emits:

```
[WARNING] Grid: 'enemies' has far more cells than objects
    10125 cells for 60 entries - the rebuild is mostly iterating empty cells
    -> Increase cellSize, or use UniformSpatialGrid.suggestCellSize().

[WARNING] System: 'TurretTargeting' causes slow frames
    median 3 us but peaks at 44 us (15x); accounts for 52% of the excess in slow frames
    -> A system that is usually cheap and occasionally expensive is what
       stutter feels like. Look for work that happens in bursts.

[CRITICAL] Lifecycle: Destroy queue is not being drained
    up to 340 entities were still queued at the end of a frame
    -> flushDestroyQueue() is not running, or it runs before the systems that
       queue destruction. Register a ReaperSystem LAST.
```

The first of these warnings explains why `SpatialIndex` could take 76% of the
frame: a grid rebuild costs `O(entries + CELLS)` (chapter 8), and having many
times more cells than objects means the rebuild is mostly walking empty space.

The full list of rules (`Diagnostics.swift`):

| Source | What it catches |
|---|---|
| World | Capacity exhausted or close to it |
| Store | A store is full; the change log overflowed |
| Frame | p95 over budget; uneven frame cost |
| System | A system dominates; a system makes frames slow |
| Lifecycle | The destroy queue is not being drained (the reaper is misplaced) |
| Query | The cache never hits; the result is truncated |
| Grid | Too many or too few cells; a 3D grid that is almost flat |
| Clock | Sub-steps are being dropped — the machine cannot keep up with `timeScale` |

The thresholds are configurable, all `public var` on `inspector.diagnostics`:

```swift
inspector.diagnostics.frameBudgetUsec = 8000.0    // 120 Hz
inspector.diagnostics.volatilityWarning = 3.0
```

---

## 13.8. Without an interface: console, file, CI

Recording and analysis are plain `AegisECS`, with no SwiftUI dependency — the
same reason `Inspector.Mode.telemetry` works in a build that never links
`AegisECSInspectorUI` at all.

```swift
inspector.printReport()   // the full text report, to the console
```

`printReport()` calls `refreshNow()` and prints `Report.text(recorder:stats:
world:findings:)`. That function returns a plain `String`, so an app that wants
to save it to disk does so with ordinary Swift file I/O:

```swift
let text = Report.text(recorder: inspector.recorder, stats: inspector.stats,
                        world: inspector.getWorld(), findings: inspector.getFindings())
try? text.write(toFile: "/path/to/ecs_report.txt", atomically: true, encoding: .utf8)
```

This Swift port ships the plain-text report only — `Report.swift` is explicitly
a **trimmed** port of the original: per-frame JSON/CSV writers were left out on
the assumption that a client rendering its own panel does not need them. If your
app wants a machine-readable export (for comparing two builds' `report.json`,
say), write one against `FrameRecorder`'s and `FrameStats`' public accessors —
they expose everything `Report.text` uses.

### A budget check in CI

`swift test` is already headless, so there is no separate "run this script with
no window" step to reach for — a budget check is just another `XCTestCase`:

```swift
import XCTest
@testable import AegisECS

final class PerformanceBudgetTests: XCTestCase {
    func testFrameBudget() {
        let context = buildMyWorld()

        var options = Inspector.Options()
        options.mode = .telemetry
        let inspector = Inspector.attach(scheduler: context.scheduler, world: context.world, options: options)

        for _ in 0..<600 {
            context.scheduler.executeAll(delta: 1.0 / 60.0)
            inspector.capture()
        }

        inspector.refreshNow()
        print(Report.text(recorder: inspector.recorder, stats: inspector.stats,
                           world: context.world, findings: inspector.getFindings()))

        let p95 = inspector.stats.frameP95Usec()
        XCTAssertLessThanOrEqual(p95, 8000.0, "ECS p95 exceeds the 8 ms budget")
    }
}
```

Now a performance regression fails `swift test` the same way a broken assertion
does, in CI, with no extra plumbing.

---

## 13.9. The panel

`InspectorPanelView` is plain SwiftUI, built to be dropped in with nothing but a
reference to an `Inspector`:

```swift
InspectorPanelView(inspector: inspector, isActive: isVisible)
```

Pass `isActive: false` while the panel is off-screen (a closed drawer that stays
mounted for its slide animation, a hidden tab): the view's own refresh timer
keeps ticking either way, but skips calling back into the inspector while
inactive, so a hidden panel costs nothing beyond the timer itself.

It draws a header (title, and a `log` button that calls `inspector.
printReport()`) above a scrolling list of collapsible sections, each toggled by
tapping its title:

| Section | Contents | Expanded by default |
|---|---|---|
| **Frame** | One "now" line, then median / p95 / max over the window | yes |
| **Counters** | Your counters (13.6) — the card is omitted entirely when there are none | yes |
| **Systems** | The distribution table (13.4) | yes |
| **What makes the slow frames slow** | Spike attribution (13.5) | yes |
| **Diagnostics** | Findings (13.7) | yes |
| **World and stores** | Population, stores | **no** — collapsed until tapped |

`Options.initiallyExpandedSections` controls that default set, so an app that
wants a different starting layout (or wants "World and stores" open too) can
override it.

`Options.headlineOverride: ((PanelSnapshot) -> String)?` lets the host replace
the generic "`<ms> · <fps> · <entities>`" headline with its own, if it already
renders an fps/frame-cost readout elsewhere and wants the panel to match it
exactly instead of showing a second, slightly different number.

### Disabling systems on the fly

In `.dev` mode, the system names in the table are tappable. Tap — the system is
disabled; tap again — it is enabled. This calls `Scheduler.setSystemEnabled(_:_:)`
directly, through `inspector.getScheduler()`.

This is the fastest way to find out what a system is actually responsible for:
disable `EnemySteering` and the enemies stop turning, so it is that one. And the
fastest way to localize a bug: disable half the pipeline and see whether the
symptom disappears.

> Disabling changes the simulation, so the rows are only tappable in `.dev`
> mode — `panel.canToggleSystems` is `inspector.mode == .dev`.

---

## 13.10. What it costs

Nothing in this Swift port ships a benchmark target, so this section states
what the source guarantees rather than measured numbers you cannot verify
yourself.

- **`FrameRecorder.capture()`** writes a fixed number of cells (one per system)
  into flat, preallocated buffers and — per its own doc comment — "never
  allocates after `configure()`, so it is safe to leave on in a release build."
- **`FrameStats.analyse()`** is documented as a cold operation: "it sorts the
  window per system. Call it when you are about to read the results, not every
  frame." That is exactly why it runs at its own rate, `statsRefreshHz`
  (2 Hz by default) — decoupled from `capture()`, which still runs every frame.
- **`Diagnostics.inspect()`** runs slower still, at `diagnosticsRefreshHz`
  (0.5 Hz by default).
- **`InspectorPanelView`** re-renders at `Options.refreshHz` (6 Hz by default),
  independently of both of the above — a SwiftUI redraw is far more expensive
  than reading already-computed aggregates, which is why the view does not
  refresh on every frame its host draws.

If you need concrete numbers for your own machine and your own system set,
profile with Instruments' Time Profiler, or wrap the loop from 13.8's CI example
in an `XCTest` timing measurement — the same tests already do the recording and
analysis, just add a clock around them.

The rates are ordinary `public var`s:

```swift
inspector.statsRefreshHz = 1.0
inspector.diagnosticsRefreshHz = 0.25
```

---

## 13.11. Restarting a level

After `world.reset()`, the frames of the previous run distort the medians and
the attribution:

```swift
func onRestartRequested() {
    restartSimulation()
    inspector.recorder.clear()
    inspector.diagnostics.reset()
}
```

---

## Chapter summary

1. **Collected statistics are more informative than live numbers.** The frame
   that hitched is already gone by the time you look at it.
2. `median` and `p95` instead of the mean; **`spread` (max/median) shows who
   causes spikes**.
3. **Attribution** names the culprit: a system that is expensive always is not
   to blame for spikes.
4. Recording allocates nothing after `configure()` — there is no cost reason to
   leave it out of a release build.
5. The UI has no compile-time footprint in a target that only depends on
   `AegisECS`: `AegisECSInspectorUI` is a separate product, not a runtime
   feature flag.
6. Game counters are one closure, called at the panel's own redraw rate.
7. Everything below the UI works headless: a report to the console, and a
   budget check that is just another `XCTestCase`.

---

[← API reference](12-api-reference.md) | [Contents](README.md)
