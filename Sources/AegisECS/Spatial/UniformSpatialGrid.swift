import Foundation

public struct SIMDVector3 { public var x, y, z: Float
    public init(_ x: Float, _ y: Float, _ z: Float) { self.x = x; self.y = y; self.z = z }
    @inline(__always) func distanceSquared(to o: SIMDVector3) -> Float {
        let dx = x - o.x, dy = y - o.y, dz = z - o.z
        return dx*dx + dy*dy + dz*dz
    }
}

/// Uniform 3D broadphase grid built on a counting sort over flat arrays. Port
/// of `UniformSpatialGrid`.
///
/// Built for "everything moves every frame": there is no point move, the whole
/// index is rebuilt with `rebuild()`. Counting sort reshuffles every entry in
/// three linear passes with no allocation (all buffers preallocated in
/// `configure`), all three working on the same `cellOffsets` array.
///
/// **The rebuild costs O(entries + CELLS)** — pass 2 walks every cell including
/// the empty ones — so `cellSize` is critical; `suggestCellSize` does the
/// arithmetic. `verticalExtent == 0` collapses the grid to one Y layer.
public final class UniformSpatialGrid {
    public static let maxQueryResults = 2048

    private var cellSize: Float = 1
    private var invCellSize: Float = 1
    private var dimX = 0, dimY = 0, dimZ = 0
    private var cellCount = 0
    private var originXZ: Float = 0
    private var flat = false

    /// Size is `cellCount + 1`. Through `rebuild()` it plays three roles in
    /// turn: histogram -> cell "ends" -> cell "starts". On return it is always
    /// "starts".
    private var cellOffsets = ContiguousArray<Int32>()
    private var scratchCells = ContiguousArray<Int32>()
    private var entryCountValue = 0

    /// Entries sorted by cell. Read-only from outside; valid prefix is
    /// `0..<entryCount`.
    public private(set) var sortedEntities = ContiguousArray<Int32>()
    public private(set) var sortedPoints = ContiguousArray<SIMDVector3>()

    /// Result of the last `querySphere`. Read-only, OVERWRITTEN by the next query.
    public private(set) var queryBuffer = ContiguousArray<Int32>()
    public private(set) var queryPointBuffer = ContiguousArray<SIMDVector3>()

    /// Makes `querySphere` fill `queryPointBuffer` too. Off by default.
    public var storeQueryPoints = false

    public init() {}

    /// `arenaRadius` bounds the XZ plane, `verticalExtent` bounds Y upward from
    /// zero. Anything past the bounds is clamped to edge cells, not lost. Pass
    /// `verticalExtent = 0` for a flat world. `entryCapacity` is the largest
    /// number of entries any one `rebuild()` will ever get.
    public func configure(arenaRadius: Float, verticalExtent: Float, cellSize: Float, entryCapacity: Int) {
        self.cellSize = max(cellSize, 0.01)
        invCellSize = 1 / self.cellSize
        originXZ = -arenaRadius
        dimX = Int((arenaRadius * 2 * invCellSize).rounded(.up)) + 1
        dimZ = dimX
        flat = verticalExtent <= 0
        dimY = flat ? 1 : Int((max(verticalExtent, self.cellSize) * invCellSize).rounded(.up)) + 1
        cellCount = dimX * dimY * dimZ

        cellOffsets = ContiguousArray(repeating: 0, count: cellCount + 1)
        scratchCells = ContiguousArray(repeating: 0, count: entryCapacity)
        sortedEntities = ContiguousArray(repeating: 0, count: entryCapacity)
        sortedPoints = ContiguousArray(repeating: SIMDVector3(0, 0, 0), count: entryCapacity)
        let qcap = min(entryCapacity, UniformSpatialGrid.maxQueryResults)
        queryBuffer = ContiguousArray(repeating: 0, count: qcap)
        queryPointBuffer = ContiguousArray(repeating: SIMDVector3(0, 0, 0), count: qcap)
        entryCountValue = 0
    }

    /// Starting point for `cellSize`: roughly one cell per expected object,
    /// with a floor of twice the typical query radius.
    public static func suggestCellSize(arenaRadius: Float, verticalExtent: Float, expectedEntries: Int, typicalQueryRadius: Float) -> Float {
        let span = max(arenaRadius * 2, 0.01)
        let entries = Float(max(expectedEntries, 1))
        let densitySize: Float
        if verticalExtent <= 0 {
            densitySize = span / entries.squareRoot()
        } else {
            densitySize = pow(span * span * max(verticalExtent, 0.01) / entries, 1.0 / 3.0)
        }
        return max(densitySize, max(typicalQueryRadius, 0.01) * 2)
    }

