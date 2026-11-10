import AVFoundation
import Combine
import Foundation

/// The Mac's own volume. Each player keeps its fade level separately so changing the app's
/// volume during a handover, including muting it, never resets or flattens the fades.
@MainActor
final class PlaybackVolume: ObservableObject {
    static let shared = PlaybackVolume()
    static let key = "audio.macVolume"

    @Published private(set) var value: Double
    private let defaults: UserDefaults
    private let controlsVolume: Bool
    private struct Output {
        weak var player: AVPlayer? = nil
        weak var preview: AVAudioPlayer? = nil
        var level: Float

        var isAlive: Bool { player != nil || preview != nil }

        func apply(gain: Float) {
            player?.volume = level * gain
            preview?.volume = level * gain
        }
    }
    private var outputs: [ObjectIdentifier: Output] = [:]

    init(defaults: UserDefaults = .standard,
         controlsVolume: Bool = ProcessInfo.processInfo.isMacCatalystApp) {
        self.defaults = defaults
        self.controlsVolume = controlsVolume
        value = Self.clamp(defaults.object(forKey: Self.key) as? Double ?? 1)
    }

    /// `dragging`: a slider's value while it moves, kept once it stops. A slider sends a value for
    /// every step of a drag, and each write to UserDefaults wakes everything that watches them (the
    /// account's preferences, the prepared song), which made the drag stutter.
    func set(_ volume: Double, dragging: Bool = false) {
        value = Self.clamp(volume)
        outputs = outputs.filter { $0.value.isAlive }
        for output in outputs.values {
            output.apply(gain: gain)
        }
        pendingSave?.cancel()
        guard dragging else {
            defaults.set(value, forKey: Self.key)
            return
        }
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            self.defaults.set(self.value, forKey: Self.key)
        }
    }

    private var pendingSave: Task<Void, Never>?

    /// Call before a player can produce sound, including the player armed for AutoMix.
    func register(_ player: AVPlayer) {
        outputs = outputs.filter { $0.value.isAlive }
        let id = ObjectIdentifier(player)
        if outputs[id]?.player !== player { outputs[id] = Output(player: player, level: 1) }
        player.volume = (outputs[id]?.level ?? 1) * gain
    }

    /// Playlist Mix previews use AVAudioPlayer, but share the same live app volume.
    func register(_ preview: AVAudioPlayer) {
        outputs = outputs.filter { $0.value.isAlive }
        let id = ObjectIdentifier(preview)
        outputs[id] = Output(preview: preview, level: 1)
        preview.volume = gain
    }

    func level(of player: AVPlayer) -> Float { outputs[ObjectIdentifier(player)]?.level ?? 1 }

    func setLevel(_ level: Float, for player: AVPlayer) {
        let level = Float(Self.clamp(Double(level)))
        outputs[ObjectIdentifier(player)] = Output(player: player, level: level)
        player.volume = level * gain
    }

    private var gain: Float { controlsVolume ? Float(value) : 1 }

    private static func clamp(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 1
    }
}
