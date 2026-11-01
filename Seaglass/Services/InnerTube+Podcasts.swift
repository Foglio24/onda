import Foundation

/// YouTube Music's podcasts, as a visitor without an account sees them: the shows of the Home's
/// "Podcast" filter, search, and each show's page with its episodes.
extension InnerTube {
    /// The Home's "Podcast" chip.
    private static let podcastsChip = "ggNCSgQIDBADSgQICRABSgQICBABSgQIDhABSgQIBxABSgQIBBABSgQIAxAB"
    private static let podcastsFilter = "EgWKAQJQAWoIEBEQEBAEEBU="
    private static let episodesFilter = "EgWKAQJIAWoIEBEQEBAEEBU="

    /// The rows of podcasts the Home suggests with its "Podcast" filter ("Podcast per iniziare").
    func podcastShelves() async throws -> [PodcastShelf] {
        let json = try await post("browse", ["browseId": "FEmusic_home", "params": Self.podcastsChip])
        var seen = Set<String>()
        return J.findAll("musicCarouselShelfRenderer", in: json["contents"]).compactMap { shelf in
            let title = Self.text(J.value(shelf, "header", "musicCarouselShelfBasicHeaderRenderer", "title")) ?? ""
            let shows = J.array(shelf["contents"])
                .compactMap { J.dict(J.value($0, "musicTwoRowItemRenderer")) }
                .compactMap(Self.podcastCard)
                .filter { seen.insert($0.id).inserted }
            return shows.isEmpty ? nil : PodcastShelf(title: title, shows: shows)
        }
    }

    /// Podcasts found by a search (YouTube Music's podcasts filter).
    func searchPodcasts(_ query: String) async throws -> [PodcastShow] {
        let json = try await post("search", ["query": query, "params": Self.podcastsFilter])
        var seen = Set<String>()
        return J.findAll("musicResponsiveListItemRenderer", in: json["contents"])
            .compactMap(Self.podcastRow)
            .filter { seen.insert($0.id).inserted }
    }

    /// Episodes found by a search (YouTube Music's episodes filter).
    func searchEpisodes(_ query: String) async throws -> [PodcastEpisode] {
        let json = try await post("search", ["query": query, "params": Self.episodesFilter])
        var seen = Set<String>()
        return J.findAll("musicResponsiveListItemRenderer", in: json["contents"])
            .compactMap(Self.episodeRow)
            .filter { seen.insert($0.videoId).inserted }
    }

    /// A podcast's page: its header and its first episodes (newest first).
    func podcast(_ id: String) async throws -> PodcastShowPage {
        let json = try await post("browse", ["browseId": id])
        let header = J.findAll("musicResponsiveHeaderRenderer", in: json["contents"]).first
        guard let header, let title = Self.text(header["title"]) else { throw InnerTubeError.notFound }
        // The page's own description has the biggest cover (544 pixels, the header's 226).
        let artwork = Self.lastThumbnail(J.value(json, "microformat", "microformatDataRenderer", "thumbnail", "thumbnails"))
            ?? Self.lastThumbnail(J.value(header, "thumbnail", "musicThumbnailRenderer", "thumbnail", "thumbnails"))
        let show = PodcastShow(id: id, title: title, author: Self.text(header["straplineTextOne"]) ?? "",
                               artworkURL: artwork)
        let about = J.findAll("musicDescriptionShelfRenderer", in: header).first.flatMap { Self.text($0["description"]) }
        let shelf = J.findAll("musicShelfRenderer", in: json["contents"]).first
        let episodes = J.array(shelf?["contents"]).compactMap { item in
            J.dict(J.value(item, "musicMultiRowListItemRenderer")).flatMap { Self.episode($0, of: show) }
        }
        let continuation = J.string(J.value(shelf, "continuations", 0, "nextContinuationData", "continuation"))
        return PodcastShowPage(show: show, about: about, episodes: episodes, continuation: continuation)
    }

    /// The podcast's next page of (older) episodes.
    func moreEpisodes(of show: PodcastShow, continuation: String) async throws -> (episodes: [PodcastEpisode], continuation: String?) {
        let json = try await post("browse", ["continuation": continuation])
        if let shelf = J.dict(J.value(json, "continuationContents", "musicShelfContinuation")) {
            let episodes = J.array(shelf["contents"]).compactMap { item in
                J.dict(J.value(item, "musicMultiRowListItemRenderer")).flatMap { Self.episode($0, of: show) }
            }
            return (episodes, J.string(J.value(shelf, "continuations", 0, "nextContinuationData", "continuation")))
        }
        // The newer form of continuations.
        let items = J.findAll("appendContinuationItemsAction", in: json).first.map { J.array($0["continuationItems"]) } ?? []
        let episodes = items.compactMap { item in
            J.dict(J.value(item, "musicMultiRowListItemRenderer")).flatMap { Self.episode($0, of: show) }
        }
        let next = items.compactMap {
            J.string(J.value($0, "continuationItemRenderer", "continuationEndpoint", "continuationCommand", "token"))
        }.first
        return (episodes, next)
    }

