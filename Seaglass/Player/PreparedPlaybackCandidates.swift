import Foundation

/// Selection for the single speculative player, independent of AVFoundation.
/// Queue intent outranks visible rows; starting playback retains only its selection.
struct PreparedPlaybackCandidates {
    private struct Offer {
        let videoID: String
        let priority: Int
        let order: UInt64
    }

    private var visible: [UUID: Offer] = [:]
    private var order: UInt64 = 0
    private var upcoming: String?
    private var selected: String?
    private var suspended = false

    var visibleTokens: Set<UUID> { Set(visible.keys) }

    mutating func offerVisible(_ videoID: String, token: UUID, priority: Int) {
        order &+= 1
        visible[token] = Offer(videoID: videoID, priority: priority, order: order)
        if visible.count > 32, let oldest = visible.min(by: { $0.value.order < $1.value.order })?.key {
            visible[oldest] = nil
        }
    }

    mutating func releaseVisible(_ token: UUID) { visible[token] = nil }
    mutating func offerUpcoming(_ videoID: String?) { upcoming = videoID }

    mutating func suspend(keeping videoID: String?) {
        suspended = true
        selected = videoID
        upcoming = nil
    }

    mutating func resume() { suspended = false }

    var preferredVideoID: String? {
        guard !suspended else { return nil }
        if let upcoming, upcoming != selected { return upcoming }
        return visible.values.filter { $0.videoID != selected }.max {
            $0.priority == $1.priority ? $0.order < $1.order : $0.priority < $1.priority
        }?.videoID
    }

    func shouldKeep(_ videoID: String) -> Bool {
        suspended ? videoID == selected : videoID == preferredVideoID
    }
}
