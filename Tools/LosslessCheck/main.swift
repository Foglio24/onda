import Foundation

var failures = 0
func expect(_ condition: Bool, _ message: String) {
    if condition { print("ok   \(message)") } else { print("FAIL \(message)"); failures += 1 }
}

func candidate(_ title: String, _ artists: [String], album: String? = nil, duration: TimeInterval? = 200,
               isrcs: [String] = [], codec: AudioFormatInfo.Codec = .flac, bits: Int? = 16, rate: Double? = 44_100,
               id: String = UUID().uuidString, source: LosslessSourceKind = .openSubsonic) -> LosslessCandidate {
    LosslessCandidate(source: source, id: id, scope: "server1", title: title, artists: artists, album: album, duration: duration,
                      isrcs: isrcs, format: AudioFormatInfo(codec: codec, sampleRate: rate, bitDepth: bits, channels: 2), suffix: codec.rawValue)
}

let song = LosslessQuery(title: "Blinding Lights", artists: ["The Weeknd"], album: "After Hours", duration: 200)

// MARK: Matching

expect(LosslessMatcher.score(song, candidate("Blinding Lights", ["The Weeknd"])) != nil, "same title, artist and length: a match")
expect(LosslessMatcher.score(song, candidate("Blinding Lights", ["Weeknd"])) != nil, "\"The\" before an artist's name doesn't matter")
expect(LosslessMatcher.score(song, candidate("Blinding Lights (2020 Remaster)", ["The Weeknd"])) != nil, "a remaster is the same recording")
expect(LosslessMatcher.score(song, candidate("Blinding Lights - Live", ["The Weeknd"])) == nil, "a live take is another recording")
expect(LosslessMatcher.score(song, candidate("Blinding Lights", ["The Weeknd"], album: "Live at SoFi Stadium")) == nil,
       "a song on a live album is a live take")
expect(LosslessMatcher.score(song, candidate("Blinding Lights (Chromatics Remix)", ["The Weeknd"])) == nil, "a remix is another recording")
expect(LosslessMatcher.score(song, candidate("Blinding Lights (Instrumental)", ["The Weeknd"])) == nil, "an instrumental is another recording")
expect(LosslessMatcher.score(song, candidate("Blinding Lights (Sped Up)", ["The Weeknd"])) == nil, "a sped-up upload is another recording")
expect(LosslessMatcher.score(song, candidate("Blinding Lights", ["The Weeknd"], duration: 260)) == nil, "a minute longer: another cut")
expect(LosslessMatcher.score(song, candidate("Blinding Lights", ["The Weeknd"], duration: 204)) != nil, "4 seconds longer: the same, with silence")
expect(LosslessMatcher.score(song, candidate("Blinding Lights", ["Someone Else"])) == nil, "another artist: another song")
expect(LosslessMatcher.score(song, candidate("Save Your Tears", ["The Weeknd"])) == nil, "another title: another song")
let featured = LosslessQuery(title: "Señorita", artists: ["Shawn Mendes", "Camila Cabello"], duration: 191)
expect(LosslessMatcher.score(featured, candidate("Senorita (feat. Camila Cabello)", ["Shawn Mendes"], duration: 191)) != nil,
       "accents and a \"feat.\" in the title don't stop a match")
let live = LosslessQuery(title: "Blue Monday", artists: ["The New Deal"], album: "Live at The Casbah - 2005-04-29", duration: 166)
expect(LosslessMatcher.score(live, candidate("Blue Monday", ["The New Deal"], album: "Live at The Casbah - 2005-04-29", duration: 166)) != nil,
       "a live take matches the same live take")

// ISRC decides when both have one.
let withISRC = LosslessQuery(title: "Blinding Lights", artists: ["The Weeknd"], duration: 200, isrc: "USUG11904206")
expect(LosslessMatcher.score(withISRC, candidate("Blinding Lights [Explicit]", ["The Weeknd"], isrcs: ["US-UG1-19-04206"])) == 1,
       "the same ISRC (written differently): the same recording")
expect(LosslessMatcher.score(withISRC, candidate("Blinding Lights", ["The Weeknd"], isrcs: ["USUG12000001"])) == nil,
       "another ISRC: another recording, whatever the title")
