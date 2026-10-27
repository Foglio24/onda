// Checks the daily recommendations: the taste profile, the daily draw of mixes and how mixes and
// "Scelti per te" are put together, without the network.
// Run from the repository root: bash Tools/RecommendationCheck/run.sh
import Foundation

var failures = 0
func expect(_ condition: Bool, _ message: String) {
    print(condition ? "ok   \(message)" : "FAIL \(message)")
    if !condition { failures += 1 }
}

func track(_ id: String, _ artist: String, length: TimeInterval = 200) -> Track {
    Track(videoId: id, title: "Song \(id)", artists: [artist], duration: length)
}

let now = Date(timeIntervalSince1970: 1_800_000_000)
let day: TimeInterval = 86_400

// MARK: Daily random

var first = DailyRandom(day: 100, salt: "mixes"), again = DailyRandom(day: 100, salt: "mixes")
var tomorrow = DailyRandom(day: 101, salt: "mixes"), otherSalt = DailyRandom(day: 100, salt: "picks")
let a = (0..<4).map { _ in first.next() }, b = (0..<4).map { _ in again.next() }
expect(a == b, "the same day and salt give the same numbers")
expect(a != (0..<4).map { _ in tomorrow.next() }, "another day gives other numbers")
expect(a != (0..<4).map { _ in otherSalt.next() }, "another salt gives other numbers")

var counter = DailyRandom(day: 1, salt: "weights")
var heavy = 0
for _ in 0..<2000 where counter.sample([(item: "heavy", weight: 9.0), (item: "light", weight: 1.0)], count: 1) == ["heavy"] {
    heavy += 1
}
expect(heavy > 1650 && heavy < 1950, "a weight of 9 against 1 is drawn about 90% of the time: \(heavy)/2000")
let three = counter.sample((0..<10).map { (item: $0, weight: 1.0) }, count: 3)
expect(Set(three).count == 3, "a draw never repeats an item")
expect(counter.sample([(item: 1, weight: 0.0), (item: 2, weight: -1)], count: 2).isEmpty, "zero and negative weights are never drawn")

// MARK: Taste profile

let loved = track("loved", "Daft Punk"), skipped = track("skipped", "Daft Punk")
let old = track("old", "Justice"), recent = track("recent", "Justice")
let events = [
    ListenEvent(videoId: "skipped", artist: "Daft Punk", date: now - 2 * day, listened: 10, length: 200, skipped: true),
    ListenEvent(videoId: "skipped", artist: "Daft Punk", date: now - 1 * day, listened: 5, length: 200, skipped: true),
    ListenEvent(videoId: "old", artist: "Justice", date: now - 90 * day, listened: 200, length: 200, skipped: false),
    ListenEvent(videoId: "recent", artist: "Justice", date: now - 1 * day, listened: 200, length: 200, skipped: false),
]
let profile = TasteProfile(events: events, history: [recent, skipped, old], liked: [loved], playlists: [],
                           downloads: [], now: now)
expect(profile.score(loved) > profile.score(recent), "a liked song counts more than one play")
expect(profile.score(recent) > profile.score(old) * 4, "a play three months ago counts much less than yesterday's")
expect(profile.score(skipped) < 0, "skipped songs score below zero")
expect(profile.isDisliked(skipped) && !profile.isDisliked(recent), "two skips in a month mark a song as disliked")
expect(profile.wasPlayed(recent, within: 2 * day, now: now) && !profile.wasPlayed(old, within: 2 * day, now: now),
       "the last play of each song is known")
expect(!profile.favourites.contains(skipped), "disliked songs are not favourites")

// MARK: Daily mixes

let artistNames = ["Daft Punk", "Justice", "Air", "Phoenix", "Kavinsky", "Cassius", "Sebastian", "Breakbot",
                   "Madeon", "Uffie", "Busy P", "Mr. Oizo"]
