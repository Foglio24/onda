import Foundation

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure(description: message) }
}

@MainActor
func item(_ title: String) -> ScrobbleOutbox.Item {
    ScrobbleOutbox.Item(artist: "Test Artist", track: title, album: nil, duration: 180, timestamp: 1_700_000_000)
}

/// Holds the first real outbox send across an actor suspension while the caller switches account.
@MainActor
final class FakeTransport {
    var requests: [(ScrobbleOutbox.Session, [ScrobbleOutbox.Item])] = []
    var firstResponse: CheckedContinuation<ScrobbleOutbox.Delivery, Never>?

    func send(_ session: ScrobbleOutbox.Session, _ items: [ScrobbleOutbox.Item]) async -> ScrobbleOutbox.Delivery {
        requests.append((session, items))
        if requests.count == 1 {
            return await withCheckedContinuation { firstResponse = $0 }
        }
        return .retry
    }
}

@MainActor
func runChecks() async throws {
    let legacy = Data("""
        [{"artist":"Test Artist","track":"Legacy","timestamp":1700000000}]
        """.utf8)

    let migrated = ScrobbleOutbox(legacyData: legacy, legacyOwner: " Alice ")
    migrated.connect(username: "ALICE", key: "session-a")
    try expect(migrated.pendingCount == 1, "Migrate legacy listens to the persisted owner, case-insensitively")
    try expect(migrated.pending(for: "bob").isEmpty, "Legacy migration must not populate another account")
    let restored = ScrobbleOutbox(data: try migrated.encoded(), legacyData: legacy, legacyOwner: "bob")
    try expect(restored.pending(for: "alice") == migrated.pending(for: "alice"), "Persist IDs and ownership across launches")
    try expect(restored.pending(for: "bob").isEmpty, "Do not migrate legacy data a second time")

    let unowned = ScrobbleOutbox(legacyData: legacy)
    unowned.connect(username: "bob", key: "session-b")
    var unownedSends = 0
    await unowned.flush { _, _ in unownedSends += 1; return .accepted }
    try expect(unownedSends == 0 && unowned.pendingCount == 0, "Never send unowned legacy data to a new account")
    try expect(unowned.unattributedLegacyCount == 1, "Preserve unowned legacy data in quarantine")
    let restoredUnowned = ScrobbleOutbox(data: try unowned.encoded())
    try expect(restoredUnowned.unattributedLegacyCount == 1, "Persist the legacy quarantine")

    let isolated = ScrobbleOutbox()
    isolated.connect(username: "alice", key: "session-a")
    isolated.append(item("A"))
    isolated.disconnect()
    try expect(isolated.pendingCount == 0, "Signed-out UI must not show another account's pending count")
    isolated.connect(username: "bob", key: "session-b")
    isolated.append(item("B"))
    await isolated.flush { session, batch in
        try! expect(session.owner == "bob" && batch.map(\.track) == ["B"], "Only send the active owner's queue")
        return .accepted
    }
    try expect(isolated.pending(for: "alice").map(\.track) == ["A"], "Flushing B must preserve A's offline history")
    isolated.connect(username: "alice", key: "session-a-new")
    try expect(isolated.pendingCount == 1, "Restore offline listens when their owner reconnects")

    let batching = ScrobbleOutbox()
    batching.connect(username: "alice", key: "session-a")
    for index in 0..<121 { batching.append(item("Track \(index)")) }
    var batchSizes: [Int] = []
    await batching.flush { _, batch in batchSizes.append(batch.count); return .accepted }
    try expect(batchSizes == [50, 50, 21] && batching.pendingCount == 0, "Respect Last.fm's 50-entry batch limit")
    batching.append(item("Retry"))
    await batching.flush { _, _ in .retry }
    try expect(batching.pendingCount == 1, "Keep the batch after a transient error")
    await batching.flush { _, _ in .rejected }
    try expect(batching.pendingCount == 0, "Remove a permanently rejected batch")
    batching.isEnabled = false
    batching.append(item("Disabled"))
    try expect(batching.pendingCount == 0, "Disabled scrobbling must not enqueue history")

    // 52 queued on A; while its first 50 are awaiting a response, connect B and enqueue its song.
    let switching = ScrobbleOutbox()
    switching.connect(username: "alice", key: "session-a")
    for index in 0..<52 { switching.append(item("A \(index)")) }
    let transport = FakeTransport()
    let flushing = Task { await switching.flush { await transport.send($0, $1) } }
    while transport.firstResponse == nil { await Task.yield() }
    let oldSession = transport.requests[0].0
    switching.disconnect()
    switching.connect(username: "bob", key: "session-b")
    switching.append(item("B preserved"))
    try expect(switching.session != oldSession, "An old response cannot invalidate B's current session")
    // A simultaneous request must not start a second drain of the same queue.
    var duplicateSends = 0
    await switching.flush { _, _ in duplicateSends += 1; return .accepted }
    transport.firstResponse?.resume(returning: .accepted)
    await flushing.value
    try expect(duplicateSends == 0, "Only one flush can send at a time")
    try expect(transport.requests.map { $0.0.owner } == ["alice", "bob"], "Never send A's second batch using its old session after account switch")
    try expect(transport.requests[1].1.map(\.track) == ["B preserved"], "A's acknowledgement must not remove B's queued data")
    try expect(switching.pending(for: "alice").count == 2, "Acknowledge exactly the completed batch belonging to A")
    try expect(switching.pendingCount == 1, "A transient error on B must retain B's queue")

    // Sign-out alone must stop the drain, even when the in-flight request succeeds.
    let signingOut = ScrobbleOutbox()
    signingOut.connect(username: "alice", key: "same-key")
    for index in 0..<51 { signingOut.append(item("A \(index)")) }
    let signingOutTransport = FakeTransport()
    let signingOutFlush = Task { await signingOut.flush { await signingOutTransport.send($0, $1) } }
    while signingOutTransport.firstResponse == nil { await Task.yield() }
    let oldLogin = signingOut.session
    signingOut.disconnect()
    signingOutTransport.firstResponse?.resume(returning: .accepted)
    await signingOutFlush.value
    try expect(signingOutTransport.requests.count == 1, "Do not send another batch after sign-out")
    try expect(signingOut.pending(for: "alice").count == 1, "Keep unsent history after sign-out")
    signingOut.connect(username: "alice", key: "same-key")
    try expect(signingOut.session != oldLogin, "A replacement login with the same key must invalidate old request identity")
}

do {
    try await runChecks()
    print("Scrobble outbox checks passed (migration, ownership, batching, retries, account switches, sign-out).")
} catch {
    fputs("Scrobble outbox check failed: \(error)\n", stderr)
    exit(1)
}
