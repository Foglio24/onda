import Combine
import Foundation
import SwiftUI

/// Liked songs, playlists, listening history and downloaded songs, saved as JSON files.
@MainActor
final class Library: ObservableObject {
    static let shared = Library()

    @Published private(set) var liked: [Track]
    @Published private(set) var playlists: [Playlist]
    @Published private(set) var history: [Track]
    @Published private(set) var downloads: [Track]

    private static let historyLimit = 200

    private init() {
        liked = Self.load("liked")
        playlists = Self.load("playlists")
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

    func moveLiked(fromOffsets source: IndexSet, toOffset destination: Int) {
        liked.move(fromOffsets: source, toOffset: destination)
        Self.save(liked, as: "liked")
    }

    // MARK: Playlists

    func playlist(_ id: UUID) -> Playlist? {
        playlists.first { $0.id == id }
    }

    @discardableResult
    func createPlaylist(named name: String, tracks: [Track] = []) -> Playlist {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let playlist = Playlist(id: UUID(), name: trimmed.isEmpty ? "Nuova playlist" : trimmed,
                                tracks: tracks.uniqued(), createdAt: .now)
        playlists.insert(playlist, at: 0)
        savePlaylists()
        return playlist
    }

    func renamePlaylist(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updatePlaylist(id) { $0.name = trimmed }
    }

    func deletePlaylist(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        savePlaylists()
    }

    func deletePlaylists(atOffsets offsets: IndexSet) {
        playlists.remove(atOffsets: offsets)
        savePlaylists()
    }

    func contains(_ track: Track, in id: UUID) -> Bool {
        playlist(id)?.tracks.contains { $0.id == track.id } ?? false
    }

    /// Adds the song to the playlist, or removes it if it is already there.
    func toggle(_ track: Track, in id: UUID) {
        updatePlaylist(id) { playlist in
            if let position = playlist.tracks.firstIndex(where: { $0.id == track.id }) {
                playlist.tracks.remove(at: position)
            } else {
                playlist.tracks.append(track)
            }
        }
    }

    func removeTracks(atOffsets offsets: IndexSet, from id: UUID) {
        updatePlaylist(id) { $0.tracks.remove(atOffsets: offsets) }
    }

    func moveTracks(fromOffsets source: IndexSet, toOffset destination: Int, in id: UUID) {
        updatePlaylist(id) { $0.tracks.move(fromOffsets: source, toOffset: destination) }
    }

    private func updatePlaylist(_ id: UUID, _ change: (inout Playlist) -> Void) {
        guard let position = playlists.firstIndex(where: { $0.id == id }) else { return }
        change(&playlists[position])
        savePlaylists()
    }

    private func savePlaylists() {
        Self.save(playlists, as: "playlists")
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

    private static func load<T: Decodable>(_ name: String) -> [T] {
        guard let data = try? Data(contentsOf: fileURL(name)) else { return [] }
        return (try? JSONDecoder().decode([T].self, from: data)) ?? []
    }

    private static func save<T: Encodable>(_ items: [T], as name: String) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL(name), options: .atomic)
    }
}
