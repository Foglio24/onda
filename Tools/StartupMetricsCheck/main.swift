import Foundation

@main
struct StartupMetricsCheck {
    @MainActor
    static func main() {
        var clock: TimeInterval = 100
        let metrics = PlaybackStartupMetrics(now: { clock })
        var count = 0
        func expect(_ condition: @autoclosure () -> Bool, _ description: String) {
            count += 1
            guard condition() else {
                fputs("FAIL: \(description)\n", stderr)
                exit(1)
            }
        }
        let first = UUID()
        metrics.begin(first)
        clock = 100.25
        metrics.resolved(first, source: .network)
        clock = 100.5
        metrics.itemReady(first)
        clock = 101
        metrics.playing(first)
        expect(metrics.last?.resolvedAfter == 0.25, "Resolution uses the injected monotonic clock")
        expect(metrics.last?.readyAfter == 0.5, "Item readiness is recorded separately")
        expect(metrics.last?.playingAfter == 1, "First playing measures the complete startup")
        expect(metrics.last?.source == .network, "The source contains no song information")
        metrics.playing(first)
        metrics.resolved(first, source: .prepared)
        expect(metrics.samples.count == 1 && metrics.last?.source == .network, "Repeated callbacks cannot record another start")

        let cancelled = UUID()
        metrics.begin(cancelled)
        metrics.cancel(cancelled)
        metrics.playing(cancelled)
        let failed = UUID()
        metrics.begin(failed)
        metrics.fail(failed)
        metrics.playing(failed)
        expect(metrics.samples.count == 1, "Cancelled and failed attempts do not enter statistics")

        let stale = UUID()
        let selected = UUID()
        metrics.begin(stale)
        metrics.begin(selected, reason: .skip)
        metrics.cancel(stale)
        metrics.resolved(stale, source: .localFile)
        metrics.playing(stale)
        clock = 104
        metrics.resolved(selected, source: .prepared)
        metrics.playing(selected)
        expect(metrics.samples.count == 2 && metrics.last?.reason == .skip, "Stale generations do not affect a newer selection")
        expect(metrics.manualMedian == 2, "An even manual median averages its two middle values")

        let automatic = UUID()
        metrics.begin(automatic, reason: .automatic)
        clock = 204
        metrics.playing(automatic)
        let resume = UUID()
        metrics.begin(resume, reason: .resume)
        clock = 404
        metrics.playing(resume)
        expect(metrics.manualCount == 2 && metrics.manualMedian == 2, "Automatic changes and resumes do not dilute manual latency")
        expect(metrics.automaticCount == 1 && metrics.automaticMedian == 100, "Automatic changes have separate statistics")

        let duplicateBegin = UUID()
        metrics.begin(duplicateBegin)
        clock = 405
        metrics.begin(duplicateBegin)
        clock = 406
        metrics.playing(duplicateBegin)
        expect(metrics.last?.playingAfter == 2, "A repeated begin does not reset an in-progress clock")
        expect(metrics.manualMedian == 2, "The odd manual median uses its middle value")

        let invalid = UUID()
        metrics.begin(invalid)
        clock = 405
        metrics.playing(invalid)
        expect(metrics.samples.count == 5, "A clock regression does not produce a negative sample")

        for _ in 0..<25 {
            let next = UUID()
            metrics.begin(next)
            clock += 0.5
            metrics.playing(next)
        }
        expect(metrics.samples.count == 20, "Only twenty completed attempts are retained")
        expect(metrics.manualCount == 20 && metrics.manualMedian == 0.5, "Statistics reflect only retained samples")
        metrics.removeAll()
        expect(metrics.samples.isEmpty && metrics.manualMedian == nil, "Clearing removes local statistics")
        print("StartupMetricsCheck: \(count) checks passed")
    }
}
