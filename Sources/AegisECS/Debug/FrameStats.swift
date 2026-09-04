import Foundation

/// Turns a window of recorded frames into answers. Port of `EcsFrameStats`.
///
/// One frame's numbers are noise. What is worth looking at is the distribution
/// — the typical cost, the one most frames stay under, the worst case — and
/// above all **which system is responsible for the spikes**.
///
/// That last question a live readout cannot answer: for each slow frame the
/// excess over the system's OWN median is charged to that system, and the
/// totals are ranked. A system that is simply expensive every frame contributes
/// nothing here; one that occasionally explodes contributes everything.
///
/// `analyse()` is a cold operation — it sorts the window per system. Call it
/// when you are about to read the results, not every frame.
public final class FrameStats {
    /// A frame counts as a spike when it costs this many times the median.
    public var spikeFactor: Float = 1.5
    /// The percentile reported as "what most frames stay under".
    public var highPercentile: Float = 0.95

    private var systemCountValue = 0
    private var frameCountValue = 0

    private var avg: [Float] = []
    private var median: [Float] = []
    private var high: [Float] = []
    private var maxV: [Float] = []
    private var share: [Float] = []
    private var excess: [Float] = []
    private var executedFrames: [Int32] = []
    private var ranking: [Int] = []

    private var frameAvg: Float = 0
    private var frameMedian: Float = 0
    private var frameHigh: Float = 0
    private var frameMax: Float = 0
    private var frameMin: Float = 0
    private var worstSlot = -1
    private var spikeCount = 0
    private var attributedFrames = 0
    private var totalExcess: Float = 0

    private var liveMinV = 0
    private var liveMaxV = 0
    private var capacityChanges = 0
    private var peakPending = 0
    private var analysed = false

    public init() {}

    /// Recomputes every aggregate over the recorder's current window. Returns
    /// false when there is nothing to analyse yet.
    @discardableResult
    public func analyse(_ recorder: FrameRecorder) -> Bool {
        analysed = false
        guard recorder.isConfigured else { return false }
        frameCountValue = recorder.frameCount
        systemCountValue = recorder.systemCount
        guard frameCountValue > 0, systemCountValue > 0 else { return false }

        avg = Array(repeating: 0, count: systemCountValue)
        median = Array(repeating: 0, count: systemCountValue)
        high = Array(repeating: 0, count: systemCountValue)
        maxV = Array(repeating: 0, count: systemCountValue)
        share = Array(repeating: 0, count: systemCountValue)
        excess = Array(repeating: 0, count: systemCountValue)
        executedFrames = Array(repeating: 0, count: systemCountValue)

        let ringCapacity = recorder.frameCapacity
        let oldest = recorder.oldestSlot
        let slots = (0..<frameCountValue).map { (oldest + $0) % ringCapacity }
        var scratch = [Float](repeating: 0, count: frameCountValue)
        let stride = systemCountValue
        let executedStatus = FrameRecorder.Status.executed.rawValue

        // --- per-frame distribution -----------------------------------------
        var frameSum: Float = 0
        frameMax = -1
        frameMin = .infinity
        worstSlot = -1
        liveMinV = Int(Int32.max)
        liveMaxV = 0
        capacityChanges = 0
        peakPending = 0
        var previousCapacity: Int32 = -1

        for index in 0..<frameCountValue {
            let slot = slots[index]
            let total = recorder.frameTotalUsec(slot)
            scratch[index] = total
            frameSum += total
            if total > frameMax { frameMax = total; worstSlot = slot }
            if total < frameMin { frameMin = total }
            let live = Int(recorder.frameLiveCount(slot))
            liveMinV = min(liveMinV, live)
            liveMaxV = max(liveMaxV, live)
            peakPending = max(peakPending, Int(recorder.framePendingDestroy(slot)))
            let capacityNow = recorder.frameWorldCapacity(slot)
            if previousCapacity != -1 && capacityNow != previousCapacity { capacityChanges += 1 }
            previousCapacity = capacityNow
        }

        frameAvg = frameSum / Float(frameCountValue)
        scratch.sort()
        frameMedian = percentile(scratch, 0.5)
        frameHigh = percentile(scratch, highPercentile)
        if frameMin == .infinity { frameMin = 0 }

        // --- per-system distribution ---------------------------------------
        recorder.withTimings { timings in
            recorder.withStatuses { statuses in
                for system in 0..<systemCountValue {
                    var sum: Float = 0
                    var peak: Float = 0
                    var executed: Int32 = 0
                    for index in 0..<frameCountValue {
                        let cell = slots[index] * stride + system
                        let value = timings[cell]
                        scratch[index] = value
                        sum += value
                        if value > peak { peak = value }
                        if statuses[cell] == executedStatus { executed += 1 }
                    }
                    avg[system] = sum / Float(frameCountValue)
                    maxV[system] = peak
                    executedFrames[system] = executed
                    share[system] = frameSum > 0 ? sum / frameSum * 100 : 0
                    scratch.sort()
                    median[system] = percentile(scratch, 0.5)
                    high[system] = percentile(scratch, highPercentile)
                }

                // --- spike attribution -----------------------------------
                let tailThreshold = frameHigh
                let spikeThreshold = frameMedian * spikeFactor
                spikeCount = 0
                totalExcess = 0
                attributedFrames = 0
                for index in 0..<frameCountValue {
                    let slot = slots[index]
                    let total = recorder.frameTotalUsec(slot)
                    if total > spikeThreshold { spikeCount += 1 }
                    if total < tailThreshold { continue }
                    attributedFrames += 1
                    let base = slot * stride
                    for system in 0..<systemCountValue {
                        let over = timings[base + system] - median[system]
                        if over > 0 { excess[system] += over; totalExcess += over }
                    }
                }
            }
        }

        ranking = Array(0..<systemCountValue)
        // Insertion sort by excess, descending, stable — keeps registration
        // order on ties.
        for i in 1..<max(ranking.count, 1) {
            let current = ranking[i]
            let value = excess[current]
            var j = i - 1
            while j >= 0 && excess[ranking[j]] < value {
                ranking[j + 1] = ranking[j]
                j -= 1
            }
            ranking[j + 1] = current
        }

        analysed = true
        return true
    }

