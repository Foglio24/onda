import Combine
import Foundation

/// Saves songs (AAC audio plus cover art) inside the app for offline listening.
@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    /// Progress (0...1) of downloads in flight, by video ID.
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var lastError: String?
    /// Bumped whenever files change, so views asking `isDownloaded` refresh.
    @Published private(set) var revision = 0

    private init() {}

    func isDownloaded(_ track: Track) -> Bool {
        Storage.localAudio(for: track) != nil
    }

    func download(_ track: Track) {
        guard let videoId = track.videoId, progress[videoId] == nil, !isDownloaded(track) else { return }
        progress[videoId] = 0
        lastError = nil
        Task {
            do {
                let remote = try await StreamResolver.shared.audioURL(for: videoId)
                try await Self.transfer(remote, to: Storage.audioFile(for: videoId)) { value in
                    Task { @MainActor in
                        // Ignore late updates arriving after the download finished.
                        if DownloadManager.shared.progress[videoId] != nil {
                            DownloadManager.shared.progress[videoId] = value
                        }
                    }
                }
                if let artwork = track.largeArtworkURL,
                   let result = try? await URLSession.shared.data(from: artwork) {
                    try? result.0.write(to: Storage.artworkFile(for: videoId))
                }
                Library.shared.addDownload(track)
            } catch {
                try? FileManager.default.removeItem(at: Storage.audioFile(for: videoId))
                lastError = error.localizedDescription
            }
            progress[videoId] = nil
            revision += 1
        }
    }

    func remove(_ track: Track) {
        deleteFiles(of: track)
        Library.shared.removeDownload(track)
        revision += 1
    }

    func removeAll() {
        for track in Library.shared.downloads { deleteFiles(of: track) }
        Library.shared.clearDownloads()
        revision += 1
    }

    var totalSize: Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Storage.downloads, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    private func deleteFiles(of track: Track) {
        guard let videoId = track.videoId else { return }
        try? FileManager.default.removeItem(at: Storage.audioFile(for: videoId))
        try? FileManager.default.removeItem(at: Storage.artworkFile(for: videoId))
    }

    /// Downloads `url` to `destination`, reporting progress along the way.
    nonisolated private static func transfer(_ url: URL, to destination: URL,
                                             progress: @escaping @Sendable (Double) -> Void) async throws {
        var observation: NSKeyValueObservation?
        defer { observation?.invalidate() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let task = URLSession.shared.downloadTask(with: url) { temporary, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let temporary, let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }
                do {
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: temporary, to: destination)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            observation = task.progress.observe(\.fractionCompleted) { value, _ in
                progress(value.fractionCompleted)
            }
            task.resume()
        }
    }
}
