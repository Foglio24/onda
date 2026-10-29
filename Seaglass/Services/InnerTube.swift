import Foundation

enum InnerTubeError: LocalizedError {
    case badResponse(Int)
    case notFound

    var errorDescription: String? {
        switch self {
        case .badResponse(let status):
            return String(localized: "YouTube Music non ha risposto correttamente (\(status)).")
        case .notFound:
            return String(localized: "Nessun brano trovato.")
        }
    }
}

/// Minimal client for the YouTube Music web API (the "WEB_REMIX" InnerTube client).
/// Used for search and radios; the audio stream itself comes from `StreamResolver`.
struct InnerTube {
    static let shared = InnerTube()

    private static let base = URL(string: "https://music.youtube.com/youtubei/v1/")!
    private static let songsFilter = "EgWKAQIIAWoMEA4QChADEAQQCRAF"
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private static var context: [String: Any] {
        [
            "client": [
                "clientName": "WEB_REMIX",
                "clientVersion": "1.20250310.01.00",
                "hl": Locale.current.language.languageCode?.identifier ?? "en",
                "gl": Locale.current.region?.identifier ?? "US",
            ],
        ]
    }

    func searchSongs(_ query: String) async throws -> [Track] {
        let json = try await post("search", ["query": query, "params": Self.songsFilter])
        return J.findAll("musicResponsiveListItemRenderer", in: json["contents"])
            .compactMap(Self.parseListItem)
            .uniqued()
    }

    /// The radio YouTube Music builds when you start a song: the song itself followed by similar ones.
    func radio(for videoId: String) async throws -> [Track] {
        let json = try await post("next", [
            "videoId": videoId,
            "playlistId": "RDAMVM\(videoId)",
            "isAudioOnly": true,
            "enablePersistentPlaylistPanel": true,
        ])
        return J.findAll("playlistPanelVideoRenderer", in: json["contents"])
            .compactMap(Self.parsePanelItem)
            .uniqued()
    }

    /// Songs of a public YouTube / YouTube Music playlist, following up to 10 pages of results.
    func playlist(id playlistId: String) async throws -> (title: String?, tracks: [Track]) {
        let id = playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId
        let firstPage = try await post("browse", ["browseId": "VL\(id)"])
        let title = Self.playlistTitle(firstPage)

        var items = J.findAll("musicPlaylistShelfRenderer", in: firstPage["contents"]).first
            .map { J.array($0["contents"]) } ?? []
        if items.isEmpty {
            items = J.findAll("musicShelfRenderer", in: firstPage["contents"]).first
                .map { J.array($0["contents"]) } ?? []
        }

        var tracks: [Track] = []
        for _ in 0..<10 {
            tracks += items
                .compactMap { J.dict(J.value($0, "musicResponsiveListItemRenderer")) }
                .compactMap(Self.parseListItem)
            let token = items.compactMap {
                J.string(J.value($0, "continuationItemRenderer", "continuationEndpoint",
                                 "continuationCommand", "token"))
            }.first
            guard let token else { break }
            let page = try await post("browse", ["continuation": token])
            items = J.findAll("appendContinuationItemsAction", in: page).first
                .map { J.array($0["continuationItems"]) } ?? []
        }
        guard !tracks.isEmpty else { throw InnerTubeError.notFound }
        return (title, tracks.uniqued())
    }

    /// The playlist ID from a link such as `https://music.youtube.com/playlist?list=PL…`, or the text itself.
    static func playlistID(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let components = URLComponents(string: trimmed),
           let list = components.queryItems?.first(where: { $0.name == "list" })?.value, !list.isEmpty {
            return list
        }
        let isBareID = !trimmed.isEmpty && trimmed.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        return isBareID ? trimmed : nil
    }

    private static func playlistTitle(_ json: [String: Any]) -> String? {
        let headers = ["musicResponsiveHeaderRenderer", "musicDetailHeaderRenderer",
                       "musicEditablePlaylistDetailHeaderRenderer", "musicImmersiveHeaderRenderer"]
        for key in headers {
            if let header = J.findAll(key, in: json).first,
               let title = J.string(J.value(header, "title", "runs", 0, "text")) {
                return title
            }
        }
        return nil
    }

    /// The YouTube Music song that best matches a track from another service, judged on
    /// artist, title and length. Nil when nothing is close enough.
    func bestMatch(for wanted: Track) async throws -> Track? {
        let results = try await searchSongs("\(wanted.primaryArtist) \(Self.baseTitle(wanted.title))")
        let scored = results.prefix(8).map { ($0, Self.matchScore($0, wanted)) }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 >= 4 else { return nil }
        return best.0
    }

