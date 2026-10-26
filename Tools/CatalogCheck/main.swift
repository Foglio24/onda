// Live check of YouTube Music parsing (search, artist and album pages, song details, loudness) against the real
// service, so a change on YouTube's side shows up in CI. Needs network access.
// Run from the repository root: bash Tools/CatalogCheck/run.sh
import Foundation

var failures = 0
func expect(_ condition: Bool, _ message: String) {
    print(condition ? "ok   \(message)" : "FAIL \(message)")
    if !condition { failures += 1 }
}

let tube = InnerTube.shared
do {
    let catalog = try await tube.searchCatalog("daft punk")
    expect(catalog.top?.isArtist == true, "top result is an artist: \(catalog.top?.title ?? "none")")
    expect(!catalog.albums.isEmpty, "search finds albums: \(catalog.albums.prefix(3).map(\.title))")

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

    let decibels = await Loudness.shared.decibels(for: "dQw4w9WgXcQ")
    expect(decibels != nil, "loudness from YouTube: \(decibels.map { String(format: "%.2f dB", $0) } ?? "none")")
} catch {
    expect(false, "request failed: \(error)")
}

print(failures == 0 ? "CatalogCheck: all checks passed" : "CatalogCheck: \(failures) failed")
exit(failures == 0 ? 0 : 1)
