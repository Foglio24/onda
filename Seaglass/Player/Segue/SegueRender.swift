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
///   from the playing song's, as the plan has it), and the two meet halfway in tempo: the playing song
///   glides from its own speed to the middle one over the window, the next one with it.
/// - After the window the next song glides back to its own speed over eight of its bars, eased at both
///   ends (no corner in the speed), then onto its own samples exactly (`settle`): the file ends with
///   it sample for sample as its file plays, where the song's file carries on (`join`).
///
/// A speed here is a resampling: the pitch moves with the tempo by half the gap at most, as on a
/// turntable, and nothing else is changed (no time stretch with its artefacts).
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
        /// The next song's own time just after the file's last frame: its file carries on from there.
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

    /// Meeting halfway: the playing song goes to 1/√rate, the next one, locked to it, to √rate (its
    /// speed against the playing one is the plan's `rate`); then back to 1 over eight of its bars.
    /// Plans that don't match beats keep both songs at their own speed.
    static func glides(for plan: SeguePlan) -> Glide {
        let rate = plan.rate
        guard plan.level.isLocked, rate.isFinite, rate > 0.5, rate < 2, abs(rate - 1) > 1e-6 else {
            return Glide(outgoingRate: 1, incomingRate: 1, incomingGlide: 0)
        }
        let root = rate.squareRoot()
        let tempo = max(40, (plan.tempo ?? 120) / rate)
        return Glide(outgoingRate: 1 / root, incomingRate: root, incomingGlide: min(24, max(8, 8 * 4 * 60 / tempo)))
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

    /// The sample at frame position `x` (fractional) of `samples`: exact on a whole frame, cubic
    /// (Hermite) between, silence outside them.
    @inline(__always)
    private static func read(_ samples: UnsafeBufferPointer<Float>, at x: Double) -> Float {
        let frames = samples.count
        guard x.isFinite, x > -4, x < Double(frames) + 4 else { return 0 }
        @inline(__always) func at(_ i: Int) -> Float { i >= 0 && i < frames ? samples[i] : 0 }
        let nearest = x.rounded()
        if abs(x - nearest) < 1e-6 { return at(Int(nearest)) }
        let base = Int(x.rounded(.down))
        let fraction = Float(x - Double(base))
        let y0 = at(base - 1), y1 = at(base), y2 = at(base + 1), y3 = at(base + 2)
        let c1 = 0.5 * (y2 - y0)
        let c2 = y0 - 2.5 * y1 + 2 * y2 - 0.5 * y3
        let c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2)
        return ((c3 * fraction + c2) * fraction + c1) * fraction + y1
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
        guard first >= 4, endS > startS, Double(a.frames) > outgoingLast + 4,
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

        return try a.left.withUnsafeBufferPointer { aLeft in
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
                        let headFrames = Int(((crossing + fade + 0.05) * sr).rounded())
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
                                    aL[i] = read(aLeft, at: pA)
                                    aR[i] = read(aRight, at: pA)
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
                                    bL[i] = read(bLeft, at: pB)
                                    bR[i] = read(bRight, at: pB)
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
                                    bL[i] = read(bLeft, at: pB)
                                    bR[i] = read(bRight, at: pB)
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
                                    bL[i] = read(bLeft, at: pB)
                                    bR[i] = read(bRight, at: pB)
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

    // MARK: Files

    /// Decodes both songs, mixes `plan` and writes it to `destination` (32-bit float, at the playing
    /// song's own rate, so the file's first second is its samples exactly).
    static func render(_ plan: SeguePlan, outgoing: URL, incoming: URL, outgoingGain: Float, incomingGain: Float,
                       to destination: URL) async throws -> Result {
        let outgoingSpan = outgoingRange(plan), incomingSpan = incomingRange(plan)
        let a = try await decode(outgoing, from: outgoingSpan.from, to: outgoingSpan.to, sampleRate: nil)
        let b = try await decode(incoming, from: incomingSpan.from, to: incomingSpan.to, sampleRate: a.sampleRate)
        try Task.checkCancellation()
        try? FileManager.default.removeItem(at: destination)
        let file = try AVAudioFile(forWriting: destination, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: a.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: a.sampleRate, channels: 2, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(4096)),
              let channels = buffer.floatChannelData else { throw RenderError.unreadable }
        var filled = 0
        func flush() throws {
            guard filled > 0 else { return }
            buffer.frameLength = AVAudioFrameCount(filled)
            try file.write(from: buffer)
            filled = 0
        }
        let result = try mix(plan, a: a, b: b, gains: (outgoingGain, incomingGain)) { left, right, count in
            var offset = 0
            while offset < count {
                let take = min(count - offset, 4096 - filled)
                channels[0].advanced(by: filled).update(from: left + offset, count: take)
                channels[1].advanced(by: filled).update(from: right + offset, count: take)
                filled += take
                offset += take
                if filled == 4096 { try flush() }
            }
        }
        try flush()
        return result
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
