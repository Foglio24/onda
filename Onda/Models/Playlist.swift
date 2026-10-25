import Foundation

struct Playlist: Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var tracks: [Track]
    var createdAt: Date
    /// File name of a cover picked from Photos, inside `Storage.covers`.
    var coverFile: String?

    var countLabel: String {
        tracks.count == 1 ? String(localized: "1 brano") : String(localized: "\(tracks.count) brani")
    }

    var customCoverURL: URL? {
        coverFile.map { Storage.covers.appending(path: $0) }
    }
}
