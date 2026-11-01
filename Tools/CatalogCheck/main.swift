// Live check of YouTube Music parsing (search, artist and album pages, podcasts, song details, loudness) against the real
// service, so a change on YouTube's side shows up in CI. Needs network access.
// Run from the repository root: bash Tools/CatalogCheck/run.sh
import Foundation

var failures = 0
func expect(_ condition: Bool, _ message: String) {
    print(condition ? "ok   \(message)" : "FAIL \(message)")
    if !condition { failures += 1 }
}

// Chapters from an episode's description (no network).
let chapters = PodcastChapter.chapters(in: "Guest: Mario\n00:00 Intro\n(02:15) - Who is Mario\n12:30 – The story\n1:02:03 Q&A\nSponsor 05:00")
expect(chapters.map(\.time) == [0, 135, 750, 3723] && chapters.last?.title == "Q&A", "chapters: \(chapters.map { "\(Int($0.time)) \($0.title)" })")
expect(PodcastChapter.chapters(in: "See 3:00 for the point\n").isEmpty, "a single timestamp is not a chapter list")
expect(InnerTube.listedLength("2 h 43 min") == 9780 && InnerTube.listedLength("1 hr 5 min") == 3900, "listed lengths")

let tube = InnerTube.shared
do {
    let catalog = try await tube.searchCatalog("daft punk")
    expect(catalog.top?.isArtist == true, "top result is an artist: \(catalog.top?.title ?? "none")")
    expect(!catalog.albums.isEmpty, "search finds albums: \(catalog.albums.prefix(3).map(\.title))")
    // Typing the artist's name puts the artist first; a song title doesn't.
    expect(catalog.artist(named: "Daft  punk")?.id == "UCRr1xG_2WIDs18a6cIiCxeA", "the search names the artist")
    let byTitle = try await tube.searchCatalog("get lucky daft punk")
    expect(byTitle.artist(named: "get lucky daft punk") == nil, "a song's title names no artist")
    expect(try await tube.searchCatalog("ac dc").artist(named: "ac dc")?.title == "AC/DC", "\"ac dc\" names AC/DC")

    let playlists = try await tube.searchPlaylists("daft punk")
    expect(playlists.count >= 3 && playlists.allSatisfy { $0.kind == .playlist && $0.id.hasPrefix("VL") },
           "search finds playlists: \(playlists.prefix(3).map(\.title))")

    let songs = try await tube.searchSongs("daft punk")
    expect(!songs.isEmpty, "search finds songs: \(songs.prefix(3).map(\.title))")
    expect(songs.contains { $0.artistID != nil }, "songs carry their artist's page")

    let named = try await tube.artistID(named: "Daft Punk")
    expect(named == "UCRr1xG_2WIDs18a6cIiCxeA", "artist found by name: \(named ?? "none")")

    let artist = try await tube.artist("UCRr1xG_2WIDs18a6cIiCxeA")
    expect(artist.name == "Daft Punk", "artist page name: \(artist.name)")
    expect(artist.topSongs.count >= 3, "artist top songs: \(artist.topSongs.map(\.title))")
    expect(artist.artworkURL != nil, "artist picture")
    expect(artist.shelves.contains { $0.items.contains { $0.kind == .album } }, "artist albums: \(artist.shelves.map(\.title))")

    let albumID = catalog.albums.first?.id ?? "MPREb_ePmUY37w4pZ"
    let album = try await tube.album(albumID)
    expect(!album.tracks.isEmpty, "album \(album.title): \(album.tracks.count) tracks")
    expect(album.tracks.allSatisfy { $0.artist != "300 Mln riproduzioni" && !$0.artist.isEmpty }, "album tracks have artists, not play counts: \(album.tracks.first?.artist ?? "")")
    expect(album.tracks.contains { $0.duration != nil }, "album tracks have durations")

    // The quick way to audio links: one visionOS player request with a visitor ID.
    if let song = songs.first, let videoId = song.videoId {
        do {
            let direct = try await DirectStreams.fetch(videoId)
            let found = direct.renditions.map { "\($0.format) \($0.bitrate / 1000)k" }
            expect(direct.renditions.contains { $0.format == .aac && $0.isNative }, "direct links for \(song.title): \(found)")
        } catch {
            print("skip direct links of \(song.title): YouTube refused them here (\(error))")
        }
    }

    // YouTube often refuses this request from data centres (like CI's), as it does audio:
    // that is reported, not counted as a failure. The parsing itself is checked offline by
    // Tools/SongDetailsCheck.
    if let song = songs.first, let videoId = song.videoId {
        let json = try await YouTubePlayerData.response(for: videoId) ?? [:]
        let status = J.string(J.value(json, "playabilityStatus", "status")) ?? "nothing"
        if status != "OK" {
            print("skip song details of \(song.title): YouTube answered \(status) here")
        } else {
            let details = SongDetails(json: json)
            let released = details.releaseDate.map { String(describing: $0) } ?? "none"
            let credits = details.credits.map { credit in credit.role + ": " + credit.names.joined(separator: ", ") }
            let label = details.label ?? "none", albumName = details.album ?? "none"
            let copyright = details.copyright ?? "no copyright"
            expect(details.label != nil, "song details of \(song.title): label \(label), album \(albumName), released \(released), \(copyright)")
            expect(!credits.isEmpty, "song credits: \(credits)")
            expect(details.views != nil, "song plays: \(details.views.map(String.init) ?? "none")")
        }
    }

    // Podcasts: the Home's suggestions, search, a show's pages of episodes and an episode's length.
    // The Home's suggestions depend on the place and the visitor (none from CI's machines at times,
    // and the app then searches instead): only what comes is checked.
    let shelves = try await tube.podcastShelves()
    let suggested = shelves.flatMap(\.shows)
    if suggested.isEmpty {
        print("skip podcast suggestions: none here")
    } else {
        expect(suggested.allSatisfy { $0.id.hasPrefix("MPSP") && !$0.title.isEmpty },
               "podcast suggestions: \(shelves.map(\.title)) \(suggested.prefix(3).map(\.title))")
    }
    let shows = try await tube.searchPodcasts("history")
    expect(shows.count >= 3 && shows.allSatisfy { $0.id.hasPrefix("MPSP") }, "podcast search: \(shows.prefix(3).map(\.title))")
    let found = try await tube.searchEpisodes("history")
    expect(found.count >= 3 && found.allSatisfy { !$0.videoId.isEmpty && !$0.showTitle.isEmpty },
           "episode search: \(found.prefix(2).map { "\($0.title) (\($0.showTitle), \($0.date ?? "no date"))" })")
    let mixed = try await tube.searchCatalog("history podcast")
    expect(mixed.podcasts.contains { $0.kind == .podcast }, "the main search lists podcasts: \(mixed.podcasts.prefix(2).map(\.title))")
    if let show = suggested.first ?? shows.first {
        let page = try await tube.podcast(show.id)
        expect(page.episodes.count >= 5 && page.episodes.allSatisfy { $0.showID == show.id },
               "\(page.show.title) by \(page.show.author): \(page.episodes.count) episodes, the first \(page.episodes.first?.title ?? "none") (\(page.episodes.first?.date ?? "no date"))")
        expect(page.show.artworkURL != nil && page.about?.isEmpty == false, "the show's cover and description")
        if let continuation = page.continuation {
            let more = try await tube.moreEpisodes(of: page.show, continuation: continuation)
            let known = Set(page.episodes.map(\.videoId))
            expect(more.episodes.count >= 5 && !more.episodes.contains { known.contains($0.videoId) },
                   "older episodes: \(more.episodes.count)")
        } else {
            expect(page.episodes.count < 20, "a full first page goes on")
        }
        if let episode = page.episodes.first(where: { $0.listedLength != nil }) {
            let exact = try await tube.episodeLength(episode.videoId)
            let listed = episode.listedLength ?? 0
            expect(exact.map { abs($0 - listed) <= 90 } == true,
                   "exact length \(exact.map { String(Int($0)) } ?? "none") s, listed \(Int(listed)) s")
        }
    }

    let decibels = await Loudness.shared.decibels(for: "dQw4w9WgXcQ")
    expect(decibels != nil, "loudness from YouTube: \(decibels.map { String(format: "%.2f dB", $0) } ?? "none")")
} catch {
    expect(false, "request failed: \(error)")
}

print(failures == 0 ? "CatalogCheck: all checks passed" : "CatalogCheck: \(failures) failed")
exit(failures == 0 ? 0 : 1)
