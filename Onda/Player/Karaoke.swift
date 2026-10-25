import AVFoundation
import Foundation
#if canImport(SherpaOnnxC)
import SherpaOnnxC
#endif

enum KaraokeMode: Int32, CaseIterable, Identifiable {
    case off = 0
    case noVocals = 1
    case vocalsOnly = 2

    var id: Self { self }

    var title: String {
        switch self {
        case .off: return "Normale"
        case .noVocals: return "Senza voce"
        case .vocalsOnly: return "Solo voce"
        }
    }

    var symbol: String {
        switch self {
        case .off: return "music.note"
        case .noVocals: return "mic.slash"
        case .vocalsOnly: return "music.mic"
        }
    }

    /// Volumes of the vocals and instrumental stems. `amount` 1 removes the other part completely,
    /// like the slider in Apple Music Sing.
    func gains(amount: Float) -> (vocals: Float, instrumental: Float) {
        switch self {
        case .off: return (1, 1)
        case .noVocals: return (1 - amount, 1)
        case .vocalsOnly: return (1, 1 - amount)
        }
    }
}

enum KaraokeStatus: Equatable {
    case idle
    case downloadingModel(Double)
    case preparing
    case ready
    case failed(String)
}

struct StemFiles: Sendable {
    let vocals: URL
    let instrumental: URL
}

enum KaraokeError: LocalizedError {
    case modelMissing
    case engineUnavailable
    case unreadableAudio
    case separationFailed

    var errorDescription: String? {
        switch self {
        case .modelMissing: return "Il modello AI per il karaoke non è stato scaricato."
        case .engineUnavailable: return "Il motore AI per il karaoke non è disponibile."
        case .unreadableAudio: return "Non riesco a leggere l'audio del brano."
        case .separationFailed: return "La separazione di voce e musica non è riuscita."
        }
    }
}

