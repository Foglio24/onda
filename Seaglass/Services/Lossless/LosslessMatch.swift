import Foundation

// The pure part of lossless sources: what a format is, which candidate is the same recording as a
// song, how a source's files are named in the caches, and what was decided for a song lately.
// Foundation only, so Tools/LosslessCheck compiles it on its own.

/// A file's or a stream's audio as it really is: its codec, sample rate, bit depth and channels, read
/// from the audio itself (see `AudioFormatProbe`) or stated by the source. A lossless codec says the
/// file keeps every sample it was made with, not that the music was never compressed before (a FLAC
/// made from an MP3 is still an MP3's sound): sources say which they are, and Seaglass says which it
/// plays, never "restored".
struct AudioFormatInfo: Codable, Equatable, Hashable, Sendable {
    enum Codec: String, Codable, Sendable {
        case flac, alac, wav, aiff, aac, opus, mp3, dolby, other

        var isLossless: Bool { self == .flac || self == .alac || self == .wav || self == .aiff }

        var name: String {
            switch self {
            case .flac: return "FLAC"
            case .alac: return "ALAC"
            case .wav: return "WAV"
            case .aiff: return "AIFF"
            case .aac: return "AAC"
            case .opus: return "Opus"
            case .mp3: return "MP3"
            case .dolby: return "Dolby"
            case .other: return "Audio"
            }
        }

        /// From a file name's extension or a MIME type's subtype.
        init(suffix: String) {
            switch suffix.lowercased() {
            case "flac", "x-flac": self = .flac
            case "alac": self = .alac
            case "wav", "wave", "x-wav": self = .wav
            case "aif", "aiff", "x-aiff": self = .aiff
            case "aac", "mp4a": self = .aac
            case "opus", "ogg", "webm": self = .opus
            case "mp3", "mpeg": self = .mp3
            case "ec3", "ac3", "eac3": self = .dolby
            default: self = .other
            }
        }
    }

    var codec: Codec
    /// Hz.
    var sampleRate: Double?
    var bitDepth: Int?
    var channels: Int?
    /// Bits per second, for lossy codecs.
    var bitrate: Int?

    var isLossless: Bool { codec.isLossless }

    /// "FLAC · 24 bit/96 kHz", "ALAC · 16 bit/44.1 kHz", "AAC · 256 kbps": what the audio is.
    var label: String {
        var parts = [codec.name]
        if isLossless {
            var detail: [String] = []
            if let bitDepth, bitDepth > 0 { detail.append("\(bitDepth) bit") }
            if let sampleRate, sampleRate > 0 { detail.append(Self.kilohertz(sampleRate)) }
            if !detail.isEmpty { parts.append(detail.joined(separator: "/")) }
        } else if let bitrate, bitrate > 0 {
            parts.append("\(Int((Double(bitrate) / 1000).rounded())) kbps")
        }
        return parts.joined(separator: " · ")
    }

    /// "44.1 kHz", "96 kHz", in the reader's language's decimal mark.
    static func kilohertz(_ rate: Double) -> String {
        let value = rate / 1000
        let text = value.rounded() == value
            ? String(Int(value))
            : value.formatted(.number.precision(.fractionLength(1)))
        return "\(text) kHz"
    }

    /// A rank for choosing between two lossless copies of one recording: more bits, then a higher rate.
    var rank: Double {
        guard isLossless else { return 0 }
        return Double(bitDepth ?? 16) * 1_000_000 + (sampleRate ?? 44_100)
    }
}

/// Where a lossless copy comes from.
enum LosslessSourceKind: String, Codable, CaseIterable, Sendable {
    /// A file the user imported (Libreria › File lossless).
    case localFile
    /// The user's own OpenSubsonic server (Navidrome and others), streaming its original files.
    case openSubsonic

    var title: String {
        switch self {
        case .localFile: return String(localized: "File personale")
        case .openSubsonic: return "OpenSubsonic"
        }
    }
}

/// A recording a source holds, as the source describes it.
struct LosslessCandidate: Codable, Equatable, Hashable, Sendable {
    var source: LosslessSourceKind
    /// The source's own id: the imported file's id, the server's song id.
    var id: String
    /// Which server or library this came from (a server's address, hashed), so two servers' ids never meet.
    var scope: String
    var title: String
    var artists: [String]
    var album: String?
    var duration: TimeInterval?
    var isrcs: [String] = []
    var format: AudioFormatInfo?
    /// The file's extension as the source states it ("flac", "m4a").
    var suffix: String?
}

/// What is known of the song to find: from the catalogue (YouTube Music), with an ISRC when there is one.
struct LosslessQuery: Equatable, Sendable {
    var title: String
    var artists: [String]
    var album: String?
    var duration: TimeInterval?
    var isrc: String?
}

