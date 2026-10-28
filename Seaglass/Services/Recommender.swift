import Foundation

/// A play as the recommendations remember it (see `ListeningLog`).
struct ListenEvent: Codable, Equatable, Sendable {
    let videoId: String
    let artist: String
    let date: Date
    var listened: TimeInterval
    let length: TimeInterval?
    /// Left with "next" in its first 30 seconds (songs longer than a minute).
    var skipped: Bool
}

/// Random numbers that come out the same for the same day and salt (SplitMix64), so
/// recommendations change every day but stay put during it.
struct DailyRandom: RandomNumberGenerator {
    private var state: UInt64

    init(day: Int, salt: String) {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in salt.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        state = hash ^ (UInt64(bitPattern: Int64(day)) &* 0x9E37_79B9_7F4A_7C15)
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    /// Picks up to `count` items, each with a chance proportional to its weight, none twice.
    mutating func sample<Item>(_ items: [(item: Item, weight: Double)], count: Int) -> [Item] {
        var pool = items.filter { $0.weight > 0 && $0.weight.isFinite }
        var picked: [Item] = []
        while picked.count < count, !pool.isEmpty {
            let total = pool.reduce(0) { $0 + $1.weight }
            var target = Double.random(in: 0..<total, using: &self)
            var index = pool.count - 1
            for (position, entry) in pool.enumerated() {
                target -= entry.weight
                if target < 0 {
                    index = position
                    break
                }
            }
            picked.append(pool.remove(at: index).item)
        }
        return picked
    }
}

/// How much the user likes each song and artist, learned on the iPhone from what they play to
/// the end, skip, like, keep in playlists and download. Recent plays count most: a play's weight
/// halves every three weeks.
struct TasteProfile {
    struct Artist {
        let name: String
        let score: Double
        /// Their songs the app knows, best liked first.
        let tracks: [Track]
    }

    private(set) var artists: [Artist] = []
    private var scores: [String: Double] = [:]
    private var known: [String: Track] = [:]
    private var recentSkips: [String: Int] = [:]
    private var lastPlayed: [String: Date] = [:]

    static let halfLife: TimeInterval = 21 * 86_400

    init(events: [ListenEvent], history: [Track], liked: [Track], playlists: [[Track]],
         downloads: [Track], now: Date = .now) {
        var artistNames: [String: String] = [:]
        var artistScores: [String: Double] = [:]
        func key(_ name: String) -> String { name.trimmingCharacters(in: .whitespaces).lowercased() }
        func remember(_ track: Track) {
            guard let videoId = track.videoId, known[videoId] == nil else { return }
            known[videoId] = track
        }
        func add(_ videoId: String, artist: String, _ value: Double) {
            scores[videoId, default: 0] += value
            let artistKey = key(artist)
            guard !artistKey.isEmpty else { return }
            artistNames[artistKey] = artistNames[artistKey] ?? artist.trimmingCharacters(in: .whitespaces)
            artistScores[artistKey, default: 0] += value
        }

        for event in events {
            let age = max(0, now.timeIntervalSince(event.date))
            let decay = pow(0.5, age / Self.halfLife)
            if event.skipped {
                add(event.videoId, artist: event.artist, -0.6 * decay)
                if age < 30 * 86_400 { recentSkips[event.videoId, default: 0] += 1 }
            } else {
                let completion = event.length.map { $0 > 0 ? min(1, event.listened / $0) : 1 } ?? 1
                // Half a point just for starting it, the rest for how much was heard.
                add(event.videoId, artist: event.artist, (0.5 + 0.5 * completion) * decay)
            }
            if let previous = lastPlayed[event.videoId], previous >= event.date { continue }
            lastPlayed[event.videoId] = event.date
        }
        // Libraries from before the log: recent history, most recent first, as a weaker signal.
        let logged = Set(events.map(\.videoId))
        for (position, track) in history.enumerated() {
            remember(track)
            guard let videoId = track.videoId, !logged.contains(videoId) else { continue }
            add(videoId, artist: track.primaryArtist, 0.5 * pow(0.5, Double(position) / 50))
        }
        for track in liked {
            remember(track)
            if let videoId = track.videoId { add(videoId, artist: track.primaryArtist, 1.5) }
        }
        for track in playlists.joined() {
            remember(track)
            if let videoId = track.videoId { add(videoId, artist: track.primaryArtist, 0.6) }
        }
        for track in downloads {
            remember(track)
            if let videoId = track.videoId { add(videoId, artist: track.primaryArtist, 0.6) }
        }

        var tracksByArtist: [String: [Track]] = [:]
        for track in known.values { tracksByArtist[key(track.primaryArtist), default: []].append(track) }
        artists = artistScores.compactMap { artistKey, score in
            guard let name = artistNames[artistKey] else { return nil }
            let tracks = (tracksByArtist[artistKey] ?? []).sorted {
                let left = scores[$0.videoId ?? ""] ?? 0, right = scores[$1.videoId ?? ""] ?? 0
                return left == right ? ($0.videoId ?? "") < ($1.videoId ?? "") : left > right
            }
            return Artist(name: name, score: score, tracks: tracks)
        }
        .sorted { $0.score == $1.score ? $0.name < $1.name : $0.score > $1.score }
    }

