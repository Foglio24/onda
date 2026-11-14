import AVFoundation
import Foundation
#if canImport(CoreAudio)
import CoreAudio // UnsafeMutableAudioBufferListPointer: AVFoundation brings it on iOS, not on a Mac
#endif

/// A stretch of one song decoded to memory for `SegueRender`: stereo, at the render's rate.
struct SegueAudio {
    var left: [Float]
    var right: [Float]
    /// The song's own time, seconds, of the first frame.
    var origin: Double
    var sampleRate: Double
    var frames: Int { min(left.count, right.count) }
}

/// A Segue plan played ahead of time into a file, both songs on their own samples, so that no tempo
/// ever changes in a step: AVPlayer can't change a playing song's speed without its sound jumping
/// (see `SegueSession`), so the speeds change here instead, as gradually as a DJ's fader.
///
/// - The file starts a second before the window with the playing song alone, sample for sample as
///   its player plays it (same samples, same gain): the player that plays the file takes over from
///   the playing one there, unheard (`crossing`, `fade`).
/// - Through the window the next song is locked to the playing one, beat on beat (its place follows
///   from the playing song's, as the plan has it), and the tempo goes from the playing song's to the
///   next one's, eased at both ends (no corner in the speed): at the start the playing song is at its
///   own speed and the next one, still quiet, at the playing one's tempo; at the end the next song is
///   at its own speed and the playing one, faded out, at the next one's. The song heard most is always
///   at or near its own tempo, and nothing changes after the window.
/// - After the window the next song goes onto its own samples exactly (`settle`), and the file goes on
///   with them to the song's end, at its gain: the player plays this one file from the take-over to
///   the song's end, so nothing changes after the mix (no other file, no other level, no seam).
///   `join` is where the song is its own samples again (seeks before it go to the song's own file).
///
/// A speed here is a resampling with a long windowed-sinc filter (flat to about 20 kHz, exact on a
/// whole frame), so the sound is the song's own through and after the mix: the pitch moves with the
/// tempo, as on a turntable, and nothing else changes (no time stretch with its artefacts).
enum SegueRender {
    enum RenderError: Error {
        case noAudio
        case unreadable
        case range
    }

    /// The speeds: the playing song's at the window's end, the next one's there, and how long (seconds
    /// of the next song's own time) it takes after the window to get back to its own.
    struct Glide: Equatable {
        var outgoingRate: Double
        var incomingRate: Double
        var incomingGlide: Double
    }

    struct Result {
        /// The file's sample rate (the playing song's own).
        var sampleRate: Double
        /// Seconds of audio in the file.
        var length: Double
        /// The playing song's own time at the file's first frame.
        var handover: Double
        /// The next song's own time just after the mix's last frame (`length`): from there the file is
        /// the song's own samples to its end.
        var join: Double
        /// In the file's seconds: the window, and where the next song is back at its own speed.
        var windowStart: Double
        var windowEnd: Double
        var back: Double
        var glide: Glide
        /// Largest difference between the file and the songs as their players play them, where the
        /// file takes over (the playing song) and where it hands back (the next song): 0 when exact.
        var headDifference: Float
        var tailDifference: Float
        /// The largest change of a song's speed from one frame to the next (no step: a few millionths).
        var largestSpeedStep: Double
        /// Samples that didn't follow on in the decks' processing (0).
        var jumps: Int
        /// Largest difference between the rest of the song written after the mix (decoded again) and
        /// the same frames of the first decoding, at its gain: 0 when it follows on exactly.
        var restDifference: Float = 0
    }

    /// Seconds of the playing song alone before the window; when the file's player comes in (silent
    /// until then, so its start is never heard), and the crossover's length.
    static let lead = 1.0
    static let crossing = 0.35
    static let fade = 0.08
    /// The next song's lanes going back to plain after the window (seconds of its time), then its own
    /// samples over `blend`; the last fraction of a frame made up over `settle`; `margin` of its own
    /// samples to end on.
    static let release = 2.0
    static let blend = 0.1
    static let settle = 1.0
    static let margin = 1.5
    static let chunk = 64

