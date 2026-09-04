import Foundation

/// Grows the world BEFORE it runs out of entity ids. Port of
/// `EcsCapacityPolicySystem`.
///
/// `World.createEntity()` returns -1 when the world is full, and
/// `World.reserveCapacity()` is an explicit allocating barrier that must not
/// run in the middle of a system pass. That combination is fine while the
/// population is predictable, but a simulation that grows explosively can
/// double its population in seconds and start silently losing spawns.
///
/// **Register it immediately after the reaper**, or on another explicit phase
/// boundary. Growth reallocates every world and store buffer.
public final class CapacityPolicySystem: System {
    /// Called after a successful growth so the app can resize buffers the
    /// library knows nothing about.
    public var onCapacityGrown: ((_ previous: Int32, _ new: Int32) -> Void)?

    /// Grow once this fraction of the world is occupied by live entities.
    public var growThreshold: Float = 0.85
    /// New capacity is the old one times this.
    public var growthFactor: Float = 1.5
    /// Hard ceiling. 0 means "no limit beyond the handle layout".
    public var maximumCapacity: Int32 = 0
    /// How often the check runs.
    public var checkIntervalFrames: Int32 = 30

    public private(set) var growthCount: Int32 = 0
    public private(set) var lastGrowthCapacity: Int32 = 0

    private weak var world: World?
    private var framesSinceCheck: Int32 = 0

    public init(world: World? = nil, name: String = "CapacityPolicy") {
        super.init()
        self.world = world
        systemName = name
        writesWorldStructure = true
        _ = completeAccessMetadata()
    }

    public override func setup(world: World, context: Any?) {
        if self.world == nil { self.world = world }
    }

    public override func execute(delta: Float) {
        guard let world else { return }
        framesSinceCheck += 1
        if framesSinceCheck < checkIntervalFrames { return }
        framesSinceCheck = 0
        if world.getLoadFactor() < growThreshold { return }
        _ = growNow()
    }

    /// Runs the growth check immediately, ignoring the interval. Use it right
    /// before a burst whose size you already know.
    @discardableResult
    public func growNow() -> Bool {
        guard let world else { return false }
        let previous = world.capacity
        var target = Int32((Float(previous) * max(growthFactor, 1.01)).rounded(.up))
        if target <= previous { target = previous + 1 }
        if maximumCapacity > 0 { target = min(target, maximumCapacity) }
        if target <= previous { return false }
        if !world.reserveCapacity(target) { return false }
        growthCount += 1
        lastGrowthCapacity = target
        onCapacityGrown?(previous, target)
        return true
    }
}
