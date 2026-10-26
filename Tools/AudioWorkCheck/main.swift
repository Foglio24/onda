import Foundation

private actor Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false
    func wait() async {
        if !isOpen { await withCheckedContinuation { continuation = $0 } }
    }
    func open() { isOpen = true; continuation?.resume(); continuation = nil }
}

private actor Counter {
    var starts = 0
    var cancellations = 0
    func started() { starts += 1 }
    func cancelled() { cancellations += 1 }
}

private final class ConcurrentProbe: @unchecked Sendable {
    let conversion = AudioConversionLock()
    var active = 0
    var maximum = 0
    var completed = 0

    func run() {
        conversion.perform {
            active += 1
            maximum = max(maximum, active)
            Thread.sleep(forTimeInterval: 0.005)
            active -= 1
            completed += 1
        }
    }
}

@main
private struct AudioWorkCheck {
    static func expect(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }

    static func main() async throws {
        let files = SharedAudioFiles()
        let gate = Gate()
        let counter = Counter()
        let result = URL(fileURLWithPath: "/tmp/prepared-audio.m4a")
        let first = Task {
            try await files.value(for: "shared") {
                await counter.started()
                await gate.wait()
                try Task.checkCancellation()
                return result
            }
        }
        while await files.waiterCount(for: "shared") != 1 { await Task.yield() }
        let second = Task {
            try await files.value(for: "shared") {
                fatalError("A shared file must have exactly one producer")
            }
        }
        while await files.waiterCount(for: "shared") != 2 { await Task.yield() }
        first.cancel()
        while await files.waiterCount(for: "shared") != 1 { await Task.yield() }
        await gate.open()
        do { _ = try await first.value; fatalError("A cancelled caller must reject the file") }
        catch is CancellationError {}
        expect(try await second.value == result, "Cancelling one caller must preserve the other's preparation")
        expect(await counter.starts == 1, "Only one producer should run")

        let abandoned = Task {
            try await files.value(for: "abandoned") {
                await counter.started()
                do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                catch { await counter.cancelled(); throw error }
                return result
            }
        }
        while await counter.starts < 2 { await Task.yield() }
        abandoned.cancel()
        do { _ = try await abandoned.value; fatalError("An abandoned producer must be cancelled") }
        catch is CancellationError {}
        expect(await counter.cancellations == 1, "Cancelling the final waiter must stop its producer")
        expect(await files.waiterCount(for: "abandoned") == 0, "An abandoned entry must release its lease")

        let probe = ConcurrentProbe()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in probe.run() }
        expect(probe.maximum == 1 && probe.completed == 8, "Audio conversions must be serialized across callers")
        print("Shared audio checks passed (shared cancellation, orphan cancellation, serial conversion).")
    }
}
