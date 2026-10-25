import Foundation
import YouTubeKit

enum StreamError: LocalizedError {
    case noPlayableStream

    var errorDescription: String? { "Nessuno stream audio riproducibile per questo brano." }
}

struct ResolvedStream: Sendable {
    let url: URL
    /// Bits per second, when YouTube reports it.
    let bitrate: Int?

    /// "AAC · 129 kbps"
    var label: String {
        guard let bitrate, bitrate > 0 else { return "AAC" }
        return "AAC · \(Int((Double(bitrate) / 1000).rounded())) kbps"
    }
}

/// Turns a YouTube video ID into a direct audio URL that AVPlayer can play.
actor StreamResolver {
    static let shared = StreamResolver()

    private struct Entry {
        let stream: ResolvedStream
        let expires: Date
    }

    private var cache: [String: Entry] = [:]

    func audioStream(for videoId: String, quality: AudioQuality) async throws -> ResolvedStream {
        let key = "\(videoId)|\(quality.rawValue)"
        if let entry = cache[key], entry.expires > .now { return entry.stream }
        // Local extraction first; the remote fallback keeps working when YouTube changes its player.
        let streams = try await YouTube(videoID: videoId, methods: [.local, .remote]).streams
        let audio = streams.filterAudioOnly()
        // AVPlayer can't decode WebM/Opus, so only the AAC (m4a) renditions are usable.
        let aac = audio.filter { $0.fileExtension == .m4a }
        let preferred = quality == .high ? aac.highestAudioBitrateStream() : aac.lowestAudioBitrateStream()
        guard let best = preferred ?? audio.filter(\.isNativelyPlayable).highestAudioBitrateStream() else {
            throw StreamError.noPlayableStream
        }
        let stream = ResolvedStream(url: best.url, bitrate: best.averageBitrate ?? best.bitrate)
        // Stream URLs are signed for roughly six hours.
        cache[key] = Entry(stream: stream, expires: .now.addingTimeInterval(4 * 3600))
        return stream
    }

    func invalidate(_ videoId: String) {
        for quality in AudioQuality.allCases {
            cache["\(videoId)|\(quality.rawValue)"] = nil
        }
    }
}
