import Foundation
import UIKit

/// The podcasts you follow and where you are in each episode, saved as a JSON file.
@MainActor
final class PodcastLibrary: ObservableObject {
    static let shared = PodcastLibrary()

    struct Progress: Codable, Hashable {
        var position: TimeInterval
        /// The exact length, once the player knows it.
        var length: TimeInterval?
        var finished: Bool
        var updated: Date
    }

    @Published private(set) var followed: [PodcastShow]
    /// Episodes played, the last first: "Continua ad ascoltare" and the player's chapters.
    @Published private(set) var recent: [PodcastEpisode]
    @Published private(set) var progress: [String: Progress]

    private struct Saved: Codable {
        var followed: [PodcastShow] = []
        var recent: [PodcastEpisode] = []
        var progress: [String: Progress] = [:]
    }

    private static let recentLimit = 100
    private static let file = Storage.support.appending(path: "podcasts.json")
    /// The position is noted every few seconds while playing, the file is written at most this often
    /// (and when the app goes to the background).
    private static let saveInterval: TimeInterval = 30
    private var lastSave = Date.distantPast
    private var unsaved = false

    private init() {
        let saved = (try? Data(contentsOf: Self.file)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } ?? Saved()
        followed = saved.followed
        recent = saved.recent
        progress = saved.progress
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PodcastLibrary.shared.saveIfNeeded(force: true) }
        }
    }

    // MARK: Following

    func isFollowing(_ id: String) -> Bool { followed.contains { $0.id == id } }

    func toggleFollow(_ show: PodcastShow) {
        if isFollowing(show.id) {
            followed.removeAll { $0.id == show.id }
        } else {
            followed.insert(show, at: 0)
        }
        save()
    }

    // MARK: Episodes

    /// An episode starts playing: it goes first in "Continua ad ascoltare".
    func played(_ episode: PodcastEpisode) {
        var episode = episode
        // A search result knows less than the show's page: keep what an earlier listing knew.
        if let known = recent.first(where: { $0.videoId == episode.videoId }) {
            episode.notes = episode.notes ?? known.notes
            episode.listedLength = episode.listedLength ?? known.listedLength
            episode.date = episode.date ?? known.date
            episode.showArtworkURL = episode.showArtworkURL ?? known.showArtworkURL
        }
        recent.removeAll { $0.videoId == episode.videoId }
        recent.insert(episode, at: 0)
        if recent.count > Self.recentLimit { recent.removeLast(recent.count - Self.recentLimit) }
        save()
    }

    /// Plays an episode from where it was left (see `PlayerController.playEpisodes`).
    func play(_ episode: PodcastEpisode) {
        played(episode)
        var track = episode.track
        // The exact length, once known: the lists round it to the minute.
        track.duration = progress[episode.videoId]?.length
        PlayerController.shared.playEpisodes([track], source: episode.showTitle)
    }

    func episode(_ videoId: String?) -> PodcastEpisode? {
        guard let videoId else { return nil }
        return recent.first { $0.videoId == videoId }
    }

    /// Episodes started and not finished, the last played first.
    var inProgress: [PodcastEpisode] {
        recent.filter { episode in
            guard let saved = progress[episode.videoId] else { return false }
            return !saved.finished && saved.position > 0
        }
    }

    /// How far into an episode (0…1), nil if never started.
    func fraction(of episode: PodcastEpisode) -> Double? {
        guard let saved = progress[episode.videoId] else { return nil }
        if saved.finished { return 1 }
        guard let length = saved.length ?? episode.listedLength, length > 0 else { return nil }
        return min(1, saved.position / length)
    }

    func isFinished(_ videoId: String) -> Bool { progress[videoId]?.finished ?? false }

    /// Where an episode starts again: where it was left, or the start once finished (or nearly).
    func startTime(for videoId: String?) -> TimeInterval? {
        guard let videoId, let saved = progress[videoId], !saved.finished, saved.position > 10 else { return nil }
        if let length = saved.length, saved.position > length - 30 { return nil }
        // A few seconds back, to pick up the thread.
        return max(0, saved.position - 3)
    }

    /// From the player, every few seconds and on pause.
    func note(position: TimeInterval, length: TimeInterval?, of videoId: String) {
        var saved = progress[videoId] ?? Progress(position: 0, length: nil, finished: false, updated: .now)
        if let length, length > 0 { saved.length = length }
        if saved.finished {
            // Back at the start after the end (the player rewinds): still finished. Listening again
            // (further in) makes it unfinished.
            guard position > 10 else { return }
            saved.finished = false
        }
        saved.position = position
        // Within the last half minute (the credits, the outro): finished.
        if let total = saved.length, position >= total - 30 { saved.finished = true }
        saved.updated = .now
        progress[videoId] = saved
        unsaved = true
        saveIfNeeded()
    }

    func noteLength(_ length: TimeInterval, of videoId: String) {
        var saved = progress[videoId] ?? Progress(position: 0, length: nil, finished: false, updated: .now)
        saved.length = length
        progress[videoId] = saved
        unsaved = true
    }

    func setFinished(_ finished: Bool, _ videoId: String) {
        var saved = progress[videoId] ?? Progress(position: 0, length: nil, finished: false, updated: .now)
        saved.finished = finished
        if !finished { saved.position = 0 }
        saved.updated = .now
        progress[videoId] = saved
        save()
    }

    // MARK: Saving

    private func saveIfNeeded(force: Bool = false) {
        guard unsaved, force || Date.now.timeIntervalSince(lastSave) >= Self.saveInterval else { return }
        save()
    }

    private func save() {
        unsaved = false
        lastSave = .now
        let saved = Saved(followed: followed, recent: recent, progress: progress)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: Self.file, options: .atomic)
    }
}
