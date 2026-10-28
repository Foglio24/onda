import Foundation

/// Decides when the current track counts as listened, following Last.fm's rules:
/// tracks longer than 30 seconds, played for half their length or for 4 minutes.
@MainActor
final class Scrobbler {
    private var track: Track?
    private var startedAt = Date()
    private var listened: TimeInterval = 0
    private var submitted = false

    func begin(_ track: Track) {
        self.track = track
        startedAt = Date()
        listened = 0
        submitted = false
        Task { await LastFM.shared.updateNowPlaying(track) }
    }

    func addListeningTime(_ seconds: TimeInterval, trackLength: TimeInterval) {
        guard let track, !submitted else { return }
        listened += seconds
        let length = trackLength > 0 ? trackLength : (track.duration ?? 0)
        guard length > 30, listened >= min(length / 2, 240) else { return }
        submitted = true
        let timestamp = startedAt
        Task { await LastFM.shared.scrobble(track, startedAt: timestamp) }
    }
}
