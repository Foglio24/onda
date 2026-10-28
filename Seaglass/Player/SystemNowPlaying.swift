import Foundation

#if canImport(NowPlaying)
import NowPlaying
import Observation

/// What iOS 27's NowPlaying framework reads to draw the lock screen and Dynamic Island player.
/// On iOS 27 this replaces MPNowPlayingInfoCenter / MPRemoteCommandCenter entirely: Apple documents
/// mixing the two for local playback as undefined, and with the old path iOS shows Seaglass's song
/// but hands the player (and taps on it) to another music app.
///
/// Framework structs (Artwork, content) are only built inside computed properties, never stored,
/// so nothing breaks on iOS 26, where the framework is absent and its symbols are weakly linked.
@available(iOS 27, *)
@Observable
@MainActor
final class SeaglassMediaSessionModel: @MainActor MediaSessionRepresentable {
    struct Handlers {
        let play: @MainActor () -> Void
        let pause: @MainActor () -> Void
        let togglePlayPause: @MainActor () -> Void
        let next: @MainActor () -> Void
        let previous: @MainActor () -> Void
    }

    /// One session per app.
    let id = (Bundle.main.bundleIdentifier ?? "com.onda.player") + ".nowplaying"

    var contentID = "none"
    var title = ""
    var artist: String?
    var duration: TimeInterval = 0
    var isPlaying = false
    var elapsed: TimeInterval = 0
    var timestamp = Date()
    /// Encoded cover of the current song.
    var artworkData: Data?
    var handlers: Handlers?

    var content: (any MediaContentRepresentable)? {
        guard !title.isEmpty else { return nil }
        var artwork: Artwork?
        if let data = artworkData {
            // The system caches artwork by id, so the id changes with the song.
            artwork = Artwork(id: "\(contentID):artwork") { _ in try ArtworkRepresentation(data: data) }
        }
        let length: MediaDuration = duration > 0 ? .finite(duration) : .continuous
        return GenericContent(id: contentID, title: title, subtitle: artist, type: .audio,
                              duration: length, artwork: artwork)
    }

    var playbackSnapshot: MediaPlaybackSnapshot? {
        let state: MediaPlaybackSnapshot.PlaybackState = isPlaying ? .playing() : .paused
        return MediaPlaybackSnapshot(state: state, elapsedTime: elapsed, timestamp: timestamp)
    }

    var commands: [MediaCommand] {
        guard let handlers else { return [] }
        return [
            .play { handlers.play() },
            .pause { handlers.pause() },
            .togglePlayPause { handlers.togglePlayPause() },
            .next { handlers.next() },
            .previous { handlers.previous() },
        ]
    }
}

/// Owns Seaglass's MediaSession and asks iOS to make it the primary one once music plays.
@available(iOS 27, *)
@MainActor
final class SystemNowPlaying {
    let model = SeaglassMediaSessionModel()
    private var session: MediaSession<SeaglassMediaSessionModel>?
    private var primaryRequest: Task<Void, Never>?

    /// Called right after the audio session is activated for playback, the order Apple asks for.
    func claim() {
        guard session == nil else { return }
        let session = MediaSession(model)
        self.session = session
        primaryRequest = Task { [weak self] in
            do {
                try await session.requestToBecomeApplicationPrimary()
                UserDefaults.standard.set(1, forKey: Preferences.nowPlayingAccepted)
                // Best effort: also ask for the system-wide card (honoured only in the foreground).
                try? await session.requestToBecomeSystemPrimary()
            } catch {
                UserDefaults.standard.set(0, forKey: Preferences.nowPlayingAccepted)
                // Drop it so the next playback retries.
                if self?.session === session { self?.session = nil }
            }
        }
    }
}
#endif
