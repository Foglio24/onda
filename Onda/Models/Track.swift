import Foundation

/// A song as the app knows it. Tracks coming from Last.fm have no `videoId`
/// until the player looks them up on YouTube Music.
struct Track: Codable, Hashable, Identifiable {
    var id: String
    var videoId: String?
    var title: String
    var artist: String
    var primaryArtist: String
    var album: String?
    var duration: TimeInterval?
    var artworkURL: URL?
    /// Original Last.fm identities, retained when YouTube uses a different title or artist.
    /// Optional so libraries saved by older versions still decode.
    var sourceIDs: [String]?

    init(videoId: String?, title: String, artists: [String], album: String? = nil,
         duration: TimeInterval? = nil, artworkURL: URL? = nil) {
        let names = artists.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        self.videoId = videoId
        self.title = title
        self.artist = names.isEmpty ? String(localized: "Artista sconosciuto") : names.joined(separator: ", ")
        self.primaryArtist = names.first ?? ""
        self.album = album
        self.duration = duration
        self.artworkURL = artworkURL
        self.id = videoId ?? "\(names.first?.lowercased() ?? "")|\(title.lowercased())"
    }

    var subtitle: String {
        [artist, album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var mediumArtworkURL: URL? { resizedArtwork(226) }
    var largeArtworkURL: URL? { resizedArtwork(1080) }

    var shareURL: URL? {
        videoId.flatMap { URL(string: "https://music.youtube.com/watch?v=\($0)") }
    }

    /// Metadata can identify an unresolved Last.fm song, but must never merge two
    /// different YouTube recordings (for example a studio and a live version).
    func isSameRecording(as other: Track) -> Bool {
        if let videoId, let otherID = other.videoId { return videoId == otherID }
        if id == other.id { return true }
        if videoId == nil, other.sourceIDs?.contains(id) == true { return true }
        if other.videoId == nil, sourceIDs?.contains(other.id) == true { return true }
        let artist = Self.identityText(self.primaryArtist)
        let title = Self.identityText(self.title)
        return !artist.isEmpty && !title.isEmpty
            && artist == Self.identityText(other.primaryArtist)
            && title == Self.identityText(other.title)
    }

    func retainingIdentity(of original: Track) -> Track {
        var result = self
        var aliases = Set(sourceIDs ?? [])
        aliases.formUnion(original.sourceIDs ?? [])
        if original.videoId == nil { aliases.insert(original.id) }
        result.sourceIDs = aliases.isEmpty ? nil : aliases.sorted()
        return result
    }

    /// Folded texts, kept because rows on screen compare unresolved songs with the whole library.
    private static let identityCache = NSCache<NSString, NSString>()

    private static func identityText(_ value: String) -> String {
        if let cached = identityCache.object(forKey: value as NSString) { return cached as String }
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                   locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        identityCache.setObject(folded as NSString, forKey: value as NSString)
        return folded
    }

    /// YouTube Music artwork URLs carry their size as a `=wNNN-hNNN` suffix.
    private func resizedArtwork(_ size: Int) -> URL? {
        guard let artworkURL else { return nil }
        let string = artworkURL.absoluteString
        guard let range = string.range(of: #"=w\d+-h\d+"#, options: .regularExpression) else { return artworkURL }
        return URL(string: string.replacingCharacters(in: range, with: "=w\(size)-h\(size)"))
    }
}

extension Array where Element == Track {
    /// Keeps order, preferring the resolved copy of an unresolved duplicate.
    func uniqued() -> [Track] {
        var result: [Track] = []
        for track in self {
            if let position = result.firstIndex(where: { $0.isSameRecording(as: track) }) {
                if result[position].videoId == nil, track.videoId != nil {
                    result[position] = track.retainingIdentity(of: result[position])
                } else {
                    result[position] = result[position].retainingIdentity(of: track)
                }
            } else {
                result.append(track)
            }
        }
        return result
    }

    /// Replaces unresolved references and removes a duplicate of the chosen video,
    /// while preserving any other resolved video with matching title/artist.
    func reconciling(original: Track, resolved: Track) -> [Track] {
        let canonical = resolved.retainingIdentity(of: original)
        return map { track in
            if track.videoId != nil {
                return track.isSameRecording(as: canonical) ? canonical.retainingIdentity(of: track) : track
            }
            return track.isSameRecording(as: original) || track.isSameRecording(as: canonical)
                ? canonical.retainingIdentity(of: track) : track
        }.uniqued()
    }
}