expect(LosslessMatcher.score(withISRC, candidate("Blinding Lights", ["The Weeknd"], duration: 230, isrcs: ["USUG11904206"])) == nil,
       "the same ISRC with half a minute more: a wrong tag, refused")

// Choosing.
let lossy = candidate("Blinding Lights", ["The Weeknd"], codec: .mp3, bits: nil, id: "mp3")
let cd = candidate("Blinding Lights", ["The Weeknd"], id: "cd")
let hiRes = candidate("Blinding Lights", ["The Weeknd"], bits: 24, rate: 96_000, id: "hires")
expect(LosslessMatcher.best(for: song, among: [lossy]) == nil, "a lossy file is never chosen as lossless")
expect(LosslessMatcher.best(for: song, among: [lossy, cd, hiRes])?.id == "hires", "between equal matches, the better format")
expect(LosslessMatcher.best(for: song, among: [candidate("Blinding Lights - Live", ["The Weeknd"])]) == nil, "nothing fitting: none")

// MARK: Cache names

let first = LosslessCacheKey.name(videoId: "abc123", candidate: cd)
let other = LosslessCacheKey.name(videoId: "abc123", candidate: hiRes)
expect(first != other, "two copies of one song have two names (\(first))")
expect(first == LosslessCacheKey.name(videoId: "abc123", candidate: cd), "the same copy, the same name")
expect(LosslessCacheKey.isLossless(first) && !LosslessCacheKey.isLossless("abc123__Opus__160"),
       "a lossless copy's name never looks like a YouTube copy's")
expect(first.hasPrefix("abc123__") && first.contains("flac16-44100"), "the name carries the song and the format")
let weird = candidate("x", ["y"], id: "../../etc/passwd")
expect(!LosslessCacheKey.name(videoId: "v/../w", candidate: weird).contains("/"), "ids can't leave the cache's folder")
var serverTwo = cd
serverTwo.scope = "server2"
expect(LosslessCacheKey.name(videoId: "abc123", candidate: serverTwo) != first, "two servers' songs with one id never share a file")

// MARK: Decisions

var decisions = LosslessDecisions()
let start = Date(timeIntervalSince1970: 1_000_000)
decisions.record(.found(cd), for: "song", now: start)
expect(decisions.decision(for: "song", now: start.addingTimeInterval(60)) == .found(cd), "a found copy is remembered")
expect(decisions.decision(for: "song", now: start.addingTimeInterval(LosslessDecisions.foundLifetime + 1)) == nil,
       "and asked for again after half an hour")
decisions.record(.missing, for: "gone", now: start)
expect(decisions.decision(for: "gone", now: start.addingTimeInterval(60)) == .missing, "a song not found isn't searched for at once again")
expect(decisions.decision(for: "gone", now: start.addingTimeInterval(LosslessDecisions.missingLifetime + 1)) == nil,
       "but is after ten minutes")
decisions.record(.found(cd), for: "broken", now: start)
decisions.recordFailure("broken", cd)
expect(decisions.decision(for: "broken", now: start) == nil && decisions.hasFailed("broken", cd),
       "a copy that failed while playing is forgotten and marked")
decisions.record(.found(cd), for: "broken", now: start)
expect(decisions.decision(for: "broken", now: start) == .missing, "and never chosen again for that song (no back and forth)")
expect(!decisions.hasFailed("broken", hiRes), "another copy of the song can still be tried")

// MARK: Labels

expect(AudioFormatInfo(codec: .flac, sampleRate: 96_000, bitDepth: 24, channels: 2).label == "FLAC · 24 bit/96 kHz", "FLAC hi-res label")
expect(AudioFormatInfo(codec: .alac, sampleRate: 44_100, bitDepth: 16, channels: 2).label.hasPrefix("ALAC · 16 bit/44"), "ALAC CD label")
expect(AudioFormatInfo(codec: .aac, sampleRate: 44_100, channels: 2, bitrate: 256_000).label == "AAC · 256 kbps", "lossy label: its bitrate")
expect(!AudioFormatInfo(codec: .opus, sampleRate: 48_000).isLossless, "Opus is never lossless")
expect(AudioFormatInfo.Codec(suffix: "flac") == .flac && AudioFormatInfo.Codec(suffix: "x-flac") == .flac, "codec from a suffix or MIME type")

if failures > 0 {
    print("LosslessCheck: \(failures) failed")
    exit(1)
}
print("LosslessCheck passed")
