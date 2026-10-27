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

    var errorDescription: String? { String(localized: "Questo brano non è disponibile.") }
}

/// Playback position, kept apart from `PlayerController` so that only the views
/// showing time re-render several times per second.
@MainActor
final class PlaybackProgress: ObservableObject {
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
}

/// What song lists and the Home show about playback: the current song, whether it plays, and
/// whether a session is going. Kept apart from `PlayerController`, and changed only when a value
/// really changes, so lists don't redraw for the player's other updates (loading, karaoke
/// progress, lyrics, colours…).
@MainActor
final class NowPlayingState: ObservableObject {
    @Published private(set) var currentID: String?
    @Published private(set) var isPlaying = false
    /// Nothing loaded, or only the queue restored at launch: the Home offers "Riprendi".
    @Published private(set) var isIdle = true

    fileprivate func update(currentID: String?, isPlaying: Bool, isIdle: Bool) {
        if self.currentID != currentID { self.currentID = currentID }
        if self.isPlaying != isPlaying { self.isPlaying = isPlaying }
        if self.isIdle != isIdle { self.isIdle = isIdle }
    }
}

/// The queue and the audio engine: AVPlayer, crossfade, background audio, lock screen and Control Center.
@MainActor
final class PlayerController: ObservableObject {
    static let shared = PlayerController()
    static let defaultTint = Color(red: 0.24, green: 0.18, blue: 0.42)

    @Published private(set) var queue: [Track] = [] {
        didSet {
            scheduleQueueSave()
            syncNowPlaying()
        }
    }
    @Published private(set) var index = 0 {
        didSet {
            scheduleQueueSave()
            syncNowPlaying()
        }
    }
    /// The queue was restored at launch and nothing has been loaded yet: the Home's "Riprendi"
    /// card carries on from the saved position.
    @Published private(set) var isRestoredSession = false {
        didSet { syncNowPlaying() }
    }
    @Published private(set) var isPlaying = false {
        didSet { syncNowPlaying() }
    }
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String? = nil
    @Published private(set) var source = ""
    @Published private(set) var lyrics: LyricsState = .idle
    @Published private(set) var artworkColor = PlayerController.defaultTint
    /// Blurred cover for the full-screen player's background (see `ArtworkLoader`).
    @Published private(set) var backdrop: UIImage?
    /// "AAC · 129 kbps", "Opus · 160 kbps", or "… · offline" for downloaded songs.
    @Published private(set) var streamInfo: String? = nil
    @Published private(set) var shuffleEnabled = false
    @Published private(set) var sleepTimer: SleepTimer = .off
    @Published private(set) var karaokeMode: KaraokeMode = .off
    @Published private(set) var karaokeAmount: Float = 1
    @Published private(set) var karaokeStatus: KaraokeStatus = .idle
    @Published var repeatMode: RepeatMode = .off
    @Published var autoRadio: Bool {
        didSet { UserDefaults.standard.set(autoRadio, forKey: "player.autoRadio") }
    }

    let progress = PlaybackProgress()
    let nowPlaying = NowPlayingState()

    /// Where the last song stopped, for the Home's "Riprendi" card.
    struct ResumePoint: Codable {
        let track: Track
        let time: TimeInterval
    }

    /// Saved every few seconds of playback and on pause; not published, so saving re-renders nothing.
    private(set) var resumePoint: ResumePoint?
    private static let resumeKey = "player.resumePoint"
    /// Where to jump once the song being loaded is ready (see `continueListening`).
    private var pendingStartTime: TimeInterval?

    /// The queue as saved for the next launch.
    private struct SavedQueue: Codable {
        let tracks: [Track]
        let index: Int
        let source: String
        let shuffled: Bool
        let unshuffled: [Track]
    }

    private static var queueFile: URL { Storage.support.appending(path: "queue.json") }
    private var saveQueueTask: Task<Void, Never>?

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
    private let requests = PlaybackRequests()
    private var loadTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var advanceTask: Task<Void, Never>?
    private var lyricsTask: Task<Void, Never>?
    /// The next songs' lyrics, fetched ahead of time, by track id.
    private var prefetchedLyrics: [String: LyricsState] = [:]
    private var artworkTask: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?
    private var fadeOutTask: Task<Void, Never>?
    private var fadeInTask: Task<Void, Never>?
    /// Prepares the local copy of the streaming song (see `offerLocal`).
    private var upgradeTask: Task<Void, Never>?
    /// At most one upcoming AAC copy; never a speculative Opus conversion.
    private var prefetchTask: Task<Void, Never>?
    private var lyricsPrefetchTask: Task<Void, Never>?
    /// A seek made while streaming, applied when the local copy takes over.
    private var requestedSeek: StreamingSeekPosition?
    /// A local file of the playing song (its copy, or decoded Opus), ready for the next seek.
    /// Swapping files while the song plays is heard as a gap, so the song keeps its stream.
    private var localFile: (trackID: String, url: URL, label: String)?
    /// Separates the current song for karaoke.
    private var karaokeTask: Task<Void, Never>?
    /// The song whose karaoke stems are playing right now.
    private var karaokeTrackID: String?
    /// Seconds of fade-in for the song being loaded as part of a crossfade.
    private var pendingFadeIn: TimeInterval?
    /// Catalogue length of the song fading out, to know how much of it is left.
    private var outgoingLength: TimeInterval = 0
    private var nowPlayingArtwork: MPMediaItemArtwork?
    /// The upcoming songs in their original order, to restore when shuffle is turned off.
    private var unshuffledUpcoming: [Track] = []
    private var playWhenReady = true
    private var failuresInARow = 0
    private var retriedCurrentItem = false
    /// Set once the current song has ended (or started fading out), so it is never finished twice.
    private var finishedCurrent = false
    /// The song whose preparation (local copy, next song, karaoke) waits for its first note, so
    /// nothing competes with the start of its stream for the connection.
    private var deferredPreparation: (generation: UUID, track: Track)?
    private let startupMetrics = PlaybackStartupMetrics.shared
    private var lastTick: TimeInterval = 0
    /// When the music paused because the headphones went away (see `handleRouteChange`).
    private var pausedForHeadphones: Date?
    /// AutoMix (see `prepareAutoMix`): the transition into the next song, planned while this one plays.
    private var autoMix: PlannedTransition?
    private var autoMixTask: Task<Void, Never>?
    /// The pair of songs being planned for, "current>next".
    private var autoMixPair: String?
    /// The next song's player, loaded and waiting for its moment (see `armTransition`).
    private var armed: ArmedTransition?
    private var armTask: Task<Void, Never>?
    /// The AutoMix transition playing now: volumes, bass and tempo follow the outgoing song's time.
    private var transitionTask: Task<Void, Never>?

    private init() {
        autoRadio = UserDefaults.standard.object(forKey: "player.autoRadio") as? Bool ?? true
        resumePoint = UserDefaults.standard.data(forKey: Self.resumeKey)
            .flatMap { try? JSONDecoder().decode(ResumePoint.self, from: $0) }
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
        restoreQueue()
        syncNowPlaying()
    }

    private func syncNowPlaying() {
        nowPlaying.update(currentID: current?.id, isPlaying: isPlaying,
                          isIdle: current == nil || isRestoredSession)
    }

    // MARK: Queue

