import AVFoundation
import Combine
import MediaPlayer
import SwiftUI

enum RepeatMode {
    case off, all, one

    var symbol: String { self == .one ? "repeat.1" : "repeat" }

    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

enum SleepTimer: Equatable {
    case off
    case at(Date)
    case endOfTrack
}

struct QueueEntry: Identifiable {
    let index: Int
    let track: Track
    var id: Int { index }
}

enum PlayerError: LocalizedError {
    case unavailable

    var errorDescription: String? { "Questo brano non è disponibile." }
}

/// Playback position, kept apart from `PlayerController` so that only the views
/// showing time re-render several times per second.
@MainActor
final class PlaybackProgress: ObservableObject {
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
}

/// The queue and the audio engine: AVPlayer, background audio, lock screen and Control Center.
@MainActor
final class PlayerController: ObservableObject {
    static let shared = PlayerController()
    static let defaultTint = Color(red: 0.24, green: 0.18, blue: 0.42)

    @Published private(set) var queue: [Track] = []
    @Published private(set) var index = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String? = nil
    @Published private(set) var source = ""
    @Published private(set) var lyrics: LyricsState = .idle
    @Published private(set) var artworkColor = PlayerController.defaultTint
    /// "AAC · 129 kbps", or "AAC · offline" for downloaded songs.
    @Published private(set) var streamInfo: String? = nil
    @Published private(set) var shuffleEnabled = false
    @Published private(set) var sleepTimer: SleepTimer = .off
    @Published var repeatMode: RepeatMode = .off
    @Published var autoRadio: Bool {
        didSet { UserDefaults.standard.set(autoRadio, forKey: "player.autoRadio") }
    }

    let progress = PlaybackProgress()

    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }

    var upcoming: [QueueEntry] {
        queue.indices.filter { $0 > index }.map { QueueEntry(index: $0, track: queue[$0]) }
    }

    private let player = AVPlayer()
    private let scrobbler = Scrobbler()
    private var cancellables = Set<AnyCancellable>()
    private var itemStatus: AnyCancellable?
    private var timeObserver: Any?
    private var loadTask: Task<Void, Never>?
    private var lyricsTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?
    private var nowPlayingArtwork: MPMediaItemArtwork?
    /// The upcoming songs in their original order, to restore when shuffle is turned off.
    private var unshuffledUpcoming: [Track] = []
    private var playWhenReady = true
    private var isExtendingQueue = false
    private var failuresInARow = 0
    private var retriedCurrentItem = false
    private var lastTick: TimeInterval = 0

    private init() {
        autoRadio = UserDefaults.standard.object(forKey: "player.autoRadio") as? Bool ?? true
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        try? session.setSupportsMultichannelContent(true)
        observePlayer()
        configureRemoteCommands()
    }

    // MARK: Queue

    /// Replaces the queue. With shuffle on, the chosen song plays first and the rest follow in random order.
    func play(_ tracks: [Track], startAt start: Int = 0, source: String, startRadio: Bool = false,
              shuffled: Bool? = nil) {
        guard tracks.indices.contains(start) else { return }
        if let shuffled { shuffleEnabled = shuffled }
        var list = tracks
        var first = start
        if shuffleEnabled {
            let chosen = list.remove(at: start)
            unshuffledUpcoming = list
            list = [chosen] + list.shuffled()
            first = 0
        } else {
            unshuffledUpcoming = []
        }
        queue = list
        index = first
        self.source = source
        failuresInARow = 0
        loadCurrent()
        if startRadio { Task { await extendQueue() } }
    }

    /// Plays a song followed by YouTube Music's radio of similar songs.
    func playRadio(from track: Track) {
        play([track], source: "Radio · \(track.title)", startRadio: true)
    }

    func playNext(_ track: Track) {
        guard current != nil else { return play([track], source: "Coda") }
        queue.insert(track, at: index + 1)
        unshuffledUpcoming.insert(track, at: 0)
    }

    func addToQueue(_ track: Track) {
        guard current != nil else { return play([track], source: "Coda") }
        queue.append(track)
        unshuffledUpcoming.append(track)
    }

