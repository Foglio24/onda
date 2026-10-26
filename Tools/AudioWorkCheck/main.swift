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

private final class WorkerProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var began = false
    private var stopped = false
    private var finished = false

    var state: (started: Bool, cancelled: Bool, completed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (began, stopped, finished)
    }

    func convert() throws -> Int {
        lock.lock()
        began = true
        lock.unlock()
        do {
            let limit = ProcessInfo.processInfo.systemUptime + 5
            while ProcessInfo.processInfo.systemUptime < limit {
                try Task.checkCancellation()
                Thread.sleep(forTimeInterval: 0.005)
            }
            lock.lock()
            finished = true
            lock.unlock()
            return 42
        } catch {
            lock.lock()
            stopped = error is CancellationError
            lock.unlock()
            throw error
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

        let workerProbe = WorkerProbe()
        let parent = Task { try await AudioWorker.run { try workerProbe.convert() } }
        while !workerProbe.state.started { await Task.yield() }
        parent.cancel()
        do { _ = try await parent.value; fatalError("A cancelled download must not return a conversion result") }
        catch is CancellationError {}
        expect(workerProbe.state.cancelled && !workerProbe.state.completed,
               "Cancelling the download parent must stop its detached conversion worker before completion")

        let startGate = Gate()
        let neverStarted = WorkerProbe()
        let alreadyCancelled = Task {
            await startGate.wait()
            return try await AudioWorker.run { try neverStarted.convert() }
        }
        alreadyCancelled.cancel()
        await startGate.open()
        do { _ = try await alreadyCancelled.value; fatalError("An already cancelled parent must reject the work") }
        catch is CancellationError {}
        expect(!neverStarted.state.started, "Do not start a worker for an already cancelled download")
        expect(try await AudioWorker.run { 17 } == 17, "A successful worker must return its result unchanged")
        print("Shared audio checks passed (shared cancellation, orphan cancellation, serial conversion, parent-worker cancellation).")
    }
}
