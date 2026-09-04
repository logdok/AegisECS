import Foundation

/// Records what each frame cost, per system, into a fixed-size ring buffer.
/// Port of `EcsFrameRecorder`.
///
/// **This is the useful part.** A live readout of the current frame moves too
/// fast to read and shows whichever frame you happened to look at; the
/// interesting one has almost always already passed. Keeping a window of
/// history turns "the numbers jump" into "here is the frame that cost 3x the
/// median, and here is what it spent the extra on".
///
/// Holds no engine types and never allocates after `configure()`, so it is safe
/// to leave on in a release build.
public final class FrameRecorder {
    /// 4 seconds at 60 Hz — enough for a spike to land in the window, still
    /// cheap (240 x 20 x 4 bytes ~ 19 KB).
    public static let defaultFrameCapacity = 240

    public enum Status: UInt8 {
        case executed = 0
        case skippedPaused = 1
        case disabled = 2
        case phaseOff = 3
    }

    public private(set) var frameCapacity = 0
    public private(set) var systemCount = 0

    private weak var scheduler: Scheduler?
    private weak var world: World?
    private var names: [String] = []
    private var phases: [Int32] = []
    private var requiresTimeFlags: [UInt8] = []

    // Flat ring buffers. Per-system index = slot * systemCount + i.
    private var timings = ContiguousArray<Float>()
    private var statuses = ContiguousArray<UInt8>()
    private var frameTotal = ContiguousArray<Float>()
    private var frameWall = ContiguousArray<Float>()
    private var frameSubsteps = ContiguousArray<Int32>()
    private var frameLive = ContiguousArray<Int32>()
    private var framePending = ContiguousArray<Int32>()
    private var frameCapacityAt = ContiguousArray<Int32>()
    private var frameStructural = ContiguousArray<Int32>()
    private var frameID = ContiguousArray<Int32>()

    private var write = 0
    private var filled = 0
    private var framesSeen = 0
    private var lastStructural: Int64 = 0
    private var configured = false

    public private(set) var lastCaptureUsec: Float = 0

    public init() {}

    /// Binds to the pipeline and preallocates every buffer. Call once, after
    /// `Scheduler.setupAll()`.
    @discardableResult
    public func configure(scheduler: Scheduler, world: World, frames: Int = defaultFrameCapacity) -> Bool {
        self.scheduler = scheduler
        self.world = world
        systemCount = Int(scheduler.systemCount)
        frameCapacity = max(frames, 2)

        names = (0..<systemCount).map { scheduler.getSystemName(Int32($0)) }
        phases = (0..<systemCount).map { scheduler.getSystemPhase(Int32($0)) }
        requiresTimeFlags = (0..<systemCount).map { scheduler.getSystem(Int32($0))?.requiresTime == true ? 1 : 0 }

        let cells = frameCapacity * max(systemCount, 1)
        timings = ContiguousArray(repeating: 0, count: cells)
        statuses = ContiguousArray(repeating: 0, count: cells)
        frameTotal = ContiguousArray(repeating: 0, count: frameCapacity)
        frameWall = ContiguousArray(repeating: 0, count: frameCapacity)
        frameSubsteps = ContiguousArray(repeating: 0, count: frameCapacity)
        frameLive = ContiguousArray(repeating: 0, count: frameCapacity)
        framePending = ContiguousArray(repeating: 0, count: frameCapacity)
        frameCapacityAt = ContiguousArray(repeating: 0, count: frameCapacity)
        frameStructural = ContiguousArray(repeating: 0, count: frameCapacity)
        frameID = ContiguousArray(repeating: 0, count: frameCapacity)

        write = 0; filled = 0; framesSeen = 0
        lastStructural = world.structuralVersion
        configured = true
        return true
    }