    func jump(to position: Int) {
        guard queue.indices.contains(position) else { return }
        index = position
        loadCurrent()
    }

    func toggleShuffle() {
        guard !queue.isEmpty else {
            shuffleEnabled.toggle()
            return
        }
        let upcomingTracks = Array(queue[(index + 1)...])
        if shuffleEnabled {
            // Back to the original order; songs added while shuffled keep their place at the end.
            let remaining = Set(upcomingTracks.map(\.id))
            var restored = unshuffledUpcoming.filter { remaining.contains($0.id) }.uniqued()
            let restoredIDs = Set(restored.map(\.id))
            restored += upcomingTracks.filter { !restoredIDs.contains($0.id) }
            queue.replaceSubrange((index + 1)..., with: restored)
            unshuffledUpcoming = []
        } else {
            unshuffledUpcoming = upcomingTracks
            queue.replaceSubrange((index + 1)..., with: upcomingTracks.shuffled())
        }
        shuffleEnabled.toggle()
    }

    func removeUpcoming(atOffsets offsets: IndexSet) {
        let removed = Set(offsets.map { queue[$0 + index + 1].id })
        queue.remove(atOffsets: IndexSet(offsets.map { $0 + index + 1 }))
        unshuffledUpcoming.removeAll { removed.contains($0.id) }
    }

    func moveUpcoming(fromOffsets source: IndexSet, toOffset destination: Int) {
        queue.move(fromOffsets: IndexSet(source.map { $0 + index + 1 }), toOffset: destination + index + 1)
    }

    // MARK: Transport

    func togglePlayPause() {
        if isPlaying || (isLoading && playWhenReady) {
            pause()
        } else {
            resume()
        }
    }

    func pause() {
        playWhenReady = false
        player.pause()
        updateNowPlayingInfo()
    }

    func resume() {
        guard current != nil else { return }
        playWhenReady = true
        if player.currentItem != nil {
            activateSession()
            player.play()
        } else if !isLoading {
            loadCurrent()
        }
    }

    func next() {
        advance()
    }

    func previous() {
        if progress.currentTime > 3 || index == 0 {
            seek(to: 0)
        } else {
            index -= 1
            loadCurrent()
        }
    }

