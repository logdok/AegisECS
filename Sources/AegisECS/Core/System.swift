import Foundation

/// One unit of simulation logic. Port of `EcsSystem`.
///
/// A system is pure logic with no game data of its own. It does not keep
/// world-owned state in its fields; it re-reads and writes the component stores
/// every frame. Systems run in the FIXED order they were registered in — that
/// order is itself part of the game's behaviour.
///
/// The `context` passed to `setup` is untyped on purpose: the library knows
/// nothing about your app. Cast it in `setup` and keep a typed reference.
open class System {
    /// Shown in profiling output, so set it in the subclass initialiser.
    open var systemName: String = "UnnamedSystem"

    /// Runtime switch. A disabled system keeps its stable index in the
    /// scheduler and reports zero time for the frames it skipped.
    public var enabled: Bool = true

    /// Declares that this system does nothing when time is not advancing. Pause
    /// is a zero-length step, not a skipped call, so rendering and other
    /// time-independent systems keep running. Set this and the scheduler skips
    /// the call while the step is zero — safer than an early return.
    public var requiresTime: Bool = false

    /// Optional access description. It adds no checks to the hot path and does
    /// not affect execution order; tools use it to validate views and to work
    /// out which systems could safely overlap.
    public private(set) var readComponentTypes: [Int32] = []
    public private(set) var writeComponentTypes: [Int32] = []
    public private(set) var structuralWriteComponentTypes: [Int32] = []
    public var writesWorldStructure = false
    public private(set) var accessMetadataComplete = false

    public private(set) var systemPhase: Int32 = 0
    private var phaseLocked = false
    private var schedulerOwner: ObjectIdentifier?

    public init() {}

    /// Called once, after every store is registered and the whole pipeline is
    /// assembled — so a system may safely cache references to stores here.
    open func setup(world: World, context: Any?) {}

    /// Called in reverse registration order from `Scheduler.teardownAll()`.
    open func teardown() {}

    /// Called once per frame, in the order the scheduler defines. Pausing
    /// passes `0`.
    open func execute(delta: Float) {}

    @discardableResult public func declareRead(_ typeID: Int32) -> Self { appendUnique(&readComponentTypes, typeID); return self }
    @discardableResult public func declareWrite(_ typeID: Int32) -> Self { appendUnique(&writeComponentTypes, typeID); return self }
    @discardableResult public func declareStructuralWrite(_ typeID: Int32) -> Self { appendUnique(&structuralWriteComponentTypes, typeID); return self }

    public func hasDeclaredAccess(_ typeID: Int32) -> Bool {
        readComponentTypes.contains(typeID)
            || writeComponentTypes.contains(typeID)
            || structuralWriteComponentTypes.contains(typeID)
    }

    @discardableResult public func completeAccessMetadata() -> Self { accessMetadataComplete = true; return self }

    func assignPhase(_ value: Int32, owner: ObjectIdentifier) -> Bool {
        if let existing = schedulerOwner, existing != owner {
            AegisDiagnostics.report("System(\(systemName)): one instance cannot be registered in two schedulers")
            return false
        }
        schedulerOwner = owner
        systemPhase = value
        phaseLocked = true
        return true
    }

    private func appendUnique(_ values: inout [Int32], _ value: Int32) {
        if !values.contains(value) { values.append(value) }
    }
}
