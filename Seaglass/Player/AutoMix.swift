import AVFoundation
import Foundation

/// AutoMix's analyses of songs (`TrackAnalyzer`) and of their voices (`VocalDetector`), made from
/// their local files and kept on disk, so each file is analysed once.
actor AutoMixLibrary {
    static let shared = AutoMixLibrary()

    /// Songs longer than this aren't analysed (hour-long mixes would take too much memory).
    static let lengthLimit: TimeInterval = 15 * 60
    private static let fileLimit = 500

    private static let directory: URL = {
        // On a Mac (not sandboxed, see Storage) in the app's own caches folder.
        let caches = ProcessInfo.processInfo.isMacCatalystApp
            ? URL.cachesDirectory.appending(path: "com.onda.player", directoryHint: .isDirectory) : URL.cachesDirectory
        let url = caches.appending(path: "AutoMix", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// The name a file's analyses are kept under, when it isn't its own: the app gives the user's own
    /// songs one (their file names repeat), set once at launch (see `LocalMusic`).
    nonisolated(unsafe) static var customKey: (@Sendable (URL) -> String?)?

    /// The name a file's analyses are kept under: its own, which for a download or a cached file is its
    /// song's ID.
    static func cacheKey(for file: URL) -> String {
        customKey?(file) ?? file.deletingPathExtension().lastPathComponent
    }

    private var recent: [String: TrackAnalysis] = [:]
    private var recentVocals: [String: VocalActivity] = [:]
    private var running: [String: Task<TrackAnalysis?, Never>] = [:]

    /// The analysis of a song's file, made now unless it was made before. `beats`: with Beat This!'s
    /// beats and downbeats (see `BeatThis`), added to an analysis made without them when the model is
    /// there and the energy allows it (the tempo panel doesn't wait for them).
    /// `priority`: higher when someone waits for it (the tempo panel's BPM).
    func analysis(of file: URL, priority: TaskPriority = .utility, beats: Bool = true) async -> TrackAnalysis? {
        let key = Self.cacheKey(for: file)
        var known = recent[key]
        let saved = Self.directory.appending(path: "\(key).json")
        if known == nil, let data = try? Data(contentsOf: saved),
           let analysis = try? JSONDecoder().decode(TrackAnalysis.self, from: data),
           analysis.version == TrackAnalysis.currentVersion {
            remember(analysis, key: key)
            known = analysis
        }
        let wantsBeats = beats && BeatThis.isBundled && EnergyPolicy.current.allowsAudioConversion
        if let known, !(wantsBeats && known.modelBeats == nil) { return known }
        if let task = running[key] {
            let analysis = await task.value
            if let analysis, !(wantsBeats && analysis.modelBeats == nil) { return analysis }
        }
        let base = known
        let task = Task.detached(priority: priority) { () -> TrackAnalysis? in
            guard let samples = try? await AutoMixDecoder.samples(of: file) else { return base }
            guard var analysis = base ?? TrackAnalyzer.analyze(samples, sampleRate: TrackAnalyzer.sampleRate) else { return nil }
            if wantsBeats, !Task.isCancelled, let model = BeatThis.shared {
                // A model that fails on this song isn't tried on it again: no beats, as if it found none.
                let found = (try? model.analyze(samples)) ?? BeatThis.Result(beats: [], downbeats: [], downbeatLogits: [])
                analysis.modelBeats = found.beats.map { Float($0) }
                analysis.modelDownbeats = found.downbeats.map { Float($0) }
                analysis.modelDownbeatLogits = found.downbeatLogits
            }
            return analysis
        }
        running[key] = task
        let analysis = await task.value
        running[key] = nil
        guard let analysis else { return nil }
        remember(analysis, key: key)
        if analysis != known, let data = try? JSONEncoder().encode(analysis) {
            try? data.write(to: saved, options: .atomic)
            Self.prune()
        }
        return analysis
    }

    /// The voices of a part of a song's file (its start or its end, see `VocalDetector`), measured
    /// now unless they were before; nil when they can't be (no model, energy saving, cancelled).
    /// Cancelling the caller stops the measuring.
    func vocals(_ part: VocalDetector.Part, of file: URL, analysis: TrackAnalysis,
                separate: @escaping VocalDetector.Separate) async -> VocalActivity? {
        let key = Self.cacheKey(for: file)
        let saved = Self.directory.appending(path: "\(key).vocals.json")
        var activity = recentVocals[key]
        if activity == nil, let data = try? Data(contentsOf: saved),
           let decoded = try? JSONDecoder().decode(VocalActivity.self, from: data),
           decoded.version == VocalActivity.currentVersion {
            activity = decoded
        }
        let stretch = VocalDetector.range(part, of: analysis)
        if let activity, activity.covers(from: stretch.start, to: stretch.end) { return activity }
        guard let region = try? await VocalDetector.measure(part, of: file, analysis: analysis, separate: separate) else {
            return activity
        }
        var updated = recentVocals[key] ?? activity ?? VocalActivity()
        updated.regions.removeAll { $0.start >= region.start && $0.end <= region.end }
        updated.regions.append(region)
        if recentVocals.count >= 20 { recentVocals.removeAll() }
        recentVocals[key] = updated
        if let data = try? JSONEncoder().encode(updated) { try? data.write(to: saved, options: .atomic) }
        return updated
    }

    private func remember(_ analysis: TrackAnalysis, key: String) {
        if recent.count >= 20 { recent.removeAll() }
        recent[key] = analysis
    }

    /// Keeps the most recently made analyses.
    private static func prune() {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter({ $0.pathExtension == "json" }),
              files.count > 2 * fileLimit else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
        for (file, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(2 * fileLimit) {
            try? manager.removeItem(at: file)
        }
    }

    /// A new file for a rendered mix. Mixes older than a quarter of an hour are deleted: by then
    /// they have played (or never will).
    static func newMixFile() -> URL {
        let folder = directory.appending(path: "Mixes", directoryHint: .isDirectory)
        let manager = FileManager.default
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = Date.now.addingTimeInterval(-15 * 60)
        for file in (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
            let created = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if created < old { try? manager.removeItem(at: file) }
        }
        return folder.appending(path: "\(UUID().uuidString).caf")
    }

    static func clearCache() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

enum AutoMixDecoder {
    enum DecodeError: Error {
        case noAudio
        case unreadable
    }

    /// A file's audio as mono samples at `TrackAnalyzer.sampleRate`.
    static func samples(of file: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: file)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw DecodeError.noAudio }
        let duration = try await asset.load(.duration).seconds
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: TrackAnalyzer.sampleRate,
            AVNumberOfChannelsKey: 2,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw DecodeError.unreadable }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? DecodeError.unreadable }
        var samples: [Float] = []
        if duration.isFinite, duration > 0 { samples.reserveCapacity(Int(duration * TrackAnalyzer.sampleRate) + 4_096) }
        var interleaved: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let block = CMSampleBufferGetDataBuffer(buffer),
                  let format = CMSampleBufferGetFormatDescription(buffer),
                  let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { continue }
            let channels = max(1, Int(description.mChannelsPerFrame))
            let length = CMBlockBufferGetDataLength(block)
            let count = length / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            if interleaved.count < count { interleaved = [Float](repeating: 0, count: count) }
            let status = interleaved.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size,
                                           destination: bytes.baseAddress!)
            }
            guard status == noErr else { continue }
            let frames = count / channels
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels { sum += interleaved[frame * channels + channel] }
                samples.append(sum / Float(channels))
            }
        }
        guard reader.status == .completed else { throw reader.error ?? DecodeError.unreadable }
        return samples
    }
}
