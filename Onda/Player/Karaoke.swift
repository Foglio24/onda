import AVFoundation
import CoreML
import Foundation
import os

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
    /// Separating the song: the share done so far and, once known, the seconds left.
    case preparing(Double, remaining: TimeInterval?)
    case ready
    case failed(String)
}

struct StemFiles: Sendable {
    let vocals: URL
    let instrumental: URL
}

/// Estimates the time a separation still needs from the progress reported so far
/// (measured from the first report, which may come from a separation already under way).
@MainActor
final class KaraokeClock {
    private var start: (date: Date, value: Double)?

    func remaining(at value: Double) -> TimeInterval? {
        guard let start else {
            self.start = (.now, value)
            return nil
        }
        let done = value - start.value
        guard done > 0.01 else { return nil }
        return Date.now.timeIntervalSince(start.date) / done * (1 - value)
    }
}

enum KaraokeError: LocalizedError {
    case engineUnavailable
    case modelFailed(String)
    case unreadableAudio
    case separationFailed
    case lowMemory

    var errorDescription: String? {
        switch self {
        case .engineUnavailable: return "Il modello AI per il karaoke non è incluso in questa versione dell'app."
        case .modelFailed(let detail): return "Il modello AI non è riuscito a separare il brano (\(detail))."
        case .unreadableAudio: return "Non riesco a leggere l'audio del brano."
        case .separationFailed: return "La separazione di voce e musica non è riuscita."
        case .lowMemory: return "Memoria insufficiente per il karaoke: chiudi qualche app e riprova."
        }
    }
}

