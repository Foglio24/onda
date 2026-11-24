import AVFoundation
import Foundation

/// A short listen to the passage from one song into the next, made ahead into one file: a few
/// seconds of the first song, the passage, a few seconds of the second. The Home's AutoMix demo plays
/// two of the same pair (one after the other, and AutoMix's mix) and a playlist's "Ordina per il mix"
/// plays the passages of the order it suggests.
struct TransitionClip: Equatable, Sendable {
    var url: URL
    /// Seconds of audio in the file.
    var length: Double
    /// Where the passage starts and ends in the file: with AutoMix, the mix's window; one song after
    /// the other, from the first song's last sound to the second's first.
    var passageStart: Double
    var passageEnd: Double
}

/// Makes `TransitionClip`s with AutoMix's own engine: the mix is the one `SegueRender` plays in the
/// app (the same plan, the same samples), preceded by the first song's own samples up to where the
/// app's player hands over to it and followed by the second song's own samples from where it hands
/// back, so the clip is what the player plays, in one piece, with nothing joined that could jump.
/// Both kinds hold each song at the gain it is given, the same in both: the two listens of a pair are
/// as loud as each other, and only the passage differs.
enum TransitionClipMaker {
    /// Seconds of the first song before the passage, and of the second after it.
    static let before = 10.0
    static let after = 12.0
    /// The clip starts and ends inside songs: it comes in and goes out over these.
    static let fadeIn = 0.8
    static let fadeOut = 1.5
    /// Quieter than this (linear, -60 dB) is silence: where a song's sound starts and ends.
    static let silence: Float = 0.001

    enum Failure: Error {
        case unreadable
        case range
    }

    /// A clip's audio before it is written: stereo, at `sampleRate`.
    struct Mixed {
        var left: [Float]
        var right: [Float]
        var sampleRate: Double
        var passageStart: Double
        var passageEnd: Double
        /// The frames where one piece follows another (the checks look there for a jump).
        var seams: [Int]
        /// With AutoMix, the first song's frame the mix's file starts on, and the second song's frame
        /// the clip goes on from after it (nil: the mix's file reached the clip's end).
        var mixFrom: Int? = nil
        var tailFrom: Int? = nil
        var length: Double { Double(min(left.count, right.count)) / sampleRate }
    }

    // MARK: One after the other

    /// The first song's end and the second's start, as they play with no transition: `a` holds the
    /// first song's last seconds up to its very end, `b` the second song from its start.
    static func plain(a: SegueAudio, b: SegueAudio, gains: (outgoing: Float, incoming: Float)) throws -> Mixed {
        let sr = a.sampleRate
        guard sr > 1000, abs(b.sampleRate - sr) < 0.5, a.frames > 0, b.frames > 0 else { throw Failure.unreadable }
        let lastSound = lastLoud(a) ?? (a.frames - 1)
        let firstSound = firstLoud(b) ?? 0
        let start = max(0, lastSound - Int(before * sr))
        let end = min(b.frames, firstSound + Int(after * sr))
        var left: [Float] = [], right: [Float] = []
        left.reserveCapacity(a.frames - start + end)
        right.reserveCapacity(a.frames - start + end)
        for i in start..<a.frames {
            left.append(a.left[i] * gains.outgoing)
            right.append(a.right[i] * gains.outgoing)
        }
        let seam = left.count
        for i in 0..<end {
            left.append(b.left[i] * gains.incoming)
            right.append(b.right[i] * gains.incoming)
        }
        var mixed = Mixed(left: left, right: right, sampleRate: sr, passageStart: Double(lastSound - start) / sr,
                          passageEnd: Double(seam + firstSound) / sr, seams: [seam])
        fadeEdges(&mixed)
        return mixed
    }

    // MARK: AutoMix

    /// AutoMix's passage from `plan` (as `SeguePolicy` decides it): `a` must hold the first song from
    /// `before` seconds ahead of the window, `b` the second song past the mix by `after` seconds.
    static func autoMix(_ plan: SeguePlan, a: SegueAudio, b: SegueAudio, gains: (outgoing: Float, incoming: Float)) throws -> Mixed {
        let sr = a.sampleRate
        guard sr > 1000, abs(b.sampleRate - sr) < 0.5, a.frames > 0, b.frames > 0 else { throw Failure.unreadable }
        // Where the mix's file starts in the first song: the frame `SegueRender.mix` starts on.
        let first = Int(((plan.outgoingStart - SegueRender.lead - a.origin) * sr).rounded())
        let from = Int(((plan.outgoingStart - before - a.origin) * sr).rounded())
        guard from >= 0, first > from, first <= a.frames else { throw Failure.range }
        var left: [Float] = [], right: [Float] = []
        for i in from..<first {
            left.append(a.left[i] * gains.outgoing)
            right.append(a.right[i] * gains.outgoing)
        }
        let seamIn = left.count
        let result = try SegueRender.mix(plan, a: a, b: b, gains: gains) { l, r, count in
            left.append(contentsOf: UnsafeBufferPointer(start: l, count: count))
            right.append(contentsOf: UnsafeBufferPointer(start: r, count: count))
        }
        var seams = [seamIn]
        var tailFrom: Int?
        let offset = Double(seamIn) / sr
        let passageStart = offset + result.windowStart, passageEnd = offset + result.windowEnd
        let wanted = Int(((passageEnd + after) * sr).rounded())
        if left.count >= wanted {
            left.removeSubrange(wanted...)
            right.removeSubrange(wanted...)
        } else {
            // The second song goes on from where the mix's file has it on its own samples.
            let next = Int(((result.join - b.origin) * sr).rounded())
            guard next >= 0, next < b.frames else { throw Failure.range }
            seams.append(left.count)
            tailFrom = next
            for i in next..<min(b.frames, next + wanted - left.count) {
                left.append(b.left[i] * gains.incoming)
                right.append(b.right[i] * gains.incoming)
            }
        }
        var mixed = Mixed(left: left, right: right, sampleRate: sr, passageStart: passageStart, passageEnd: passageEnd, seams: seams,
                          mixFrom: first, tailFrom: tailFrom)
        fadeEdges(&mixed)
        return mixed
    }

