import Combine
import Foundation

/// Saves songs (audio plus cover art) inside the app for offline listening.
/// Downloads go through a queue, three at a time, so a whole playlist can be saved in one tap.
@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    /// Progress (0...1), keyed by video ID or the original identity while resolving Last.fm.
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var lastError: String?
    /// Bumped whenever files change, so views asking `isDownloaded` refresh.
    @Published private(set) var revision = 0

    private static let maxConcurrent = 3
    private var waiting: [Track] = []
    private var active: [Track] = []
    private var activeVideoIDs = Set<String>()
    private var progressTokens: [String: UUID] = [:]
    private var running = 0

    private init() {}

    func isDownloaded(_ track: Track) -> Bool {
        Storage.localAudio(for: Library.shared.resolvedTrack(matching: track) ?? track) != nil
    }

    func isQueued(_ track: Track) -> Bool {
        progress[track.videoId ?? track.id] != nil
            || (waiting + active).contains { $0.isSameRecording(as: track) }
    }

    func dismissError() {
        lastError = nil
    }

    func download(_ track: Track) {
        downloadAll([track])
    }

    /// Queues every song that is not downloaded yet.
    func downloadAll(_ tracks: [Track]) {
        lastError = nil
        for track in tracks.uniqued() {
            guard !isQueued(track), !isDownloaded(track) else { continue }
            progress[track.videoId ?? track.id] = 0
            waiting.append(track)
        }
        pump()
    }

    /// Stops the songs that have not started yet.
    func cancelWaiting(in tracks: [Track]? = nil) {
        waiting.removeAll { track in
            guard tracks?.contains(where: { $0.isSameRecording(as: track) }) ?? true else { return false }
            progress[track.videoId ?? track.id] = nil
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
            active.append(track)
            Task {
                await self.perform(track)
                self.active.removeAll { $0.id == track.id }
                self.running -= 1
                self.pump()
            }
        }
    }

    private func perform(_ track: Track) async {
        let requestKey = track.videoId ?? track.id
        let progressToken = UUID()
        var activeVideoID: String?
        var destination: URL?
        defer {
            progress[requestKey] = nil
            if let activeVideoID {
                progress[activeVideoID] = nil
                progressTokens[activeVideoID] = nil
                activeVideoIDs.remove(activeVideoID)
            }
            revision += 1
        }
        do {
            var playable = Library.shared.resolvedTrack(matching: track) ?? track
            if playable.videoId == nil {
                let resolved = try await InnerTube.shared.resolve(playable)
                playable = Library.shared.reconcile(original: track, resolved: resolved)
            }
            guard let videoId = playable.videoId else { throw InnerTubeError.notFound }
            // Reserve the video before inspecting its file: an active decoder may
            // already have created the destination without finishing its contents.
            guard activeVideoIDs.insert(videoId).inserted else { return }
            activeVideoID = videoId
            progressTokens[videoId] = progressToken
            if Storage.localAudio(for: playable) != nil {
                Library.shared.addDownload(playable)
                return
            }
            progress[videoId] = progress.removeValue(forKey: requestKey) ?? 0
            let audioDestination = Storage.audioFile(for: videoId)
            destination = audioDestination
            let quality = Preferences.downloadQualitySetting
            let tooLongForOpus = (playable.duration ?? 0) > Preferences.opusLengthLimit
            var stream = try await StreamResolver.shared.stream(for: videoId, quality: tooLongForOpus ? .high : quality)
            // Opus still needs decoding once the transfer is done: keep some of the bar for it.
            let scale = stream.format == .opus ? 0.85 : 1.0
            let report: @Sendable (Double) -> Void = { value in
                Task { @MainActor in
                    // Ignore late updates arriving after the download finished.
                    if DownloadManager.shared.progressTokens[videoId] == progressToken {
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
                    try await Self.decode(webm: webm, to: audioDestination)
                } catch {
                    stream = try await StreamResolver.shared.stream(for: videoId, quality: .high)
                    try await Self.transfer(stream.url, to: audioDestination, progress: report)
                }
            } else {
                try await Self.transfer(stream.url, to: audioDestination, progress: report)
            }
            if let artwork = playable.largeArtworkURL,
               let result = try? await URLSession.shared.data(from: artwork) {
                try? result.0.write(to: Storage.artworkFile(for: videoId))
            }
            Self.recordFormat(stream.label, for: videoId)
            Library.shared.addDownload(playable)
        } catch {
            if let destination { try? FileManager.default.removeItem(at: destination) }
            lastError = "\(track.title): \(error.localizedDescription)"
        }
    }

    private func deleteFiles(of track: Track) {
        guard let videoId = (Library.shared.resolvedTrack(matching: track) ?? track).videoId else { return }
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
        try await ChunkedDownload.fetch(url, to: destination, progress: progress)
    }
}
