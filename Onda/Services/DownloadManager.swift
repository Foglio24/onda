import Combine
import Foundation

/// What a song's row shows about its download, like the Music app.
enum DownloadState: Equatable {
    case none
    case waiting
    /// Received so far, from 0 to 1.
    case downloading(Double)
    case downloaded
}

/// Saves songs (audio plus cover art) inside the app for offline listening.
/// Downloads go through a queue, three at a time, so a whole playlist can be saved in one tap.
@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    /// Progress (0...1), keyed by video ID or the original identity while resolving Last.fm.
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var lastError: String?
    /// Bumped whenever files change, so views asking `isDownloaded` refresh.
    @Published private(set) var revision = 0 {
        didSet { downloadedIDs = nil }
    }
    /// Songs downloading right now and songs waiting their turn, in order.
    @Published private(set) var active: [Track] = []
    @Published private(set) var waiting: [Track] = []
    /// Songs queued since the queue was last empty, and how many of them are done,
    /// for the overall progress.
    @Published private(set) var batchTotal = 0
    @Published private(set) var batchDone = 0

    private static let maxConcurrent = 3
    private var activeVideoIDs = Set<String>()
    private var progressTokens: [String: UUID] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var running = 0
    /// Video IDs that have a downloaded file, read from the folder once after each change
    /// instead of asking the file system again for every row on screen.
    private var downloadedIDs: Set<String>?

    private init() {
        // Pieces of downloads interrupted when the app was closed (".<id>.webm", ".<uuid>.part").
        let folder = Storage.downloads
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix(".") {
            try? FileManager.default.removeItem(at: folder.appending(path: name))
        }
    }

    func isDownloaded(_ track: Track) -> Bool {
        guard let videoId = (Library.shared.resolvedTrack(matching: track) ?? track).videoId else { return false }
        return downloadedFiles.contains(videoId)
    }

    private var downloadedFiles: Set<String> {
        if let downloadedIDs { return downloadedIDs }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Storage.downloads.path)) ?? []
        let ids = Set(names.compactMap { name in
            name.hasSuffix(".m4a") && !name.hasPrefix(".") ? String(name.dropLast(4)) : nil
        })
        downloadedIDs = ids
        return ids
    }

    /// Waiting, downloading (and how far) or downloaded.
    func state(of track: Track) -> DownloadState {
        if let value = progress[track.videoId ?? track.id] {
            return active.contains { $0.isSameRecording(as: track) } ? .downloading(value) : .waiting
        }
        if isDownloaded(track) { return .downloaded }
        return isQueued(track) ? .waiting : .none
    }

    struct CollectionStatus {
        var total = 0
        var saved = 0
        /// Waiting or downloading.
        var inProgress = 0
        /// Saved songs plus the received part of those downloading, from 0 to 1.
        var fraction: Double = 0
    }

    /// How much of an album or playlist is on the iPhone.
    func status(of tracks: [Track]) -> CollectionStatus {
        var status = CollectionStatus(total: tracks.count)
        var done = 0.0
        for track in tracks {
            switch state(of: track) {
            case .downloaded:
                status.saved += 1
                done += 1
            case .downloading(let value):
                status.inProgress += 1
                done += value
            case .waiting:
                status.inProgress += 1
            case .none:
                break
            }
        }
        status.fraction = tracks.isEmpty ? 0 : done / Double(tracks.count)
        return status
    }

    /// Overall progress of the songs queued since the queue was last empty, from 0 to 1.
    var batchFraction: Double {
        guard batchTotal > 0 else { return 0 }
        let received = active.reduce(0.0) { $0 + (progress[$1.videoId ?? $1.id] ?? 0) }
        return min(1, (Double(batchDone) + received) / Double(batchTotal))
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
        if active.isEmpty, waiting.isEmpty {
            batchTotal = 0
            batchDone = 0
        }
        for track in tracks.uniqued() {
            guard !isQueued(track), !isDownloaded(track) else { continue }
            progress[track.videoId ?? track.id] = 0
            waiting.append(track)
            batchTotal += 1
        }
        pump()
    }

    /// Stops the songs that have not started yet.
    func cancelWaiting(in tracks: [Track]? = nil) {
        let before = waiting.count
        waiting.removeAll { track in
            guard tracks?.contains(where: { $0.isSameRecording(as: track) }) ?? true else { return false }
            progress[track.videoId ?? track.id] = nil
            return true
        }
        batchTotal -= before - waiting.count
    }

    /// Stops these songs' downloads (all of them when nil), whether waiting or already running:
    /// partial files are deleted, and no error is shown.
    func cancel(_ tracks: [Track]? = nil) {
        cancelWaiting(in: tracks)
        for track in active where tracks?.contains(where: { $0.isSameRecording(as: track) }) ?? true {
            tasks[track.id]?.cancel()
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
            tasks[track.id] = Task {
                await self.perform(track)
                // A stopped song leaves the batch instead of counting as done.
                if Task.isCancelled { self.batchTotal -= 1 } else { self.batchDone += 1 }
                self.tasks[track.id] = nil
                self.active.removeAll { $0.id == track.id }
                self.running -= 1
                if self.active.isEmpty, self.waiting.isEmpty {
                    self.batchTotal = 0
                    self.batchDone = 0
                }
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
            let requestedQuality = Preferences.downloadQualitySetting
            let quality = requestedQuality.usesOpus && !EnergyPolicy.current.allowsAudioConversion
                ? AudioQuality.high : requestedQuality
            let tooLongForOpus = (playable.duration ?? 0) > Preferences.opusLengthLimit
            var stream = try await StreamResolver.shared.stream(for: videoId, quality: tooLongForOpus ? .high : quality)
            try Task.checkCancellation()
            // The thermal budget may have changed while YouTube resolved the URL.
            if stream.format == .opus && !EnergyPolicy.current.allowsAudioConversion {
                stream = try await StreamResolver.shared.stream(for: videoId, quality: .high)
                try Task.checkCancellation()
            }
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
                    try Task.checkCancellation()
                    stream = try await StreamResolver.shared.stream(for: videoId, quality: .high)
                    try await Self.transfer(stream.url, to: audioDestination, progress: report)
                }
            } else {
                try await Self.transfer(stream.url, to: audioDestination, progress: report)
            }
            // Stopped while the last part was decoding: drop the file instead of keeping it.
            try Task.checkCancellation()
            if let artwork = playable.largeArtworkURL,
               let result = try? await URLSession.shared.data(from: artwork) {
                try? result.0.write(to: Storage.artworkFile(for: videoId))
            }
            Self.recordFormat(stream.label, for: videoId)
            Library.shared.addDownload(playable)
        } catch {
            if let destination { try? FileManager.default.removeItem(at: destination) }
            // Stopped by the user: not a failure.
            if !Task.isCancelled { lastError = "\(track.title): \(error.localizedDescription)" }
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
