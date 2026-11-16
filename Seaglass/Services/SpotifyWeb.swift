import Foundation

/// Reading the user's own Spotify account (private playlists too, past the 100 songs of a public
/// link) through the web player's own queries ("pathfinder"). The public Web API refuses the web
/// player's token, so this talks to the player's endpoint, with the headers and the query hashes
/// the player itself sends (SpotifySession notes them from its traffic). Seaglass never sees the
/// password: the sign-in happens on Spotify's page. The Windows app does the same (spotify/SpotifyWeb.kt).

struct SpotifyPlaylist: Identifiable, Hashable {
    let uri: String
    let name: String
    let owner: String?
    let imageURL: URL?
    var id: String { uri }
}

/// A song as Spotify describes it: only what is needed to find it on YouTube Music.
struct SpotifySong {
    let title: String
    let artists: [String]
    let album: String?
    let durationSeconds: Double?
}

/// A playlist's songs; nil entries are rows Spotify can't play here (removed, local files, episodes).
struct SpotifyPlaylistContent {
    let name: String?
    let songs: [SpotifySong?]
}

enum SpotifyImportError: LocalizedError {
    case cancelled
    case unavailable
    case sessionExpired
    case noPlaylists

    var errorDescription: String? {
        switch self {
        case .cancelled: return String(localized: "Accesso a Spotify annullato.")
        case .unavailable, .sessionExpired:
            return String(localized: "Spotify non ha risposto correttamente. Riprova più tardi.")
        case .noPlaylists: return String(localized: "Non ci sono playlist nel tuo account Spotify.")
        }
    }
}

/// One GraphQL query of the web player, as seen in its own traffic. The hash names the query on
/// Spotify's side and changes when the player is updated, so it is read from the live page every
/// time instead of being written here.
struct PathfinderOperation {
    let name: String
    let hash: String
    let url: String
    let variables: [String: Any]

    /// What the web player sent: its URL and a body (a POST) or the query in the URL (a GET).
    static func parse(url: String, body: String?) -> PathfinderOperation? {
        var name = "", variables: [String: Any]?, extensions: [String: Any]?
        if let body, let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            name = json["operationName"] as? String ?? ""
            variables = json["variables"] as? [String: Any]
            extensions = json["extensions"] as? [String: Any]
        } else if let components = URLComponents(string: url) {
            func object(_ key: String) -> [String: Any]? {
                components.queryItems?.first { $0.name == key }?.value
                    .flatMap { $0.data(using: .utf8) }
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            }
            name = components.queryItems?.first { $0.name == "operationName" }?.value ?? ""
            variables = object("variables")
            extensions = object("extensions")
        }
        let hash = J.string(J.value(extensions, "persistedQuery", "sha256Hash")) ?? ""
        guard !name.isEmpty, !hash.isEmpty else { return nil }
        return PathfinderOperation(name: name, hash: hash, url: url.components(separatedBy: "?")[0],
                                   variables: variables ?? [:])
    }
}

struct SpotifyHTTPRequest {
    var method: String
    var url: URL
    var headers: [String: String]
    var body: String?
}

struct SpotifyHTTPResponse {
    var status: Int
    var retryAfter: Double?
    var body: String
}

/// How a request reaches Spotify: SpotifySession sends it from inside the signed-in web page, so it
/// is exactly what the player itself would send; a check feeds canned answers instead.
@MainActor
protocol SpotifyTransport: AnyObject {
    func send(_ request: SpotifyHTTPRequest) async throws -> SpotifyHTTPResponse
}

/// Reads the signed-in user's playlists with the queries the web player sent.
@MainActor
final class SpotifyWeb {
    private let transport: SpotifyTransport
    private let headers: [String: String]
    private let library: PathfinderOperation
    private let playlist: PathfinderOperation?

    private static let page = 100
    /// Spotify playlists stop at 10,000 songs; a guard against a loop if a total is wrong.
    private static let maxItems = 10_000

    init(transport: SpotifyTransport, headers: [String: String], library: PathfinderOperation, playlist: PathfinderOperation?) {
        self.transport = transport
        self.headers = headers
        self.library = library
        self.playlist = playlist
    }

    func playlists() async throws -> [SpotifyPlaylist] {
        var found: [SpotifyPlaylist] = []
        var seen = Set<String>()
        var offset = 0
        while true {
            var variables = library.variables
            variables["offset"] = offset
            variables["limit"] = Self.page
            // Playlists inside folders only show up in a flattened list.
            if variables["flatten"] != nil { variables["flatten"] = true }
            let json = try await query(library, variables)
            for item in SpotifyParse.libraryPlaylists(json) where seen.insert(item.uri).inserted { found.append(item) }
            let total = SpotifyParse.libraryTotal(json)
            let items = SpotifyParse.libraryItemCount(json)
            offset += Self.page
            if items == 0 || total == nil || offset >= total! || offset >= Self.maxItems { break }
        }
        return found
    }

    func content(of uri: String) async throws -> SpotifyPlaylistContent {
        guard let operation = playlist else { throw SpotifyImportError.unavailable }
        var songs: [SpotifySong?] = []
        var name: String?
        var offset = 0
        while true {
            var variables = operation.variables
            variables["uri"] = uri
            variables["offset"] = offset
            variables["limit"] = Self.page
            let page = try SpotifyParse.playlistPage(try await query(operation, variables))
            name = name ?? page.name
            songs += page.songs
            offset += Self.page
            if page.songs.isEmpty || offset >= page.total || offset >= Self.maxItems { break }
        }
        return SpotifyPlaylistContent(name: name, songs: songs)
    }

