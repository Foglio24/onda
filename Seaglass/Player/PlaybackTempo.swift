import AVFoundation

/// The songs' tempo, as a DJ app's tempo fader (djay Pro's, say): faster or slower by up to 15 % (or
/// 8, 25 or 50 %), with the key lock on (the voice keeps its pitch: the audio is time-stretched) or
/// off (as on a turntable: faster is higher, slower is lower). It stays until it's set back to 0.
/// Podcasts keep their own speed. AutoMix's mixes play at the same tempo as the songs, so their beats
/// stay matched.
enum PlaybackTempo {
    /// The fader's ranges, either way.
    static let ranges: [Double] = [0.08, 0.15, 0.25, 0.5]

    /// How far the fader goes either way.
    static var limit: Double {
        let stored = UserDefaults.standard.double(forKey: Preferences.tempoRange)
        return ranges.contains(stored) ? stored : 0.15
    }

    static var range: ClosedRange<Double> { -limit...limit }

    /// The tempo set (0: the song's own), within the range.
    static var tempo: Double {
        let value = UserDefaults.standard.double(forKey: Preferences.songTempo)
        return value.isFinite ? min(limit, max(-limit, value)) : 0
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

    /// A tempo to the nearest 0.1 %, kept in the range [limit], with values close to 0 back on 0 (the
    /// fader's detent).
    static func snapped(_ value: Double, limit: Double = PlaybackTempo.limit) -> Double {
        let clamped = min(limit, max(-limit, value))
        let rounded = (clamped * 1000).rounded() / 1000
        return abs(rounded) < 0.003 ? 0 : rounded
    }
}