/// Whether a candidate is the song asked for: the same recording, not another version of it.
enum LosslessMatcher {
    /// Kinds of version that make another recording, or another cut of it: a live take, a remix, an
    /// acoustic or instrumental one, an edit or extended cut, a speed-changed upload. A remaster is
    /// the same performance and timing, so it is not one of them.
    static let versionMarkers: [String: [String]] = [
        "live": ["live", "dal vivo", "en vivo", "en directo", "concert", "unplugged"],
        "remix": ["remix", "rmx", "rework", "bootleg", "vip mix", "club mix", "dub mix"],
        "acoustic": ["acoustic", "acustica", "acoustique", "akustik", "piano version", "stripped"],
        "instrumental": ["instrumental", "karaoke", "backing track", "base"],
        "edit": ["radio edit", "single edit", "edit", "short version"],
        "extended": ["extended", "extended mix", "original mix", "12 inch", "12\""],
        "speed": ["sped up", "speed up", "nightcore", "slowed", "reverb", "8d"],
        "demo": ["demo"],
        "cover": ["cover", "tribute"],
    ]

    /// A candidate's fit, 0…1, or nil when it is another recording or not this song at all.
    static func score(_ query: LosslessQuery, _ candidate: LosslessCandidate) -> Double? {
        // Both with ISRCs: they decide, as an ISRC names one recording (a remaster gets its own).
        let candidateISRCs = Set(candidate.isrcs.map(normalizedISRC).filter { !$0.isEmpty })
        if let isrc = query.isrc.map(normalizedISRC), !isrc.isEmpty, !candidateISRCs.isEmpty {
            guard candidateISRCs.contains(isrc) else { return nil }
            if let a = query.duration, let b = candidate.duration, abs(a - b) > 10 { return nil }
            return 1
        }
        // The same kind of version, both in the title or the album (a live album's songs are live).
        guard versions(of: query.title, album: query.album) == versions(of: candidate.title, album: candidate.album)
        else { return nil }
        let titleFit = similarity(baseTitle(query.title), baseTitle(candidate.title))
        guard titleFit >= 0.8 else { return nil }
        let artistFit = artistSimilarity(query.artists, candidate.artists)
        guard artistFit >= 0.5 else { return nil }
        let durationFit: Double
        if let a = query.duration, let b = candidate.duration, a > 0, b > 0 {
            let gap = abs(a - b)
            let free = max(3, a * 0.02)
            guard gap <= max(7, a * 0.04) else { return nil }
            durationFit = gap <= free ? 1 : 0.5
        } else {
            // Without both lengths only an exact title and artist will do.
            guard titleFit == 1, artistFit == 1 else { return nil }
            durationFit = 0.5
        }
        return 0.5 * titleFit + 0.3 * artistFit + 0.2 * durationFit
    }

    /// The best candidate that fits well enough (0.75), the better format first between equals.
    static func best(for query: LosslessQuery, among candidates: [LosslessCandidate]) -> LosslessCandidate? {
        let fitting = candidates.compactMap { candidate -> (LosslessCandidate, Double)? in
            guard candidate.format?.isLossless ?? true, let score = score(query, candidate), score >= 0.75 else { return nil }
            return (candidate, score)
        }
        return fitting.max { a, b in
            if abs(a.1 - b.1) > 0.001 { return a.1 < b.1 }
            return (a.0.format?.rank ?? 0) < (b.0.format?.rank ?? 0)
        }?.0
    }

    // MARK: Text

