import Foundation

enum StreamError: LocalizedError {
    case noPlayableStream

    var errorDescription: String? { String(localized: "Nessuno stream audio riproducibile per questo brano.") }
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

/// One audio rendition of a video, however it was found.
struct AudioRendition: Sendable, Equatable {
    let url: URL
    let format: StreamFormat
    let bitrate: Int
    /// AVPlayer can play it as it is (MP4); WebM/Opus needs `OpusPipeline`.
    let isNative: Bool
}

/// The quick way to a song's audio links: one request to YouTube's player as its visionOS app,
/// which answers with direct links to every audio rendition (no web page to download, no
/// JavaScript to run) as long as it carries a visitor ID. The same visitor ID serves every song,
/// so it is kept between launches. `StreamResolver` falls back to YouTubeKit when this fails.
enum DirectStreams {
    struct Result: Sendable {
        let renditions: [AudioRendition]
        let expires: Date
        /// Decibels above YouTube's reference level, for "Volume uniforme".
        let loudness: Double?
    }

    // The visionOS client as yt-dlp sends it (yt_dlp/extractor/youtube/_base.py).
    private static let endpoint = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!
    private static let clientVersion = "1.02"
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    private static let visitorKey = "youtube.visitorData"

    static func fetch(_ videoId: String) async throws -> Result {
        let stored = UserDefaults.standard.string(forKey: visitorKey)
        var json = try await request(videoId, visitor: stored)
        if !isPlayable(json) {
            // Without a visitor ID (or with an old one) YouTube refuses, and hands out a new one.
            guard let fresh = J.string(J.value(json, "responseContext", "visitorData")), fresh != stored else {
                throw StreamError.noPlayableStream
            }
            UserDefaults.standard.set(fresh, forKey: visitorKey)
            json = try await request(videoId, visitor: fresh)
        }
        guard isPlayable(json) else { throw StreamError.noPlayableStream }
        let result = parse(json)
        guard !result.renditions.isEmpty else { throw StreamError.noPlayableStream }
        return result
    }

    private static func isPlayable(_ json: [String: Any]) -> Bool {
        J.string(J.value(json, "playabilityStatus", "status")) == "OK"
    }

    private static func request(_ videoId: String, visitor: String?) async throws -> [String: Any] {
        var client: [String: Any] = [
            "clientName": "VISIONOS",
            "clientVersion": clientVersion,
            "deviceMake": "Apple",
            "deviceModel": "RealityDevice17,1",
            "osName": "visionOS",
            "osVersion": "26.5.23O471",
            "hl": Locale.current.language.languageCode?.identifier ?? "en",
        ]
        var request = URLRequest(url: endpoint, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("101", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        if let visitor {
            client["visitorData"] = visitor
            request.setValue(visitor, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        let body: [String: Any] = [
            "videoId": videoId,
            "contentCheckOk": true,
            "racyCheckOk": true,
            "context": ["client": client],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StreamError.noPlayableStream
        }
        return json
    }

    /// The audio renditions with a direct link, leaving out dubbed tracks and the
    /// dynamic-range-compressed copies YouTube adds for some songs.
    static func parse(_ json: [String: Any]) -> Result {
        let formats = J.array(J.value(json, "streamingData", "adaptiveFormats")).compactMap { $0 as? [String: Any] }
        let renditions = formats.compactMap { format -> AudioRendition? in
            guard let mime = format["mimeType"] as? String, mime.hasPrefix("audio/"),
                  let link = format["url"] as? String, let url = URL(string: link),
                  format["isDrc"] as? Bool != true,
                  J.value(format, "audioTrack", "audioIsDefault") as? Bool != false else { return nil }
            let kind: StreamFormat
            if mime.contains("opus") {
                kind = .opus
            } else if mime.contains("ec-3") || mime.contains("ac-3") {
                kind = .dolby
            } else if mime.contains("mp4a") {
                kind = .aac
            } else {
                return nil
            }
            let bitrate = (format["averageBitrate"] as? Int) ?? (format["bitrate"] as? Int) ?? 0
            return AudioRendition(url: url, format: kind, bitrate: bitrate, isNative: mime.hasPrefix("audio/mp4"))
        }
        // Links are signed for about six hours; keep a margin.
        let expiry = J.value(json, "streamingData", "expiresInSeconds")
        let lifetime = (expiry as? String).flatMap { Double($0) } ?? (expiry as? Double) ?? 21_600
        return Result(renditions: renditions, expires: .now.addingTimeInterval(max(3_600, lifetime - 1_800)),
                      loudness: SongDetails.loudness(in: json))
    }
}
