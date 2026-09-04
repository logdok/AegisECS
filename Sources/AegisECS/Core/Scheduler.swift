import Foundation

/// Ordered, deterministic system pipeline with per-system profiling built in.
/// Port of `EcsScheduler`.
///
/// The scheduler holds ALL of "what runs after what" in one place. The list is
/// set once while building the world and never changes.
///
/// **System order is behaviour, not code style.** Swapping two registration
/// lines changes what happens: if system B reads what system A writes in the
/// same frame, A must come first.
///
/// The scheduler does not own the systems — the caller keeps them alive.
public final class Scheduler {
    /// Weight of the newest sample in the smoothed timing. Lower is steadier.
    public static let averageSmoothing: Float = 0.1

    /// Measuring costs two clock reads per system per frame. Turn it off to run
    /// the loop with no instrumentation at all.
    public var profilingEnabled = true

    private var systems: [System] = []
    private var timingsUsec: [Float] = []
    private var averageUsec: [Float] = []
    private var phaseAllowed: [UInt8] = []
    private var executed: [UInt8] = []
    private var isSetup = false
    private weak var world: World?
    private var context: Any?

    public init() {}

    /// Registers a system and returns it. The order of `addSystem` calls is the
    /// order of execution.
    @discardableResult
    public func addSystem(_ system: System, phase: Int32 = 0) -> System {
        if isSetup {
            AegisDiagnostics.report("Scheduler: addSystem() after setupAll() is not allowed")
            return system
        }
        if systems.contains(where: { $0 === system }) {
            AegisDiagnostics.report("Scheduler: the same system object was registered twice")
            return system
        }
        if !system.assignPhase(phase, owner: ObjectIdentifier(self)) { return system }
        systems.append(system)
        timingsUsec.append(0)
        averageUsec.append(0)
        phaseAllowed.append(1)
        executed.append(0)
        return system
    }

    /// Calls `setup` on every registered system. Call once, when the world, all
    /// stores and the whole system list are ready.
    @discardableResult
    public func setupAll(world: World, context: Any?) -> Bool {
        if isSetup {
            AegisDiagnostics.report("Scheduler: setupAll() was already called")
            return false
        }
        self.world = world
        self.context = context
        for system in systems { system.setup(world: world, context: context) }
        isSetup = true
        return true
    }

    public func teardownAll() {
        guard isSetup else { return }
        for index in stride(from: systems.count - 1, through: 0, by: -1) {
            systems[index].teardown()
        }
        isSetup = false
        world = nil
        context = nil
    }

    /// Runs EVERY system for one frame, strictly in registration order. Pass
    /// `0` to pause: systems that declared `requiresTime` are skipped.
    public func executeAll(delta: Float) {
        guard isSetup else {
            AegisDiagnostics.report("Scheduler: executeAll() before setupAll()")
            return
        }
        beginFrame()
        let timeStopped = delta <= 0
        if profilingEnabled {
            for i in systems.indices {
                let system = systems[i]
                if !system.enabled || phaseAllowed[i] == 0 { continue }
                if timeStopped && system.requiresTime { continue }
                let started = DispatchTime.now().uptimeNanoseconds
                system.execute(delta: delta)
                timingsUsec[i] += Float(DispatchTime.now().uptimeNanoseconds - started) / 1000.0
                executed[i] = 1
            }
        } else {
            for i in systems.indices {
                let system = systems[i]
                if !system.enabled || phaseAllowed[i] == 0 { continue }
                if timeStopped && system.requiresTime { continue }
                system.execute(delta: delta)
                executed[i] = 1
            }
        }
    }

    /// Closes the previous frame's measurements and clears per-frame state.
    /// Timings ACCUMULATE between two `beginFrame()` calls.
    public func beginFrame() {
        if profilingEnabled {
            for i in averageUsec.indices {
                averageUsec[i] += (timingsUsec[i] - averageUsec[i]) * Scheduler.averageSmoothing
            }
        }
        for i in timingsUsec.indices { timingsUsec[i] = 0 }
        for i in executed.indices { executed[i] = 0 }
    }

    /// Runs one phase in registration order. Phases are a filter and metadata;
    /// the scheduler never sorts systems by itself.
    public func executePhase(_ phase: Int32, delta: Float) {
        guard isSetup else {
            AegisDiagnostics.report("Scheduler: executePhase() before setupAll()")
            return
        }
        let timeStopped = delta <= 0
        for i in systems.indices {
            let system = systems[i]
            if system.systemPhase != phase || !system.enabled || phaseAllowed[i] == 0 { continue }
            if timeStopped && system.requiresTime { continue }
            if profilingEnabled {
                let started = DispatchTime.now().uptimeNanoseconds
                system.execute(delta: delta)
                timingsUsec[i] += Float(DispatchTime.now().uptimeNanoseconds - started) / 1000.0
            } else {
                system.execute(delta: delta)
            }
            executed[i] = 1
        }
    }

    public func setSystemEnabled(_ index: Int32, _ value: Bool) {
        guard inRange(index) else { return }
        systems[Int(index)].enabled = value
        if !value { timingsUsec[Int(index)] = 0; executed[Int(index)] = 0 }
    }

