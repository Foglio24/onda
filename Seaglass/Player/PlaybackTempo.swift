import AVFoundation

/// The songs' tempo, as a DJ app's tempo fader (djay Pro's, say): up to 15 % faster or slower, with
/// the key lock on (the voice keeps its pitch: the audio is time-stretched) or off (as on a turntable:
/// faster is higher, slower is lower). It stays until it's set back to 0. Podcasts keep their own
/// speed. AutoMix's mixes play at the same tempo as the songs, so their beats stay matched.
enum PlaybackTempo {
    static let range: ClosedRange<Double> = -0.15...0.15

    /// -0.15…+0.15 (0: the song's own tempo).
    static var tempo: Double {
        let value = UserDefaults.standard.double(forKey: Preferences.songTempo)
        return value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : 0
    }

    static var keyLock: Bool {
        UserDefaults.standard.object(forKey: Preferences.keyLock) as? Bool ?? true
    }

    /// The rate songs play at.
    static var rate: Float { Float(1 + tempo) }

    /// How the player changes the tempo: keeping the pitch (spectral, the best for music) or not.
    static var pitchAlgorithm: AVAudioTimePitchAlgorithm {
        keyLock ? .spectral : .varispeed
    }

    /// A tempo to the nearest 0.1 %, kept in the range, with values close to 0 back on 0.
    static func snapped(_ value: Double) -> Double {
        let clamped = min(range.upperBound, max(range.lowerBound, value))
        let rounded = (clamped * 1000).rounded() / 1000
        return abs(rounded) < 0.004 ? 0 : rounded
    }
}