    /// Import is stricter than ordinary playback: never silently substitute an unrelated title,
    /// artist or recognizable live/remix version. Try a second query before asking the user.
    func bestImportMatch(for wanted: Track) async throws -> Track? {
        let base = Self.baseTitle(wanted.title)
        let first = "\(wanted.primaryArtist) \(base)".trimmingCharacters(in: .whitespaces)
        let second = "\(wanted.title) \(wanted.primaryArtist)".trimmingCharacters(in: .whitespaces)
        for query in [first, second].uniquedQueries() where !query.isEmpty {
            let results = try await searchSongs(query)
            if let found = Self.bestImportCandidate(in: results, wanted: wanted) { return found }
        }
        return nil
    }

    /// Suggestions are not automatic matches: the user can choose an alternate recording.
    func importSuggestions(for wanted: Track, query: String? = nil) async throws -> [Track] {
        let typed = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let search = typed.isEmpty ? "\(wanted.primaryArtist) \(wanted.title)" : typed
        let results = try await searchSongs(search)
        return results.filter { $0.videoId != nil }.sorted { Self.matchScore($0, wanted) > Self.matchScore($1, wanted) }
    }

    static func bestImportCandidate(in results: [Track], wanted: Track) -> Track? {
        let wantedArtist = importKey(wanted.primaryArtist), wantedTitle = importKey(baseTitle(wanted.title))
        guard wantedArtist.count >= 2, !wantedTitle.isEmpty else { return nil }
        let variants = importVariants(wanted.title)
        let compatible = results.prefix(25).filter { candidate in
            guard candidate.videoId != nil, importVariants(candidate.title) == variants else { return false }
            if let a = candidate.duration, let b = wanted.duration, abs(a - b) > max(15, b * 0.15) { return false }
            let title = importKey(baseTitle(candidate.title)), artist = importKey(candidate.artist)
            let primary = importKey(candidate.primaryArtist)
            let shorter = min(title.count, wantedTitle.count), longer = max(title.count, wantedTitle.count)
            let titleMatches = title == wantedTitle || (shorter >= 4 && Double(shorter) / Double(max(1, longer)) >= 0.65
                && (title.contains(wantedTitle) || wantedTitle.contains(title)))
            let artistMatches = wantedArtist.count < 3 ? primary == wantedArtist
                : artist.contains(wantedArtist) || (primary.count >= 3 && wantedArtist.contains(primary))
            return titleMatches && artistMatches
        }
        return compatible.max { matchScore($0, wanted) < matchScore($1, wanted) }
    }