/// Splits a song into vocals and instrumental with an AI model (UVR MDX-Net "Voc_FT"),
/// run on the iPhone by sherpa-onnx / ONNX Runtime. Results are cached per song.
actor StemSeparator {
    static let shared = StemSeparator()

    static let modelName = "UVR-MDX-NET-Voc_FT.onnx"
    static let modelSizeLabel = "64 MB"
    private static let modelRemoteURL = URL(
        string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/source-separation-models/UVR-MDX-NET-Voc_FT.onnx")!
    private static let cacheLimit: Int64 = 800 << 20
    /// One separation at a time: the model is heavy on CPU and memory.
    private static let workQueue = DispatchQueue(label: "onda.karaoke.separation", qos: .userInitiated)

    nonisolated static var modelFile: URL { Storage.models.appending(path: modelName) }

    nonisolated static var isModelInstalled: Bool {
        FileManager.default.fileExists(atPath: modelFile.path)
    }

    /// False only if the app was built without the sherpa-onnx framework.
    nonisolated static var isEngineAvailable: Bool {
        #if canImport(SherpaOnnxC)
        return true
        #else
        return false
        #endif
    }

    private var engine: OpaquePointer?
    private var inFlight: [String: Task<StemFiles, Error>] = [:]

    // MARK: Model

    nonisolated static func downloadModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await ChunkedDownload.fetch(modelRemoteURL, to: modelFile, progress: progress)
    }

    func deleteModel() {
        releaseEngine()
        try? FileManager.default.removeItem(at: Self.modelFile)
    }

    /// Frees the model's memory; it is loaded again on the next separation.
    func releaseEngine() {
        #if canImport(SherpaOnnxC)
        if let engine { SherpaOnnxDestroyOfflineSourceSeparation(engine) }
        #endif
        engine = nil
    }

    // MARK: Stems

    nonisolated static func stemFiles(for videoId: String) -> StemFiles {
        StemFiles(vocals: Storage.stems.appending(path: "\(videoId)-vocals.m4a"),
                  instrumental: Storage.stems.appending(path: "\(videoId)-instrumental.m4a"))
    }

    nonisolated static func cachedStems(for videoId: String) -> StemFiles? {
        let files = stemFiles(for: videoId)
        let manager = FileManager.default
        guard manager.fileExists(atPath: files.vocals.path), manager.fileExists(atPath: files.instrumental.path) else {
            return nil
        }
        return files
    }

    nonisolated static var cacheSize: Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: Storage.stems,
                                                                  includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
    }

    nonisolated static func clearCache() {
        try? FileManager.default.removeItem(at: Storage.stems)
        try? FileManager.default.createDirectory(at: Storage.stems, withIntermediateDirectories: true)
    }

    /// Vocals and instrumental for a song, separating `source` (a local audio file) unless cached.
    func stems(for videoId: String, source: URL) async throws -> StemFiles {
        if let cached = Self.cachedStems(for: videoId) { return cached }
        if let running = inFlight[videoId] { return try await running.value }
        let task = Task { try await self.separate(videoId: videoId, source: source) }
        inFlight[videoId] = task
        defer { inFlight[videoId] = nil }
        return try await task.value
    }

    private func separate(videoId: String, source: URL) async throws -> StemFiles {
        guard Self.isModelInstalled else { throw KaraokeError.modelMissing }
        #if canImport(SherpaOnnxC)
        let engine = try loadEngine()
        let files = Self.stemFiles(for: videoId)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.workQueue.async {
                do {
                    try Self.separateSync(engine: engine, source: source, into: files)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        Self.pruneCache()
        return files
        #else
        throw KaraokeError.engineUnavailable
        #endif
    }

    private static func pruneCache() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: Storage.stems,
                                                                      includingPropertiesForKeys: keys) else { return }
        let entries = files.compactMap { url -> (url: URL, size: Int64, date: Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        for entry in entries.sorted(by: { $0.date < $1.date }) where total > cacheLimit {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    #if canImport(SherpaOnnxC)
    private func loadEngine() throws -> OpaquePointer {
        if let engine { return engine }
        var config = SherpaOnnxOfflineSourceSeparationConfig()
        let model = strdup(Self.modelFile.path)
        let provider = strdup("cpu")
        defer {
            free(model)
            free(provider)
        }
        config.model.uvr.model = UnsafePointer(model)
        config.model.provider = UnsafePointer(provider)
        config.model.num_threads = 4
        config.model.debug = 0
        guard let created = SherpaOnnxCreateOfflineSourceSeparation(&config) else {
            throw KaraokeError.engineUnavailable
        }
        engine = created
        return created
    }

    /// Decodes the song, runs the model and writes both stems as AAC 256 kbps.
    private nonisolated static func separateSync(engine: OpaquePointer, source: URL, into files: StemFiles) throws {
        let file = try AVAudioFile(forReading: source)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw KaraokeError.unreadableAudio
        }
        try file.read(into: buffer)
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else {
            throw KaraokeError.unreadableAudio
        }
        let left = UnsafePointer(channelData[0])
        let right = UnsafePointer(format.channelCount > 1 ? channelData[1] : channelData[0])
        let channels: [UnsafePointer<Float>?] = [left, right]

        let output = channels.withUnsafeBufferPointer { list in
            SherpaOnnxOfflineSourceSeparationProcess(engine, list.baseAddress, 2,
                                                     Int32(buffer.frameLength), Int32(format.sampleRate))
        }
        guard let output else { throw KaraokeError.separationFailed }
        defer { SherpaOnnxDestroySourceSeparationOutput(output) }
        let result = output.pointee
        guard result.num_stems >= 2, let stems = result.stems else { throw KaraokeError.separationFailed }
        // UVR models: stem 0 is the model's target (vocals for Voc_FT), stem 1 the rest of the mix.
        try writeStem(stems[0], sampleRate: Double(result.sample_rate), to: files.vocals)
        try writeStem(stems[1], sampleRate: Double(result.sample_rate), to: files.instrumental)
    }

    private nonisolated static func writeStem(_ stem: SherpaOnnxSourceSeparationStem, sampleRate: Double,
                                              to url: URL) throws {
        let channelCount = max(1, min(2, Int(stem.num_channels)))
        let frames = Int(stem.n)
        guard frames > 0, sampleRate > 0, let samples = stem.samples,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channelCount), interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let destination = buffer.floatChannelData else {
            throw KaraokeError.separationFailed
        }
        for channel in 0..<channelCount {
            guard let source = samples[channel] else { throw KaraokeError.separationFailed }
            destination[channel].update(from: source, count: frames)
        }
        buffer.frameLength = AVAudioFrameCount(frames)

        let temporary = url.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).m4a")
        do {
            try encodeAAC(buffer, sampleRate: sampleRate, channels: channelCount, to: temporary)
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: temporary, to: url)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// In its own function so the file is closed (and finalized) before it is moved.
    private nonisolated static func encodeAAC(_ buffer: AVAudioPCMBuffer, sampleRate: Double, channels: Int,
                                              to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 256_000,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        try file.write(from: buffer)
    }
    #endif
}

/// Plays the two stems together, with the vocal / instrumental balance set by an audio mix
/// that can change while the song plays.
enum KaraokeMixer {
    @MainActor
    static func makeItem(stems: StemFiles, mode: KaraokeMode, amount: Float) async throws -> AVPlayerItem {
        let composition = AVMutableComposition()
        for url in [stems.vocals, stems.instrumental] {
            let asset = AVURLAsset(url: url)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first,
                  let track = composition.addMutableTrack(withMediaType: .audio,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw KaraokeError.unreadableAudio
            }
            let duration = try await asset.load(.duration)
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: .zero)
        }
        let item = AVPlayerItem(asset: composition)
        item.audioMix = mix(for: composition, mode: mode, amount: amount)
        return item
    }

    /// Track 0 is the vocals, track 1 the instrumental.
    static func mix(for composition: AVMutableComposition, mode: KaraokeMode, amount: Float) -> AVAudioMix {
        let gains = mode.gains(amount: amount)
        var parameters: [AVMutableAudioMixInputParameters] = []
        for (index, track) in composition.tracks.enumerated() {
            let parameter = AVMutableAudioMixInputParameters(track: track)
            parameter.setVolume(index == 0 ? gains.vocals : gains.instrumental, at: .zero)
            parameters.append(parameter)
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return mix
    }
}
