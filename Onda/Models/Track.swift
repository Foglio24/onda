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

    /// YouTube Music artwork URLs carry their size as a `=wNNN-hNNN` suffix.
    private func resizedArtwork(_ size: Int) -> URL? {
        guard let artworkURL else { return nil }
        let string = artworkURL.absoluteString
        guard let range = string.range(of: #"=w\d+-h\d+"#, options: .regularExpression) else { return artworkURL }
        return URL(string: string.replacingCharacters(in: range, with: "=w\(size)-h\(size)"))
    }
}

extension Array where Element == Track {
    /// Drops repeated tracks, keeping the first occurrence.
    func uniqued() -> [Track] {
        var seen = Set<String>()
        return filter { seen.insert($0.id).inserted }
    }
}
