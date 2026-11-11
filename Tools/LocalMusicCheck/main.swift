// Tests the pure part of the user's own songs (LocalMusicIndex): which files count, the songs' IDs,
// what a new scan has to read again, titles from file names, the order and the search. Run from the
// repository root: bash Tools/LocalMusicCheck/run.sh
import Foundation

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

// Which files count.
for name in ["a.mp3", "A.MP3", "b.m4a", "c.flac", "d.wav", "e.aiff", "f.aif", "g.caf", "h.aac", "i.m4b", "Song.With.Dots.mp3"] {
    expect(LocalMusicIndex.isAudio(name), "\(name) is audio")
}
for name in ["cover.jpg", "notes.txt", "a.mp3.part", "song", "playlist.m3u", "a.ogg", "a.opus", ".DS_Store"] {
    expect(!LocalMusicIndex.isAudio(name), "\(name) is not audio")
}

// IDs: stable, 22 characters, never a YouTube one.
let first = LocalMusicIndex.trackID(folder: "f1", path: "Artist/Album/01 Song.mp3")
expect(first == LocalMusicIndex.trackID(folder: "f1", path: "Artist/Album/01 Song.mp3"), "the same file has the same ID")
expect(first != LocalMusicIndex.trackID(folder: "f2", path: "Artist/Album/01 Song.mp3"), "another folder, another ID")
expect(first != LocalMusicIndex.trackID(folder: "f1", path: "Artist/Album/02 Song.mp3"), "another file, another ID")
expect(first.count == 22 && first.hasPrefix("local-") && Track.isLocalID(first), "an ID is 22 characters and local")
expect(!Track.isLocalID("dQw4w9WgXcQ") && !Track.isLocalID("local-abcde") && !Track.isLocalID("local-"), "YouTube's IDs are not local")
expect(first == "local-" + first.dropFirst(6).lowercased(), "an ID is lowercase hexadecimal")
var seen = Set<String>()
for n in 0..<2_000 { seen.insert(LocalMusicIndex.trackID(folder: "f", path: "Album \(n % 50)/\(n).mp3")) }
expect(seen.count == 2_000, "two thousand files, two thousand IDs")
expect(LocalMusicIndex.folderID(path: "/a/b") == LocalMusicIndex.folderID(path: "/a/b")
       && LocalMusicIndex.folderID(path: "/a/b") != LocalMusicIndex.folderID(path: "/a/c"), "a folder's ID comes from where it is")
let cover = Data([1, 2, 3, 4])
expect(LocalMusicIndex.coverKey(cover) == LocalMusicIndex.coverKey(Data([1, 2, 3, 4])) && LocalMusicIndex.coverKey(cover) != LocalMusicIndex.coverKey(Data([1, 2, 3, 5])),
       "a cover's key comes from its content")

// What a scan reads again.
func file(_ path: String, size: Int64 = 100, modified: TimeInterval = 1_000) -> LocalFile {
    LocalFile(id: LocalMusicIndex.trackID(folder: "f", path: path), folder: "f", path: path, size: size, modified: modified,
              title: "T " + path, artist: "A", album: nil, duration: 200, cover: nil)
}
let known = [file("a.mp3"), file("b.mp3"), file("c.mp3"), file("gone.mp3")]
let found = [
    LocalMusicIndex.Found(path: "a.mp3", size: 100, modified: 1_000),
    LocalMusicIndex.Found(path: "b.mp3", size: 101, modified: 1_000),
    LocalMusicIndex.Found(path: "c.mp3", size: 100, modified: 2_000),
    LocalMusicIndex.Found(path: "new.mp3", size: 50, modified: 1_000),
]
let plan = LocalMusicIndex.plan(previous: known, found: found)
expect(plan.kept.map(\.path) == ["a.mp3"], "an unchanged file isn't read again")
expect(plan.toRead.map(\.path) == ["b.mp3", "c.mp3", "new.mp3"], "a changed (size or date) or new file is read")
expect(plan.removed.map(\.path) == ["gone.mp3"], "a file that is gone is dropped")
expect(LocalMusicIndex.plan(previous: [], found: []).toRead.isEmpty, "an empty folder reads nothing")
let nearly = LocalMusicIndex.plan(previous: [file("a.mp3")], found: [LocalMusicIndex.Found(path: "a.mp3", size: 100, modified: 1_000.4)])
expect(nearly.toRead.isEmpty, "a date within a second is the same")