    // MARK: From files

    /// The plain clip of two song files, written to `destination` (decoded at the second song's rate).
    static func plain(outgoing: URL, incoming: URL, gains: (outgoing: Float, incoming: Float),
                      to destination: URL) async throws -> TransitionClip {
        let length = try await AVURLAsset(url: outgoing).load(.duration).seconds
        guard length.isFinite, length > 1 else { throw Failure.unreadable }
        // Up to 20 seconds of silence at the second song's start are kept, as they would be heard.
        let b = try await SegueRender.decode(incoming, from: 0, to: before + after + 20, sampleRate: nil)
        let a = try await SegueRender.decode(outgoing, from: max(0, length - before - 12), to: length + 1, sampleRate: b.sampleRate)
        let mixed = try plain(a: a, b: b, gains: gains)
        try write(mixed, to: destination)
        return TransitionClip(url: destination, length: mixed.length, passageStart: mixed.passageStart, passageEnd: mixed.passageEnd)
    }

    /// AutoMix's clip of two song files for `plan`, written to `destination`.
    static func autoMix(_ plan: SeguePlan, outgoing: URL, incoming: URL, gains: (outgoing: Float, incoming: Float),
                        to destination: URL) async throws -> TransitionClip {
        let outgoingSpan = SegueRender.outgoingRange(plan), incomingSpan = SegueRender.incomingRange(plan)
        let b = try await SegueRender.decode(incoming, from: incomingSpan.from, to: incomingSpan.to + after + 4, sampleRate: nil)
        let a = try await SegueRender.decode(outgoing, from: max(0, min(outgoingSpan.from, plan.outgoingStart - before - 1)),
                                             to: outgoingSpan.to, sampleRate: b.sampleRate)
        try Task.checkCancellation()
        let mixed = try autoMix(plan, a: a, b: b, gains: gains)
        try write(mixed, to: destination)
        return TransitionClip(url: destination, length: mixed.length, passageStart: mixed.passageStart, passageEnd: mixed.passageEnd)
    }

    // MARK: Pieces

    /// How loud the clip is from `start` to `end` (seconds), in dB of its root mean square.
    static func loudness(_ mixed: Mixed, from start: Double, to end: Double) -> Double {
        let from = max(0, Int(start * mixed.sampleRate)), to = min(mixed.left.count, mixed.right.count, Int(end * mixed.sampleRate))
        guard to > from else { return -120 }
        var sum = 0.0
        for i in from..<to {
            let m = Double(mixed.left[i] + mixed.right[i]) / 2
            sum += m * m
        }
        return 10 * log10(max(sum / Double(to - from), 1e-12))
    }

    /// The largest change from one frame to the next within `radius` frames of `frame`.
    static func largestStep(_ mixed: Mixed, around frame: Int, radius: Int) -> Float {
        let from = max(1, frame - radius), to = min(mixed.left.count, mixed.right.count, frame + radius)
        guard to > from else { return 0 }
        var step: Float = 0
        for i in from..<to {
            step = max(step, abs(mixed.left[i] - mixed.left[i - 1]), abs(mixed.right[i] - mixed.right[i - 1]))
        }
        return step
    }

    private static func lastLoud(_ audio: SegueAudio) -> Int? {
        var i = audio.frames - 1
        while i >= 0 {
            if abs(audio.left[i]) > silence || abs(audio.right[i]) > silence { return i }
            i -= 1
        }
        return nil
    }

    private static func firstLoud(_ audio: SegueAudio) -> Int? {
        (0..<audio.frames).first { abs(audio.left[$0]) > silence || abs(audio.right[$0]) > silence }
    }

    private static func fadeEdges(_ mixed: inout Mixed) {
        let count = min(mixed.left.count, mixed.right.count)
        let inFrames = min(count / 2, Int(fadeIn * mixed.sampleRate))
        let outFrames = min(count / 2, Int(fadeOut * mixed.sampleRate))
        func smooth(_ x: Float) -> Float { x * x * (3 - 2 * x) }
        for i in 0..<inFrames {
            let g = smooth(Float(i) / Float(max(1, inFrames)))
            mixed.left[i] *= g
            mixed.right[i] *= g
        }
        for k in 0..<outFrames {
            let i = count - 1 - k
            let g = smooth(Float(k) / Float(max(1, outFrames)))
            mixed.left[i] *= g
            mixed.right[i] *= g
        }
    }

    /// 16-bit, as the app's rendered mixes are.
    static func write(_ mixed: Mixed, to url: URL) throws {
        let count = min(mixed.left.count, mixed.right.count)
        guard count > 0 else { throw Failure.range }
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: mixed.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)),
              let channels = buffer.floatChannelData, buffer.format.channelCount >= 2 else { throw Failure.unreadable }
        for i in 0..<count {
            channels[0][i] = max(-1, min(1, mixed.left[i]))
            channels[1][i] = max(-1, min(1, mixed.right[i]))
        }
        buffer.frameLength = AVAudioFrameCount(count)
        try file.write(from: buffer)
    }
}
