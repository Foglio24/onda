import AVFoundation
import Combine
import Network
import UIKit

/// One paused, primed native player. Playback adopts this exact player so the
/// prepared media pipeline survives the tap; it never waits for preroll to finish.
@MainActor
final class PreparedPlayback {
    static let shared = PreparedPlayback()

    struct Result {
        let player: AVPlayer
        let label: String
        let wasPrerolled: Bool
    }

    private struct Slot {
        let id: UUID
        let videoID: String
        let quality: AudioQuality
        var player: AVPlayer?
        var label = ""
        var startedPreroll = false
        var wasPrerolled = false
        let created = ProcessInfo.processInfo.systemUptime
    }

    private var candidates = PreparedPlaybackCandidates()
    private var visible: [UUID: Track] = [:]
    private var upcoming: Track?
    private var slot: Slot?
    private var selectionTask: Task<Void, Never>?
    private var resolveTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var statusObservation: NSKeyValueObservation?
    private var observers = Set<AnyCancellable>()
    private var cooldown: [String: TimeInterval] = [:]
    private let network = NWPathMonitor()
    private var unmeteredWiFi = false
    private var quality = Preferences.initialStreamQuality

    private init() {
        network.pathUpdateHandler = { [weak self] path in
            let permitted = path.status == .satisfied && path.usesInterfaceType(.wifi)
                && !path.isExpensive && !path.isConstrained
            Task { @MainActor in
                self?.unmeteredWiFi = permitted
                self?.refreshBudget()
            }
        }
        network.start(queue: DispatchQueue(label: "onda.prepared-playback.network", qos: .utility))
        _ = EnergyPolicy.current
        NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .merge(with: NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange))
            .merge(with: NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification))
            .merge(with: NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshBudget() }
            .store(in: &observers)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.quality != Preferences.initialStreamQuality else { return }
                self.quality = Preferences.initialStreamQuality
                self.clearSlot()
                self.scheduleSelection()
            }
            .store(in: &observers)
    }

    func offerVisible(_ track: Track, token: UUID, priority: Int = 0) {
        guard let videoID = track.videoId else { return }
        visible[token] = track
        candidates.offerVisible(videoID, token: token, priority: priority)
        visible = visible.filter { candidates.visibleTokens.contains($0.key) }
        scheduleSelection()
    }

    func releaseVisible(_ token: UUID) {
        visible[token] = nil
        candidates.releaseVisible(token)
        scheduleSelection()
    }

    func offerUpcoming(_ track: Track?) {
        upcoming = track
        candidates.offerUpcoming(track?.videoId)
        scheduleSelection()
    }

    /// Cancel unrelated work as soon as a user requests playback. A matching
    /// in-flight slot may still be consumed without waiting for its preroll.
    func suspendForStartup(keeping videoID: String?) {
        selectionTask?.cancel()
        candidates.suspend(keeping: videoID)
        upcoming = nil
        if let slot, !candidates.shouldKeep(slot.videoID) { clearSlot() }
    }

    func resumeAfterStartup() {
        candidates.resume()
        scheduleSelection()
    }

    func take(for videoID: String, quality: AudioQuality) -> Result? {
        guard let slot, slot.videoID == videoID, slot.quality == quality,
              ProcessInfo.processInfo.systemUptime - slot.created < 120,
              let player = slot.player, player.currentItem != nil,
              player.status != .failed, player.currentItem?.status != .failed else { return nil }
        let result = Result(player: player, label: slot.label, wasPrerolled: slot.wasPrerolled)
        clearSlot(destroyPlayer: false)
        player.cancelPendingPrerolls()
        return result
    }

    func invalidate(_ videoID: String) {
        if slot?.videoID == videoID { clearSlot() }
    }

    func refreshBudget() {
        guard allowsPreparation else {
            selectionTask?.cancel()
            clearSlot()
            return
        }
        scheduleSelection()
    }

    private var allowsPreparation: Bool {
        unmeteredWiFi && EnergyPolicy.current.allowsSpeculativeWork
            && UIApplication.shared.applicationState != .background
    }

    private func scheduleSelection() {
        selectionTask?.cancel()
        guard allowsPreparation else { clearSlot(); return }
        if let slot, candidates.shouldKeep(slot.videoID), slot.quality == Preferences.initialStreamQuality {
            return
        }
        // Scrolling can offer many rows in the same frame: start only its final candidate.
        selectionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            self.selectCandidate()
        }
    }

    private func selectCandidate() {
        guard allowsPreparation else { clearSlot(); return }
        guard let videoID = candidates.preferredVideoID else { return }
        if let slot, slot.videoID == videoID, slot.quality == Preferences.initialStreamQuality { return }
        clearSlot()
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= (cooldown[videoID] ?? 0) else { return }
        let selected = upcoming?.videoId == videoID ? upcoming : visible.values.first { $0.videoId == videoID }
        guard let track = selected else { return }
        let id = UUID()
        let quality = Preferences.initialStreamQuality
        slot = Slot(id: id, videoID: videoID, quality: quality)
        cooldown = cooldown.filter { $0.value > now }
        cooldown[videoID] = now + 30
        deadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, self?.slot?.id == id else { return }
            self?.clearSlot()
        }
        resolveTask = Task { [weak self] in
            do {
                let url: URL
                let label: String
                if let local = Storage.localAudio(for: track) {
                    url = local
                    label = "\(DownloadManager.formatLabel(for: track) ?? "AAC") · offline"
                } else if let cached = OpusPipeline.cachedFile(videoId: videoID) {
                    url = cached.url
                    label = cached.label
                } else {
                    let stream = try await StreamResolver.shared.stream(for: videoID, quality: quality)
                    guard stream.format == .aac else { throw PlayerError.unavailable }
                    url = stream.url
                    label = stream.label
                }
                guard !Task.isCancelled, let self, self.slot?.id == id, self.allowsPreparation,
                      self.candidates.shouldKeep(videoID), Preferences.initialStreamQuality == quality else { return }
                let item = AVPlayerItem(url: url)
                // This is AVFoundation's preference, not a hard byte/download cap.
                item.preferredForwardBufferDuration = 2
                item.allowedAudioSpatializationFormats = Preferences.spatialAudioEnabled ? .monoStereoAndMultichannel : []
                let player = AVPlayer(playerItem: item)
                self.slot?.player = player
                self.slot?.label = label
                self.statusObservation = player.observe(\.status, options: [.initial, .new]) { [weak self, weak player] _, _ in
                    Task { @MainActor in
                        guard let self, let player, self.slot?.id == id else { return }
                        self.prepare(player, id: id)
                    }
                }
            } catch {
                guard let self, self.slot?.id == id else { return }
                self.clearSlot()
            }
        }
    }

    private func prepare(_ player: AVPlayer, id: UUID) {
        guard slot?.id == id, allowsPreparation else { return }
        guard player.status != .failed else { clearSlot(); return }
        // Calling preroll before player readiness raises an AVFoundation exception.
        guard player.status == .readyToPlay, player.rate == 0, slot?.startedPreroll == false else { return }
        slot?.startedPreroll = true
        player.preroll(atRate: 1) { [weak self] finished in
            Task { @MainActor in
                guard let self, self.slot?.id == id else { return }
                guard finished else { self.clearSlot(); return }
                self.slot?.wasPrerolled = true
                self.deadlineTask?.cancel()
                self.expiryTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(120))
                    guard !Task.isCancelled, self?.slot?.id == id else { return }
                    self?.clearSlot()
                }
            }
        }
    }

    private func clearSlot(destroyPlayer: Bool = true) {
        let previous = slot
        slot = nil
        statusObservation = nil
        resolveTask?.cancel()
        resolveTask = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        expiryTask?.cancel()
        expiryTask = nil
        if destroyPlayer {
            previous?.player?.cancelPendingPrerolls()
            previous?.player?.pause()
            previous?.player?.replaceCurrentItem(with: nil)
        }
    }
}
