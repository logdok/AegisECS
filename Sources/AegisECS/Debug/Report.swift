import Foundation

/// Plain-text rendering of a window, for the "log" action and headless runs.
/// A trimmed port of `EcsReport` — the JSON/CSV writers are omitted; the client
/// renders the live panel itself.
public enum Report {
    private static func pad(_ s: String, _ width: Int, right: Bool = false) -> String {
        if s.count >= abs(width) { return s }
        let fill = String(repeating: " ", count: abs(width) - s.count)
        return right ? fill + s : s + fill
    }

    public static func text(recorder: FrameRecorder, stats: FrameStats, world: World?, findings: [Diagnostics.Finding]) -> String {
        var out = "=== Aegis ECS report ===\n"
        out += "window: \(recorder.frameCount) frames, \(recorder.framesSeenCount) seen\n"
        if stats.isAnalysed {
            out += String(format: "frame  median %.2f ms   p95 %.2f ms   max %.2f ms   worst %.1fx\n",
                          stats.frameMedianUsec() / 1000, stats.frameP95Usec() / 1000,
                          stats.frameMaxUsec() / 1000, stats.spikeRatio())
            out += pad("system", 26) + pad("median", 10, right: true) + pad("p95", 10, right: true)
                + pad("max", 10, right: true) + pad("share", 8, right: true) + pad("spread", 8, right: true) + "\n"
            for i in 0..<stats.systemCount {
                out += pad(recorder.systemName(i), 26)
                    + pad("\(Int(stats.systemMedianUsec(i)))", 10, right: true)
                    + pad("\(Int(stats.systemP95Usec(i)))", 10, right: true)
                    + pad("\(Int(stats.systemMaxUsec(i)))", 10, right: true)
                    + pad(String(format: "%.1f%%", stats.systemSharePercent(i)), 8, right: true)
                    + pad(String(format: "%.1fx", stats.systemVolatility(i)), 8, right: true) + "\n"
            }
            if stats.totalExcessUsec() > 0 {
                out += "\nslow-frame excess, worst first:\n"
                for rank in 0..<stats.spikeContributorCount() {
                    let i = stats.spikeContributor(rank)
                    if stats.systemExcessUsec(i) <= 0 { break }
                    out += "  " + pad(String(format: "%.1f%%", stats.systemExcessShare(i)), 6, right: true)
                        + "  " + pad(recorder.systemName(i), 24)
                        + "  median \(Int(stats.systemMedianUsec(i))) us, peaks \(Int(stats.systemMaxUsec(i))) us\n"
                }
            }
        }
        if let world {
            out += String(format: "\nworld  entities %d / %d  (%.0f%% full)\n",
                          Int(world.getLiveCount()), Int(world.capacity), world.getLoadFactor() * 100)
        }
        if !findings.isEmpty {
            out += "\ndiagnostics:\n"
            for f in findings { out += f.formatted() + "\n" }
        }
        return out
    }
}