    /// From the playing song's tempo to the next one's over the window: the playing song goes to
    /// 1/rate, the next one, locked to it (its speed against the playing one is the plan's `rate`),
    /// to 1, its own, by the window's end. Nothing glides after it. Plans that don't match beats keep
    /// both songs at their own speed.
    static func glides(for plan: SeguePlan) -> Glide {
        let rate = plan.rate
        guard plan.level.isLocked, rate.isFinite, rate > 0.5, rate < 2, abs(rate - 1) > 1e-6 else {
            return Glide(outgoingRate: 1, incomingRate: 1, incomingGlide: 0)
        }
        return Glide(outgoingRate: 1 / rate, incomingRate: 1, incomingGlide: 0)
    }

    /// The song time each side's audio must cover, decoded from (before, after) seconds around these.
    static func outgoingRange(_ plan: SeguePlan) -> (from: Double, to: Double) {
        let echo = plan.hasEcho ? SeguePlan.echoTail : 0
        return (plan.outgoingStart - lead - 0.5, plan.outgoingEnd + echo + 1)
    }

    static func incomingRange(_ plan: SeguePlan) -> (from: Double, to: Double) {
        let glide = glides(for: plan)
        let after = max(glide.incomingGlide, release + blend + 0.5) + settle + margin
        return (max(0, plan.incomingStart - 1), plan.incomingEnd + after * 1.2 + 2)
    }

    @inline(__always)
    private static func smooth(_ u: Double) -> Double {
        let x = max(0, min(1, u))
        return x * x * (3 - 2 * x)
    }

    // MARK: Resampling

    /// The interpolation filter: a windowed sinc of `taps` taps (Kaiser, β 9.5), tabulated at `phases`
    /// fractions of a frame and read between them linearly. Flat to about nine tenths of the Nyquist
    /// frequency (20 kHz at 44.1 kHz) with its images 90 dB down; on a whole frame it is the frame
    /// itself. A cubic filter, as before, dulled the top octave by a few decibels while a song was
    /// resampled, heard as its own sound coming back when the resampling stopped.
    static let taps = 64
    static let phases = 512
    private static let kernel: [Float] = {
        let half = taps / 2
        let beta = 9.5
        func bessel0(_ x: Double) -> Double {
            var sum = 1.0, term = 1.0, k = 1.0
            while term > 1e-12 * sum {
                term *= (x / (2 * k)) * (x / (2 * k))
                sum += term
                k += 1
            }
            return sum
        }
        let norm = bessel0(beta)
        var table = [Float](repeating: 0, count: (phases + 1) * taps)
        for phase in 0...phases {
            let fraction = Double(phase) / Double(phases)
            for j in 0..<taps {
                // Tap j reads frame base + j - (half - 1); its distance from the position.
                let t = Double(j - (half - 1)) - fraction
                let ratio = t / Double(half)
                guard abs(ratio) < 1 else { continue }
                let sinc = t == 0 ? 1 : sin(Double.pi * t) / (Double.pi * t)
                let window = bessel0(beta * (1 - ratio * ratio).squareRoot()) / norm
                table[phase * taps + j] = Float(sinc * window)
            }
        }
        return table
    }()

    /// The sample at frame position `x` (fractional) of `samples`: exact on a whole frame, the
    /// windowed sinc between, silence outside them.
    @inline(__always)
    private static func read(_ samples: UnsafeBufferPointer<Float>, at x: Double, kernel: UnsafeBufferPointer<Float>) -> Float {
        let frames = samples.count
        let half = taps / 2
        guard x.isFinite, x > Double(-half), x < Double(frames + half) else { return 0 }
        let nearest = x.rounded()
        if abs(x - nearest) < 1e-6 {
            let i = Int(nearest)
            return i >= 0 && i < frames ? samples[i] : 0
        }
        let base = Int(x.rounded(.down))
        let position = (x - Double(base)) * Double(phases)
        let phase = min(phases - 1, Int(position))
        let blend = Float(position - Double(phase))
        let low = phase * taps, high = low + taps
        let first = base - (half - 1)
        var sum: Float = 0
        if first >= 0, first + taps <= frames {
            for j in 0..<taps {
                let weight = kernel[low + j] + (kernel[high + j] - kernel[low + j]) * blend
                sum += samples[first + j] * weight
            }
        } else {
            for j in 0..<taps {
                let i = first + j
                guard i >= 0, i < frames else { continue }
                let weight = kernel[low + j] + (kernel[high + j] - kernel[low + j]) * blend
                sum += samples[i] * weight
            }
        }
        return sum
    }