    /// Replaces the queue. With shuffle on, the chosen song plays first and the rest follow in random order.
    func play(_ tracks: [Track], startAt start: Int = 0, source: String, startRadio: Bool = false,
              shuffled: Bool? = nil) {
        guard tracks.indices.contains(start) else { return }
        requests.replaceQueue()
        advanceTask?.cancel()
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
        if startRadio {
            let generation = requests.queueGeneration
            Task {
                guard self.requests.isCurrentQueue(generation) else { return }
                await self.extendQueue()
            }
        }
    }

    /// Plays a song followed by YouTube Music's radio of similar songs.
    func playRadio(from track: Track) {
        play([track], source: "Radio · \(track.title)", startRadio: true)
    }

    /// Plays the last song again from where it stopped (from the start when it had almost ended):
    /// within the restored queue when there is one, otherwise followed by its radio.
    func continueListening(_ point: ResumePoint) {
        if isRestoredSession, current?.id == point.track.id {
            resume()
            return
        }
        playRadio(from: point.track)
        pendingStartTime = Self.startTime(of: point)
    }

    /// Where a saved song should start again: nil (the start) near either end.
    private static func startTime(of point: ResumePoint) -> TimeInterval? {
        let length = point.track.duration ?? 0
        return point.time > 5 && (length == 0 || point.time < length - 15) ? point.time : nil
    }

    /// Brings back the last session's queue, paused on its song, without loading anything:
    /// pressing play carries on from the saved position.
    private func restoreQueue() {
        guard let data = try? Data(contentsOf: Self.queueFile),
              let saved = try? JSONDecoder().decode(SavedQueue.self, from: data),
              saved.tracks.indices.contains(saved.index) else { return }
        queue = saved.tracks
        index = saved.index
        source = saved.source
        shuffleEnabled = saved.shuffled
        unshuffledUpcoming = saved.unshuffled
        playWhenReady = false
        isRestoredSession = true
        let track = saved.tracks[saved.index]
        progress.duration = track.duration ?? 0
        if let point = resumePoint, point.track.id == track.id {
            progress.currentTime = point.time
            lastTick = point.time
        }
        loadArtwork(for: track)
    }

