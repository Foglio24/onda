import Foundation

struct Playlist: Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var tracks: [Track]
    var createdAt: Date

    var countLabel: String {
        tracks.count == 1 ? "1 brano" : "\(tracks.count) brani"
    }
}
