import Foundation

/// Lifetimes for asynchronous player work. Radio callers share the request for
/// their queue; replacing that queue invalidates every result from the old one.
@MainActor
final class PlaybackRequests {
    private(set) var queueGeneration = UUID()
    private(set) var loadGeneration = UUID()
    private var radio: (id: UUID, generation: UUID, task: Task<Bool, Never>)?

    func replaceQueue() {
        queueGeneration = UUID()
        loadGeneration = UUID()
        radio?.task.cancel()
        radio = nil
    }

    @discardableResult
    func beginLoad() -> UUID {
        loadGeneration = UUID()
        return loadGeneration
    }

    func isCurrentQueue(_ generation: UUID) -> Bool { generation == queueGeneration }
    func isCurrentLoad(_ generation: UUID) -> Bool { generation == loadGeneration }

    func extendQueue(using operation: @escaping @MainActor (UUID) async -> Bool) async -> Bool {
        let generation = queueGeneration
        if let running = radio, running.generation == generation {
            let result = await running.task.value
            return result && isCurrentQueue(generation)
        }
        let id = UUID()
        let task = Task { await operation(generation) }
        radio = (id, generation, task)
        let result = await task.value
        // An old completion must not discard a newer queue's request.
        if radio?.id == id { radio = nil }
        return result && isCurrentQueue(generation)
    }
}

enum PlaybackQueueOrder {
    /// Restore the original order while preserving the number of occurrences of
    /// each song still upcoming. Track IDs identify songs, not queue entries.
    static func restoring<Element, ID: Hashable>(original: [Element], upcoming: [Element],
                                                id: (Element) -> ID) -> [Element] {
        var remaining: [ID: Int] = [:]
        for element in upcoming { remaining[id(element), default: 0] += 1 }
        var restored: [Element] = []
        for element in original where remaining[id(element), default: 0] > 0 {
            restored.append(element)
            remaining[id(element), default: 0] -= 1
        }
        for element in upcoming where remaining[id(element), default: 0] > 0 {
            restored.append(element)
            remaining[id(element), default: 0] -= 1
        }
        return restored
    }

    /// Remove only the requested occurrences, rather than every copy of a song.
    static func removing<Element, ID: Hashable>(_ removed: [Element], from original: [Element],
                                               id: (Element) -> ID) -> [Element] {
        var remaining: [ID: Int] = [:]
        for element in removed { remaining[id(element), default: 0] += 1 }
        return original.filter { element in
            let key = id(element)
            guard remaining[key, default: 0] > 0 else { return true }
            remaining[key, default: 0] -= 1
            return false
        }
    }
}

/// Position requested while streaming, advanced only while audio actually plays.
/// A monotonic clock avoids counting pauses, buffering, or wall-clock changes.
struct StreamingSeekPosition {
    private let requested: TimeInterval
    private var played: TimeInterval = 0
    private var playingSince: TimeInterval?

    init(time: TimeInterval, isPlaying: Bool, now: TimeInterval) {
        requested = time
        playingSince = isPlaying ? now : nil
    }

    mutating func setPlaying(_ playing: Bool, now: TimeInterval) {
        if let start = playingSince { played += max(0, now - start) }
        playingSince = playing ? now : nil
    }

    func position(at now: TimeInterval) -> TimeInterval {
        requested + played + (playingSince.map { max(0, now - $0) } ?? 0)
    }
}
