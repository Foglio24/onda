import AVFoundation
import Foundation

/// A way to play the user's own songs that AVPlayer won't open. AVPlayer reads a file through a system
/// service of its own; this app, which holds the access to the folder, decodes it itself (AVAudioFile
/// reads more containers, and needs nothing but that access) into a PCM copy in the cache, which
/// AVPlayer plays without trouble. Audio only: a file with no video, no cover or a strange container
/// plays all the same.
enum LocalPlayable {
    /// The copies kept: older ones go when a new one is made.
    private static let keep = 12

    /// The PCM copy of `source` in `folder` (made now if there isn't one), or nil when the file can't be
    /// decoded either.
    static func copy(of source: URL, key: String, in folder: URL) async -> URL? {
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let target = folder.appending(path: "\(key)-\(String(size, radix: 16)).caf")
        if FileManager.default.fileExists(atPath: target.path) { return target }
        return await Task.detached(priority: .userInitiated) { () -> URL? in
            do {
                try decode(source, to: target)
                trim(in: folder, keeping: target)
                return target
            } catch {
                try? FileManager.default.removeItem(at: target)
                return nil
            }
        }.value
    }

    /// Reads `source` whole and writes it, as PCM, to `target` (through a temporary name, so a copy that
    /// isn't finished is never taken for one).
    nonisolated private static func decode(_ source: URL, to target: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        guard input.length > 0, format.channelCount > 0 else { throw CocoaError(.fileReadCorruptFile) }
        // A lossless file keeps its depth (up to 24 bits); a compressed one has none to keep.
        let depth = Int(input.fileFormat.streamDescription.pointee.mBitsPerChannel)
        let bits = depth == 0 ? 16 : min(24, max(16, depth))
        let temporary = target.deletingLastPathComponent().appending(path: "writing-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            let output = try AVAudioFile(forWriting: temporary, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: Int(format.channelCount),
                AVLinearPCMBitDepthKey: bits,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_768) else { throw CocoaError(.fileReadUnknown) }
            while input.framePosition < input.length {
                try Task.checkCancellation()
                try input.read(into: buffer, frameCount: 32_768)
                if buffer.frameLength == 0 { break }
                try output.write(from: buffer)
            }
        }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: temporary, to: target)
    }

    /// Keeps the newest copies, and always `keeping`.
    nonisolated private static func trim(in folder: URL, keeping current: URL) {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = ((try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? [])
            .filter { $0.pathExtension == "caf" && $0 != current }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast) }
        for (old, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(keep - 1) { try? manager.removeItem(at: old) }
    }
}
