import AVFoundation
import Foundation

@main
struct PlaybackVolumeCheck {
    @MainActor static func main() throws {
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

        // The Mix editor's AVAudioPlayer receives the saved gain before play(), then follows
        // changes along with the streaming players. A local silent CAF needs no output hardware.
        let file = FileManager.default.temporaryDirectory.appending(path: "Seaglass-volume-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: file) }
        try writeSilence(to: file)
        let preview = try AVAudioPlayer(contentsOf: file)
        volume.register(preview)
        check(preview.volume, 0.25)

        // A fade continues while muted. Unmuting uses its latest position, never stale volume
        // divided by zero, and an adopted player retains its fade when registered again.
        volume.set(0)
        check(preview.volume, 0)
        volume.setLevel(0.3, for: outgoing)
        volume.setLevel(0.9, for: current)
        check(outgoing.volume, 0)
        volume.set(0.5)
        volume.register(current)
        check(current.volume, 0.45)
        check(outgoing.volume, 0.15)
        check(armed.volume, 0.5)
        check(preview.volume, 0.5)
        precondition(PlaybackVolume(defaults: defaults, controlsVolume: true).value == 0.5)

        // A slider's drag: the players follow at once, the value is kept once it stops.
        volume.set(0.7, dragging: true)
        check(armed.volume, 0.7)
        precondition(PlaybackVolume(defaults: defaults, controlsVolume: true).value == 0.5)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        precondition(PlaybackVolume(defaults: defaults, controlsVolume: true).value == 0.7)
        volume.set(0.5)

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
        print("PlaybackVolumeCheck passed: gain, live fades, mute, adoption, preview, persistence and iOS volume")
    }

    private static func writeSilence(to url: URL) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024),
              let samples = buffer.floatChannelData?[0] else { fatalError("No fixture audio buffer") }
        buffer.frameLength = 1024
        samples.update(repeating: 0, count: 1024)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private static func check(_ value: Float, _ expected: Float) {
        precondition(abs(value - expected) < 0.0001, "Volume \(value), expected \(expected)")
    }
}