/// Splits a song into vocals and instrumental with an AI model (UVR MDX-Net "Voc_FT"), run by
/// Core ML on the Neural Engine / GPU (see `MDXSeparator`). The model ships inside the app;
/// results are cached per song.
actor StemSeparator {
    static let shared = StemSeparator()

    private static let cacheLimit: Int64 = 800 << 20
    private static let sampleRate = MDXSeparator.sampleRate
    /// Frames given to the model at once (about 5.8 s), the most it takes in one go.
    private static let pieceLength = MDXSeparator.maxPieceLength
    /// Neighbouring pieces overlap by half a second and are crossfaded, which hides the seams.
    private static let overlap = 22_050
    /// Below this much free memory the separation stops with an error, before iOS closes the app.
    private static let memoryReserve = 300 << 20
    /// One separation at a time. The model is used, loaded and freed only on this queue, so
    /// freeing it (on a memory warning) waits for the separation in progress.
    private static let workQueue = DispatchQueue(label: "onda.karaoke.separation", qos: .userInitiated)
    private static let wanted = WantedSongs()
    private static let lastRunKey = "karaoke.lastRun"
    /// The sherpa-onnx model that 1.4.0 test builds downloaded; Core ML has replaced it.
    private static let legacyModelName = "UVR-MDX-NET-Voc_FT.onnx"

    // Only touched on `workQueue`.
    private static var loadedSeparator: MDXSeparator?
    private static var computeUnits: MLComputeUnits = .all

    /// The compiled Core ML model bundled with the app (made in CI from the ONNX model).
    nonisolated static var modelURL: URL? {
        Bundle.main.url(forResource: "VocFT", withExtension: "mlmodelc", subdirectory: "Karaoke")
    }

    nonisolated static var isAvailable: Bool { modelURL != nil }

    private var inFlight: [String: Task<StemFiles, Error>] = [:]
    private var listeners: [String: [@Sendable (Double) -> Void]] = [:]

    // MARK: Model

    /// Frees the model's memory once the separation in progress (if any) is done;
    /// it is loaded again on the next one.
    nonisolated static func releaseEngine() {
        workQueue.async { loadedSeparator = nil }
    }

    /// Deletes the model older test builds downloaded (64 MB).
    nonisolated static func removeLegacyModel() {
        try? FileManager.default.removeItem(at: Storage.models.appending(path: legacyModelName))
    }

    /// "48 pezzi in 14 s (Neural Engine/GPU)", for Settings.
    nonisolated static var lastRun: String? {
        UserDefaults.standard.string(forKey: lastRunKey)
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
        clearInterruptedRun()
    }

    /// Only these songs (the one playing and the next) keep being separated;
    /// the others stop at their next piece.
    nonisolated static func focus(on videoIds: [String]) {
        wanted.set(Set(videoIds))
    }

    /// Vocals and instrumental for a song, separating `source` (a local audio file) unless cached.
    /// `duration` (the catalogue length) is only used for `progress`.
    func stems(for videoId: String, source: URL, duration: TimeInterval?,
               progress: (@Sendable (Double) -> Void)? = nil) async throws -> StemFiles {
        if let cached = Self.cachedStems(for: videoId) { return cached }
        if let progress { listeners[videoId, default: []].append(progress) }
        if let running = inFlight[videoId] {
            do {
                return try await running.value
            } catch is CancellationError where Self.wanted.contains(videoId) {
                // Dropped, then wanted again before it stopped: start over.
                if inFlight[videoId] == running { inFlight[videoId] = nil }
                return try await stems(for: videoId, source: source, duration: duration)
            }
        }
        let task = Task { try await self.separate(videoId: videoId, source: source, duration: duration) }
        inFlight[videoId] = task
        defer {
            if inFlight[videoId] == task {
                inFlight[videoId] = nil
                listeners[videoId] = nil
            }
        }
        return try await task.value
    }

    private func report(_ value: Double, for videoId: String) {
        listeners[videoId]?.forEach { $0(value) }
    }

    private func separate(videoId: String, source: URL, duration: TimeInterval?) async throws -> StemFiles {
        guard let modelURL = Self.modelURL else { throw KaraokeError.engineUnavailable }
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw KaraokeError.unreadableAudio
        }
        var length = duration ?? 0
        if length <= 0 { length = (try? await asset.load(.duration).seconds) ?? 0 }
        let totalFrames = max(1, Int(length * Double(Self.sampleRate)))
        let files = Self.stemFiles(for: videoId)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.workQueue.async {
                do {
                    try Self.separateSync(modelURL: modelURL, asset: asset, track: track, videoId: videoId,
                                          totalFrames: totalFrames, into: files) { value in
                        Task { await self.report(value, for: videoId) }
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        Self.pruneCache()
        return files
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

    // MARK: Diagnostics

    /// Rewritten before every piece and removed when a separation ends: if iOS closes the app
    /// in the middle, the next launch knows where it stopped.
    private nonisolated static var progressNote: URL { Storage.models.appending(path: "separation-progress.txt") }
    private nonisolated static var interruptedNote: URL { Storage.models.appending(path: "separation-interrupted.txt") }

    /// Called at launch: a progress note left behind means the last separation never finished.
    nonisolated static func noteInterruptedRun() {
        let manager = FileManager.default
        guard manager.fileExists(atPath: progressNote.path) else { return }
        try? manager.removeItem(at: interruptedNote)
        try? manager.moveItem(at: progressNote, to: interruptedNote)
    }

    /// Where the last separation stopped when the app was closed during it, if that happened.
    nonisolated static var interruptedRun: String? {
        try? String(contentsOf: interruptedNote, encoding: .utf8)
    }

    nonisolated static func clearInterruptedRun() {
        try? FileManager.default.removeItem(at: interruptedNote)
    }

    private nonisolated static func leaveNote(_ step: String) {
        let used = ByteCountFormatter.string(fromByteCount: Int64(memoryFootprint), countStyle: .memory)
        let free = ByteCountFormatter.string(fromByteCount: Int64(os_proc_available_memory()), countStyle: .memory)
        let date = Date.now.formatted(date: .abbreviated, time: .standard)
        let text = "\(step) · memoria usata \(used), libera \(free) · \(date)"
        try? text.write(to: progressNote, atomically: true, encoding: .utf8)
    }

    private nonisolated static func removeNote() {
        try? FileManager.default.removeItem(at: progressNote)
    }

    /// The app's memory as iOS counts it against its limit.
    private nonisolated static var memoryFootprint: UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    private nonisolated static func name(of units: MLComputeUnits) -> String {
        if units == .cpuOnly { return "CPU" }
        if units == .cpuAndGPU { return "GPU" }
        return "Neural Engine/GPU"
    }

    /// The next, safer choice when the current one fails: GPU, then CPU only.
    private nonisolated static func fallback(from units: MLComputeUnits) -> MLComputeUnits? {
        if units == .cpuOnly { return nil }
        if units == .cpuAndGPU { return .cpuOnly }
        return .cpuAndGPU
    }

    // MARK: Separation (on workQueue)

    private nonisolated static func loadSeparator(modelURL: URL) throws -> MDXSeparator {
        if let loadedSeparator { return loadedSeparator }
        while true {
            leaveNote("Caricamento del modello AI (\(name(of: computeUnits)))")
            do {
                let separator = try MDXSeparator(modelURL: modelURL, computeUnits: computeUnits)
                loadedSeparator = separator
                return separator
            } catch {
                guard let next = fallback(from: computeUnits) else {
                    throw KaraokeError.modelFailed(error.localizedDescription)
                }
                computeUnits = next
            }
        }
    }

    /// Runs the model on one piece. Should the Neural Engine / GPU give back a broken result
    /// (float16 overflow), the piece is redone on a safer compute unit, used from then on.
    private nonisolated static func separateVocals(modelURL: URL, left: ArraySlice<Float>,
                                                   right: ArraySlice<Float>) throws -> (left: [Float], right: [Float]) {
        while true {
            let separator = try loadSeparator(modelURL: modelURL)
            let vocals: (left: [Float], right: [Float])
            do {
                vocals = try separator.vocals(left: left, right: right)
            } catch {
                guard let next = fallback(from: computeUnits) else {
                    throw KaraokeError.modelFailed(error.localizedDescription)
                }
                computeUnits = next
                loadedSeparator = nil
                continue
            }
            if vocals.left.allSatisfy(\.isFinite) && vocals.right.allSatisfy(\.isFinite) { return vocals }
            guard let next = fallback(from: computeUnits) else { throw KaraokeError.separationFailed }
            computeUnits = next
            loadedSeparator = nil
        }
    }

    /// Decodes the song a piece at a time, runs the model on each piece and streams both stems
    /// to AAC 256 kbps files. The instrumental is the song minus the vocals.
    private nonisolated static func separateSync(modelURL: URL, asset: AVAsset, track: AVAssetTrack,
                                                 videoId: String, totalFrames: Int, into files: StemFiles,
                                                 progress: (Double) -> Void) throws {
        defer { removeNote() }
        guard wanted.contains(videoId) else { throw CancellationError() }
        let started = Date.now
        let reader = try PCMReader(asset: asset, track: track, sampleRate: Double(sampleRate))
        let vocalsWriter = try StemWriter(destination: files.vocals, sampleRate: Double(sampleRate),
                                          capacity: pieceLength)
        let instrumentalWriter = try StemWriter(destination: files.instrumental, sampleRate: Double(sampleRate),
                                                capacity: pieceLength)
        var finished = false
        defer {
            if !finished {
                vocalsWriter.discard()
                instrumentalWriter.discard()
            }
        }

        // Song frames not written yet. The first `tailLeft.count` of them were already separated
        // as the end of the previous piece: that is the overlap to crossfade.
        var left: [Float] = []
        var right: [Float] = []
        left.reserveCapacity(pieceLength + 16_384)
        right.reserveCapacity(pieceLength + 16_384)
        var tailLeft: [Float] = []
        var tailRight: [Float] = []
        var written = 0
        let pieces = max(1, Int((Double(totalFrames) / Double(pieceLength - overlap)).rounded(.up)))
        var piece = 0

        while true {
            let more = try autoreleasepool { () throws -> Bool in
                try reader.fill(&left, &right, upTo: pieceLength)
                let carried = tailLeft.count
                let count = min(left.count, pieceLength)
                guard count > carried else {
                    // The song ended inside the overlap: what is left was already separated.
                    try writeStems(vocalsLeft: tailLeft, vocalsRight: tailRight, songLeft: left, songRight: right,
                                   count: carried, vocalsWriter: vocalsWriter, instrumentalWriter: instrumentalWriter)
                    return false
                }
                guard wanted.contains(videoId) else { throw CancellationError() }
                let available = os_proc_available_memory()
                if available > 0, available < memoryReserve { throw KaraokeError.lowMemory }
                piece += 1
                leaveNote("Separazione: pezzo \(piece) di circa \(max(piece, pieces)) (\(name(of: computeUnits)))")

                var vocals = try separateVocals(modelURL: modelURL, left: left[0..<count], right: right[0..<count])
                for index in 0..<carried {
                    let weight = Float(index + 1) / Float(carried + 1)
                    vocals.left[index] = tailLeft[index] * (1 - weight) + vocals.left[index] * weight
                    vocals.right[index] = tailRight[index] * (1 - weight) + vocals.right[index] * weight
                }
                let isLast = reader.isFinished && left.count <= pieceLength
                let keep = isLast ? count : count - overlap
                try writeStems(vocalsLeft: vocals.left, vocalsRight: vocals.right, songLeft: left, songRight: right,
                               count: keep, vocalsWriter: vocalsWriter, instrumentalWriter: instrumentalWriter)
                written += keep
                progress(min(0.99, Double(written) / Double(totalFrames)))
                guard !isLast else { return false }
                tailLeft = Array(vocals.left[keep..<count])
                tailRight = Array(vocals.right[keep..<count])
                left.removeFirst(keep)
                right.removeFirst(keep)
                return true
            }
            if !more { break }
        }
        guard written > 0 || !tailLeft.isEmpty else { throw KaraokeError.unreadableAudio }
        try vocalsWriter.finish()
        try instrumentalWriter.finish()
        finished = true

        let seconds = Int(Date.now.timeIntervalSince(started).rounded())
        let songLength = Duration.seconds(Double(written + tailLeft.count) / Double(sampleRate))
        let summary = "\(piece) pezzi in \(seconds) s per \(songLength.formatted(.time(pattern: .minuteSecond))) "
            + "di brano (\(name(of: computeUnits)))"
        UserDefaults.standard.set(summary, forKey: lastRunKey)
    }

    /// Writes the first `count` frames of the vocals and of the instrumental (song minus vocals).
    private nonisolated static func writeStems(vocalsLeft: [Float], vocalsRight: [Float], songLeft: [Float],
                                               songRight: [Float], count: Int, vocalsWriter: StemWriter,
                                               instrumentalWriter: StemWriter) throws {
        guard count > 0 else { return }
        try vocalsWriter.write(count: count) { outLeft, outRight in
            for index in 0..<count {
                outLeft[index] = vocalsLeft[index]
                outRight[index] = vocalsRight[index]
            }
        }
        try instrumentalWriter.write(count: count) { outLeft, outRight in
            for index in 0..<count {
                outLeft[index] = songLeft[index] - vocalsLeft[index]
                outRight[index] = songRight[index] - vocalsRight[index]
            }
        }
    }
}

/// The songs whose separation is still wanted, read by the separation between pieces.
private final class WantedSongs: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<String> = []

    func set(_ newIDs: Set<String>) {
        lock.withLock { ids = newIDs }
    }

    func contains(_ id: String) -> Bool {
        lock.withLock { ids.contains(id) }
    }
}

/// Decodes a song to 44.1 kHz stereo float, a little at a time. AVAssetReader reads every file
/// AVPlayer plays (YouTube's fragmented MP4 included) and converts the sample rate itself.
private final class PCMReader {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private(set) var isFinished = false

    init(asset: AVAsset, track: AVAssetTrack, sampleRate: Double) throws {
        reader = try AVAssetReader(asset: asset)
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw KaraokeError.unreadableAudio }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? KaraokeError.unreadableAudio }
    }

    /// Appends decoded frames until `left` holds at least `count` of them or the song ends.
    func fill(_ left: inout [Float], _ right: inout [Float], upTo count: Int) throws {
        while left.count < count, !isFinished {
            guard let sample = output.copyNextSampleBuffer() else {
                if reader.status == .failed { throw reader.error ?? KaraokeError.unreadableAudio }
                isFinished = true
                break
            }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var interleaved = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let status = interleaved.withUnsafeMutableBytes { bytes -> OSStatus in
                guard let base = bytes.baseAddress else { return kCMBlockBufferBadCustomBlockSourceErr }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: base)
            }
            guard status == kCMBlockBufferNoErr else { throw KaraokeError.unreadableAudio }
            var index = 0
            while index + 1 < interleaved.count {
                left.append(interleaved[index])
                right.append(interleaved[index + 1])
                index += 2
            }
        }
    }
}

