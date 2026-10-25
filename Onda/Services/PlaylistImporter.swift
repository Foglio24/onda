import Combine
import Foundation

enum ImportError: LocalizedError {
    case unsupportedLink
    case pageChanged
    case empty
    case nothingMatched
    case busy

    var errorDescription: String? {
        switch self {
        case .unsupportedLink:
            return String(localized: "Link non riconosciuto. Incolla il link di una playlist o di un album di YouTube Music, Spotify o Apple Music.")
        case .pageChanged:
            return String(localized: "Non riesco a leggere la playlist. Controlla che sia pubblica.")
        case .empty:
            return String(localized: "La playlist è vuota.")
        case .nothingMatched:
            return String(localized: "Nessun brano della playlist è stato trovato su YouTube Music.")
        case .busy:
            return String(localized: "C'è già un'importazione in corso.")
        }
    }
}

/// Imports public playlists and albums from YouTube Music, Spotify and Apple Music links.
/// Spotify and Apple Music only give titles and artists: each song is then looked up on YouTube Music.
@MainActor
final class PlaylistImporter: ObservableObject {
    static let shared = PlaylistImporter()

    /// What the import is doing right now, nil when idle.
    @Published private(set) var status: String?

    struct Outcome {
        let playlist: Playlist
        let unmatched: Int
    }

    private enum Source {
        case youTube(String)
        case spotify(kind: String, id: String)
        case appleMusic(URL)
    }

    private struct Page {
        let title: String?
        let tracks: [Track]
    }

    private static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    private init() {}

    func importPlaylist(from text: String) async throws -> Outcome {
        guard status == nil else { throw ImportError.busy }
        status = String(localized: "Lettura della playlist…")
        defer { status = nil }

        switch try await Self.source(from: text) {
        case .youTube(let id):
            let result = try await InnerTube.shared.playlist(id: id)
            let playlist = Library.shared.createPlaylist(named: result.title ?? String(localized: "Playlist importata"),
                                                         tracks: result.tracks)
            return Outcome(playlist: playlist, unmatched: 0)
        case .spotify(let kind, let id):
            return try await finish(try await Self.spotifyPage(kind: kind, id: id), service: "Spotify")
        case .appleMusic(let url):
            return try await finish(try await Self.appleMusicPage(url), service: "Apple Music")
        }
    }

    private func finish(_ page: Page, service: String) async throws -> Outcome {
        guard !page.tracks.isEmpty else { throw ImportError.empty }
        let found = await match(page.tracks).compactMap { $0 }
        guard !found.isEmpty else { throw ImportError.nothingMatched }
        let playlist = Library.shared.createPlaylist(named: page.title ?? String(localized: "Playlist da \(service)"),
                                                     tracks: found)
        return Outcome(playlist: playlist, unmatched: page.tracks.count - found.count)
    }

    /// Looks every song up on YouTube Music, four at a time, keeping the original order.
    private func match(_ tracks: [Track]) async -> [Track?] {
        var results = [Track?](repeating: nil, count: tracks.count)
        var done = 0
        status = String(localized: "Ricerca su YouTube Music: \(done)/\(tracks.count)")
        await withTaskGroup(of: (Int, Track?).self) { group in
            var next = 0
            while next < min(4, tracks.count) {
                let position = next
                let track = tracks[position]
                group.addTask {
                    let match = try? await InnerTube.shared.bestMatch(for: track)
                    return (position, match)
                }
                next += 1
            }
            for await (position, match) in group {
                results[position] = match
                done += 1
                status = String(localized: "Ricerca su YouTube Music: \(done)/\(tracks.count)")
                if next < tracks.count {
                    let upcoming = next
                    let track = tracks[upcoming]
                    group.addTask {
                        let match = try? await InnerTube.shared.bestMatch(for: track)
                        return (upcoming, match)
                    }
                    next += 1
                }
            }
        }
        return results
    }

    // MARK: Links

