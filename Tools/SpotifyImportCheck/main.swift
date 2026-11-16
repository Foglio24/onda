import Foundation

// Playlist.swift uses these app services for cover art and mixes; the checks need neither.
enum Storage { static let covers = URL(fileURLWithPath: "/tmp") }
struct PlaylistMix: Codable, Hashable {}

var failures = 0
func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    if value() { print("ok   \(message)") }
    else { failures += 1; print("FAIL \(message)") }
}
func json(_ text: String) -> Any { try! JSONSerialization.jsonObject(with: Data(text.utf8)) }

// What the web player answers with ("libraryV3" and "fetchPlaylist"), trimmed to what the import reads.
let library = json("""
{"data":{"me":{"libraryV3":{"__typename":"LibraryPage","totalCount":3,"items":[
  {"item":{"data":{"__typename":"Playlist","uri":"spotify:playlist:AAA","name":"Estate",
    "ownerV2":{"data":{"name":"Luca"}},
    "images":{"items":[{"sources":[{"url":"https://i.scdn.co/image/a"}]}]}}}},
  {"item":{"data":{"__typename":"Album","uri":"spotify:album:BBB","name":"Un album"}}},
  {"item":{"data":{"__typename":"Folder","uri":"spotify:user:x:folder:1","name":"Cartella",
    "playlists":[{"data":{"__typename":"Playlist","uri":"spotify:playlist:CCC","name":"Dentro la cartella"}}]}}}
]}}}}
""")
let playlistPage = json("""
{"data":{"playlistV2":{"__typename":"Playlist","name":"Estate","content":{"totalCount":250,"items":[
  {"itemV2":{"data":{"__typename":"Track","name":"Bohemian Rhapsody - Remastered 2011",
    "artists":{"items":[{"profile":{"name":"Queen"}}]},
    "albumOfTrack":{"name":"A Night at the Opera"},
    "trackDuration":{"totalMilliseconds":354320}}}},
  {"itemV2":{"data":{"__typename":"NotFound"}}},
  {"itemV2":{"data":{"__typename":"Episode","name":"Un podcast"}}}
]}}}}
""")

let playlists = SpotifyParse.libraryPlaylists(library)
expect(playlists.map(\.uri) == ["spotify:playlist:AAA", "spotify:playlist:CCC"], "playlists come from the library, folders included, albums left out")
expect(playlists.first?.owner == "Luca" && playlists.first?.imageURL?.absoluteString == "https://i.scdn.co/image/a", "owner and cover are read")
expect(SpotifyParse.libraryTotal(library) == 3 && SpotifyParse.libraryItemCount(library) == 3, "total and page size are read")

let page = try SpotifyParse.playlistPage(playlistPage)
expect(page.name == "Estate" && page.total == 250 && page.songs.count == 3, "a playlist page keeps every row")
expect(page.songs[0]?.title == "Bohemian Rhapsody - Remastered 2011" && page.songs[0]?.artists == ["Queen"]
       && page.songs[0]?.album == "A Night at the Opera" && abs((page.songs[0]?.durationSeconds ?? 0) - 354.32) < 0.001,
       "a song is read with artist, album and duration")