/// Writes one stem as AAC 256 kbps, piece by piece, into a temporary file that replaces
/// the destination only once complete.
private final class StemWriter {
    private let destination: URL
    private let temporary: URL
    private let buffer: AVAudioPCMBuffer
    private var file: AVAudioFile?

    init(destination: URL, sampleRate: Double, capacity: Int) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 2, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(capacity)) else {
            throw KaraokeError.separationFailed
        }
        self.destination = destination
        self.buffer = buffer
        temporary = destination.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 256_000,
        ]
        file = try AVAudioFile(forWriting: temporary, settings: settings, commonFormat: .pcmFormatFloat32,
                               interleaved: false)
    }

    /// Writes `count` frames (at most the capacity) that `fill` puts in the left and right channels.
    func write(count: Int, _ fill: (_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>) -> Void) throws {
        guard let file, count > 0, count <= Int(buffer.frameCapacity),
              let channels = buffer.floatChannelData else { return }
        fill(channels[0], channels[1])
        buffer.frameLength = AVAudioFrameCount(count)
        try file.write(from: buffer)
    }

    /// Closes the file (which finalizes it) and moves it in place.
    func finish() throws {
        autoreleasepool { file = nil }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    func discard() {
        autoreleasepool { file = nil }
        try? FileManager.default.removeItem(at: temporary)
    }
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
