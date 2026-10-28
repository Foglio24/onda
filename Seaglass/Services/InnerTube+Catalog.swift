import Foundation

/// An entry of YouTube Music other than a plain song row: an artist, an album (or single, EP),
/// a playlist, or a song or video shown as a card.
struct MusicItem: Identifiable, Hashable {
    enum Kind: Hashable {
        case artist, album, playlist
        case song(Track)
    }

    let kind: Kind
    /// The page's browse ID ("UC…" artists, "MPREb_…" albums, "VL…" playlists), or the video ID.
    let id: String
    let title: String
    let subtitle: String
    let artworkURL: URL?

    var isArtist: Bool { kind == .artist }
}

/// A row of an artist page: albums, singles, videos, playlists or similar artists.
struct MusicShelf: Identifiable {
    let title: String
    let items: [MusicItem]
    var id: String { title }
}

struct ArtistPage {
    let name: String
    let artworkURL: URL?
    let about: String?
    let topSongs: [Track]
    /// The playlist with all of the artist's songs ("Tutti i brani").
    let songsPlaylistID: String?
    let shelves: [MusicShelf]
}

struct AlbumPage {
    let title: String
    let artist: String
    let artistID: String?
    /// "Album • 2013", "EP • 1997".
    let kindAndYear: String
    /// "4 brani • 23 minuti".
    let details: String
    let artworkURL: URL?
    let tracks: [Track]
}

/// Artists and albums found by a search, with YouTube Music's top result when it is one of them.
struct CatalogResults {
    var top: MusicItem?
    var artists: [MusicItem] = []
    var albums: [MusicItem] = []

    var isEmpty: Bool { top == nil && artists.isEmpty && albums.isEmpty }
}

extension InnerTube {
    private static let artistsFilter = "EgWKAQIgAWoMEA4QChADEAQQCRAF"

    /// The unfiltered search, which ranks artists and albums well; songs come from `searchSongs`.
    func searchCatalog(_ query: String) async throws -> CatalogResults {
        let json = try await post("search", ["query": query])
        var results = CatalogResults()
        if let card = J.findAll("musicCardShelfRenderer", in: json["contents"]).first {
            results.top = Self.cardItem(card)
        }
        var seen = Set(results.top.map { [$0.id] } ?? [])
        for row in J.findAll("musicResponsiveListItemRenderer", in: json["contents"]) {
            guard let item = Self.listItem(row), seen.insert(item.id).inserted else { continue }
            switch item.kind {
            case .artist: results.artists.append(item)
            case .album: results.albums.append(item)
            default: break
            }
        }
        // The unfiltered results mix in singles that only mention the name: albums by the searched
        // artist come first, then albums and EPs before singles, otherwise in YouTube's order.
        let wanted = Self.folded(query)
        results.albums = results.albums.enumerated().sorted { a, b in
            let first = Self.albumScore(a.element, query: wanted)
            let second = Self.albumScore(b.element, query: wanted)
            return first != second ? first > second : a.offset < b.offset
        }.map(\.element)
        return results
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
    }

    /// "Album • Daft Punk • 2013" for "daft punk" scores 3; "Singolo • Someone else • 2021" scores 0.
    private static func albumScore(_ album: MusicItem, query: String) -> Int {
        let parts = album.subtitle.components(separatedBy: " • ")
        var score = 0
        if !query.isEmpty, parts.dropFirst().contains(where: { folded($0).contains(query) }) { score += 2 }
        if let kind = parts.first.map(folded), ["album", "ep"].contains(kind) { score += 1 }
        return score
    }

    /// The YouTube Music page of an artist known only by name (e.g. a song from Last.fm).
    func artistID(named name: String) async throws -> String? {
        let json = try await post("search", ["query": name, "params": Self.artistsFilter])
        let artists = J.findAll("musicResponsiveListItemRenderer", in: json["contents"])
            .compactMap(Self.listItem)
            .filter(\.isArtist)
        let exact = artists.first { $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame }
        return (exact ?? artists.first)?.id
    }

