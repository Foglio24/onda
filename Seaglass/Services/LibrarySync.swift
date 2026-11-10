import Foundation

/// What the account keeps of the library: liked songs, playlists (name and songs), the history
/// and the listening preferences. Downloads, playlist covers and Mixes stay on each device.
struct LibrarySnapshot: Codable, Equatable {
    var liked: [Track]
    var playlists: [SyncedPlaylist]
    var history: [Track]
    /// Optional: the snapshots of before preferences were synced have none.
    var preferences: [String: SyncValue]?

    static let empty = LibrarySnapshot(liked: [], playlists: [], history: [], preferences: nil)

    var isEmpty: Bool { liked.isEmpty && playlists.isEmpty && history.isEmpty }
}

struct SyncedPlaylist: Codable, Equatable {
    var id: UUID
    var title: String
    var tracks: [Track]

    private enum CodingKeys: String, CodingKey { case id, title, tracks }

    init(id: UUID, title: String, tracks: [Track]) {
        self.id = id
        self.title = title
        self.tracks = tracks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = UUID(uuidString: try container.decode(String.self, forKey: .id)) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "Not a UUID")
        }
        self.id = id
        title = try container.decode(String.self, forKey: .title)
        tracks = try container.decode([Track].self, forKey: .tracks)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // The service takes lowercase UUIDs.
        try container.encode(id.uuidString.lowercased(), forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(tracks, forKey: .tracks)
    }
}

/// A preference's value as JSON has it.
enum SyncValue: Codable, Equatable {
    case bool(Bool)
    case number(Double)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}

/// Merges the library on this device with the account's, against what the two last agreed on
/// (the base): what one side added is added to the other, what one side removed is removed from
/// the other, and when both changed the same list both changes are kept. Nothing on the device
/// is removed unless it was removed on another device (by its user) since the base.
enum LibraryMerge {
    static func merge(local: LibrarySnapshot, base: LibrarySnapshot?, remote: LibrarySnapshot?) -> LibrarySnapshot {
        guard let remote else { return local }
        // An account whose library emptied all at once is not taken as the user's deletions (a
        // device that lost its library shouldn't empty the others): the two are joined instead.
        let base = remote.isEmpty && base?.isEmpty == false ? nil : base
        return LibrarySnapshot(
            liked: mergeTracks(local: local.liked, base: base?.liked, remote: remote.liked, addedFirst: true),
            playlists: mergePlaylists(local: local.playlists, base: base?.playlists, remote: remote.playlists),
            history: Array(mergeTracks(local: local.history, base: base?.history, remote: remote.history, addedFirst: true)
                .prefix(historyLimit)),
            preferences: mergePreferences(local: local.preferences, base: base?.preferences, remote: remote.preferences)
        )
    }

    static let historyLimit = 200

    /// One song, whatever its metadata: its video, or its Last.fm identity until it has one.
    static func key(_ track: Track) -> String { track.videoId ?? track.id }

    /// A list of songs. `addedFirst`: what the account added goes on top (liked songs and the
    /// history, newest first); otherwise at the end (a playlist's order).
    static func mergeTracks(local: [Track], base: [Track]?, remote: [Track], addedFirst: Bool) -> [Track] {
        guard let base else {
            // Never synced with this account: everything from both.
            var seen = Set(local.map(key))
            return deduplicated(local + remote.filter { seen.insert(key($0)).inserted })
        }
        let localKeys = local.map(key)
        let baseKeys = base.map(key)
        let remoteKeys = remote.map(key)
        if localKeys == baseKeys { return deduplicated(remote) }
        if remoteKeys == baseKeys { return deduplicated(local) }
        let inBase = Set(baseKeys)
        let removedRemotely = inBase.subtracting(remoteKeys)
        let kept = local.filter { !removedRemotely.contains(key($0)) }
        var present = Set(kept.map(key))
        let added = remote.filter { !inBase.contains(key($0)) && present.insert(key($0)).inserted }
        return deduplicated(addedFirst ? added + kept : kept + added)
    }