    public func isSystemEnabled(_ index: Int32) -> Bool {
        inRange(index) && systems[Int(index)].enabled
    }

    public func setPhaseEnabled(_ phase: Int32, _ value: Bool) {
        for i in systems.indices where systems[i].systemPhase == phase {
            phaseAllowed[i] = value ? 1 : 0
            if !value { timingsUsec[i] = 0; executed[i] = 0 }
        }
    }

    /// Whether a system is allowed to run by its PHASE, as opposed to its own
    /// enabled switch. Tools need to tell the two apart.
    public func isPhaseAllowed(_ index: Int32) -> Bool {
        inRange(index) && phaseAllowed[Int(index)] == 1
    }

    public func isPhaseEnabled(_ phase: Int32) -> Bool {
        for i in systems.indices where systems[i].systemPhase == phase && phaseAllowed[i] == 0 {
            return false
        }
        return true
    }

    public var systemCount: Int32 { Int32(systems.count) }
    public func getSystemName(_ index: Int32) -> String { inRange(index) ? systems[Int(index)].systemName : "" }
    public func getSystem(_ index: Int32) -> System? { inRange(index) ? systems[Int(index)] : nil }
    public func getSystemPhase(_ index: Int32) -> Int32 { inRange(index) ? systems[Int(index)].systemPhase : 0 }

    /// Index of the first system with this name, or -1. Cold path.
    public func findSystem(_ name: String) -> Int32 {
        for i in systems.indices where systems[i].systemName == name { return Int32(i) }
        return -1
    }

    public func wasSystemExecuted(_ index: Int32) -> Bool { inRange(index) && executed[Int(index)] == 1 }

    /// Time the system spent in the last frame, in microseconds. Microseconds
    /// rather than milliseconds on purpose: cheap systems land in single digits.
    public func getTimingUsec(_ index: Int32) -> Float { inRange(index) ? timingsUsec[Int(index)] : 0 }

    /// Exponentially smoothed timing, in microseconds. Far steadier than the
    /// per-frame value — normally what a live overlay wants.
    public func getAverageTimingUsec(_ index: Int32) -> Float { inRange(index) ? averageUsec[Int(index)] : 0 }

    public func getTotalTimingUsec() -> Float { timingsUsec.reduce(0, +) }

    public func resetProfiling() {
        for i in timingsUsec.indices { timingsUsec[i] = 0 }
        for i in averageUsec.indices { averageUsec[i] = 0 }
        for i in executed.indices { executed[i] = 0 }
    }

    /// Cold-path validation for build tools and tests.
    @discardableResult
    public func validatePipeline(world: World, reportErrors: Bool = true) -> Bool {
        var valid = true
        var previousPhase = Int32.min
        for system in systems {
            if system.systemName.isEmpty || system.systemName == "UnnamedSystem" {
                valid = false
                if reportErrors { AegisDiagnostics.report("Scheduler: a system has no diagnostic name") }
            }
            if system.systemPhase < previousPhase {
                valid = false
                if reportErrors { AegisDiagnostics.report("Scheduler: phases must not decrease in registration order") }
            }
            previousPhase = system.systemPhase
            for list in [system.readComponentTypes, system.writeComponentTypes, system.structuralWriteComponentTypes] {
                for typeID in list where !world.hasStore(typeID) {
                    valid = false
                    if reportErrors {
                        AegisDiagnostics.report("Scheduler: system \(system.systemName) references unregistered type \(typeID)")
                    }
                }
            }
        }
        return valid
    }

    /// Conservative dependency analysis for tools and future parallel batches.
    /// The current scheduler stays deliberately sequential.
    public func systemsConflict(_ first: Int32, _ second: Int32) -> Bool {
        guard inRange(first), inRange(second) else { return true }
        let a = systems[Int(first)], b = systems[Int(second)]
        if !a.accessMetadataComplete || !b.accessMetadataComplete { return true }
        if a.writesWorldStructure || b.writesWorldStructure { return true }
        func intersects(_ x: [Int32], _ y: [Int32]) -> Bool { x.contains { y.contains($0) } }
        if intersects(a.writeComponentTypes, b.readComponentTypes)
            || intersects(a.writeComponentTypes, b.writeComponentTypes)
            || intersects(a.writeComponentTypes, b.structuralWriteComponentTypes)
            || intersects(b.writeComponentTypes, a.readComponentTypes)
            || intersects(b.writeComponentTypes, a.structuralWriteComponentTypes) {
            return true
        }
        func structuralConflict(_ types: [Int32], _ other: System) -> Bool {
            intersects(types, other.readComponentTypes)
                || intersects(types, other.writeComponentTypes)
                || intersects(types, other.structuralWriteComponentTypes)
        }
        return structuralConflict(a.structuralWriteComponentTypes, b)
            || structuralConflict(b.structuralWriteComponentTypes, a)
    }

    private func inRange(_ index: Int32) -> Bool { index >= 0 && index < Int32(systems.count) }
}
