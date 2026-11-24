import AVFoundation
import Combine
import Foundation

/// Plays `TransitionClip`s (the AutoMix demo, a playlist's passages in "Ordina per il mix") beside the
/// app's own player, never in it: the queue, the song and its position stay as they are.
///
/// What was playing pauses while a clip plays, and plays on from where it was when the page closes
/// (`close`), as long as nothing else was asked of it meanwhile: if the song is played again while a
/// clip plays (from the lock screen, a widget, headphones), the clip stops and the song goes on. A
/// song that was paused stays paused. Nothing a clip plays is counted as listened to: the app's
/// player never sees it (no history, no listening log, no scrobble, no widget).
@MainActor
final class PassagePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    /// The clip playing (its key), and how far into it.
    @Published private(set) var playing: String?
    @Published private(set) var position: Double = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?
    /// The app's player was playing (or starting) when the first clip paused it.
    private(set) var resumesQueue = false
    private var watch: AnyCancellable?

    override init() {
        super.init()
        // Played again elsewhere while a clip plays: the clip gives way, and the song isn't resumed
        // a second time on close.
        watch = PlayerController.shared.$isPlaying
            .removeDuplicates()
            .sink { [weak self] isPlaying in
                guard isPlaying, let self, self.playing != nil else { return }
                self.resumesQueue = false
                self.stop()
            }
    }

    func toggle(_ clip: TransitionClip, key: String) {
        if playing == key { stop() } else { play(clip, key: key) }
    }

    func play(_ clip: TransitionClip, key: String, from start: Double = 0) {
        stop()
        let main = PlayerController.shared
        if main.isPlaying || main.isLoading {
            resumesQueue = true
            main.pause()
        }
        guard let player = try? AVAudioPlayer(contentsOf: clip.url) else { return }
        player.delegate = self
        PlaybackVolume.shared.register(player)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.currentTime = max(0, min(start, clip.length - 1))
        guard player.play() else { return }
        self.player = player
        playing = key
        position = player.currentTime
        // Only for the progress shown on the page, and only while a clip plays.
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        timer?.invalidate()
        timer = nil
        playing = nil
        position = 0
    }

    /// The page is closing: the clip stops and the song that was playing plays on.
    func close() {
        stop()
        guard resumesQueue else { return }
        resumesQueue = false
        PlayerController.shared.resume()
    }

    private func tick() {
        guard let player else { return }
        guard player.isPlaying else { return stop() }
        position = player.currentTime
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            if self.player === player { self.stop() }
        }
    }
}
