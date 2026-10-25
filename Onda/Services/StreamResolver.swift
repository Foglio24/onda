import Foundation
import YouTubeKit

enum StreamError: LocalizedError {
    case noPlayableStream

    var errorDescription: String? { "Nessuno stream audio riproducibile per questo brano." }
}

enum StreamFormat: Sendable {
    case aac, opus, dolby
}

struct ResolvedStream: Sendable {
    let url: URL
    let format: StreamFormat
    /// Bits per second, when YouTube reports it.
    let bitrate: Int?

    /// "Opus · 160 kbps", "AAC · 128 kbps", "Dolby Digital Plus · 384 kbps"
    var label: String {
        let name: String
        switch format {
        case .aac: name = "AAC"
        case .opus: name = "Opus"
        case .dolby: name = "Dolby Digital Plus"
        }
        guard let bitrate, bitrate > 0 else { return name }
        return "\(name) · \(Int((Double(bitrate) / 1000).rounded())) kbps"
    }
}

/// Turns a YouTube video ID into a direct audio URL, picking the rendition for the chosen quality.
actor StreamResolver {
    static let shared = StreamResolver()

    private struct Entry {
        let stream: ResolvedStream
        let expires: Date
    }

    private var cache: [String: Entry] = [:]

    func stream(for videoId: String, quality: AudioQuality) async throws -> ResolvedStream {
        let key = "\(videoId)|\(quality.rawValue)|\(Preferences.prefersDolby)"
        if let entry = cache[key], entry.expires > .now { return entry.stream }
        // Local extraction first; the remote fallback keeps working when YouTube changes its player.
        let streams = try await YouTube(videoID: videoId, methods: [.local, .remote]).streams
        let audio = streams.filterAudioOnly()
        let aac = audio.filter { $0.fileExtension == .m4a && $0.audioCodec != .ec3 && $0.audioCodec != .ac3 }
        let opus = audio.filter { $0.fileExtension == .webm }
        let dolby = audio.filter { $0.audioCodec == .ec3 || $0.audioCodec == .ac3 }

        var chosen: ResolvedStream?
        switch quality {
        case .max:
            if Preferences.prefersDolby, let best = dolby.highestAudioBitrateStream() {
                chosen = Self.resolved(best, .dolby)
            } else if let best = aac.highestAudioBitrateStream(), Self.bitrate(of: best) >= 190_000 {
                // 256 kbps AAC, when YouTube offers it.
                chosen = Self.resolved(best, .aac)
            } else if let best = opus.highestAudioBitrateStream() {
                chosen = Self.resolved(best, .opus)
            }
        case .high:
            break
        case .medium:
            // The Opus rendition closest to 70 kbps.
            if let best = opus.min(by: { abs(Self.bitrate(of: $0) - 70_000) < abs(Self.bitrate(of: $1) - 70_000) }) {
                chosen = Self.resolved(best, .opus)
            }
        case .low:
            if let lowest = aac.lowestAudioBitrateStream() { chosen = Self.resolved(lowest, .aac) }
        }
        if chosen == nil, let best = aac.highestAudioBitrateStream() {
            chosen = Self.resolved(best, .aac)
        }
        if chosen == nil, let any = audio.filter(\.isNativelyPlayable).highestAudioBitrateStream() {
            chosen = Self.resolved(any, .aac)
        }
        guard let stream = chosen else { throw StreamError.noPlayableStream }
        // Stream URLs are signed for roughly six hours.
        cache[key] = Entry(stream: stream, expires: .now.addingTimeInterval(4 * 3600))
        return stream
    }

    func invalidate(_ videoId: String) {
        cache = cache.filter { !$0.key.hasPrefix("\(videoId)|") }
    }

    private static func bitrate(of stream: YouTubeKit.Stream) -> Int {
        stream.averageBitrate ?? stream.bitrate ?? 0
    }

    private static func resolved(_ stream: YouTubeKit.Stream, _ format: StreamFormat) -> ResolvedStream {
        ResolvedStream(url: stream.url, format: format, bitrate: bitrate(of: stream))
    }
}
