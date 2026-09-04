import Foundation
import AegisECS

/// A plain value copy of everything the inspector panel draws, taken at
/// panel-refresh rate. `InspectorPanelView` renders purely from this — it
/// never reaches into the live recorder/world, so it can update on its own
/// slow schedule the way the Godot addon's `ecs_inspector_panel.gd` does.
///
/// Built entirely from an `Inspector`, nothing else — no host app type is
/// referenced here, so this snapshot (and the view that renders it) works
/// the same in any app that has an `Inspector` to point at.
public struct PanelSnapshot: Sendable {
    public struct SystemRow: Sendable, Identifiable {
        public let id: Int
        public let name: String
        public let medianUsec: Int
        public let p95Usec: Int
        public let maxUsec: Int
        public let sharePercent: Float
        public let volatility: Float
        public let enabled: Bool
    }
    public struct SpikeRow: Sendable, Identifiable {
        public let id: Int
        public let name: String
        public let excessSharePercent: Float
        public let medianUsec: Int
        public let peakUsec: Int
    }
    public struct CounterSection: Sendable, Identifiable {
        public let id: Int
        public let title: String
        public let rows: [(String, String)]
    }
    public struct Finding: Sendable, Identifiable {
        public let id: Int
        public let severity: Int   // 0 info, 1 warning, 2 critical
        public let label: String
        public let source: String
        public let title: String
        public let detail: String
        public let hint: String
    }

    // Frame section
    public var hasData = false
    public var frameWallMs: Double = 0
    public var ecsNowMs: Double = 0
    public var liveEntities: Int = 0
    public var analysed = false
    public var windowFrames = 0
    public var frameMedianMs: Double = 0
    public var frameP95Ms: Double = 0
    public var frameMaxMs: Double = 0
    public var frameP95OverBudget = false
    public var spikeRatio: Float = 0
    public var spikeFrameCount = 0
    public var substeps = 1

    public var counters: [CounterSection] = []
    public var systems: [SystemRow] = []
    public var spikes: [SpikeRow] = []
    public var slowFramesEven = true
    public var attributedFrames = 0
    public var findings: [Finding] = []

    // World section
    public var worldEntities = 0
    public var worldCapacity = 0
    public var worldLoadPercent: Float = 0
    public var stores: [(name: String, count: Int, capacity: Int, fillPercent: Float)] = []

    public var canToggleSystems = false

    public init() {}

    public init(from inspector: Inspector) {
        let recorder = inspector.recorder
        let stats = inspector.stats
        canToggleSystems = inspector.mode == .dev
        guard recorder.isConfigured, recorder.frameCount > 0 else { return }
        hasData = true

        let newest = recorder.newestSlot
        frameWallMs = Double(recorder.frameWallUsec(newest)) / 1000
        ecsNowMs = Double(recorder.frameTotalUsec(newest)) / 1000
        liveEntities = Int(recorder.frameLiveCount(newest))
        substeps = Int(recorder.frameSubstepsCount(newest))

        counters = (0..<inspector.counterSectionCount).map {
            CounterSection(id: $0, title: inspector.counterSectionTitle($0), rows: inspector.counterSectionRows($0))
        }

        let budget = inspector.diagnostics.frameBudgetUsec
        if stats.isAnalysed {
            analysed = true
            windowFrames = stats.frameCount
            frameMedianMs = Double(stats.frameMedianUsec()) / 1000
            frameP95Ms = Double(stats.frameP95Usec()) / 1000
            frameMaxMs = Double(stats.frameMaxUsec()) / 1000
            frameP95OverBudget = stats.frameP95Usec() > budget
            spikeRatio = stats.spikeRatio()
            spikeFrameCount = stats.spikeFrameCount()

            systems = (0..<stats.systemCount).map { i in
                SystemRow(id: i, name: recorder.systemName(i),
                          medianUsec: Int(stats.systemMedianUsec(i)),
                          p95Usec: Int(stats.systemP95Usec(i)),
                          maxUsec: Int(stats.systemMaxUsec(i)),
                          sharePercent: stats.systemSharePercent(i),
                          volatility: stats.systemVolatility(i),
                          enabled: inspector.getScheduler()?.isSystemEnabled(Int32(i)) ?? true)
            }

            if stats.totalExcessUsec() > 0 {
                slowFramesEven = false
                attributedFrames = stats.attributedFrameCount()
                var rows: [SpikeRow] = []
                for rank in 0..<stats.spikeContributorCount() {
                    let i = stats.spikeContributor(rank)
                    if stats.systemExcessUsec(i) <= 0 || rows.count >= 5 { break }
                    rows.append(SpikeRow(id: i, name: recorder.systemName(i),
                                         excessSharePercent: stats.systemExcessShare(i),
                                         medianUsec: Int(stats.systemMedianUsec(i)),
                                         peakUsec: Int(stats.systemMaxUsec(i))))
                }
                spikes = rows
            }
        }

        findings = inspector.getFindings().enumerated().map { idx, f in
            Finding(id: idx, severity: f.severity.rawValue, label: f.severity.label,
                    source: f.source, title: f.title, detail: f.detail, hint: f.hint)
        }

        if let world = inspector.getWorld() {
            worldEntities = Int(world.getLiveCount())
            worldCapacity = Int(world.capacity)
            worldLoadPercent = world.getLoadFactor() * 100
            stores = (0..<world.storeCount).compactMap { i in
                guard let store = world.getStore(at: i) else { return nil }
                let cap = max(Int(store.capacity), 1)
                return (store.getDebugName(), Int(store.count), cap, Float(store.count) / Float(cap) * 100)
            }
        }
    }
}