    static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let scalars = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(scalars).split(separator: " ").joined(separator: " ")
    }

    /// The title without what is in brackets and without "feat." and what follows.
    static func baseTitle(_ title: String) -> String {
        var text = title.lowercased()
        for (open, close) in [("(", ")"), ("[", "]"), ("{", "}")] {
            while let start = text.range(of: open), let end = text.range(of: close, range: start.upperBound..<text.endIndex) {
                text.removeSubrange(start.lowerBound..<end.upperBound)
            }
        }
        for marker in [" feat. ", " feat ", " ft. ", " ft ", " featuring ", " with "] {
            if let range = text.range(of: marker) { text = String(text[..<range.lowerBound]) }
        }
        // "Song - Live at …", "Song - 2011 Remaster": the part after a dash describes a version.
        if let dash = text.range(of: " - ") { text = String(text[..<dash.lowerBound]) }
        return normalized(text)
    }

    /// The version kinds a title (and its album) carries.
    static func versions(of title: String, album: String?) -> Set<String> {
        var found = Set<String>()
        let haystacks = [" \(normalized(title)) ", album.map { " \(normalized($0)) " }].compactMap { $0 }
        for (kind, words) in versionMarkers {
            for word in words {
                let needle = " \(normalized(word)) "
                guard needle.count > 2 else { continue }
                // An album counts only for live recordings: a remix in an album's name says little.
                for (index, haystack) in haystacks.enumerated() where index == 0 || kind == "live" {
                    if haystack.contains(needle) { found.insert(kind) }
                }
            }
        }
        // "Edit" inside "Radio Edit" or "Extended Mix" is already said by the longer marker.
        if found.contains("extended") { found.remove("edit") }
        return found
    }

    /// Token overlap of two normalized texts, 1 when equal.
    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return a.isEmpty ? 0 : 1 }
        let left = Set(a.split(separator: " ")), right = Set(b.split(separator: " "))
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(left.union(right).count)
    }

    /// 1 when an artist is named on both sides, else the best token overlap of their names.
    static func artistSimilarity(_ a: [String], _ b: [String]) -> Double {
        let left = splitArtists(a), right = splitArtists(b)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        if !Set(left).isDisjoint(with: right) { return 1 }
        var best = 0.0
        for x in left { for y in right { best = max(best, similarity(x, y)) } }
        return best
    }

    static func splitArtists(_ names: [String]) -> [String] {
        names.flatMap { name -> [String] in
            var parts = [name]
            for separator in [", ", " & ", " x ", " X ", " feat. ", " ft. ", " and ", " e ", "; ", "/"] {
                parts = parts.flatMap { $0.components(separatedBy: separator) }
            }
            return parts
        }
        .map(normalized)
        .map { $0.hasPrefix("the ") ? String($0.dropFirst(4)) : $0 }
        .filter { !$0.isEmpty }
    }

    static func normalizedISRC(_ isrc: String) -> String {
        isrc.uppercased().filter { $0.isLetter || $0.isNumber }
    }
}

/// How a source's files are named in the caches, so a compressed copy of a song never stands for its
/// lossless one: the song, the source and its scope, the source's id, and the format, all in the name.
enum LosslessCacheKey {
    /// "<videoId>__lossless-<source>-<scope>-<id>__flac24-96000": the shape of the other caches'
    /// names (`<videoId>__<format>__<kbps>`), which AutoMix's analyses are keyed on.
    static func name(videoId: String, candidate: LosslessCandidate) -> String {
        let format = candidate.format
        let codec = format?.codec.rawValue ?? AudioFormatInfo.Codec(suffix: candidate.suffix ?? "").rawValue
        let bits = format?.bitDepth.map(String.init) ?? "x"
        let rate = format?.sampleRate.map { String(Int($0)) } ?? "x"
        return "\(safe(videoId))__lossless-\(candidate.source.rawValue)-\(safe(candidate.scope))-\(safe(candidate.id))__\(codec)\(bits)-\(rate)"
    }

    /// Letters, digits, "-" and "_" only, at most 64 of them.
    static func safe(_ text: String) -> String {
        String(text.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? Character($0) : "_" }
            .prefix(64))
    }

    /// Whether a cached file's name is a lossless source's (and so never a YouTube stream's copy).
    static func isLossless(_ fileName: String) -> Bool { fileName.contains("__lossless-") }
}

/// What was decided for each song lately: the candidate found, nothing found, or a source that failed
/// while it played. Found and missing expire (a server can change); a failure lasts until the app
/// starts again, so a song never goes back and forth between sources.
struct LosslessDecisions: Sendable {
    enum Decision: Equatable, Sendable {
        case found(LosslessCandidate)
        case missing
    }

    static let foundLifetime: TimeInterval = 30 * 60
    static let missingLifetime: TimeInterval = 10 * 60

    private var decisions: [String: (decision: Decision, at: Date)] = [:]
    private var failed: Set<String> = []

    /// The decision for a song still in date (nil: ask again).
    func decision(for songID: String, now: Date = .now) -> Decision? {
        guard let entry = decisions[songID] else { return nil }
        let lifetime = entry.decision == .missing ? Self.missingLifetime : Self.foundLifetime
        guard now.timeIntervalSince(entry.at) < lifetime else { return nil }
        if case .found(let candidate) = entry.decision, hasFailed(songID, candidate) { return .missing }
        return entry.decision
    }

    mutating func record(_ decision: Decision, for songID: String, now: Date = .now) {
        decisions[songID] = (decision, now)
        if decisions.count > 500 {
            let oldest = decisions.min { $0.value.at < $1.value.at }?.key
            if let oldest { decisions[oldest] = nil }
        }
    }

    /// The source failed while the song played: not tried again for it.
    mutating func recordFailure(_ songID: String, _ candidate: LosslessCandidate) {
        failed.insert(Self.failureKey(songID, candidate))
        decisions[songID] = nil
    }

    func hasFailed(_ songID: String, _ candidate: LosslessCandidate) -> Bool {
        failed.contains(Self.failureKey(songID, candidate))
    }

    mutating func forget(_ songID: String) { decisions[songID] = nil }

    private static func failureKey(_ songID: String, _ candidate: LosslessCandidate) -> String {
        "\(songID)|\(candidate.source.rawValue)|\(candidate.scope)|\(candidate.id)"
    }
}