    private static func importKey(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter(CharacterSet.alphanumerics.contains)))
    }

    private static func importVariants(_ title: String) -> Set<String> {
        let value = normalized(title)
        let patterns = ["live", "remix", "acoustic", "instrumental", "karaoke", "sped up", "slowed", "cover"]
        return Set(patterns.filter { value.range(of: "\\b" + NSRegularExpression.escapedPattern(for: $0) + "\\b", options: .regularExpression) != nil })
    }

    private static func matchScore(_ candidate: Track, _ wanted: Track) -> Int {
        var score = 0
        let wantedArtist = normalized(wanted.primaryArtist)
        let candidateArtists = normalized(candidate.artist)
        let candidateMain = normalized(candidate.primaryArtist)
        if !wantedArtist.isEmpty,
           candidateArtists.contains(wantedArtist) || (!candidateMain.isEmpty && wantedArtist.contains(candidateMain)) {
            score += 3
        }
        let candidateTitle = normalized(baseTitle(candidate.title))
        let wantedTitle = normalized(baseTitle(wanted.title))
        if candidateTitle == wantedTitle {
            score += 3
        } else if !candidateTitle.isEmpty, !wantedTitle.isEmpty,
                  candidateTitle.contains(wantedTitle) || wantedTitle.contains(candidateTitle) {
            score += 2
        }
        if let a = candidate.duration, let b = wanted.duration {
            let difference = abs(a - b)
            if difference <= 3 { score += 2 } else if difference <= 10 { score += 1 } else if difference > 40 { score -= 2 }
        }
        return score
    }

    /// "Song (feat. X) - Remastered 2011" -> "Song"
    private static func baseTitle(_ title: String) -> String {
        let cleaned = title
            .replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+-\s+.*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? title : cleaned
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "&", with: "and")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Finds the YouTube Music version of a track that only has artist and title (e.g. from Last.fm).
    func resolve(_ track: Track) async throws -> Track {
        if track.videoId != nil { return track }
        let results = try await searchSongs("\(track.primaryArtist) \(track.title)")
        let sameArtist = results.first {
            $0.primaryArtist.localizedCaseInsensitiveCompare(track.primaryArtist) == .orderedSame
        }
        guard let match = sameArtist ?? results.first else { throw InnerTubeError.notFound }
        return match
    }

    func post(_ endpoint: String, _ body: [String: Any]) async throws -> [String: Any] {
        var url = Self.base.appending(path: endpoint)
        url.append(queryItems: [URLQueryItem(name: "prettyPrint", value: "false")])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://music.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        var payload = body
        payload["context"] = Self.context
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InnerTubeError.badResponse(status)
        }
        return json
    }

    // MARK: Parsing

    struct Byline {
        var artists: [String] = []
        var album: String?
        var duration: TimeInterval?
        /// Pages of the first linked artist and of the album.
        var artistID: String?
        var albumID: String?
    }

    static let kindLabels: Set<String> = ["Song", "Brano", "Canzone", "Video"]

    /// A row of search results.
    static func parseListItem(_ item: [String: Any]) -> Track? {
        let columns = J.array(item["flexColumns"]).compactMap {
            J.dict(J.value($0, "musicResponsiveListItemFlexColumnRenderer"))
        }
        guard let titleRun = J.value(columns.first, "text", "runs", 0),
              let title = J.string(J.value(titleRun, "text")) else { return nil }
        let videoId = J.string(J.value(item, "playlistItemData", "videoId"))
            ?? J.string(J.value(titleRun, "navigationEndpoint", "watchEndpoint", "videoId"))
        guard let videoId else { return nil }

        var byline = parseByline(columns.dropFirst().flatMap { J.array(J.value($0, "text", "runs")) })
        if byline.duration == nil {
            let fixed = J.string(J.value(item, "fixedColumns", 0, "musicResponsiveListItemFixedColumnRenderer",
                                         "text", "runs", 0, "text"))
            byline.duration = fixed.flatMap { parseDuration($0) }
        }
        let thumbnails = J.value(item, "thumbnail", "musicThumbnailRenderer", "thumbnail", "thumbnails")
        return Track(videoId: videoId, title: title, artists: byline.artists, album: byline.album,
                     duration: byline.duration, artworkURL: lastThumbnail(thumbnails),
                     artistID: byline.artistID, albumID: byline.albumID)
    }

    /// A row of the "up next" panel returned by the `next` endpoint.
    private static func parsePanelItem(_ item: [String: Any]) -> Track? {
        guard let videoId = J.string(item["videoId"]),
              let title = J.string(J.value(item, "title", "runs", 0, "text")) else { return nil }
        var byline = parseByline(J.array(J.value(item, "longBylineText", "runs")))
        if byline.artists.isEmpty, let short = J.string(J.value(item, "shortBylineText", "runs", 0, "text")) {
            byline.artists = [short]
        }
        let length = J.string(J.value(item, "lengthText", "runs", 0, "text")).flatMap { parseDuration($0) }
        return Track(videoId: videoId, title: title, artists: byline.artists, album: byline.album,
                     duration: length ?? byline.duration,
                     artworkURL: lastThumbnail(J.value(item, "thumbnail", "thumbnails")),
                     artistID: byline.artistID, albumID: byline.albumID)
    }

    /// Bylines look like "Artist • Album • 3:45": links tell artists and albums apart.
    static func parseByline(_ runs: [Any]) -> Byline {
        var byline = Byline()
        var plain: [String] = []
        for run in runs {
            guard let text = J.string(J.value(run, "text")) else { continue }
            let pageType = J.string(J.value(run, "navigationEndpoint", "browseEndpoint",
                                            "browseEndpointContextSupportedConfigs",
                                            "browseEndpointContextMusicConfig", "pageType")) ?? ""
            let browseId = J.string(J.value(run, "navigationEndpoint", "browseEndpoint", "browseId"))
            switch pageType {
            case "MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_USER_CHANNEL":
                byline.artists.append(text)
                if byline.artistID == nil, pageType == "MUSIC_PAGE_TYPE_ARTIST" { byline.artistID = browseId }
            case "MUSIC_PAGE_TYPE_ALBUM":
                byline.album = text
                byline.albumID = browseId
            default:
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if let duration = parseDuration(trimmed) {
                    byline.duration = duration
                } else if !trimmed.isEmpty, trimmed != "•", trimmed != "&", trimmed != "," {
                    plain.append(trimmed)
                }
            }
        }
        // Some artists (e.g. "Various Artists") have no link: the first plain run is the artist.
        if byline.artists.isEmpty, let first = plain.first(where: { !kindLabels.contains($0) }) {
            byline.artists = [first]
        }
        return byline
    }

    static func lastThumbnail(_ thumbnails: Any?) -> URL? {
        J.string(J.value(J.array(thumbnails).last, "url")).flatMap { URL(string: $0) }
    }

    static func parseDuration(_ text: String) -> TimeInterval? {
        let parts = text.split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var total: TimeInterval = 0
        for part in parts {
            guard let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return total
    }
}

private extension Array where Element == String {
    func uniquedQueries() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)).inserted }
    }
}
