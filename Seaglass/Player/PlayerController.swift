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
            // Moving on through the songs added to the queue uses them up; going back starts over.
            if index > oldValue {
                queuedAhead = max(0, oldValue + queuedAhead - index)
            } else if index < oldValue {
                queuedAhead = 0
            }
            if queue.indices.contains(index) { playedInQueue.insert(queue[index].id) }
            scheduleQueueSave()
            syncNowPlaying()
        }
    }
    /// How many songs added to the queue ("Riproduci dopo", "Aggiungi in coda") wait right after the
    /// one playing: the next one added goes after them, before the rest of the album, playlist or
    /// radio, as in Spotify's queue. Shuffle leaves them where they are.
    private var queuedAhead = 0
    /// The songs of this queue that have played (or started): turning shuffle on brings back the
    /// others, those before the song playing too, as Spotify and Apple Music do.
    private var playedInQueue: Set<String> = []
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
    /// The speed of podcast episodes.
    @Published private(set) var episodeSpeed: Float
    /// The songs' tempo, -0.15…+0.15, and the key lock (see `PlaybackTempo`).
    @Published private(set) var songTempo: Double = PlaybackTempo.tempo
    @Published private(set) var tempoLimit: Double = PlaybackTempo.limit
    @Published private(set) var keyLock: Bool = PlaybackTempo.keyLock
    /// The playing song's own tempo in BPM, once measured (AutoMix's analysis), for the tempo fader.
    @Published private(set) var songBPM: (trackID: String, bpm: Double)?
    /// The song whose tempo is being measured, for the tempo panel's spinner.
    @Published private(set) var measuringBPM: String?
    private var bpmTask: Task<Void, Never>?

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
        /// The playlist the queue was started from, so its Mix plays after a relaunch too.
        var playlist: UUID?
        /// Songs added to the queue still waiting after the one playing (see `queuedAhead`).
        var queued: Int?
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
    /// Watches a song waiting for its stream to buffer (see `watchStall`).
    private var stallTask: Task<Void, Never>?
    /// The song whose stream was already reloaded once for a long stall.
    private var stallReloaded: String?
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
    /// A microphone session temporarily owns the shared audio session. Its stop callback must
    /// stop recording and restore the playback category synchronously before playback can resume.
    private struct RecognitionAudioReservation {
        let id: UUID
        let stop: @MainActor () -> Void
        let wasPlaying: Bool
        let queueGeneration: UUID
        let loadGeneration: UUID
        let trackID: String?
        let index: Int
        var mayResume = true
    }
    private var recognitionAudio: RecognitionAudioReservation?
    private var failuresInARow = 0
    private var retriedCurrentItem = false
    /// Set once the current song has ended (or started fading out), so it is never finished twice.
    private var finishedCurrent = false
    /// The song whose preparation (local copy, next song, karaoke) waits for its first note, so
    /// nothing competes with the start of its stream for the connection.
    private var deferredPreparation: (generation: UUID, track: Track)?
    private let startupMetrics = PlaybackStartupMetrics.shared
    private var lastTick: TimeInterval = 0
    /**
     What the lock screen was told: the song's position, when (system uptime), whether it plays, and
     the speed it moves on from there by itself. iOS 27's NowPlaying moves it at normal speed (it
     isn't told the tempo): `tick` sends the position again whenever what it shows strays.
     */
    private var reportedPosition: (elapsed: TimeInterval, at: TimeInterval, playing: Bool, rate: Double)?
    /// When the music paused because the headphones went away (see `handleRouteChange`).
    private var pausedForHeadphones: Date?
    /// Where the sound went at the last route change (for when iOS doesn't say where it was).
    private var lastOutputs: [(kind: AVAudioSession.Port, name: String)] = []
    /// AutoMix (see `prepareAutoMix`): the transition into the next song, planned while this one plays.
    private var autoMix: PlannedTransition?
    /// A live AutoMix transition planned by `SeguePolicy` (the next song played on a second player in
    /// step, its lanes in each player's audio processing), and its session once armed. The rendered
    /// mix (`autoMix`) is the fallback when it can't run.
    private var seguePlanned: SeguePlanned?
    private var segueSession: SegueSession?
    /// The pair the policy left as plain playback (no crossfade either), and a pair whose live mix
    /// couldn't be prepared (planned the rendered way instead).
    private var segueNormalPair: String?
    private var segueRefusedPair: String?
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
    private var itemEffects: (item: AVPlayerItem, gain: Float, fader: HandoverFader?, segue: SegueStage?)?
    /// The Opus stream the current item plays from while it downloads (see `OpusStream`), and the
    /// one of a song fading out (the stream serves its item until the end).
    private var opusPlayback: (item: AVPlayerItem, stream: OpusStream)?
    /// The song playing from a lossless copy (see `LosslessSources`): its item, so that a failure or
    /// a long stall hands it over once to the song's usual source, where it was.
    private var losslessPlayback: (trackID: String, item: AVPlayerItem, choice: LosslessSources.Choice)?
    private var losslessStall: Task<Void, Never>?
    private var outgoingOpus: OpusStream?
    /// Between the start of a mix and the end of the song it takes over from.
    private var mixHandover = false
    /// The playlist the queue was started from, whose Mix then plays (see `playlistMix`).
    private var playlistContext: UUID?

    private init() {
        autoRadio = UserDefaults.standard.object(forKey: "player.autoRadio") as? Bool ?? true
        episodeSpeed = UserDefaults.standard.object(forKey: Preferences.episodeSpeed) as? Float ?? 1
        resumePoint = UserDefaults.standard.data(forKey: Self.resumeKey)
            .flatMap { try? JSONDecoder().decode(ResumePoint.self, from: $0) }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setSupportsMultichannelContent(true)
        lastOutputs = Self.outputs(session.currentRoute)
        var usesNowPlayingFramework = false
        #if canImport(NowPlaying) && !targetEnvironment(macCatalyst)
        if #available(iOS 27, *) {
            let system = SystemNowPlaying()
            system.model.handlers = SeaglassMediaSessionModel.Handlers(
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
        stopMusicRecognitionForPlayback()
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
        playedInQueue = []
        queue = list
        index = first
        queuedAhead = 0
        self.source = source
        failuresInARow = 0
        loadCurrent()
        if startRadio {
            let generation = requests.queueGeneration
            if tracks[start].videoId == nil {
                // A song known only by its title and artist (recognized, from Last.fm) has no
                // radio to ask for until it's found on YouTube Music: it starts then (`loadCurrent`).
                radioAwaitingSong = generation
            } else {
                Task {
                    guard self.requests.isCurrentQueue(generation) else { return }
                    await self.extendQueue()
                }
            }
        }
    }

    /// The queue whose radio waits for its first song to be found on YouTube Music.
    private var radioAwaitingSong: UUID?

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
        if point.track.isPodcastEpisode {
            play([point.track], source: point.track.album ?? point.track.artist)
        } else {
            playRadio(from: point.track)
        }
        pendingStartTime = Self.startTime(of: point)
    }

    /// Plays podcast episodes, each from where it was left (see `loadCurrent`), without a radio after.
    func playEpisodes(_ tracks: [Track], startAt start: Int = 0, source: String) {
        play(tracks, startAt: start, source: source)
    }

    /// Back or forward within the episode (or song).
    func skip(by seconds: TimeInterval) {
        guard current != nil else { return }
        let end = progress.duration > 1 ? progress.duration - 1 : .greatestFiniteMagnitude
        seek(to: max(0, min(end, progress.currentTime + seconds)))
    }

    func setEpisodeSpeed(_ speed: Float) {
        episodeSpeed = speed
        UserDefaults.standard.set(speed, forKey: Preferences.episodeSpeed)
        applyRate()
    }

    /// Songs up to 15 % faster or slower (see `PlaybackTempo`), until set back to 0.
    func setSongTempo(_ tempo: Double) {
        let value = PlaybackTempo.snapped(tempo)
        guard value != songTempo else { return }
        let wasMixing = songTempo == 0
        songTempo = value
        UserDefaults.standard.set(value, forKey: Preferences.songTempo)
        applyRate()
        // AutoMix and the crossfade pause while the tempo is changed, and come back at 0.
        if wasMixing != (value == 0) {
            if value == 0 { prepareAutoMix() } else { resetAutoMix() }
        }
        // A local copy waiting for a seek takes over now: a stream may not keep up at another speed.
        if value != 0, let local = localFile, let track = current, local.trackID == track.id {
            localFile = nil
            switchItem(to: AVPlayerItem(url: local.url), label: local.label, track: track)
        }
    }

    /// How far the tempo fader goes either way (one of `PlaybackTempo.ranges`); the tempo set stays within it.
    func setTempoLimit(_ limit: Double) {
        guard PlaybackTempo.ranges.contains(limit) else { return }
        tempoLimit = limit
        UserDefaults.standard.set(limit, forKey: Preferences.tempoRange)
        if abs(songTempo) > limit { setSongTempo(songTempo) }
    }

    /// The voice at its own pitch whatever the tempo (on), or higher when faster, as on a turntable (off).
    func setKeyLock(_ on: Bool) {
        keyLock = on
        UserDefaults.standard.set(on, forKey: Preferences.keyLock)
        applyRate()
    }

    /// The playing song's tempo, measured by AutoMix's analysis (made once per song), for the fader.
    func measureSongBPM() {
        guard let track = current, !track.isPodcastEpisode, let videoId = track.videoId,
              songBPM?.trackID != track.id, measuringBPM != track.id else { return }
        bpmTask?.cancel()
        measuringBPM = track.id
        bpmTask = Task {
            let started = Date()
            // The very file playing (the stream's own once it's all in), not a second download of the
            // song, analysed ahead of other work: someone is waiting for the number.
            let file = await self.outgoingFile(for: track, videoId: videoId, source: self.playingSource)
            let found = Date()
            var analysis: TrackAnalysis?
            if let file, !Task.isCancelled {
                // In the background: never ahead of the decoding of the song that plays.
                analysis = await AutoMixLibrary.shared.analysis(of: file, priority: .utility, beats: false)
            }
            if LaunchScene.isActive {
                let times = String(format: "file in %.1f s, analysis in %.1f s", found.timeIntervalSince(started),
                                   Date().timeIntervalSince(found))
                print("tempo-bpm: \(file?.lastPathComponent ?? "no file") (\(times)), tempo \(analysis?.tempo ?? 0), grid fit \(analysis?.gridFit ?? 0)")
            }
            if self.measuringBPM == track.id { self.measuringBPM = nil }
            guard let bpm = analysis?.shownTempo, self.current?.id == track.id else { return }
            self.songBPM = (track.id, bpm)
        }
    }

    /// The current item's speed: podcasts at theirs, songs at the tempo set.
    private var playbackRate: Float { current?.isPodcastEpisode == true ? episodeSpeed : PlaybackTempo.rate }

    /// How the current item's tempo is changed: songs as the key lock says, podcasts always keeping
    /// the voice's pitch.
    private var pitchAlgorithm: AVAudioTimePitchAlgorithm {
        current?.isPodcastEpisode == true ? .spectral : PlaybackTempo.pitchAlgorithm
    }

    /// The player plays at `playbackRate` from its next `play()` on, and right away if it is playing.
    private func applyRate() {
        // A song coming in through a live mix plays at the speed its session sets (in step, then back
        // to its own): nothing here may jump it to another.
        if let session = segueSession, session.player === player, session.phase == .mixing || session.phase == .restoring {
            player.defaultRate = session.rate
            updateNowPlayingInfo()
            return
        }
        let rate = playbackRate
        if let item = player.currentItem, item.audioTimePitchAlgorithm != pitchAlgorithm {
            item.audioTimePitchAlgorithm = pitchAlgorithm
        }
        player.defaultRate = rate
        if player.timeControlStatus != .paused, player.rate != rate { player.rate = rate }
        requestedSeek?.setRate(Double(rate), now: ProcessInfo.processInfo.systemUptime)
        updateNowPlayingInfo()
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
        queuedAhead = min(max(0, saved.queued ?? 0), saved.tracks.count - saved.index - 1)
        source = saved.source
        shuffleEnabled = saved.shuffled
        unshuffledUpcoming = saved.unshuffled
        playlistContext = saved.playlist
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

    /// Shows a queue paused on its first song without loading anything, as after a relaunch: for
    /// the screenshots (see `LaunchScene`), as YouTube doesn't hand audio to CI's machines.
    func cue(_ tracks: [Track], source: String) {
        guard let first = tracks.first else { return }
        stopMusicRecognitionForPlayback()
        requests.replaceQueue()
        advanceTask?.cancel()
        playedInQueue = []
        queue = tracks
        index = 0
        queuedAhead = 0
        self.source = source
        unshuffledUpcoming = []
        playlistContext = nil
        playWhenReady = false
        isRestoredSession = true
        progress.duration = first.duration ?? 0
        loadArtwork(for: first)
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
                               shuffled: shuffleEnabled, unshuffled: Array(unshuffledUpcoming.prefix(200)),
                               playlist: playlistContext, queued: queuedAhead)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: Self.queueFile, options: .atomic)
    }

    /// Right after the song playing, before the songs added earlier.
    func playNext(_ track: Track) {
        guard current != nil else { return play([track], source: String(localized: "Coda")) }
        queue.insert(track, at: index + 1)
        queuedAhead += 1
        offerUpcoming()
    }

    /// After the song playing and the songs added before it, ahead of the rest of the queue.
    func addToQueue(_ track: Track) {
        guard current != nil else { return play([track], source: String(localized: "Coda")) }
        queue.insert(track, at: min(queue.count, index + 1 + queuedAhead))
        queuedAhead += 1
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
        // The songs added to the queue stay first, in their order; the rest is shuffled or put back.
        queuedAhead = min(queuedAhead, queue.count - index - 1)
        let start = min(queue.count, index + 1 + queuedAhead)
        let upcomingTracks = Array(queue[start...])
        if shuffleEnabled {
            // Back to the original order; songs added while shuffled keep their place at the end.
            let restored = PlaybackQueueOrder.restoring(original: unshuffledUpcoming,
                                                        upcoming: upcomingTracks, id: { $0.id })
            queue.replaceSubrange(start..., with: restored)
            unshuffledUpcoming = []
        } else {
            // Every song of the queue not played yet, those before the one playing too (a song
            // chosen near the end of a playlist doesn't leave only the few after it).
            let earlier = queue[..<index]
            let waiting = earlier.filter { !playedInQueue.contains($0.id) }
            let others = waiting + upcomingTracks
            let played = earlier.filter { playedInQueue.contains($0.id) }
            let playingAndQueued = Array(queue[index..<start])
            let queued = queuedAhead
            unshuffledUpcoming = others
            queue = played + playingAndQueued + others.shuffled()
            index = played.count
            queuedAhead = queued
        }
        shuffleEnabled.toggle()
        offerUpcoming()
    }

    func removeUpcoming(atOffsets offsets: IndexSet) {
        let removed = offsets.map { queue[$0 + index + 1] }
        queuedAhead -= offsets.filter { $0 < queuedAhead }.count
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
        stopMusicRecognitionForPlayback()
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

    /// Gives an explicitly requested recognition recording exclusive use of the audio session.
    /// The current song and position stay in place. In-flight startup and delayed automatic skips
    /// are invalidated so they cannot start music over the microphone or change the saved song.
    @discardableResult
    func reserveAudioForMusicRecognition(onStop: @escaping @MainActor () -> Void) -> UUID {
        stopMusicRecognitionForPlayback()
        let wasPlaying = playWhenReady && current != nil && !isRestoredSession
        pause()
        pausedForHeadphones = nil
        resetAutoMix()
        loadTask?.cancel()
        retryTask?.cancel()
        advanceTask?.cancel()
        _ = requests.beginLoad()
        deferredPreparation = nil
        isLoading = false
        isPlaying = false
        PreparedPlayback.shared.suspendForStartup(keeping: nil)
        StemSeparator.releaseEngine()
        let id = UUID()
        recognitionAudio = RecognitionAudioReservation(id: id, stop: onStop, wasPlaying: wasPlaying,
            queueGeneration: requests.queueGeneration, loadGeneration: requests.loadGeneration,
            trackID: current?.id, index: index)
        return id
    }

    /// The recording service restores the audio session before releasing this reservation. By
    /// default music stays paused; optional resumption requires the exact saved playback intent.
    func releaseAudioForMusicRecognition(_ id: UUID, resume: Bool = false) {
        guard let reservation = recognitionAudio, reservation.id == id else { return }
        recognitionAudio = nil
        PreparedPlayback.shared.resumeAfterStartup()
        guard resume, reservation.wasPlaying, reservation.mayResume,
              requests.isCurrentQueue(reservation.queueGeneration),
              requests.isCurrentLoad(reservation.loadGeneration),
              current?.id == reservation.trackID, index == reservation.index else { return }
        self.resume()
    }

    private func stopMusicRecognitionForPlayback() {
        guard let reservation = recognitionAudio else { return }
        // Clear ownership before the callback, which calls release as part of its cleanup too.
        recognitionAudio = nil
        reservation.stop()
        PreparedPlayback.shared.resumeAfterStartup()
    }

    /// The updater is about to quit the whole Mac app, including its menu-bar session. Persist
    /// playback before releasing every player and invalidate in-flight results before they return.
    func prepareForAppTermination() {
        stopMusicRecognitionForPlayback()
        pause()
        saveQueueTask?.cancel()
        saveQueue()
        requests.replaceQueue()
        loadTask?.cancel()
        retryTask?.cancel()
        advanceTask?.cancel()
        lyricsTask?.cancel()
        artworkTask?.cancel()
        bpmTask?.cancel()
        sleepTask?.cancel()
        fadeInTask?.cancel()
        resetAutoMix()
        PreparedPlayback.shared.suspendForStartup(keeping: nil)
        StemSeparator.releaseEngine()
        opusPlayback?.stream.cancel()
        opusPlayback = nil
        deferredPreparation = nil
        itemStatus = nil
        playerCancellables.removeAll()
        cancellables.removeAll()
        if let observedPlayer, let timeObserver { observedPlayer.removeTimeObserver(timeObserver) }
        timeObserver = nil
        observedPlayer = nil
        player.replaceCurrentItem(with: nil)
        isLoading = false
        isPlaying = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func resume() {
        guard current != nil else { return }
        stopMusicRecognitionForPlayback()
        pausedForHeadphones = nil
        playWhenReady = true
        if let item = player.currentItem, item.status != .failed {
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
        stopMusicRecognitionForPlayback()
        // Counts as a skip for the recommendations if the song played less than 30 seconds.
        ListeningLog.shared.noteSkip()
        advance(reason: .skip)
    }

    func previous() {
        stopMusicRecognitionForPlayback()
        if progress.currentTime > 3 || index == 0 {
            seek(to: 0)
        } else {
            index -= 1
            loadCurrent(reason: .skip)
        }
    }

    func seek(to seconds: TimeInterval) {
        recognitionAudio?.mayResume = false
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
        // An Opus stream seeks like a file (where it isn't decoded yet, it waits for it).
        if let asset = player.currentItem?.asset as? AVURLAsset, !asset.url.isFileURL, asset.url.scheme != OpusStream.scheme {
            // Seeking in YouTube's streams is unreliable: remember it for when the local copy takes over.
            requestedSeek = StreamingSeekPosition(time: seconds,
                                                   isPlaying: player.timeControlStatus == .playing,
                                                   now: ProcessInfo.processInfo.systemUptime,
                                                   rate: Double(playbackRate))
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
        guard playWhenReady, !Self.isInBackground,
              karaokeMode != .off, let track = current, let videoId = track.videoId,
              !track.isPodcastEpisode else { return }
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
                             adopting transition: ArmedTransition? = nil,
                             adoptingLive live: (item: AVPlayerItem, label: String)? = nil) {
        guard recognitionAudio == nil else { return }
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
        losslessPlayback = nil
        losslessStall?.cancel()
        resetAutoMix()
        guard let track = current else { return }
        if track.isPodcastEpisode { pendingStartTime = PodcastLibrary.shared.startTime(for: track.videoId) }
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
        if let opus = opusPlayback {
            // A song fading out still plays from its stream; one left behind stops downloading.
            if crossfading, opus.item === outgoingPlayer?.currentItem {
                outgoingOpus = opus.stream
            } else {
                opus.stream.cancel()
            }
            opusPlayback = nil
        }
        if transition == nil, live == nil {
            player.replaceCurrentItem(with: nil)
            mixItem = nil
            itemOffset = 0
            itemEffects = nil
        } else if live != nil {
            mixItem = nil
            itemOffset = 0
        }
        progress.currentTime = 0
        progress.duration = track.duration ?? 0
        lastTick = 0
        lyrics = .loading
        loadArtwork(for: track)
        updateNowPlayingInfo()

        if let live {
            // A live mix already started the song on its own player, in step (see `SegueSession`).
            startupMetrics.resolved(generation, source: .localFile)
            begin(live.item, track: track, isRetry: false, alreadyStarted: true)
            streamInfo = "AutoMix"
            extendQueueIfNeeded()
            return
        }
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
                // A lossless copy (a file of the user's, their own server), within a short budget:
                // otherwise the song plays as before, and the search goes on for the next time.
                let searchStarted = Date()
                let choice = await LosslessSources.shared.choice(for: playable, budget: LosslessSources.startupBudget)
                if LaunchScene.isActive {
                    let seconds = Date().timeIntervalSince(searchStarted).formatted(.number.precision(.fractionLength(1)))
                    print("lossless: choice in \(seconds) s: \(choice?.label ?? "none")")
                }
                if let choice {
                    guard !Task.isCancelled, self.requests.isCurrentLoad(generation), self.index == position else { return }
                    self.startupMetrics.resolved(generation, source: choice.isLocal ? .localFile : .network)
                    self.start(lossless: choice, track: playable)
                    return
                }
                guard !Task.isCancelled, self.requests.isCurrentLoad(generation), self.index == position else { return }
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
                // Found now: its radio, asked for or automatic, can start (it had no seed before).
                if track.videoId == nil, playable.videoId != nil {
                    if self.radioAwaitingSong == self.requests.queueGeneration {
                        self.radioAwaitingSong = nil
                        let queueGeneration = self.requests.queueGeneration
                        Task {
                            guard self.requests.isCurrentQueue(queueGeneration) else { return }
                            await self.extendQueue()
                        }
                    } else {
                        self.extendQueueIfNeeded()
                    }
                }
                // A player prepared while the song was on screen or next in the queue already
                // has audio buffered: play that one (not during a crossfade, which has its own).
                if !crossfading, let videoId = playable.videoId,
                   let prepared = PreparedPlayback.shared.take(for: videoId, quality: Preferences.initialStreamQuality) {
                    self.startupMetrics.resolved(generation, source: prepared.opus == nil ? .prepared : .opusPrepared)
                    self.streamInfo = prepared.label
                    if let opus = prepared.opus, let item = prepared.player.currentItem {
                        opus.resume()
                        self.opusPlayback = (item, opus)
                    }
                    self.start(adopting: prepared.player, track: playable)
                    return
                }
                let source = await self.startupSource(for: playable)
                // At the Opus qualities, Opus plays from its first seconds while it downloads.
                let opus = try await self.opusStart(for: playable)
                guard !Task.isCancelled, self.requests.isCurrentLoad(generation), self.index == position else {
                    if case .stream(let stream, _) = opus { stream.cancel() }
                    return
                }
                if case .stream(let stream, let label) = opus {
                    self.startupMetrics.resolved(generation, source: source == .resolvedURL ? .opusResolvedURL : .opusNetwork)
                    self.streamInfo = label
                    self.start(opus: stream, track: playable)
                    return
                }
                let stream = try await self.stream(for: playable)
                guard !Task.isCancelled, self.requests.isCurrentLoad(generation), self.index == position else { return }
                self.startupMetrics.resolved(generation, source: source)
                if case .unavailable(let reason) = opus {
                    // Said where the format is shown, as AAC plays instead.
                    self.streamInfo = "\(stream.label) · " + String(localized: "Opus: \(reason)")
                } else {
                    self.streamInfo = stream.label
                }
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

    /// How a song starts at the Opus qualities.
    private enum OpusStart {
        /// From a file, or the best rendition isn't Opus (Dolby, AAC 256): the usual way.
        case none
        /// Opus from its first seconds, while it downloads.
        case stream(OpusStream, label: String)
        /// Opus can't play now: AAC does, and says why.
        case unavailable(String)
    }

    /// At the Opus qualities (with "Opus dal primo suono"), the song's Opus stream, started. AAC
    /// plays instead only when Opus can't: a song over 20 minutes (its decoded audio would be too
    /// big), or Low Power Mode or a hot iPhone; the reason is kept for Settings.
    private func opusStart(for track: Track) async throws -> OpusStart {
        let quality = Preferences.streamingQuality
        guard quality.usesOpus, Preferences.playsOpusFromStart, let videoId = track.videoId,
              Storage.localAudio(for: track) == nil else { return .none }
        // Decoded Opus from an earlier listen plays as a file.
        if let cached = OpusPipeline.cachedFile(videoId: videoId), cached.label.hasPrefix("Opus") { return .none }
        if (track.duration ?? 0) > Preferences.opusLengthLimit {
            return noteOpusFallback(String(localized: "brano oltre 20 minuti"))
        }
        guard EnergyPolicy.current.allowsAudioConversion else {
            return noteOpusFallback(String(localized: "risparmio energetico"))
        }
        let stream = try await StreamResolver.shared.stream(for: videoId, quality: quality)
        guard stream.format == .opus else { return .none }
        let opus = OpusStream(source: .remote(stream.url), destination: OpusPipeline.streamFile(videoId: videoId, stream: stream),
                              duration: track.duration)
        opus.start()
        return .stream(opus, label: stream.label)
    }

    // MARK: Lossless

    /// Plays a lossless copy (see `LosslessSources`), showing its format as the audio itself states it.
    private func start(lossless choice: LosslessSources.Choice, track: Track) {
        streamInfo = choice.label
        start(url: choice.url, track: track)
        guard let item = player.currentItem else { return }
        losslessPlayback = (track.id, item, choice)
        Task {
            guard let format = await AudioFormatProbe.probe(item.asset), self.player.currentItem === item else { return }
            self.streamInfo = LosslessSources.Choice.label(format, source: choice.candidate.source)
            if LaunchScene.isActive { print("lossless: verified \(format.label) (\(choice.isLocal ? "file" : "stream"))") }
        }
    }

    /// The lossless copy failed while playing (an error, a dropped stream, an expired address, audio
    /// that doesn't decode): the song's usual source (its download, or YouTube at the quality set)
    /// carries on from where it was, once. The copy isn't tried again for it (no going back and forth).
    private func fallBackFromLossless(_ item: AVPlayerItem, track: Track, reason: String) {
        guard let lossless = losslessPlayback, lossless.item === item, player.currentItem === item else { return }
        losslessPlayback = nil
        losslessStall?.cancel()
        LosslessSources.shared.failed(track, lossless.choice.candidate)
        if LaunchScene.isActive { print("lossless: fallback (\(reason))") }
        let position = progress.currentTime
        let generation = requests.loadGeneration
        let time = Date.now.formatted(date: .omitted, time: .standard)
        UserDefaults.standard.set("\(time) · \(lossless.choice.label): \(reason)", forKey: Preferences.lastLosslessFallback)
        retryTask?.cancel()
        retryTask = Task {
            do {
                var playable = track
                if playable.videoId == nil, !playable.id.hasPrefix(LocalLosslessLibrary.trackPrefix) {
                    playable = try await InnerTube.shared.resolve(track)
                }
                let stream = try await self.stream(for: playable)
                guard !Task.isCancelled, self.requests.isCurrentLoad(generation), self.player.currentItem === item else { return }
                self.switchItem(to: AVPlayerItem(url: stream.url),
                                label: "\(stream.label) · " + String(localized: "lossless non disponibile"),
                                track: track, at: position)
            } catch {
                guard !Task.isCancelled, self.requests.isCurrentLoad(generation), self.player.currentItem === item else { return }
                self.fail(reason.isEmpty ? error.localizedDescription : reason)
            }
        }
    }

    /// CI only (see LaunchScene): the lossless stream cut off where it is, as a dropped connection is.
    func simulateLosslessFailure() {
        guard LaunchScene.isActive, let lossless = losslessPlayback, let track = current else { return }
        fallBackFromLossless(lossless.item, track: track, reason: "simulated dropout")
    }

    /// A lossless stream that stays stalled while it should play (the server gone, the network too
    /// slow for it) hands over like a failure, after a few seconds.
    private func watchLosslessStall(_ item: AVPlayerItem) {
        guard let lossless = losslessPlayback, lossless.item === item, !lossless.choice.isLocal, let track = current else { return }
        losslessStall?.cancel()
        losslessStall = Task {
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, self.losslessPlayback?.item === item, self.playWhenReady,
                  !item.isPlaybackLikelyToKeepUp, self.player.timeControlStatus != .playing else { return }
            self.fallBackFromLossless(item, track: track, reason: String(localized: "stream interrotto"))
        }
    }

    /// AAC plays where Opus should have: kept, with the reason, for Settings → Diagnostica.
    private func noteOpusFallback(_ reason: String) -> OpusStart {
        let time = Date.now.formatted(date: .omitted, time: .standard)
        UserDefaults.standard.set("\(time) · \(reason)", forKey: Preferences.lastOpusFallback)
        return .unavailable(reason)
    }

    /// Plays an Opus stream as it downloads (see `OpusStream`).
    private func start(opus stream: OpusStream, track: Track) {
        let item = stream.makeItem()
        item.allowedAudioSpatializationFormats = Self.spatializationFormats
        opusPlayback = (item, stream)
        player.replaceCurrentItem(with: item)
        begin(item, track: track, isRetry: false)
    }

    /// An Opus stream failed (the network, or its decoding): AAC carries on from where the song
    /// is, and says so. The only time a song changes format while it plays.
    private func playAAC(insteadOf item: AVPlayerItem, track: Track) {
        guard let opus = opusPlayback, opus.item === item, let videoId = track.videoId else { return }
        let reason = opus.stream.failure?.localizedDescription ?? item.error?.localizedDescription ?? ""
        opus.stream.cancel()
        opusPlayback = nil
        _ = noteOpusFallback(String(localized: "non riuscito (\(reason))"))
        let generation = requests.loadGeneration
        retryTask?.cancel()
        retryTask = Task {
            let stream = try? await StreamResolver.shared.stream(for: videoId, quality: .high)
            guard !Task.isCancelled, self.requests.isCurrentLoad(generation), self.player.currentItem === item else { return }
            guard let stream else { return self.fail(reason) }
            self.startupMetrics.fellBack(generation)
            self.switchItem(to: AVPlayerItem(url: stream.url),
                            label: "\(stream.label) · " + String(localized: "Opus non riuscito"), track: track)
        }
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
        // With Tempo a stream can stall for good (faster than the song, it outruns YouTube, which
        // sends it at about its own speed): the file, which plays at any speed, takes over at once,
        // as it does after a seek.
        if requestedSeek != nil || songTempo != 0 {
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
        if let opus = opusPlayback, opus.item === player.currentItem {
            // Stems or AAC take over: the stream still finishes the song's decoded file.
            let stream = opus.stream
            opusPlayback = nil
            Task { _ = try? await stream.completedFile() }
        }
        // The new item holds the song from its start.
        mixItem = nil
        itemOffset = 0
        let wasPlaying = player.timeControlStatus != .paused
        newItem.allowedAudioSpatializationFormats = Self.spatializationFormats
        newItem.audioTimePitchAlgorithm = pitchAlgorithm
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

    /// Normalization and the optional equalizer on the original song. The handover uses the
    /// player's volume, as in 1.15, so AutoMix does not add an audio-processing tap on its own.
    private func audioMix(for item: AVPlayerItem, track: Track) async -> (mix: AVAudioMix?, gain: Float, fader: HandoverFader?, segue: SegueStage?) {
        let gain = await volumeGain(for: track)
        // With AutoMix, a stage for its live transitions out of this song (idle until one is armed).
        let stage = mixesTransitions && !track.isPodcastEpisode && Preferences.liveMixEnabled ? SegueStage() : nil
        let effects = await AudioEffects.mix(for: item, gain: gain, segue: stage)
        return (effects.mix, gain, effects.fader, effects.segue)
    }

    /// Keeps what the current item now plays with. A mix into the next song made at another gain
    /// would be louder or quieter than the song where it takes over: it is made again.
    private func noteEffects(_ effects: (mix: AVAudioMix?, gain: Float, fader: HandoverFader?, segue: SegueStage?),
                             of item: AVPlayerItem, track: Track) {
        itemEffects = (item, effects.gain, effects.fader, effects.segue)
        if let autoMix, autoMix.trackID == track.id, autoMix.outgoingGain != effects.gain {
            resetAutoMix()
            prepareAutoMix()
        }
        // A live mix planned on the item's earlier audio processing (the equalizer turned on or off):
        // planned again on the new one.
        if let planned = seguePlanned, planned.trackID == track.id, planned.outgoingStage !== effects.segue {
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
            self.player.playImmediately(atRate: self.playbackRate)
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

        // Before `play()`, which starts at the player's default rate (a prepared player may already play).
        if !alreadyStarted { item.audioTimePitchAlgorithm = pitchAlgorithm }
        applyRate()
        if !alreadyStarted {
            if pendingFadeIn != nil {
                // Crossfading in: stay silent until the song really plays (see `startPendingFades`).
                PlaybackVolume.shared.setLevel(0, for: player)
            } else if !isRetry {
                fadeInTask?.cancel()
                PlaybackVolume.shared.setLevel(1, for: player)
            }
            if playWhenReady {
                startWithEffects(item, track: track)
            } else {
                applyAudioEffects(to: item, track: track)
            }
        }
        deferredPreparation = (requests.loadGeneration, track)
        guard !isRetry else { return }
        if track.isPodcastEpisode {
            beginEpisode(track)
        } else {
            scrobbler.begin(track)
            ListeningLog.shared.start(track)
            Library.shared.recordPlay(track)
            loadLyrics(for: track)
        }
        updateNowPlayingInfo()
    }

    /// An episode starts: no scrobble, history, recommendations or lyrics. It goes first in
    /// "Continua ad ascoltare", and its exact length is asked for (the lists round it to the minute,
    /// and the player would take that as the end).
    private func beginEpisode(_ track: Track) {
        scrobbler.stop()
        ListeningLog.shared.close()
        lyricsTask?.cancel()
        LyricsTranslator.shared.show([])
        lyrics = .unavailable
        if let episode = PodcastLibrary.shared.episode(track.videoId) { PodcastLibrary.shared.played(episode) }
        guard track.duration == nil, let videoId = track.videoId else { return }
        Task {
            guard let length = try? await InnerTube.shared.episodeLength(videoId) else { return }
            self.noteLength(length, of: videoId)
        }
    }

    /// An episode's exact length, once known: for the scrubber, the lock screen and its progress.
    private func noteLength(_ length: TimeInterval, of videoId: String) {
        PodcastLibrary.shared.noteLength(length, of: videoId)
        for position in queue.indices where queue[position].videoId == videoId {
            queue[position].duration = length
        }
        guard current?.videoId == videoId else { return }
        progress.duration = length
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
        // A lossless copy plays as it is: no copy of YouTube's stream takes its place.
        guard losslessPlayback?.trackID != track.id else { return }
        guard playWhenReady, !isPlayingStems, Storage.localAudio(for: track) == nil,
              let videoId = track.videoId, let asset = player.currentItem?.asset as? AVURLAsset else { return }
        // An Opus stream becomes the song's decoded file by itself.
        guard asset.url.scheme != OpusStream.scheme else { return }
        let quality = Preferences.streamingQuality
        let isStreaming = !asset.url.isFileURL
        let canConvert = !Self.isInBackground && EnergyPolicy.current.allowsAudioConversion
        guard isStreaming || (quality.usesOpus && canConvert) else { return }
        let generation = requests.loadGeneration
        upgradeTask = Task {
            guard !Task.isCancelled, self.requests.isCurrentLoad(generation), self.playWhenReady else { return }
            if isStreaming, let copy = try? await Self.prepareCopy(videoId: videoId, quality: quality),
               !Task.isCancelled, self.requests.isCurrentLoad(generation), self.playWhenReady {
                self.offerLocal(copy.url, label: copy.label, track: track)
            }
            guard !Task.isCancelled, self.requests.isCurrentLoad(generation), self.playWhenReady,
                  !Self.isInBackground,
                  quality.usesOpus, EnergyPolicy.current.allowsAudioConversion else { return }
            // Decoded Opus plays from the next listen, or from the next seek.
            if let opus = await Self.prepareOpus(videoId: videoId, quality: quality, duration: track.duration),
               !Task.isCancelled, self.requests.isCurrentLoad(generation), self.playWhenReady {
                self.offerLocal(opus.url, label: opus.label, track: track)
            }
        }
    }

    /// In the background as an iPhone counts it, where work beyond the music itself waits. A Mac
    /// keeps working with its window closed or minimised, as Apple Music does: it isn't asleep.
    static var isInBackground: Bool {
        !ProcessInfo.processInfo.isMacCatalystApp && UIApplication.shared.applicationState == .background
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
        guard recognitionAudio == nil, item === player.currentItem else { return }
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
            if opusPlayback?.item === item { return playAAC(insteadOf: item, track: track) }
            if losslessPlayback?.item === item {
                return fallBackFromLossless(item, track: track, reason: item.error?.localizedDescription ?? "")
            }
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
        guard recognitionAudio == nil else { return }
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
                // After an episode the queue simply ends: no radio of songs.
                if self.autoRadio, self.current?.isPodcastEpisode != true { await self.extendQueue() }
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
        guard recognitionAudio == nil, !finishedCurrent else { return }
        finishedCurrent = true
        if let track = current, track.isPodcastEpisode, let videoId = track.videoId {
            PodcastLibrary.shared.setFinished(true, videoId)
        }
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
            && !involvesEpisode && songTempo == 0
    }

    /// An episode playing or next: no crossfade, no AutoMix (talk isn't mixed into music).
    private var involvesEpisode: Bool {
        current?.isPodcastEpisode == true || (index + 1 < queue.count && queue[index + 1].isPodcastEpisode)
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
        // What's left of the song, in real time at the tempo it plays.
        let left = outgoingPlayer.map { max(0.5, (outgoingLength - $0.currentTime().seconds) / Double(max(0.5, $0.rate))) }
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
        // A live mix stopped halfway (a pause, a seek, a skip): the song coming in plays on plainly.
        if interrupted, let session = segueSession, session.phase == .mixing { session.releaseIncoming() }
        guard let outgoing = outgoingPlayer else { return }
        outgoing.pause()
        outgoing.replaceCurrentItem(with: nil)
        outgoingPlayer = nil
        outgoingOpus?.cancel()
        outgoingOpus = nil
        if interrupted {
            fadeInTask?.cancel()
            pendingFadeIn = nil
            PlaybackVolume.shared.setLevel(1, for: player)
        }
        isPlaying = player.timeControlStatus != .paused
    }

    /// Equal-power fade, so the overall loudness stays steady while two songs overlap.
    private static func fade(_ target: AVPlayer, in fadingIn: Bool, over duration: TimeInterval) async {
        let start = PlaybackVolume.shared.level(of: target)
        let steps = max(1, Int(duration * 25))
        for step in 1...steps {
            try? await Task.sleep(for: .milliseconds(40))
            if Task.isCancelled { return }
            let progress = Float(step) / Float(steps)
            PlaybackVolume.shared.setLevel(fadingIn ? sin(progress * .pi / 2) : start * cos(progress * .pi / 2),
                                           for: target)
        }
    }

    // MARK: AutoMix

    /// The Mix of the playlist playing, when it is on: its transitions play, whatever the setting.
    private var playlistMix: PlaylistMix? {
        guard let id = playlistContext, let mix = Library.shared.playlist(id)?.mix, mix.enabled,
              AccountService.shared.unlocks(.autoMix) else { return nil }
        return mix
    }

    /// The transitions that play: the setting, with a crossfade instead of AutoMix where AutoMix
    /// needs Premium and there is none.
    private var transitionSetting: SongTransition {
        let setting = Preferences.songTransitionSetting
        return setting == .autoMix && !AccountService.shared.unlocks(.autoMix) ? .crossfade : setting
    }

    /// AutoMix (the setting) or a playlist's Mix makes the transitions.
    /// With the tempo fader away from 0, the songs follow each other without AutoMix or crossfade:
    /// the tempo is the listener's, as in a DJ app when the fader is ridden by hand.
    private var mixesTransitions: Bool {
        (transitionSetting == .autoMix || playlistMix != nil) && songTempo == 0
    }

    /// Seconds of plain crossfade at the end of a song: the setting's with "Dissolvenza incrociata";
    /// with AutoMix, a short one while no plan is ready.
    private var plainCrossfadeSeconds: Double {
        if playlistMix != nil { return 5 }
        switch transitionSetting {
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
        // With the tempo changed AutoMix waits, but the tempo panel shows the song's BPM: each song's
        // is measured as it starts, so it's there when the panel opens.
        if songTempo != 0, playWhenReady { measureSongBPM() }
        guard mixesTransitions, karaokeMode == .off, playWhenReady, !involvesEpisode,
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
            // The song's tempo, for the tempo fader.
            if let bpm = outgoing.shownTempo, self.current?.id == track.id { self.songBPM = (track.id, bpm) }
            // At the gain the song plays with, so the mix takes over at its very level.
            let outgoingGain: Float
            if let gain = self.playingGain { outgoingGain = gain } else { outgoingGain = await self.volumeGain(for: track) }
            let incomingGain = await self.volumeGain(for: next)
            guard !Task.isCancelled, self.autoMixPair == pair else { return }
            // Two songs that follow each other on their album, played in order (an album's songs, not
            // a playlist), stay as the album has them.
            let albumOrder = self.isPlayingAlbumInOrder(from: track, to: next)
            // Their voices where they meet (this song's end, the next one's start), with the
            // karaoke's vocal model, when there is the energy and the time for it: by a minute and a
            // half before this song's end the mix must be planned and rendered. Without them AutoMix
            // plans carefully.
            var outgoingVocals: VocalActivity?
            var incomingVocals: VocalActivity?
            let remaining = (track.duration ?? outgoing.duration) - self.progress.currentTime
            let budget = min(120, remaining - 90)
            if design == nil, !albumOrder, StemSeparator.isAvailable, EnergyPolicy.current.allowsKaraoke, budget >= 10 {
                self.autoMixNote = String(localized: "Ascolto delle voci…")
                let separate: VocalDetector.Separate = { try await StemSeparator.vocals(left: $0, right: $1) }
                let incomingURL = incomingFile.url
                let voices = await Self.within(budget) { () -> (VocalActivity?, VocalActivity?) in
                    async let tail = AutoMixLibrary.shared.vocals(.tail, of: outgoingFile, analysis: outgoing, separate: separate)
                    async let head = AutoMixLibrary.shared.vocals(.head, of: incomingURL, analysis: incoming, separate: separate)
                    return await (tail, head)
                }
                outgoingVocals = voices?.0
                incomingVocals = voices?.1
                if self.karaokeMode == .off { StemSeparator.releaseEngine() }
                guard !Task.isCancelled, self.requests.isCurrentLoad(generation), self.autoMixPair == pair else { return }
            }
            // The live transition (see `SeguePolicy`): planned from the analyses, played on two players
            // in step. The rendered mix below stays the fallback when it can't run here, and keeps an
            // album in order exactly as it is (its junction rendered sample for sample).
            if design == nil, !albumOrder, self.segueRefusedPair != pair, let stage = self.segueStage(for: track) {
                let request = SegueRequest(outgoing: SegueSong(outgoing, voices: outgoingVocals),
                                           incoming: SegueSong(incoming, voices: incomingVocals),
                                           earliestExit: self.progress.currentTime + SegueSession.prepareLead + 5)
                let decision = await Task.detached(priority: .userInitiated) { SeguePolicy.decide(request) }.value
                guard !Task.isCancelled, self.requests.isCurrentLoad(generation), self.autoMixPair == pair else { return }
                let why = decision.why.isEmpty ? "" : "\n" + decision.why
                if LaunchScene.isActive {
                    print("segue: beats from the model: \(outgoing.modelBeats?.count ?? -1) and \(incoming.modelBeats?.count ?? -1)")
                    print("segue: \(decision.level.rawValue) \(decision.plan.map { "\($0.shape.rawValue) \(Self.describe($0))" } ?? "")\(why)")
                }
                if decision.level == .normal {
                    self.autoMixTask = nil
                    self.segueNormalPair = pair
                    UserDefaults.standard.set("\(track.title) → \(next.title)\nSegue: \(decision.level.rawValue)\(why)",
                                              forKey: Preferences.lastAutoMixChoice)
                    self.autoMixNote = String(localized: "Senza mix: un brano dopo l'altro")
                    return
                }
                if let segue = decision.plan {
                    self.autoMixTask = nil
                    self.seguePlanned = SeguePlanned(trackID: track.id, nextID: next.id, plan: segue, file: incomingFile.url,
                                                     label: incomingFile.label, incomingGain: incomingGain, outgoingStage: stage)
                    UserDefaults.standard.set("\(track.title) → \(next.title)\nSegue: \(Self.describe(segue))\(why)",
                                              forKey: Preferences.lastAutoMixChoice)
                    self.autoMixNote = Self.describe(segue)
                    return
                }
            }
            let plan: TransitionPlan
            // What Settings → Informazioni shows of this transition ("Ultima scelta AutoMix").
            var diagnostics = "\(track.title) → \(next.title)\n"
            let volumes = String(localized: "Volume uniforme: \(Self.decibels(outgoingGain)) → \(Self.decibels(incomingGain))")
            if let design {
                plan = MixDesigner.plan(from: outgoing, to: incoming, design: design)
                diagnostics += String(localized: "Transizione disegnata nel Mix della playlist") + "\n" + volumes
            } else {
                let context = TransitionContext(outgoingGain: outgoingGain, incomingGain: incomingGain,
                                                outgoingVocals: outgoingVocals, incomingVocals: incomingVocals,
                                                albumOrder: albumOrder)
                // Hundreds of candidates are weighed: away from the main thread.
                let choice = await Task.detached(priority: .userInitiated) {
                    TransitionPlanner.choose(from: outgoing, to: incoming, context: context)
                }.value
                guard !Task.isCancelled, self.requests.isCurrentLoad(generation), self.autoMixPair == pair else { return }
                plan = choice.plan
                diagnostics += choice.summary + "\n" + volumes
            }
            UserDefaults.standard.set(diagnostics, forKey: Preferences.lastAutoMixChoice)
            self.autoMixNote = String(localized: "Preparazione del mix…")
            let destination = AutoMixLibrary.newMixFile()
            let mix: AutoMixRenderer.Mix
            do {
                mix = try await AutoMixRenderer.render(MixSchedule(plan: plan), outgoing: outgoingFile,
                                                       incoming: incomingFile.url, outgoingGain: outgoingGain,
                                                       incomingGain: incomingGain, to: destination)
            } catch {
                guard !Task.isCancelled, self.autoMixPair == pair else { return }
                self.autoMixTask = nil
                self.noteHandover(String(localized: "mix non pronto: dissolvenza semplice"))
                self.autoMixNote = String(localized: "Mix non riuscito: dissolvenza semplice")
                return
            }
            guard !Task.isCancelled, self.requests.isCurrentLoad(generation), self.autoMixPair == pair else { return }
            self.autoMixTask = nil
            // How loud the mix is: where it takes over and hands back, against the songs as they
            // play (measured on the rendered audio), and through the overlap against the louder song
            // alone (as planned). A jump in volume would show here.
            let planned = TransitionJudge(outgoing, incoming, TransitionContext(outgoingGain: outgoingGain, incomingGain: incomingGain))
                .loudness(of: plan).map { $0.together - $0.louder }
            let entry = mix.takeOver.map(Self.decibels(change:)) ?? "—", exit = mix.handBack.map(Self.decibels(change:)) ?? "—"
            let rise = Self.decibels(change: planned.max() ?? 0), dip = Self.decibels(change: planned.min() ?? 0)
            UserDefaults.standard.set(diagnostics + "\n" + String(localized: "Livelli: entrata \(entry), uscita \(exit); durante il mix \(rise) / \(dip) sul brano più forte"),
                                      forKey: Preferences.lastAutoMixChoice)
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

    /// A gain as "-4.2 dB".
    private static func decibels(_ gain: Float) -> String {
        String(format: "%.1f dB", 20 * log10(Double(max(gain, 1e-6))))
    }

    /// A change in decibels as "+0.3 dB".
    private static func decibels(change: Double) -> String {
        String(format: "%+.1f dB", change)
    }

    /// The queue is an album played in order, and the two songs follow each other on it: not a
    /// playlist (whose Mix, or AutoMix, mixes everything), not shuffled, and most of the queue
    /// from that album.
    private func isPlayingAlbumInOrder(from track: Track, to next: Track) -> Bool {
        guard playlistContext == nil, !shuffleEnabled, let album = track.albumID, next.albumID == album else { return false }
        let fromAlbum = queue.filter { $0.albumID == album }.count
        return fromAlbum >= 2 && fromAlbum * 2 >= queue.count
    }

    /// The result of `work`, unless it takes longer than `seconds` (it is cancelled then).
    private nonisolated static func within<T: Sendable>(_ seconds: Double,
                                                        _ work: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
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
        case .gapless:
            text = String(localized: "Senza silenzio tra i brani")
        case .sequence:
            text = String(localized: "Uno dopo l'altro, con una breve pausa")
        case .album:
            text = String(localized: "Come nell'album")
        }
        if plan.inStart - incoming.soundStart > 3 {
            let start = Int(plan.inStart.rounded())
            let time = String(format: "%ld:%02ld", start / 60, start % 60)
            text += " · " + String(localized: "il prossimo parte da \(time)")
        }
        return text
    }

    /// The file a song is analysed from (and, for the next song, played from): its download, its
    /// cached file, or a fresh copy; at the Opus qualities, its Opus decoded (so the song after a
    /// mix plays Opus too).
    private func analysisFile(for track: Track, videoId: String) async -> (url: URL, label: String)? {
        // A lossless copy of the song (kept on the device, or fetched from the user's server): the
        // song after the mix then plays from it too.
        if let file = await LosslessSources.shared.file(for: track, fetch: true),
           let format = await AudioFormatProbe.probe(file), format.isLossless {
            let source: LosslessSourceKind = LosslessCacheKey.isLossless(file.lastPathComponent) ? .openSubsonic : .localFile
            return (file, LosslessSources.Choice.label(format, source: source))
        }
        if let local = Storage.localAudio(for: track) {
            return (local, "\(DownloadManager.formatLabel(for: track) ?? "AAC") · offline")
        }
        let cached = OpusPipeline.cachedFile(videoId: videoId)
        if let cached, cached.label.hasPrefix("Opus") || !Preferences.initialStreamQuality.usesOpus { return cached }
        if Preferences.initialStreamQuality.usesOpus, (track.duration ?? 0) <= Preferences.opusLengthLimit,
           EnergyPolicy.current.allowsAudioConversion,
           let stream = try? await StreamResolver.shared.stream(for: videoId, quality: Preferences.streamingQuality),
           stream.format == .opus {
            let opus = OpusStream(source: .remote(stream.url), destination: OpusPipeline.streamFile(videoId: videoId, stream: stream),
                                  duration: track.duration)
            opus.start()
            let file = await withTaskCancellationHandler {
                try? await opus.completedFile()
            } onCancel: {
                opus.cancel()
            }
            if let file { return (file, stream.label) }
        }
        if let cached { return cached }
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
        // Playing a lossless copy: that very file (a server's is fetched whole, the same bytes it streams).
        if let lossless = losslessPlayback, lossless.trackID == track.id {
            if lossless.choice.isLocal { return lossless.choice.url }
            return await LosslessSources.shared.file(for: track, fetch: true)
        }
        if let source, source.isFileURL { return source }
        // An Opus stream: its decoded file, once the whole song is in.
        if let source, source.scheme == OpusStream.scheme, let opus = opusPlayback?.stream, opus.playbackURL == source,
           let file = try? await opus.completedFile() {
            return file
        }
        if let source, let stream = await StreamResolver.shared.stream(for: videoId, at: source),
           let copy = try? await OpusPipeline.shared.localCopy(videoId: videoId, stream: stream) {
            return copy
        }
        return await analysisFile(for: track, videoId: videoId)?.url
    }

    // MARK: Live mix

    /// The stage in the playing song's audio processing, when a live mix can play out of it (AutoMix
    /// set up when the song started, not karaoke).
    private func segueStage(for track: Track) -> SegueStage? {
        guard Preferences.liveMixEnabled, current?.id == track.id, karaokeMode == .off, !isPlayingStems,
              let itemEffects, itemEffects.item === player.currentItem else { return nil }
        return itemEffects.segue
    }

    /// Prepares the next song's player well before the window; its moment missed (a seek, a slow
    /// start), the song ends with a plain crossfade instead.
    private func followSegue(_ planned: SeguePlanned, at seconds: TimeInterval) {
        let start = planned.plan.outgoingStart
        guard segueSession == nil else { return }
        if seconds >= start - SegueSession.prepareLead, seconds < start - SegueSession.runUp - 1 {
            armSegue(planned)
        } else if seconds >= start - SegueSession.runUp - 1 {
            seguePlanned = nil
            autoMixNote = String(localized: "Transizione saltata: dissolvenza semplice")
            noteHandover(String(localized: "Transizione saltata: dissolvenza semplice"))
        }
    }

    private func armSegue(_ planned: SeguePlanned) {
        guard segueSession == nil, let track = current, index + 1 < queue.count, queue[index + 1].id == planned.nextID else { return }
        let offset = itemOffset
        let session = SegueSession(plan: planned.plan, outgoingTrackID: track.id, next: queue[index + 1], file: planned.file,
                                   label: planned.label, incomingGain: planned.incomingGain, outgoingStage: planned.outgoingStage,
                                   outgoingOffset: offset)
        segueSession = session
        let outgoing = player
        SegueSession.logs = LaunchScene.isActive
        if LaunchScene.isActive { print("segue: arming \(session.summary)") }
        Task {
            guard await session.prepare(spatial: Self.spatializationFormats), self.segueSession === session, self.player === outgoing else {
                if self.segueSession === session { self.dropSegue(session, reason: "not ready") }
                return
            }
            // Started when the playing song nears its run-up.
            while self.segueSession === session, self.player === outgoing {
                guard outgoing.timeControlStatus == .playing, let time = outgoing.currentItem?.currentTime().seconds else {
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }
                let wait = (planned.plan.outgoingStart - SegueSession.runUp) - (time - offset)
                if wait <= 1 { break }
                try? await Task.sleep(for: .seconds(min(wait - 0.8, 2)))
            }
            guard self.segueSession === session, self.player === outgoing, session.start(outgoing: outgoing, offset: offset) else {
                if self.segueSession === session { self.dropSegue(session, reason: "start missed") }
                return
            }
            session.follow(outgoingTime: { [weak outgoing] in
                guard let outgoing, outgoing.timeControlStatus == .playing, let item = outgoing.currentItem else { return nil }
                return item.currentTime().seconds - offset
            }, window: { [weak self] in
                self?.beginSegue(session, outgoing: outgoing)
            }, ended: { [weak self] in
                self?.endSegueWindow(session, outgoing: outgoing)
            }, lost: { [weak self] reason in
                self?.loseSegue(session, reason: reason)
            })
        }
    }

    /// The window starts: the next song becomes the current one (its player already playing in step),
    /// the playing one runs on as `outgoingPlayer` through its lanes.
    private func beginSegue(_ session: SegueSession, outgoing: AVPlayer) {
        guard segueSession === session, player === outgoing, let item = session.item,
              index + 1 < queue.count, queue[index + 1].id == session.next.id else {
            return dropSegue(session, reason: "queue changed")
        }
        seguePlanned = nil
        finishedCurrent = true
        fadeOutTask?.cancel()
        fadeOutTask = nil
        fadeInTask?.cancel()
        pendingFadeIn = nil
        outgoingPlayer = outgoing
        outgoingLength = current?.duration ?? 0
        mixHandover = true
        player = session.player
        attach(session.player)
        index += 1
        loadCurrent(crossfading: true, reason: .automatic, adoptingLive: (item, session.label))
        itemEffects = (item, session.incomingGain, nil, session.incomingStage)
        if LaunchScene.isActive { print("segue: window \(session.summary), off by \(Int(session.lastError * 1000)) ms") }
    }

    /// The window ends: the outgoing song's player stops once its last sound is out.
    private func endSegueWindow(_ session: SegueSession, outgoing: AVPlayer) {
        if current?.id == session.next.id { streamInfo = session.label }
        noteHandover(String(localized: "mix dal vivo") + " · " + session.summary)
        if LaunchScene.isActive { print("segue: mixed \(session.summary)") }
        Task {
            try? await Task.sleep(for: .seconds(Self.outputLatency + 0.3))
            if self.outgoingPlayer === outgoing { self.endCrossfade(interrupted: false) }
        }
    }

    /// Lost while heard (the next song stalled, or drifted far off): it plays on plainly, the playing
    /// song fades out over a second.
    private func loseSegue(_ session: SegueSession, reason: String) {
        guard segueSession === session else { return }
        noteHandover(String(localized: "mix dal vivo") + " · " + reason)
        if LaunchScene.isActive { print("segue: lost (\(reason)) \(session.summary)") }
        session.releaseIncoming()
        guard let outgoing = outgoingPlayer else { return }
        fadeOutTask?.cancel()
        fadeOutTask = Task {
            await Self.fade(outgoing, in: false, over: 1)
            guard !Task.isCancelled else { return }
            self.endCrossfade(interrupted: false)
        }
    }

    /// Couldn't prepare in time: the session goes, and the pair is planned again the rendered way.
    private func dropSegue(_ session: SegueSession, reason: String) {
        session.abandon()
        if segueSession === session { segueSession = nil }
        seguePlanned = nil
        noteHandover(String(localized: "mix non pronto: dissolvenza semplice") + " (\(reason))")
        if LaunchScene.isActive { print("segue: dropped (\(reason))") }
        guard let track = current, index + 1 < queue.count else { return }
        segueRefusedPair = "\(track.id)>\(queue[index + 1].id)"
        autoMixPair = nil
        prepareAutoMix()
    }

    /// A live plan in words, for the queue.
    private static func describe(_ plan: SeguePlan) -> String {
        let before = Int((plan.outgoingStart).rounded())
        let seconds = Int(plan.length.rounded())
        switch plan.level {
        case .lockedLong, .lockedShort, .lockedBeat:
            let tempo = Int((plan.tempo ?? 0).rounded()), tempoIn = Int(((plan.tempo ?? 0) / plan.rate).rounded())
            return String(localized: "Mix a tempo: \(plan.bars ?? 0) battute, \(tempoIn) → \(tempo) BPM, a \(before) s")
        case .filtered:
            return String(localized: "Dissolvenza filtrata: \(seconds) s")
        case .hard:
            return String(localized: "Stacco sul battere, a \(before) s")
        case .simpleFade:
            return String(localized: "Dissolvenza incrociata: \(seconds) s")
        case .normal:
            return String(localized: "Senza mix: un brano dopo l'altro")
        }
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
        PlaybackVolume.shared.register(incoming)
        // AVPlayer starts at an exact moment (see `startOnTime`) only without its own waiting.
        incoming.automaticallyWaitsToMinimizeStalling = false
        // As in 1.15, the rendered mix starts fading in immediately at its scheduled start.
        let crossing = 0.0
        let fade = AutoMixPlayback.handoverFade
        let transition = ArmedTransition(planned: planned, player: incoming, track: next, outgoingTrackID: track.id,
                                         fade: fade)
        armed = transition
        armTask = Task {
            guard let made = await Self.makeMixItem(for: planned, crossing: crossing, fade: fade) else {
                self.noteHandover(String(localized: "mix non pronto: dissolvenza semplice"))
                return self.abandon(transition)
            }
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
            // Its audio ready to play at once (a preroll that didn't finish is tried once more).
            var ready = item.status == .readyToPlay && incoming.status == .readyToPlay
            if ready {
                let rate = PlaybackTempo.rate
                ready = await incoming.preroll(atRate: rate)
                if !ready, !Task.isCancelled, self.armed === transition { ready = await incoming.preroll(atRate: rate) }
            }
            guard !Task.isCancelled, self.armed === transition else { return }
            guard ready else {
                self.noteHandover(String(localized: "mix non pronto: dissolvenza semplice"))
                return self.abandon(transition)
            }
            await self.startOnTime(transition)
        }
    }

    /// The mix fades in as soon as it starts. Add processing taps only when the equalizer is on,
    /// as in 1.15; the next handover fades out using the player's volume.
    nonisolated private static func makeMixItem(for planned: PlannedTransition, crossing: Double,
                                                fade: Double) async -> (item: AVPlayerItem, fader: HandoverFader?)? {
        guard let parts = await AutoMixPlayback.compose(mixURL: planned.mix.url, songURL: planned.file,
            length: planned.mix.length, join: planned.mix.join, incomingGain: planned.incomingGain,
            crossing: crossing, fade: fade) else { return nil }
        if EqualizerParameters.shared.isOn {
            parts.mixPart.audioTapProcessor = EqualizerTap.make()
            parts.songPart.audioTapProcessor = EqualizerTap.make()
        }
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = [parts.mixPart, parts.songPart]
        let item = AVPlayerItem(asset: parts.composition)
        item.audioMix = audioMix
        // At the songs' tempo (see `PlaybackTempo`): the mix's beats stay matched, faster or slower.
        item.audioTimePitchAlgorithm = PlaybackTempo.pitchAlgorithm
        return (item, nil)
    }

    /// Output latency is included when deciding when to stop the outgoing player.
    private static var outputLatency: TimeInterval {
        let session = AVAudioSession.sharedInstance()
        return max(0, session.outputLatency) + max(0, session.ioBufferDuration)
    }

    /// Schedule the preloaded mix as in 1.15. The outgoing player stays audible until that
    /// moment and fades out with its volume; the rendered mix fades in over the same interval.
    private func startOnTime(_ transition: ArmedTransition) async {
        let handover = transition.planned.plan.handover
        let outgoing = player
        while true {
            guard !Task.isCancelled, armed === transition, player === outgoing,
                  current?.id == transition.outgoingTrackID, karaokeMode == .off else { return abandon(transition) }
            guard outgoing.timeControlStatus == .playing, let item = outgoing.currentItem else {
                try? await Task.sleep(for: .milliseconds(250))
                continue
            }
            let wait = handover + itemOffset - item.currentTime().seconds
            if wait <= 0.4 { break }
            try? await Task.sleep(for: .seconds(min(wait - 0.35, 1)))
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
        // The mix plays at the songs' tempo; its fade, in the mix's own seconds, lasts that much less (or more).
        let tempo = PlaybackTempo.rate
        transition.player.setRate(tempo, time: .zero, atHostTime: start)
        transition.scheduled = true
        let fade = transition.fade / Double(tempo)
        beginTransition(transition, outgoingFor: delay + fade + Self.outputLatency + 0.3)
        noteHandover(String(localized: "mix avviato senza controllo"))
        fadeOutTask = Task {
            while !Task.isCancelled {
                let elapsed = CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), start).seconds
                PlaybackVolume.shared.setLevel(Float(max(0, min(1, 1 - elapsed / fade))), for: outgoing)
                if elapsed >= fade { break }
                try? await Task.sleep(for: .milliseconds(elapsed < 0 ? max(1, Int(-elapsed * 1000)) : 8))
            }
        }
    }

    /// The last AutoMix handover and how it went, for Settings → Informazioni.
    private func noteHandover(_ text: String) {
        let time = Date.now.formatted(date: .omitted, time: .standard)
        UserDefaults.standard.set("\(time) · \(text)", forKey: Preferences.lastHandover)
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
        itemEffects = (item, planned.incomingGain, transition.fader, nil)
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
        seguePlanned = nil
        segueNormalPair = nil
        // A live mix not yet heard is dropped; one under way plays on.
        if let session = segueSession, [.preparing, .ready, .running].contains(session.phase) {
            session.abandon()
            segueSession = nil
        }
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
        guard autoRadio, queue.count - index <= 3, current?.isPodcastEpisode != true else { return }
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
        guard playWhenReady, !Self.isInBackground,
              EnergyPolicy.current.allowsSpeculativeWork else { return }
        prefetchLyrics()
        guard index + 1 < queue.count else { return }
        let track = queue[index + 1]
        LosslessSources.shared.prefetch(track)
        // An episode is far bigger than a song: it is only fetched when it plays.
        guard let videoId = track.videoId, !track.isPodcastEpisode else { return }
        // With AutoMix the next song's copy is made by `prepareAutoMix`, at the quality it will play.
        // An Opus song starts from its stream (its first seconds are prepared by PreparedPlayback).
        let needsCopy = Storage.localAudio(for: track) == nil && OpusPipeline.cachedFile(videoId: videoId) == nil
            && !mixesTransitions && !Preferences.initialStreamQuality.usesOpus
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
        guard prefetchedLyrics[upNext.id] == nil, !upNext.isPodcastEpisode else { return }
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
        let session = AVAudioSession.sharedInstance()
        // Recording normally restores this category itself. Reclaim it before playback too, so
        // a failed restoration or audio-services reset cannot leave music on a recording route.
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        #if canImport(NowPlaying) && !targetEnvironment(macCatalyst)
        if #available(iOS 27, *), let system = systemNowPlayingBox as? SystemNowPlaying {
            system.claim()
        }
        #endif
    }

    /// Moves the time and state observers to the player of the current song.
    private func attach(_ newPlayer: AVPlayer) {
        PlaybackVolume.shared.register(newPlayer)
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
                guard self.recognitionAudio == nil else { return }
                self.requestedSeek?.setPlaying(status == .playing, now: ProcessInfo.processInfo.systemUptime)
                // While the next song loads during a crossfade, the previous one is still audible.
                self.isPlaying = status != .paused || self.outgoingPlayer != nil
                if status == .playing {
                    self.isLoading = false
                    self.startPendingFades()
                    self.startupMetrics.playing(self.requests.loadGeneration)
                    self.noteStartupDetails(self.requests.loadGeneration)
                    self.startDeferredPreparation()
                }
                self.watchStall(status, player: newPlayer)
                self.updateNowPlayingInfo()
            }
            .store(in: &playerCancellables)
    }

    /// A song left waiting for its stream (AVPlayer predicting it can't keep up, which a song played
    /// faster than YouTube sends it never does) gets going again after a few seconds: from its local
    /// copy when there is one, else from a fresh link to its stream, where it was; once per song.
    private func watchStall(_ status: AVPlayer.TimeControlStatus, player watched: AVPlayer) {
        stallTask?.cancel()
        guard status == .waitingToPlayAtSpecifiedRate, watched.reasonForWaitingToPlay == .toMinimizeStalls,
              playWhenReady, let track = current, let item = watched.currentItem,
              let url = (item.asset as? AVURLAsset)?.url, !url.isFileURL, url.scheme != OpusStream.scheme,
              losslessPlayback?.item !== item else { return }
        stallTask = Task {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, self.player === watched, watched.currentItem === item, self.current?.id == track.id,
                  watched.timeControlStatus == .waitingToPlayAtSpecifiedRate, self.playWhenReady else { return }
            if let local = self.localFile, local.trackID == track.id {
                self.localFile = nil
                self.switchItem(to: AVPlayerItem(url: local.url), label: local.label, track: track)
                return
            }
            guard self.stallReloaded != track.id, let videoId = track.videoId else {
                // Still stuck after a reload: play what is buffered rather than wait for ever.
                watched.playImmediately(atRate: watched.defaultRate > 0 ? watched.defaultRate : 1)
                return
            }
            self.stallReloaded = track.id
            await StreamResolver.shared.invalidate(videoId)
            guard let stream = try? await StreamResolver.shared.stream(for: videoId, quality: .high),
                  self.player === watched, watched.currentItem === item, self.current?.id == track.id else { return }
            self.switchItem(to: AVPlayerItem(url: stream.url), label: stream.label, track: track)
        }
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
                guard (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                if self.progress.duration > 0, self.progress.currentTime >= self.progress.duration - 3 {
                    return self.itemFinished()
                }
                if let item = note.object as? AVPlayerItem { self.watchLosslessStall(item) }
            }
            .store(in: &cancellables)

        // A lossless stream cut off before its end: the song's usual source takes over.
        NotificationCenter.default.publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification)
            .receive(on: DispatchQueue.main)
            .sink { note in
                guard let item = note.object as? AVPlayerItem, item === self.player.currentItem,
                      self.losslessPlayback?.item === item, let track = self.current else { return }
                let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                self.fallBackFromLossless(item, track: track, reason: error?.localizedDescription ?? "")
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
                guard Self.isInBackground else { return }
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
        // The lock screen's position, moved on by the system since it was sent: sent again when it
        // strays from the song's (with the tempo changed, or after anything that moved the song).
        if let reported = reportedPosition, player.timeControlStatus == .playing {
            let shown = reported.elapsed
                + (reported.playing ? (ProcessInfo.processInfo.systemUptime - reported.at) * reported.rate : 0)
            if abs(shown - seconds) > 0.75 { updateNowPlayingInfo() }
        }
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
        if let planned = seguePlanned, planned.trackID == current?.id, canCrossfade, outgoingPlayer == nil,
           index + 1 < queue.count, queue[index + 1].id == planned.nextID {
            followSegue(planned, at: seconds)
        } else if let planned = plannedTransition(), canCrossfade {
            followPlan(planned, at: seconds)
        } else if let current, index + 1 < queue.count, segueNormalPair == "\(current.id)>\(queue[index + 1].id)" {
            // Plain playback, as the policy decided: the next song when this one ends.
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

    /// A moment after a song starts: Opus's first byte and first decoded audio, and the first
    /// audio through the item's audio processing (see `PlaybackStartupMetrics`).
    private func noteStartupDetails(_ generation: UUID) {
        let timing = opusPlayback?.stream.timing
        let fader = player.currentItem.flatMap { handoverFader(of: $0) }
        Task {
            try? await Task.sleep(for: .seconds(1))
            self.startupMetrics.details(generation, firstByte: timing?.firstByte, firstDecoded: timing?.firstAudio,
                                        firstAudio: fader?.firstProcessed)
        }
    }

    /// Saves the current song and position for the Home's "Riprendi" card.
    private func rememberPosition(_ seconds: TimeInterval) {
        guard let track = current, let videoId = track.videoId, seconds.isFinite, seconds >= 0 else { return }
        // An episode resuming hasn't jumped to its saved place yet: that place stays.
        if track.isPodcastEpisode {
            guard pendingStartTime == nil else { return }
            PodcastLibrary.shared.note(position: seconds, length: track.duration, of: videoId)
        }
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
        guard recognitionAudio == nil else {
            lastOutputs = Self.outputs(AVAudioSession.sharedInstance().currentRoute)
            return
        }
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
        guard recognitionAudio == nil else { return }
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
        // For episodes (see `updateNowPlayingInfo`): the lock screen then shows -15 / +30 instead of
        // previous / next.
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { _ in
            Task { @MainActor in self.skip(by: -15) }
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipForwardCommand.addTarget { _ in
            Task { @MainActor in self.skip(by: 30) }
            return .success
        }
        center.skipBackwardCommand.isEnabled = false
        center.skipForwardCommand.isEnabled = false
    }

    private func updateNowPlayingInfo() {
        #if canImport(NowPlaying) && !targetEnvironment(macCatalyst)
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
            reportedPosition = (progress.currentTime, ProcessInfo.processInfo.systemUptime, model.isPlaying, 1)
            return
        }
        #endif
        let center = MPNowPlayingInfoCenter.default()
        guard let track = current else {
            center.nowPlayingInfo = nil
            return
        }
        let commands = MPRemoteCommandCenter.shared()
        if commands.skipForwardCommand.isEnabled != track.isPodcastEpisode {
            commands.skipForwardCommand.isEnabled = track.isPodcastEpisode
            commands.skipBackwardCommand.isEnabled = track.isPodcastEpisode
        }
        let rate = Double(playbackRate)
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyPlaybackDuration: progress.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: progress.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: player.timeControlStatus == .playing ? rate : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: rate,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let album = track.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if let nowPlayingArtwork { info[MPMediaItemPropertyArtwork] = nowPlayingArtwork }
        center.nowPlayingInfo = info
        reportedPosition = (progress.currentTime, ProcessInfo.processInfo.systemUptime,
                            player.timeControlStatus == .playing, rate)
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

/// A live mix planned for the playing song (see `SegueSession`).
private struct SeguePlanned {
    let trackID: String
    let nextID: String
    let plan: SeguePlan
    /// The next song's file, analysed and played from.
    let file: URL
    let label: String
    let incomingGain: Float
    /// The stage in the playing song's audio processing.
    let outgoingStage: SegueStage
}

/// The mix's player, loaded and waiting for its moment.
private final class ArmedTransition {
    let planned: PlannedTransition
    let player: AVPlayer
    let track: Track
    let outgoingTrackID: String
    /// How long the two players cross at the start of the mix.
    let fade: Double
    var item: AVPlayerItem?
    /// The item's fader, when one is in use.
    var fader: HandoverFader?
    /// Its start has been set on the system clock.
    var scheduled = false

    init(planned: PlannedTransition, player: AVPlayer, track: Track, outgoingTrackID: String, fade: Double) {
        self.planned = planned
        self.player = player
        self.track = track
        self.outgoingTrackID = outgoingTrackID
        self.fade = fade
    }
}
