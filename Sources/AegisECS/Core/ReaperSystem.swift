import Foundation

/// The only system that actually destroys entities. Port of `EcsReaperSystem`.
///
/// Every other system merely calls `World.queueDestroy()`; the real removal
/// happens here, in `World.flushDestroyQueue()`. This class exists so that the
/// library's most important rule is something you REGISTER rather than
/// something you must remember to write.
///
/// **Register it last, and exactly one per pipeline.** A flush in the middle of
/// a frame would let a dense slot cached by an earlier system point at a
/// different entity by the time a later one reads it.
///
/// It deliberately does NOT set `requiresTime`: entities marked for destruction
/// before a pause still have to be cleaned up.
public final class ReaperSystem: System {
    /// Entities destroyed by the last `execute()`.
    public private(set) var lastReaped: Int32 = 0
    /// Entities destroyed since this system was created.
    public private(set) var totalReaped: Int64 = 0

    private weak var world: World?

    public init(world: World? = nil, name: String = "Reaper") {
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
        lastReaped = world.flushDestroyQueue()
        totalReaped += Int64(lastReaped)
    }
}
