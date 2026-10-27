import AVFoundation
import Foundation
import os

/// AutoMix's analyses of songs (`TrackAnalyzer`), made from their local files and kept on disk, so
/// each file is analysed once.
actor AutoMixLibrary {
    static let shared = AutoMixLibrary()

    /// Songs longer than this aren't analysed (hour-long mixes would take too much memory).
    static let lengthLimit: TimeInterval = 15 * 60
    private static let fileLimit = 500

    private static let directory: URL = {
        let url = URL.cachesDirectory.appending(path: "AutoMix", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private var recent: [String: TrackAnalysis] = [:]
    private var running: [String: Task<TrackAnalysis?, Never>] = [:]

    /// The analysis of a song's file, made now unless it was made before.
    func analysis(of file: URL) async -> TrackAnalysis? {
        let key = file.deletingPathExtension().lastPathComponent
        if let known = recent[key] { return known }
        let saved = Self.directory.appending(path: "\(key).json")
        if let data = try? Data(contentsOf: saved),
           let analysis = try? JSONDecoder().decode(TrackAnalysis.self, from: data),
           analysis.version == TrackAnalysis.currentVersion {
            remember(analysis, key: key)
            return analysis
        }
        if let task = running[key] { return await task.value }
        let task = Task.detached(priority: .utility) { () -> TrackAnalysis? in
            guard let samples = try? await AutoMixDecoder.samples(of: file) else { return nil }
            return TrackAnalyzer.analyze(samples, sampleRate: TrackAnalyzer.sampleRate)
        }
        running[key] = task
        let analysis = await task.value
        running[key] = nil
        guard let analysis else { return nil }
        remember(analysis, key: key)
        if let data = try? JSONEncoder().encode(analysis) {
            try? data.write(to: saved, options: .atomic)
            Self.prune()
        }
        return analysis
    }

    private func remember(_ analysis: TrackAnalysis, key: String) {
        if recent.count >= 20 { recent.removeAll() }
        recent[key] = analysis
    }

    /// Keeps the most recently made analyses.
    private static func prune() {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > fileLimit else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
        for (file, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(fileLimit) {
            try? manager.removeItem(at: file)
        }
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

/// The bass cut AutoMix moves while two songs play together, read by the song's audio tap
/// (see `EqualizerProcessor`): 0 leaves the bass alone, 1 takes it out.
final class TransitionFilter: @unchecked Sendable {
    private let cut = OSAllocatedUnfairLock(initialState: Float(0))

    func set(_ value: Float) {
        let clamped = max(0, min(1, value))
        cut.withLock { $0 = clamped }
    }

    /// Nil while it is being changed: the audio thread keeps the previous value instead of waiting.
    func valueIfAvailable() -> Float? {
        cut.withLockIfAvailable { $0 }
    }
}

extension AVPlayerItem {
    private static var transitionFilterKey: UInt8 = 0

    /// The bass cut on this item's audio, when its mix has one (AutoMix on).
    var transitionFilter: TransitionFilter? {
        get { objc_getAssociatedObject(self, &Self.transitionFilterKey) as? TransitionFilter }
        set { objc_setAssociatedObject(self, &Self.transitionFilterKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}
