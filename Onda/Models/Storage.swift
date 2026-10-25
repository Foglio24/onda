import Foundation

/// File locations used by the app.
enum Storage {
    static let support: URL = makeDirectory(
        URL.applicationSupportDirectory.appending(path: "Onda", directoryHint: .isDirectory))
    static let downloads: URL = makeDirectory(
        URL.documentsDirectory.appending(path: "Downloads", directoryHint: .isDirectory))
    static let covers: URL = makeDirectory(support.appending(path: "Covers", directoryHint: .isDirectory))

    static func audioFile(for videoId: String) -> URL { downloads.appending(path: "\(videoId).m4a") }
    static func artworkFile(for videoId: String) -> URL { downloads.appending(path: "\(videoId).jpg") }

    static func audioFileExists(videoId: String) -> Bool {
        FileManager.default.fileExists(atPath: audioFile(for: videoId).path)
    }

    static func localAudio(for track: Track) -> URL? {
        existing(track.videoId.map { audioFile(for: $0) })
    }

    static func localArtwork(for track: Track) -> URL? {
        existing(track.videoId.map { artworkFile(for: $0) })
    }

    private static func existing(_ url: URL?) -> URL? {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private static func makeDirectory(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
