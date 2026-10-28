import Foundation

/// YouTube's player data for a video, from YouTube's iOS client: unlike the YouTube Music web
/// client's, it includes the loudness and is rarely refused.
enum YouTubePlayerData {
    private static let endpoint = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!
    private static let clientVersion = "20.10.4"
    private static let userAgent = "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)"

    static func response(for videoId: String) async throws -> [String: Any]? {
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
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

/// A song's general data for "Informazioni sul brano": what YouTube knows about the video and,
/// for songs of YouTube Music's catalogue, what the label sent with it. YouTube writes the latter
/// in the description ("Provided to YouTube by …", the album, ℗, "Released on: …", credits).
struct SongDetails: Sendable, Equatable {
    struct Credit: Sendable, Equatable, Hashable {
        /// As YouTube writes it ("Composer"); see `title` for the shown name.
        let role: String
        var names: [String]
    }

    var channel: String?
    var views: Int?
    var length: TimeInterval?
    /// Who delivered the song to YouTube, usually the label or distributor.
    var label: String?
    /// "℗ 2001 Daft Life Ltd. …"
    var copyright: String?
    var album: String?
    var releaseDate: Date?
    /// When the video was put on YouTube.
    var published: Date?
    var credits: [Credit] = []
    /// The text of videos without catalogue data (official videos, uploads).
    var description: String?
    /// Decibels above YouTube's reference level (-14 LUFS).
    var loudness: Double?

    static func load(videoId: String) async throws -> SongDetails {
        guard let json = try await YouTubePlayerData.response(for: videoId) else {
            throw URLError(.badServerResponse)
        }
        return SongDetails(json: json)
    }

    init() {}

    init(json: [String: Any]) {
        let video = J.dict(J.value(json, "videoDetails"))
        channel = (video?["author"] as? String).map { $0.replacingOccurrences(of: " - Topic", with: "") }
        views = (video?["viewCount"] as? String).flatMap { Int($0) }
        length = (video?["lengthSeconds"] as? String).flatMap { TimeInterval($0) }
        loudness = Self.loudness(in: json)
        published = (J.value(json, "microformat", "playerMicroformatRenderer", "publishDate") as? String)
            .flatMap(Self.date)
        if let text = video?["shortDescription"] as? String { read(description: text) }
    }

    static func loudness(in json: [String: Any]) -> Double? {
        let config = J.dict(J.value(json, "playerConfig", "audioConfig"))
        if let decibels = config?["loudnessDb"] as? Double { return decibels }
        if let absolute = config?["trackAbsoluteLoudnessLkfs"] as? Double {
            return absolute - (config?["loudnessTargetLkfs"] as? Double ?? -14)
        }
        return nil
    }

    private static let providedPrefix = "Provided to YouTube by "
    private static let releasedPrefix = "Released on:"

    /// Reads the description YouTube generates for catalogue songs; other descriptions are kept as text.
    mutating func read(description text: String) {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = lines.first, first.hasPrefix(Self.providedPrefix) else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            description = trimmed.isEmpty ? nil : trimmed
            return
        }
        label = String(first.dropFirst(Self.providedPrefix.count))
        var sawTitle = false
        for line in lines.dropFirst() {
            if line.hasPrefix("℗") || line.hasPrefix("©") {
                if copyright == nil { copyright = line }
            } else if line.hasPrefix(Self.releasedPrefix) {
                releaseDate = Self.date(line.dropFirst(Self.releasedPrefix.count)
                    .trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("Auto-generated by YouTube") {
                continue
            } else if !sawTitle, line.contains(" · ") {
                // "One More Time · Daft Punk": the title and artists, already shown.
                sawTitle = true
            } else if sawTitle, album == nil, copyright == nil, credits.isEmpty {
                // The line right after the title is the album, even with a colon in its name.
                album = line
            } else if let colon = line.range(of: ": ") {
                let role = line[..<colon.lowerBound].split(whereSeparator: \.isWhitespace).joined(separator: " ")
                let name = line[colon.upperBound...].trimmingCharacters(in: .whitespaces)
                guard !role.isEmpty, role.count <= 40, !name.isEmpty else { continue }
                addCredit(role: role, name: name)
            }
        }
    }

    private mutating func addCredit(role: String, name: String) {
        if let index = credits.firstIndex(where: { $0.role == role }) {
            if !credits[index].names.contains(name) { credits[index].names.append(name) }
        } else {
            credits.append(Credit(role: role, names: [name]))
        }
    }

    /// "2001-03-07", or a full timestamp that starts with it.
    private static func date(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(text.prefix(10)))
    }
}

extension SongDetails.Credit {
    /// The role in the app's language. Combined roles ("Producer, Synthesizer") are translated
    /// part by part; uncommon ones stay as YouTube writes them.
    var title: String {
        if let known = Self.translate(role) { return known }
        let parts = role.components(separatedBy: ", ")
        guard parts.count > 1 else { return role }
        return parts.map { Self.translate($0) ?? $0 }.joined(separator: ", ")
    }

    private static func translate(_ role: String) -> String? {
        switch role.lowercased() {
        case "composer": return String(localized: "Compositore")
        case "lyricist": return String(localized: "Autore del testo")
        case "composer lyricist", "composer, lyricist", "composer & lyricist":
            return String(localized: "Compositore e autore del testo")
        case "writer", "author", "songwriter": return String(localized: "Autore")
        case "producer": return String(localized: "Produttore")
        case "co-producer": return String(localized: "Coproduttore")
        case "executive producer": return String(localized: "Produttore esecutivo")
        case "arranger": return String(localized: "Arrangiatore")
        case "mixer", "mixing engineer": return String(localized: "Missaggio")
        case "masterer", "mastering engineer": return String(localized: "Mastering")
        case "recording engineer", "engineer": return String(localized: "Tecnico del suono")
        case "associated performer", "performer": return String(localized: "Interprete")
        case "main artist", "primary artist": return String(localized: "Artista principale")
        case "featured artist": return String(localized: "Artista ospite")
        case "studio personnel": return String(localized: "Personale di studio")
        case "programmer", "programming": return String(localized: "Programmazione")
        case "synthesizer", "synth": return String(localized: "Sintetizzatore")
        case "vocals", "vocalist", "lead vocalist", "background vocalist": return String(localized: "Voce")
        case "guitar", "guitarist": return String(localized: "Chitarra")
        case "bass", "bass guitar", "bassist": return String(localized: "Basso")
        case "drums", "drummer": return String(localized: "Batteria")
        case "keyboards", "keyboard": return String(localized: "Tastiere")
        case "piano", "pianist": return String(localized: "Pianoforte")
        case "unknown": return String(localized: "Altro")
        default: return nil
        }
    }
}
