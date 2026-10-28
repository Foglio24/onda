import Combine
import Foundation

enum StartupReason: Sendable {
    case selection, skip, automatic, resume

    var isManualSelection: Bool { self == .selection || self == .skip }
}

enum StartupSource: Sendable {
    case network, resolvedURL, localFile, prepared, preparing
    /// Opus played as it downloads (`OpusStream`): links fetched first, links already known, or
    /// its first seconds prepared (`PreparedPlayback`).
    case opusNetwork, opusResolvedURL, opusPrepared

    var isOpus: Bool { self == .opusNetwork || self == .opusResolvedURL || self == .opusPrepared }
}

/// Local timing only: no song, account, URL or persistent request identifier is recorded.
/// `.playing` measures AVPlayer's state transition, not sound arriving at the speakers; the first
/// audio through the item's audio processing (`firstAudioAfter`), when there is a tap, comes
/// closer (the sound is heard the output's latency later).
@MainActor
final class PlaybackStartupMetrics: ObservableObject {
    static let shared = PlaybackStartupMetrics()

    struct Sample {
        let reason: StartupReason
        let source: StartupSource?
        let resolvedAfter: TimeInterval?
        let readyAfter: TimeInterval?
        let playingAfter: TimeInterval
        /// Opus: its first byte and its first decoded audio.
        var firstByteAfter: TimeInterval?
        var firstDecodedAfter: TimeInterval?
        /// The first audio through the item's audio processing.
        var firstAudioAfter: TimeInterval?
        /// Opus failed and AAC played instead.
        var fellBack = false
        fileprivate var generation: UUID?
        fileprivate var started: TimeInterval = 0
    }

    private struct Attempt {
        let generation: UUID
        let reason: StartupReason
        let started: TimeInterval
        var source: StartupSource?
        var resolvedAfter: TimeInterval?
        var readyAfter: TimeInterval?
        var fellBack = false
    }

    @Published private(set) var samples: [Sample] = []
    private var attempt: Attempt?
    private let now: () -> TimeInterval
    private static let limit = 20

    /// Injectable monotonic clock lets the checks exercise the actual production recorder.
    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    var last: Sample? { samples.last }
    var manualCount: Int { samples.filter { $0.reason.isManualSelection }.count }
    var automaticCount: Int { samples.filter { $0.reason == .automatic }.count }
    var manualMedian: TimeInterval? {
        Self.median(samples.filter { $0.reason.isManualSelection }.map(\.playingAfter))
    }
    var automaticMedian: TimeInterval? {
        Self.median(samples.filter { $0.reason == .automatic }.map(\.playingAfter))
    }

    /// The median start of the chosen songs from each source, with how many there were.
    func manualMedian(for source: StartupSource) -> (median: TimeInterval, count: Int)? {
        let values = samples.filter { $0.reason.isManualSelection && $0.source == source && !$0.fellBack }.map(\.playingAfter)
        return Self.median(values).map { ($0, values.count) }
    }

    func begin(_ generation: UUID, reason: StartupReason = .selection) {
        guard attempt?.generation != generation else { return }
        attempt = Attempt(generation: generation, reason: reason, started: now())
    }

    func resolved(_ generation: UUID, source: StartupSource) {
        guard var current = attempt, current.generation == generation,
              current.resolvedAfter == nil, let elapsed = elapsed(since: current.started) else { return }
        current.source = source
        current.resolvedAfter = elapsed
        attempt = current
    }

    func itemReady(_ generation: UUID) {
        guard var current = attempt, current.generation == generation,
              current.readyAfter == nil, let elapsed = elapsed(since: current.started) else { return }
        current.readyAfter = elapsed
        attempt = current
    }

    func playing(_ generation: UUID) {
        guard let current = attempt, current.generation == generation else { return }
        attempt = nil
        guard let elapsed = elapsed(since: current.started) else { return }
        samples.append(Sample(reason: current.reason, source: current.source,
                              resolvedAfter: current.resolvedAfter, readyAfter: current.readyAfter,
                              playingAfter: elapsed, fellBack: current.fellBack,
                              generation: generation, started: current.started))
        if samples.count > Self.limit { samples.removeFirst(samples.count - Self.limit) }
    }

    /// Opus failed before the song played: AAC plays instead (the start is still timed).
    func fellBack(_ generation: UUID) {
        if attempt?.generation == generation { attempt?.fellBack = true }
        if let index = samples.lastIndex(where: { $0.generation == generation }) { samples[index].fellBack = true }
    }

    /// Moments known only after the start (system uptime): Opus's first byte and first decoded
    /// audio, and the first audio through the audio processing.
    func details(_ generation: UUID, firstByte: TimeInterval?, firstDecoded: TimeInterval?, firstAudio: TimeInterval?) {
        guard let index = samples.lastIndex(where: { $0.generation == generation }) else { return }
        let started = samples[index].started
        func after(_ time: TimeInterval?) -> TimeInterval? {
            guard let time, time >= started, time - started < 120 else { return nil }
            return time - started
        }
        samples[index].firstByteAfter = after(firstByte) ?? samples[index].firstByteAfter
        samples[index].firstDecodedAfter = after(firstDecoded) ?? samples[index].firstDecodedAfter
        samples[index].firstAudioAfter = after(firstAudio) ?? samples[index].firstAudioAfter
    }

    func cancel(_ generation: UUID) {
        if attempt?.generation == generation { attempt = nil }
    }

    func fail(_ generation: UUID) {
        cancel(generation)
    }

    func removeAll() {
        samples = []
    }

    private func elapsed(since started: TimeInterval) -> TimeInterval? {
        let value = now() - started
        return value.isFinite && value >= 0 ? value : nil
    }

    private static func median(_ values: [TimeInterval]) -> TimeInterval? {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
