import AVFoundation
import Foundation

/// Where a song is sung near its start and its end, for AutoMix's choice of transition (see
/// `VocalActivity` and `TransitionPlanner.choose`). The karaoke's vocal model (UVR MDX-Net Voc_FT,
/// trained to take the singing voice out of music, not speech) separates those stretches, and a
/// voice counts as present where the separated vocals carry a clear share of the sound. Only the
/// stretches AutoMix mixes over are measured, once per song (the whole song would keep the Neural
/// Engine busy for minutes); the rest stays unknown, which AutoMix treats with care.
enum VocalDetector {
    enum Part: String, Sendable {
        case head, tail
    }

    /// How much of a song's start and of its end is measured.
    static let headLength = 45.0
    static let tailLength = 60.0
    /// The vocals' share of the sound (dB) up to which no voice is taken to sing, and from which
    /// one surely does; in between, a chance from 0 to 1. Starting points, checked against the word
    /// timings of the JamendoLyrics songs by Tools/VocalCheck; the model lets a little of the
    /// instruments through, which stays under the lower one.
    static let absentShare: Float = -15
    static let presentShare: Float = -7
    /// Pauses between words shorter than this count as the same phrase; voice shorter than this
    /// doesn't count.
    static let phraseGap = 0.75
    static let shortestVoice = 0.5
    /// The sample rate the model works at.
    static let sampleRate = Double(MDXSeparator.sampleRate)

    /// A function that separates the vocals of a stereo piece of at most `MDXSeparator.maxPieceLength`
    /// frames (in the app, `StemSeparator.vocals`).
    typealias Separate = @Sendable (ArraySlice<Float>, ArraySlice<Float>) async throws -> (left: [Float], right: [Float])

    /// The stretch of a song measured for a part: from its sound's start, or up to its sound's end.
    static func range(_ part: Part, of analysis: TrackAnalysis) -> (start: Double, end: Double) {
        switch part {
        case .head:
            return (analysis.soundStart, min(analysis.soundEnd, analysis.soundStart + headLength))
        case .tail:
            return (max(analysis.soundStart, analysis.audibleEnd - tailLength), analysis.soundEnd)
        }
    }

    /// Measures a part of a song's file.
    static func measure(_ part: Part, of file: URL, analysis: TrackAnalysis,
                        separate: Separate) async throws -> VocalActivity.Region {
        let stretch = range(part, of: analysis)
        let audio = try await AutoMixRenderer.decode(file, from: stretch.start, duration: stretch.end - stretch.start)
        guard let channels = audio.floatChannelData else { throw AutoMixRenderer.RenderError.noAudio }
        let count = Int(audio.frameLength)
        let left = Array(UnsafeBufferPointer(start: channels[0], count: count))
        let right = audio.format.channelCount > 1 ? Array(UnsafeBufferPointer(start: channels[1], count: count)) : left
        let measured = try await shares(left: left, right: right, separate: separate)
        return region(start: stretch.start, shares: measured)
    }

    /// The vocals' share of the sound (dB) every `VocalActivity.step` seconds of a stretch of stereo
    /// audio at the model's rate (-60 where there is next to no sound).
    static func shares(left: [Float], right: [Float], separate: Separate) async throws -> [Float] {
        let frame = Int(VocalActivity.step * sampleRate)
        let piece = MDXSeparator.maxPieceLength / frame * frame
        var vocalPower: [Double] = []
        var soundPower: [Double] = []
        var start = 0
        while start < left.count {
            try Task.checkCancellation()
            let end = min(left.count, start + piece)
            let vocals = try await separate(left[start..<end], right[start..<end])
            var position = 0
            while position + frame <= end - start {
                var vocal = 0.0, sound = 0.0
                for index in position..<(position + frame) {
                    let l = Double(vocals.left[index]), r = Double(vocals.right[index])
                    let ml = Double(left[start + index]), mr = Double(right[start + index])
                    vocal += l * l + r * r
                    sound += ml * ml + mr * mr
                }
                vocalPower.append(vocal / Double(2 * frame))
                soundPower.append(sound / Double(2 * frame))
                position += frame
            }
            start = end
        }
        // Next to no sound: 35 dB under the stretch's loud parts.
        let sorted = soundPower.sorted()
        let loud = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]
        return zip(vocalPower, soundPower).map { vocal, sound in
            guard sound > 0, sound >= loud * pow(10, -3.5) else { return -60 }
            return Float(max(-60, 10 * log10(max(vocal, 1e-12) / sound)))
        }
    }

    /// The chance a voice sings in each step, from the vocals' shares: pauses within a phrase are
    /// filled, blips left out. (Other thresholds than the app's are for the checks.)
    static func region(start: Double, shares: [Float], absent: Float = absentShare,
                       present: Float = presentShare) -> VocalActivity.Region {
        var chances = shares.map { share -> Double in
            let x = Double(max(0, min(1, (share - absent) / (present - absent))))
            return x * x * (3 - 2 * x)
        }
        let gap = Int((phraseGap / VocalActivity.step).rounded())
        let shortest = Int((shortestVoice / VocalActivity.step).rounded())
        var index = 0
        while index < chances.count {
            let sung = chances[index] >= 0.5
            var end = index
            while end < chances.count, (chances[end] >= 0.5) == sung { end += 1 }
            if sung, end - index < shortest {
                for step in index..<end { chances[step] = min(chances[step], 0.45) }
            } else if !sung, index > 0, end < chances.count, end - index < gap {
                for step in index..<end { chances[step] = max(chances[step], 0.5) }
            }
            index = end
        }
        return VocalActivity.Region(start: start, values: chances.map { UInt8((max(0, min(1, $0)) * 255).rounded()) })
    }
}