    public var isAnalysed: Bool { analysed }
    public var frameCount: Int { frameCountValue }
    public var systemCount: Int { systemCountValue }

    public func frameAverageUsec() -> Float { frameAvg }
    public func frameMedianUsec() -> Float { frameMedian }
    public func frameP95Usec() -> Float { frameHigh }
    public func frameMaxUsec() -> Float { frameMax }
    public func frameMinUsec() -> Float { frameMin }
    public func worstFrameSlot() -> Int { worstSlot }
    public func spikeFrameCount() -> Int { spikeCount }
    public func spikeFramePercent() -> Float { frameCountValue > 0 ? Float(spikeCount) / Float(frameCountValue) * 100 : 0 }
    public func spikeRatio() -> Float { frameMedian > 0 ? frameMax / frameMedian : 0 }

    public func systemAverageUsec(_ i: Int) -> Float { avg[i] }
    public func systemMedianUsec(_ i: Int) -> Float { median[i] }
    public func systemP95Usec(_ i: Int) -> Float { high[i] }
    public func systemMaxUsec(_ i: Int) -> Float { maxV[i] }
    public func systemSharePercent(_ i: Int) -> Float { share[i] }
    public func systemExecutedFrames(_ i: Int) -> Int32 { executedFrames[i] }
    public func systemVolatility(_ i: Int) -> Float { maxV[i] / max(median[i], 1) }
    public func systemExcessUsec(_ i: Int) -> Float { excess[i] }
    public func systemExcessShare(_ i: Int) -> Float { totalExcess > 0 ? excess[i] / totalExcess * 100 : 0 }
    public func totalExcessUsec() -> Float { totalExcess }
    public func attributedFrameCount() -> Int { attributedFrames }

    public func spikeContributorCount() -> Int { ranking.count }
    public func spikeContributor(_ rank: Int) -> Int { ranking[rank] }

    public func liveMin() -> Int { liveMinV }
    public func liveMax() -> Int { liveMaxV }
    public func capacityChangeCount() -> Int { capacityChanges }
    public func peakPendingDestroy() -> Int { peakPending }

    private func percentile(_ sorted: [Float], _ quantile: Float) -> Float {
        guard !sorted.isEmpty else { return 0 }
        let index = min(max(Int(Float(sorted.count) * quantile), 0), sorted.count - 1)
        return sorted[index]
    }
}