    func score(_ track: Track) -> Double { track.videoId.flatMap { scores[$0] } ?? 0 }

    /// Skipped at least twice in the last month: left out of recommendations.
    func isDisliked(_ track: Track) -> Bool { (track.videoId.flatMap { recentSkips[$0] } ?? 0) >= 2 }

    func wasPlayed(_ track: Track, within interval: TimeInterval, now: Date = .now) -> Bool {
        guard let date = track.videoId.flatMap({ lastPlayed[$0] }) else { return false }
        return now.timeIntervalSince(date) < interval
    }

    /// Known songs with a positive score, best first.
    var favourites: [Track] {
        known.values.filter { score($0) > 0 }
            .sorted { score($0) == score($1) ? ($0.videoId ?? "") < ($1.videoId ?? "") : score($0) > score($1) }
    }
}

/// One of the Home's daily mixes: an artist the user likes and similar music, started from a few
/// of their songs that change every day.
struct DailyMix: Identifiable, Equatable {
    let number: Int
    let artist: String
    /// Songs whose YouTube Music radios make up the mix.
    let seeds: [Track]
    /// The artist's songs the user knows, for the cover mosaic.
    let covers: [Track]

    var id: String { "mix-\(number)" }
}

/// Picks the day's mixes. Each day draws a few of the user's artists at random, favourites more
/// often, the ones featured the day before less often, so the mixes rotate instead of always
/// being the most played artists.
enum DailyMixPlanner {
    static let candidates = 16

    static func plan(_ profile: TasteProfile, day: Int, count: Int = 6) -> [DailyMix] {
        let pool = Array(profile.artists.filter { $0.tracks.count >= 2 && $0.score > 0 }.prefix(candidates))
        let yesterday = Set(pick(pool, day: day - 1, count: count, lessLikely: []).map(\.name))
        let chosen = pick(pool, day: day, count: count, lessLikely: yesterday)
            .sorted { $0.score > $1.score }
        return chosen.enumerated().map { position, artist in
            var random = DailyRandom(day: day, salt: "seeds|\(artist.name)")
            let weighted = artist.tracks.map { (item: $0, weight: max(0.05, profile.score($0))) }
            let seeds = random.sample(weighted, count: 3)
            let covers = random.sample(artist.tracks.map { (item: $0, weight: 1.0) }, count: 4)
            return DailyMix(number: position + 1, artist: artist.name, seeds: seeds, covers: covers)
        }
    }

