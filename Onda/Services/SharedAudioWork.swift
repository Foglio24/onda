import Foundation

/// Share one file preparation without allowing one cancelled caller to cancel another's audio.
actor SharedAudioFiles {
    private struct Work: Sendable {
        let id: UUID
        let task: Task<URL, Error>
        var waiters: Set<UUID>
    }

    private var work: [String: Work] = [:]

    func waiterCount(for key: String) -> Int { work[key]?.waiters.count ?? 0 }

    func value(for key: String, build: @escaping @Sendable () async throws -> URL) async throws -> URL {
        try Task.checkCancellation()
        let waiter = UUID()
        let current: Work
        if var existing = work[key] {
            existing.waiters.insert(waiter)
            work[key] = existing
            current = existing
        } else {
            current = Work(id: UUID(), task: Task.detached(priority: .utility, operation: build), waiters: [waiter])
            work[key] = current
        }
        return try await withTaskCancellationHandler {
            defer { release(key, id: current.id, waiter: waiter, cancelled: false) }
            let file = try await current.task.value
            try Task.checkCancellation()
            return file
        } onCancel: {
            Task { await self.release(key, id: current.id, waiter: waiter, cancelled: true) }
        }
    }

    private func release(_ key: String, id: UUID, waiter: UUID, cancelled: Bool) {
        guard var current = work[key], current.id == id else { return }
        current.waiters.remove(waiter)
        if current.waiters.isEmpty {
            work[key] = nil
            if cancelled { current.task.cancel() }
        } else {
            work[key] = current
        }
    }
}

/// Synchronous decoders run on utility workers. Serialize playback and explicit downloads
/// through the same gate instead of converting several complete songs at once.
final class AudioConversionLock: @unchecked Sendable {
    private let lock = NSLock()

    func perform<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