    /// Untouched up to 0.95, then a smooth knee under 1 (as `DeckMixer`'s): only where both songs play.
    @inline(__always)
    private static func soften(_ x: Float) -> Float {
        let magnitude = abs(x)
        if magnitude <= 0.95 { return x }
        let shaped = 0.95 + 0.05 * Float(tanh(Double((magnitude - 0.95) / 0.05)))
        return x < 0 ? -shaped : shaped
    }

    private enum IncomingState {
        case waiting
        case locked
        case gliding
        case settling(left: Int, step: Double)
        case exact(index: Int, left: Int)
    }

    /// Mixes `plan` from `a` (the playing song) and `b` (the next one), at their gains, handing the
    /// file's frames to `write` (left, right, count) as they are made. Both at the same rate.
    static func mix(_ plan: SeguePlan, a: SegueAudio, b: SegueAudio, gains: (outgoing: Float, incoming: Float),
                    write: (UnsafePointer<Float>, UnsafePointer<Float>, Int) throws -> Void) throws -> Result {
        let sr = a.sampleRate
        guard sr > 1000, abs(b.sampleRate - sr) < 0.5, a.frames > 0, b.frames > 0 else { throw RenderError.unreadable }
        let glide = glides(for: plan)
        let r = plan.rate
        let alpha = glide.outgoingRate, beta = glide.incomingRate
        // Positions are frames into each song's samples.
        let first = ((plan.outgoingStart - lead - a.origin) * sr).rounded()
        let startS = (plan.outgoingStart - a.origin) * sr
        let endS = (plan.outgoingEnd - a.origin) * sr
        let startI = (plan.incomingStart - b.origin) * sr
        let endI = startI + (endS - startS) * r
        let glideFrames = glide.incomingGlide * sr
        let echo = plan.hasEcho ? SeguePlan.echoTail : 0
        let outgoingLast = endS + (echo + 0.2) * sr
        let incomingFrom = startS - 0.5 * sr
        let stageFrom = startS - 0.5 * sr
        let bypassAt = endI + (release + 0.5) * sr
        let blendFrames = blend * sr
        let settleAt = max(endI + glideFrames, bypassAt + blendFrames)
        let settleFrames = max(1, Int((settle * sr).rounded()))
        let marginFrames = max(1, Int((margin * sr).rounded()))
        // The playing song may end with the window, or within its echo's tail (most mixes are at a song's
        // end): past its samples it reads as silence. It must only hold the take-over's second.
        let headFrames = Int(((crossing + fade + 0.05) * sr).rounded())
        guard first >= 4, endS > startS, Double(a.frames) > first + Double(headFrames) + 8,
              Double(b.frames) > settleAt + Double(settleFrames + marginFrames) * 1.01 + 8 else { throw RenderError.range }

        func rateA(_ p: Double) -> Double {
            if p <= startS { return 1 }
            if p >= endS { return alpha }
            return 1 + (alpha - 1) * smooth((p - startS) / (endS - startS))
        }
        func rateB(_ p: Double) -> Double {
            guard glideFrames > 0 else { return 1 }
            return 1 + (beta - 1) * (1 - smooth((p - endI) / glideFrames))
        }

        // The decks: the plan's lanes on each side, by its own time. The playing song's echo keeps to
        // its beat at the speed it has then.
        var outgoingPlan = plan
        if let delay = plan.echoDelay { outgoingPlan.echoDelay = delay / alpha }
        let stageA = SegueStage(), stageB = SegueStage()
        stageA.prepare(sampleRate: sr, channels: 2, isFloat: true)
        stageB.prepare(sampleRate: sr, channels: 2, isFloat: true)
        stageA.arm(outgoingPlan, side: .outgoing)
        stageB.arm(plan, side: .incoming)

        let n = chunk
        let aL = UnsafeMutablePointer<Float>.allocate(capacity: n), aR = UnsafeMutablePointer<Float>.allocate(capacity: n)
        let bL = UnsafeMutablePointer<Float>.allocate(capacity: n), bR = UnsafeMutablePointer<Float>.allocate(capacity: n)
        let rawL = UnsafeMutablePointer<Float>.allocate(capacity: n), rawR = UnsafeMutablePointer<Float>.allocate(capacity: n)
        let outL = UnsafeMutablePointer<Float>.allocate(capacity: n), outR = UnsafeMutablePointer<Float>.allocate(capacity: n)
        let bPositions = UnsafeMutablePointer<Double>.allocate(capacity: n)
        let listA = AudioBufferList.allocate(maximumBuffers: 2), listB = AudioBufferList.allocate(maximumBuffers: 2)
        let bytes = UInt32(n * MemoryLayout<Float>.size)
        listA[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: UnsafeMutableRawPointer(aL))
        listA[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: UnsafeMutableRawPointer(aR))
        listB[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: UnsafeMutableRawPointer(bL))
        listB[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: UnsafeMutableRawPointer(bR))
        defer {
            for pointer in [aL, aR, bL, bR, rawL, rawR, outL, outR] { pointer.deallocate() }
            bPositions.deallocate()
            free(listA.unsafeMutablePointer)
            free(listB.unsafeMutablePointer)
        }

        return try kernel.withUnsafeBufferPointer { kernel in
        try a.left.withUnsafeBufferPointer { aLeft in
            try a.right.withUnsafeBufferPointer { aRight in
                try b.left.withUnsafeBufferPointer { bLeft in
                    try b.right.withUnsafeBufferPointer { bRight in
                        var pA = first
                        var pB = 0.0
                        var outgoingOn = true
                        var state = IncomingState.waiting
                        var released = false
                        var written = 0
                        var windowStart: Int?, windowEnd: Int?, back: Int?
                        var lastA = 1.0, lastB: Double?
                        var largestStep = 0.0
                        var head: Float = 0, tail: Float = 0
                        var finished = false
                        var joinIndex = 0
                        while !finished {
                            let chunkA = pA
                            let aStaged = outgoingOn && chunkA >= stageFrom
                            if case .waiting = state, pA >= incomingFrom {
                                state = .locked
                                pB = startI + (pA - startS) * r
                            }
                            let chunkB = pB
                            let incomingOn: Bool
                            if case .waiting = state { incomingOn = false } else { incomingOn = true }
                            if incomingOn, !released, chunkB >= endI {
                                stageB.release(over: release)
                                released = true
                            }
                            let bStaged = incomingOn && chunkB < bypassAt + blendFrames
                            var count = n
                            for i in 0..<n {
                                // The playing song.
                                if outgoingOn {
                                    aL[i] = read(aLeft, at: pA, kernel: kernel)
                                    aR[i] = read(aRight, at: pA, kernel: kernel)
                                    if windowStart == nil, pA >= startS { windowStart = written + i }
                                    if windowEnd == nil, pA >= endS { windowEnd = written + i }
                                    let advance = rateA(pA)
                                    largestStep = max(largestStep, abs(advance - lastA))
                                    lastA = advance
                                    pA += advance
                                } else {
                                    aL[i] = 0
                                    aR[i] = 0
                                }
                                // The next song.
                                bPositions[i] = pB
                                var advance = 0.0
                                switch state {
                                case .waiting:
                                    bL[i] = 0
                                    bR[i] = 0
                                case .locked:
                                    bL[i] = read(bLeft, at: pB, kernel: kernel)
                                    bR[i] = read(bRight, at: pB, kernel: kernel)
                                    if pA < endS {
                                        let next = startI + (pA - startS) * r
                                        advance = next - pB
                                        pB = next
                                    } else {
                                        state = .gliding
                                        advance = rateB(pB)
                                        pB += advance
                                    }
                                case .gliding:
                                    bL[i] = read(bLeft, at: pB, kernel: kernel)
                                    bR[i] = read(bRight, at: pB, kernel: kernel)
                                    advance = rateB(pB)
                                    pB += advance
                                    if pB >= settleAt {
                                        let missing = pB.rounded(.up) - pB
                                        if missing < 1e-9 {
                                            pB = pB.rounded(.up)
                                            state = .exact(index: Int(pB), left: marginFrames)
                                            if back == nil { back = written + i + 1 }
                                        } else {
                                            state = .settling(left: settleFrames, step: 1 + missing / Double(settleFrames))
                                        }
                                    }
                                case .settling(let left, let step):
                                    bL[i] = read(bLeft, at: pB, kernel: kernel)
                                    bR[i] = read(bRight, at: pB, kernel: kernel)
                                    advance = step
                                    pB += step
                                    if left <= 1 {
                                        pB = pB.rounded()
                                        state = .exact(index: Int(pB), left: marginFrames)
                                        if back == nil { back = written + i + 1 }
                                    } else {
                                        state = .settling(left: left - 1, step: step)
                                    }
                                case .exact(let index, let left):
                                    bL[i] = index >= 0 && index < bLeft.count ? bLeft[index] : 0
                                    bR[i] = index >= 0 && index < bRight.count ? bRight[index] : 0
                                    advance = 1
                                    pB = Double(index + 1)
                                    if left <= 1 {
                                        finished = true
                                        joinIndex = index + 1
                                        count = i + 1
                                    } else {
                                        state = .exact(index: index + 1, left: left - 1)
                                    }
                                }
                                if incomingOn {
                                    if let lastB { largestStep = max(largestStep, abs(advance - lastB)) }
                                    lastB = advance
                                }
                                if finished { break }
                            }
                            // The lanes, by each song's own time over the chunk.
                            if aStaged {
                                stageA.process(listA, frames: n, time: a.origin + chunkA / sr, duration: (pA - chunkA) / sr)
                            }
                            if bStaged {
                                for i in 0..<n {
                                    rawL[i] = bL[i]
                                    rawR[i] = bR[i]
                                }
                                stageB.process(listB, frames: n, time: b.origin + chunkB / sr, duration: max(0, pB - chunkB) / sr)
                                // From the lanes (back to plain by now) onto the song's own samples, over `blend`.
                                for i in 0..<n where bPositions[i] >= bypassAt {
                                    let w = Float(min(1, (bPositions[i] - bypassAt) / blendFrames))
                                    bL[i] = bL[i] * (1 - w) + rawL[i] * w
                                    bR[i] = bR[i] * (1 - w) + rawR[i] * w
                                }
                            }
                            let both = outgoingOn && incomingOn
                            for i in 0..<count {
                                var left = aL[i] * gains.outgoing + bL[i] * gains.incoming
                                var right = aR[i] * gains.outgoing + bR[i] * gains.incoming
                                if both {
                                    left = soften(left)
                                    right = soften(right)
                                }
                                outL[i] = left
                                outR[i] = right
                                let frame = written + i
                                if frame < headFrames {
                                    let index = Int(first) + frame
                                    head = max(head, abs(left - aLeft[index] * gains.outgoing), abs(right - aRight[index] * gains.outgoing))
                                }
                            }
                            if case .exact = state, back.map({ written + count > $0 }) ?? false {
                                // The tail: the next song's own samples (checked against them as they were read).
                                for i in 0..<count where written + i >= (back ?? Int.max) {
                                    let index = Int(bPositions[i].rounded())
                                    guard index >= 0, index < bLeft.count else { continue }
                                    tail = max(tail, abs(outL[i] - bLeft[index] * gains.incoming), abs(outR[i] - bRight[index] * gains.incoming))
                                }
                            }
                            if outgoingOn, pA >= outgoingLast { outgoingOn = false }
                            try write(outL, outR, count)
                            written += count
                            // A safety stop: the plan's window and glides never take this long.
                            if written > Int(sr * 600) { throw RenderError.range }
                        }
                        return Result(sampleRate: sr, length: Double(written) / sr, handover: a.origin + first / sr,
                                      join: b.origin + Double(joinIndex) / sr,
                                      windowStart: Double(windowStart ?? 0) / sr, windowEnd: Double(windowEnd ?? 0) / sr,
                                      back: Double(back ?? written) / sr, glide: glide, headDifference: head,
                                      tailDifference: tail, largestSpeedStep: largestStep,
                                      jumps: stageA.jumps + stageB.jumps)
                    }
                }
            }
        }
        }
    }

