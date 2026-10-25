import Combine
import CryptoKit
import Foundation

enum LastFMError: LocalizedError {
    case missingCredentials
    case badResponse
    case emptyHistory
    case api(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return String(localized: "Inserisci API key e shared secret di Last.fm nelle impostazioni.")
        case .badResponse:
            return String(localized: "Risposta non valida da Last.fm.")
        case .emptyHistory:
            return String(localized: "Su Last.fm non ci sono ancora abbastanza ascolti per creare un mix.")
        case .api(14, _):
            return String(localized: "Autorizzazione non completata: nella pagina di Last.fm tocca \"Yes, allow access\" e riprova.")
        case .api(let code, let message):
            return "Last.fm (\(code)): \(message)"
        }
    }
}

/// Last.fm account, scrobbling and recommendations.
/// API docs: https://www.last.fm/api — every user brings their own API key and secret.
@MainActor
final class LastFM: ObservableObject {
    static let shared = LastFM()

    @Published private(set) var apiKey: String
    @Published private(set) var username: String?
    @Published private(set) var pendingCount = 0
    @Published var scrobblingEnabled: Bool {
        didSet { UserDefaults.standard.set(scrobblingEnabled, forKey: Keys.scrobbling) }
    }

    var hasCredentials: Bool { !apiKey.isEmpty && !apiSecret.isEmpty }
    var isConnected: Bool { sessionKey != nil && username != nil }
    private var canScrobble: Bool { scrobblingEnabled && isConnected }

    private var apiSecret: String
    private var sessionKey: String?
    private var pendingToken: String?
    private var pending: [PendingScrobble]
    private var isFlushing = false
    private let endpoint = URL(string: "https://ws.audioscrobbler.com/2.0/")!

    private enum Keys {
        static let apiKey = "lastfm.apiKey"
        static let apiSecret = "lastfm.apiSecret"
        static let session = "lastfm.session"
        static let username = "lastfm.username"
        static let scrobbling = "lastfm.scrobbling"
        static let pending = "lastfm.pending"
    }

    /// Scrobbles waiting to be sent, kept across launches so offline listening still counts.
    private struct PendingScrobble: Codable {
        let artist: String
        let track: String
        let album: String?
        let duration: Int?
        let timestamp: Int
    }

    private init() {
        let defaults = UserDefaults.standard
        apiKey = defaults.string(forKey: Keys.apiKey) ?? ""
        apiSecret = Keychain.get(Keys.apiSecret) ?? ""
        sessionKey = Keychain.get(Keys.session)
        username = defaults.string(forKey: Keys.username)
        scrobblingEnabled = defaults.object(forKey: Keys.scrobbling) as? Bool ?? true
        pending = defaults.data(forKey: Keys.pending)
            .flatMap { try? JSONDecoder().decode([PendingScrobble].self, from: $0) } ?? []
        pendingCount = pending.count
    }

    // MARK: Account

    func saveCredentials(key: String, secret: String) {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if key != apiKey || secret != apiSecret { signOut() }
        apiSecret = secret
        Keychain.set(secret, for: Keys.apiSecret)
        UserDefaults.standard.set(key, forKey: Keys.apiKey)
        apiKey = key
    }

    /// Step 1 of the desktop auth flow: returns the page where the user grants access.
    func beginAuth() async throws -> URL {
        let json = try await call("auth.getToken", signed: true)
        guard let token = json["token"] as? String else { throw LastFMError.badResponse }
        pendingToken = token
        return URL(string: "https://www.last.fm/api/auth/?api_key=\(apiKey)&token=\(token)")!
    }

    /// Step 2: once the user has allowed access, trade the token for a session key.
    func completeAuth() async throws {
        guard let token = pendingToken else { return }
        pendingToken = nil
        let json = try await call("auth.getSession", params: ["token": token], signed: true)
        guard let key = J.string(J.value(json, "session", "key")),
              let name = J.string(J.value(json, "session", "name")) else { throw LastFMError.badResponse }
        sessionKey = key
        Keychain.set(key, for: Keys.session)
        UserDefaults.standard.set(name, forKey: Keys.username)
        username = name
        await flushPending()
    }

    func signOut() {
        sessionKey = nil
        Keychain.set(nil, for: Keys.session)
        UserDefaults.standard.removeObject(forKey: Keys.username)
        username = nil
    }

    // MARK: Scrobbling

    func updateNowPlaying(_ track: Track) async {
        guard canScrobble, let sessionKey else { return }
        var params = ["artist": artistName(track), "track": track.title, "sk": sessionKey]
        if let album = track.album { params["album"] = album }
        if let duration = track.duration { params["duration"] = String(Int(duration)) }
        _ = try? await call("track.updateNowPlaying", params: params, signed: true, post: true)
    }

    func scrobble(_ track: Track, startedAt: Date) async {
        guard canScrobble else { return }
        pending.append(PendingScrobble(artist: artistName(track), track: track.title, album: track.album,
                                       duration: track.duration.map { Int($0) },
                                       timestamp: Int(startedAt.timeIntervalSince1970)))
        savePending()
        await flushPending()
    }

