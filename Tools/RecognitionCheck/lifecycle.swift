import Foundation

@main
struct RecognitionLifecycleCheck {
    private enum Failure: Error { case permission, configure, capture, preparation, network }
    private typealias Operation = RecognitionOperation<Int, String, String>

    @MainActor static func main() async throws {
        await latePermissionCannotRecord()
        await failuresReleaseCapture()
        await cancellingCaptureIsSynchronous()
        await cancellationDuringConfigurationCannotRecord()
        await replacedRunCannotPublish()
        await cleanupPrecedesNetwork()
        print("RecognitionLifecycleCheck: late permission, failures, synchronous stop, configure race, replacement and network cleanup passed")
    }

    @MainActor private static func latePermissionCannotRecord() async {
        var permission: CheckedContinuation<Void, Error>?
        var captures = 0, cleanups = 0
        let operation = Operation(authorize: {
            try await withCheckedThrowingContinuation { permission = $0 }
        }, capture: { check in try check(); captures += 1; return 1 },
            prepare: { String($0) }, match: { _ in "old" },
            cleanup: { cleanups += 1 }, state: { _ in })
        operation.start()
        await until { permission != nil }
        operation.cancel()
        expect(cleanups == 1 && !operation.isRunning, "cancel cleans up before returning")
        permission?.resume()
        permission = nil
        await drain()
        expect(captures == 0 && cleanups == 1, "late microphone permission never starts capture")
    }

    @MainActor private static func failuresReleaseCapture() async {
        for failure in [Failure.permission, .configure, .capture, .preparation, .network] {
            var cleanups = 0, failed = false, resourcesHeld = false
            let operation = Operation(authorize: {
                if case .permission = failure { throw failure }
            }, capture: { check in
                try check()
                resourcesHeld = true
                if case .configure = failure { throw failure }
                if case .capture = failure { throw failure }
                return 1
            }, prepare: { _ in
                if case .preparation = failure { throw failure }
                return "signature"
            }, match: { _ in
                expect(!resourcesHeld, "capture released before matcher starts")
                throw failure
            }, cleanup: { cleanups += 1; resourcesHeld = false }, state: { event in
                if case .failed = event {
                    expect(!resourcesHeld, "failed state never leaves recorder/session held")
                    failed = true
                }
            })
            operation.start()
            await until { failed && !operation.isRunning }
            expect(cleanups == 1 && !resourcesHeld, "every failure cleans capture exactly once")
            operation.cancel()
            expect(cleanups == 1, "closing after failure does not clean another run")
        }
    }

    @MainActor private static func cancellingCaptureIsSynchronous() async {
        var capture: CheckedContinuation<Int, Error>?
        var recorderActive = false, sessionHeld = false
        var cleanups = 0, preparations = 0
        let operation = Operation(authorize: {}, capture: { check in
            try check()
            recorderActive = true
            sessionHeld = true
            return try await withCheckedThrowingContinuation { capture = $0 }
        }, prepare: { _ in preparations += 1; return "signature" }, match: { _ in "result" }, cleanup: {
            cleanups += 1
            recorderActive = false
            sessionHeld = false
            let completion = capture
            capture = nil
            completion?.resume(throwing: CancellationError())
        }, state: { _ in })
        operation.start()
        await until { capture != nil }
        operation.cancel()
        expect(!recorderActive && !sessionHeld && cleanups == 1, "stop releases recorder/session synchronously")
        await drain()
        expect(preparations == 0 && cleanups == 1, "resumed cancellation cannot prepare or clean twice")
    }

    @MainActor private static func cancellationDuringConfigurationCannotRecord() async {
        var operation: Operation?
        var starts = 0, cleanups = 0
        operation = Operation(authorize: {}, capture: { check in
            // A session mutation can synchronously report an interruption. The service invokes
            // this bound check again before it starts the physical recorder.
            operation?.cancel()
            try check()
            starts += 1
            return 1
        }, prepare: { String($0) }, match: { _ in "result" },
            cleanup: { cleanups += 1 }, state: { _ in })
        operation?.start()
        await until { cleanups == 1 }
        await drain()
        expect(starts == 0 && cleanups == 1, "interruption during setup prevents recorder start")
        operation = nil
    }

    @MainActor private static func replacedRunCannotPublish() async {
        var firstResult: CheckedContinuation<String?, Error>?
        var matches = 0, cleanups = 0
        var found: [String] = []
        let operation = Operation(authorize: {}, capture: { check in try check(); return 1 },
            prepare: { String($0) }, match: { _ in
                matches += 1
                if matches == 1 {
                    return try await withCheckedThrowingContinuation { firstResult = $0 }
                }
                return "new"
            }, cleanup: { cleanups += 1 }, state: { event in
                if case .found(let result) = event { found.append(result) }
            })
        operation.start()
        await until { firstResult != nil }
        operation.start()
        await until { found == ["new"] && !operation.isRunning }
        firstResult?.resume(returning: "old")
        firstResult = nil
        await drain()
        expect(found == ["new"] && cleanups == 2, "late result cannot overwrite a replacement run")
    }

    @MainActor private static func cleanupPrecedesNetwork() async {
        var response: CheckedContinuation<String?, Error>?
        var cleanups = 0, resourcesHeld = false
        var results = 0
        let operation = Operation(authorize: {}, capture: { check in
            try check(); resourcesHeld = true; return 1
        }, prepare: { _ in
            expect(resourcesHeld, "sample remains available until fingerprint preparation finishes")
            return "signature"
        }, match: { _ in
            expect(!resourcesHeld && cleanups == 1, "capture cleaned before a slow network request")
            return try await withCheckedThrowingContinuation { response = $0 }
        }, cleanup: { cleanups += 1; resourcesHeld = false }, state: { event in
            if case .found = event { results += 1 }
        })
        operation.start()
        await until { response != nil }
        operation.cancel()
        expect(cleanups == 1, "cancelling a network lookup does not clean capture again")
        response?.resume(returning: "stale")
        response = nil
        await drain()
        expect(results == 0 && cleanups == 1, "cancelled network result is discarded")
    }

    @MainActor private static func until(_ condition: () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        fatalError("Timed out waiting for recognition lifecycle transition")
    }

    private static func drain() async {
        for _ in 0..<30 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(1))
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }
}
