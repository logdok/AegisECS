[← Time and events](07-time-events-capacity.md) | [Contents](README.md) | [Performance →](09-performance.md)

---

# 8. Spatial search

---

## 8.1. The problem

"Which objects are near point X right now?"

The naive answer is to iterate everyone and compare distances. That is `O(n)` per
query. If there are also `n` queries (every enemy looking for its nearest
neighbour), it becomes `O(n²)`: for 10,000 objects that is 100 million checks per
frame. Unacceptable already at a few thousand.

`UniformSpatialGrid` solves this by dividing space into equal cells. An object
lands in a cell by its coordinates, and the "who is nearby" search comes down to
looking at a handful of neighbouring cells instead of the whole world.

---

## 8.2. Basic usage

```swift
let grid = UniformSpatialGrid()

// Once, at assembly:
grid.configure(
    arenaRadius: 130.0,     // the XZ-plane boundary
    verticalExtent: 0.0,    // 0 = flat (2D) mode
    cellSize: 10.0,
    entryCapacity: 10000    // maximum entries any one rebuild() will get
)
```

Every frame, **after** everyone has moved:

```swift
grid.rebuild(entityIDs: entityIDs, points: points, entryCount: entryCount)
```

`entityIDs` is `[Int32]` (or an `UnsafePointer<Int32>` for the allocation-free
overload) and `points` is `[SIMDVector3]` — the library's own small value type
(`struct SIMDVector3 { var x, y, z: Float }`), not a type from any UI framework.

Then — queries:

```swift
// The nearest one within a radius, or -1.
let nearest = grid.queryNearest(center: center, radius: 12.0)

// Everyone within a radius. Returns the count; the ids are in queryBuffer.
let found = grid.querySphere(center: center, radius: 10.0, resultLimit: 64)
for i in 0..<found {
    let entity = grid.queryBuffer[i]
}
```

> **`queryBuffer` is overwritten by the next query.** Read it immediately or
> copy what you need. The result deliberately lands in a stored property rather
> than an `inout` out-parameter: this makes the ownership and lifetime of the
> result obvious, and returning a freshly allocated array would allocate memory
> on every single query.

### Rebuild, not move

The grid is built for the "everything moves every frame" scenario: it **does
not** support moving a single object; it rebuilds entirely, from a flat pair of
arrays, every time you call `rebuild()`. For a simulation where almost
everything moved, this is cheaper than `n` individual updates would be.

---

## 8.3. Flat (2D) mode

```swift
grid.configure(arenaRadius: 130.0, verticalExtent: 0.0, cellSize: 10.0, entryCapacity: 10000)
// verticalExtent = 0
```

If your game happens on a plane — top-down, RTS, bullet hell, a Petri-dish
simulation — pass `verticalExtent = 0.0` and the grid collapses into a single Y
layer: `dimY` becomes `1` instead of however many vertical layers `cellSize`
would otherwise produce.

The Y coordinate is then ignored when bucketing into cells (distance checks
performed by `queryNearest`/`querySphere` remain fully three-dimensional), and
the total cell count drops by as many times as there would otherwise have been
vertical layers — which matters, because §8.4 below shows the rebuild cost is
driven by cell count, not just by how many entries you have.

Check the mode at runtime: `grid.isFlat()`, `grid.getDimensions()`.

---

## 8.4. The one that matters most: choosing `cellSize`

The cost of `rebuild()` is **`O(entries + CELL COUNT)`**, not just
`O(entries)`.

The reason is inside the algorithm: the grid is built on a **counting sort**
over flat arrays, and its middle pass (turning the per-cell histogram into
prefix sums) is obliged to walk **every** cell, empty ones included. A grid of
10,000 cells holding 30 objects spends almost all of that pass on emptiness —
this is exactly the mechanism behind the "far more cells than objects"
diagnostic the inspector panel surfaces (see [chapter 13](13-inspector.md)).

Two forces pull in opposite directions:

- **small cells** make the rebuild expensive but speed up queries — fewer
  candidates land in each cell;
- **large cells** make the rebuild nearly free, but queries degrade — you end
  up distance-checking a pile of candidates that were never going to be close
  enough.

### The rule of thumb

Keep `getCellCount()` **comparable to the expected number of objects**, and
`cellSize` itself **2–4× larger than the typical query radius**.

Or just ask the library:

```swift
let size = UniformSpatialGrid.suggestCellSize(
    arenaRadius: 130.0,
    verticalExtent: 0.0,      // 0 = flat
    expectedEntries: 10000,
    typicalQueryRadius: 12.0
)
grid.configure(arenaRadius: 130.0, verticalExtent: 0.0, cellSize: size, entryCapacity: 10000)
```

The formula (`suggestCellSize`) takes "roughly one cell per object" — computed
from the arena's area or volume divided by the expected entry count — and
raises the result to at least twice the query radius. This is a starting
point, not a law: profile from there with your own population and query
pattern.

