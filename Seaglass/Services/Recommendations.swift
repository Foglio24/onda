import Foundation

/// The Home's daily recommendations: the user's taste (`TasteProfile`) meets YouTube Music's radios.
/// Daily mixes, "Scelti per te" and moods change once a day and stay put during it; pulling the
/// Home down draws new picks.
@MainActor
enum Recommendations {
    /// Changes at midnight.
    static var today: Int { Calendar.current.ordinality(of: .day, in: .era, for: .now) ?? 0 }

    private static var cachedProfile: (key: String, profile: TasteProfile)?

    /// Worked out again only when the day, the log or the library changes.
    static var profile: TasteProfile {
        let library = Library.shared
        let log = ListeningLog.shared
        let key = [String(today), String(log.revision), library.history.first?.id ?? "", String(library.history.count),
                   library.liked.first?.id ?? "", String(library.liked.count), String(library.downloads.count),
                   String(library.playlists.reduce(0) { $0 + $1.tracks.count })].joined(separator: "|")
        if let cachedProfile, cachedProfile.key == key { return cachedProfile.profile }
        let profile = TasteProfile(events: log.events, history: library.history, liked: library.liked,
                                   playlists: library.playlists.map(\.tracks), downloads: library.downloads)
        cachedProfile = (key, profile)
        return profile
    }

    // MARK: Daily mixes

    static func dailyMixes() -> [DailyMix] {
        DailyMixPlanner.plan(profile, day: today)
    }

    /// A mix's songs: the radios of its seeds, with the artist's favourites mixed in.
    static func tracks(for mix: DailyMix) async throws -> [Track] {
        let radios = await radios(for: mix.seeds)
        guard radios.contains(where: { !$0.isEmpty }) else { throw InnerTubeError.notFound }
        let profile = self.profile
        let favourites = profile.artists.first { $0.name == mix.artist }?.tracks ?? mix.seeds
        return RecommendationMixer.dailyMix(radios: radios, favourites: withoutLongMixes(Array(favourites.prefix(20))),
                                            profile: profile, day: today, salt: mix.artist)
    }

    // MARK: Scelti per te

    private struct SavedPicks: Codable {
        let day: Int
        /// Built from the user's taste, not the generic fallback.
        let personal: Bool
        let tracks: [Track]
    }

    private static var picksFile: URL { Storage.support.appending(path: "quick-picks.json") }

    /// Today's "Scelti per te", worked out once a day and kept; `refresh` draws new ones.
    static func quickPicks(refresh: Bool) async -> [Track] {
        let day = today
        let profile = self.profile
        let saved = (try? Data(contentsOf: picksFile)).flatMap { try? JSONDecoder().decode(SavedPicks.self, from: $0) }
        if !refresh, let saved, saved.day == day, !saved.tracks.isEmpty,
           saved.personal || profile.favourites.isEmpty {
            return saved.tracks
        }
        let salt = refresh ? UUID().uuidString : "daily"
        let seeds = RecommendationMixer.pickSeeds(profile, day: day, salt: salt)
        var tracks: [Track]
        if seeds.isEmpty {
            // Nothing to go on yet: the day's hits.
            var random = DailyRandom(day: day, salt: "hits|\(salt)")
            let query = ["top hits", "hit del momento", "viral hits", "new music friday", "top 50 italia"]
                .randomElement(using: &random) ?? "top hits"
            tracks = Array(withoutLongMixes((try? await InnerTube.shared.searchSongs(query)) ?? []).prefix(20))
        } else {
            tracks = RecommendationMixer.quickPicks(radios: await radios(for: seeds), seeds: seeds,
                                                    profile: profile, day: day, salt: salt)
        }
        guard !tracks.isEmpty else { return saved?.tracks ?? [] }
        if let data = try? JSONEncoder().encode(SavedPicks(day: day, personal: !seeds.isEmpty, tracks: tracks)) {
            try? data.write(to: picksFile, options: .atomic)
        }
        return tracks
    }

    // MARK: Moods

    /// A mood's songs: one of its searches (a different one each day), with the radios of the top
    /// results, without songs skipped twice lately, shuffled for the day.
    static func moodTracks(queries: [String]) async throws -> [Track] {
        var random = DailyRandom(day: today, salt: "mood|\(queries.first ?? "")")
        let query = queries.randomElement(using: &random) ?? queries.first ?? ""
        let found = withoutLongMixes(try await InnerTube.shared.searchSongs(query))
        guard !found.isEmpty else { throw InnerTubeError.notFound }
        let radios = await radios(for: Array(found.prefix(3)))
        let profile = self.profile
        return ([found] + radios).flatMap { $0 }.uniqued()
            .filter { !profile.isDisliked($0) }
            .shuffled(using: &random)
            .prefix(60)
            .map { $0 }
    }

    // MARK: Helpers

    /// The seeds' radios, fetched at the same time; a radio that fails is left out.
    private static func radios(for seeds: [Track]) async -> [[Track]] {
        let ids = seeds.compactMap(\.videoId)
        let results = await withTaskGroup(of: (Int, [Track]).self) { group in
            for (position, id) in ids.enumerated() {
                group.addTask { (position, (try? await InnerTube.shared.radio(for: id)) ?? []) }
            }
            var found: [(Int, [Track])] = []
            for await result in group { found.append(result) }
            return found
        }
        return results.sorted { $0.0 < $1.0 }.map { withoutLongMixes($0.1) }
    }

    /// Drops hour-long compilations uploaded as "songs", unless the user turned the filter off.
    private static func withoutLongMixes(_ tracks: [Track]) -> [Track] {
        guard Preferences.skipsLongMixes else { return tracks }
        return tracks.filter { ($0.duration ?? 0) <= Preferences.longMixThreshold }
    }
}
