import Foundation

struct LyricLine: Identifiable, Hashable {
    let id: Int
    let time: TimeInterval
    let text: String
}

enum LyricsState: Equatable {
    case idle
    case loading
    case unavailable
    case synced([LyricLine])
    case plain(String)
}

/// Lyrics from LRCLIB (https://lrclib.net), a free and open lyrics database.
struct LyricsService {
    static let shared = LyricsService()

    private struct Record: Decodable {
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    func lyrics(for track: Track) async -> LyricsState {
        var record: Record?
        // The exact-match endpoint needs album and duration.
        if let album = track.album, let duration = track.duration {
            record = try? await fetch("get", query: [
                "artist_name": track.primaryArtist,
                "track_name": track.title,
                "album_name": album,
                "duration": String(Int(duration.rounded())),
            ], as: Record.self)
        }
        if record?.syncedLyrics == nil {
            let results = (try? await fetch("search", query: [
                "artist_name": track.primaryArtist,
                "track_name": Self.cleanTitle(track.title),
            ], as: [Record].self)) ?? []
            let best = results.min { rank($0, for: track) < rank($1, for: track) }
            if best?.syncedLyrics != nil || record == nil { record = best ?? record }
        }

        guard let record else { return .unavailable }
        if record.instrumental == true { return .plain(String(localized: "♪ Brano strumentale")) }
        if let synced = record.syncedLyrics {
            let lines = Self.parseLRC(synced)
            if !lines.isEmpty { return .synced(lines) }
        }
        if let plain = record.plainLyrics, !plain.isEmpty { return .plain(plain) }
        return .unavailable
    }

    private func fetch<T: Decodable>(_ path: String, query: [String: String], as type: T.Type) async throws -> T {
        var components = URLComponents(string: "https://lrclib.net/api/\(path)")!
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        // URLComponents leaves "+" alone, which servers read as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: components.url!)
        request.setValue("Seaglass/1.0 (personal iOS build)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.fileDoesNotExist) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Lower is better: synced lyrics first, then the closest duration.
    private func rank(_ record: Record, for track: Track) -> Double {
        var score = 0.0
        if record.syncedLyrics == nil { score += 1_000 }
        if record.syncedLyrics == nil && record.plainLyrics == nil { score += 10_000 }
        if let a = record.duration, let b = track.duration { score += abs(a - b) } else { score += 30 }
        return score
    }

    /// "Song (feat. X) [Remastered]" -> "Song", which LRCLIB matches more reliably.
    private static func cleanTitle(_ title: String) -> String {
        let cleaned = title
            .replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? title : cleaned
    }

    /// Parses "[mm:ss.xx] text" lines; a line may carry several timestamps.
    static func parseLRC(_ lrc: String) -> [LyricLine] {
        guard let regex = try? NSRegularExpression(pattern: #"\[(\d+):(\d+(?:[.:]\d+)?)\]"#) else { return [] }
        var timed: [(TimeInterval, String)] = []
        for raw in lrc.components(separatedBy: .newlines) {
            let line = raw as NSString
            let matches = regex.matches(in: raw, range: NSRange(location: 0, length: line.length))
            guard let last = matches.last else { continue }
            let text = line.substring(from: last.range.location + last.range.length)
                .trimmingCharacters(in: .whitespaces)
            for match in matches {
                let minutes = Double(line.substring(with: match.range(at: 1))) ?? 0
                let seconds = Double(line.substring(with: match.range(at: 2))
                    .replacingOccurrences(of: ":", with: ".")) ?? 0
                timed.append((minutes * 60 + seconds, text))
            }
        }
        return timed
            .sorted { $0.0 < $1.0 }
            .enumerated()
            .map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
    }
}
