import Foundation

/// Owns one explicitly requested recognition run. Capture cleanup is synchronous and happens
/// exactly once, including when permission or a platform callback returns after cancellation.
@MainActor
final class RecognitionOperation<Input, Signature, Output> {
    enum Event {
        case idle, requestingPermission, listening, matching
        case found(Output), noMatch, failed(Error)
    }

    private let authorize: @MainActor () async throws -> Void
    private let capture: @MainActor (_ check: @escaping @MainActor () throws -> Void) async throws -> Input
    private let prepare: @MainActor (Input) async throws -> Signature
    private let match: @MainActor (Signature) async throws -> Output?
    private let cleanup: @MainActor () -> Void
    private let state: @MainActor (Event) -> Void
    private var run: UUID?
    private var task: Task<Void, Never>?
    private var needsCleanup = false

    var isRunning: Bool { run != nil }

    init(authorize: @escaping @MainActor () async throws -> Void,
         capture: @escaping @MainActor (_ check: @escaping @MainActor () throws -> Void) async throws -> Input,
         prepare: @escaping @MainActor (Input) async throws -> Signature,
         match: @escaping @MainActor (Signature) async throws -> Output?,
         cleanup: @escaping @MainActor () -> Void,
         state: @escaping @MainActor (Event) -> Void) {
        self.authorize = authorize
        self.capture = capture
        self.prepare = prepare
        self.match = match
        self.cleanup = cleanup
        self.state = state
    }

    func start() {
        cancel()
        let identity = UUID()
        run = identity
        needsCleanup = true
        state(.requestingPermission)
        guard run == identity else { return }
        task = Task { [weak self] in
            guard let self else { return }
            await self.perform(identity)
        }
    }

    func cancel() {
        // Invalidate callbacks before cleanup, which can resume a suspended capture continuation.
        run = nil
        task?.cancel()
        task = nil
        cleanupIfNeeded()
        state(.idle)
    }

    private func perform(_ identity: UUID) async {
        defer {
            if run == identity {
                cleanupIfNeeded()
                if run == identity {
                    run = nil
                    task = nil
                }
            }
        }
        do {
            try check(identity)
            try await authorize()
            try check(identity)
            state(.listening)
            try check(identity)
            let input = try await capture { try self.check(identity) }
            try check(identity)
            let signature = try await prepare(input)
            try check(identity)
            // The microphone, temporary sample and playback reservation belong to capture, not
            // the network lookup. Release them before the matcher can wait on a remote service.
            cleanupIfNeeded()
            try check(identity)
            state(.matching)
            try check(identity)
            let result = try await match(signature)
            try check(identity)
            if let result { state(.found(result)) }
            else { state(.noMatch) }
        } catch is CancellationError {
            if run == identity {
                cleanupIfNeeded()
                if run == identity { state(.idle) }
            }
        } catch {
            if run == identity {
                cleanupIfNeeded()
                if run == identity { state(.failed(error)) }
            }
        }
    }

    private func check(_ identity: UUID) throws {
        try Task.checkCancellation()
        guard run == identity else { throw CancellationError() }
    }

    private func cleanupIfNeeded() {
        guard needsCleanup else { return }
        // Cleanup can synchronously invoke cancel again through an audio lifecycle notification.
        needsCleanup = false
        cleanup()
    }
}
