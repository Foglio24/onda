import Foundation

@MainActor
private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}

/// Exercises the same Foundation helpers used by PlayerController, with network
/// requests suspended explicitly so queue replacement races are deterministic.
@main
private struct PlaybackCheck {
    @MainActor private static var checks = 0

    @MainActor
    private static func expect(_ condition: Bool, _ message: String, line: UInt = #line) {
        guard condition else { fatalError("PlaybackCheck line \(line): \(message)") }
        checks += 1
    }

    @MainActor
    static func main() async {
        let original = ["B", "B", "C"]
        expect(PlaybackQueueOrder.restoring(original: original, upcoming: ["C", "B", "B"], id: { $0 })
               == original, "shuffle must retain repeated queue entries")
        let removed = PlaybackQueueOrder.removing(["B"], from: original, id: { $0 })
        expect(removed == ["B", "C"], "deleting one duplicate must retain the other")
        expect(PlaybackQueueOrder.restoring(original: removed, upcoming: ["C", "B"], id: { $0 })
               == ["B", "C"], "remaining duplicates must still restore their order")
        expect(PlaybackQueueOrder.restoring(original: ["B"], upcoming: ["C", "B", "B", "C"], id: { $0 })
               == ["B", "C", "B", "C"], "new entries and extra copies must survive restoration")
        expect(PlaybackQueueOrder.restoring(original: ["B", "B", "C"], upcoming: ["C"], id: { $0 })
               == ["C"], "consumed entries must not return")

        var seek = StreamingSeekPosition(time: 60, isPlaying: true, now: 0)
        seek.setPlaying(false, now: 1)
        seek.setPlaying(true, now: 11)
        expect(seek.position(at: 12) == 62, "a ten-second pause must not advance the requested seek")
        seek.setPlaying(false, now: 12)
        seek.setPlaying(true, now: 32)
        expect(seek.position(at: 33) == 63, "buffering must not advance the requested seek")
        seek.setPlaying(true, now: 34)
        expect(seek.position(at: 35) == 65, "repeated playing notifications must not lose elapsed audio")
        let pausedSeek = StreamingSeekPosition(time: 20, isPlaying: false, now: 100)
        expect(pausedSeek.position(at: 200) == 20, "a seek made while paused must remain fixed")

        let requests = PlaybackRequests()
        let oldLoad = requests.beginLoad()
        expect(requests.isCurrentLoad(oldLoad), "the current load must accept its own result")
        let newLoad = requests.beginLoad()
        expect(!requests.isCurrentLoad(oldLoad) && requests.isCurrentLoad(newLoad),
               "loading another song at the same index must invalidate retry and advance results")
        let oldQueue = requests.queueGeneration
        requests.replaceQueue()
        expect(!requests.isCurrentQueue(oldQueue) && !requests.isCurrentLoad(newLoad),
               "replacing a queue must invalidate old queue and load work")

        var calls = 0
        var appended: [String] = []
        let gate = Gate()
        let first = Task { @MainActor in
            await requests.extendQueue { generation in
                calls += 1
                await gate.wait()
                guard requests.isCurrentQueue(generation) else { return false }
                appended.append("radio")
                return true
            }
        }
        while !gate.isWaiting { await Task.yield() }
        var joined = false
        let advance = Task { @MainActor in
            joined = true
            return await requests.extendQueue { _ in
                calls += 1
                return false
            }
        }
        while !joined { await Task.yield() }
        expect(calls == 1, "advance must join a radio request already in flight")
        gate.open()
        expect(await first.value, "the original radio caller must observe success")
        expect(await advance.value, "advance must await and observe the shared radio success")
        expect(calls == 1 && appended == ["radio"], "a shared request must append its results once")

        let staleGate = Gate()
        let stale = Task { @MainActor in
            await requests.extendQueue { generation in
                calls += 1
                await staleGate.wait()
                guard requests.isCurrentQueue(generation), !Task.isCancelled else { return false }
                appended.append("stale")
                return true
            }
        }
        while !staleGate.isWaiting { await Task.yield() }
        requests.replaceQueue()
        let freshGate = Gate()
        let fresh = Task { @MainActor in
            await requests.extendQueue { generation in
                calls += 1
                await freshGate.wait()
                guard requests.isCurrentQueue(generation) else { return false }
                appended.append("fresh")
                return true
            }
        }
        while !freshGate.isWaiting { await Task.yield() }
        staleGate.open()
        expect(!(await stale.value), "the old queue's request must be rejected")
        expect(!appended.contains("stale"), "an old radio response must not contaminate the new queue")
        var freshJoined = false
        let freshWaiter = Task { @MainActor in
            freshJoined = true
            return await requests.extendQueue { _ in
                calls += 1
                return false
            }
        }
        while !freshJoined { await Task.yield() }
        expect(calls == 3, "an old completion must not clear the newer in-flight request")
        freshGate.open()
        expect(await fresh.value, "the new queue's request must succeed")
        expect(await freshWaiter.value, "the new queue's waiter must share that success")
        expect(appended == ["radio", "fresh"], "only the active queue may receive recommendations")
        print("Playback checks passed: \(checks)")
    }
}