    /// Fully rebuilds the index from a flat pair of arrays.
    public func rebuild(entityIDs: UnsafePointer<Int32>, points: UnsafePointer<SIMDVector3>, entryCount: Int) {
        let clamped = min(max(entryCount, 0), scratchCells.count)
        entryCountValue = clamped
        for i in cellOffsets.indices { cellOffsets[i] = 0 }
        if clamped <= 0 { return }

        let lastX = Int32(dimX - 1), lastZ = Int32(dimZ - 1)
        let origin = originXZ, inv = invCellSize
        let dx = Int32(dimX), dz = Int32(dimZ)

        scratchCells.withUnsafeMutableBufferPointer { cells in
            cellOffsets.withUnsafeMutableBufferPointer { offsets in
                // Pass 1 — cell of each entry + histogram.
                if flat {
                    for i in 0..<clamped {
                        let p = points[i]
                        let cx = clampi(Int32((p.x - origin) * inv), 0, lastX)
                        let cz = clampi(Int32((p.z - origin) * inv), 0, lastZ)
                        let cell = cz * dx + cx
                        cells[i] = cell
                        offsets[Int(cell)] += 1
                    }
                } else {
                    let lastY = Int32(dimY - 1)
                    for i in 0..<clamped {
                        let p = points[i]
                        let cx = clampi(Int32((p.x - origin) * inv), 0, lastX)
                        let cy = clampi(Int32(p.y * inv), 0, lastY)
                        let cz = clampi(Int32((p.z - origin) * inv), 0, lastZ)
                        let cell = (cy * dz + cz) * dx + cx
                        cells[i] = cell
                        offsets[Int(cell)] += 1
                    }
                }
                // Pass 2 — inclusive prefix sums in place.
                var running: Int32 = 0
                for c in 0..<cellCount {
                    running += offsets[c]
                    offsets[c] = running
                }
                offsets[cellCount] = running
                // Pass 3 — scatter, iterating BACKWARD and decrementing each
                // cell's "end" before each write. Afterward every offset points
                // at its cell's start again.
                sortedEntities.withUnsafeMutableBufferPointer { outE in
                    sortedPoints.withUnsafeMutableBufferPointer { outP in
                        var i = clamped
                        while i > 0 {
                            i -= 1
                            let cell = Int(cells[i])
                            let slot = offsets[cell] - 1
                            offsets[cell] = slot
                            outE[Int(slot)] = entityIDs[i]
                            outP[Int(slot)] = points[i]
                        }
                    }
                }
            }
        }
    }

    public func rebuild(entityIDs: [Int32], points: [SIMDVector3], entryCount: Int) {
        entityIDs.withUnsafeBufferPointer { e in
            points.withUnsafeBufferPointer { p in
                rebuild(entityIDs: e.baseAddress!, points: p.baseAddress!, entryCount: entryCount)
            }
        }
    }

    /// Id of the nearest indexed entity within `radius`, or -1.
    public func queryNearest(center: SIMDVector3, radius: Float) -> Int32 {
        if entryCountValue <= 0 { return -1 }
        var bestEntity: Int32 = -1
        var bestDistanceSq = radius * radius
        let (minX, maxX, minY, maxY, minZ, maxZ) = cellBox(center, radius)
        for cy in minY...maxY {
            for cz in minZ...maxZ {
                let rowBase = (cy * dimZ + cz) * dimX
                let start = Int(cellOffsets[rowBase + minX])
                let end = Int(cellOffsets[rowBase + maxX + 1])
                for s in start..<end {
                    let d = sortedPoints[s].distanceSquared(to: center)
                    if d < bestDistanceSq { bestDistanceSq = d; bestEntity = sortedEntities[s] }
                }
            }
        }
        return bestEntity
    }

    /// Fills `queryBuffer` with every indexed entity within `radius` and
    /// returns how many ids were written.
    @discardableResult
    public func querySphere(center: SIMDVector3, radius: Float, resultLimit: Int) -> Int {
        if entryCountValue <= 0 { return 0 }
        let cappedLimit = min(resultLimit, queryBuffer.count)
        if cappedLimit <= 0 { return 0 }
        var written = 0
        let radiusSq = radius * radius
        let (minX, maxX, minY, maxY, minZ, maxZ) = cellBox(center, radius)
        let withPoints = storeQueryPoints
        for cy in minY...maxY {
            for cz in minZ...maxZ {
                let rowBase = (cy * dimZ + cz) * dimX
                let start = Int(cellOffsets[rowBase + minX])
                let end = Int(cellOffsets[rowBase + maxX + 1])
                for s in start..<end {
                    let point = sortedPoints[s]
                    if point.distanceSquared(to: center) > radiusSq { continue }
                    if written >= cappedLimit { return written }
                    queryBuffer[written] = sortedEntities[s]
                    if withPoints { queryPointBuffer[written] = point }
                    written += 1
                }
            }
        }
        return written
    }

    public func getEntryCount() -> Int { entryCountValue }
    public func getCellCount() -> Int { cellCount }
    public func getCellSize() -> Float { cellSize }
    public func getDimensions() -> (Int, Int, Int) { (dimX, dimY, dimZ) }
    public func isFlat() -> Bool { flat }
    public func getCellStart(_ cell: Int) -> Int32 { cellOffsets[cell] }
    public func getCellEnd(_ cell: Int) -> Int32 { cellOffsets[cell + 1] }

    private func cellBox(_ center: SIMDVector3, _ radius: Float) -> (Int, Int, Int, Int, Int, Int) {
        (
            Int(clampi(Int32((center.x - radius - originXZ) * invCellSize), 0, Int32(dimX - 1))),
            Int(clampi(Int32((center.x + radius - originXZ) * invCellSize), 0, Int32(dimX - 1))),
            Int(clampi(Int32((center.y - radius) * invCellSize), 0, Int32(dimY - 1))),
            Int(clampi(Int32((center.y + radius) * invCellSize), 0, Int32(dimY - 1))),
            Int(clampi(Int32((center.z - radius - originXZ) * invCellSize), 0, Int32(dimZ - 1))),
            Int(clampi(Int32((center.z + radius - originXZ) * invCellSize), 0, Int32(dimZ - 1)))
        )
    }
}

@inline(__always)
func clampi(_ value: Int32, _ lo: Int32, _ hi: Int32) -> Int32 { min(max(value, lo), hi) }
