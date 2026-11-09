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
        weak var player: AVPlayer?
        var level: Float
    }
    private var outputs: [ObjectIdentifier: Output] = [:]

    init(defaults: UserDefaults = .standard,
         controlsVolume: Bool = ProcessInfo.processInfo.isMacCatalystApp) {
        self.defaults = defaults
        self.controlsVolume = controlsVolume
        value = Self.clamp(defaults.object(forKey: Self.key) as? Double ?? 1)
    }

    func set(_ volume: Double) {
        value = Self.clamp(volume)
        defaults.set(value, forKey: Self.key)
        outputs = outputs.filter { $0.value.player != nil }
        for output in outputs.values {
            output.player?.volume = output.level * gain
        }
    }

    /// Call before a player can produce sound, including the player armed for AutoMix.
    func register(_ player: AVPlayer) {
        outputs = outputs.filter { $0.value.player != nil }
        let id = ObjectIdentifier(player)
        if outputs[id]?.player !== player { outputs[id] = Output(player: player, level: 1) }
        player.volume = (outputs[id]?.level ?? 1) * gain
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
