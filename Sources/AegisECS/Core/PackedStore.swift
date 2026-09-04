import Foundation

/// Element type of one payload column. The Swift stand-in for the GDScript
/// original's `Packed*Array` field types. Object-holding columns are absent by
/// design — a store that needs one subclasses `ComponentStore` with the
/// `.releaseDense` hook.
public enum ColumnType: UInt8, Sendable {
    case uint8
    case int32
    case int64
    case float32
    case float64
    case vec2   // 2 x float32
    case vec3   // 3 x float32
    case vec4   // 4 x float32, also the shape of a colour

    public var elementSize: Int {
        switch self {
        case .uint8: return 1
        case .int32, .float32: return 4
        case .int64, .float64, .vec2: return 8
        case .vec3: return 12
        case .vec4: return 16
        }
    }
}

/// Declarative component store: you declare the columns, the base class writes
/// all the plumbing. Port of `EcsPackedStore`.
///
/// The original took field NAMES and resolved them by reflection. Swift has no
/// equivalent, so a schema of column TYPES is passed instead. What matters is
/// preserved: reserve, grow and relocate are generated rather than hand-written,
/// which removes the single most damaging mistake in the hand-written form.
///
/// Columns are backed by explicitly allocated buffers (not Swift arrays), so
/// `columnF32(_:)` can hand back a stable base pointer a system hoists once and
/// indexes directly — the same contract the C++ port and the GDScript original
/// give. The pointer is valid until the world's capacity grows.
open class PackedStore: ComponentStore {
    private final class Column {
        let type: ColumnType
        let stride: Int
        var storage: UnsafeMutableRawBufferPointer

        init(type: ColumnType) {
            self.type = type
            self.stride = type.elementSize
            self.storage = UnsafeMutableRawBufferPointer(start: nil, count: 0)
        }

        func resize(_ elementCount: Int32, zeroFill: Bool) {
            let bytes = Int(elementCount) * stride
            let fresh = UnsafeMutableRawBufferPointer.allocate(byteCount: max(bytes, 1), alignment: 16)
            if zeroFill {
                fresh.initializeMemory(as: UInt8.self, repeating: 0)
            } else {
                let carry = min(storage.count, bytes)
                if carry > 0 { fresh.copyMemory(from: UnsafeRawBufferPointer(rebasing: storage[0..<carry])) }
                if bytes > carry {
                    UnsafeMutableRawBufferPointer(rebasing: fresh[carry..<bytes])
                        .initializeMemory(as: UInt8.self, repeating: 0)
                }
            }
            storage.deallocate()
            storage = fresh
        }

        deinit { storage.deallocate() }
    }

    private var columns: [Column]

    /// Builds a store with the given column schema. An empty schema is an
    /// error; use `TagStore` for a payload-free component.
    public init(schema: [ColumnType]) {
        if schema.isEmpty {
            AegisDiagnostics.report("PackedStore: no columns declared — use TagStore for a payload-free component")
        }
        self.columns = schema.map { Column(type: $0) }
        super.init()
    }

    /// `.growDense` so `world.reserveCapacity()` works — a resize preserves the
    /// live prefix. `.relocateBatch` so batched destruction resolves each
    /// column once instead of once per move.
    public override var hooks: Hooks { [.growDense, .relocateBatch] }

    public var columnCount: Int32 { Int32(columns.count) }

    public func columnType(_ index: Int32) -> ColumnType? {
        guard index >= 0 && index < columnCount else { return nil }
        return columns[Int(index)].type
    }

    /// Raw base pointer of a column's dense buffer, valid until the world's
    /// capacity grows. Index it by dense slot, never by entity id.
    public func columnData(_ index: Int32) -> UnsafeMutableRawPointer? {
        guard index >= 0 && index < columnCount else { return nil }
        return columns[Int(index)].storage.baseAddress
    }

    /// Typed accessors. They return `nil` when the index is out of range or the
    /// column is not of that type, so a schema mismatch surfaces as `nil`
    /// rather than reinterpreted bytes.
    public func columnF32(_ index: Int32) -> UnsafeMutablePointer<Float>? {
        checked(index, .float32)?.assumingMemoryBound(to: Float.self)
    }
    public func columnF64(_ index: Int32) -> UnsafeMutablePointer<Double>? {
        checked(index, .float64)?.assumingMemoryBound(to: Double.self)
    }
    public func columnI32(_ index: Int32) -> UnsafeMutablePointer<Int32>? {
        checked(index, .int32)?.assumingMemoryBound(to: Int32.self)
    }
    public func columnI64(_ index: Int32) -> UnsafeMutablePointer<Int64>? {
        checked(index, .int64)?.assumingMemoryBound(to: Int64.self)
    }
    public func columnU8(_ index: Int32) -> UnsafeMutablePointer<UInt8>? {
        checked(index, .uint8)?.assumingMemoryBound(to: UInt8.self)
    }

    private func checked(_ index: Int32, _ expected: ColumnType) -> UnsafeMutableRawPointer? {
        guard index >= 0 && index < columnCount, columns[Int(index)].type == expected else { return nil }
        return columns[Int(index)].storage.baseAddress
    }

    /// Writes a zero of the column's type into `slot` of every column. Dense
    /// slots are recycled, so a freshly attached component starts out holding
    /// whatever the slot's previous owner left behind.
    public func clearSlot(_ slot: Int32) {
        guard slot >= 0 && slot < count else { return }
        for column in columns {
            let base = column.storage.baseAddress!.advanced(by: Int(slot) * column.stride)
            memset(base, 0, column.stride)
        }
    }

    public override func reserveDense(_ capacity: Int32) {
        for column in columns { column.resize(capacity, zeroFill: true) }
    }

    public override func growDense(previousCapacity: Int32, newCapacity: Int32) {
        for column in columns { column.resize(newCapacity, zeroFill: false) }
    }

    public override func relocateDense(from: Int32, to: Int32) {
        for column in columns {
            let base = column.storage.baseAddress!
            memcpy(base.advanced(by: Int(to) * column.stride),
                   base.advanced(by: Int(from) * column.stride),
                   column.stride)
        }
    }

    public override func relocateDenseBatch(from: UnsafePointer<Int32>, to: UnsafePointer<Int32>, moveCount: Int32) {
        // Resolving each column once and then walking the moves turns a per-move
        // lookup into a per-column one; this is where the batched destruction
        // path gets most of its speed.
        for column in columns {
            let base = column.storage.baseAddress!
            let stride = column.stride
            for move in 0..<Int(moveCount) {
                memcpy(base.advanced(by: Int(to[move]) * stride),
                       base.advanced(by: Int(from[move]) * stride),
                       stride)
            }
        }
    }
}
