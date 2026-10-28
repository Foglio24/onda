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
    /// What AutoMix plans for the end of the current song, shown in the queue.
    @Published private(set) var autoMixNote: String?
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
    /// Where the sound went at the last route change (for when iOS doesn't say where it was).
    private var lastOutputs: [(kind: AVAudioSession.Port, name: String)] = []
    /// AutoMix (see `prepareAutoMix`): the transition into the next song, planned while this one plays.
    private var autoMix: PlannedTransition?
    private var autoMixTask: Task<Void, Never>?
    /// The pair of songs being planned for, "current>next".
    private var autoMixPair: String?
    /// The next song's player, loaded and waiting for its moment (see `armTransition`).
    private var armed: ArmedTransition?
    private var armTask: Task<Void, Never>?
    /// The item playing an AutoMix mix: its first `length` seconds are the rendered mix, then the
    /// song carries on from its own time `join` (from `file`). Item time minus `itemOffset` is the
    /// song's time.
    private var mixItem: (item: AVPlayerItem, length: Double, join: Double, file: URL, label: String)?
    private var itemOffset: TimeInterval = 0
    /// What the current item plays with: its "Volume uniforme" gain and, when AutoMix may hand over
    /// from it, the fader in its audio processing (see `audioMix(for:track:)` and `startOnTime`).
    private var itemEffects: (item: AVPlayerItem, gain: Float, fader: HandoverFader?)?
    /// Between the start of a mix and the end of the song it takes over from.
    private var mixHandover = false
    /// The playlist the queue was started from, whose Mix then plays (see `playlistMix`).
    private var playlistContext: UUID?

    private init() {
        autoRadio = UserDefaults.standard.object(forKey: "player.autoRadio") as? Bool ?? true
        resumePoint = UserDefaults.standard.data(forKey: Self.resumeKey)
            .flatMap { try? JSONDecoder().decode(ResumePoint.self, from: $0) }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setSupportsMultichannelContent(true)
        lastOutputs = Self.outputs(session.currentRoute)
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
              shuffled: Bool? = nil, playlist: UUID? = nil) {
        guard tracks.indices.contains(start) else { return }
        playlistContext = playlist
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
        // An AutoMix transition about to start is prepared again after the pause.
        disarm()
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
        if outgoingPlayer != nil { endCrossfade() }
        if let mix = mixItem, player.currentItem === mix.item, let track = current {
            // An AutoMix item holds the song only from the end of its mix: before that, the song's
            // own file takes over.
            if seconds >= mix.join {
                player.seek(to: CMTime(seconds: seconds + itemOffset, preferredTimescale: 600),
                            toleranceBefore: .zero, toleranceAfter: .zero)
            } else {
                switchItem(to: AVPlayerItem(url: mix.file), label: mix.label, track: track, at: seconds)
            }
            progress.currentTime = seconds
            lastTick = seconds
            if seconds < progress.duration - 1 { finishedCurrent = false }
            updateNowPlayingInfo()
            return
        }
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
        if transition == nil {
            player.replaceCurrentItem(with: nil)
            mixItem = nil
            itemOffset = 0
            itemEffects = nil
        }
        progress.currentTime = 0
        progress.duration = track.duration ?? 0
        lastTick = 0
        lyrics = .loading
        loadArtwork(for: track)
        updateNowPlayingInfo()

        if let transition, let item = transition.item {
            // AutoMix already started the song (see `startOnTime`), from its mix.
            startupMetrics.resolved(generation, source: .localFile)
            begin(item, track: track, isRetry: false, alreadyStarted: true)
            // Like Apple Music's "Mixing" while the mix plays.
            streamInfo = "AutoMix"
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
    private func switchItem(to newItem: AVPlayerItem, label: String, track: Track, at time: TimeInterval? = nil) {
        guard current?.id == track.id, player.currentItem != nil else { return }
        var position = time ?? player.currentTime().seconds - itemOffset
        if let requested = requestedSeek {
            position = requested.position(at: ProcessInfo.processInfo.systemUptime)
        }
        requestedSeek = nil
        // The new item holds the song from its start.
        mixItem = nil
        itemOffset = 0
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
        // The mix into the next song is made from the audio that plays (see `outgoingFile`):
        // another file of the song needs a mix of its own.
        if let autoMix, autoMix.trackID == track.id, (newItem.asset as? AVURLAsset)?.url != autoMix.outgoingFile {
            resetAutoMix()
            prepareAutoMix()
        }
    }

    /// "Volume uniforme" and the equalizer, through the item's audio mix, so the player's own
    /// volume stays free for crossfades. "Volume uniforme" lowers songs louder than YouTube's
    /// reference level.
    private func applyAudioEffects(to item: AVPlayerItem, track: Track) {
        Task {
            let effects = await self.audioMix(for: item, track: track)
            guard self.player.currentItem === item else { return }
            item.audioMix = effects.mix
            self.noteEffects(effects, of: item, track: track)
        }
    }

    /// With AutoMix, also the fader of the handover from this song into the next (see `startOnTime`):
    /// it has to be in the item's audio mix from the start, as changing the mix of a song that plays
    /// is heard as a gap.
    private func audioMix(for item: AVPlayerItem, track: Track) async -> (mix: AVAudioMix?, gain: Float, fader: HandoverFader?) {
        let gain = await volumeGain(for: track)
        let effects = await AudioEffects.mix(for: item, gain: gain, fades: mixesTransitions)
        return (effects.mix, gain, effects.fader)
    }

    /// Keeps what the current item now plays with. A mix into the next song made at another gain
    /// would be louder or quieter than the song where it takes over: it is made again.
    private func noteEffects(_ effects: (mix: AVAudioMix?, gain: Float, fader: HandoverFader?),
                             of item: AVPlayerItem, track: Track) {
        itemEffects = (item, effects.gain, effects.fader)
        if let autoMix, autoMix.trackID == track.id, autoMix.outgoingGain != effects.gain {
            resetAutoMix()
            prepareAutoMix()
        }
    }

    /// The "Volume uniforme" gain the current item plays with, once its audio mix is on.
    private var playingGain: Float? {
        guard let itemEffects, itemEffects.item === player.currentItem else { return nil }
        return itemEffects.gain
    }

    /// The "Volume uniforme" gain of a song (1 with it off).
    private func volumeGain(for track: Track) async -> Float {
        guard Preferences.normalizesVolume, let videoId = track.videoId else { return 1 }
        return Loudness.gain(forDecibels: await Loudness.shared.decibels(for: videoId))
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
            let effects = await self.audioMix(for: item, track: track)
            guard self.player.currentItem === item else { return }
            item.audioMix = effects.mix
            self.noteEffects(effects, of: item, track: track)
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
        // An AutoMix item has its own mix of two parts: the change applies from the next song.
        if mixItem?.item === item { return }
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
        // An AutoMix mix has its own volumes.
        guard !mixHandover else { return }
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
        mixHandover = false
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

    /// The Mix of the playlist playing, when it is on: its transitions play, whatever the setting.
    private var playlistMix: PlaylistMix? {
        guard let id = playlistContext, let mix = Library.shared.playlist(id)?.mix, mix.enabled else { return nil }
        return mix
    }

    /// AutoMix (the setting) or a playlist's Mix makes the transitions.
    private var mixesTransitions: Bool {
        Preferences.songTransitionSetting == .autoMix || playlistMix != nil
    }

    /// Seconds of plain crossfade at the end of a song: the setting's with "Dissolvenza incrociata";
    /// with AutoMix, a short one while no plan is ready.
    private var plainCrossfadeSeconds: Double {
        if playlistMix != nil { return 5 }
        switch Preferences.songTransitionSetting {
        case .off:
            return 0
        case .crossfade:
            return max(1, Preferences.crossfadeSeconds)
        case .autoMix:
            return 5
        }
    }

    /// Applies a change of "Transizioni tra brani".
    func applyTransitionPreference() {
        resetAutoMix()
        prepareAutoMix()
    }

    /// Plans and renders AutoMix's mix into the next song, whatever the two songs are: both songs'
    /// files are analysed (the next song's is the copy it then plays from, so nothing is downloaded
    /// twice), `TransitionPlanner` picks the mix and `AutoMixRenderer` builds it into a file, which
    /// takes over from the playing song at the plan's handover. Until it is ready the song ends with
    /// a short plain crossfade.
    private func prepareAutoMix() {
        guard mixesTransitions, karaokeMode == .off, playWhenReady,
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
        let thermal = ProcessInfo.processInfo.thermalState
        guard let videoId = track.videoId, let nextVideoId = next.videoId,
              (track.duration ?? 0) <= AutoMixLibrary.lengthLimit, (next.duration ?? 0) <= AutoMixLibrary.lengthLimit,
              thermal != .serious, thermal != .critical else {
            autoMixNote = String(localized: "Non disponibile per questi brani: dissolvenza semplice")
            return
        }
        autoMixNote = String(localized: "Analisi dei brani in corso…")
        let generation = requests.loadGeneration
        // A transition designed in the playlist's Mix, when there is one for these two songs.
        let design = playlistMix?.transitions[PlaylistMix.key(from: track.id, to: next.id)]
        autoMixTask = Task {
            let source = self.playingSource
            let outgoingFile = await self.outgoingFile(for: track, videoId: videoId, source: source)
            let incomingFile = await self.analysisFile(for: next, videoId: nextVideoId)
            guard !Task.isCancelled, self.autoMixPair == pair else { return }
            var analyses: (TrackAnalysis?, TrackAnalysis?) = (nil, nil)
            if let outgoingFile, let incomingFile {
                async let outgoingAnalysis = AutoMixLibrary.shared.analysis(of: outgoingFile)
                async let incomingAnalysis = AutoMixLibrary.shared.analysis(of: incomingFile.url)
                analyses = await (outgoingAnalysis, incomingAnalysis)
            }
            guard !Task.isCancelled, self.requests.isCurrentLoad(generation), self.autoMixPair == pair else { return }
            guard let outgoingFile, let incomingFile, let outgoing = analyses.0, let incoming = analyses.1 else {
                self.autoMixTask = nil
                self.autoMixNote = String(localized: "Analisi non riuscita: dissolvenza semplice")
                return
            }
            let plan = design.map { MixDesigner.plan(from: outgoing, to: incoming, design: $0) }
                ?? TransitionPlanner.plan(from: outgoing, to: incoming)
            self.autoMixNote = String(localized: "Preparazione del mix…")
            // At the gain the song plays with, so the mix takes over at its very level.
            let outgoingGain: Float
            if let gain = self.playingGain { outgoingGain = gain } else { outgoingGain = await self.volumeGain(for: track) }
            let incomingGain = await self.volumeGain(for: next)
            let destination = AutoMixLibrary.newMixFile()
            let mix: AutoMixRenderer.Mix
            do {
                mix = try await AutoMixRenderer.render(MixSchedule(plan: plan), outgoing: outgoingFile,
                                                       incoming: incomingFile.url, outgoingGain: outgoingGain,
                                                       incomingGain: incomingGain, to: destination)
            } catch {
                guard !Task.isCancelled, self.autoMixPair == pair else { return }
                self.autoMixTask = nil
                self.autoMixNote = String(localized: "Mix non riuscito: dissolvenza semplice")
                return
            }
            guard !Task.isCancelled, self.requests.isCurrentLoad(generation), self.autoMixPair == pair else { return }
            self.autoMixTask = nil
            // Meanwhile the song moved to another file (a seek, karaoke) or gain: made again.
            let playing = self.playingSource
            guard playing == source || playing == outgoingFile, (self.playingGain ?? outgoingGain) == outgoingGain else {
                self.autoMixPair = nil
                self.prepareAutoMix()
                return
            }
            self.autoMix = PlannedTransition(trackID: track.id, nextID: next.id, plan: plan, mix: mix,
                                             file: incomingFile.url, label: incomingFile.label, incomingGain: incomingGain,
                                             outgoingFile: outgoingFile, outgoingGain: outgoingGain)
            self.autoMixNote = Self.describe(plan, from: outgoing, to: incoming)
        }
    }

    /// The plan in words, for the queue.
    private static func describe(_ plan: TransitionPlan, from outgoing: TrackAnalysis, to incoming: TrackAnalysis) -> String {
        let before = Int((outgoing.duration - plan.outStart).rounded())
        let tempoOut = Int(plan.tempoOut.rounded()), tempoIn = Int(plan.tempoIn.rounded())
        let seconds = Int(plan.overlap.rounded())
        if let design = plan.design {
            return String(localized: "Mix della playlist: \(design.preset.title), \(before) s prima della fine")
        }
        var text: String
        switch plan.style {
        case .beatMatched:
            let bars = plan.bars ?? 0
            text = String(localized: "Mix a tempo: \(bars) battute, \(tempoOut) → \(tempoIn) BPM, \(before) s prima della fine")
        case .fade:
            text = String(localized: "Dissolvenza sul finale: \(seconds) s")
        case .blend:
            text = plan.filterOut != nil
                ? String(localized: "Dissolvenza filtrata: \(seconds) s")
                : String(localized: "Dissolvenza incrociata: \(seconds) s")
        }
        if plan.inStart - incoming.soundStart > 3 {
            let start = Int(plan.inStart.rounded())
            let time = String(format: "%ld:%02ld", start / 60, start % 60)
            text += " · " + String(localized: "il prossimo parte da \(time)")
        }
        return text
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

    /// What the current song's audio comes from: its file, or the address of its stream.
    private var playingSource: URL? {
        if let mixItem, player.currentItem === mixItem.item { return mixItem.file }
        return (player.currentItem?.asset as? AVURLAsset)?.url
    }

    /// The file the playing song's part of the mix is made from: the very audio the player plays
    /// (`source`: its file, or a copy of the same stream), so the mix carries on exactly where the
    /// song is when it takes over. Another file of the song (decoded Opus, AAC 256, made meanwhile
    /// for the next listen) is encoded differently: its music lands some milliseconds off, which is
    /// heard as a jump at the handover.
    private func outgoingFile(for track: Track, videoId: String, source: URL?) async -> URL? {
        if let source, source.isFileURL { return source }
        if let source, let stream = await StreamResolver.shared.stream(for: videoId, at: source),
           let copy = try? await OpusPipeline.shared.localCopy(videoId: videoId, stream: stream) {
            return copy
        }
        return await analysisFile(for: track, videoId: videoId)?.url
    }

    /// The AutoMix plan from the current song into the next, unless its moment was missed.
    private func plannedTransition() -> PlannedTransition? {
        guard let autoMix, !autoMix.missed, mixesTransitions, karaokeMode == .off,
              autoMix.trackID == current?.id, index + 1 < queue.count, queue[index + 1].id == autoMix.nextID
        else { return nil }
        return autoMix
    }

    /// Loads the mix shortly before its handover. A mix whose moment passed (a seek beyond it)
    /// becomes a plain crossfade.
    private func followPlan(_ planned: PlannedTransition, at seconds: TimeInterval) {
        guard outgoingPlayer == nil else { return }
        let handover = planned.plan.handover
        if armed == nil, seconds >= handover - 12, seconds < handover - 1 {
            armTransition(planned)
        } else if seconds > handover + 0.3, armed?.scheduled != true {
            disarm()
            autoMix?.missed = true
            autoMixNote = String(localized: "Transizione saltata: dissolvenza semplice")
        }
    }

    /// Prepares the player of the mix: the rendered mix, then the next song from where the mix
    /// ends (overlapping by 30 ms, crossfaded), with the equalizer; then starts it on time.
    private func armTransition(_ planned: PlannedTransition) {
        guard armed == nil, let track = current, index + 1 < queue.count, queue[index + 1].id == planned.nextID else { return }
        let next = queue[index + 1]
        let incoming = AVPlayer()
        // AVPlayer starts at an exact moment (see `startOnTime`) only without its own waiting.
        incoming.automaticallyWaitsToMinimizeStalling = false
        let transition = ArmedTransition(planned: planned, player: incoming, track: next, outgoingTrackID: track.id)
        armed = transition
        armTask = Task {
            guard let made = await Self.makeMixItem(for: planned) else { return self.abandon(transition) }
            guard !Task.isCancelled, self.armed === transition else { return }
            let item = made.item
            item.allowedAudioSpatializationFormats = Self.spatializationFormats
            incoming.replaceCurrentItem(with: item)
            transition.item = item
            transition.fader = made.fader
            var waited = 0
            while item.status == .unknown, waited < 50, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                waited += 1
            }
            guard !Task.isCancelled, self.armed === transition else { return }
            guard item.status == .readyToPlay, incoming.status == .readyToPlay else { return self.abandon(transition) }
            _ = await incoming.preroll(atRate: 1)
            guard !Task.isCancelled, self.armed === transition else { return }
            await self.startOnTime(transition)
        }
    }

    /// The mix's item, and the fader for the handover from it into the song after (see `startOnTime`).
    nonisolated private static func makeMixItem(for planned: PlannedTransition) async -> (item: AVPlayerItem, fader: HandoverFader?)? {
        let mixAsset = AVURLAsset(url: planned.mix.url)
        let songAsset = AVURLAsset(url: planned.file)
        guard let mixTrack = try? await mixAsset.loadTracks(withMediaType: .audio).first,
              let songTrack = try? await songAsset.loadTracks(withMediaType: .audio).first,
              let songDuration = try? await songAsset.load(.duration) else { return nil }
        let composition = AVMutableComposition()
        guard let first = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
              let second = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return nil }
        let scale: CMTimeScale = 44_100
        let overlap = CMTime(seconds: 0.03, preferredTimescale: scale)
        let length = CMTime(seconds: planned.mix.length, preferredTimescale: scale)
        let join = CMTime(seconds: planned.mix.join, preferredTimescale: scale)
        guard CMTimeCompare(songDuration, join) > 0 else { return nil }
        do {
            try first.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: mixTrack, at: .zero)
            try second.insertTimeRange(CMTimeRange(start: CMTimeSubtract(join, overlap), end: songDuration),
                                       of: songTrack, at: CMTimeSubtract(length, overlap))
        } catch {
            return nil
        }
        let seam = CMTimeRange(start: CMTimeSubtract(length, overlap), duration: overlap)
        let mixPart = AVMutableAudioMixInputParameters(track: first)
        // The mix comes in under the playing song, which fades out over it (see `startOnTime`).
        mixPart.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1,
                              timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: handoverFade, preferredTimescale: scale)))
        mixPart.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: seam)
        let songPart = AVMutableAudioMixInputParameters(track: second)
        songPart.setVolumeRamp(fromStartVolume: 0, toEndVolume: planned.incomingGain, timeRange: seam)
        // The equalizer, and the fade of the next handover over both parts (it is in the item's time).
        let fader = await AudioEffects.isDolby([songTrack]) ? nil : HandoverFader()
        if fader != nil || EqualizerParameters.shared.isOn {
            mixPart.audioTapProcessor = EqualizerTap.make(fader: fader)
            songPart.audioTapProcessor = EqualizerTap.make(fader: fader)
        }
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = [mixPart, songPart]
        let item = AVPlayerItem(asset: composition)
        item.audioMix = audioMix
        return (item, fader)
    }

    /// How long the playing song and the mix overlap at the handover. There both play the same
    /// music (the mix starts as a copy of the song), so a short crossfade hides the change of player
    /// (two players never start on the very same sample: switched at once, it is heard as a cut).
    nonisolated private static let handoverFade = 0.25

    /// How long after the audio is made it is heard: a few milliseconds on the iPhone's speaker,
    /// a fifth of a second or more with AirPods, about two seconds over AirPlay.
    private static var outputLatency: TimeInterval {
        let session = AVAudioSession.sharedInstance()
        return max(0, session.outputLatency) + max(0, session.ioBufferDuration)
    }

    /// Waits until the playing song is about to reach the handover, then has AVPlayer start the mix
    /// at that exact moment of the system clock, fading in while the playing song fades out.
    ///
    /// The song fades out inside its own audio processing (`HandoverFader`), over the very stretch
    /// of the music the mix fades in on: the two add up to the song, whatever the output. That
    /// processing runs ahead of what is heard (by the output's latency, more with the screen
    /// locked), so both are set at least a second before it gets there. A song without the fader
    /// (one that started before AutoMix was turned on, or Dolby) fades out with the player's
    /// volume, set ahead by the output's latency.
    private func startOnTime(_ transition: ArmedTransition) async {
        let handover = transition.planned.plan.handover
        let outgoing = player
        let latency = Self.outputLatency
        while true {
            guard !Task.isCancelled, armed === transition, player === outgoing,
                  current?.id == transition.outgoingTrackID, karaokeMode == .off else { return abandon(transition) }
            guard outgoing.timeControlStatus == .playing, let item = outgoing.currentItem else {
                // Paused or waiting for the stream: try again shortly.
                try? await Task.sleep(for: .milliseconds(250))
                continue
            }
            let time = item.currentTime().seconds
            let ahead = handoverFader(of: item)?.ahead(of: time) ?? 0
            let lead = max(1, latency + 0.6, ahead + 0.6)
            let wait = handover + itemOffset - time
            if wait <= lead { break }
            try? await Task.sleep(for: .seconds(min(wait - lead + 0.05, 1)))
        }
        guard let item = outgoing.currentItem, let timebase = item.timebase, transition.item != nil else {
            return abandon(transition)
        }
        let rate = CMTimebaseGetRate(timebase)
        let now = CMTimebaseGetTime(timebase).seconds
        let target = handover + itemOffset
        guard rate > 0, now.isFinite, now <= target + 0.02 else { return abandon(transition) }
        let delay = max(0, (target - now) / rate)
        let start = CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()),
                              CMTime(seconds: delay, preferredTimescale: 1_000_000_000))
        let fade = Self.handoverFade
        let exact = handoverFader(of: item)?.fadeOut(at: target, over: fade, now: now) == true
        transition.player.setRate(1, time: .zero, atHostTime: start)
        transition.scheduled = true
        // The playing song goes on under the mix's first moments, and stops once its fade is heard.
        beginTransition(transition, outgoingFor: delay + fade + latency + 0.3)
        guard !exact else { return }
        fadeOutTask = Task {
            // Down in step with the mix coming up (same music: the two add up to the song). What is
            // set now is heard `latency` later.
            while !Task.isCancelled {
                let heard = CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), start).seconds + latency
                outgoing.volume = Float(max(0, min(1, 1 - heard / fade)))
                if heard >= fade { break }
                try? await Task.sleep(for: .milliseconds(heard < 0 ? max(1, Int(-heard * 1000)) : 8))
            }
        }
    }

    /// The fader in the item's audio processing, if it has one (`itemEffects` are the current item's).
    private func handoverFader(of item: AVPlayerItem) -> HandoverFader? {
        guard let itemEffects, itemEffects.item === item else { return nil }
        return itemEffects.fader
    }

    /// The mix is starting: the next song becomes the current song (its player plays the mix and
    /// then the song), while the playing one runs to the handover and fades out (as
    /// `outgoingPlayer`), stopping `seconds` from now.
    private func beginTransition(_ transition: ArmedTransition, outgoingFor seconds: TimeInterval) {
        guard let item = transition.item else { return }
        let planned = transition.planned
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
        mixHandover = true
        player = transition.player
        attach(transition.player)
        index += 1
        loadCurrent(crossfading: true, reason: .automatic, adopting: transition)
        mixItem = (item, planned.mix.length, planned.mix.join, planned.file, planned.label)
        itemOffset = planned.mix.length - planned.mix.join
        itemEffects = (item, planned.incomingGain, transition.fader)
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if self.outgoingPlayer === outgoing { self.endCrossfade(interrupted: false) }
        }
    }

    private func resetAutoMix() {
        autoMixTask?.cancel()
        autoMixTask = nil
        autoMixPair = nil
        autoMix = nil
        if autoMixNote != nil { autoMixNote = nil }
        disarm()
    }

    /// Drops the mix's waiting player.
    private func disarm() {
        armTask?.cancel()
        armTask = nil
        guard let armed else { return }
        armed.player.pause()
        armed.player.replaceCurrentItem(with: nil)
        self.armed = nil
    }

    /// The armed mix can't happen (paused or moved past it, the song changed): the song ends with
    /// a plain crossfade instead.
    private func abandon(_ transition: ArmedTransition) {
        guard armed === transition else { return }
        disarm()
        autoMix?.missed = true
        autoMixNote = String(localized: "Transizione saltata: dissolvenza semplice")
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
            && !mixesTransitions
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

    private func tick(_ itemTime: TimeInterval) {
        guard itemTime.isFinite else { return }
        // In an AutoMix item, the song's own time.
        let seconds = max(0, itemTime - itemOffset)
        if let mix = mixItem, streamInfo == "AutoMix", itemTime >= mix.length { streamInfo = mix.label }
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
    ///
    /// Whatever reason iOS gives for the change (not always "old device unavailable"), what counts is
    /// the sound moving from somewhere else to the iPhone itself. A route still settling (no output
    /// yet) is looked at again a moment later. The last change is kept for Settings → Informazioni.
    private func handleRouteChange(_ note: Notification) {
        let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
        let previous = (note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription)
            .map(Self.outputs) ?? lastOutputs
        let current = Self.outputs(AVAudioSession.sharedInstance().currentRoute)
        lastOutputs = current
        var action = String(localized: "nessuna azione")
        if Self.isAway(previous), playWhenReady {
            if current.isEmpty {
                // Still switching: decide once there is an output.
                Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    let settled = Self.outputs(AVAudioSession.sharedInstance().currentRoute)
                    self.lastOutputs = settled
                    guard self.playWhenReady, Self.isOnPhone(settled) else { return }
                    self.pauseForHeadphones()
                    self.noteRouteChange(reason, from: previous, to: settled, action: String(localized: "in pausa"))
                }
                action = String(localized: "in attesa")
            } else if Self.isOnPhone(current) {
                pauseForHeadphones()
                action = String(localized: "in pausa")
            }
        } else if let paused = pausedForHeadphones, Self.isAway(current), !playWhenReady,
                  Date.now.timeIntervalSince(paused) > 2, Date.now.timeIntervalSince(paused) < 30 * 60 {
            resume()
            action = String(localized: "ripresa")
        }
        noteRouteChange(reason, from: previous, to: current, action: action)
    }

    private func pauseForHeadphones() {
        pause()
        pausedForHeadphones = .now
    }

    /// The outputs of a route: their kind and name.
    private static func outputs(_ route: AVAudioSessionRouteDescription) -> [(kind: AVAudioSession.Port, name: String)] {
        route.outputs.map { ($0.portType, $0.portName) }
    }

    /// Playing on the iPhone itself (its speaker or earpiece).
    private static func isOnPhone(_ outputs: [(kind: AVAudioSession.Port, name: String)]) -> Bool {
        !outputs.isEmpty && outputs.allSatisfy { $0.kind == .builtInSpeaker || $0.kind == .builtInReceiver }
    }

    /// Playing somewhere else: headphones, AirPods, a Bluetooth or AirPlay speaker, the car.
    private static func isAway(_ outputs: [(kind: AVAudioSession.Port, name: String)]) -> Bool {
        !outputs.isEmpty && !isOnPhone(outputs)
    }

    private func noteRouteChange(_ reason: AVAudioSession.RouteChangeReason?, from previous: [(kind: AVAudioSession.Port, name: String)],
                                 to current: [(kind: AVAudioSession.Port, name: String)], action: String) {
        let names = { (outputs: [(kind: AVAudioSession.Port, name: String)]) -> String in
            outputs.isEmpty ? "—" : outputs.map(\.name).joined(separator: ", ")
        }
        let time = Date.now.formatted(date: .omitted, time: .standard)
        let text = "\(time) · \(names(previous)) → \(names(current)) (\(reason.map { "\($0.rawValue)" } ?? "?")) · \(action)"
        UserDefaults.standard.set(text, forKey: Preferences.lastRouteChange)
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

/// AutoMix's plan for one pair of songs and its rendered mix (see `PlayerController.prepareAutoMix`).
private struct PlannedTransition {
    let trackID: String
    let nextID: String
    let plan: TransitionPlan
    let mix: AutoMixRenderer.Mix
    /// The next song's file, analysed, mixed and played from.
    let file: URL
    let label: String
    let incomingGain: Float
    /// The playing song's file and gain the mix was made from (see `outgoingFile`).
    let outgoingFile: URL
    let outgoingGain: Float
    /// Its moment passed without the mix.
    var missed = false
}

/// The mix's player, loaded and waiting for its moment.
private final class ArmedTransition {
    let planned: PlannedTransition
    let player: AVPlayer
    let track: Track
    let outgoingTrackID: String
    var item: AVPlayerItem?
    /// The fader in the mix's item: it fades the next song out when that one hands over in turn.
    var fader: HandoverFader?
    /// Its start has been set on the system clock.
    var scheduled = false

    init(planned: PlannedTransition, player: AVPlayer, track: Track, outgoingTrackID: String) {
        self.planned = planned
        self.player = player
        self.track = track
        self.outgoingTrackID = outgoingTrackID
    }
}
