import Foundation

// Playlist.swift uses these app services for cover art and mixes; the import tests need neither.
enum Storage { static let covers = URL(fileURLWithPath: "/tmp") }
struct PlaylistMix: Codable, Hashable {}

var failures = 0
func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    if value() { print("ok   \(message)") }
    else { failures += 1; print("FAIL \(message)") }
}
func song(_ title: String, _ artist: String = "Artist", video: String? = nil, duration: Double? = nil) -> Track {
    Track(videoId: video, title: title, artists: [artist], duration: duration)
}

do {
    var csv = "\u{FEFF}Track Name,Artist Name(s),Album Name,Track Duration (ms)\r\n"
    csv += "\"A, B\",\"Artist One, Artist Two\",\"Album \"\"Deluxe\"\"\",210000\r\n"
    for n in 1...150 { csv += "Song \(n),Artist,Album,180000\r\n" }
    csv += ",Artist,Album,180000\r\n"
    let lists = try PlaylistImportFile.read(Data(csv.utf8), fileName: "Long playlist.csv")
    let rows = lists.first?.rows ?? []
    expect(lists.count == 1 && lists[0].name == "Long playlist" && rows.count == 152,
           "CSV retains more than 100 rows and the playlist name")
    expect(rows.first?.track.title == "A, B" && rows.first?.track.album == "Album \"Deluxe\""
           && rows.first?.track.duration == 210 && rows.first?.track.primaryArtist == "Artist One",
           "CSV reads quoted commas, escaped quotes, artists and duration")
    expect(rows.last?.issue == .unavailable, "CSV reports a row whose title is missing")
    let multiline = try PlaylistImportFile.csv("title,artist\r\n\"line 1\nline 2\",Singer\r\n")
    expect(multiline.count == 2 && multiline[1][0] == "line 1\nline 2", "CSV keeps quoted newlines")
    do { _ = try PlaylistImportFile.csv("title,artist\n\"unfinished"); expect(false, "malformed CSV rejected") }
    catch { expect(true, "malformed CSV rejected") }
} catch { expect(false, "CSV parsed: \(error)") }

do {
    let items: [[String: Any]] = (0..<151).map { n in
        ["track": ["trackName": "Song \(n)", "artistName": "Artist", "albumName": "Album"]]
    }
    let data = try JSONSerialization.data(withJSONObject: ["playlists": [
        ["name": "First", "items": items + [["track": NSNull()], ["episode": ["episodeName": "Podcast", "showName": "Show"]]]],
        ["name": "Second", "items": [["localTrack": ["trackName": "Local", "artistName": "Singer"]]]],
    ]])
    let lists = try PlaylistImportFile.read(data, fileName: "Playlist1.json")
    expect(lists.count == 2 && lists[0].rows.count == 153 && lists[0].rows[150].track.title == "Song 150",
           "Spotify JSON retains all 151 songs and lets the user choose among playlists")
    expect(lists[0].rows[151].issue == .unavailable && lists[0].rows[152].issue == .unsupported,
           "unavailable rows and podcast entries remain visible")
    expect(lists[1].rows.first?.track.title == "Local", "Spotify local track metadata can be matched")
} catch { expect(false, "Spotify JSON parsed: \(error)") }

let source = ["A", "B", "C", "D", "E"].map { PlaylistImportSource.Row(track: song($0)) }
let a = song("A", video: "a"), b = song("B", video: "b"), c = song("C", video: "c")
let assembled = PlaylistImportReport.assemble(service: "Spotify", rows: source,
    matches: [.matched(a), .issue(.notFound), .matched(c), .matched(a), .issue(.searchFailed)], mayBeTruncated: true)
var tracks = assembled.tracks, report = assembled.report
expect(tracks.map(\.videoId) == ["a", "c"] && report.entries.count == 5 && report.pending.count == 3,
       "matched, missing, duplicate and failed rows are all accounted for")
expect(report.pending[1].issue == .duplicate && report.pending[2].issue == .searchFailed && report.mayBeTruncated,
       "duplicates, network errors and a possible source limit are distinct")
let bID = report.entries[1].id
expect(report.resolve(bID, with: b, in: &tracks) == .added && tracks.compactMap(\.videoId) == ["a", "b", "c"],
       "a chosen alternative is inserted between its original neighbors")
let duplicateID = report.entries[3].id
expect(report.resolve(duplicateID, with: a, in: &tracks) == .alreadyPresent && tracks.count == 3,
       "choosing a recording already in the playlist doesn't remove or duplicate it")
report.ignore(duplicateID)
expect(report.ignored.count == 1 && report.pending.count == 1, "an ignored entry remains recoverable")
report.restore(duplicateID)
expect(report.pending.count == 2 && report.entries[3].issue == .duplicate, "restoring retains the original reason")
let missing = PlaylistImportReport.assemble(service: "Spotify", rows: source, matches: [], mayBeTruncated: false)
expect(missing.report.pending.count == source.count && missing.report.pending.allSatisfy { $0.issue == .searchFailed },
       "missing search results never silently drop source rows")

do {
    var playlist = Playlist(id: UUID(), name: "Import", tracks: tracks, createdAt: Date(timeIntervalSinceReferenceDate: 0))
    playlist.importReport = report
    let restored = try JSONDecoder().decode(Playlist.self, from: JSONEncoder().encode(playlist))
    expect(restored.importReport == report && restored.tracks == tracks, "import report survives saving and reopening")
    let old = "{\"id\":\"\(UUID().uuidString)\",\"name\":\"Old\",\"tracks\":[],\"createdAt\":0}"
    let legacy = try JSONDecoder().decode(Playlist.self, from: Data(old.utf8))
    expect(legacy.importReport == nil, "older saved playlists still decode")
} catch { expect(false, "playlist persistence: \(error)") }

let wanted = song("Everlong (Live)", "Foo Fighters", duration: 260)
let live = song("Everlong (Live)", "Foo Fighters", video: "live", duration: 260)
let studio = song("Everlong", "Foo Fighters", video: "studio", duration: 260)
let wrongArtist = song("Everlong (Live)", "Someone Else", video: "wrong", duration: 260)
let tooLong = song("Everlong (Live)", "Foo Fighters", video: "long", duration: 600)
expect(InnerTube.bestImportCandidate(in: [studio, wrongArtist, tooLong, live], wanted: wanted)?.videoId == "live",
       "automatic matching checks title, artist, duration and live/remix version")
expect(InnerTube.bestImportCandidate(in: [studio, wrongArtist, tooLong], wanted: wanted) == nil,
       "uncertain versions are left for the user to choose")

print(failures == 0 ? "PlaylistImportCheck: all checks passed" : "PlaylistImportCheck: \(failures) failed")
if failures > 0 { exit(1) }
