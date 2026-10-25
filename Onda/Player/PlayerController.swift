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

/// The queue and the audio engine: AVPlayer, crossfade, background audio, lock screen and Control Center.
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
    /// "AAC · 129 kbps", "Opus · 160 kbps", or "… · offline" for downloaded songs.
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

    /// The player of the current song. During a crossfade a fresh one takes over
    /// while `outgoingPlayer` fades the previous song out.
    private var player = AVPlayer()
    private var outgoingPlayer: AVPlayer?
    private var observedPlayer: AVPlayer?
    private var timeObserver: Any?
    /// iOS 27+ with the iOS 27 SDK: the NowPlaying framework session (`SystemNowPlaying`), used instead of
    /// MPNowPlayingInfoCenter / MPRemoteCommandCenter. Stored type-erased because the type only exists on iOS 27.
    /// (MPNowPlayingSession is not used: removing the player it was created with at the end of a
    /// crossfade crashed the app, and it didn't change which app owned the system player anyway.)
    private var systemNowPlayingBox: AnyObject?
    /// Cover of the current song, encoded for the iOS 27 player.
    private var currentArtworkData: Data?
    private var playerCancellables = Set<AnyCancellable>()
    private var cancellables = Set<AnyCancellable>()
    private var itemStatus: AnyCancellable?

    private let scrobbler = Scrobbler()
    private var loadTask: Task<Void, Never>?
    private var lyricsTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?
    private var fadeOutTask: Task<Void, Never>?
    private var fadeInTask: Task<Void, Never>?
    /// Prepares the local copy of the streaming song (see `switchToLocal`).
    private var upgradeTask: Task<Void, Never>?
    /// A seek made while streaming, applied when the local copy takes over.
    private var requestedSeek: (time: TimeInterval, at: Date)?
    /// Seconds of fade-in for the song being loaded as part of a crossfade.
    private var pendingFadeIn: TimeInterval?
    /// Catalogue length of the song fading out, to know how much of it is left.
    private var outgoingLength: TimeInterval = 0
    private var nowPlayingArtwork: MPMediaItemArtwork?
    /// The upcoming songs in their original order, to restore when shuffle is turned off.
    private var unshuffledUpcoming: [Track] = []
    private var playWhenReady = true
    private var isExtendingQueue = false
    private var failuresInARow = 0
    private var retriedCurrentItem = false
    /// Set once the current song has ended (or started fading out), so it is never finished twice.
    private var finishedCurrent = false
    private var lastTick: TimeInterval = 0

    private init() {
        autoRadio = UserDefaults.standard.object(forKey: "player.autoRadio") as? Bool ?? true
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setSupportsMultichannelContent(true)
        var usesNowPlayingFramework = false
        #if canImport(NowPlaying)
        if #available(iOS 27, *) {
            let system = SystemNowPlaying()
            system.model.handlers = OndaMediaSessionModel.Handlers(
                play: { self.resume() },
                pause: { self.pause() },
                togglePlayPause: { self.togglePlayPause() },
                next: { self.next() },
                previous: { self.previous() })
            systemNowPlayingBox = system
            usesNowPlayingFramework = true
        }
        #endif
        if !usesNowPlayingFramework {
            configureRemoteCommands(MPRemoteCommandCenter.shared())
            UserDefaults.standard.removeObject(forKey: Preferences.nowPlayingAccepted)
        }
        UserDefaults.standard.set(usesNowPlayingFramework ? "NowPlaying (iOS 27)" : "MPNowPlayingInfoCenter",
                                  forKey: Preferences.nowPlayingBackend)
        attach(player)
        observeNotifications()
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
        endCrossfade()
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
        if let asset = player.currentItem?.asset as? AVURLAsset, !asset.url.isFileURL {
            // Seeking in YouTube's streams is unreliable: remember it for when the local copy takes over.
            requestedSeek = (seconds, Date.now)
        }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        progress.currentTime = seconds
        lastTick = seconds
        if seconds < progress.duration - 1 { finishedCurrent = false }
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

    /// Loads the song at `index`. As part of a crossfade the previous song keeps playing on `outgoingPlayer`.
    private func loadCurrent(crossfading: Bool = false) {
        if !crossfading { endCrossfade() }
        loadTask?.cancel()
        upgradeTask?.cancel()
        requestedSeek = nil
        guard let track = current else { return }
        let position = index
        playWhenReady = true
        retriedCurrentItem = false
        finishedCurrent = false
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

    /// Downloaded or cached file when there is one; otherwise the plain AAC stream, which starts at once.
    /// `start` then prepares a local copy in the chosen quality and switches to it.
    private func stream(for track: Track) async throws -> (url: URL, label: String) {
        if let local = Storage.localAudio(for: track) {
            return (local, "\(DownloadManager.formatLabel(for: track) ?? "AAC") · offline")
        }
        guard let videoId = track.videoId else { throw PlayerError.unavailable }
        if let cached = OpusPipeline.cachedFile(videoId: videoId) { return cached }
        // Usually already resolved by StreamPrewarmer while the song was on screen.
        let stream = try await StreamResolver.shared.stream(for: videoId, quality: Preferences.initialStreamQuality)
        return (stream.url, stream.label)
    }

    /// A local copy of the plain stream (Dolby, AAC 256 or AAC 128/48): quick to fetch,
    /// so the song can seek and crossfade early.
    nonisolated static func prepareCopy(videoId: String, quality: AudioQuality) async throws -> (url: URL, label: String) {
        var stream = try await StreamResolver.shared.stream(for: videoId, quality: quality)
        if stream.format == .opus {
            stream = try await StreamResolver.shared.stream(for: videoId, quality: quality == .medium ? .low : .high)
        }
        let copy = try await OpusPipeline.shared.localCopy(videoId: videoId, stream: stream)
        return (copy, stream.label)
    }

    /// The decoded Opus file for the top qualities, when YouTube's best stream is Opus. Nil otherwise.
    nonisolated static func prepareOpus(videoId: String, quality: AudioQuality,
                                        duration: TimeInterval?) async -> (url: URL, label: String)? {
        guard quality.usesOpus, (duration ?? 0) <= Preferences.opusLengthLimit,
              let stream = try? await StreamResolver.shared.stream(for: videoId, quality: quality),
              stream.format == .opus else { return nil }
        do {
            let file = try await OpusPipeline.shared.playableFile(videoId: videoId, stream: stream)
            UserDefaults.standard.removeObject(forKey: Preferences.opusLastError)
            return (file, stream.label)
        } catch {
            // Shown in Settings, to understand why Opus isn't used.
            UserDefaults.standard.set(error.localizedDescription, forKey: Preferences.opusLastError)
            return nil
        }
    }

    /// Caches a song ahead of time: the quick copy first, then the Opus decode.
    nonisolated static func prepare(videoId: String, quality: AudioQuality, duration: TimeInterval?) async {
        _ = try? await prepareCopy(videoId: videoId, quality: quality)
        _ = await prepareOpus(videoId: videoId, quality: quality, duration: duration)
    }

    /// Replaces the current item with a better local file at the same position.
    private func switchToLocal(_ url: URL, label: String, track: Track) {
        guard current?.id == track.id, let item = player.currentItem,
              (item.asset as? AVURLAsset)?.url != url else { return }
        var position = player.currentTime().seconds
        if let requested = requestedSeek {
            // The user scrubbed while streaming: honour it, counting the time played since.
            position = requested.time + (player.timeControlStatus == .playing ? Date.now.timeIntervalSince(requested.at) : 0)
        }
        requestedSeek = nil
        let wasPlaying = player.timeControlStatus != .paused
        let local = AVPlayerItem(url: url)
        local.allowedAudioSpatializationFormats = Self.spatializationFormats
        itemStatus = local.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { status in self.itemStatusChanged(status, track: track) }
        player.replaceCurrentItem(with: local)
        if position.isFinite, position > 0.5 {
            player.seek(to: CMTime(seconds: position, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if wasPlaying || playWhenReady { player.play() }
        streamInfo = label
    }

    private func start(url: URL, track: Track, isRetry: Bool = false) {
        let item = AVPlayerItem(url: url)
        item.allowedAudioSpatializationFormats = Self.spatializationFormats
        itemStatus = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { status in self.itemStatusChanged(status, track: track) }
        player.replaceCurrentItem(with: item)

        if pendingFadeIn != nil {
            // Crossfading in: stay silent until the song really plays (see `startPendingFades`).
            player.volume = 0
        } else if !isRetry {
            fadeInTask?.cancel()
            player.volume = 1
        }
        if playWhenReady {
            activateSession()
            // Start as soon as the first audio arrives instead of waiting for a "safe" buffer;
            // later stalls are still handled by AVPlayer's normal waiting.
            player.playImmediately(atRate: 1)
        }
        if Storage.localAudio(for: track) == nil, let videoId = track.videoId {
            let quality = Preferences.streamingQuality
            let duration = track.duration
            let isStreaming = !url.isFileURL
            upgradeTask?.cancel()
            upgradeTask = Task {
                // 1. A quick local copy, so seeking and crossfade work.
                if isStreaming, let copy = try? await Self.prepareCopy(videoId: videoId, quality: quality),
                   !Task.isCancelled {
                    self.switchToLocal(copy.url, label: copy.label, track: track)
                }
                // 2. Lossless Opus. Switching mid-song would be audible, so only near the start;
                //    otherwise it is ready for the next time the song plays.
                if let opus = await Self.prepareOpus(videoId: videoId, quality: quality, duration: duration),
                   !Task.isCancelled, self.player.currentTime().seconds < 20 {
                    self.switchToLocal(opus.url, label: opus.label, track: track)
                }
            }
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
                // Retry with plain AAC: the most reliable rendition.
                await StreamResolver.shared.invalidate(videoId)
                let stream = try? await StreamResolver.shared.stream(for: videoId, quality: .high)
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
        guard !finishedCurrent else { return }
        finishedCurrent = true
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

    // MARK: Crossfade

    private var canCrossfade: Bool {
        index + 1 < queue.count && repeatMode != .one && sleepTimer != .endOfTrack && playWhenReady
    }

    /// Starts loading the next song on a fresh player. The fades begin once it actually plays,
    /// so a slow start never leaves a gap of silence.
    private func beginCrossfade(remaining: TimeInterval, length: TimeInterval) {
        finishedCurrent = true
        outgoingPlayer = player
        outgoingLength = length
        fadeOutTask?.cancel()
        fadeOutTask = nil
        let incoming = AVPlayer()
        player = incoming
        attach(incoming)
        pendingFadeIn = min(remaining, Preferences.crossfadeSeconds)
        index += 1
        loadCurrent(crossfading: true)
    }

    /// Called when the new song starts playing: fades it in and the previous one out over
    /// whatever is left of the previous song.
    private func startPendingFades() {
        let left = outgoingPlayer.map { max(0.5, outgoingLength - $0.currentTime().seconds) }
        if let fadeIn = pendingFadeIn {
            pendingFadeIn = nil
            let target = player
            fadeInTask?.cancel()
            fadeInTask = Task { await Self.fade(target, in: true, over: min(fadeIn, left ?? fadeIn)) }
        }
        if let outgoing = outgoingPlayer, fadeOutTask == nil, let left {
            fadeOutTask = Task {
                await Self.fade(outgoing, in: false, over: left)
                guard !Task.isCancelled else { return }
                self.endCrossfade(interrupted: false)
            }
        }
    }

    /// Stops the song fading out. At the natural end of the fade the new song keeps fading in;
    /// when the user skips or pauses, the new song jumps to full volume.
    private func endCrossfade(interrupted: Bool = true) {
        fadeOutTask?.cancel()
        fadeOutTask = nil
        guard let outgoing = outgoingPlayer else { return }
        outgoing.pause()
        outgoing.replaceCurrentItem(with: nil)
        outgoingPlayer = nil
        if interrupted {
            fadeInTask?.cancel()
            pendingFadeIn = nil
            player.volume = 1
        }
        isPlaying = player.timeControlStatus != .paused
    }

    /// Equal-power fade, so the overall loudness stays steady while two songs overlap.
    private static func fade(_ target: AVPlayer, in fadingIn: Bool, over duration: TimeInterval) async {
        let start = target.volume
        let steps = max(1, Int(duration * 25))
        for step in 1...steps {
            try? await Task.sleep(for: .milliseconds(40))
            if Task.isCancelled { return }
            let progress = Float(step) / Float(steps)
            target.volume = fadingIn ? sin(progress * .pi / 2) : start * cos(progress * .pi / 2)
        }
    }

    // MARK: Queue upkeep

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

    /// Caches the next two songs while this one plays, so they start instantly and crossfade on time,
    /// even with the screen locked.
    private func prefetchNext() {
        let quality = Preferences.streamingQuality
        let upcoming = queue.indices.filter { $0 > index }.prefix(2).map { queue[$0] }
        let songs = upcoming.compactMap { track -> (String, TimeInterval?)? in
            guard let videoId = track.videoId, Storage.localAudio(for: track) == nil else { return nil }
            return (videoId, track.duration)
        }
        guard !songs.isEmpty else { return }
        Task.detached(priority: .utility) {
            for (videoId, duration) in songs {
                await PlayerController.prepare(videoId: videoId, quality: quality, duration: duration)
            }
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
        currentArtworkData = nil
        artworkTask = Task {
            guard let artwork = await ArtworkLoader.shared.artwork(for: track),
                  !Task.isCancelled, self.current?.id == track.id else { return }
            self.nowPlayingArtwork = Self.makeArtwork(artwork.image)
            self.currentArtworkData = artwork.image.jpegData(compressionQuality: 0.85)
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
        #if canImport(NowPlaying)
        if #available(iOS 27, *), let system = systemNowPlayingBox as? SystemNowPlaying {
            system.claim()
        }
        #endif
    }

    /// Moves the time and state observers to the player of the current song.
    private func attach(_ newPlayer: AVPlayer) {
        if let observedPlayer, let timeObserver {
            observedPlayer.removeTimeObserver(timeObserver)
        }
        playerCancellables.removeAll()
        observedPlayer = newPlayer
        timeObserver = newPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { time in
            let seconds = time.seconds
            MainActor.assumeIsolated { self.tick(seconds) }
        }
        newPlayer.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { status in
                // While the next song loads during a crossfade, the previous one is still audible.
                self.isPlaying = status != .paused || self.outgoingPlayer != nil
                if status == .playing {
                    self.isLoading = false
                    self.startPendingFades()
                }
                self.updateNowPlayingInfo()
            }
            .store(in: &playerCancellables)
    }

    private func observeNotifications() {
        NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)
            .receive(on: DispatchQueue.main)
            .sink { note in
                guard let item = note.object as? AVPlayerItem else { return }
                if item === self.player.currentItem {
                    self.itemFinished()
                } else if let outgoing = self.outgoingPlayer, item === outgoing.currentItem {
                    self.endCrossfade(interrupted: false)
                }
            }
            .store(in: &cancellables)

        // A stream that stalls right at its end has simply finished.
        NotificationCenter.default.publisher(for: AVPlayerItem.playbackStalledNotification)
            .receive(on: DispatchQueue.main)
            .sink { note in
                guard (note.object as? AVPlayerItem) === self.player.currentItem,
                      self.progress.duration > 0,
                      self.progress.currentTime >= self.progress.duration - 3 else { return }
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

        // YouTube's audio files often report a wrong (even doubled) length to AVPlayer,
        // so the catalogue length wins; the file's own length is only a fallback.
        let itemLength = player.currentItem?.duration.seconds ?? 0
        let length = current?.duration ?? (itemLength.isFinite && itemLength > 0 ? itemLength : 0)
        if length > 0, abs(progress.duration - length) > 0.5 {
            progress.duration = length
            updateNowPlayingInfo()
        }
        if player.timeControlStatus == .playing, delta > 0, delta < 1.5 {
            scrobbler.addListeningTime(delta, trackLength: progress.duration)
        }

        guard length > 0, !finishedCurrent, player.timeControlStatus == .playing else { return }
        let remaining = length - seconds
        let crossfade = Preferences.crossfadeSeconds
        if crossfade > 0, outgoingPlayer == nil, canCrossfade, length > crossfade * 3, remaining <= crossfade {
            beginCrossfade(remaining: max(0.5, remaining), length: length)
        } else if remaining < -1.5 {
            // The file keeps "playing" silence past the real end.
            itemFinished()
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        if type == .began {
            endCrossfade()
            return
        }
        guard let rawOptions = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
              AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume),
              playWhenReady else { return }
        player.play()
    }

    private func configureRemoteCommands(_ center: MPRemoteCommandCenter) {
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
        #if canImport(NowPlaying)
        if #available(iOS 27, *), let system = systemNowPlayingBox as? SystemNowPlaying {
            let model = system.model
            guard let track = current else {
                model.title = ""
                return
            }
            model.contentID = track.id
            model.title = track.title
            model.artist = track.artist
            model.duration = progress.duration
            model.isPlaying = player.timeControlStatus == .playing
            model.elapsed = progress.currentTime
            model.timestamp = .now
            model.artworkData = currentArtworkData
            return
        }
        #endif
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