    private static func pick(_ pool: [TasteProfile.Artist], day: Int, count: Int,
                             lessLikely: Set<String>) -> [TasteProfile.Artist] {
        var random = DailyRandom(day: day, salt: "mixes")
        let weighted = pool.map { artist in
            (item: artist, weight: pow(artist.score, 0.75) * (lessLikely.contains(artist.name) ? 0.3 : 1))
        }
        return random.sample(weighted, count: count)
    }
}

/// Puts together a list of songs from several YouTube Music radios.
enum RecommendationMixer {
    /// The radios taken in turn, one song from each, without repeats.
    static func interleave(_ radios: [[Track]]) -> [Track] {
        var result: [Track] = []
        var seen = Set<String>()
        let longest = radios.map(\.count).max() ?? 0
        for position in 0..<longest {
            for radio in radios where position < radio.count {
                let track = radio[position]
                if seen.insert(track.videoId ?? track.id).inserted { result.append(track) }
            }
        }
        return result
    }

    /// A daily mix: the artist's favourite songs mixed into its radios, shuffled for the day,
    /// opening with a favourite. Songs skipped twice lately and songs played in the last day
    /// are left out.
    static func dailyMix(radios: [[Track]], favourites: [Track], profile: TasteProfile, day: Int,
                         salt: String, limit: Int = 50, now: Date = .now) -> [Track] {
        var random = DailyRandom(day: day, salt: "mix|\(salt)")
        let fresh: (Track) -> Bool = { !profile.isDisliked($0) && !profile.wasPlayed($0, within: 86_400, now: now) }
        let familiar = Array(favourites.filter(fresh).shuffled(using: &random).prefix(8))
        let familiarIDs = Set(familiar.compactMap(\.videoId))
        let others = interleave(radios).filter { fresh($0) && !familiarIDs.contains($0.videoId ?? "") }
            .shuffled(using: &random)
        // A familiar song every fourth place, starting with one.
        var result: [Track] = []
        var familiarQueue = familiar[...], otherQueue = others[...]
        while result.count < limit, !(familiarQueue.isEmpty && otherQueue.isEmpty) {
            if result.count % 4 == 0, let next = familiarQueue.popFirst() {
                result.append(next)
            } else if let next = otherQueue.popFirst() {
                result.append(next)
            } else if let next = familiarQueue.popFirst() {
                result.append(next)
            }
        }
        return result
    }

    /// The day's seeds for "Scelti per te": a few liked or recently enjoyed songs, drawn at random
    /// with the better liked more likely, from the 60 best.
    static func pickSeeds(_ profile: TasteProfile, day: Int, salt: String, count: Int = 4) -> [Track] {
        var random = DailyRandom(day: day, salt: "picks|\(salt)")
        let weighted = profile.favourites.prefix(60).map { (item: $0, weight: profile.score($0)) }
        return random.sample(Array(weighted), count: count)
    }

    /// "Scelti per te": mostly songs not played in the last week, from the seeds' radios, with a
    /// few favourites not heard for two weeks.
    static func quickPicks(radios: [[Track]], seeds: [Track], profile: TasteProfile, day: Int, salt: String,
                           limit: Int = 20, now: Date = .now) -> [Track] {
        var random = DailyRandom(day: day, salt: "picks-order|\(salt)")
        let seedIDs = Set(seeds.compactMap(\.videoId))
        let discoveries = interleave(radios).filter {
            !seedIDs.contains($0.videoId ?? "") && !profile.isDisliked($0)
                && !profile.wasPlayed($0, within: 7 * 86_400, now: now)
        }
        let rediscoveries = profile.favourites.prefix(40)
            .filter { !seedIDs.contains($0.videoId ?? "") && !profile.wasPlayed($0, within: 14 * 86_400, now: now) }
            .shuffled(using: &random)
            .prefix(limit / 4)
        var result = Array(discoveries.prefix(limit - rediscoveries.count)) + rediscoveries
        result.shuffle(using: &random)
        return Array(result.prefix(limit))
    }
}