    private nonisolated static func source(from text: String) async throws -> Source {
        // Shared links often come with text around them ("Ascolta su Spotify: https://…").
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let link = trimmed.range(of: #"https?://\S+"#, options: .regularExpression).map { String(trimmed[$0]) } ?? trimmed

        if link.hasPrefix("spotify:") {
            let parts = link.split(separator: ":")
            if parts.count >= 3, ["playlist", "album"].contains(String(parts[1])) {
                return .spotify(kind: String(parts[1]), id: String(parts[2]))
            }
            throw ImportError.unsupportedLink
        }
        guard var url = URL(string: link), let host = url.host?.lowercased() else {
            if let id = InnerTube.playlistID(from: trimmed) { return .youTube(id) }
            throw ImportError.unsupportedLink
        }

        // Short links (spotify.link, spoti.fi) redirect to open.spotify.com.
        if host.hasSuffix("spotify.link") || host.hasSuffix("spoti.fi") {
            var request = URLRequest(url: url)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            let (_, response) = try await URLSession.shared.data(for: request)
            if let resolved = response.url { url = resolved }
        }

        let finalHost = url.host?.lowercased() ?? host
        if finalHost.hasSuffix("spotify.com") {
            let components = url.pathComponents
            for kind in ["playlist", "album"] {
                if let position = components.firstIndex(of: kind), position + 1 < components.count {
                    return .spotify(kind: kind, id: components[position + 1])
                }
            }
            throw ImportError.unsupportedLink
        }
        if finalHost.hasSuffix("music.apple.com") || finalHost.hasSuffix("itunes.apple.com") {
            return .appleMusic(url)
        }
        if finalHost.contains("youtube.com") || finalHost.contains("youtu.be"),
           let id = InnerTube.playlistID(from: url.absoluteString) {
            return .youTube(id)
        }
        throw ImportError.unsupportedLink
    }

    // MARK: Pages

    /// Spotify's embed page carries the first 100 songs as JSON, no account needed.
    private nonisolated static func spotifyPage(kind: String, id: String) async throws -> Page {
        guard let url = URL(string: "https://open.spotify.com/embed/\(kind)/\(id)") else {
            throw ImportError.unsupportedLink
        }
        let html = try await fetch(url)
        guard let json = scriptJSON(in: html, after: #"id="__NEXT_DATA__""#) else { throw ImportError.pageChanged }
        let entity = J.value(json, "props", "pageProps", "state", "data", "entity")
        let tracks = J.array(J.value(entity, "trackList")).compactMap { item -> Track? in
            guard let title = J.string(J.value(item, "title")) else { return nil }
            let artists = (J.string(J.value(item, "subtitle")) ?? "").components(separatedBy: ", ")
            let milliseconds = J.value(item, "duration") as? Double
            return Track(videoId: nil, title: title, artists: artists,
                         duration: milliseconds.map { $0 / 1000 })
        }
        return Page(title: J.string(J.value(entity, "name")), tracks: tracks)
    }

    /// Apple Music's public page embeds its track list in the "serialized-server-data" script.
    private nonisolated static func appleMusicPage(_ url: URL) async throws -> Page {
        let html = try await fetch(url)
        guard let json = scriptJSON(in: html, after: #"id="serialized-server-data""#) else { throw ImportError.pageChanged }
        var items: [[String: Any]] = []
        J.walk(json) { object in
            if let id = object["id"] as? String, id.hasPrefix("track-lockup"), object["title"] is String {
                items.append(object)
            }
        }
        let tracks = items.compactMap { item -> Track? in
            guard let title = item["title"] as? String else { return nil }
            let artist = item["artistName"] as? String
                ?? J.string(J.value(item, "subtitleLinks", 0, "title")) ?? ""
            let milliseconds = item["duration"] as? Double
            return Track(videoId: nil, title: title, artists: [artist], duration: milliseconds.map { $0 / 1000 })
        }
        let title = scriptJSON(in: html, after: "application/ld+json").flatMap { J.string(J.value($0, "name")) }
        return Page(title: title, tracks: tracks)
    }

    private nonisolated static func fetch(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("it-IT,it;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ImportError.pageChanged }
        return String(decoding: data, as: UTF8.self)
    }

    /// The JSON inside the first `<script …>` tag whose attributes contain `marker`.
    private nonisolated static func scriptJSON(in html: String, after marker: String) -> Any? {
        guard let markerRange = html.range(of: marker),
              let open = html.range(of: ">", range: markerRange.upperBound..<html.endIndex),
              let close = html.range(of: "</script>", range: open.upperBound..<html.endIndex) else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(html[open.upperBound..<close.lowerBound].utf8))
    }
}