expect(page.songs[1] == nil && page.songs[2] == nil, "an unavailable row and an episode stay as gaps")
expect((try? SpotifyParse.playlistPage(json(#"{"data":{}}"#))) == nil, "an answer without a playlist is refused")

let source = PlaylistImportSource.spotify(name: "", content: SpotifyPlaylistContent(
    name: "Estate", songs: [SpotifySong(title: "Song", artists: ["A", "B"], album: "Album", durationSeconds: 200), nil]))
expect(source.name == "Estate" && source.rows.count == 2 && source.rows[0].track.title == "Song"
       && source.rows[0].track.primaryArtist == "A" && source.rows[1].issue == .unavailable, "a playlist becomes import rows, unavailable songs reported")
expect(PlaylistImportSource.spotify(name: "Mia", content: SpotifyPlaylistContent(name: "Estate", songs: [])).name == "Mia", "the chosen name wins")

// The queries the web player sent: a POST with a body, or a GET with the query in the URL.
let post = PathfinderOperation.parse(url: "https://api-partner.spotify.com/pathfinder/v2/query",
    body: #"{"operationName":"libraryV3","variables":{"filters":[],"limit":50},"extensions":{"persistedQuery":{"version":1,"sha256Hash":"abc123"}}}"#)
expect(post?.name == "libraryV3" && post?.hash == "abc123" && post?.url.hasSuffix("/pathfinder/v2/query") == true
       && (post?.variables["limit"] as? Int) == 50, "a POST query is read")
let ext = #"{"persistedQuery":{"version":1,"sha256Hash":"def456"}}"#.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
let vars = #"{"uri":"spotify:playlist:AAA"}"#.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
let get = PathfinderOperation.parse(url: "https://api-partner.spotify.com/pathfinder/v1/query?operationName=fetchPlaylist&variables=\(vars)&extensions=\(ext)", body: nil)
expect(get?.name == "fetchPlaylist" && get?.hash == "def456" && get?.url == "https://api-partner.spotify.com/pathfinder/v1/query"
       && (get?.variables["uri"] as? String) == "spotify:playlist:AAA", "a GET query is read from its URL")
expect(PathfinderOperation.parse(url: "https://x/pathfinder/v2/query", body: #"{"operationName":"x"}"#) == nil, "a query without a hash is not kept")

// The reader: pages through the library and a playlist, retries a 429, says when the token expired.
@MainActor final class FakeTransport: SpotifyTransport {
    var requests: [SpotifyHTTPRequest] = []
    var answers: [SpotifyHTTPResponse] = []
    func send(_ request: SpotifyHTTPRequest) async throws -> SpotifyHTTPResponse {
        requests.append(request)
        return answers.isEmpty ? SpotifyHTTPResponse(status: 500, retryAfter: nil, body: "") : answers.removeFirst()
    }
}
func text(_ value: Any) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self) }
func libraryPage(total: Int, uris: [String]) -> String {
    text(["data": ["me": ["libraryV3": ["totalCount": total, "items": uris.map { uri in
        ["item": ["data": ["__typename": "Playlist", "uri": uri, "name": "N " + uri]]] }]]]])
}

@MainActor func readerChecks() async {
    let transport = FakeTransport()
    let library = PathfinderOperation(name: "libraryV3", hash: "h1", url: "https://api-partner.spotify.com/pathfinder/v2/query",
                                      variables: ["flatten": false, "limit": 50])
    let reader = SpotifyWeb(transport: transport, headers: ["authorization": "Bearer t"], library: library, playlist: nil)
    let first = (0..<100).map { "spotify:playlist:P\($0)" }
    transport.answers = [
        SpotifyHTTPResponse(status: 429, retryAfter: 1, body: ""),
        SpotifyHTTPResponse(status: 200, retryAfter: nil, body: libraryPage(total: 130, uris: first)),
        SpotifyHTTPResponse(status: 200, retryAfter: nil, body: libraryPage(total: 130, uris: (100..<130).map { "spotify:playlist:P\($0)" })),
    ]
    let all = (try? await reader.playlists()) ?? []
    expect(all.count == 130, "the library is read page after page (and a 429 is retried)")
    expect(transport.requests.count == 3 && transport.requests.allSatisfy { $0.method == "POST" && $0.headers["authorization"] == "Bearer t" },
           "every request carries the player's headers")
    let body = (json(transport.requests[2].body ?? "{}") as? [String: Any]) ?? [:]
    let variables = body["variables"] as? [String: Any]
    expect((variables?["offset"] as? Int) == 100 && (variables?["limit"] as? Int) == 100 && (variables?["flatten"] as? Bool) == true,
           "the second page asks from 100, and folders are flattened")
    expect(((body["extensions"] as? [String: Any])?["persistedQuery"] as? [String: Any])?["sha256Hash"] as? String == "h1", "the query's hash is sent")
    expect(transport.requests[0].headers["content-type"] == "application/json;charset=UTF-8", "a POST says it is JSON")

    transport.answers = [SpotifyHTTPResponse(status: 401, retryAfter: nil, body: "")]
    var expired = false
    do { _ = try await reader.playlists() } catch SpotifyImportError.sessionExpired { expired = true } catch {}
    expect(expired, "a 401 means the session expired")

    let playlistOperation = PathfinderOperation(name: "fetchPlaylist", hash: "h2",
                                                url: "https://api-partner.spotify.com/pathfinder/v1/query", variables: ["limit": 25])
    let withPlaylist = SpotifyWeb(transport: transport, headers: [:], library: library, playlist: playlistOperation)
    func songs(_ range: Range<Int>, total: Int) -> String {
        text(["data": ["playlistV2": ["name": "Estate", "content": ["totalCount": total, "items": range.map { n in
            ["itemV2": ["data": ["__typename": "Track", "name": "Song \(n)", "artists": ["items": [["profile": ["name": "A"]]]]]]] }]]]])
    }
    transport.requests = []
    transport.answers = [SpotifyHTTPResponse(status: 200, retryAfter: nil, body: songs(0..<100, total: 120)),
                         SpotifyHTTPResponse(status: 200, retryAfter: nil, body: songs(100..<120, total: 120))]
    let content = try? await withPlaylist.content(of: "spotify:playlist:AAA")
    expect(content?.songs.count == 120 && content?.name == "Estate", "a playlist past 100 songs is read whole")
    expect(transport.requests.allSatisfy { $0.method == "GET" && $0.url.query?.contains("operationName=fetchPlaylist") == true },
           "the older endpoint is asked with the query in the URL")
    let sentQuery = transport.requests.first?.url.query?.removingPercentEncoding ?? ""
    expect(sentQuery.contains(#""uri":"spotify:playlist:AAA""#) && sentQuery.contains(#""offset":0"#), "the playlist's address goes in the query")

    let without = SpotifyWeb(transport: transport, headers: [:], library: library, playlist: nil)
    var missing = false
    do { _ = try await without.content(of: "spotify:playlist:AAA") } catch SpotifyImportError.unavailable { missing = true } catch {}
    expect(missing, "a playlist can't be read before the player has asked for one")
}

await readerChecks()

if failures > 0 { print("\(failures) check(s) failed"); exit(1) }
print("All Spotify import checks passed")