    // MARK: Files

    /// Writes stereo frames to a file in blocks (16-bit, interleaved on disk).
    private final class Writer {
        let file: AVAudioFile
        let buffer: AVAudioPCMBuffer
        let channels: UnsafePointer<UnsafeMutablePointer<Float>>
        var filled = 0
        static let block = 4096

        init(_ url: URL, sampleRate: Double) throws {
            try? FileManager.default.removeItem(at: url)
            file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Self.block)),
                  let channels = buffer.floatChannelData else { throw RenderError.unreadable }
            self.buffer = buffer
            self.channels = channels
        }

        func write(_ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>, _ count: Int) throws {
            var offset = 0
            while offset < count {
                let take = min(count - offset, Self.block - filled)
                channels[0].advanced(by: filled).update(from: left + offset, count: take)
                channels[1].advanced(by: filled).update(from: right + offset, count: take)
                filled += take
                offset += take
                if filled == Self.block { try flush() }
            }
        }

        func flush() throws {
            guard filled > 0 else { return }
            buffer.frameLength = AVAudioFrameCount(filled)
            try file.write(from: buffer)
            filled = 0
        }
    }

    /// Decodes both songs, mixes `plan` and writes it to `destination`, followed by the rest of the
    /// next song to its end, at its gain: the player plays this one file from the take-over to the
    /// song's end, so nothing changes after the mix (no other file, no other level, no seam). At the
    /// next song's own rate (the playing song resampled to it if it differs), so its samples go on
    /// exactly as decoded; 16-bit.
    static func render(_ plan: SeguePlan, outgoing: URL, incoming: URL, outgoingGain: Float, incomingGain: Float,
                       to destination: URL) async throws -> Result {
        let outgoingSpan = outgoingRange(plan), incomingSpan = incomingRange(plan)
        let b = try await decode(incoming, from: incomingSpan.from, to: incomingSpan.to, sampleRate: nil)
        let a = try await decode(outgoing, from: outgoingSpan.from, to: outgoingSpan.to, sampleRate: b.sampleRate)
        try Task.checkCancellation()
        let writer = try Writer(destination, sampleRate: b.sampleRate)
        var result = try mix(plan, a: a, b: b, gains: (outgoingGain, incomingGain)) { left, right, count in
            try writer.write(left, right, count)
        }
        // From the first decoding (the mix's last frames are its samples) onto the second, over 50 ms.
        let firstKnown = Int(((result.join - b.origin) * b.sampleRate).rounded())
        result.restDifference = try await appendSong(of: incoming, from: result.join, sampleRate: b.sampleRate,
                                                     gain: incomingGain, to: writer, blend: Int(0.05 * b.sampleRate)) { k in
            let index = firstKnown + k
            return index >= 0 && index < b.frames ? (b.left[index] * incomingGain, b.right[index] * incomingGain) : nil
        }
        try writer.flush()
        return result
    }

    /// The song from `start` (its own time) to its end, at `gain`, onto `writer`: decoded again from a
    /// little before it, its first frames up to `start` dropped. `before(k)` is what the file would hold
    /// at the k-th of these frames had it gone on as it was (the first decoding's samples, or a mix's
    /// last ones), already at its gain, nil past what is known: the first `blend` frames cross over from
    /// it to the new decoding, so a decoder that doesn't give the very same samples twice (a lossy one
    /// started elsewhere) is never heard as a step. Returns the largest difference between the two
    /// where both are known (0: the song follows on exactly).
    private static func appendSong(of url: URL, from start: Double, sampleRate: Double, gain: Float, to writer: Writer,
                                   blend: Int, before: (Int) -> (Float, Float)?) async throws -> Float {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw RenderError.noAudio }
        let duration = try await asset.load(.duration).seconds
        let reader = try AVAssetReader(asset: asset)
        let from = max(0, start - 0.5)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 1_000_000),
                                       end: duration.isFinite && duration > from ? CMTime(seconds: duration, preferredTimescale: 1_000_000) : .positiveInfinity)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw RenderError.unreadable }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? RenderError.unreadable }
        var skip: Int?
        var scratch: [Float] = []
        var left = [Float](repeating: 0, count: Writer.block), right = [Float](repeating: 0, count: Writer.block)
        var count = 0
        var written = 0
        var known = true
        var difference: Float = 0
        let blendFrames = max(1, blend)
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let values = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
            guard values >= 2 else { continue }
            if skip == nil {
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                guard time.isNumeric else { continue }
                skip = max(0, Int(((start - time.seconds) * sampleRate).rounded()))
            }
            if scratch.count < values { scratch = [Float](repeating: 0, count: values) }
            let status = scratch.withUnsafeMutableBytes { bytes -> OSStatus in
                guard let base = bytes.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: values * MemoryLayout<Float>.size, destination: base)
            }
            guard status == noErr else { throw RenderError.unreadable }
            var index = 0
            while index + 1 < values {
                if let remaining = skip, remaining > 0 {
                    skip = remaining - 1
                } else {
                    var l = scratch[index] * gain, r = scratch[index + 1] * gain
                    if known {
                        if let earlier = before(written) {
                            difference = max(difference, abs(l - earlier.0), abs(r - earlier.1))
                            if written < blendFrames {
                                let w = Float(written) / Float(blendFrames)
                                l = earlier.0 * (1 - w) + l * w
                                r = earlier.1 * (1 - w) + r * w
                            }
                        } else {
                            known = false
                        }
                    }
                    left[count] = l
                    right[count] = r
                    written += 1
                    count += 1
                    if count == Writer.block {
                        try writer.write(left, right, count)
                        count = 0
                    }
                }
                index += 2
            }
        }
        guard reader.status == .completed else { throw reader.error ?? RenderError.unreadable }
        if count > 0 { try writer.write(left, right, count) }
        return difference
    }

    /// A mix rendered the earlier way (`AutoMixRenderer`: `length` seconds, ending where the next song
    /// is at `join`), followed by the rest of that song to its end at `gain`, in one file at
    /// `destination`: its last 30 ms cross over into the song's own samples, as the two-part item did
    /// with volume ramps, which weren't held with audio processing on its parts (the song came back at
    /// full level). The player plays this one file to the song's end.
    static func extend(mix: URL, length: Double, join: Double, song: URL, gain: Float, to destination: URL) async throws {
        let file = try AVAudioFile(forReading: mix, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let rate = format.sampleRate
        let wanted = min(file.length, AVAudioFramePosition((length * rate).rounded()))
        guard wanted > 0, format.channelCount >= 2, rate > 1000,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(wanted)) else { throw RenderError.unreadable }
        try file.read(into: buffer, frameCount: AVAudioFrameCount(wanted))
        guard let channels = buffer.floatChannelData else { throw RenderError.unreadable }
        let count = Int(buffer.frameLength)
        let overlap = min(count, max(1, Int(0.03 * rate)))
        guard count > overlap, join * rate > Double(overlap) else { throw RenderError.range }
        let writer = try Writer(destination, sampleRate: rate)
        try writer.write(channels[0], channels[1], count - overlap)
        let tailLeft = channels[0] + (count - overlap), tailRight = channels[1] + (count - overlap)
        _ = try await appendSong(of: song, from: join - Double(overlap) / rate, sampleRate: rate, gain: gain, to: writer,
                                 blend: overlap) { k in k < overlap ? (tailLeft[k], tailRight[k]) : nil }
        try writer.flush()
        // The mix's samples (the pointers above) live as long as their buffer.
        withExtendedLifetime(buffer) {}
    }

    /// The song's audio from `start` to `end` (its own time), stereo, at `sampleRate` (nil: the file's
    /// own). The first frame's time is the decoder's own (its first buffer's).
    static func decode(_ url: URL, from start: Double, to end: Double, sampleRate wanted: Double?) async throws -> SegueAudio {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw RenderError.noAudio }
        let formats = (try? await track.load(.formatDescriptions)) ?? []
        let native = formats.compactMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate }
            .first(where: { $0 > 1000 }) ?? 44_100
        let rate = wanted ?? native
        let reader = try AVAssetReader(asset: asset)
        let from = max(0, start)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 1_000_000),
                                       duration: CMTime(seconds: max(0.5, end - from), preferredTimescale: 1_000_000))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 2,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw RenderError.unreadable }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? RenderError.unreadable }
        var left: [Float] = [], right: [Float] = []
        let expected = Int(max(0, end - from) * rate) + 4096
        left.reserveCapacity(expected)
        right.reserveCapacity(expected)
        var origin: Double?
        var scratch: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
            guard count >= 2 else { continue }
            if origin == nil {
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                guard time.isNumeric else { continue }
                origin = time.seconds
            }
            if scratch.count < count { scratch = [Float](repeating: 0, count: count) }
            let status = scratch.withUnsafeMutableBytes { bytes -> OSStatus in
                guard let base = bytes.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size, destination: base)
            }
            guard status == noErr else { throw RenderError.unreadable }
            var index = 0
            while index + 1 < count {
                left.append(scratch[index])
                right.append(scratch[index + 1])
                index += 2
            }
        }
        guard reader.status == .completed, let origin, origin.isFinite, !left.isEmpty else { throw reader.error ?? RenderError.unreadable }
        return SegueAudio(left: left, right: right, origin: origin, sampleRate: rate)
    }
}