var library: [Track] = []
var liked: [Track] = []
for (rank, name) in artistNames.enumerated() {
    for song in 0..<3 {
        let item = track("\(rank)-\(song)", name)
        // Favourite artists first: more of their songs are liked and in the recent history.
        library.append(item)
        if song < max(0, 3 - rank / 4) { liked.append(item) }
    }
}
let taste = TasteProfile(events: [], history: library, liked: liked, playlists: [], downloads: [], now: now)
let today = DailyMixPlanner.plan(taste, day: 500)
expect(today == DailyMixPlanner.plan(taste, day: 500), "the mixes stay the same all day")
expect(today.count == 6, "six daily mixes: \(today.map(\.artist))")
expect(today.allSatisfy { mix in mix.seeds.count == 3 && mix.seeds.allSatisfy { $0.primaryArtist == mix.artist } },
       "each mix starts from three of its artist's songs")
expect(Set(today.map(\.artist)).count == today.count, "no artist has two mixes")

var changedDays = 0, topArtistDays = 0, seen = Set<String>()
var previous = Set(DailyMixPlanner.plan(taste, day: 999).map(\.artist))
for dayNumber in 1000..<1030 {
    let mixes = DailyMixPlanner.plan(taste, day: dayNumber)
    let artists = Set(mixes.map(\.artist))
    if artists != previous { changedDays += 1 }
    if artists.contains("Daft Punk") { topArtistDays += 1 }
    seen.formUnion(artists)
    previous = artists
}
expect(changedDays >= 25, "the mixes change from one day to the next: \(changedDays) days out of 30")
expect(topArtistDays >= 12, "the favourite artist has a mix on many days: \(topArtistDays) out of 30")
expect(seen.count >= 10, "over a month most artists get a mix: \(seen.count) of \(artistNames.count)")
let monday = Set(DailyMixPlanner.plan(taste, day: 2000).flatMap(\.seeds).map(\.videoId))
let tuesday = Set(DailyMixPlanner.plan(taste, day: 2001).flatMap(\.seeds).map(\.videoId))
expect(monday != tuesday, "the songs the mixes start from change too")

// MARK: Putting mixes together

let radioA = (0..<30).map { track("a\($0)", "Other") }, radioB = (0..<30).map { track("b\($0)", "Other") }
let favourites = [track("fav1", "Daft Punk"), track("fav2", "Daft Punk"), skipped]
let mix = RecommendationMixer.dailyMix(radios: [radioA + [skipped], radioB], favourites: favourites,
                                       profile: profile, day: 7, salt: "Daft Punk", now: now)
expect(mix.count == 50, "a mix has 50 songs: \(mix.count)")
expect(Set(mix.map(\.id)).count == mix.count, "no song twice")
expect(mix.first?.id.hasPrefix("fav") == true, "it opens with one of the artist's favourites")
expect(!mix.contains(skipped), "songs skipped twice lately are left out")
expect(mix != RecommendationMixer.dailyMix(radios: [radioA, radioB], favourites: favourites, profile: profile,
                                           day: 8, salt: "Daft Punk", now: now),
       "the order changes from day to day")
expect(RecommendationMixer.interleave([[track("1", "x"), track("2", "x")], [track("3", "x")]]).map(\.id) == ["1", "3", "2"],
       "radios are taken in turn")

let seeds = RecommendationMixer.pickSeeds(taste, day: 3, salt: "daily")
expect(seeds.count == 4 && seeds == RecommendationMixer.pickSeeds(taste, day: 3, salt: "daily"),
       "four seeds for the day's picks, the same all day")
expect(seeds != RecommendationMixer.pickSeeds(taste, day: 3, salt: "refresh"), "pulling down draws other seeds")
let picks = RecommendationMixer.quickPicks(radios: [[recent] + radioA, radioB], seeds: seeds, profile: profile,
                                           day: 3, salt: "daily", now: now)
expect(picks.count == 20, "twenty picks: \(picks.count)")
expect(!picks.contains(recent), "songs played in the last week are left out of the picks")
expect(!picks.contains(where: { seeds.contains($0) }), "the seeds themselves are not picks")

print(failures == 0 ? "RecommendationCheck: all checks passed" : "RecommendationCheck: \(failures) failed")
exit(failures == 0 ? 0 : 1)
