import Foundation

/// Account-owned offline scrobbles. This is independent of networking so account switches and
/// responses arriving after sign-out can be checked without sending real listening history.
@MainActor
final class ScrobbleOutbox {
    struct Item: Codable, Equatable, Sendable {
        let id: UUID
        let artist: String
        let track: String
        let album: String?
        let duration: Int?
        let timestamp: Int

        init(artist: String, track: String, album: String?, duration: Int?, timestamp: Int) {
            id = UUID()
            self.artist = artist
            self.track = track
            self.album = album
            self.duration = duration
            self.timestamp = timestamp
        }

        private enum CodingKeys: String, CodingKey { case id, artist, track, album, duration, timestamp }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            // The old global queue had no IDs. Assign them once during migration.
            id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            artist = try values.decode(String.self, forKey: .artist)
            track = try values.decode(String.self, forKey: .track)
            album = try values.decodeIfPresent(String.self, forKey: .album)
            duration = try values.decodeIfPresent(Int.self, forKey: .duration)
            timestamp = try values.decode(Int.self, forKey: .timestamp)
        }
    }

    struct Session: Equatable, Sendable {
        let owner: String
        let key: String
        // A fresh login with the same key is still a different authorization lifetime.
        let generation = UUID()
    }

    enum Delivery: Sendable {
        case accepted
        case rejected
        case retry
    }

    private struct Archive: Codable {
        var accounts: [String: [Item]] = [:]
        // Preserve unowned legacy data, but never attach it to the next person who signs in.
        var unattributedLegacy: [Item] = []
    }

    private var archive: Archive
    private var isFlushing = false
    private(set) var session: Session?
    var isEnabled = true
    var onChange: (() -> Void)?

    init(data: Data? = nil, legacyData: Data? = nil, legacyOwner: String? = nil) {
        if let data, let saved = try? JSONDecoder().decode(Archive.self, from: data) {
            archive = saved
        } else {
            archive = Archive()
            let legacy = legacyData.flatMap { try? JSONDecoder().decode([Item].self, from: $0) } ?? []
            if let owner = legacyOwner.flatMap(Self.ownerKey), !legacy.isEmpty {
                archive.accounts[owner] = legacy
            } else {
                archive.unattributedLegacy = legacy
            }
        }
    }

    var pendingCount: Int {
        session.map { pending(for: $0.owner).count } ?? 0
    }

    var unattributedLegacyCount: Int { archive.unattributedLegacy.count }

    func pending(for owner: String) -> [Item] {
        guard let key = Self.ownerKey(owner) else { return [] }
        return archive.accounts[key] ?? []
    }

    func connect(username: String, key: String) {
        guard let owner = Self.ownerKey(username), !key.isEmpty else {
            disconnect()
            return
        }
        session = Session(owner: owner, key: key)
        onChange?()
    }

    func disconnect() {
        session = nil
        onChange?()
    }

    func append(_ item: Item) {
        guard isEnabled, let session else { return }
        archive.accounts[session.owner, default: []].append(item)
        onChange?()
    }

    func encoded() throws -> Data { try JSONEncoder().encode(archive) }

    /// Acknowledgements remove only the captured owner's exact entries. Concurrent additions,
    /// another account's queue and a replacement login are never removed by an old response.
    func flush(send: (Session, [Item]) async -> Delivery) async {
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }

        while isEnabled, let sendingSession = session {
            let batch = Array(pending(for: sendingSession.owner).prefix(50))
            guard !batch.isEmpty else { return }
            let result = await send(sendingSession, batch)
            switch result {
            case .accepted, .rejected:
                let acknowledged = Set(batch.map(\.id))
                archive.accounts[sendingSession.owner]?.removeAll { acknowledged.contains($0.id) }
                onChange?()
            case .retry:
                // A new account may have requested a flush while this request was suspended.
                // Keep going with its session; never retry the old account with a new key.
                if session == sendingSession { return }
            }
        }
    }

    private nonisolated static func ownerKey(_ username: String) -> String? {
        let key = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return key.isEmpty ? nil : key
    }
}