    /// An episode's exact length: the lists only give it to the minute ("34 min").
    func episodeLength(_ videoId: String) async throws -> TimeInterval? {
        let json = try await post("next", ["videoId": videoId, "isAudioOnly": true])
        let item = J.findAll("playlistPanelVideoRenderer", in: json["contents"])
            .first { J.string($0["videoId"]) == videoId }
        return J.string(J.value(item, "lengthText", "runs", 0, "text")).flatMap(Self.parseDuration)
    }

    // MARK: Parsing

    private static func podcastCard(_ item: [String: Any]) -> PodcastShow? {
        guard let browseId = J.string(J.value(item, "navigationEndpoint", "browseEndpoint", "browseId")),
              browseId.hasPrefix("MPSP"), let title = text(item["title"]) else { return nil }
        return PodcastShow(id: browseId, title: title, author: text(item["subtitle"]) ?? "",
                           artworkURL: lastThumbnail(J.value(item, "thumbnailRenderer", "musicThumbnailRenderer",
                                                             "thumbnail", "thumbnails")))
    }

    private static func columns(_ row: [String: Any]) -> [[String: Any]] {
        J.array(row["flexColumns"]).compactMap { J.dict(J.value($0, "musicResponsiveListItemFlexColumnRenderer")) }
    }

    /// A search row of the podcasts filter: the show's title, then who makes it.
    private static func podcastRow(_ row: [String: Any]) -> PodcastShow? {
        guard let browseId = J.string(J.value(row, "navigationEndpoint", "browseEndpoint", "browseId")),
              browseId.hasPrefix("MPSP") else { return nil }
        let columns = Self.columns(row)
        guard let title = text(J.value(columns.first, "text")), !title.isEmpty else { return nil }
        let byline = columns.dropFirst().compactMap { text(J.value($0, "text")) }
            .joined(separator: " • ").components(separatedBy: " • ")
        return PodcastShow(id: browseId, title: title, author: byline.last ?? "",
                           artworkURL: lastThumbnail(J.value(row, "thumbnail", "musicThumbnailRenderer",
                                                             "thumbnail", "thumbnails")))
    }

    /// A search row of the episodes filter: the title, then "16 giu 2025 • Show".
    private static func episodeRow(_ row: [String: Any]) -> PodcastEpisode? {
        let watch = J.findAll("watchEndpoint", in: row).first
        guard let videoId = J.string(watch?["videoId"]) else { return nil }
        let columns = Self.columns(row)
        guard let title = text(J.value(columns.first, "text")), !title.isEmpty else { return nil }
        let runs = J.array(J.value(columns.dropFirst().first, "text", "runs"))
        var showTitle: String?
        var showID: String?
        for run in runs {
            if let browseId = J.string(J.value(run, "navigationEndpoint", "browseEndpoint", "browseId")),
               browseId.hasPrefix("MPSP") {
                showID = browseId
                showTitle = J.string(J.value(run, "text"))
            }
        }
        let parts = runs.compactMap { J.string(J.value($0, "text")) }.joined()
            .components(separatedBy: " • ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return PodcastEpisode(videoId: videoId, title: title, showTitle: showTitle ?? parts.last ?? "",
                              showID: showID, date: parts.count > 1 ? parts.first : nil, listedLength: nil, notes: nil,
                              artworkURL: lastThumbnail(J.value(row, "thumbnail", "musicThumbnailRenderer",
                                                                "thumbnail", "thumbnails")))
    }

    /// An episode of a podcast's page: "85K visualizzazioni • 3 gg fa", its length to the minute and
    /// its description.
    private static func episode(_ row: [String: Any], of show: PodcastShow) -> PodcastEpisode? {
        let videoId = J.string(J.value(row, "onTap", "watchEndpoint", "videoId"))
            ?? J.string(J.findAll("watchEndpoint", in: row).first?["videoId"])
        guard let videoId, let title = text(row["title"]) else { return nil }
        let parts = (text(row["subtitle"]) ?? "").components(separatedBy: "•")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let length = text(J.value(row, "playbackProgress", "musicPlaybackProgressRenderer", "durationText"))
            .flatMap(listedLength)
        return PodcastEpisode(videoId: videoId, title: title, showTitle: show.title, showID: show.id,
                              date: parts.last, listedLength: length, notes: text(row["description"]),
                              artworkURL: lastThumbnail(J.value(row, "thumbnail", "musicThumbnailRenderer",
                                                                "thumbnail", "thumbnails")),
                              showArtworkURL: show.artworkURL)
    }

    /// "34 min", "2 h 43 min", "1 hr 5 min", "45 sec" (to the minute or so).
    static func listedLength(_ text: String) -> TimeInterval? {
        var total: TimeInterval = 0
        var found = false
        for match in text.matches(of: #/(\d+)\s*([^\d\s•]+)/#) {
            guard let value = Double(match.output.1) else { continue }
            let unit = match.output.2.lowercased()
            if unit.hasPrefix("h") || unit.hasPrefix("or") || unit.hasPrefix("st") {
                total += value * 3600
            } else if unit.hasPrefix("m") {
                total += value * 60
            } else if unit.hasPrefix("s") {
                total += value
            } else {
                continue
            }
            found = true
        }
        return found ? total : nil
    }
}
