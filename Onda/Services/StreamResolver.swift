import Foundation
import YouTubeKit

enum StreamError: LocalizedError {
    case noPlayableStream

    var errorDescription: String? { "Nessuno stream audio riproducibile per questo brano." }
}

/// Turns a YouTube video ID into a direct audio URL that AVPlayer can play.
actor StreamResolver {
    static let shared = StreamResolver()

    private struct Entry {
        let url: URL
        let expires: Date
    }

    private var cache: [String: Entry] = [:]

    func audioURL(for videoId: String) async throws -> URL {
        if let entry = cache[videoId], entry.expires > .now { return entry.url }
        // Local extraction first; the remote fallback keeps working when YouTube changes its player.
        let streams = try await YouTube(videoID: videoId, methods: [.local, .remote]).streams
        let audio = streams.filterAudioOnly()
        // AVPlayer can't decode WebM/Opus, so prefer the AAC (m4a) renditions.
        guard let best = audio.filter({ $0.fileExtension == .m4a }).highestAudioBitrateStream()
                ?? audio.filter(\.isNativelyPlayable).highestAudioBitrateStream() else {
            throw StreamError.noPlayableStream
        }
        // Stream URLs are signed for roughly six hours.
        cache[videoId] = Entry(url: best.url, expires: .now.addingTimeInterval(4 * 3600))
        return best.url
    }

    func invalidate(_ videoId: String) {
        cache[videoId] = nil
    }
}