    private func query(_ operation: PathfinderOperation, _ variables: [String: Any]) async throws -> Any {
        let extensions: [String: Any] = ["persistedQuery": ["version": 1, "sha256Hash": operation.hash]]
        func text(_ value: Any) -> String {
            String(decoding: (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
        }
        var request: SpotifyHTTPRequest
        if operation.url.contains("/v1/") {
            // The older endpoint takes the query in the URL.
            var components = URLComponents(string: operation.url)
            components?.queryItems = [URLQueryItem(name: "operationName", value: operation.name),
                                      URLQueryItem(name: "variables", value: text(variables)),
                                      URLQueryItem(name: "extensions", value: text(extensions))]
            guard let url = components?.url else { throw SpotifyImportError.unavailable }
            request = SpotifyHTTPRequest(method: "GET", url: url, headers: headers, body: nil)
        } else {
            guard let url = URL(string: operation.url) else { throw SpotifyImportError.unavailable }
            let body: [String: Any] = ["variables": variables, "operationName": operation.name, "extensions": extensions]
            request = SpotifyHTTPRequest(method: "POST", url: url, headers: headers, body: text(body))
            request.headers["content-type"] = "application/json;charset=UTF-8"
        }
        for attempt in 0..<4 {
            let response = try await transport.send(request)
            switch response.status {
            case 401:
                throw SpotifyImportError.sessionExpired
            case 429 where attempt < 3:
                try await Task.sleep(nanoseconds: UInt64(min(max(response.retryAfter ?? 2, 1), 15) * 1_000_000_000))
            case 200..<300:
                guard let data = response.body.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) else { throw SpotifyImportError.unavailable }
                if !J.array(J.value(json, "errors")).isEmpty, J.value(json, "data") == nil || J.value(json, "data") is NSNull {
                    throw SpotifyImportError.unavailable
                }
                return json
            default:
                throw SpotifyImportError.unavailable
            }
        }
        throw SpotifyImportError.unavailable
    }
}

/// Reading the web player's answers. The shapes follow what the player received when this was
/// written; they are read loosely (by `uri` and `__typename` wherever they sit) so a moved field
/// doesn't break the import.
enum SpotifyParse {
    struct Page {
        let name: String?
        let total: Int
        let songs: [SpotifySong?]
    }

    static func libraryPlaylists(_ json: Any?) -> [SpotifyPlaylist] {
        var found: [SpotifyPlaylist] = []
        var seen = Set<String>()
        J.walk(J.value(json, "data")) { node in
            guard let uri = node["uri"] as? String, uri.hasPrefix("spotify:playlist:"),
                  let name = node["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seen.insert(uri).inserted else { return }
            found.append(SpotifyPlaylist(
                uri: uri,
                name: name,
                owner: J.string(J.value(node, "ownerV2", "data", "name")),
                imageURL: J.string(J.value(node, "images", "items", 0, "sources", 0, "url")).flatMap(URL.init(string:))))
        }
        return found
    }

    static func libraryTotal(_ json: Any?) -> Int? {
        (J.value(json, "data", "me", "libraryV3", "totalCount") as? NSNumber)?.intValue
    }

    static func libraryItemCount(_ json: Any?) -> Int {
        J.array(J.value(json, "data", "me", "libraryV3", "items")).count
    }

    static func playlistPage(_ json: Any?) throws -> Page {
        guard let playlist = J.dict(J.value(json, "data", "playlistV2")) else { throw SpotifyImportError.unavailable }
        let content = J.dict(J.value(playlist, "content"))
        let songs = J.array(content?["items"]).map { item in
            song(J.dict(J.value(item, "itemV2", "data")) ?? J.dict(J.value(item, "item", "data")))
        }
        let total = (content?["totalCount"] as? NSNumber)?.intValue ?? songs.count
        return Page(name: J.string(playlist["name"]), total: total, songs: songs)
    }

    static func song(_ data: [String: Any]?) -> SpotifySong? {
        guard let data else { return nil }
        if let type = data["__typename"] as? String, !type.isEmpty, type != "Track" { return nil }
        let title = (data["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let artists = J.array(J.value(data, "artists", "items")).compactMap { item -> String? in
            guard let name = J.string(J.value(item, "profile", "name")),
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return name
        }
        let milliseconds = (J.value(data, "trackDuration", "totalMilliseconds") as? NSNumber)?.doubleValue
        return SpotifySong(title: title, artists: artists, album: J.string(J.value(data, "albumOfTrack", "name")),
                           durationSeconds: milliseconds.map { $0 / 1000 })
    }
}

extension PlaylistImportSource {
    /// A Spotify playlist as the importer reads it; a song Spotify can't play here is reported, not looked up.
    static func spotify(name: String, content: SpotifyPlaylistContent) -> PlaylistImportSource {
        let rows = content.songs.enumerated().map { index, song -> Row in
            guard let song else {
                return Row(track: Track(videoId: nil, title: String(localized: "Brano non disponibile \(index + 1)"), artists: []),
                           issue: .unavailable)
            }
            return Row(track: Track(videoId: nil, title: song.title, artists: song.artists, album: song.album,
                                    duration: song.durationSeconds))
        }
        let fallback = content.name.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Playlist importata")
        return PlaylistImportSource(name: name.isEmpty ? fallback : name, rows: rows)
    }
}