### Several grids with different `cellSize`

This is a **recommended pattern**, not a trick.

If your scene has both a dense mass of small objects and a dozen large rare
ones, a single shared grid is bad for both: sized for the dense population it
wastes the rebuild on the sparse one's near-empty region of space, and sized
for the sparse population it makes the dense population's queries expensive.
Set up two:

```swift
// 10,000 units, small cells: the rebuild is expensive but queries are fast
unitsGrid.configure(arenaRadius: 130.0, verticalExtent: 0.0, cellSize: 6.0, entryCapacity: 10000)

// 30 projectiles, large cells: iterating 10,000 mostly empty small cells for
// the sake of thirty entries would be pure waste
missilesGrid.configure(arenaRadius: 130.0, verticalExtent: 0.0, cellSize: 40.0, entryCapacity: 64)
```

---

## 8.5. Positions alongside identifiers

The typical "find neighbours and compute a force" loop after `querySphere()`
would, for each found id, still have to fetch its position through its own
component store. The grid already has those positions, if you ask it to keep
them:

```swift
grid.storeQueryPoints = true   // once

let found = grid.querySphere(center: center, radius: 10.0, resultLimit: 64)
for i in 0..<found {
    let entity = grid.queryBuffer[i]
    let point = grid.queryPointBuffer[i]        // no extra lookup
    let dx = center.x - point.x
    let dy = center.y - point.y
    let dz = center.z - point.z
}
```

(`SIMDVector3` is a plain `{x, y, z: Float}` value with no vector-math
operators of its own — subtraction, length and normalisation are yours to
write, or bring your own math type and convert at the boundary.)

`storeQueryPoints` is off by default, so callers that only need ids do not pay
for the extra write into `queryPointBuffer`.

---

## 8.6. Custom cell iteration

For non-standard tasks — "all pairs within a cell", a bucketed pass over the
whole grid — the grid exposes its sorted arrays and lets you walk every cell
directly:

```swift
for cell in 0..<grid.getCellCount() {
    let start = Int(grid.getCellStart(cell))
    let end = Int(grid.getCellEnd(cell))
    for s in start..<end {
        let entity = grid.sortedEntities[s]
        let position = grid.sortedPoints[s]
    }
}
```

`sortedEntities` and `sortedPoints` are **read-only** from outside (`public
private(set)`), by the same convention as the public store fields in
[chapter 4](04-components-and-stores.md). There is no public API to go the
other way — from an arbitrary point straight to its cell index — only
`queryNearest`/`querySphere` (which already do that internally) and iteration
by cell index as shown above.

---

## 8.7. Geometric assumptions

- The world is centred at zero on the **X and Z** axes: range
  `[-arenaRadius, +arenaRadius]`.
- On **Y** the count runs upward from zero: range `[0, verticalExtent]`.
- Objects **are not lost outside these bounds** — they are clamped to the edge
  cells, so queries near the arena boundary stay correct.
- `querySphere()` **stops searching** once it hits `resultLimit`, so a
  truncated result is biased toward the cells visited first rather than being
  a random sample.

---

## 8.8. `AngleMath`

A small module for smooth turning, entirely independent of the ECS — it is
just three static functions on `Float` angles in radians.

```swift
// Turn current toward desired, by no more than maxStep, along the shortest path.
yaw = AngleMath.approach(yaw, desiredYaw, turnRate * delta)

// The absolute shortest angular distance — "how far", with no direction.
if AngleMath.shortestDelta(yaw, desiredYaw) < firingTolerance {
    fire()
}
```

**Why this is not trivial.** The naive
`current += clamp(desired - current, -maxStep, maxStep)` breaks at the ±π
crossover. If `current = 3.1` and `desired = -3.1`, the "straight" difference
is −6.2 rad, even though the shortest path between those angles is only 0.08
rad **the other way**. `AngleMath.wrap(_:_:_:)` brings a difference to its
shortest equivalent in `[min, max)` before anything else is computed from it —
`approach` and `shortestDelta` are both built on top of it.

---

## Chapter summary

1. The grid **rebuilds entirely** every frame; there is no single-object move.
2. The rebuild cost is `O(entries + CELLS)`, so `cellSize` is critical — and
   too many empty cells is exactly what the inspector's grid diagnostic
   ([chapter 13](13-inspector.md)) flags.
3. **Flat mode** (`verticalExtent = 0`) is a free speed-up for a game on a
   plane: fewer Y layers means fewer cells for the same rebuild cost formula.
4. `suggestCellSize()` gives a reasoned starting point.
5. Object sets with different populations need **different grids** with
   different `cellSize`.
6. `queryBuffer` (and `queryPointBuffer`) are overwritten by the next query.
7. `AngleMath.approach()` is a correct turn across ±π.

---

[← Time and events](07-time-events-capacity.md) | [Contents](README.md) | [Performance →](09-performance.md)
