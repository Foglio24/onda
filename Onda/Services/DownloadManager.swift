import Combine
import Foundation

/// Saves songs (audio plus cover art) inside the app for offline listening.
/// Downloads go through a queue, three at a time, so a whole playlist can be saved in one tap.
@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    /// Progress (0...1) of queued and running downloads, by video ID.
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var lastError: String?
    /// Bumped whenever files change, so views asking `isDownloaded` refresh.
    @Published private(set) var revision = 0

    private static let maxConcurrent = 3
    private var waiting: [Track] = []
    private var running = 0

    private init() {}

    func isDownloaded(_ track: Track) -> Bool {
        Storage.localAudio(for: track) != nil
    }

    func isQueued(_ track: Track) -> Bool {
        track.videoId.map { progress[$0] != nil } ?? false
    }

    func download(_ track: Track) {
        downloadAll([track])
    }

    /// Queues every song that is not downloaded yet.
    func downloadAll(_ tracks: [Track]) {
        lastError = nil
        for track in tracks {
            guard let videoId = track.videoId, progress[videoId] == nil, !isDownloaded(track) else { continue }
            progress[videoId] = 0
            waiting.append(track)
        }
        pump()
    }

    /// Stops the songs that have not started yet.
    func cancelWaiting(in tracks: [Track]? = nil) {
        let ids = tracks.map { Set($0.compactMap(\.videoId)) }
        waiting.removeAll { track in
            guard let videoId = track.videoId, ids?.contains(videoId) ?? true else { return false }
            progress[videoId] = nil
            return true
        }
    }

    func remove(_ track: Track) {
        deleteFiles(of: track)
        Library.shared.removeDownload(track)
        revision += 1
    }

    func removeAll(_ tracks: [Track]? = nil) {
        for track in tracks ?? Library.shared.downloads {
            deleteFiles(of: track)
            Library.shared.removeDownload(track)
        }
        revision += 1
    }

    var totalSize: Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Storage.downloads, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    /// "Opus · 160 kbps" for a downloaded song, as recorded when it was saved.
    nonisolated static func formatLabel(for track: Track) -> String? {
        guard let videoId = track.videoId else { return nil }
        let labels = UserDefaults.standard.dictionary(forKey: Preferences.downloadFormats) as? [String: String]
        return labels?[videoId]
    }

    // MARK: Queue

    private func pump() {
        while running < Self.maxConcurrent, !waiting.isEmpty {
            let track = waiting.removeFirst()
            running += 1
            Task {
                await self.perform(track)
                self.running -= 1
                self.pump()
            }
        }
    }

    private func perform(_ track: Track) async {
        guard let videoId = track.videoId else { return }
        let destination = Storage.audioFile(for: videoId)
        do {
            let quality = Preferences.downloadQualitySetting
            let tooLongForOpus = (track.duration ?? 0) > Preferences.opusLengthLimit
            var stream = try await StreamResolver.shared.stream(for: videoId, quality: tooLongForOpus ? .high : quality)
            // Opus still needs decoding once the transfer is done: keep some of the bar for it.
            let scale = stream.format == .opus ? 0.85 : 1.0
            let report: @Sendable (Double) -> Void = { value in
                Task { @MainActor in
                    // Ignore late updates arriving after the download finished.
                    if DownloadManager.shared.progress[videoId] != nil {
                        DownloadManager.shared.progress[videoId] = value * scale
                    }
                }
            }
            if stream.format == .opus {
                // Lossless copy of YouTube's best stream: decode the Opus and save it as Apple Lossless.
                let webm = Storage.downloads.appending(path: ".\(videoId).webm")
                defer { try? FileManager.default.removeItem(at: webm) }
                do {
                    try await Self.transfer(stream.url, to: webm, progress: report)
                    try await Self.decode(webm: webm, to: destination)
                } catch {
                    stream = try await StreamResolver.shared.stream(for: videoId, quality: .high)
                    try await Self.transfer(stream.url, to: destination, progress: report)
                }
            } else {
                try await Self.transfer(stream.url, to: destination, progress: report)
            }
            if let artwork = track.largeArtworkURL,
               let result = try? await URLSession.shared.data(from: artwork) {
                try? result.0.write(to: Storage.artworkFile(for: videoId))
            }
            Self.recordFormat(stream.label, for: videoId)
            Library.shared.addDownload(track)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            lastError = error.localizedDescription
        }
        progress[videoId] = nil
        revision += 1
    }

    private func deleteFiles(of track: Track) {
        guard let videoId = track.videoId else { return }
        try? FileManager.default.removeItem(at: Storage.audioFile(for: videoId))
        try? FileManager.default.removeItem(at: Storage.artworkFile(for: videoId))
    }

    private static func recordFormat(_ label: String, for videoId: String) {
        var labels = UserDefaults.standard.dictionary(forKey: Preferences.downloadFormats) as? [String: String] ?? [:]
        labels[videoId] = label
        UserDefaults.standard.set(labels, forKey: Preferences.downloadFormats)
    }

    nonisolated private static func decode(webm: URL, to destination: URL) async throws {
        try await Task.detached(priority: .utility) {
            try OpusPipeline.transcode(webm: webm, to: destination)
        }.value
    }

    /// Downloads `url` to `destination`, reporting progress along the way.
    nonisolated static func transfer(_ url: URL, to destination: URL,
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