    static func mergePlaylists(local: [SyncedPlaylist], base: [SyncedPlaylist]?, remote: [SyncedPlaylist]) -> [SyncedPlaylist] {
        let baseByID = Dictionary((base ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let remoteByID = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [SyncedPlaylist] = []
        for playlist in local {
            let before = baseByID[playlist.id]
            if let theirs = remoteByID[playlist.id] {
                result.append(mergePlaylist(local: playlist, base: before, remote: theirs))
            } else if let before, base != nil {
                // Deleted on another device: gone here too, unless it changed here since.
                if !same(playlist, before) { result.append(playlist) }
            } else {
                result.append(playlist)
            }
        }
        let localIDs = Set(local.map(\.id))
        var added: [SyncedPlaylist] = []
        var addedIDs = Set<UUID>()
        for playlist in remote where !localIDs.contains(playlist.id) && addedIDs.insert(playlist.id).inserted {
            // Deleted here: stays deleted, unless another device changed it since.
            if let before = baseByID[playlist.id], same(playlist, before) { continue }
            added.append(playlist)
        }
        return added + result
    }

    private static func mergePlaylist(local: SyncedPlaylist, base: SyncedPlaylist?, remote: SyncedPlaylist) -> SyncedPlaylist {
        var merged = local
        if let base, local.title == base.title { merged.title = remote.title }
        merged.tracks = mergeTracks(local: local.tracks, base: base?.tracks, remote: remote.tracks, addedFirst: false)
        return merged
    }

    private static func same(_ one: SyncedPlaylist, _ other: SyncedPlaylist) -> Bool {
        one.title == other.title && one.tracks.map(key) == other.tracks.map(key)
    }

    /// The account's values on a device that never synced; then each side's changes.
    static func mergePreferences(local: [String: SyncValue]?, base: [String: SyncValue]?,
                                 remote: [String: SyncValue]?) -> [String: SyncValue]? {
        guard let remote else { return local }
        guard let local else { return remote }
        guard let base else { return local.merging(remote) { _, theirs in theirs } }
        var result = remote
        for (key, value) in local where base[key] != value || result[key] == nil { result[key] = value }
        return result
    }

    private static func deduplicated(_ tracks: [Track]) -> [Track] {
        var seen = Set<String>()
        return tracks.filter { seen.insert(key($0)).inserted }
    }
}

/// What the account service accepts (server/account/src/sync.mjs): songs it would refuse are left
/// out of the upload, and stay on the device.
enum SyncLimits {
    static let liked = 10_000
    static let playlists = 1_000
    static let playlistTracks = 10_000
    static let history = 200
    static let bytes = 1_900_000
    static let preferences = 100

    static func uploadable(_ snapshot: LibrarySnapshot) -> LibrarySnapshot {
        LibrarySnapshot(
            liked: Array(snapshot.liked.compactMap(track).prefix(liked)),
            playlists: snapshot.playlists.prefix(playlists).map { playlist in
                let title = String(playlist.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
                return SyncedPlaylist(id: playlist.id, title: title.isEmpty ? "Playlist" : title,
                                      tracks: Array(playlist.tracks.compactMap(track).prefix(playlistTracks)))
            },
            history: Array(snapshot.history.compactMap(track).prefix(history)),
            preferences: snapshot.preferences.map { values in
                Dictionary(uniqueKeysWithValues: values.filter { key, value in
                    key.range(of: #"^[a-zA-Z][a-zA-Z0-9_.-]{0,79}$"#, options: .regularExpression) != nil && {
                        if case .string(let text) = value { return text.count <= 500 }
                        if case .number(let number) = value { return number.isFinite }
                        return true
                    }()
                }.sorted { $0.key < $1.key }.prefix(preferences).map { ($0.key, $0.value) })
            }
        )
    }

    /// The song as the service takes it, or nil when it can't be sent.
    static func track(_ track: Track) -> Track? {
        func text(_ value: String, _ limit: Int) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= limit
        }
        guard text(track.id, 255), text(track.title, 500), text(track.artist, 500), track.primaryArtist.count <= 255 else { return nil }
        if let videoId = track.videoId, videoId.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) == nil { return nil }
        var result = track
        if let album = track.album, album.count > 500 { result.album = nil }
        if let duration = track.duration, !(duration.isFinite && duration >= 0 && duration <= 86_400) { result.duration = nil }
        if let url = track.artworkURL, url.scheme != "https" || url.absoluteString.count > 2048 { result.artworkURL = nil }
        if let ids = track.sourceIDs {
            let valid = Array(ids.filter { $0.count <= 255 }.prefix(32))
            result.sourceIDs = valid.isEmpty ? nil : valid
        }
        if (track.artistID?.count ?? 0) > 255 { result.artistID = nil }
        if (track.albumID?.count ?? 0) > 255 { result.albumID = nil }
        if (track.podcastID?.count ?? 0) > 255 { result.podcastID = nil }
        return result
    }
}
