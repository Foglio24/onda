import CryptoKit
import Foundation

/// The user's own OpenSubsonic server (Navidrome, Gonic, Airsonic and others), as a source of the
/// original files of songs they have: searched for the song playing, its file streamed as it is
/// (`format=raw`, never transcoded). Set up by the user in Impostazioni › Audio › Lossless: the address
/// (HTTPS only) and the user name in the preferences, the password in the keychain; Seaglass ships no
/// server and no credentials.
enum OpenSubsonicSettings {
    static let serverKey = "lossless.subsonic.server"
    static let userKey = "lossless.subsonic.user"
    /// The keychain item holding the password.
    static let passwordAccount = "lossless.subsonic.password"

    /// The server set up, if any (on the main actor: the keychain is read there).
    @MainActor static var client: OpenSubsonicClient? {
        guard let text = UserDefaults.standard.string(forKey: serverKey), let server = URL(string: text),
              let user = UserDefaults.standard.string(forKey: userKey), !user.isEmpty,
              let password = Keychain.get(passwordAccount), !password.isEmpty else { return nil }
        return OpenSubsonicClient(server: server, username: user, password: password)
    }

    @MainActor static var isConfigured: Bool { client != nil }

    /// Keeps a server; the address must be HTTPS (the password's token travels with each request).
    @MainActor static func save(server: URL, username: String, password: String) {
        UserDefaults.standard.set(server.absoluteString, forKey: serverKey)
        UserDefaults.standard.set(username, forKey: userKey)
        Keychain.set(password, for: passwordAccount)
    }

    @MainActor static func clear() {
        UserDefaults.standard.removeObject(forKey: serverKey)
        UserDefaults.standard.removeObject(forKey: userKey)
        Keychain.set(nil, for: passwordAccount)
    }

