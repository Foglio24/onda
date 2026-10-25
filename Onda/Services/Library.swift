import Combine
import Foundation

/// Liked songs, listening history and the list of downloaded songs, saved as JSON files.
@MainActor
final class Library: ObservableObject {
    static let shared = Library()

    @Published private(set) var liked: [Track]
    @Published private(set) var history: [Track]
    @Published private(set) var downloads: [Track]

    private static let historyLimit = 200

    private init() {
        liked = Self.load("liked")
        history = Self.load("history")
        downloads = Self.load("downloads")
    }

    // MARK: Liked

    func isLiked(_ track: Track) -> Bool {
        liked.contains { $0.id == track.id }
    }

    func toggleLike(_ track: Track) {
        let nowLiked: Bool
        if let position = liked.firstIndex(where: { $0.id == track.id }) {
            liked.remove(at: position)
            nowLiked = false
        } else {
            liked.insert(track, at: 0)
            nowLiked = true
        }
        Self.save(liked, as: "liked")
        Task { await LastFM.shared.love(track, loved: nowLiked) }
    }

    // MARK: History

    func recordPlay(_ track: Track) {
        history.removeAll { $0.id == track.id }
        history.insert(track, at: 0)
        if history.count > Self.historyLimit {
            history.removeLast(history.count - Self.historyLimit)
        }
        Self.save(history, as: "history")
    }

    func removeFromHistory(_ tracks: [Track]) {
        let ids = Set(tracks.map(\.id))
        history.removeAll { ids.contains($0.id) }
        Self.save(history, as: "history")
    }

    func clearHistory() {
        history = []
        Self.save(history, as: "history")
    }

    // MARK: Downloads

    func addDownload(_ track: Track) {
        downloads.removeAll { $0.id == track.id }
        downloads.insert(track, at: 0)
        Self.save(downloads, as: "downloads")
    }

    func removeDownload(_ track: Track) {
        downloads.removeAll { $0.id == track.id }
        Self.save(downloads, as: "downloads")
    }

    func clearDownloads() {
        downloads = []
        Self.save(downloads, as: "downloads")
    }

    // MARK: Persistence

    private static func fileURL(_ name: String) -> URL {
        Storage.support.appending(path: "\(name).json")
    }

    private static func load(_ name: String) -> [Track] {
        guard let data = try? Data(contentsOf: fileURL(name)) else { return [] }
        return (try? JSONDecoder().decode([Track].self, from: data)) ?? []
    }

    private static func save(_ tracks: [Track], as name: String) {
        guard let data = try? JSONEncoder().encode(tracks) else { return }
        try? data.write(to: fileURL(name), options: .atomic)
    }
}
