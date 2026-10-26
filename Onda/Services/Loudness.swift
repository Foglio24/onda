import AVFoundation
import Foundation

/// How much louder than YouTube's reference level (-14 LUFS) each song is, as YouTube itself
/// measures it. Read from the player data of YouTube's iOS client, which (unlike the YouTube Music
/// web client) includes it.
actor Loudness {
    static let shared = Loudness()

    private static let endpoint = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!
    private static let clientVersion = "20.10.4"
    private static let userAgent = "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)"

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

    /// The volume that brings a song down to the reference level. Quieter songs stay as they are:
    /// raising them could clip.
    static func gain(forDecibels decibels: Double?) -> Float {
        guard let decibels, decibels > 0.1 else { return 1 }
        return Float(pow(10, -min(decibels, 20) / 20))
    }

    private static func fetch(_ videoId: String) async throws -> Double? {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("5", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        let body: [String: Any] = [
            "videoId": videoId,
            "contentCheckOk": true,
            "racyCheckOk": true,
            "context": [
                "client": [
                    "clientName": "IOS",
                    "clientVersion": clientVersion,
                    "deviceMake": "Apple",
                    "deviceModel": "iPhone16,2",
                    "osName": "iPhone",
                    "osVersion": "18.3.2.22D82",
                    "hl": Locale.current.language.languageCode?.identifier ?? "en",
                ],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let config = J.dict(J.value(json, "playerConfig", "audioConfig"))
        if let decibels = config?["loudnessDb"] as? Double { return decibels }
        if let absolute = config?["trackAbsoluteLoudnessLkfs"] as? Double {
            return absolute - (config?["loudnessTargetLkfs"] as? Double ?? -14)
        }
        return nil
    }

    /// An audio mix that plays the item's audio at `gain`, or nil when nothing needs changing.
    static func mix(for item: AVPlayerItem, gain: Float) async -> AVAudioMix? {
        guard gain < 0.999,
              let track = try? await item.asset.loadTracks(withMediaType: .audio).first else { return nil }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.setVolume(gain, at: .zero)
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }
}
