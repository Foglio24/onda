import Foundation
import YouTubeKit

/// Turns a YouTube video ID into a direct audio URL, picking the rendition for the chosen quality.
/// A video's renditions are looked up once and shared by every quality: first with one direct
/// request (`DirectStreams`), otherwise with YouTubeKit, which loads the video's web page and
/// YouTube's player script.
actor StreamResolver {
    static let shared = StreamResolver()

    private struct Entry {
        let renditions: [AudioRendition]
        let expires: Date
    }

    private var cache: [String: Entry] = [:]
    /// Lookups in progress, so a tap on a song being pre-resolved waits for the same work.
    private var inFlight: [String: Task<Entry, Error>] = [:]
    /// Videos whose direct links failed to play: YouTubeKit looks them up from now on.
    private var avoidDirect: Set<String> = []

    func stream(for videoId: String, quality: AudioQuality) async throws -> ResolvedStream {
        try Task.checkCancellation()
        let entry = try await renditions(for: videoId)
        try Task.checkCancellation()
        guard let stream = Self.choose(from: entry.renditions, quality: quality,
                                       prefersDolby: Preferences.prefersDolby) else {
            throw StreamError.noPlayableStream
        }
        return stream
    }

    /// The best rendition AVPlayer plays as it is: at Massima, Dolby or 256 kbps AAC when the video
    /// has them, otherwise AAC. A song starts with it and keeps it, so nothing changes mid-song.
    func nativeStream(for videoId: String, quality: AudioQuality) async throws -> ResolvedStream {
        let stream = try await stream(for: videoId, quality: quality)
        guard stream.format == .opus else { return stream }
        return try await self.stream(for: videoId, quality: quality == .medium ? .low : .high)
    }

    /// The rendition a stream address belongs to, while the video's links are known.
    func stream(for videoId: String, at url: URL) -> ResolvedStream? {
        guard let rendition = cache[videoId]?.renditions.first(where: { $0.url == url }) else { return nil }
        return ResolvedStream(url: rendition.url, format: rendition.format, bitrate: rendition.bitrate)
    }

    /// Whether the video's links are already known, so playing it needs no request.
    func isCached(_ videoId: String) -> Bool {
        (cache[videoId]?.expires ?? .distantPast) > .now
    }

    /// Forgets the video's links (they expired or failed). After a failure the next lookup goes
    /// through YouTubeKit, in case the direct links were the problem.
    func invalidate(_ videoId: String) {
        cache[videoId] = nil
        avoidDirect.insert(videoId)
    }

    private func renditions(for videoId: String) async throws -> Entry {
        if let entry = cache[videoId], entry.expires > .now { return entry }
        if let running = inFlight[videoId] { return try await running.value }
        let direct = !avoidDirect.contains(videoId)
        let task = Task { try await Self.load(videoId, direct: direct) }
        inFlight[videoId] = task
        defer { inFlight[videoId] = nil }
        let entry = try await task.value
        if cache.count > 300 { cache = cache.filter { $0.value.expires > .now } }
        cache[videoId] = entry
        return entry
    }

    private static func load(_ videoId: String, direct: Bool) async throws -> Entry {
        if direct, let result = try? await DirectStreams.fetch(videoId) {
            // The same answer tells how loud the song is: "Volume uniforme" needs no request of its own.
            if let loudness = result.loudness { await Loudness.shared.remember(loudness, for: videoId) }
            return Entry(renditions: result.renditions, expires: result.expires)
        }
        // Local extraction first; the remote fallback keeps working when YouTube changes its player.
        let streams = try await YouTube(videoID: videoId, methods: [.local, .remote]).streams
        let renditions = streams.filterAudioOnly().map { stream -> AudioRendition in
            let format: StreamFormat
            if stream.audioCodec == .ec3 || stream.audioCodec == .ac3 {
                format = .dolby
            } else if stream.fileExtension == .webm {
                format = .opus
            } else {
                format = .aac
            }
            return AudioRendition(url: stream.url, format: format,
                                  bitrate: stream.averageBitrate ?? stream.bitrate ?? 0,
                                  isNative: stream.isNativelyPlayable)
        }
        // Stream URLs are signed for roughly six hours.
        return Entry(renditions: renditions, expires: .now.addingTimeInterval(4 * 3600))
    }

    /// The rendition for a quality: Dolby, 256 kbps AAC or Opus at the top, Opus near 70 kbps for
    /// Media, the smallest AAC for Risparmio dati, otherwise the best AAC.
    static func choose(from renditions: [AudioRendition], quality: AudioQuality, prefersDolby: Bool) -> ResolvedStream? {
        let aac = renditions.filter { $0.format == .aac && $0.isNative }
        let opus = renditions.filter { $0.format == .opus }
        let dolby = renditions.filter { $0.format == .dolby && $0.isNative }

        var chosen: AudioRendition?
        switch quality {
        case .max:
            if prefersDolby, let best = dolby.max(by: { $0.bitrate < $1.bitrate }) {
                chosen = best
            } else if let best = aac.max(by: { $0.bitrate < $1.bitrate }), best.bitrate >= 190_000 {
                // 256 kbps AAC, when YouTube offers it.
                chosen = best
            } else {
                chosen = opus.max(by: { $0.bitrate < $1.bitrate })
            }
        case .high:
            break
        case .medium:
            chosen = opus.min(by: { abs($0.bitrate - 70_000) < abs($1.bitrate - 70_000) })
        case .low:
            chosen = aac.min(by: { $0.bitrate < $1.bitrate })
        }
        if chosen == nil { chosen = aac.max(by: { $0.bitrate < $1.bitrate }) }
        if chosen == nil { chosen = renditions.filter(\.isNative).max(by: { $0.bitrate < $1.bitrate }) }
        guard let chosen else { return nil }
        return ResolvedStream(url: chosen.url, format: chosen.format, bitrate: chosen.bitrate)
    }
}