    private func scheduleQueueSave() {
        saveQueueTask?.cancel()
        saveQueueTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self.saveQueue()
        }
    }

    /// Up to 50 songs back and 200 ahead, so long radio sessions stay small.
    private func saveQueue() {
        guard queue.indices.contains(index) else {
            try? FileManager.default.removeItem(at: Self.queueFile)
            return
        }
        let range = max(0, index - 50)..<min(queue.count, index + 201)
        let saved = SavedQueue(tracks: Array(queue[range]), index: index - range.lowerBound, source: source,
                               shuffled: shuffleEnabled, unshuffled: Array(unshuffledUpcoming.prefix(200)))
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: Self.queueFile, options: .atomic)
    }

    func playNext(_ track: Track) {
        guard current != nil else { return play([track], source: String(localized: "Coda")) }
        queue.insert(track, at: index + 1)
        unshuffledUpcoming.insert(track, at: 0)
        offerUpcoming()
    }

    func addToQueue(_ track: Track) {
        guard current != nil else { return play([track], source: String(localized: "Coda")) }
        queue.append(track)
        unshuffledUpcoming.append(track)
        offerUpcoming()
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
            let restored = PlaybackQueueOrder.restoring(original: unshuffledUpcoming,
                                                        upcoming: upcomingTracks, id: { $0.id })
            queue.replaceSubrange((index + 1)..., with: restored)
            unshuffledUpcoming = []
        } else {
            unshuffledUpcoming = upcomingTracks
            queue.replaceSubrange((index + 1)..., with: upcomingTracks.shuffled())
        }
        shuffleEnabled.toggle()
        offerUpcoming()
    }

    func removeUpcoming(atOffsets offsets: IndexSet) {
        let removed = offsets.map { queue[$0 + index + 1] }
        queue.remove(atOffsets: IndexSet(offsets.map { $0 + index + 1 }))
        unshuffledUpcoming = PlaybackQueueOrder.removing(removed, from: unshuffledUpcoming, id: { $0.id })
        offerUpcoming()
    }

    func moveUpcoming(fromOffsets source: IndexSet, toOffset destination: Int) {
        queue.move(fromOffsets: IndexSet(source.map { $0 + index + 1 }), toOffset: destination + index + 1)
        offerUpcoming()
    }

    /// Tells `PreparedPlayback` which song comes next, so "next" can start it at once, and AutoMix,
    /// so the transition into it is planned.
    private func offerUpcoming() {
        PreparedPlayback.shared.offerUpcoming(index + 1 < queue.count ? queue[index + 1] : nil)
        prepareAutoMix()
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
        stopPreparationWork()
        requestedSeek?.setPlaying(false, now: ProcessInfo.processInfo.systemUptime)
        player.pause()
        rememberPosition(progress.currentTime)
        updateNowPlayingInfo()
    }

    func resume() {
        guard current != nil else { return }
        pausedForHeadphones = nil
        playWhenReady = true
        if player.currentItem != nil {
            activateSession()
            player.play()
            // Prepared right here, so the first note doesn't start it again.
            deferredPreparation = nil
            if let track = current {
                if karaokeMode != .off, !isPlayingStems { startKaraoke() }
                else { prepareCurrentAudio(for: track) }
                prefetchNext()
                prepareAutoMix()
            }
        } else if !isLoading {
            loadCurrent(reason: .resume)
            // After a restored session: carry on where the song was left.
            if let point = resumePoint, point.track.id == current?.id {
                pendingStartTime = Self.startTime(of: point)
            }
        }
    }

    func next() {
        // Counts as a skip for the recommendations if the song played less than 30 seconds.
        ListeningLog.shared.noteSkip()
        advance(reason: .skip)
    }

    func previous() {
        if progress.currentTime > 3 || index == 0 {
            seek(to: 0)
        } else {
            index -= 1
            loadCurrent(reason: .skip)
        }
    }

    func seek(to seconds: TimeInterval) {
        // Moving within the song ends a transition into it: it goes on alone.
        if outgoingPlayer != nil { endCrossfade() }
        var switched = false
        if let asset = player.currentItem?.asset as? AVURLAsset, !asset.url.isFileURL {
            // Seeking in YouTube's streams is unreliable: remember it for when the local copy takes over.
            requestedSeek = StreamingSeekPosition(time: seconds,
                                                   isPlaying: player.timeControlStatus == .playing,
                                                   now: ProcessInfo.processInfo.systemUptime)
            // A seek pauses the sound anyway: the moment to move to the local file, if it is ready.
            if let local = localFile, let track = current, local.trackID == track.id {
                localFile = nil
                switchItem(to: AVPlayerItem(url: local.url), label: local.label, track: track)
                switched = true
            }
        }
        if !switched {
            player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        }
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

    // MARK: Karaoke

    /// Turns karaoke on or off. The song keeps playing normally while the AI separates it,
    /// then playback moves to the separated stems at the same position.
    func setKaraoke(_ mode: KaraokeMode) {
        karaokeMode = mode
        if mode == .off {
            leaveKaraoke()
        } else if isPlayingStems {
            updateKaraokeMix()
        } else {
            startKaraoke()
        }
        // Karaoke plays the separated parts of one song: AutoMix waits until it is off.
        if mode == .off { prepareAutoMix() } else { resetAutoMix() }
    }

    /// How much of the other part is removed: 1 removes it completely.
    func setKaraokeAmount(_ amount: Float) {
        karaokeAmount = amount
        updateKaraokeMix()
    }

    private var isPlayingStems: Bool {
        karaokeTrackID != nil && karaokeTrackID == current?.id
            && player.currentItem?.asset is AVMutableComposition
    }

    private func startKaraoke() {
        guard playWhenReady, UIApplication.shared.applicationState != .background,
              karaokeMode != .off, let track = current, let videoId = track.videoId else { return }
        guard EnergyPolicy.current.allowsKaraoke || StemSeparator.cachedStems(for: videoId) != nil else {
            karaokeStatus = .failed(KaraokeError.energyLimited.localizedDescription)
            return
        }
        guard StemSeparator.isAvailable else {
            karaokeStatus = .failed(KaraokeError.engineUnavailable.localizedDescription)
            return
        }
        karaokeTask?.cancel()
        upgradeTask?.cancel()
        karaokeStatus = .preparing(0, remaining: nil)
        StemSeparator.focus(on: [videoId])
        let clock = KaraokeClock()
        karaokeTask = Task {
            do {
                let stems: StemFiles
                if let cached = StemSeparator.cachedStems(for: videoId) {
                    stems = cached
                } else {
                    let source = try await Self.karaokeSource(for: track, videoId: videoId)
                    try Task.checkCancellation()
                    stems = try await StemSeparator.shared.stems(for: videoId, source: source,
                                                                  duration: track.duration) { value in
                        Task { @MainActor in
                            let controller = PlayerController.shared
                            if case .preparing = controller.karaokeStatus, controller.current?.id == track.id {
                                controller.karaokeStatus = .preparing(value, remaining: clock.remaining(at: value))
                            }
                        }
                    }
                }
                guard !Task.isCancelled, self.current?.id == track.id, self.karaokeMode != .off else { return }
                let item = try await KaraokeMixer.makeItem(stems: stems, mode: self.karaokeMode,
                                                           amount: self.karaokeAmount)
                guard !Task.isCancelled, self.current?.id == track.id, self.karaokeMode != .off else { return }
                self.karaokeTrackID = track.id
                self.switchItem(to: item, label: String(localized: "Karaoke AI"), track: track)
                self.karaokeStatus = .ready
            } catch {
                guard !Task.isCancelled else { return }
                self.karaokeStatus = .failed(error.localizedDescription)
            }
        }
    }

    private func leaveKaraoke() {
        karaokeTask?.cancel()
        karaokeStatus = .idle
        // Stop separating: nothing needs the stems now.
        StemSeparator.focus(on: [])
        guard isPlayingStems, let track = current else {
            karaokeTrackID = nil
            return
        }
        karaokeTrackID = nil
        Task {
            guard let original = try? await self.stream(for: track),
                  self.current?.id == track.id, self.karaokeMode == .off else { return }
            self.switchItem(to: AVPlayerItem(url: original.url), label: original.label, track: track)
        }
    }

    private func updateKaraokeMix() {
        guard isPlayingStems, let item = player.currentItem,
              let composition = item.asset as? AVMutableComposition else { return }
        item.audioMix = KaraokeMixer.mix(for: composition, mode: karaokeMode, amount: karaokeAmount)
    }

    /// A local file to separate: the download, the cached copy, or a fresh AAC copy.
    nonisolated private static func karaokeSource(for track: Track, videoId: String) async throws -> URL {
        if let local = Storage.localAudio(for: track) { return local }
        if let cached = OpusPipeline.cachedFile(videoId: videoId) { return cached.url }
        return try await prepareCopy(videoId: videoId, quality: .high).url
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

    /// Loads the song at `index`. As part of a crossfade the previous song keeps playing on `outgoingPlayer`;
    /// an AutoMix transition hands over the next song already playing (`adopting`).
    /// `reason` only sorts the startup timings shown in Settings → Diagnostica.
    private func loadCurrent(crossfading: Bool = false, reason: StartupReason = .selection,
                             adopting transition: ArmedTransition? = nil) {
        if !crossfading { endCrossfade() }
        let generation = requests.beginLoad()
        startupMetrics.begin(generation, reason: crossfading ? .automatic : reason)
        deferredPreparation = nil
        loadTask?.cancel()
        retryTask?.cancel()
        upgradeTask?.cancel()
        prefetchTask?.cancel()
        lyricsPrefetchTask?.cancel()
        karaokeTask?.cancel()
        StemSeparator.focus(on: [])
        karaokeTrackID = nil
        requestedSeek = nil
        localFile = nil
        pendingStartTime = nil
        isRestoredSession = false
        resetAutoMix()
        guard let track = current else { return }
        // The requested song comes first: speculative preparation waits until it plays.
        PreparedPlayback.shared.suspendForStartup(keeping: track.videoId)
        let position = index
        playWhenReady = true
        retriedCurrentItem = false
        finishedCurrent = false
        isLoading = true
        errorMessage = nil
        streamInfo = nil
        itemStatus = nil
        if transition == nil { player.replaceCurrentItem(with: nil) }
        progress.currentTime = 0
        progress.duration = track.duration ?? 0
        lastTick = 0
        lyrics = .loading
        loadArtwork(for: track)
        updateNowPlayingInfo()

        if let transition {
            // AutoMix already started the song (see `startOnTime`), from its local file.
            startupMetrics.resolved(generation, source: .localFile)
            streamInfo = transition.label
            begin(transition.item, track: track, isRetry: false, alreadyStarted: true)
            extendQueueIfNeeded()
            return
        }

        loadTask = Task {
            do {
                guard !Task.isCancelled, self.requests.isCurrentLoad(generation) else { return }
                var playable = Library.shared.resolvedTrack(matching: track) ?? track
                if playable.videoId == nil {
                    // Last.fm tracks only know artist and title: find them on YouTube Music first.
                    playable = try await InnerTube.shared.resolve(track)
                    guard !Task.isCancelled, self.requests.isCurrentLoad(generation), self.index == position else { return }
                    playable = Library.shared.reconcile(original: track, resolved: playable)
                }
                if playable != track {
                    self.queue[position] = playable
                    self.loadArtwork(for: playable)
                }
                // A player prepared while the song was on screen or next in the queue already
                // has audio buffered: play that one (not during a crossfade, which has its own).
                if !crossfading, let videoId = playable.videoId,
                   let prepared = PreparedPlayback.shared.take(for: videoId, quality: Preferences.initialStreamQuality) {
                    self.startupMetrics.resolved(generation, source: .prepared)
                    self.streamInfo = prepared.label
                    self.start(adopting: prepared.player, track: playable)
                    return
                }
                let source = await self.startupSource(for: playable)
                let stream = try await self.stream(for: playable)
                guard !Task.isCancelled, self.requests.isCurrentLoad(generation), self.index == position else { return }
                self.startupMetrics.resolved(generation, source: source)
                self.streamInfo = stream.label
                self.start(url: stream.url, track: playable)
            } catch {
                guard !Task.isCancelled, self.requests.isCurrentLoad(generation), self.index == position else { return }
                self.startupMetrics.fail(generation)
                self.fail(error.localizedDescription)
            }
        }
        extendQueueIfNeeded()
    }

    /// Where the song's audio will come from, for the startup timings in Settings.
    private func startupSource(for track: Track) async -> StartupSource {
        if Storage.localAudio(for: track) != nil { return .localFile }
        guard let videoId = track.videoId else { return .network }
        if OpusPipeline.cachedFile(videoId: videoId) != nil { return .localFile }
        return await StreamResolver.shared.isCached(videoId) ? .resolvedURL : .network
    }

    /// Downloaded or cached file when there is one; otherwise the best stream AVPlayer plays as it is,
    /// which starts at once and plays to the end. The local copy (and Opus) made meanwhile serve
    /// seeks and the next listen.
    private func stream(for track: Track) async throws -> (url: URL, label: String) {
        if let local = Storage.localAudio(for: track) {
            return (local, "\(DownloadManager.formatLabel(for: track) ?? "AAC") · offline")
        }
        guard let videoId = track.videoId else { throw PlayerError.unavailable }
        if let cached = OpusPipeline.cachedFile(videoId: videoId) { return cached }
        // Usually already resolved by StreamPrewarmer while the song was on screen.
        let stream = try await StreamResolver.shared.nativeStream(for: videoId, quality: Preferences.streamingQuality)
        return (stream.url, stream.label)
    }

    /// A local copy of the plain stream (Dolby, AAC 256 or AAC 128/48): quick to fetch,
    /// so the song can seek and crossfade early.
    nonisolated static func prepareCopy(videoId: String, quality: AudioQuality) async throws -> (url: URL, label: String) {
        try Task.checkCancellation()
        var stream = try await StreamResolver.shared.stream(for: videoId, quality: quality)
        try Task.checkCancellation()
        if stream.format == .opus {
            stream = try await StreamResolver.shared.stream(for: videoId, quality: quality == .medium ? .low : .high)
        }
        try Task.checkCancellation()
        let copy = try await OpusPipeline.shared.localCopy(videoId: videoId, stream: stream)
        return (copy, stream.label)
    }

    /// The decoded Opus file for the top qualities, when YouTube's best stream is Opus. Nil otherwise.
    nonisolated static func prepareOpus(videoId: String, quality: AudioQuality,
                                        duration: TimeInterval?) async -> (url: URL, label: String)? {
        guard !Task.isCancelled, EnergyPolicy.current.allowsAudioConversion,
              quality.usesOpus, (duration ?? 0) <= Preferences.opusLengthLimit,
              let stream = try? await StreamResolver.shared.stream(for: videoId, quality: quality),
              !Task.isCancelled, EnergyPolicy.current.allowsAudioConversion,
              stream.format == .opus else { return nil }
        do {
            let file = try await OpusPipeline.shared.playableFile(videoId: videoId, stream: stream)
            UserDefaults.standard.removeObject(forKey: Preferences.opusLastError)
            return (file, stream.label)
        } catch is CancellationError {
            return nil
        } catch OpusError.energyBudget {
            return nil
        } catch {
            // Shown in Settings, to understand why Opus isn't used.
            UserDefaults.standard.set(error.localizedDescription, forKey: Preferences.opusLastError)
            return nil
        }
    }

    /// A local file of the playing song is ready. It waits for a seek (see `seek`), unless the
    /// user already seeked in the stream: then it takes over at once, where seeking is reliable.
    /// Not while karaoke stems are playing.
    private func offerLocal(_ url: URL, label: String, track: Track) {
        guard current?.id == track.id, let item = player.currentItem,
              (item.asset as? AVURLAsset)?.url != url, !isPlayingStems else { return }
        if requestedSeek != nil {
            localFile = nil
            switchItem(to: AVPlayerItem(url: url), label: label, track: track)
        } else {
            localFile = (track.id, url, label)
        }
    }

    /// Swaps the current item (local copy, karaoke stems, or back to the original) at the same position.
    private func switchItem(to newItem: AVPlayerItem, label: String, track: Track) {
        guard current?.id == track.id, player.currentItem != nil else { return }
        var position = player.currentTime().seconds
        if let requested = requestedSeek {
            position = requested.position(at: ProcessInfo.processInfo.systemUptime)
        }
        requestedSeek = nil
        let wasPlaying = player.timeControlStatus != .paused
        newItem.allowedAudioSpatializationFormats = Self.spatializationFormats
        itemStatus = newItem.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak newItem] status in
                guard let newItem else { return }
                self.itemStatusChanged(status, item: newItem, track: track)
            }
        player.replaceCurrentItem(with: newItem)
        if position.isFinite, position > 0.5 {
            player.seek(to: CMTime(seconds: position, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if wasPlaying || playWhenReady { player.play() }
        streamInfo = label
        // Karaoke stems carry their own mix of vocal and instrumental volumes (and the equalizer).
        if !(newItem.asset is AVMutableComposition) { applyAudioEffects(to: newItem, track: track) }
    }

    /// "Volume uniforme" and the equalizer, through the item's audio mix, so the player's own
    /// volume stays free for crossfades. "Volume uniforme" lowers songs louder than YouTube's
    /// reference level.
    private func applyAudioEffects(to item: AVPlayerItem, track: Track) {
        Task {
            let mix = await self.audioMix(for: item, track: track)
            guard self.player.currentItem === item else { return }
            item.audioMix = mix
        }
    }

    private func audioMix(for item: AVPlayerItem, track: Track) async -> AVAudioMix? {
        let videoId = Preferences.normalizesVolume ? track.videoId : nil
        // With AutoMix every song carries the bass cut its transitions use.
        let bassCut = Preferences.songTransitionSetting == .autoMix
        guard videoId != nil || EqualizerParameters.shared.isOn || bassCut else { return nil }
        var gain: Float = 1
        if let videoId { gain = Loudness.gain(forDecibels: await Loudness.shared.decibels(for: videoId)) }
        return await AudioEffects.mix(for: item, gain: gain, bassCut: bassCut)
    }

    /// Starts the item once its mix ("Volume uniforme", equalizer) is on: putting a mix on an item
    /// that already plays is heard as a gap. The mix is nearly always ready at once (the loudness
    /// comes with the audio links); if it takes longer than `limit`, the song starts and the mix follows.
    private func startWithEffects(_ item: AVPlayerItem, track: Track, limit: Duration = .milliseconds(600)) {
        let generation = requests.loadGeneration
        var started = false
        let start = {
            guard !started, self.requests.isCurrentLoad(generation), self.player.currentItem === item,
                  self.playWhenReady else { return }
            started = true
            self.activateSession()
            // Start as soon as the first audio arrives instead of waiting for a "safe" buffer;
            // later stalls are still handled by AVPlayer's normal waiting.
            self.player.playImmediately(atRate: 1)
        }
        Task {
            let mix = await self.audioMix(for: item, track: track)
            guard self.player.currentItem === item else { return }
            item.audioMix = mix
            start()
        }
        Task {
            try? await Task.sleep(for: limit)
            start()
        }
    }

    /// Applies the "Volume uniforme" and equalizer settings to the song that is playing.
    func applyAudioEffectsPreference() {
        guard let item = player.currentItem, let track = current else { return }
        if isPlayingStems {
            updateKaraokeMix()
        } else {
            applyAudioEffects(to: item, track: track)
        }
    }

    private func start(url: URL, track: Track, isRetry: Bool = false) {
        let item = AVPlayerItem(url: url)
        item.allowedAudioSpatializationFormats = Self.spatializationFormats
        player.replaceCurrentItem(with: item)
        begin(item, track: track, isRetry: isRetry)
    }

    /// Plays a player prepared in advance (see `PreparedPlayback`): its item already has audio
    /// buffered, so the song starts almost at once. It takes the place of the current, idle player.
    private func start(adopting prepared: AVPlayer, track: Track) {
        guard let item = prepared.currentItem else { return }
        // It buffered only a couple of seconds while waiting; playing, AVPlayer decides again.
        item.preferredForwardBufferDuration = 0
        player.pause()
        player.replaceCurrentItem(with: nil)
        player = prepared
        attach(prepared)
        begin(item, track: track, isRetry: false)
    }

    /// Everything once the song's item is on the player. Work that downloads or decodes waits
    /// for the first note (see `startDeferredPreparation`). An AutoMix transition has already
    /// started the song, with its volume and mix (`alreadyStarted`).
    private func begin(_ item: AVPlayerItem, track: Track, isRetry: Bool, alreadyStarted: Bool = false) {
        itemStatus = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak item] status in
                guard let item else { return }
                self.itemStatusChanged(status, item: item, track: track)
            }

        if !alreadyStarted {
            if pendingFadeIn != nil {
                // Crossfading in: stay silent until the song really plays (see `startPendingFades`).
                player.volume = 0
            } else if !isRetry {
                fadeInTask?.cancel()
                player.volume = 1
            }
            if playWhenReady {
                startWithEffects(item, track: track)
            } else {
                applyAudioEffects(to: item, track: track)
            }
        }
        deferredPreparation = (requests.loadGeneration, track)
        guard !isRetry else { return }
        scrobbler.begin(track)
        ListeningLog.shared.start(track)
        Library.shared.recordPlay(track)
        loadLyrics(for: track)
        updateNowPlayingInfo()
    }

    /// Runs once the song is audible: its local copy (and Opus), the next song, karaoke and the
    /// prepared player, which would otherwise compete with the stream's first seconds.
    private func startDeferredPreparation() {
        guard let pending = deferredPreparation, requests.isCurrentLoad(pending.generation),
              current?.id == pending.track.id else { return }
        deferredPreparation = nil
        prepareCurrentAudio(for: pending.track)
        prefetchNext()
        // Karaoke stays on from song to song, preparing only the current song.
        if karaokeMode != .off { startKaraoke() }
        PreparedPlayback.shared.resumeAfterStartup()
        offerUpcoming()
    }

    /// Prepare the requested song only. Upcoming songs never run the Opus decoder.
    private func prepareCurrentAudio(for track: Track) {
        upgradeTask?.cancel()
        guard playWhenReady, !isPlayingStems, Storage.localAudio(for: track) == nil,
              let videoId = track.videoId, let asset = player.currentItem?.asset as? AVURLAsset else { return }
        let quality = Preferences.streamingQuality
        let isStreaming = !asset.url.isFileURL
        let canConvert = UIApplication.shared.applicationState != .background && EnergyPolicy.current.allowsAudioConversion
        guard isStreaming || (quality.usesOpus && canConvert) else { return }
        let generation = requests.loadGeneration
        upgradeTask = Task {
            guard !Task.isCancelled, self.requests.isCurrentLoad(generation), self.playWhenReady else { return }
            if isStreaming, let copy = try? await Self.prepareCopy(videoId: videoId, quality: quality),
               !Task.isCancelled, self.requests.isCurrentLoad(generation), self.playWhenReady {
                self.offerLocal(copy.url, label: copy.label, track: track)
            }
            guard !Task.isCancelled, self.requests.isCurrentLoad(generation), self.playWhenReady,
                  UIApplication.shared.applicationState != .background,
                  quality.usesOpus, EnergyPolicy.current.allowsAudioConversion else { return }
            // Decoded Opus plays from the next listen, or from the next seek.
            if let opus = await Self.prepareOpus(videoId: videoId, quality: quality, duration: track.duration),
               !Task.isCancelled, self.requests.isCurrentLoad(generation), self.playWhenReady {
                self.offerLocal(opus.url, label: opus.label, track: track)
            }
        }
    }

    private func stopPreparationWork() {
        upgradeTask?.cancel()
        prefetchTask?.cancel()
        lyricsPrefetchTask?.cancel()
        karaokeTask?.cancel()
        StemSeparator.focus(on: [])
        if case .preparing = karaokeStatus { karaokeStatus = .idle }
    }

    private func applyEnergyBudget() {
        let budget = EnergyPolicy.current
        if !budget.allowsSpeculativeWork {
            prefetchTask?.cancel()
            lyricsPrefetchTask?.cancel()
        }
        if !budget.allowsAudioConversion { upgradeTask?.cancel() }
        if !budget.allowsKaraoke {
            karaokeTask?.cancel()
            StemSeparator.focus(on: [])
            StemSeparator.releaseEngine()
            if case .preparing = karaokeStatus {
                karaokeStatus = .failed(KaraokeError.energyLimited.localizedDescription)
            }
        }
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status, item: AVPlayerItem, track: Track) {
        guard item === player.currentItem else { return }
        switch status {
        case .readyToPlay:
            isLoading = false
            failuresInARow = 0
            startupMetrics.itemReady(requests.loadGeneration)
            if let start = pendingStartTime {
                pendingStartTime = nil
                seek(to: start)
            }
            updateNowPlayingInfo()
        case .failed:
            let message = player.currentItem?.error?.localizedDescription
                ?? PlayerError.unavailable.localizedDescription
            guard !retriedCurrentItem, let videoId = track.videoId, Storage.localAudio(for: track) == nil else {
                return fail(message)
            }
            // Stream URLs expire after a few hours: fetch a fresh one once before giving up.
            retriedCurrentItem = true
            let generation = requests.loadGeneration
            retryTask?.cancel()
            retryTask = Task {
                // Retry with plain AAC: the most reliable rendition.
                PreparedPlayback.shared.invalidate(videoId)
                await StreamResolver.shared.invalidate(videoId)
                let stream = try? await StreamResolver.shared.stream(for: videoId, quality: .high)
                guard !Task.isCancelled, self.requests.isCurrentLoad(generation),
                      self.player.currentItem === item else { return }
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
        let generation = requests.loadGeneration
        // Skip unplayable songs, but don't spin through a whole broken queue.
        guard failuresInARow < 3, index + 1 < queue.count else { return }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard self.requests.isCurrentLoad(generation), self.index == failedIndex,
                  self.errorMessage == message else { return }
            self.index += 1
            self.loadCurrent(reason: .automatic)
        }
    }

    private func advance(reason: StartupReason = .automatic) {
        advanceTask?.cancel()
        if index + 1 < queue.count {
            index += 1
            loadCurrent(reason: reason)
        } else if repeatMode == .all, !queue.isEmpty {
            index = 0
            loadCurrent(reason: reason)
        } else {
            let generation = requests.loadGeneration
            advanceTask = Task {
                if self.autoRadio { await self.extendQueue() }
                guard !Task.isCancelled, self.requests.isCurrentLoad(generation) else { return }
                if self.index + 1 < self.queue.count {
                    self.index += 1
                    self.loadCurrent(reason: reason)
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
        pendingFadeIn = min(remaining, plainCrossfadeSeconds)
        index += 1
        loadCurrent(crossfading: true)
    }

    /// Called when the new song starts playing: fades it in and the previous one out over
    /// whatever is left of the previous song.
    private func startPendingFades() {
        // An AutoMix transition sets its own volumes.
        guard transitionTask == nil else { return }
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
        if interrupted { stopTransition() }
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

    // MARK: AutoMix

    /// Seconds of plain crossfade at the end of a song: the setting's with "Dissolvenza incrociata";
    /// with AutoMix, a short one while no plan is ready (none between songs of the same album).
    private var plainCrossfadeSeconds: Double {
        switch Preferences.songTransitionSetting {
        case .off:
            return 0
        case .crossfade:
            return max(1, Preferences.crossfadeSeconds)
        case .autoMix:
            if let track = current, index + 1 < queue.count, !shuffleEnabled, Self.sameAlbum(track, queue[index + 1]) {
                return 0
            }
            return 5
        }
    }

    /// Applies a change of "Transizioni tra brani".
    func applyTransitionPreference() {
        resetAutoMix()
        prepareAutoMix()
    }

    /// Plans AutoMix's transition into the next song: both songs' files are analysed (the next
    /// song's is the copy it then plays from, so nothing is downloaded twice) and
    /// `TransitionPlanner` picks the transition. Until a plan is ready the song ends with a short
    /// plain crossfade; songs of the same album, in order, play as they are.
    private func prepareAutoMix() {
        guard Preferences.songTransitionSetting == .autoMix, karaokeMode == .off, playWhenReady,
              let track = current, index + 1 < queue.count else {
            resetAutoMix()
            return
        }
        let next = queue[index + 1]
        let pair = "\(track.id)>\(next.id)"
        if let autoMix, "\(autoMix.trackID)>\(autoMix.nextID)" == pair { return }
        if autoMixPair == pair { return }
        resetAutoMix()
        autoMixPair = pair
        if !shuffleEnabled, Self.sameAlbum(track, next) {
            autoMix = PlannedTransition(trackID: track.id, nextID: next.id, plan: nil, file: nil, label: "")
            return
        }
        let thermal = ProcessInfo.processInfo.thermalState
        guard let videoId = track.videoId, let nextVideoId = next.videoId,
              (track.duration ?? 0) <= AutoMixLibrary.lengthLimit, (next.duration ?? 0) <= AutoMixLibrary.lengthLimit,
              thermal != .serious, thermal != .critical else { return }
        let generation = requests.loadGeneration
        autoMixTask = Task {
            guard let outgoingFile = await self.analysisFile(for: track, videoId: videoId),
                  let incomingFile = await self.analysisFile(for: next, videoId: nextVideoId),
                  !Task.isCancelled else { return }
            async let outgoingAnalysis = AutoMixLibrary.shared.analysis(of: outgoingFile.url)
            async let incomingAnalysis = AutoMixLibrary.shared.analysis(of: incomingFile.url)
            let analyses = await (outgoingAnalysis, incomingAnalysis)
            guard !Task.isCancelled, self.requests.isCurrentLoad(generation), self.autoMixPair == pair,
                  let outgoing = analyses.0, let incoming = analyses.1 else { return }
            self.autoMix = PlannedTransition(trackID: track.id, nextID: next.id,
                                             plan: TransitionPlanner.plan(from: outgoing, to: incoming, sameAlbum: false),
                                             file: incomingFile.url, label: incomingFile.label)
            self.autoMixTask = nil
        }
    }

    /// The file a song is analysed from (and, for the next song, played from): its download, its
    /// cached file, or a fresh copy.
    private func analysisFile(for track: Track, videoId: String) async -> (url: URL, label: String)? {
        if let local = Storage.localAudio(for: track) {
            return (local, "\(DownloadManager.formatLabel(for: track) ?? "AAC") · offline")
        }
        if let cached = OpusPipeline.cachedFile(videoId: videoId) { return cached }
        return try? await Self.prepareCopy(videoId: videoId, quality: Preferences.streamingQuality)
    }

    /// Songs of the same album: one after the other in order, they play as they are.
    private static func sameAlbum(_ a: Track, _ b: Track) -> Bool {
        if let first = a.albumID, let second = b.albumID { return first == second }
        guard let first = a.album, let second = b.album, !first.isEmpty else { return false }
        return first.caseInsensitiveCompare(second) == .orderedSame && a.primaryArtist == b.primaryArtist
    }

    /// The AutoMix plan from the current song into the next, unless its moment was missed.
    private func plannedTransition() -> PlannedTransition? {
        guard let autoMix, !autoMix.missed, Preferences.songTransitionSetting == .autoMix, karaokeMode == .off,
              autoMix.trackID == current?.id, index + 1 < queue.count, queue[index + 1].id == autoMix.nextID
        else { return nil }
        return autoMix
    }

    /// Loads the next song shortly before the planned transition. A transition whose moment
    /// passed (a seek beyond it) becomes a plain crossfade.
    private func followPlan(_ planned: PlannedTransition, at seconds: TimeInterval) {
        guard let plan = planned.plan, outgoingPlayer == nil else { return }
        if armed == nil, seconds >= plan.outStart - 12, seconds < plan.outStart - 1.5 {
            armTransition(planned, plan: plan)
        } else if seconds > plan.outStart + 0.5, armed?.scheduled != true {
            disarm()
            autoMix?.missed = true
        }
    }

    /// Prepares the next song's player at the plan's starting point, with its audio mix on and
    /// its first audio decoded, then starts it on time.
    private func armTransition(_ planned: PlannedTransition, plan: TransitionPlan) {
        guard armed == nil, let file = planned.file, let track = current, index + 1 < queue.count,
              queue[index + 1].id == planned.nextID else { return }
        let next = queue[index + 1]
        let incoming = AVPlayer()
        // AVPlayer starts at an exact moment (see `startOnTime`) only without its own waiting.
        incoming.automaticallyWaitsToMinimizeStalling = false
        incoming.volume = 0
        let item = AVPlayerItem(url: file)
        // Keeps the pitch when the tempo is matched.
        item.audioTimePitchAlgorithm = .spectral
        item.allowedAudioSpatializationFormats = Self.spatializationFormats
        incoming.replaceCurrentItem(with: item)
        let transition = ArmedTransition(plan: plan, player: incoming, item: item, track: next,
                                         label: planned.label, outgoingTrackID: track.id)
        armed = transition
        armTask = Task {
            item.audioMix = await self.audioMix(for: item, track: next)
            var waited = 0
            while item.status == .unknown, waited < 50, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                waited += 1
            }
            guard !Task.isCancelled, self.armed === transition else { return }
            guard item.status == .readyToPlay, incoming.status == .readyToPlay else { return self.abandon(transition) }
            _ = await incoming.seek(to: CMTime(seconds: plan.inStart, preferredTimescale: 48_000),
                                    toleranceBefore: .zero, toleranceAfter: .zero)
            guard !Task.isCancelled, self.armed === transition, incoming.status == .readyToPlay else { return }
            _ = await incoming.preroll(atRate: Float(plan.rate))
            guard !Task.isCancelled, self.armed === transition else { return }
            await self.startOnTime(transition)
        }
    }

    /// Waits until the playing song is about to reach the plan's start, then has AVPlayer start
    /// the next song at that exact moment of the system clock, so its beats land on this song's.
    private func startOnTime(_ transition: ArmedTransition) async {
        let plan = transition.plan
        let outgoing = player
        while true {
            guard !Task.isCancelled, armed === transition, player === outgoing,
                  current?.id == transition.outgoingTrackID, karaokeMode == .off else { return abandon(transition) }
            guard outgoing.timeControlStatus == .playing, let item = outgoing.currentItem else {
                // Paused or waiting for the stream: try again shortly.
                try? await Task.sleep(for: .milliseconds(250))
                continue
            }
            let wait = plan.outStart - item.currentTime().seconds
            if wait <= 0.4 { break }
            try? await Task.sleep(for: .seconds(min(wait - 0.35, 1)))
        }
        guard let timebase = outgoing.currentItem?.timebase else { return abandon(transition) }
        let rate = CMTimebaseGetRate(timebase)
        let now = CMTimebaseGetTime(timebase).seconds
        guard rate > 0, now.isFinite, now <= plan.outStart + 0.05 else { return abandon(transition) }
        let start = CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()),
                              CMTime(seconds: (plan.outStart - now) / rate, preferredTimescale: 1_000_000_000))
        transition.player.setRate(Float(plan.rate), time: CMTime(seconds: plan.inStart, preferredTimescale: 48_000),
                                  atHostTime: start)
        transition.scheduled = true
        beginTransition(transition)
    }

    /// The next song is starting: it becomes the current song while this one plays out under it
    /// (as `outgoingPlayer`), following the plan.
    private func beginTransition(_ transition: ArmedTransition) {
        armed = nil
        armTask = nil
        let outgoing = player
        finishedCurrent = true
        fadeOutTask?.cancel()
        fadeOutTask = nil
        fadeInTask?.cancel()
        pendingFadeIn = nil
        outgoingPlayer = outgoing
        outgoingLength = current?.duration ?? 0
        player = transition.player
        attach(transition.player)
        runTransition(transition.plan, outgoing: outgoing, incoming: transition.player)
        index += 1
        loadCurrent(crossfading: true, reason: .automatic, adopting: transition)
    }

    /// Follows the outgoing song's time through the transition: both volumes and bass cuts, then
    /// the end of the outgoing song, then the new song's own tempo, brought back over 8 seconds.
    private func runTransition(_ plan: TransitionPlan, outgoing: AVPlayer, incoming: AVPlayer) {
        transitionTask?.cancel()
        let outgoingFilter = outgoing.currentItem?.transitionFilter
        let incomingFilter = incoming.currentItem?.transitionFilter
        let started = ProcessInfo.processInfo.systemUptime
        transitionTask = Task {
            while !Task.isCancelled {
                var progress = 1.0
                if self.outgoingPlayer === outgoing {
                    progress = plan.progress(atOutgoingTime: outgoing.currentTime().seconds)
                }
                // A stalled stream mustn't hold both songs: the transition ends on time anyway.
                if ProcessInfo.processInfo.systemUptime - started > plan.overlap + 3 { progress = 1 }
                let levels = plan.levels(at: progress)
                if self.outgoingPlayer === outgoing {
                    outgoing.volume = levels.outgoing
                    outgoingFilter?.set(levels.outgoingBassCut)
                }
                incoming.volume = levels.incoming
                incomingFilter?.set(levels.incomingBassCut)
                if progress >= 1 { break }
                try? await Task.sleep(for: .milliseconds(30))
            }
            guard !Task.isCancelled else { return }
            if self.outgoingPlayer === outgoing { self.endCrossfade(interrupted: false) }
            incoming.volume = 1
            incomingFilter?.set(0)
            if plan.rate != 1 {
                let steps = 40
                for step in 1...steps {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled, self.player === incoming, incoming.timeControlStatus == .playing else { break }
                    incoming.rate = Float(plan.rate + (1 - plan.rate) * Double(step) / Double(steps))
                }
            }
            guard !Task.isCancelled else { return }
            if self.player === incoming { incoming.automaticallyWaitsToMinimizeStalling = true }
            self.transitionTask = nil
        }
    }

    /// Ends an AutoMix transition early (pause, skip, seek): the new song goes on alone, at full
    /// volume and its own tempo.
    private func stopTransition() {
        guard let task = transitionTask else { return }
        task.cancel()
        transitionTask = nil
        player.currentItem?.transitionFilter?.set(0)
        if player.rate > 0, player.rate != 1 { player.rate = 1 }
        player.automaticallyWaitsToMinimizeStalling = true
    }

    private func resetAutoMix() {
        autoMixTask?.cancel()
        autoMixTask = nil
        autoMixPair = nil
        autoMix = nil
        disarm()
    }

    private func disarm() {
        armTask?.cancel()
        armTask = nil
        guard let armed else { return }
        armed.player.pause()
        armed.player.replaceCurrentItem(with: nil)
        self.armed = nil
    }

    /// The armed transition can't happen (paused or moved past it, the song changed): the song
    /// ends with a plain crossfade instead.
    private func abandon(_ transition: ArmedTransition) {
        guard armed === transition else { return }
        disarm()
        autoMix?.missed = true
    }

    // MARK: Queue upkeep

    /// Keeps the music going: when few songs are left, appends a radio based on the current one.
    private func extendQueueIfNeeded() {
        guard autoRadio, queue.count - index <= 3 else { return }
        let generation = requests.queueGeneration
        Task {
            guard self.requests.isCurrentQueue(generation) else { return }
            await self.extendQueue()
        }
    }

    @discardableResult
    private func extendQueue() async -> Bool {
        guard let seed = current?.videoId ?? queue.last(where: { $0.videoId != nil })?.videoId else { return false }
        return await requests.extendQueue { generation in
            guard self.requests.isCurrentQueue(generation), !Task.isCancelled,
                  let radio = try? await InnerTube.shared.radio(for: seed),
                  self.requests.isCurrentQueue(generation), !Task.isCancelled else { return false }
            let known = Set(self.queue.map(\.id))
            let skipLong = Preferences.skipsLongMixes
            let fresh = radio.filter { track in
                !known.contains(track.id) && !(skipLong && (track.duration ?? 0) > Preferences.longMixThreshold)
            }
            guard !fresh.isEmpty else { return false }
            let added = Array(fresh.prefix(30))
            self.unshuffledUpcoming.append(contentsOf: added)
            self.queue.append(contentsOf: self.shuffleEnabled ? added.shuffled() : added)
            self.offerUpcoming()
            return true
        }
    }

    /// Cache at most one upcoming native AAC file when iOS has spare energy.
    private func prefetchNext() {
        prefetchTask?.cancel()
        guard playWhenReady, UIApplication.shared.applicationState != .background,
              EnergyPolicy.current.allowsSpeculativeWork else { return }
        prefetchLyrics()
        guard index + 1 < queue.count else { return }
        let track = queue[index + 1]
        guard let videoId = track.videoId else { return }
        // With AutoMix the next song's copy is made by `prepareAutoMix`, at the quality it will play.
        let needsCopy = Storage.localAudio(for: track) == nil && OpusPipeline.cachedFile(videoId: videoId) == nil
            && Preferences.songTransitionSetting != .autoMix
        let prefetchLoudness = Preferences.normalizesVolume
        guard needsCopy || prefetchLoudness else { return }
        let quality = Preferences.initialStreamQuality
        let generation = requests.loadGeneration
        prefetchTask = Task(priority: .utility) {
            guard !Task.isCancelled, self.requests.isCurrentLoad(generation), self.playWhenReady,
                  EnergyPolicy.current.allowsSpeculativeWork else { return }
            if prefetchLoudness {
                _ = await Loudness.shared.decibels(for: videoId)
            }
            guard !Task.isCancelled, self.requests.isCurrentLoad(generation), self.playWhenReady,
                  EnergyPolicy.current.allowsSpeculativeWork else { return }
            if needsCopy {
                _ = try? await Self.prepareCopy(videoId: videoId, quality: quality)
            }
        }
    }

    /// Loads the lyrics (often already fetched during the previous song) and starts translating them,
    /// so both are ready when the lyrics panel opens.
    private func loadLyrics(for track: Track) {
        lyricsTask?.cancel()
        LyricsTranslator.shared.show([])
        if let prefetched = prefetchedLyrics[track.id] {
            showLyrics(prefetched)
            return
        }
        lyrics = .loading
        lyricsTask = Task {
            let result = await LyricsService.shared.lyrics(for: track)
            guard !Task.isCancelled, self.current?.id == track.id else { return }
            self.showLyrics(result)
        }
    }

    private func showLyrics(_ result: LyricsState) {
        lyrics = result
        if case .synced(let lines) = result { LyricsTranslator.shared.show(lines) }
    }

    /// Fetches the next song's lyrics, and translates them, while this one plays.
    private func prefetchLyrics() {
        lyricsPrefetchTask?.cancel()
        guard playWhenReady, EnergyPolicy.current.allowsSpeculativeWork, index + 1 < queue.count else { return }
        let upNext = queue[index + 1]
        guard prefetchedLyrics[upNext.id] == nil else { return }
        let generation = requests.loadGeneration
        lyricsPrefetchTask = Task {
            let result = await LyricsService.shared.lyrics(for: upNext)
            // A network error also reads as "unavailable": leave it to be fetched again.
            guard !Task.isCancelled, self.requests.isCurrentLoad(generation), self.playWhenReady,
                  EnergyPolicy.current.allowsSpeculativeWork, result != .unavailable else { return }
            if self.prefetchedLyrics.count >= 20 { self.prefetchedLyrics.removeAll() }
            self.prefetchedLyrics[upNext.id] = result
            if case .synced(let lines) = result { LyricsTranslator.shared.prefetch(lines) }
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
            // Only the iOS 27 player takes the cover as data: don't re-encode it for nothing.
            if self.systemNowPlayingBox != nil {
                self.currentArtworkData = artwork.image.jpegData(compressionQuality: 0.85)
            }
            self.backdrop = artwork.backdrop
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
            .sink { [weak newPlayer] status in
                guard let newPlayer, newPlayer === self.player else { return }
                self.requestedSeek?.setPlaying(status == .playing, now: ProcessInfo.processInfo.systemUptime)
                // While the next song loads during a crossfade, the previous one is still audible.
                self.isPlaying = status != .paused || self.outgoingPlayer != nil
                if status == .playing {
                    self.isLoading = false
                    self.startPendingFades()
                    self.startupMetrics.playing(self.requests.loadGeneration)
                    self.startDeferredPreparation()
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

        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { note in self.handleRouteChange(note) }
            .store(in: &cancellables)

        // Reading thermalState enables its change notifications on iOS.
        _ = EnergyPolicy.current
        NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .merge(with: NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange))
            .receive(on: DispatchQueue.main)
            .sink { _ in self.applyEnergyBudget() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { _ in
                self.stopPreparationWork()
                StemSeparator.releaseEngine()
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { _ in
                guard self.playWhenReady, let track = self.current, self.player.currentItem != nil else { return }
                if self.karaokeMode != .off, !self.isPlayingStems { self.startKaraoke() }
                else { self.prepareCurrentAudio(for: track) }
                self.prefetchNext()
                self.prepareAutoMix()
            }
            .store(in: &cancellables)

        // A separation the app was closed in the middle of shows up in Settings → Karaoke.
        StemSeparator.noteInterruptedRun()
        StemSeparator.removeLegacyModel()
        // The karaoke model takes a few hundred MB: give it back when iOS asks for memory
        // (after the separation in progress, if any).
        NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
            .sink { _ in StemSeparator.releaseEngine() }
            .store(in: &cancellables)
    }

    private func tick(_ seconds: TimeInterval) {
        guard seconds.isFinite else { return }
        let delta = seconds - lastTick
        lastTick = seconds
        progress.currentTime = seconds
        if abs(seconds - (resumePoint?.time ?? 0)) >= 5 || resumePoint?.track.id != current?.id {
            rememberPosition(seconds)
        }

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
            ListeningLog.shared.addListened(delta)
        }

        guard length > 0, !finishedCurrent, player.timeControlStatus == .playing else { return }
        let remaining = length - seconds
        if let planned = plannedTransition(), canCrossfade {
            followPlan(planned, at: seconds)
        } else {
            let crossfade = plainCrossfadeSeconds
            if crossfade > 0, outgoingPlayer == nil, canCrossfade, length > crossfade * 3, remaining <= crossfade {
                beginCrossfade(remaining: max(0.5, remaining), length: length)
                return
            }
        }
        if remaining < -1.5 {
            // The file keeps "playing" silence past the real end.
            itemFinished()
        }
    }

    /// Saves the current song and position for the Home's "Riprendi" card.
    private func rememberPosition(_ seconds: TimeInterval) {
        guard let track = current, track.videoId != nil, seconds.isFinite, seconds >= 0 else { return }
        let point = ResumePoint(track: track, time: seconds)
        resumePoint = point
        UserDefaults.standard.set(try? JSONEncoder().encode(point), forKey: Self.resumeKey)
    }

    /// Headphones going away (both AirPods out of the ears or in their case, Bluetooth headphones
    /// switched off or out of range, a wired pair unplugged) pause the music instead of moving it
    /// to the speaker; when they come back within half an hour, it carries on. Taking out a single
    /// AirPod, or Beats with ear detection, sends pause and play as remote commands instead
    /// (see `configureRemoteCommands`).
    private func handleRouteChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        switch reason {
        case .oldDeviceUnavailable:
            guard let previous = note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription,
                  Self.hasHeadphones(previous), playWhenReady else { return }
            pause()
            pausedForHeadphones = .now
        case .newDeviceAvailable:
            guard let paused = pausedForHeadphones, Date.now.timeIntervalSince(paused) < 30 * 60, !playWhenReady,
                  Self.hasHeadphones(AVAudioSession.sharedInstance().currentRoute) else { return }
            resume()
        default:
            break
        }
    }

    private static func hasHeadphones(_ route: AVAudioSessionRouteDescription) -> Bool {
        let kinds: Set<AVAudioSession.Port> = [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE]
        return route.outputs.contains { kinds.contains($0.portType) }
    }

    private func handleInterruption(_ note: Notification) {
        guard let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        if type == .began {
            requestedSeek?.setPlaying(false, now: ProcessInfo.processInfo.systemUptime)
            stopPreparationWork()
            endCrossfade()
            return
        }
        guard let rawOptions = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
              AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume),
              playWhenReady else { return }
        resume()
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

/// AutoMix's plan for one pair of songs (see `PlayerController.prepareAutoMix`).
private struct PlannedTransition {
    let trackID: String
    let nextID: String
    /// Nil: the two songs play as they are (same album).
    let plan: TransitionPlan?
    /// The next song's file, analysed and played from.
    let file: URL?
    let label: String
    /// Its moment passed without the transition.
    var missed = false
}

/// The next song's player, loaded at the plan's starting point and waiting for its moment.
private final class ArmedTransition {
    let plan: TransitionPlan
    let player: AVPlayer
    let item: AVPlayerItem
    let track: Track
    let label: String
    let outgoingTrackID: String
    /// Its start has been set on the system clock.
    var scheduled = false

    init(plan: TransitionPlan, player: AVPlayer, item: AVPlayerItem, track: Track, label: String, outgoingTrackID: String) {
        self.plan = plan
        self.player = player
        self.item = item
        self.track = track
        self.label = label
        self.outgoingTrackID = outgoingTrackID
    }
}
