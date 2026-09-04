import SwiftUI
import Combine
// A declaration-level import, not `import AegisECS`: the module also exports
// a `View` type (the sparse-set query view) that would otherwise collide with
// SwiftUI's in every `: View` / `some View` below. `Inspector` is the only
// AegisECS type this file needs.
import class AegisECS.Inspector

/// The ECS inspector panel, built to match the Godot addon's
/// `ecs_inspector_panel.gd`: the same header, the same collapsible cards in
/// the same order, the same monospaced statistics table, spike attribution
/// with bars, and the diagnostics list — driven off a `PanelSnapshot` taken
/// at a fixed low rate, exactly as the original refreshes.
///
/// **Fully independent of any host app.** The only thing it needs is a
/// reference to an `Inspector` — it owns its own refresh timer and talks to
/// the scheduler directly to toggle systems, so any app or game using
/// `AegisECS` can drop this in with no view model or protocol of its own to
/// write:
///
///     InspectorPanelView(inspector: myInspector)
///
/// Pass `isActive: false` while the panel is off-screen (a closed drawer that
/// stays mounted for its slide animation, a hidden tab). The Godot original
/// does the same with `is_visible_in_tree()`, for the same reason: a hidden
/// panel that keeps refreshing costs exactly as much as an open one.
///
/// Supply `Options.headlineOverride` if the host already renders its own
/// "now" line (fps, frame cost, entity count) elsewhere and wants the panel's
/// top row to match it exactly instead of the generic default.
public struct InspectorPanelView: View {
    public struct Options {
        /// How often the panel re-reads the inspector, in Hz. The inspector's
        /// own `stats`/`diagnostics` refresh at their own (typically slower)
        /// rates regardless of this value; this only controls how often the
        /// view re-renders from whatever is currently available.
        public var refreshHz: Double = 6.0
        /// Overrides the "now" row's text. Receives the same snapshot the
        /// rest of the panel renders from. Leave `nil` for a generic
        /// "<ecs ms> · <fps> · <entities>" line.
        public var headlineOverride: ((PanelSnapshot) -> String)?
        /// Section titles expanded on first render. Matches every section
        /// this view draws by default.
        public var initiallyExpandedSections: Set<String> = [
            "Frame", "Counters", "Systems", "What makes the slow frames slow", "Diagnostics",
        ]
        public init() {}
    }

    private let inspector: Inspector
    private let options: Options
    private let isActive: Bool

    // Palette lifted straight from the GDScript panel.
    static let text = Color(hex: 0xd6dae0)
    static let dim = Color(hex: 0x7a828c)
    static let accent = Color(hex: 0x8ab4f8)
    private static let good = Color(hex: 0x7fd18c)
    private static let warn = Color(hex: 0xe5c07b)
    private static let bad = Color(hex: 0xe08b7b)
    private static let mono = Font.system(size: 12, design: .monospaced)
    static let systemsHeader = "system".padded(24) + "median".leftPadded(9) + "p95".leftPadded(9)
        + "max".leftPadded(9) + "share".leftPadded(8) + "spread".leftPadded(8)

    /// One statistics row, extracted so the compiler type-checks a small view
    /// instead of a monolithic HStack full of format strings.
    struct SystemRowView: View {
        let row: PanelSnapshot.SystemRow
        let canToggle: Bool
        let onToggle: () -> Void

        private var line: String {
            row.name.padded(24)
                + "\(row.medianUsec)".leftPadded(9)
                + "\(row.p95Usec)".leftPadded(9)
                + "\(row.maxUsec)".leftPadded(9)
                + String(format: "%.1f%%", row.sharePercent).leftPadded(8)
                + String(format: "%.1fx", row.volatility).leftPadded(8)
                + (row.enabled ? "" : "  off")
        }

        var body: some View {
            Text(line)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(row.enabled ? InspectorPanelView.text : InspectorPanelView.dim)
                .underline(canToggle, color: InspectorPanelView.accent)
                .contentShape(Rectangle())
                .onTapGesture { if canToggle { onToggle() } }
        }
    }

    @State private var panel = PanelSnapshot()
    @State private var expanded: Set<String>

    /// The tick source lives in `@State`, NOT in a plain `let`. SwiftUI rebuilds
    /// this struct on every update of whatever view contains it — at display
    /// rate in a game — and a publisher built in `init()` would be a fresh
    /// instance each time, so `onReceive` would resubscribe and restart the
    /// interval before it ever elapsed: the panel would never refresh, while the
    /// main run loop churned through a scheduled timer per frame. `@State` keeps
    /// the first one for the life of the view.
    @State private var timer: Publishers.Autoconnect<Timer.TimerPublisher>