    /// "music.example.com" → "https://music.example.com"; nil for anything but an HTTPS address.
    static func serverURL(from text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        guard var components = URLComponents(string: trimmed), components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty else { return nil }
        if components.path.hasSuffix("/") { components.path.removeLast() }
        if components.path.hasSuffix("/rest") { components.path.removeLast(5) }
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

enum OpenSubsonicError: LocalizedError {
    case badResponse
    case failed(String)
    case notHTTPS

    var errorDescription: String? {
        switch self {
        case .badResponse: return String(localized: "Risposta non valida dal server.")
        case .failed(let message): return message
        case .notHTTPS: return String(localized: "Serve un indirizzo HTTPS.")
        }
    }
}

/// A connection to one server. Each request authenticates with a fresh salt and the token
/// MD5(password + salt), as the Subsonic API asks; the password itself never travels.
struct OpenSubsonicClient: Sendable {
    let server: URL
    let username: String
    let password: String

    static let clientName = "Seaglass"
    static let apiVersion = "1.16.1"

    /// No cookies or cache: the server's answers carry tokens, and a song's file is fetched as needed.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// What tells two servers (or two users of one) apart in the caches, without the address itself.
    var scope: String {
        let digest = SHA256.hash(data: Data("\(server.absoluteString)|\(username)".utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    struct ServerInfo: Sendable {
        let type: String?
        let version: String?
        let openSubsonic: Bool
    }

    func ping(timeout: TimeInterval = 8) async throws -> ServerInfo {
        let body = try await call("ping", [], timeout: timeout)
        return ServerInfo(type: body["type"] as? String, version: body["serverVersion"] as? String,
                          openSubsonic: body["openSubsonic"] as? Bool ?? false)
    }

    /// The server's songs that could be the one asked for (lossless or not; the matcher decides).
    func search(_ query: LosslessQuery, timeout: TimeInterval) async throws -> [LosslessCandidate] {
        let title = LosslessMatcher.baseTitle(query.title)
        let artist = LosslessMatcher.splitArtists(query.artists).first ?? ""
        var found: [LosslessCandidate] = []
        for text in ["\(title) \(artist)", title] where !text.trimmingCharacters(in: .whitespaces).isEmpty {
            let body = try await call("search3", [
                URLQueryItem(name: "query", value: text),
                URLQueryItem(name: "songCount", value: "20"),
                URLQueryItem(name: "artistCount", value: "0"),
                URLQueryItem(name: "albumCount", value: "0"),
            ], timeout: timeout)
            let songs = (body["searchResult3"] as? [String: Any])?["song"] as? [[String: Any]] ?? []
            found = songs.compactMap(candidate)
            if !found.isEmpty { break }
        }
        return found
    }

    /// The song's original file, as stored on the server, for playing and for AutoMix's analysis.
    func streamURL(id: String) -> URL? {
        url("stream", [URLQueryItem(name: "id", value: id), URLQueryItem(name: "format", value: "raw")])
    }

    /// The same file through the download endpoint, for keeping it (downloads).
    func downloadURL(id: String) -> URL? {
        url("download", [URLQueryItem(name: "id", value: id)])
    }

    // MARK: Requests

    private func url(_ endpoint: String, _ items: [URLQueryItem], json: Bool = false) -> URL? {
        guard server.scheme?.lowercased() == "https",
              var components = URLComponents(url: server.appending(path: "rest/\(endpoint).view"),
                                             resolvingAgainstBaseURL: false) else { return nil }
        let salt = Self.salt()
        let token = Insecure.MD5.hash(data: Data((password + salt).utf8)).map { String(format: "%02x", $0) }.joined()
        var query = [
            URLQueryItem(name: "u", value: username),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "v", value: Self.apiVersion),
            URLQueryItem(name: "c", value: Self.clientName),
        ]
        if json { query.append(URLQueryItem(name: "f", value: "json")) }
        components.queryItems = query + items
        return components.url
    }

    private func call(_ endpoint: String, _ items: [URLQueryItem], timeout: TimeInterval) async throws -> [String: Any] {
        guard let url = url(endpoint, items, json: true) else { throw OpenSubsonicError.notHTTPS }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = root["subsonic-response"] as? [String: Any] else { throw OpenSubsonicError.badResponse }
        guard body["status"] as? String == "ok" else {
            let message = (body["error"] as? [String: Any])?["message"] as? String
            throw OpenSubsonicError.failed(message ?? String(localized: "Il server ha rifiutato la richiesta."))
        }
        return body
    }

    private static func salt() -> String {
        (0..<12).map { _ in String(format: "%x", Int.random(in: 0..<16)) }.joined()
    }

    /// A song entry as a candidate, its fields read leniently (servers differ in what they send).
    private func candidate(_ song: [String: Any]) -> LosslessCandidate? {
        guard let id = song["id"] as? String, let title = song["title"] as? String else { return nil }
        let suffix = (song["suffix"] as? String)?.lowercased()
        let contentType = (song["contentType"] as? String)?.lowercased() ?? ""
        let bitDepth = Self.int(song["bitDepth"])
        var codec = AudioFormatInfo.Codec(suffix: suffix ?? contentType.components(separatedBy: "/").last ?? "")
        // An .m4a file is ALAC when the server knows a bit depth for it (AAC has none).
        if suffix == "m4a" || contentType == "audio/mp4" { codec = (bitDepth ?? 0) > 0 ? .alac : .aac }
        let format = AudioFormatInfo(codec: codec, sampleRate: Self.int(song["samplingRate"]).map(Double.init),
                                     bitDepth: bitDepth, channels: Self.int(song["channelCount"]),
                                     bitrate: Self.int(song["bitRate"]).map { $0 * 1000 })
        var artists = [song["artist"] as? String].compactMap { $0 }
        if let named = song["artists"] as? [[String: Any]] {
            let names = named.compactMap { $0["name"] as? String }
            if !names.isEmpty { artists = names }
        }
        let isrcs: [String]
        if let list = song["isrc"] as? [String] { isrcs = list } else if let one = song["isrc"] as? String { isrcs = [one] } else { isrcs = [] }
        return LosslessCandidate(source: .openSubsonic, id: id, scope: scope, title: title, artists: artists,
                                 album: song["album"] as? String, duration: Self.int(song["duration"]).map(TimeInterval.init),
                                 isrcs: isrcs, format: format, suffix: suffix)
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? Double { return Int(number) }
        if let text = value as? String { return Int(text) }
        return nil
    }
}