// Titles from file names.
expect(LocalMusicIndex.fallbackTitle("01 - Intro.mp3") == "Intro", "\"01 - Intro\"")
expect(LocalMusicIndex.fallbackTitle("1. Intro.m4a") == "Intro", "\"1. Intro\"")
expect(LocalMusicIndex.fallbackTitle("03_Song Name.flac") == "Song Name", "\"03_Song Name\"")
expect(LocalMusicIndex.fallbackTitle("07 Song.mp3") == "Song", "a zero-padded number")
expect(LocalMusicIndex.fallbackTitle("21 Guns.mp3") == "21 Guns", "a number in the title stays")
expect(LocalMusicIndex.fallbackTitle("99 Luftballons.mp3") == "99 Luftballons", "another number in the title stays")
expect(LocalMusicIndex.fallbackTitle("Just A Song.wav") == "Just A Song", "a plain name")
expect(LocalMusicIndex.fallbackTitle("05.mp3") == "05", "a name that is only a number stays")

// The song as the lists have it.
var tagged = file("Artist/Album/01 Song.mp3")
tagged.title = "Song"
tagged.artist = "Artist"
tagged.album = "Album"
let track = LocalMusicIndex.track(tagged)
expect(track.videoId == tagged.id && track.id == tagged.id && track.isLocal, "a track has the file's ID")
expect(track.title == "Song" && track.primaryArtist == "Artist" && track.album == "Album" && track.duration == 200, "and its tags")
tagged.artist = ""
expect(!LocalMusicIndex.track(tagged).artist.isEmpty && LocalMusicIndex.track(tagged).primaryArtist.isEmpty, "no artist: the app's unknown artist")
expect(track.shareURL == nil, "a local song has no link to share")

// The order: artist, album, then the folder's order, numbers as numbers.
func entry(_ artist: String, _ album: String?, _ path: String) -> LocalFile {
    var f = file(path)
    f.artist = artist
    f.album = album
    return f
}
let unordered = [
    entry("Zed", "Z", "z/1.mp3"),
    entry("béta", "B", "b/10 Ten.mp3"),
    entry("beta", "B", "b/2 Two.mp3"),
    entry("Alpha", "Second", "a/s/1.mp3"),
    entry("Alpha", "First", "a/f/1.mp3"),
    entry("alpha", nil, "a/none.mp3"),
]
let ordered = LocalMusicIndex.sorted(unordered).map(\.path)
expect(ordered == ["a/none.mp3", "a/f/1.mp3", "a/s/1.mp3", "b/2 Two.mp3", "b/10 Ten.mp3", "z/1.mp3"],
       "artists without case or accents, albums, then paths with numbers as numbers (\(ordered))")

// The search: every word, anywhere in the title, artist or album, without case or accents.
var searched = entry("Björk", "Homogenic", "b/01 Jóga.mp3")
searched.title = "Jóga"
let hay = LocalMusicIndex.haystack(searched)
expect(LocalMusicIndex.matches(hay, query: "joga"), "a title without its accent")
expect(LocalMusicIndex.matches(hay, query: "BJORK homo"), "words from the artist and the album, in capitals")
expect(!LocalMusicIndex.matches(hay, query: "joga madonna"), "every word has to be there")
expect(!LocalMusicIndex.matches(hay, query: "   "), "an empty search matches nothing")

print("LocalMusicCheck: \(checks) checks passed")