    public init(inspector: Inspector, isActive: Bool = true, options: Options = Options()) {
        self.inspector = inspector
        self.isActive = isActive
        self.options = options
        // Allocating a publisher here is free — a TimerPublisher schedules
        // nothing until something subscribes, and only the first one ever is.
        _timer = State(initialValue: Timer.publish(every: 1.0 / max(options.refreshHz, 0.1),
                                                   on: .main, in: .common).autoconnect())
        _expanded = State(initialValue: options.initiallyExpandedSections)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    frameSection
                    countersSection
                    systemsSection
                    spikesSection
                    diagnosticsSection
                    worldSection
                }
                .padding(8)
            }
        }
        .background(Color(hex: 0x0f1017).opacity(0.92))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(hex: 0x33373f), lineWidth: 1))
        .onAppear(perform: refresh)
        .onReceive(timer) { _ in if isActive { refresh() } }
    }

    private func refresh() { panel = PanelSnapshot(from: inspector) }

    private func toggleSystem(_ index: Int) {
        guard panel.canToggleSystems, let scheduler = inspector.getScheduler() else { return }
        scheduler.setSystemEnabled(Int32(index), !scheduler.isSystemEnabled(Int32(index)))
        refresh()
    }

    private var headlineText: String {
        if let override = options.headlineOverride { return override(panel) }
        guard panel.hasData else { return "waiting for data…" }
        let fps = panel.frameWallMs > 0 ? 1000.0 / panel.frameWallMs : 0
        return String(format: "%.2f ms  ·  %.0f fps  ·  %d entities", panel.ecsNowMs, fps, panel.liveEntities)
    }

    private var header: some View {
        HStack {
            Text("AEGIS ECS INSPECTOR").font(.system(size: 12, weight: .semibold)).foregroundStyle(Self.accent)
            Spacer()
            Button("log") { inspector.printReport() }
                .font(.system(size: 11)).buttonStyle(.plain)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color(hex: 0x1b1e26)).clipShape(RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(Self.text)
        }
        .padding(8)
    }

    // MARK: sections

    @ViewBuilder private func card(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        let isOpen = expanded.contains(title)
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if isOpen { expanded.remove(title) } else { expanded.insert(title) }
            } label: {
                Text((isOpen ? "▾ " : "▸ ") + title).font(Self.mono).foregroundStyle(Self.dim)
            }
            .buttonStyle(.plain)
            if isOpen { content() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color(hex: 0x1a1c24).opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var frameSection: some View {
        let p = panel
        return card("Frame") {
            if !p.hasData {
                Text("Waiting for the first captured frame…").font(Self.mono).foregroundStyle(Self.dim)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    line([
                        .dim("now"), .val(headlineText),
                    ])
                    line([.dim("frame"), .val(String(format: "%.2f ms", p.frameWallMs)),
                          .dim("ecs"), .val(String(format: "%.2f ms", p.ecsNowMs)),
                          .dim("(\(p.liveEntities) entities)")])
                    if p.analysed {
                        Text("").font(Self.mono)
                        line([.dim("ECS cost over"), .val("\(p.windowFrames)"), .dim("frames")])
                        line([.dim("  median"), .val(String(format: "%.2f ms", p.frameMedianMs)),
                              .dim("p95"), .col(String(format: "%.2f ms", p.frameP95Ms), p.frameP95OverBudget ? Self.bad : Self.good),
                              .dim("max"), .val(String(format: "%.2f ms", p.frameMaxMs))])
                        let ratioColor = p.spikeRatio >= 2 ? Self.bad : (p.spikeRatio >= 1.5 ? Self.warn : Self.good)
                        line([.dim("  worst is"), .col(String(format: "%.1fx", p.spikeRatio), ratioColor),
                              .dim("the typical frame   \(p.spikeFrameCount) slow frames")])
                        if p.substeps > 1 {
                            Text("  timings cover \(p.substeps) simulation substeps per frame").font(Self.mono).foregroundStyle(Self.dim)
                        }
                    }
                }
            }
        }
    }

    private var countersSection: some View {
        let p = panel
        return Group {
            if !p.counters.isEmpty {
                card("Counters") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(p.counters) { section in
                            Text(section.title).font(Self.mono).foregroundStyle(Self.dim)
                            ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                                line([.plain("  " + row.0.padded(22)), .val(row.1)])
                            }
                        }
                    }
                }
            }
        }
    }

    private var systemsSection: some View {
        let p = panel
        return card("Systems  (window statistics)") {
            if !p.analysed {
                Text("collecting…").font(Self.mono).foregroundStyle(Self.dim)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(Self.systemsHeader).font(Self.mono).foregroundStyle(Self.dim)
                    ForEach(p.systems) { row in
                        SystemRowView(row: row, canToggle: p.canToggleSystems) { toggleSystem(row.id) }
                    }
                    if p.canToggleSystems {
                        Text("").font(Self.mono)
                        Text("tap a system name to switch it off — the fastest way to find")
                            .font(Self.mono).foregroundStyle(Self.dim)
                        Text("out what a system is actually responsible for")
                            .font(Self.mono).foregroundStyle(Self.dim)
                    }
                }
            }
        }
    }

    private var spikesSection: some View {
        let p = panel
        return card("What makes the slow frames slow") {
            if p.slowFramesEven {
                Text("Nothing stands out: the slow frames are slow evenly.")
                    .font(Self.mono).foregroundStyle(Self.dim)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("excess over each system's own median, across the slowest \(p.attributedFrames) frames")
                        .font(Self.mono).foregroundStyle(Self.dim)
                    Text("").font(Self.mono)
                    ForEach(p.spikes) { row in
                        let color = row.excessSharePercent >= 30 ? Self.bad : Self.warn
                        let barLen = min(max(Int(row.excessSharePercent / 5), 0), 20)
                        HStack(spacing: 0) {
                            Text(String(format: "%5.1f%%", row.excessSharePercent)).foregroundStyle(color)
                            Text(" " + row.name.padded(24))
                            Text(String(repeating: "█", count: barLen)).foregroundStyle(color)
                        }.font(Self.mono).foregroundStyle(Self.text)
                        Text("        median \(row.medianUsec) us, peaks at \(row.peakUsec) us")
                            .font(Self.mono).foregroundStyle(Self.dim)
                    }
                }
            }
        }
    }

    private var diagnosticsSection: some View {
        let p = panel
        return card("Diagnostics") {
            if p.findings.isEmpty {
                Text("No issues detected.").font(Self.mono).foregroundStyle(Self.good)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(p.findings) { f in
                        let color = f.severity == 2 ? Self.bad : (f.severity == 1 ? Self.warn : Self.dim)
                        line([.col(f.label, color), .dim(f.source), .plain(f.title)])
                        if !f.detail.isEmpty {
                            Text("    " + f.detail).font(Self.mono).foregroundStyle(Self.dim)
                        }
                        if !f.hint.isEmpty {
                            Text("    → " + f.hint).font(Self.mono).foregroundStyle(Self.accent)
                        }
                    }
                }
            }
        }
    }

    private var worldSection: some View {
        let p = panel
        return card("World and stores") {
            if p.stores.isEmpty {
                Text("no world").font(Self.mono).foregroundStyle(Self.dim)
            } else {
                let loadColor = p.worldLoadPercent >= 90 ? Self.bad : (p.worldLoadPercent >= 75 ? Self.warn : Self.good)
                VStack(alignment: .leading, spacing: 1) {
                    line([.dim("entities"), .val("\(p.worldEntities) / \(p.worldCapacity)"),
                          .col(String(format: "%.0f%% full", p.worldLoadPercent), loadColor)])
                    Text("").font(Self.mono)
                    Text("store".padded(24) + "count".leftPadded(8) + "capacity".leftPadded(10) + "fill".leftPadded(7))
                        .font(Self.mono).foregroundStyle(Self.dim)
                    ForEach(Array(p.stores.enumerated()), id: \.offset) { _, s in
                        let color = s.fillPercent >= 90 ? Self.bad : Self.text
                        Text(String(s.name.prefix(24)).padded(24) + "\(s.count)".leftPadded(8)
                             + "\(s.capacity)".leftPadded(10) + String(format: "%.1f%%", s.fillPercent).leftPadded(7))
                            .font(Self.mono).foregroundStyle(color)
                    }
                }
            }
        }
    }

    // MARK: line builder

    private enum Span { case dim(String), val(String), plain(String), col(String, Color) }
    private func line(_ spans: [Span]) -> some View {
        spans.reduce(Text("")) { acc, span in
            switch span {
            case .dim(let s): return acc + Text(s + " ").foregroundColor(Self.dim)
            case .val(let s): return acc + Text(s + " ").foregroundColor(Self.text)
            case .plain(let s): return acc + Text(s + " ").foregroundColor(Self.text)
            case .col(let s, let c): return acc + Text(s + " ").foregroundColor(c)
            }
        }
        .font(Self.mono)
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: 1)
    }
}

extension String {
    func padded(_ width: Int) -> String { count >= width ? self : self + String(repeating: " ", count: width - count) }
    func leftPadded(_ width: Int) -> String { count >= width ? self : String(repeating: " ", count: width - count) + self }
}
