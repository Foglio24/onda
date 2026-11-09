import AVFoundation
import Foundation

@main
struct PlaybackVolumeCheck {
    @MainActor static func main() {
        let name = "Seaglass.PlaybackVolumeCheck.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else { fatalError("No test defaults") }
        defer { defaults.removePersistentDomain(forName: name) }
        let volume = PlaybackVolume(defaults: defaults, controlsVolume: true)
        let current = AVPlayer(), outgoing = AVPlayer(), armed = AVPlayer()
        volume.register(current)
        volume.setLevel(0.6, for: current)
        volume.setLevel(0.8, for: outgoing)
        volume.register(armed)
        volume.set(0.25)
        check(current.volume, 0.15)
        check(outgoing.volume, 0.2)
        check(armed.volume, 0.25)

        // A fade continues while muted. Unmuting uses its latest position, never stale volume
        // divided by zero, and an adopted player retains its fade when registered again.
        volume.set(0)
        volume.setLevel(0.3, for: outgoing)
        volume.setLevel(0.9, for: current)
        check(outgoing.volume, 0)
        volume.set(0.5)
        volume.register(current)
        check(current.volume, 0.45)
        check(outgoing.volume, 0.15)
        check(armed.volume, 0.5)
        precondition(PlaybackVolume(defaults: defaults, controlsVolume: true).value == 0.5)

        // iOS retains system volume, with only the existing fade affecting AVPlayer.volume.
        let phone = PlaybackVolume(defaults: defaults, controlsVolume: false)
        let phonePlayer = AVPlayer()
        phone.register(phonePlayer)
        phone.setLevel(0.4, for: phonePlayer)
        check(phonePlayer.volume, 0.4)
        volume.set(-2)
        check(current.volume, 0)
        volume.set(2)
        check(current.volume, 0.9)
        volume.set(.nan)
        check(current.volume, 0.9)
        print("PlaybackVolumeCheck passed: gain, live fades, mute, adoption, persistence and iOS volume")
    }

    private static func check(_ value: Float, _ expected: Float) {
        precondition(abs(value - expected) < 0.0001, "Volume \(value), expected \(expected)")
    }
}