    func seek(to seconds: TimeInterval) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        progress.currentTime = seconds
        lastTick = seconds
        updateNowPlayingInfo()
    }

    func cycleRepeat() {
        repeatMode = repeatMode.next
    }

    // MARK: Sleep timer

    func setSleepTimer(minutes: Int) {
        sleepTask?.cancel()
        sleepTimer = .at(Date.now.addingTimeInterval(TimeInterval(minutes * 60)))
        sleepTask = Task {
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard !Task.isCancelled else { return }
            self.sleepTimer = .off
            self.pause()
        }
    }

    func stopAtEndOfTrack() {
        sleepTask?.cancel()
        sleepTimer = .endOfTrack
    }

    func cancelSleepTimer() {
        sleepTask?.cancel()
        sleepTimer = .off
    }

    // MARK: Settings hooks

    /// Applies the "Audio spaziale" preference to the song that is playing.
    func applySpatialAudioPreference() {
        player.currentItem?.allowedAudioSpatializationFormats = Self.spatializationFormats
    }

    /// Applies the "Colori dinamici" preference to the player tint.
    func applyThemePreference() {
        if Preferences.dynamicColorsEnabled, let track = current {
            loadArtwork(for: track)
        } else {
            artworkColor = Self.defaultTint
        }
    }

    private static var spatializationFormats: AVAudioSpatializationFormats {
        Preferences.spatialAudioEnabled ? .monoStereoAndMultichannel : []
    }

    // MARK: Loading

    private func loadCurrent() {
        loadTask?.cancel()
        guard let track = current else { return }
        let position = index
        playWhenReady = true
        retriedCurrentItem = false
        isLoading = true
        errorMessage = nil
        streamInfo = nil
        itemStatus = nil
        player.replaceCurrentItem(with: nil)
        progress.currentTime = 0
        progress.duration = track.duration ?? 0
        lastTick = 0
        lyrics = .loading
        loadArtwork(for: track)
        updateNowPlayingInfo()

        loadTask = Task {
            do {
                var playable = track
                if playable.videoId == nil {
                    // Last.fm tracks only know artist and title: find them on YouTube Music first.
                    playable = try await InnerTube.shared.resolve(track)
                    guard !Task.isCancelled, self.index == position else { return }
                    self.queue[position] = playable
                    self.loadArtwork(for: playable)
                }
                let stream = try await self.stream(for: playable)
                guard !Task.isCancelled, self.index == position else { return }
                self.streamInfo = stream.label
                self.start(url: stream.url, track: playable)
            } catch {
                guard !Task.isCancelled, self.index == position else { return }
                self.fail(error.localizedDescription)
            }
        }
        extendQueueIfNeeded()
    }

    private func stream(for track: Track) async throws -> (url: URL, label: String) {
        if let local = Storage.localAudio(for: track) { return (local, "AAC · offline") }
        guard let videoId = track.videoId else { throw PlayerError.unavailable }
        let stream = try await StreamResolver.shared.audioStream(for: videoId, quality: Preferences.streamingQuality)
        return (stream.url, stream.label)
    }

    private func start(url: URL, track: Track, isRetry: Bool = false) {
        let item = AVPlayerItem(url: url)
        item.allowedAudioSpatializationFormats = Self.spatializationFormats
        itemStatus = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { status in self.itemStatusChanged(status, track: track) }
        player.replaceCurrentItem(with: item)
        if playWhenReady {
            activateSession()
            player.play()
        }
        guard !isRetry else { return }
        scrobbler.begin(track)
        Library.shared.recordPlay(track)
        loadLyrics(for: track)
        prefetchNext()
        updateNowPlayingInfo()
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status, track: Track) {
        switch status {
        case .readyToPlay:
            isLoading = false
            failuresInARow = 0
            updateNowPlayingInfo()
        case .failed:
            let message = player.currentItem?.error?.localizedDescription
                ?? PlayerError.unavailable.localizedDescription
            guard !retriedCurrentItem, let videoId = track.videoId, Storage.localAudio(for: track) == nil else {
                return fail(message)
            }
            // Stream URLs expire after a few hours: fetch a fresh one once before giving up.
            retriedCurrentItem = true
            let position = index
            Task {
                await StreamResolver.shared.invalidate(videoId)
                let stream = try? await StreamResolver.shared.audioStream(
                    for: videoId, quality: Preferences.streamingQuality)
                guard self.index == position else { return }
                if let stream {
                    self.streamInfo = stream.label
                    self.start(url: stream.url, track: track, isRetry: true)
                } else {
                    self.fail(message)
                }
            }
        default:
            break
        }
    }

    private func fail(_ message: String) {
        isLoading = false
        errorMessage = message
        failuresInARow += 1
        let failedIndex = index
        // Skip unplayable songs, but don't spin through a whole broken queue.
        guard failuresInARow < 3, index + 1 < queue.count else { return }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard self.index == failedIndex, self.errorMessage == message else { return }
            self.index += 1
            self.loadCurrent()
        }
    }

    private func advance() {
        if index + 1 < queue.count {
            index += 1
            loadCurrent()
        } else if repeatMode == .all, !queue.isEmpty {
            index = 0
            loadCurrent()
        } else {
            Task {
                if self.autoRadio, await self.extendQueue() {
                    self.index += 1
                    self.loadCurrent()
                } else {
                    self.player.pause()
                    self.seek(to: 0)
                }
            }
        }
    }

    private func itemFinished() {
        if sleepTimer == .endOfTrack {
            sleepTimer = .off
            pause()
            return
        }
        guard repeatMode == .one, let track = current else { return advance() }
        seek(to: 0)
        scrobbler.begin(track)
        player.play()
    }

    /// Keeps the music going: when few songs are left, appends a radio based on the current one.
    private func extendQueueIfNeeded() {
        guard autoRadio, queue.count - index <= 3 else { return }
        Task { await extendQueue() }
    }

    @discardableResult
    private func extendQueue() async -> Bool {
        guard !isExtendingQueue,
              let seed = current?.videoId ?? queue.last(where: { $0.videoId != nil })?.videoId else { return false }
        isExtendingQueue = true
        defer { isExtendingQueue = false }
        guard let radio = try? await InnerTube.shared.radio(for: seed) else { return false }
        let known = Set(queue.map(\.id))
        let skipLong = Preferences.skipsLongMixes
        let fresh = radio.filter { track in
            !known.contains(track.id) && !(skipLong && (track.duration ?? 0) > Preferences.longMixThreshold)
        }
        guard !fresh.isEmpty else { return false }
        let added = Array(fresh.prefix(30))
        unshuffledUpcoming.append(contentsOf: added)
        queue.append(contentsOf: shuffleEnabled ? added.shuffled() : added)
        return true
    }

    /// Resolves the next stream URL early, so the switch is quick even with the screen locked.
    private func prefetchNext() {
        guard index + 1 < queue.count else { return }
        let upNext = queue[index + 1]
        guard let videoId = upNext.videoId, Storage.localAudio(for: upNext) == nil else { return }
        let quality = Preferences.streamingQuality
        Task.detached(priority: .utility) {
            _ = try? await StreamResolver.shared.audioStream(for: videoId, quality: quality)
        }
    }

    private func loadLyrics(for track: Track) {
        lyricsTask?.cancel()
        lyrics = .loading
        lyricsTask = Task {
            let result = await LyricsService.shared.lyrics(for: track)
            guard !Task.isCancelled, self.current?.id == track.id else { return }
            self.lyrics = result
        }
    }

    private func loadArtwork(for track: Track) {
        artworkTask?.cancel()
        nowPlayingArtwork = nil
        artworkTask = Task {
            guard let artwork = await ArtworkLoader.shared.artwork(for: track),
                  !Task.isCancelled, self.current?.id == track.id else { return }
            self.nowPlayingArtwork = Self.makeArtwork(artwork.image)
            if Preferences.dynamicColorsEnabled, let tint = artwork.tint {
                self.artworkColor = Color(uiColor: tint)
            } else {
                self.artworkColor = Self.defaultTint
            }
            self.updateNowPlayingInfo()
        }
    }

    // MARK: System integration

    private func activateSession() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func observePlayer() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { time in
            let seconds = time.seconds
            MainActor.assumeIsolated { self.tick(seconds) }
        }

        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { status in
                self.isPlaying = status != .paused
                if status == .playing { self.isLoading = false }
                self.updateNowPlayingInfo()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)
            .receive(on: DispatchQueue.main)
            .sink { note in
                guard (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                self.itemFinished()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main)
            .sink { note in self.handleInterruption(note) }
            .store(in: &cancellables)
    }

    private func tick(_ seconds: TimeInterval) {
        guard seconds.isFinite else { return }
        let delta = seconds - lastTick
        lastTick = seconds
        progress.currentTime = seconds
        if let length = player.currentItem?.duration.seconds, length.isFinite, length > 0,
           abs(progress.duration - length) > 0.5 {
            progress.duration = length
            updateNowPlayingInfo()
        }
        if player.timeControlStatus == .playing, delta > 0, delta < 1.5 {
            scrobbler.addListeningTime(delta, trackLength: progress.duration)
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: rawType) == .ended,
              let rawOptions = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
              AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume),
              playWhenReady else { return }
        player.play()
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { _ in
            Task { @MainActor in self.resume() }
            return .success
        }
        center.pauseCommand.addTarget { _ in
            Task { @MainActor in self.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { _ in
            Task { @MainActor in self.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { _ in
            Task { @MainActor in self.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { _ in
            Task { @MainActor in self.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in self.seek(to: position) }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        let center = MPNowPlayingInfoCenter.default()
        guard let track = current else {
            center.nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyPlaybackDuration: progress.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: progress.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: player.timeControlStatus == .playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let album = track.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if let nowPlayingArtwork { info[MPMediaItemPropertyArtwork] = nowPlayingArtwork }
        center.nowPlayingInfo = info
    }

    /// Built outside the main actor: the system calls the handler on a background queue.
    nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
