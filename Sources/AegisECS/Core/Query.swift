import Foundation

/// Optional materialised cache on top of a `View`. Port of `EcsQuery`.
///
/// The result buffer is allocated once and rebuilt only when one of the stores
/// involved changed membership. A direct loop over a store is still the fastest
/// option for a single hot system; a query pays off when the same intersection
/// is read several times, or when it changes far less often than it is read.
///
/// The rebuild hoists every participating sparse array into a local before the
/// loop and never calls `View.matches`.
public final class Query {
    public private(set) var count: Int32 = 0

    private weak var world: World?
    private let view = View()
    private var entities = ContiguousArray<Entity>()
    private var trackedStores: [ComponentStore] = []
    private var lastVersions: [Int64] = []
    private var configured = false
    private var rebuildCount: Int32 = 0
    private var maximumResults: Int32 = -1
    private var truncated = false

    public init() {}

    /// `maximumResults` of -1 means "as large as the world"; any other value
    /// must be positive and caps the materialised set.
    @discardableResult
    public func configure(world: World, required requiredTypes: [Int32], excluded excludedTypes: [Int32] = [], ownerSystem: System? = nil, maximumResults: Int32 = -1) -> Bool {
        configured = false
        self.world = world
        trackedStores.removeAll()
        entities.removeAll()
        lastVersions.removeAll()
        count = 0
        rebuildCount = 0
        truncated = false
        self.maximumResults = maximumResults
        if !view.configure(world: world, required: requiredTypes, excluded: excludedTypes, ownerSystem: ownerSystem) {
            return false
        }
        for index in 0..<Int(view.requiredCount) { trackedStores.append(view.requiredStoreRef(index)) }
        for index in 0..<Int(view.excludedCount) { trackedStores.append(view.excludedStoreRef(index)) }
        if maximumResults == 0 || maximumResults < -1 {
            AegisDiagnostics.report("Query: maximumResults must be -1 or positive")
            return false
        }
        entities = ContiguousArray(repeating: kInvalidEntity, count: Int(expectedCapacity))
        lastVersions = Array(repeating: -1, count: trackedStores.count)
        configured = true
        return true
    }

    private var expectedCapacity: Int32 {
        guard let world else { return 0 }
        return maximumResults == -1 ? world.capacity : min(maximumResults, world.capacity)
    }

    /// Returns true when the cache was rebuilt, false when membership had not
    /// changed since the last call.
    @discardableResult
    public func refresh() -> Bool {
        guard configured else { return false }
        let expected = expectedCapacity
        if Int32(entities.count) != expected {
            entities = ContiguousArray(repeating: kInvalidEntity, count: Int(expected))
        }
        if isCurrent { return false }

        view.refreshDriver()
        guard let driver = view.candidateStore else { return false }
        let driverIndex = view.driverRequiredIndex
        let driverCount = driver.count

        var testRequired: [ComponentStore] = []
        for index in 0..<Int(view.requiredCount) where Int32(index) != driverIndex {
            testRequired.append(view.requiredStoreRef(index))
        }
        var testExcluded: [ComponentStore] = []
        for index in 0..<Int(view.excludedCount) { testExcluded.append(view.excludedStoreRef(index)) }

        var found: Int32 = 0
        var trunc = false

        driver.denseEntities.withUnsafeBufferPointer { candidates in
            entities.withUnsafeMutableBufferPointer { out in
                let limit = Int32(out.count)

                if testRequired.isEmpty && testExcluded.isEmpty {
                    let copied = min(driverCount, limit)
                    for i in 0..<Int(copied) { out[i] = candidates[i] }
                    found = copied
                    trunc = driverCount > limit
                } else {
                    // Resolve the sparse arrays that need testing, once.
                    let reqSparse = testRequired.map { Array($0.sparseIndex) }
                    let excSparse = testExcluded.map { Array($0.sparseIndex) }
                    for d in 0..<Int(driverCount) {
                        let entity = candidates[d]
                        var matched = true
                        for s in reqSparse where s[Int(entity)] == -1 { matched = false; break }
                        if matched {
                            for s in excSparse where s[Int(entity)] != -1 { matched = false; break }
                        }
                        if !matched { continue }
                        if found < limit { out[Int(found)] = entity; found += 1 }
                        else { trunc = true; break }
                    }
                }
            }
        }

        count = found
        truncated = trunc
        for index in trackedStores.indices { lastVersions[index] = trackedStores[index].structuralVersion }
        rebuildCount += 1
        return true
    }

    public var isCurrent: Bool {
        guard configured else { return false }
        for index in trackedStores.indices where lastVersions[index] != trackedStores[index].structuralVersion {
            return false
        }
        return true
    }

    public func entityAt(_ index: Int32) -> Entity { entities[Int(index)] }

    /// Fast unchecked path: treat the returned buffer as read-only and do not
    /// keep it across `refresh()` or `world.reserveCapacity()`. Valid prefix is
    /// `0..<count`.
    public func withEntities<R>(_ body: (UnsafeBufferPointer<Entity>) -> R) -> R {
        entities.withUnsafeBufferPointer(body)
    }

    public var rebuildCountValue: Int32 { rebuildCount }
    public var resultCapacity: Int32 { Int32(entities.count) }
    public var isTruncated: Bool { truncated }
    public var underlyingView: View { view }

    @discardableResult
    public func validateOwnerAccess(reportErrors: Bool = true) -> Bool { view.validateOwnerAccess(reportErrors: reportErrors) }
}
