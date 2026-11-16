import Foundation

/// Copies playlists from the user's Spotify account into the library: the songs are read from the
/// account (private playlists too, and past the 100 songs of a public link) and each one is looked
/// up on YouTube Music by PlaylistImporter, as for a link or a file: the same rules, the same summary.
@MainActor
final class SpotifyAccountImport: ObservableObject {
    static let shared = SpotifyAccountImport()

    /// What the import is doing right now, for the sheet.
    @Published private(set) var status: String?

    struct Result {
        let outcomes: [PlaylistImporter.Outcome]
        /// Why the import stopped before the last playlist, if it did (the ones before it are kept).
        let stopped: String?
    }

    private var web: SpotifyWeb?

    private init() {}

    /// The user's playlists, signing in to Spotify first if needed.
    func playlists() async throws -> [SpotifyPlaylist] {
        defer { status = nil }
        let reader = try await SpotifySession.shared.connect { status = $0 }
        web = reader
        let found = try await reader.playlists()
        guard !found.isEmpty else { throw SpotifyImportError.noPlaylists }
        return found
    }

    func importPlaylists(_ selected: [SpotifyPlaylist]) async throws -> Result {
        defer { status = nil }
        var outcomes: [PlaylistImporter.Outcome] = []
        for (index, playlist) in selected.enumerated() {
            try Task.checkCancellation()
            status = String(localized: "Playlist \(index + 1) di \(selected.count): \(playlist.name)")
            do {
                let content = try await withSession { try await $0.content(of: playlist.uri) }
                // Signing in again may have changed the text meanwhile.
                status = String(localized: "Playlist \(index + 1) di \(selected.count): \(playlist.name)")
                let source = PlaylistImportSource.spotify(name: playlist.name, content: content)
                outcomes.append(try await PlaylistImporter.shared.importPlaylist(from: source, service: "Spotify"))
            } catch ImportError.empty {
                continue
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if outcomes.isEmpty { throw error }
                return Result(outcomes: outcomes, stopped: error.localizedDescription)
            }
        }
        if outcomes.isEmpty { throw ImportError.empty }
        return Result(outcomes: outcomes, stopped: nil)
    }

    /// The sheet is gone: the web player is stopped and the reader, which sends through it, is dropped.
    func end() {
        web = nil
        SpotifySession.shared.close()
    }

    func signOut() async {
        web = nil
        await SpotifySession.shared.signOut()
    }

    /// The token lasts about an hour: when it has expired, sign in again (the page is signed in already).
    private func withSession<T>(_ block: (SpotifyWeb) async throws -> T) async throws -> T {
        let current: SpotifyWeb
        if let web { current = web } else {
            current = try await SpotifySession.shared.connect { status = $0 }
            web = current
        }
        do {
            return try await block(current)
        } catch SpotifyImportError.sessionExpired {
            let fresh = try await SpotifySession.shared.connect { status = $0 }
            web = fresh
            return try await block(fresh)
        }
    }
}
