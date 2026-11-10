// Tests how the library on a device and the account's are merged (LibraryMerge), and what is
// sent to the account service (SyncLimits). Run from the repository root:
// bash Tools/AccountSyncCheck/run.sh
import Foundation

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

func song(_ n: Int) -> Track {
    let id = String(format: "song%07d", n)
    var track = Track(videoId: id, title: "Song \(n)", artists: ["Artist \(n)"], album: "Album", duration: 200,
                      artworkURL: URL(string: "https://lh3.googleusercontent.com/\(n)"))
    track.artistID = "UC\(n)"
    return track
}
func ids(_ tracks: [Track]) -> [String] { tracks.map(LibraryMerge.key) }
func snapshot(liked: [Track] = [], playlists: [SyncedPlaylist] = [], history: [Track] = [],
              preferences: [String: SyncValue]? = nil) -> LibrarySnapshot {
    LibrarySnapshot(liked: liked, playlists: playlists, history: history, preferences: preferences)
}

let a = song(1), b = song(2), c = song(3), d = song(4), e = song(5)

// First sync with an account: nothing is lost, from either side.
var merged = LibraryMerge.merge(local: snapshot(liked: [a, b]), base: nil, remote: snapshot(liked: [c, b]))
expect(ids(merged.liked) == ids([a, b, c]), "First sync joins both libraries")
merged = LibraryMerge.merge(local: snapshot(liked: [a]), base: nil, remote: nil)
expect(ids(merged.liked) == ids([a]), "An empty account keeps the device's library")

// One side changed: the other follows, removals included.
let base = snapshot(liked: [a, b, c])
merged = LibraryMerge.merge(local: base, base: base, remote: snapshot(liked: [d, a, c]))
expect(ids(merged.liked) == ids([d, a, c]), "Another device's like and unlike arrive")
merged = LibraryMerge.merge(local: snapshot(liked: [e, a, c]), base: base, remote: base)
expect(ids(merged.liked) == ids([e, a, c]), "This device's changes are kept when the account didn't change")

// Both changed: each side's additions and removals.
merged = LibraryMerge.merge(local: snapshot(liked: [e, a, b]), base: base, remote: snapshot(liked: [d, a, c, b]))
expect(ids(merged.liked) == ids([d, e, a, b]), "Both devices' likes are kept, both removals applied")
expect(!ids(merged.liked).contains(LibraryMerge.key(c)), "A song unliked here doesn't come back")

// A library emptied at once on the account isn't taken as deletions.
merged = LibraryMerge.merge(local: base, base: base, remote: .empty)
expect(ids(merged.liked) == ids([a, b, c]), "An emptied account doesn't empty the device")

// Playlists.
let mix = SyncedPlaylist(id: UUID(), title: "Mix", tracks: [a, b])
let road = SyncedPlaylist(id: UUID(), title: "Road", tracks: [c])
let pBase = snapshot(playlists: [mix, road])
var renamed = mix; renamed.title = "Summer Mix"
var grown = mix; grown.tracks = [a, b, d]
merged = LibraryMerge.merge(local: snapshot(playlists: [grown, road]), base: pBase, remote: snapshot(playlists: [renamed, road]))
expect(merged.playlists.count == 2 && merged.playlists[0].title == "Summer Mix" && ids(merged.playlists[0].tracks) == ids([a, b, d]),
       "A rename on one device and new songs on the other are both kept")
var reordered = mix; reordered.tracks = [b, a]
merged = LibraryMerge.merge(local: pBase, base: pBase, remote: snapshot(playlists: [reordered, road]))
expect(ids(merged.playlists[0].tracks) == ids([b, a]), "A reorder on another device arrives")
merged = LibraryMerge.merge(local: pBase, base: pBase, remote: snapshot(playlists: [mix]))
expect(merged.playlists.map(\.id) == [mix.id], "A playlist deleted on another device goes")
merged = LibraryMerge.merge(local: snapshot(playlists: [mix, SyncedPlaylist(id: road.id, title: "Road", tracks: [c, e])]),
                            base: pBase, remote: snapshot(playlists: [mix]))
expect(merged.playlists.map(\.id) == [mix.id, road.id], "A playlist changed here survives its deletion elsewhere")
merged = LibraryMerge.merge(local: snapshot(playlists: [mix]), base: pBase, remote: pBase)
expect(merged.playlists.map(\.id) == [mix.id], "A playlist deleted here stays deleted")
let fresh = SyncedPlaylist(id: UUID(), title: "New", tracks: [e])
merged = LibraryMerge.merge(local: pBase, base: pBase, remote: snapshot(playlists: [fresh, mix, road]))
expect(merged.playlists.map(\.id) == [fresh.id, mix.id, road.id], "A new playlist from another device arrives on top")