    func artist(_ browseId: String) async throws -> ArtistPage {
        let json = try await post("browse", ["browseId": browseId])
        let header = ["musicImmersiveHeaderRenderer", "musicVisualHeaderRenderer", "musicResponsiveHeaderRenderer"]
            .lazy.compactMap { J.findAll($0, in: json["header"]).first }.first
        guard let header else { throw InnerTubeError.notFound }
        var topSongs: [Track] = []
        var songsPlaylistID: String?
        var shelves: [MusicShelf] = []
        let sections = J.findAll("sectionListRenderer", in: json["contents"]).first.map { J.array($0["contents"]) } ?? []
        for section in sections {
            if let shelf = J.dict(J.value(section, "musicShelfRenderer")), topSongs.isEmpty {
                topSongs = J.array(shelf["contents"])
                    .compactMap { J.dict(J.value($0, "musicResponsiveListItemRenderer")) }
                    .compactMap(Self.parseListItem)
                songsPlaylistID = J.string(J.value(shelf, "title", "runs", 0, "navigationEndpoint", "browseEndpoint", "browseId"))
                    ?? J.string(J.value(shelf, "bottomEndpoint", "browseEndpoint", "browseId"))
            } else if let carousel = J.dict(J.value(section, "musicCarouselShelfRenderer")) {
                let title = Self.text(J.value(carousel, "header", "musicCarouselShelfBasicHeaderRenderer", "title")) ?? ""
                let items = J.array(carousel["contents"])
                    .compactMap { J.dict(J.value($0, "musicTwoRowItemRenderer")) }
                    .compactMap(Self.cardItem(twoRow:))
                if !title.isEmpty, !items.isEmpty { shelves.append(MusicShelf(title: title, items: items)) }
            }
        }
        return ArtistPage(name: Self.text(header["title"]) ?? "",
                          artworkURL: Self.thumbnail(in: header["thumbnail"]),
                          about: Self.text(header["description"]),
                          topSongs: topSongs, songsPlaylistID: songsPlaylistID, shelves: shelves)
    }

    func album(_ browseId: String) async throws -> AlbumPage {
        let json = try await post("browse", ["browseId": browseId])
        guard let header = J.findAll("musicResponsiveHeaderRenderer", in: json).first else {
            throw InnerTubeError.notFound
        }
        let title = Self.text(header["title"]) ?? ""
        let artist = Self.text(header["straplineTextOne"]) ?? ""
        let artistID = J.string(J.value(header, "straplineTextOne", "runs", 0, "navigationEndpoint",
                                        "browseEndpoint", "browseId"))
        let artwork = Self.thumbnail(in: header["thumbnail"])
        let rows = J.findAll("musicShelfRenderer", in: json["contents"]).first.map { J.array($0["contents"]) } ?? []
        let tracks = rows.compactMap { J.dict(J.value($0, "musicResponsiveListItemRenderer")) }.compactMap { row -> Track? in
            let columns = J.array(row["flexColumns"]).compactMap {
                J.dict(J.value($0, "musicResponsiveListItemFlexColumnRenderer"))
            }
            guard let name = Self.text(J.value(columns.first, "text")), !name.isEmpty,
                  let videoId = J.string(J.value(row, "playlistItemData", "videoId")) else { return nil }
            // Only the second column names artists (often empty: the album's artist); the third is play counts.
            let byline = Self.parseByline(J.array(J.value(columns.dropFirst().first, "text", "runs")))
            let length = J.string(J.value(row, "fixedColumns", 0, "musicResponsiveListItemFixedColumnRenderer",
                                          "text", "runs", 0, "text")).flatMap { Self.parseDuration($0) }
            return Track(videoId: videoId, title: name, artists: byline.artists.isEmpty ? [artist] : byline.artists,
                         album: title, duration: length, artworkURL: artwork,
                         artistID: byline.artistID ?? artistID, albumID: browseId)
        }
        guard !tracks.isEmpty else { throw InnerTubeError.notFound }
        return AlbumPage(title: title, artist: artist, artistID: artistID,
                         kindAndYear: Self.text(header["subtitle"]) ?? "",
                         details: Self.text(header["secondSubtitle"]) ?? "",
                         artworkURL: artwork, tracks: tracks)
    }

    // MARK: Parsing