/// Unlocks the stream links of songs shown on screen before they are tapped, like Spotify does,
/// so playback can start right away. Higher priority first, then the most recently shown,
/// one at a time. A row that scrolls away withdraws its request (see `playbackWarmup`).
actor StreamPrewarmer {
    static let shared = StreamPrewarmer()

    private struct Request {
        let videoId: String
        let token: UUID?
        let priority: Int
        let order: UInt64
    }

    private static let maxQueued = 4
    private static let maxRunning = 1
    private var queue: [Request] = []
    private var order: UInt64 = 0
    private var running = 0

    nonisolated func request(_ track: Track, token: UUID? = nil, priority: Int = 0) {
        guard EnergyPolicy.current.allowsSpeculativeWork, let videoId = track.videoId else { return }
        Task { await self.enqueue(videoId, token: token, priority: priority) }
    }

    nonisolated func release(_ token: UUID) {
        Task { await self.withdraw(token) }
    }

    private func enqueue(_ videoId: String, token: UUID?, priority: Int) {
        guard EnergyPolicy.current.allowsSpeculativeWork else { queue.removeAll(); return }
        order &+= 1
        queue.removeAll { $0.videoId == videoId }
        queue.append(Request(videoId: videoId, token: token, priority: priority, order: order))
        if queue.count > Self.maxQueued {
            queue.sort { ($0.priority, $0.order) < ($1.priority, $1.order) }
            queue.removeFirst(queue.count - Self.maxQueued)
        }
        pump()
    }

    private func withdraw(_ token: UUID) {
        queue.removeAll { $0.token == token }
    }

    private func pump() {
        guard EnergyPolicy.current.allowsSpeculativeWork else { queue.removeAll(); return }
        while running < Self.maxRunning,
              let next = queue.indices.max(by: { (queue[$0].priority, queue[$0].order) < (queue[$1].priority, queue[$1].order) }) {
            let videoId = queue.remove(at: next).videoId
            running += 1
            Task(priority: .utility) {
                await Self.resolve(videoId)
                self.finished()
            }
        }
    }

    private func finished() {
        running -= 1
        pump()
    }

    private static func resolve(_ videoId: String) async {
        guard !Task.isCancelled, EnergyPolicy.current.allowsSpeculativeWork else { return }
        guard Storage.audioFileExists(videoId: videoId) == false,
              OpusPipeline.cachedFile(videoId: videoId) == nil,
              await StreamResolver.shared.isCached(videoId) == false else { return }
        guard !Task.isCancelled, EnergyPolicy.current.allowsSpeculativeWork else { return }
        _ = try? await StreamResolver.shared.stream(for: videoId, quality: Preferences.initialStreamQuality)
    }
}
