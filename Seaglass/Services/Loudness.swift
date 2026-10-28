import Foundation

/// How much louder than YouTube's reference level (-14 LUFS) each song is, as YouTube itself
/// measures it (see `YouTubePlayerData`). The audio mix that applies it is `AudioEffects`.
actor Loudness {
    static let shared = Loudness()

    /// Decibels above the reference, by video ID; nil once a lookup failed, so it isn't repeated.
    private var known: [String: Double?] = [:]
    private var inFlight: [String: Task<Double?, Never>] = [:]

    func decibels(for videoId: String) async -> Double? {
        if let value = known[videoId] { return value }
        if let running = inFlight[videoId] { return await running.value }
        let task = Task { try? await Self.fetch(videoId) }
        inFlight[videoId] = task
        let value = await task.value
        inFlight[videoId] = nil
        known[videoId] = .some(value)
        return value
    }

    /// Keeps a value that came with another answer (see `DirectStreams`), so no request is needed.
    func remember(_ decibels: Double, for videoId: String) {
        known[videoId] = .some(decibels)
    }

    /// The volume that brings a song down to the reference level. Quieter songs stay as they are:
    /// raising them could clip.
    static func gain(forDecibels decibels: Double?) -> Float {
        guard let decibels, decibels > 0.1 else { return 1 }
        return Float(pow(10, -min(decibels, 20) / 20))
    }

    private static func fetch(_ videoId: String) async throws -> Double? {
        guard let json = try await YouTubePlayerData.response(for: videoId) else { return nil }
        return SongDetails.loudness(in: json)
    }
}