    /// Sends queued scrobbles in batches of 50 (the API limit).
    func flushPending() async {
        guard canScrobble, let sessionKey, !pending.isEmpty, !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }

        flush: while !pending.isEmpty {
            let batch = Array(pending.prefix(50))
            var params = ["sk": sessionKey]
            for (i, item) in batch.enumerated() {
                params["artist[\(i)]"] = item.artist
                params["track[\(i)]"] = item.track
                params["timestamp[\(i)]"] = String(item.timestamp)
                if let album = item.album { params["album[\(i)]"] = album }
                if let duration = item.duration { params["duration[\(i)]"] = String(duration) }
            }
            do {
                _ = try await call("track.scrobble", params: params, signed: true, post: true)
                pending.removeFirst(batch.count)
            } catch LastFMError.api(let code, _) where ![9, 11, 16, 29].contains(code) {
                // Rejected for good (bad data): drop it instead of retrying forever.
                pending.removeFirst(batch.count)
            } catch {
                break flush // offline, rate limited or session problem: retry later
            }
        }
        savePending()
    }

    func love(_ track: Track, loved: Bool) async {
        guard isConnected, let sessionKey else { return }
        _ = try? await call(loved ? "track.love" : "track.unlove",
                            params: ["artist": artistName(track), "track": track.title, "sk": sessionKey],
                            signed: true, post: true)
    }

    // MARK: Discovery

    func topTracks(period: String, limit: Int) async throws -> [Track] {
        guard let username else { return [] }
        let json = try await call("user.getTopTracks",
                                  params: ["user": username, "period": period, "limit": String(limit)])
        return J.array(J.value(json, "toptracks", "track")).compactMap(Self.parseTrack).uniqued()
    }

    func similarTracks(to track: Track, limit: Int) async throws -> [Track] {
        let json = try await call("track.getSimilar", params: [
            "artist": artistName(track),
            "track": track.title,
            "limit": String(limit),
            "autocorrect": "1",
        ])
        return J.array(J.value(json, "similartracks", "track")).compactMap(Self.parseTrack)
    }

    /// Songs similar to a few recent favourites, mixed with some of the favourites themselves.
    func tasteMix() async throws -> [Track] {
        let favourites = try await topTracks(period: "3month", limit: 25)
        guard !favourites.isEmpty else { throw LastFMError.emptyHistory }
        var pool = Array(favourites.shuffled().prefix(6))
        for seed in favourites.shuffled().prefix(4) {
            pool += (try? await similarTracks(to: seed, limit: 10)) ?? []
        }
        return pool.shuffled().uniqued()
    }

    /// The most played songs of the last year, shuffled.
    func rediscoverMix() async throws -> [Track] {
        let tracks = try await topTracks(period: "12month", limit: 50)
        guard !tracks.isEmpty else { throw LastFMError.emptyHistory }
        return tracks.shuffled()
    }

    // MARK: Plumbing

    private func call(_ method: String, params: [String: String] = [:], signed: Bool = false,
                      post: Bool = false) async throws -> [String: Any] {
        guard !apiKey.isEmpty, !signed || !apiSecret.isEmpty else { throw LastFMError.missingCredentials }
        var all = params
        all["method"] = method
        all["api_key"] = apiKey
        if signed { all["api_sig"] = signature(for: all) }
        all["format"] = "json"
        let body = all.map { "\($0.key)=\(Self.encode($0.value))" }.joined(separator: "&")

        var request: URLRequest
        if post {
            request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.utf8)
        } else {
            request = URLRequest(url: URL(string: "\(endpoint.absoluteString)?\(body)")!)
        }
        request.setValue("Onda/1.0 (iOS)", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LastFMError.badResponse
        }
        if let code = json["error"] as? Int {
            if code == 9 { signOut() } // session revoked from the Last.fm website
            throw LastFMError.api(code, json["message"] as? String ?? String(localized: "errore sconosciuto"))
        }
        return json
    }

    /// md5 of the parameters sorted by name, concatenated as name+value, followed by the secret.
    private func signature(for params: [String: String]) -> String {
        let base = params.keys.sorted().map { $0 + (params[$0] ?? "") }.joined() + apiSecret
        return Insecure.MD5.hash(data: Data(base.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func artistName(_ track: Track) -> String {
        track.primaryArtist.isEmpty ? track.artist : track.primaryArtist
    }

    private func savePending() {
        UserDefaults.standard.set(try? JSONEncoder().encode(pending), forKey: Keys.pending)
        pendingCount = pending.count
    }

    private static let unreserved = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    nonisolated private static func parseTrack(_ value: Any) -> Track? {
        guard let name = J.string(J.value(value, "name")) else { return nil }
        let artist = J.string(J.value(value, "artist", "name"))
            ?? J.string(J.value(value, "artist", "#text")) ?? ""
        return Track(videoId: nil, title: name, artists: [artist])
    }
}
