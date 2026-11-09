import Foundation

/// One user-requested fingerprint lookup using Shazam's community-documented discovery route.
/// It identifies Seaglass honestly, sends no raw recording, and stops on refusals or rate limits.
/// Request schema: shazamio/ShazamIO commit 3578d409e647843d94492bfdccb39dcdc7983222 (MIT).
enum RecognitionAPI {
    static let maximumSignatureBytes = 262_144
    static let maximumResponseBytes = 1_048_576
    private static let rateLimit = RateLimit()

    enum Failure: LocalizedError, Equatable {
        case invalidSample, invalidResponse, refused, rateLimited, server, network

        var errorDescription: String? {
            switch self {
            case .invalidSample:
                return String(localized: "Il campione audio non è valido. Riprova ad ascoltare il brano.")
            case .invalidResponse:
                return String(localized: "Il servizio di riconoscimento ha restituito una risposta non valida.")
            case .refused:
                return String(localized: "Shazam ha rifiutato la richiesta di riconoscimento.")
            case .rateLimited:
                return String(localized: "Troppe richieste di riconoscimento. Attendi un minuto e riprova.")
            case .server:
                return String(localized: "Il servizio di riconoscimento non è disponibile. Riprova più tardi.")
            case .network:
                return String(localized: "Connessione non riuscita. Controlla la rete e riprova.")
            }
        }
    }