// History: newest first, capped.
let long = (0..<250).map(song)
merged = LibraryMerge.merge(local: snapshot(history: Array(long.prefix(150))), base: nil,
                            remote: snapshot(history: Array(long.suffix(150))))
expect(merged.history.count == LibraryMerge.historyLimit, "The history stays within its limit")

// Preferences: the account's on a new device, then each side's changes.
merged = LibraryMerge.merge(local: snapshot(preferences: ["playback.crossfade": .number(4), "theme.accent": .string("pink")]),
                            base: nil, remote: snapshot(preferences: ["playback.crossfade": .number(8)]))
expect(merged.preferences?["playback.crossfade"] == .number(8) && merged.preferences?["theme.accent"] == .string("pink"),
       "A new device takes the account's preferences and keeps its others")
let prefBase = snapshot(preferences: ["audio.spatial": .bool(false), "theme.accent": .string("pink")])
merged = LibraryMerge.merge(local: snapshot(preferences: ["audio.spatial": .bool(true), "theme.accent": .string("pink")]),
                            base: prefBase,
                            remote: snapshot(preferences: ["audio.spatial": .bool(false), "theme.accent": .string("blue")]))
expect(merged.preferences == ["audio.spatial": .bool(true), "theme.accent": .string("blue")], "Each side's preference changes are kept")

// What's sent: songs the service would refuse stay on the device, out of the upload.
var noTitle = song(9); noTitle.title = " "
var lastfm = Track(videoId: nil, title: "Old Song", artists: ["Someone"])
var oddVideo = song(10); oddVideo.videoId = "not-a-video-id"
var plainArtwork = song(11); plainArtwork.artworkURL = URL(string: "http://example.com/a.jpg")
let upload = SyncLimits.uploadable(snapshot(liked: [a, noTitle, lastfm, oddVideo, plainArtwork],
                                            playlists: [SyncedPlaylist(id: mix.id, title: "  ", tracks: [a])]))
expect(ids(upload.liked) == ids([a, lastfm, plainArtwork]), "Only songs the service takes are sent")
expect(upload.liked[2].artworkURL == nil, "Artwork that isn't https is left out")
expect(upload.playlists[0].title == "Playlist", "A blank playlist name is sent as a name")
merged = LibraryMerge.merge(local: snapshot(liked: [a, noTitle]), base: upload, remote: upload)
expect(ids(merged.liked) == ids([a, noTitle]), "A song never sent isn't removed from the device")

// The JSON the service reads and returns.
let encoded = try JSONEncoder().encode(snapshot(liked: [a], playlists: [mix], preferences: ["audio.spatial": .bool(true), "playback.crossfade": .number(6)]))
let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
let playlistID = ((object?["playlists"] as? [[String: Any]])?.first?["id"] as? String) ?? ""
expect(playlistID == mix.id.uuidString.lowercased(), "Playlist identifiers are sent lowercase")
let fromService = """
{"liked":[{"id":"song0000001","videoId":"song0000001","title":"Song 1","artist":"Artist 1","primaryArtist":"Artist 1",
"album":null,"duration":null,"artworkURL":null,"sourceIDs":null,"artistID":null,"albumID":null,"podcastID":null}],
"playlists":[{"id":"\(mix.id.uuidString.lowercased())","title":"Mix","tracks":[]}],"history":[],
"preferences":{"audio.spatial":true,"playback.crossfade":6,"theme.accent":"blue"}}
"""
let decoded = try JSONDecoder().decode(LibrarySnapshot.self, from: Data(fromService.utf8))
expect(decoded.liked.first?.videoId == "song0000001" && decoded.playlists.first?.id == mix.id, "The service's JSON reads back")
expect(decoded.preferences?["audio.spatial"] == .bool(true) && decoded.preferences?["playback.crossfade"] == .number(6),
       "Booleans and numbers keep their type")
let older = try JSONDecoder().decode(LibrarySnapshot.self, from: Data(#"{"liked":[],"playlists":[],"history":[]}"#.utf8))
expect(older.preferences == nil, "Snapshots from before preferences still read")

print("AccountSyncCheck: \(checks) checks passed")
