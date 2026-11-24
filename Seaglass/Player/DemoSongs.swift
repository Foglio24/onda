import AVFoundation
import Foundation

/// Songs the app makes itself, to a click: a kick on every beat (stronger on the bar's first), a hi-hat
/// between beats and a chord on every bar, with a second of silence at each end. They are the app's
/// own, made on the device: no network, no account, no one else's music. CI's AutoMix scenes play them
/// (see `LaunchScene`), and the Home's AutoMix demo lets people hear a transition with two of them
/// (see `AutoMixDemo`).
enum DemoSongs {
    /// One channel of a song: `seconds` long at `sampleRate`, quieter (0.35) for its first `introBars`
    /// bars, at `level`; `drums` false leaves one chord held throughout (a song without a beat). The same samples
    /// every time for the same arguments.
    static func samples(bpm: Double, root: Int, introBars: Int, seconds: Double, sampleRate rate: Double,
                        level: Double = 0.8, drums: Bool = true) -> [Float] {
        let frames = Int(seconds * rate)
        var out = [Float](repeating: 0, count: frames)
        let beat = 60 / bpm
        var noise: UInt32 = 7
        for frame in 0..<frames {
            let time = Double(frame) / rate - 1
            var value = 0.0
            if time >= 0, time < seconds - 2 {
                let beatIndex = Int(time / beat)
                let sinceBeat = time - Double(beatIndex) * beat
                let accent: Double = beatIndex % 4 == 0 ? 1.3 : 1
                let sweep: Double = 50 + 80 * exp(-sinceBeat * 40)
                if drums { value += 0.7 * sin(2 * Double.pi * sweep * sinceBeat) * exp(-sinceBeat * 16) * accent }
                let sinceHat = sinceBeat - beat / 2
                if drums, sinceHat >= 0 {
                    noise = noise &* 1_664_525 &+ 1_013_904_223
                    value += 0.12 * (Double(noise >> 8) / Double(1 << 24) * 2 - 1) * exp(-sinceHat * 60)
                }
                let bar = beatIndex / 4
                // Without drums, one chord held throughout (no change of chord to hear as a beat either).
                let chord = drums ? [root, root + 5, root + 7, root][bar % 4] : root
                let sinceBar = drums ? time - Double(bar) * 4 * beat : time
                for interval in [0, 4, 7] {
                    let pitch = 440 * pow(2, Double(chord + interval - 69) / 12)
                    value += 0.06 * sin(2 * Double.pi * pitch * sinceBar)
                }
                if bar < introBars { value *= 0.35 }
            }
            out[frame] = Float(value * level)
        }
        return out
    }

    /// How loud a song's body is (after its intro): root mean square and peak, both linear.
    struct Level: Codable, Equatable, Sendable {
        var rms: Double
        var peak: Double
    }

    static func level(of samples: [Float], from start: Int) -> Level {
        var sum = 0.0, peak = 0.0
        let body = samples[min(max(0, start), samples.count)...]
        for value in body {
            let v = Double(value)
            sum += v * v
            peak = max(peak, abs(v))
        }
        return Level(rms: body.isEmpty ? 0 : (sum / Double(body.count)).squareRoot(), peak: peak)
    }

    /// Writes a song to `url` (see `samples`), in both channels, as AAC (`alac`: ALAC, 16 bit, as the
    /// "Massima" downloads are kept). Returns its body's level.
    @discardableResult
    static func write(to url: URL, bpm: Double, root: Int, introBars: Int, seconds: Double = 72, alac: Bool = false,
                      level: Double = 0.8, drums: Bool = true) throws -> Level {
        let rate = 44_100.0
        let mono = samples(bpm: bpm, root: root, introBars: introBars, seconds: seconds, sampleRate: rate, level: level, drums: drums)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(mono.count)),
              let channels = buffer.floatChannelData else { throw CocoaError(.fileWriteUnknown) }
        buffer.frameLength = AVAudioFrameCount(mono.count)
        mono.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channels[0].update(from: base, count: mono.count)
            channels[1].update(from: base, count: mono.count)
        }
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = alac
            ? [AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2, AVEncoderBitDepthHintKey: 16]
            : [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000]
        // Closed (and so finished) before returning: the file is read right after.
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            try file.write(from: buffer)
        }
        let bar = 4 * 60 / bpm
        return Self.level(of: mono, from: Int((1 + Double(introBars) * bar) * rate))
    }
}

// MARK: The AutoMix demo's pair

extension DemoSongs {
    struct Spec: Sendable, Equatable {
        let id: String
        let title: String
        let bpm: Double
        let root: Int
        let introBars: Int
        let seconds: Double
    }

    /// The Home's AutoMix demo (see `AutoMixDemo`): the pair CI's AutoMix scene mixes beat on beat
    /// (`LaunchScene`'s "segue"), 124 and 126 BPM, around A minor and C major, the second with a
    /// quieter four-bar intro. Their names change with how they are made, so an older analysis is
    /// never read for newer songs.
    static let autoMixPair = [
        Spec(id: "SeaglassDemoNeonDrive1", title: "Neon Drive", bpm: 124, root: 57, introBars: 0, seconds: 120),
        Spec(id: "SeaglassDemoNightRun1", title: "Night Run", bpm: 126, root: 60, introBars: 4, seconds: 120),
    ]

    /// The first mix may not start before this second of the first song: there is no song playing
    /// to wait for, only enough of it to hear before the passage.
    static let autoMixEarliestExit = 30.0

    /// The demo's transition as AutoMix plans it with its defaults (the app adds the listener's
    /// settings, see `AutoMixDemo.request`).
    static func autoMixRequest(_ outgoing: TrackAnalysis, _ incoming: TrackAnalysis) -> SegueRequest {
        SegueRequest(outgoing: SegueSong(outgoing, voices: nil), incoming: SegueSong(incoming, voices: nil),
                     earliestExit: autoMixEarliestExit)
    }

    /// Gains that bring songs' bodies to the same loudness: the loudest all can reach without
    /// clipping (peaks at 0.9), and no louder than `target` (root mean square, about -15 dBFS).
    static func matchedGains(_ levels: [Level], target: Double = 0.18) -> [Float] {
        let reachable = levels.filter { $0.rms > 0 && $0.peak > 0 }.map { $0.rms * 0.9 / $0.peak }
        let common = min(target, reachable.min() ?? target)
        return levels.map { $0.rms > 0 ? Float(common / $0.rms) : 1 }
    }
}