    /// Records the frame that just finished. Call it as the last thing in the
    /// frame. `substeps` is how many times the simulation phase ran (pass
    /// `SimulationClock.getLastSubsteps()` for a fixed step, else 1).
    /// `wallFrameUsec` is the whole drawn frame's duration if known — the gap
    /// between it and the recorded ECS sum is everything outside the scheduler.
    public func capture(substeps: Int32 = 1, wallFrameUsec: Float = 0) {
        guard configured, let scheduler, let world else { return }
        let started = DispatchTime.now().uptimeNanoseconds

        let slot = write
        let base = slot * systemCount
        var total: Float = 0

        timings.withUnsafeMutableBufferPointer { t in
            statuses.withUnsafeMutableBufferPointer { s in
                for i in 0..<systemCount {
                    let value = scheduler.getTimingUsec(Int32(i))
                    t[base + i] = value
                    total += value
                    if scheduler.wasSystemExecuted(Int32(i)) {
                        s[base + i] = Status.executed.rawValue
                    } else if !scheduler.isSystemEnabled(Int32(i)) {
                        s[base + i] = Status.disabled.rawValue
                    } else if !scheduler.isPhaseAllowed(Int32(i)) {
                        s[base + i] = Status.phaseOff.rawValue
                    } else {
                        s[base + i] = Status.skippedPaused.rawValue
                    }
                }
            }
        }

        let structural = world.structuralVersion
        frameTotal[slot] = total
        frameWall[slot] = wallFrameUsec
        frameSubsteps[slot] = max(substeps, 1)
        frameLive[slot] = world.getLiveCount()
        framePending[slot] = world.getPendingDestroyCount()
        frameCapacityAt[slot] = world.capacity
        frameStructural[slot] = Int32(structural - lastStructural)
        frameID[slot] = Int32(framesSeen)
        lastStructural = structural

        write = (write + 1) % frameCapacity
        filled = min(filled + 1, frameCapacity)
        framesSeen += 1
        lastCaptureUsec = Float(DispatchTime.now().uptimeNanoseconds - started) / 1000.0
    }

    /// Forgets the window without reallocating.
    public func clear() {
        write = 0; filled = 0; framesSeen = 0
        if let world { lastStructural = world.structuralVersion }
    }

    public var isConfigured: Bool { configured }
    public var frameCount: Int { filled }
    public var framesSeenCount: Int { framesSeen }

    public var newestSlot: Int { filled == 0 ? -1 : (write - 1 + frameCapacity) % frameCapacity }
    public var oldestSlot: Int { filled == 0 ? -1 : (write - filled + frameCapacity) % frameCapacity }
    public func slotFromNewest(age: Int) -> Int {
        (age < 0 || age >= filled) ? -1 : (write - 1 - age + frameCapacity) % frameCapacity
    }
    public func slotInOrder(_ index: Int) -> Int {
        guard index >= 0 && index < filled else { return -1 }
        return (oldestSlot + index) % frameCapacity
    }

    public func frameTotalUsec(_ slot: Int) -> Float { frameTotal[slot] }
    public func frameWallUsec(_ slot: Int) -> Float { frameWall[slot] }
    public func frameSubstepsCount(_ slot: Int) -> Int32 { frameSubsteps[slot] }
    public func frameLiveCount(_ slot: Int) -> Int32 { frameLive[slot] }
    public func framePendingDestroy(_ slot: Int) -> Int32 { framePending[slot] }
    public func frameWorldCapacity(_ slot: Int) -> Int32 { frameCapacityAt[slot] }
    public func frameStructuralDelta(_ slot: Int) -> Int32 { frameStructural[slot] }
    public func frameIDValue(_ slot: Int) -> Int32 { frameID[slot] }

    public func systemName(_ index: Int) -> String { names[index] }
    public func systemPhase(_ index: Int) -> Int32 { phases[index] }
    public func systemRequiresTime(_ index: Int) -> Bool { requiresTimeFlags[index] == 1 }
    public func timingUsec(slot: Int, system: Int) -> Float { timings[slot * systemCount + system] }
    public func status(slot: Int, system: Int) -> UInt8 { statuses[slot * systemCount + system] }

    func withTimings<R>(_ body: (UnsafeBufferPointer<Float>) -> R) -> R { timings.withUnsafeBufferPointer(body) }
    func withStatuses<R>(_ body: (UnsafeBufferPointer<UInt8>) -> R) -> R { statuses.withUnsafeBufferPointer(body) }

    public func memoryUsage() -> Int { timings.count * 4 + statuses.count + frameCapacity * 30 }
}
