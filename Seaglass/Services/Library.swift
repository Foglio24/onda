import Combine
import Foundation
import SwiftUI
import UIKit

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
        let savedLiked: [Track] = Self.load("liked")
        let savedPlaylists: [Playlist] = Self.load("playlists")
        let savedHistory: [Track] = Self.load("history")
        let savedDownloads: [Track] = Self.load("downloads")
        liked = savedLiked.uniqued()
        playlists = savedPlaylists.map { playlist in
            var copy = playlist
            copy.tracks = copy.tracks.uniqued()
            return copy
        }
        history = savedHistory.uniqued()
        downloads = savedDownloads.uniqued()
        if liked != savedLiked { Self.save(liked, as: "liked") }
        if playlists != savedPlaylists { savePlaylists() }
        if history != savedHistory { Self.save(history, as: "history") }
        if downloads != savedDownloads { Self.save(downloads, as: "downloads") }
    }

    /// Updates every saved occurrence when a Last.fm song becomes playable.
    @discardableResult
    func reconcile(original: Track, resolved: Track) -> Track {
        let canonical = resolved.retainingIdentity(of: original)
        let updatedLiked = liked.reconciling(original: original, resolved: canonical)
        let updatedHistory = history.reconciling(original: original, resolved: canonical)
        let updatedDownloads = downloads.reconciling(original: original, resolved: canonical)
        let updatedPlaylists = playlists.map { playlist in
            var copy = playlist
            copy.tracks = copy.tracks.reconciling(original: original, resolved: canonical)
            return copy
        }
        if updatedLiked != liked {
            liked = updatedLiked
            Self.save(liked, as: "liked")
        }
        if updatedHistory != history {
            history = updatedHistory
            Self.save(history, as: "history")
        }
        if updatedDownloads != downloads {
            downloads = updatedDownloads
            Self.save(downloads, as: "downloads")
        }
        if updatedPlaylists != playlists {
            playlists = updatedPlaylists
            savePlaylists()
        }
        return canonical
    }

    /// Reuses a previously resolved identity for older Last.fm rows still on screen.
    func resolvedTrack(matching track: Track) -> Track? {
        if track.videoId != nil { return track }
        // Searched list by list, without copying the whole library for every row on screen.
        let matches: (Track) -> Bool = { $0.videoId != nil && $0.isSameRecording(as: track) }
        return liked.first(where: matches) ?? history.first(where: matches)
            ?? downloads.first(where: matches)
            ?? playlists.lazy.compactMap { $0.tracks.first(where: matches) }.first
    }

    // MARK: Liked

    func isLiked(_ track: Track) -> Bool {
        liked.contains { $0.isSameRecording(as: track) }
    }

    func toggleLike(_ track: Track) {
        let nowLiked: Bool
        let target = resolvedTrack(matching: track) ?? track
        if liked.contains(where: { $0.isSameRecording(as: target) }) {
            liked.removeAll { $0.isSameRecording(as: target) }
            nowLiked = false
        } else {
            liked.insert(target, at: 0)
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
    func createPlaylist(named name: String, tracks: [Track] = [], importReport: PlaylistImportReport? = nil) -> Playlist {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var playlist = Playlist(id: UUID(), name: trimmed.isEmpty ? String(localized: "Nuova playlist") : trimmed,
                                tracks: tracks.uniqued(), createdAt: .now)
        playlist.importReport = importReport
        playlists.insert(playlist, at: 0)
        savePlaylists()
        return playlist
    }

    @discardableResult
    func resolveImportedTrack(_ entryID: UUID, in playlistID: UUID, with track: Track) -> PlaylistImportReport.Resolution {
        var result: PlaylistImportReport.Resolution = .missing
        updatePlaylist(playlistID) { playlist in
            guard var report = playlist.importReport else { return }
            result = report.resolve(entryID, with: track, in: &playlist.tracks)
            playlist.importReport = report
        }
        return result
    }

    func ignoreImportedTrack(_ entryID: UUID, in playlistID: UUID) {
        updatePlaylist(playlistID) { playlist in
            guard var report = playlist.importReport else { return }
            report.ignore(entryID)
            playlist.importReport = report
        }
    }

    func restoreImportedTrack(_ entryID: UUID, in playlistID: UUID) {
        updatePlaylist(playlistID) { playlist in
            guard var report = playlist.importReport else { return }
            report.restore(entryID)
            playlist.importReport = report
        }
    }

    func renamePlaylist(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updatePlaylist(id) { $0.name = trimmed }
    }

    func deletePlaylist(_ id: UUID) {
        Self.deleteFile(playlist(id)?.customCoverURL)
        playlists.removeAll { $0.id == id }
        savePlaylists()
    }

    func deletePlaylists(atOffsets offsets: IndexSet) {
        for position in offsets { Self.deleteFile(playlists[position].customCoverURL) }
        playlists.remove(atOffsets: offsets)
        savePlaylists()
    }

    /// Saves a photo as the playlist cover, resized to at most 1200 px.
    func setCover(_ imageData: Data, for id: UUID) {
        guard let image = UIImage(data: imageData) else { return }
        let side = min(1200, max(image.size.width, image.size.height))
        let scale = side / max(image.size.width, image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpeg = resized.jpegData(compressionQuality: 0.88) else { return }
        // A new name each time, so cached images of the old cover are never shown.
        let fileName = "\(id.uuidString)-\(UUID().uuidString.prefix(8)).jpg"
        guard (try? jpeg.write(to: Storage.covers.appending(path: fileName), options: .atomic)) != nil else { return }
        let previous = playlist(id)?.customCoverURL
        updatePlaylist(id) { $0.coverFile = fileName }
        Self.deleteFile(previous)
    }

    func removeCover(for id: UUID) {
        Self.deleteFile(playlist(id)?.customCoverURL)
        updatePlaylist(id) { $0.coverFile = nil }
    }

    private static func deleteFile(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func contains(_ track: Track, in id: UUID) -> Bool {
        playlist(id)?.tracks.contains { $0.isSameRecording(as: track) } ?? false
    }

    /// Adds the song to the playlist, or removes it if it is already there.
    func toggle(_ track: Track, in id: UUID) {
        let target = resolvedTrack(matching: track) ?? track
        updatePlaylist(id) { playlist in
            if playlist.tracks.contains(where: { $0.isSameRecording(as: target) }) {
                playlist.tracks.removeAll { $0.isSameRecording(as: target) }
            } else {
                playlist.tracks.append(target)
            }
        }
    }

    func removeTracks(atOffsets offsets: IndexSet, from id: UUID) {
        updatePlaylist(id) { $0.tracks.remove(atOffsets: offsets) }
    }

    func moveTracks(fromOffsets source: IndexSet, toOffset destination: Int, in id: UUID) {
        updatePlaylist(id) { $0.tracks.move(fromOffsets: source, toOffset: destination) }
    }

    // MARK: Mix

    func setMixEnabled(_ enabled: Bool, for id: UUID) {
        updatePlaylist(id) { playlist in
            var mix = playlist.mix ?? PlaylistMix()
            mix.enabled = enabled
            playlist.mix = mix
        }
    }

    /// Saves a transition of the playlist's Mix (nil goes back to automatic).
    func setMixDesign(_ design: MixDesign?, from: Track, to: Track, in id: UUID) {
        updatePlaylist(id) { playlist in
            var mix = playlist.mix ?? PlaylistMix()
            mix.transitions[PlaylistMix.key(from: from.id, to: to.id)] = design
            playlist.mix = mix
        }
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
        history.removeAll { $0.isSameRecording(as: track) }
        history.insert(track, at: 0)
        if history.count > Self.historyLimit {
            history.removeLast(history.count - Self.historyLimit)
        }
        Self.save(history, as: "history")
    }

    func removeFromHistory(_ tracks: [Track]) {
        history.removeAll { item in tracks.contains { item.isSameRecording(as: $0) } }
        Self.save(history, as: "history")
        // What the recommendations learned from these songs goes too.
        ListeningLog.shared.remove(Set(tracks.compactMap(\.videoId)))
    }

    func clearHistory() {
        history = []
        Self.save(history, as: "history")
        ListeningLog.shared.remove()
    }

    // MARK: Downloads

    func addDownload(_ track: Track) {
        downloads.removeAll { $0.isSameRecording(as: track) }
        downloads.insert(track, at: 0)
        Self.save(downloads, as: "downloads")
    }

    func removeDownload(_ track: Track) {
        downloads.removeAll { $0.isSameRecording(as: track) }
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
