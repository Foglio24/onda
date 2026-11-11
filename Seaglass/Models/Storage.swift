import Foundation
import os

/// Where the user's own songs are (see `LocalMusic`), for the audio code, which asks from any thread.
enum LocalFiles {
    struct Entry: Sendable {
        let url: URL
        /// The file's format as shown beside the song's quality ("FLAC", "MP3").
        let label: String
        /// The embedded cover, once it has been read.
        let cover: URL?
        /// The name the song's analyses (AutoMix) are kept under: not the file's, which says nothing
        /// ("01 Intro" is in a thousand albums), and new when the file's size changes.
        let analysisKey: String
    }

    private struct State: Sendable {
        var byID: [String: Entry] = [:]
        var keyByPath: [String: String] = [:]
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func replace(with entries: [String: Entry]) {
        var keys: [String: String] = [:]
        for entry in entries.values { keys[entry.url.path] = entry.analysisKey }
        let next = State(byID: entries, keyByPath: keys)
        state.withLock { $0 = next }
    }

    static func entry(forID id: String?) -> Entry? {
        guard let id, Track.isLocalID(id) else { return nil }
        return state.withLock { $0.byID[id] }
    }

    static func analysisKey(for url: URL) -> String? {
        state.withLock { $0.keyByPath[url.path] }
    }
}

/// File locations used by the app.
///
/// On a Mac the app isn't sandboxed: signed ad hoc, each version has a signature of its own, and macOS
/// would ask at every update whether the new one may open the old one's container. So it has no
/// container, and its folders are its own ones in the user's Library (Application Support/Seaglass,
/// Caches/com.onda.player), never the user's Documents.
enum Storage {
    static let support: URL = makeDirectory(
        ProcessInfo.processInfo.isMacCatalystApp
            ? URL.applicationSupportDirectory.appending(path: "Seaglass", directoryHint: .isDirectory)
            // The app was called Onda: its folder keeps that name, so nothing is lost.
            : URL.applicationSupportDirectory.appending(path: "Onda", directoryHint: .isDirectory))
    /// The app's caches: on a Mac, in a folder of its own.
    static let caches: URL = ProcessInfo.processInfo.isMacCatalystApp
        ? URL.cachesDirectory.appending(path: "com.onda.player", directoryHint: .isDirectory)
        : URL.cachesDirectory
    /// Documents, shown in the Files app on an iPhone; on a Mac, a folder of the app's own.
    static let documents: URL = ProcessInfo.processInfo.isMacCatalystApp
        ? support.appending(path: "Documents", directoryHint: .isDirectory)
        : URL.documentsDirectory
    /// Downloaded songs. Up to 1.5.0 they were in Documents, which is now shown in the Files app
    /// (for app updates), so they move here once; if the move fails, the old folder is kept.
    static let downloads: URL = {
        let current = support.appending(path: "Downloads", directoryHint: .isDirectory)
        let old = documents.appending(path: "Downloads", directoryHint: .isDirectory)
        let manager = FileManager.default
        if manager.fileExists(atPath: old.path), !manager.fileExists(atPath: current.path) {
            do {
                try manager.moveItem(at: old, to: current)
            } catch {
                return makeDirectory(old)
            }
        }
        return makeDirectory(current)
    }()
    /// App updates downloaded from GitHub; Documents is visible in Files (Sul mio iPhone › Seaglass).
    static let updates: URL = makeDirectory(
        documents.appending(path: updatesFolderName, directoryHint: .isDirectory))
    static let updatesFolderName = String(localized: "Aggiornamenti")
    static let covers: URL = makeDirectory(support.appending(path: "Covers", directoryHint: .isDirectory))
    /// AI models downloaded on demand (karaoke).
    static let models: URL = makeDirectory(support.appending(path: "Models", directoryHint: .isDirectory))
    /// Vocals / instrumental stems made by the karaoke model, kept for replays.
    static let stems: URL = makeDirectory(
        caches.appending(path: "KaraokeStems", directoryHint: .isDirectory))
    /// The covers read from the user's own songs (see `LocalMusic`); the songs themselves stay where they are.
    static let localCovers: URL = makeDirectory(support.appending(path: "LocalCovers", directoryHint: .isDirectory))

    static func audioFile(for videoId: String) -> URL { downloads.appending(path: "\(videoId).m4a") }
    static func artworkFile(for videoId: String) -> URL { downloads.appending(path: "\(videoId).jpg") }

    static func audioFileExists(videoId: String) -> Bool {
        FileManager.default.fileExists(atPath: audioFile(for: videoId).path)
    }

    static func localAudio(for track: Track) -> URL? {
        // The user's own song: its file where it is, as long as its folder can be opened.
        if track.isLocal { return existing(LocalFiles.entry(forID: track.videoId)?.url) }
        return existing(track.videoId.map { audioFile(for: $0) })
    }

    static func localArtwork(for track: Track) -> URL? {
        if track.isLocal { return existing(LocalFiles.entry(forID: track.videoId)?.cover) }
        return existing(track.videoId.map { artworkFile(for: $0) })
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
