import Foundation

/// An identified recording, before the player looks it up in YouTube Music. Extra catalogue
/// metadata is optional: a successful recognition does not always include streaming links.
struct RecognizedSong: Equatable {
    let track: Track
    var title: String { track.title }
    var artist: String { track.artist }
    var album: String? { track.album }
    let releaseDate: String?
    let label: String?
    let genre: String?
    let composer: String?
    let isrc: String?
    let songURL: URL?
    let appleMusicURL: URL?
    let spotifyURL: URL?
}
