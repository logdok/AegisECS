import Foundation

/// A non-materialised intersection of stores, with no allocation per frame.
/// Port of `EcsView`.
///
/// `configure` is the cold operation. Each frame `refreshDriver()` picks the
/// smallest required sparse set, and `matches` performs direct membership tests
/// without building an iterator or a result array.
///
/// **In the hottest systems, do not use `matches` at all.** It is a call per
/// candidate. Take the resolved sparse arrays once and inline the test into
/// your own loop.
public final class View {
    private weak var world: World?
    private weak var ownerSystem: System?
    private var required: [ComponentStore] = []
    private var excluded: [ComponentStore] = []
    private var driver: ComponentStore?
    private var driverIndex: Int32 = -1
    private var configured = false

    public init() {}

    @discardableResult
    public func configure(world: World, required requiredTypes: [Int32], excluded excludedTypes: [Int32] = [], ownerSystem: System? = nil) -> Bool {
        required.removeAll(); excluded.removeAll()
        driver = nil; driverIndex = -1; configured = false
        self.world = world
        self.ownerSystem = ownerSystem
        if requiredTypes.isEmpty {
            AegisDiagnostics.report("View: a world and at least one required type are mandatory")
            return false
        }
        for typeID in requiredTypes {
            guard let store = world.getStore(typeID) else {
                AegisDiagnostics.report("View: required type \(typeID) is not registered")
                return false
            }
            if required.contains(where: { $0 === store }) {
                AegisDiagnostics.report("View: required type \(typeID) listed twice")
                return false
            }
            required.append(store)
        }
        for typeID in excludedTypes {
            guard let store = world.getStore(typeID) else {
                AegisDiagnostics.report("View: excluded type \(typeID) is not registered")
                return false
            }
            if required.contains(where: { $0 === store }) {
                AegisDiagnostics.report("View: type \(typeID) is both required and excluded")
                return false
            }
            if excluded.contains(where: { $0 === store }) {
                AegisDiagnostics.report("View: excluded type \(typeID) listed twice")
                return false
            }
            excluded.append(store)
        }
        configured = true
        refreshDriver()
        return true
    }

    /// Picks the smallest required store. No allocation, no materialisation.
    public func refreshDriver() {
        guard configured else { return }
        driver = required[0]
        driverIndex = 0
        for index in 1..<required.count where required[index].count < driver!.count {
            driver = required[index]
            driverIndex = Int32(index)
        }
    }

    public func matches(_ entity: Entity) -> Bool {
        for store in required where store.sparseIndex[Int(entity)] == -1 { return false }
        for store in excluded where store.sparseIndex[Int(entity)] != -1 { return false }
        return true
    }

    public var candidateStore: ComponentStore? { driver }
    public var candidateCount: Int32 { driver?.count ?? 0 }

    /// Index, within the required list, of the store `refreshDriver()` chose.
    public var driverRequiredIndex: Int32 { driverIndex }

    public var requiredCount: Int32 { Int32(required.count) }
    public func requiredStore(_ index: Int32) -> ComponentStore? {
        (index >= 0 && index < Int32(required.count)) ? required[Int(index)] : nil
    }
    /// Sparse array of a required store — so a system can inline the membership
    /// test into its own loop.
    public func requiredSparse(_ index: Int32) -> [Int32]? {
        requiredStore(index).map { Array($0.sparseIndex) }
    }

    public var excludedCount: Int32 { Int32(excluded.count) }
    public func excludedStore(_ index: Int32) -> ComponentStore? {
        (index >= 0 && index < Int32(excluded.count)) ? excluded[Int(index)] : nil
    }
    public func excludedSparse(_ index: Int32) -> [Int32]? {
        excludedStore(index).map { Array($0.sparseIndex) }
    }

    public var isConfigured: Bool { configured }

    /// Metadata check only; no effect on execution.
    @discardableResult
    public func validateOwnerAccess(reportErrors: Bool = true) -> Bool {
        guard let owner = ownerSystem else { return true }
        if !owner.accessMetadataComplete {
            if reportErrors { AegisDiagnostics.report("View: system \(owner.systemName) did not finish describing its access") }
            return false
        }
        var valid = true
        for store in required where !owner.hasDeclaredAccess(store.typeID) {
            valid = false
            if reportErrors { AegisDiagnostics.report("View: system \(owner.systemName) did not declare access to type \(store.typeID)") }
        }
        for store in excluded where !owner.hasDeclaredAccess(store.typeID) {
            valid = false
            if reportErrors { AegisDiagnostics.report("View: system \(owner.systemName) did not declare access to excluded type \(store.typeID)") }
        }
        return valid
    }

    // Internal accessors for Query, which shares the resolved store lists.
    func requiredStoreRef(_ index: Int) -> ComponentStore { required[index] }
    func excludedStoreRef(_ index: Int) -> ComponentStore { excluded[index] }
}