    static func request(signature: Data, sampleDuration: TimeInterval, date: Date = .now) throws -> URLRequest {
        guard signature.count >= 56, signature.count <= maximumSignatureBytes,
              sampleDuration.isFinite, sampleDuration > 0, sampleDuration <= 12 else { throw Failure.invalidSample }
        let timestamp = date.timeIntervalSince1970
        guard timestamp.isFinite, timestamp >= 0, timestamp <= 253_402_300_799 else { throw Failure.invalidSample }
        // These UUIDs correlate one request, not a client or account. There is no retry, alternate
        // device identity, token or location fix if the service declines the request.
        let path = "https://amp.shazam.com/discovery/v5/en-US/GB/iphone/-/tag/\(UUID().uuidString)/\(UUID().uuidString)"
        guard var components = URLComponents(string: path) else { throw Failure.invalidResponse }
        components.queryItems = [
            URLQueryItem(name: "sync", value: "true"), URLQueryItem(name: "webv3", value: "true"),
            URLQueryItem(name: "sampling", value: "true"), URLQueryItem(name: "connected", value: ""),
            URLQueryItem(name: "shazamapiversion", value: "v3"), URLQueryItem(name: "sharehub", value: "true"),
            URLQueryItem(name: "hubv5minorversion", value: "v5.1"), URLQueryItem(name: "hidelb", value: "true"),
            URLQueryItem(name: "video", value: "v3"),
        ]
        guard let endpoint = components.url else { throw Failure.invalidResponse }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.29.0"
        request.setValue("Seaglass/\(version)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "timezone": TimeZone.current.identifier,
            "timestamp": Int64(timestamp * 1000),
            "signature": ["uri": "data:audio/vnd.shazam.sig;base64," + signature.base64EncodedString(),
                          "samplems": Int(sampleDuration * 1000)] as [String: Any],
            "context": [String: String](), "geolocation": [String: String](),
        ])
        return request
    }

    static func recognize(signature: Data, sampleDuration: TimeInterval) async throws -> RecognizedSong? {
        try await rateLimit.check()
        try Task.checkCancellation()
        let request = try request(signature: signature, sampleDuration: sampleDuration)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
            if http.statusCode == 429 { await rateLimit.recordRefusal() }
            try validateStatus(http.statusCode)
            guard response.expectedContentLength <= Int64(maximumResponseBytes) else { throw Failure.invalidResponse }
            var data = Data()
            data.reserveCapacity(min(max(0, Int(response.expectedContentLength)), maximumResponseBytes))
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < maximumResponseBytes else { throw Failure.invalidResponse }
                data.append(byte)
            }
            return try parse(data: data, statusCode: http.statusCode)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as Failure {
            throw error
        } catch {
            // Do not display remote error bodies, request URLs, or framework diagnostic details.
            throw Failure.network
        }
    }

    static func parse(data: Data, statusCode: Int = 200) throws -> RecognizedSong? {
        try validateStatus(statusCode)
        guard !data.isEmpty, data.count <= maximumResponseBytes,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let matches = json["matches"] as? [[String: Any]], matches.count <= 100 else { throw Failure.invalidResponse }
        guard !matches.isEmpty else { return nil }
        guard matches.allSatisfy({ text($0["id"]) != nil }),
              let result = json["track"] as? [String: Any],
              let title = text(result["title"]), let artist = text(result["subtitle"]) else { throw Failure.invalidResponse }
        let metadata = songMetadata(result["sections"])
        let images = result["images"] as? [String: Any] ?? [:]
        let artwork = httpsURL(images["coverarthq"]) ?? httpsURL(images["coverart"])
        let track = Track(videoId: nil, title: title, artists: [artist], album: metadata["album"], artworkURL: artwork)
        let hub = result["hub"] as? [String: Any] ?? [:]
        var actions = hub["actions"] as? [[String: Any]] ?? []
        for option in (hub["options"] as? [[String: Any]] ?? []).prefix(20) {
            actions.append(contentsOf: (option["actions"] as? [[String: Any]] ?? []).prefix(20))
        }
        for provider in (hub["providers"] as? [[String: Any]] ?? []).prefix(20) {
            actions.append(contentsOf: (provider["actions"] as? [[String: Any]] ?? []).prefix(20))
        }
        let links = actions.prefix(500).compactMap { httpsURL($0["uri"]) }
        let share = result["share"] as? [String: Any]
        let genres = result["genres"] as? [String: Any]
        return RecognizedSong(
            track: track,
            releaseDate: metadata["released"], label: metadata["label"], genre: text(genres?["primary"]),
            composer: metadata["composer"], isrc: text(result["isrc"]),
            songURL: httpsURL(result["url"], hosts: ["www.shazam.com", "shazam.com"])
                ?? httpsURL(share?["href"], hosts: ["www.shazam.com", "shazam.com"]),
            appleMusicURL: links.first { ["music.apple.com", "itunes.apple.com"].contains($0.host?.lowercased() ?? "") },
            spotifyURL: links.first { $0.host?.lowercased() == "open.spotify.com" })
    }

    private static func validateStatus(_ status: Int) throws {
        switch status {
        case 200: return
        case 401, 403: throw Failure.refused
        case 429: throw Failure.rateLimited
        case 500...599: throw Failure.server
        default: throw Failure.invalidResponse
        }
    }

    private static func text(_ value: Any?) -> String? {
        guard let value = value as? String, value.utf8.count <= 4096 else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func httpsURL(_ value: Any?, hosts: Set<String>? = nil) -> URL? {
        guard let string = text(value), let url = URL(string: string), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), !host.isEmpty, url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, hosts?.contains(host) ?? true else { return nil }
        return url
    }

    private static func songMetadata(_ sections: Any?) -> [String: String] {
        var metadata: [String: String] = [:]
        for section in (sections as? [[String: Any]] ?? []).prefix(30) where section["type"] as? String == "SONG" {
            for item in (section["metadata"] as? [[String: Any]] ?? []).prefix(100) {
                guard let title = text(item["title"])?.lowercased(), let value = text(item["text"]),
                      ["album", "released", "label", "composer"].contains(title), metadata[title] == nil else { continue }
                metadata[title] = value
            }
        }
        return metadata
    }

    private actor RateLimit {
        private let clock = ContinuousClock()
        private var nextAllowed: ContinuousClock.Instant?

        func check() throws {
            if let nextAllowed, clock.now < nextAllowed { throw Failure.rateLimited }
        }

        func recordRefusal() {
            nextAllowed = clock.now.advanced(by: .seconds(60))
        }
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