    /// The text of a `{"runs": [...]}` object.
    static func text(_ value: Any?) -> String? {
        let runs = J.array(J.value(value, "runs")).compactMap { J.string(J.value($0, "text")) }
        return runs.isEmpty ? nil : runs.joined()
    }

    private static func thumbnail(in value: Any?) -> URL? {
        lastThumbnail(J.value(J.findAll("musicThumbnailRenderer", in: value).first, "thumbnail", "thumbnails"))
    }

    private static func kind(of browseEndpoint: [String: Any]) -> MusicItem.Kind? {
        switch J.string(J.value(browseEndpoint, "browseEndpointContextSupportedConfigs",
                                "browseEndpointContextMusicConfig", "pageType")) {
        case "MUSIC_PAGE_TYPE_ARTIST": return .artist
        case "MUSIC_PAGE_TYPE_ALBUM": return .album
        case "MUSIC_PAGE_TYPE_PLAYLIST": return .playlist
        default: return nil
        }
    }

    /// A search row that opens a page (artist, album, playlist). Song rows give nil.
    private static func listItem(_ row: [String: Any]) -> MusicItem? {
        guard let endpoint = J.dict(J.value(row, "navigationEndpoint", "browseEndpoint")),
              let browseId = J.string(endpoint["browseId"]), let kind = kind(of: endpoint) else { return nil }
        let columns = J.array(row["flexColumns"]).compactMap {
            J.dict(J.value($0, "musicResponsiveListItemFlexColumnRenderer"))
        }
        guard let title = text(J.value(columns.first, "text")), !title.isEmpty else { return nil }
        var parts = columns.dropFirst().compactMap { text(J.value($0, "text")) }
            .joined(separator: " • ")
            .components(separatedBy: " • ")
        // "Artista • 67,8 Mln ascoltatori mensili": the section already says it's an artist.
        if kind == .artist, parts.count > 1 { parts.removeFirst() }
        return MusicItem(kind: kind, id: browseId, title: title, subtitle: parts.joined(separator: " • "),
                         artworkURL: lastThumbnail(J.value(row, "thumbnail", "musicThumbnailRenderer",
                                                           "thumbnail", "thumbnails")))
    }

    /// The search's top result card, when it is an artist, album or playlist.
    private static func cardItem(_ card: [String: Any]) -> MusicItem? {
        guard let endpoint = J.dict(J.value(card, "title", "runs", 0, "navigationEndpoint", "browseEndpoint")),
              let browseId = J.string(endpoint["browseId"]), let kind = kind(of: endpoint),
              let title = text(card["title"]) else { return nil }
        return MusicItem(kind: kind, id: browseId, title: title, subtitle: text(card["subtitle"]) ?? "",
                         artworkURL: lastThumbnail(J.value(card, "thumbnail", "musicThumbnailRenderer",
                                                           "thumbnail", "thumbnails")))
    }

    /// A card of an artist page's carousels: a page to open, or a song or video to play.
    private static func cardItem(twoRow item: [String: Any]) -> MusicItem? {
        let title = text(item["title"]) ?? ""
        let subtitle = text(item["subtitle"]) ?? ""
        let artwork = lastThumbnail(J.value(item, "thumbnailRenderer", "musicThumbnailRenderer", "thumbnail", "thumbnails"))
        guard !title.isEmpty else { return nil }
        if let endpoint = J.dict(J.value(item, "navigationEndpoint", "browseEndpoint")),
           let browseId = J.string(endpoint["browseId"]), let kind = kind(of: endpoint) {
            return MusicItem(kind: kind, id: browseId, title: title, subtitle: subtitle, artworkURL: artwork)
        }
        guard let videoId = J.string(J.value(item, "navigationEndpoint", "watchEndpoint", "videoId")) else { return nil }
        let byline = parseByline(J.array(J.value(item, "subtitle", "runs")))
        let track = Track(videoId: videoId, title: title, artists: byline.artists, album: byline.album,
                          duration: byline.duration, artworkURL: artwork,
                          artistID: byline.artistID, albumID: byline.albumID)
        return MusicItem(kind: .song(track), id: videoId, title: title, subtitle: subtitle, artworkURL: artwork)
    }
}
