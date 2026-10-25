import AVFoundation
import Foundation

enum OpusError: LocalizedError {
    case notWebM
    case noAudio
    case decoderUnavailable

    var errorDescription: String? {
        switch self {
        case .notWebM: return "File WebM non valido."
        case .noAudio: return "Nessun audio Opus nel file."
        case .decoderUnavailable: return "Decoder Opus non disponibile."
        }
    }
}

/// Plays YouTube's best rendition (Opus in WebM), which AVPlayer can't open:
/// the WebM is downloaded, its Opus packets are decoded with Apple's own Opus decoder
/// and the result is written as Apple Lossless, a bit-exact copy that AVPlayer plays natively.
actor OpusPipeline {
    static let shared = OpusPipeline()

    /// Decoded songs are kept for replays and prefetching, up to this size.
    private static let cacheLimit: Int64 = 600 << 20

    private var inFlight: [String: Task<URL, Error>] = [:]

    /// A playable lossless file for an Opus stream, decoding it unless it is already cached.
    func playableFile(videoId: String, stream: ResolvedStream) async throws -> URL {
        try await cached(Self.cacheFile(videoId: videoId, stream: stream)) { destination in
            let webm = destination.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).webm")
            defer { try? FileManager.default.removeItem(at: webm) }
            try await Self.download(stream.url, to: webm)
            try Self.transcode(webm: webm, to: destination)
        }
    }

    /// A local copy of an AAC or Dolby stream: AVPlayer seeks and measures reliably only in local files.
    func localCopy(videoId: String, stream: ResolvedStream) async throws -> URL {
        try await cached(Self.cacheFile(videoId: videoId, stream: stream)) { destination in
            try await Self.download(stream.url, to: destination)
        }
    }

    /// The best cached file for a song, with its format label, if one is ready.
    nonisolated static func cachedFile(videoId: String) -> (url: URL, label: String)? {
        let files = (try? FileManager.default.contentsOfDirectory(at: cacheDirectory,
                                                                  includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let matches = files.filter { $0.lastPathComponent.hasPrefix("\(videoId)__") }
        // The biggest file is the best quality (lossless Opus beats a plain AAC copy).
        guard let best = matches.max(by: { size(of: $0) < size(of: $1) }) else { return nil }
        let parts = best.deletingPathExtension().lastPathComponent.components(separatedBy: "__")
        let label = parts.count == 3 ? "\(parts[1]) · \(parts[2]) kbps" : "AAC"
        return (best, label)
    }

    private nonisolated static func size(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }

    /// "<videoId>__Opus__160.m4a"
    private nonisolated static func cacheFile(videoId: String, stream: ResolvedStream) -> URL {
        let format: String
        switch stream.format {
        case .aac: format = "AAC"
        case .opus: format = "Opus"
        case .dolby: format = "Dolby"
        }
        let kbps = Int((Double(stream.bitrate ?? 0) / 1000).rounded())
        return cacheDirectory.appending(path: "\(videoId)__\(format)__\(kbps).m4a")
    }

    /// Runs `build` once per destination, sharing the result with concurrent callers.
    private func cached(_ destination: URL,
                        build: @escaping @Sendable (URL) async throws -> Void) async throws -> URL {
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: destination.path)
            return destination
        }
        if let running = inFlight[destination.path] { return try await running.value }
        let task = Task.detached(priority: .userInitiated) {
            try await build(destination)
            return destination
        }
        inFlight[destination.path] = task
        defer { inFlight[destination.path] = nil }
        let file = try await task.value
        Self.pruneCache()
        return file
    }

    nonisolated static func download(_ url: URL, to destination: URL) async throws {
        let (temporary, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    /// Decodes a downloaded WebM/Opus file into an Apple Lossless .m4a at `destination`.
    nonisolated static func transcode(webm: URL, to destination: URL) throws {
        let data = try Data(contentsOf: webm, options: .mappedIfSafe)
        let track = try WebMDemuxer.opusTrack(in: data)
        let temporary = destination.deletingLastPathComponent()
            .appending(path: ".\(UUID().uuidString).m4a")
        do {
            try decode(track, to: temporary)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    // MARK: Decoding

    private final class Feed {
        var next = 0
    }

    private nonisolated static func decode(_ track: WebMDemuxer.OpusTrack, to url: URL) throws {
        let channels = AVAudioChannelCount(max(1, min(track.channels, 2)))
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: track.samplesPerPacket, mBytesPerFrame: 0, mChannelsPerFrame: channels,
            mBitsPerChannel: 0, mReserved: 0)
        guard let opusFormat = AVAudioFormat(streamDescription: &description),
              let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                            channels: channels, interleaved: false),
              let converter = AVAudioConverter(from: opusFormat, to: pcmFormat) else {
            throw OpusError.decoderUnavailable
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitDepthHintKey: 16,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32,
                                   interleaved: false)

        let packets = track.packets
        let feed = Feed()
        var framesToSkip = AVAudioFrameCount(track.preSkip)
        var emptyRounds = 0

        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 48_000) else {
                throw OpusError.decoderUnavailable
            }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                guard feed.next < packets.count else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                let batch = packets[feed.next..<min(feed.next + 64, packets.count)]
                feed.next += batch.count
                let largest = batch.map(\.count).max() ?? 0
                let buffer = AVAudioCompressedBuffer(format: opusFormat, packetCapacity: AVAudioPacketCount(batch.count),
                                                     maximumPacketSize: largest)
                var offset = 0
                for (position, packet) in batch.enumerated() {
                    packet.withUnsafeBytes { raw in
                        if let base = raw.baseAddress {
                            buffer.data.advanced(by: offset).copyMemory(from: base, byteCount: packet.count)
                        }
                    }
                    buffer.packetDescriptions?[position] = AudioStreamPacketDescription(
                        mStartOffset: Int64(offset), mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))
                    offset += packet.count
                }
                buffer.packetCount = AVAudioPacketCount(batch.count)
                buffer.byteLength = UInt32(offset)
                inputStatus.pointee = .haveData
                return buffer
            }
            if status == .error { throw conversionError ?? OpusError.decoderUnavailable }
            // Guard against a decoder that stops producing audio without ever reporting the end.
            if output.frameLength == 0 {
                emptyRounds += 1
                if emptyRounds > 3 { break }
            } else {
                emptyRounds = 0
            }

            // Opus starts with a few milliseconds of encoder delay ("pre-skip") that must be dropped.
            if framesToSkip > 0, output.frameLength > 0 {
                let skipped = min(framesToSkip, output.frameLength)
                let remaining = output.frameLength - skipped
                if let channelData = output.floatChannelData {
                    for channel in 0..<Int(channels) {
                        let samples = channelData[channel]
                        memmove(samples, samples.advanced(by: Int(skipped)),
                                Int(remaining) * MemoryLayout<Float>.size)
                    }
                }
                output.frameLength = remaining
                framesToSkip -= skipped
            }
            if output.frameLength > 0 { try file.write(from: output) }
            if status == .endOfStream { break }
        }
    }

    // MARK: Cache

    private static let cacheDirectory: URL = {
        let url = URL.cachesDirectory.appending(path: "OpusStreams", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static func pruneCache() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: cacheDirectory,
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

    static func clearCache() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
}

/// Just enough of a Matroska/WebM reader to pull the Opus packets out of YouTube's audio files.
enum WebMDemuxer {
    struct OpusTrack {
        var channels = 2
        var preSkip = 0
        var packets: [Data] = []

        /// Samples per packet at 48 kHz, read from the first packet's TOC byte (RFC 6716 §3.1).
        var samplesPerPacket: UInt32 {
            guard let packet = packets.first, let toc = packet.first else { return 960 }
            let config = Int(toc >> 3)
            let frameSize: Int
            switch config {
            case 0...11: frameSize = [480, 960, 1920, 2880][config % 4]
            case 12...15: frameSize = [480, 960][config % 2]
            default: frameSize = [120, 240, 480, 960][config % 4]
            }
            let frames: Int
            switch toc & 0x03 {
            case 0: frames = 1
            case 1, 2: frames = 2
            default: frames = packet.count > 1 ? max(1, Int(packet[packet.startIndex + 1] & 0x3F)) : 1
            }
            return UInt32(frameSize * frames)
        }
    }

    // Element IDs
    private static let masters: Set<UInt32> = [
        0x1853_8067, // Segment
        0x1F43_B675, // Cluster
        0x1654_AE6B, // Tracks
        0xAE,        // TrackEntry
        0xA0,        // BlockGroup
    ]
    private static let codecID: UInt32 = 0x86
    private static let codecPrivate: UInt32 = 0x63A2
    private static let simpleBlock: UInt32 = 0xA3
    private static let block: UInt32 = 0xA1
    private static let ebmlHeader: UInt32 = 0x1A45_DFA3

    static func opusTrack(in data: Data) throws -> OpusTrack {
        let bytes = [UInt8](data)
        var position = 0
        guard readID(bytes, &position) == ebmlHeader else { throw OpusError.notWebM }
        position = 0

        var track = OpusTrack()
        var isOpus = false
        while position < bytes.count {
            guard let id = readID(bytes, &position), let size = readSize(bytes, &position) else { break }
            if masters.contains(id) { continue } // children follow directly
            guard let length = size.length, position + length <= bytes.count else { break }
            let body = position..<(position + length)
            switch id {
            case codecID:
                isOpus = String(decoding: bytes[body], as: UTF8.self) == "A_OPUS"
            case codecPrivate where length >= 19:
                // OpusHead: "OpusHead", version, channel count, pre-skip (LE16), ...
                track.channels = Int(bytes[body.lowerBound + 9])
                track.preSkip = Int(bytes[body.lowerBound + 10]) | Int(bytes[body.lowerBound + 11]) << 8
            case simpleBlock, block:
                track.packets.append(contentsOf: frames(inBlock: bytes, body))
            default:
                break
            }
            position = body.upperBound
        }
        guard isOpus, !track.packets.isEmpty else { throw OpusError.noAudio }
        return track
    }

    /// The frames of a (Simple)Block: track number, 16-bit timecode, flags, then the laced frames.
    private static func frames(inBlock bytes: [UInt8], _ body: Range<Int>) -> [Data] {
        var position = body.lowerBound
        guard readSize(bytes, &position) != nil, position + 3 <= body.upperBound else { return [] }
        let flags = bytes[position + 2]
        position += 3
        let end = body.upperBound

        var sizes: [Int] = []
        switch (flags >> 1) & 0x03 {
        case 0: // no lacing
            sizes = [end - position]
        case 1: // Xiph lacing
            guard position < end else { return [] }
            let count = Int(bytes[position]) + 1
            position += 1
            for _ in 0..<(count - 1) {
                var size = 0
                while position < end {
                    let byte = Int(bytes[position])
                    position += 1
                    size += byte
                    if byte != 255 { break }
                }
                sizes.append(size)
            }
            sizes.append(end - position - sizes.reduce(0, +))
        case 2: // fixed-size lacing
            guard position < end else { return [] }
            let count = Int(bytes[position]) + 1
            position += 1
            sizes = Array(repeating: (end - position) / count, count: count)
        default: // EBML lacing
            guard position < end else { return [] }
            let count = Int(bytes[position]) + 1
            position += 1
            guard let first = readVint(bytes, &position) else { return [] }
            var previous = Int(first.value)
            sizes.append(previous)
            for _ in 0..<max(0, count - 2) {
                guard let delta = readVint(bytes, &position) else { return [] }
                let bias = (1 << (7 * delta.length - 1)) - 1
                previous += Int(delta.value) - bias
                sizes.append(previous)
            }
            sizes.append(end - position - sizes.reduce(0, +))
        }

        var frames: [Data] = []
        for size in sizes {
            guard size > 0, position + size <= end else { break }
            frames.append(Data(bytes[position..<(position + size)]))
            position += size
        }
        return frames
    }

    // MARK: EBML variable-length integers

    private enum Size {
        case known(Int)
        case unknown

        var length: Int? {
            if case .known(let value) = self { return value }
            return nil
        }
    }

    /// Element IDs keep their length marker bits.
    private static func readID(_ bytes: [UInt8], _ position: inout Int) -> UInt32? {
        guard position < bytes.count else { return nil }
        let length = bytes[position].leadingZeroBitCount + 1
        guard length <= 4, position + length <= bytes.count else { return nil }
        var value: UInt32 = 0
        for offset in 0..<length { value = value << 8 | UInt32(bytes[position + offset]) }
        position += length
        return value
    }

    private static func readSize(_ bytes: [UInt8], _ position: inout Int) -> Size? {
        guard let vint = readVint(bytes, &position) else { return nil }
        let allOnes: UInt64 = (1 << (7 * UInt64(vint.length))) - 1
        if vint.value == allOnes { return .unknown }
        guard vint.value <= UInt64(Int.max) else { return nil }
        return .known(Int(vint.value))
    }

    /// Value with the length marker removed, plus the number of bytes used.
    private static func readVint(_ bytes: [UInt8], _ position: inout Int) -> (value: UInt64, length: Int)? {
        guard position < bytes.count, bytes[position] != 0 else { return nil }
        let first = bytes[position]
        let length = first.leadingZeroBitCount + 1
        guard position + length <= bytes.count else { return nil }
        let mask: UInt8 = length >= 8 ? 0 : 0xFF >> UInt8(length)
        var value = UInt64(first & mask)
        for offset in 1..<max(1, length) {
            value = value << 8 | UInt64(bytes[position + offset])
        }
        position += length
        return (value, length)
    }
}
