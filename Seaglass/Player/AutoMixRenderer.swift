import Accelerate
import AVFoundation
import Foundation

/// Renders an AutoMix mix ahead of time into an audio file, offline and faster than real time:
/// each song through its own time stretch (`AVAudioUnitTimePitch`, pitch kept), bass cut and
/// high-pass (`AVAudioUnitEQ`) and volume, automated block by block from a `MixSchedule`. The file
/// starts exactly where the playing song is at the plan's handover and ends exactly where the next
/// song's own playback carries on (`Mix.join`).
enum AutoMixRenderer {
    struct Mix: Sendable {
        let url: URL
        /// Seconds of audio in the file.
        let length: Double
        /// The next song's own time at the end of the file.
        let join: Double
        /// How much earlier (seconds, of its own time) the next song was started so its beats land
        /// on the first one's (nil: not measured, the beats weren't matched or didn't line up clearly).
        var shift: Double? = nil
        /// How much louder (dB) the mix's first second is than the same second of the song playing,
        /// and its last half second than the same of the next song, at their gains: 0 when the mix
        /// takes over and hands back at the songs' very level (for Settings → Informazioni).
        var takeOver: Double? = nil
        var handBack: Double? = nil
    }

    enum RenderError: Error {
        case noAudio
        case unreadable
        case engine
    }

    /// `effects` false leaves out the filters (for checks that look at the beats); `limiter` false
    /// leaves the peak limiter out of the way (for checks that measure what it does).
    static func render(_ schedule: MixSchedule, outgoing: URL, incoming: URL, outgoingGain: Float,
                       incomingGain: Float, to destination: URL, effects: Bool = true,
                       limiter: Bool = true) async throws -> Mix {
        let plan = schedule.plan
        var outgoingAudio = try await decode(outgoing, from: plan.handover, duration: plan.outEnd - plan.handover + 2)
        if let loop = plan.loop { outgoingAudio = looped(outgoingAudio, from: plan.handover, loop: loop) }
        let incomingAudio = try await decode(incoming, from: plan.inStart, duration: schedule.join - plan.inStart + 2)
        try Task.checkCancellation()
        // The time stretch moves each song by a few milliseconds, depending on how its tempo moved.
        // When the beats are matched, both songs are first rendered alone (at full volume, without
        // filters) and their onsets lined up where they play together: the next song then starts
        // that much earlier or later, so the beats land together.
        var delay = 0.0
        var measured: Double?
        if plan.style == .beatMatched, let overlap = overlapWindow(schedule) {
            let alone = try renderPass(schedule, outgoingAudio, incomingAudio, delay: 0, gains: (1, 0), effects: false,
                                       fullVolume: true, capture: overlap, to: nil)
            try Task.checkCancellation()
            let other = try renderPass(schedule, outgoingAudio, incomingAudio, delay: 0, gains: (0, 1), effects: false,
                                       fullVolume: true, capture: overlap, to: nil)
            try Task.checkCancellation()
            if let lag = onsetLag(alone.captured, other.captured) {
                // Late by `lag` seconds at the next song's rate: it starts that much of its own time earlier.
                delay = -lag * plan.incomingRate
                measured = -delay
            }
        }
        let pass = try renderPass(schedule, outgoingAudio, incomingAudio, delay: delay,
                                  gains: (outgoingGain, incomingGain), effects: effects, fullVolume: false,
                                  capture: 0..<1, to: destination, limiting: limiter)
        // Where the next song really is at the end of the mix (so the join is seamless): starting
        // `delay` later, the end is `delay` earlier in it; the rest is measured.
        let end = schedule.join - plan.inStart - delay
        let offset = contentOffset(pass.tail, incomingAudio, end: end) - delay
        let rate = MixSchedule.sampleRate
        let joinFrame = Int(((end + offset + delay) * rate).rounded())
        return Mix(url: destination, length: pass.length, join: schedule.join + offset, shift: measured,
                   takeOver: level(pass.captured, against: outgoingAudio, from: 0, gain: outgoingGain),
                   handBack: level(pass.tail, against: incomingAudio, from: joinFrame - pass.tail.count, gain: incomingGain))
    }

    /// How much louder (dB) `mix` (mono) is than the same number of frames of `song` from `start`
    /// (both channels' mean), at `gain`. Nil when either is silent or out of range.
    private static func level(_ mix: [Float], against song: AVAudioPCMBuffer, from start: Int, gain: Float) -> Double? {
        guard let channels = song.floatChannelData, start >= 0, !mix.isEmpty,
              start + mix.count <= Int(song.frameLength) else { return nil }
        var heard = 0.0, own = 0.0
        for (index, value) in mix.enumerated() {
            heard += Double(value * value)
            let source = (channels[0][start + index] + channels[1][start + index]) / 2 * gain
            own += Double(source * source)
        }
        guard heard > 1e-9, own > 1e-9 else { return nil }
        return 10 * log10(heard / own)
    }
    }

    /// The stretch of the mix where both songs play clearly, for lining up their beats.
    private static func overlapWindow(_ schedule: MixSchedule) -> Range<Double>? {
        let plan = schedule.plan
        let start = schedule.entry + max(0.5, (plan.alignment ?? plan.outStart) - plan.outStart)
        var end = start
        while end < schedule.length, schedule.positions(at: end + 0.25).outgoing < plan.outEnd - 0.25 * plan.overlap {
            end += 0.25
        }
        return end - start >= 3 ? start..<end : nil
    }

    /// How much later (seconds) the beats of `b` are than those of `a`: the lag, within 80 ms
    /// either way (a sixth of a beat at 120 BPM: never the next beat), at which their onsets line
    /// up best. The low onsets (kick drum and bass) count, as a DJ lines up kicks: the time stretch
    /// moves high, short sounds (hi-hats) differently from low ones, more so when both songs are
    /// stretched. Only when the low ones don't line up clearly do all onsets count. Nil when
    /// nothing lines up clearly.
    private static func onsetLag(_ a: [Float], _ b: [Float]) -> Double? {
        let rate = MixSchedule.sampleRate
        let hop = Int(rate / 1000)
        let window = 5 * hop
        /// How much the sound grows every millisecond: in amplitude below about 150 Hz, or in
        /// loudness (dB) over all frequencies.
        func onsets(_ x: [Float], low: Bool) -> [Float] {
            var signal = x
            if low {
                // Two one-pole low-passes at 150 Hz.
                let alpha = Float(1 - exp(-2 * Double.pi * 150 / rate))
                var first: Float = 0, second: Float = 0
                for index in signal.indices {
                    first += alpha * (signal[index] - first)
                    second += alpha * (first - second)
                    signal[index] = second
                }
            }
            let count = max(0, (signal.count - window) / hop)
            var level = [Float](repeating: 0, count: count)
            signal.withUnsafeBufferPointer { samples in
                guard let base = samples.baseAddress else { return }
                for frame in 0..<count {
                    var sum: Float = 0
                    vDSP_svesq(base + frame * hop, 1, &sum, vDSP_Length(window))
                    level[frame] = low ? sum.squareRoot() : log10(sum + 1e-9)
                }
            }
            return (0..<count).map { $0 >= 3 ? max(0, level[$0] - level[$0 - 3]) : 0 }
        }
        func lag(low: Bool) -> Double? {
            let curveA = onsets(a, low: low), curveB = onsets(b, low: low)
            let range = 80
            let length = min(curveA.count, curveB.count) - 2 * range
            guard length > 500 else { return nil }
            var scores: [Double] = []
            for lag in -range...range {
                var dot = 0.0, energyA = 0.0, energyB = 0.0
                for frame in range..<(range + length) {
                    let x = Double(curveA[frame]), y = Double(curveB[frame + lag])
                    dot += x * y
                    energyA += x * x
                    energyB += y * y
                }
                scores.append(dot / ((energyA * energyB).squareRoot() + 1e-12))
            }
            guard let best = scores.indices.max(by: { scores[$0] < scores[$1] }), scores[best] > 0.3 else { return nil }
            var shift = 0.0
            if best > 0, best < scores.count - 1 {
                let left = scores[best - 1], centre = scores[best], right = scores[best + 1]
                let denominator = left - 2 * centre + right
                if denominator < 0 { shift = 0.5 * (left - right) / denominator }
            }
            return (Double(best - range) + shift) * Double(hop) / rate
        }
        return lag(low: true) ?? lag(low: false)
    }

    /// One rendering of the mix, into `destination` when there is one, the next song starting
    /// `delay` seconds late. `fullVolume` leaves out the volume curves (for measuring). Returns its
    /// length, its last half second and the `capture` stretch (both mono).
    private static func renderPass(_ schedule: MixSchedule, _ outgoingAudio: AVAudioPCMBuffer,
                                   _ incomingAudio: AVAudioPCMBuffer, delay: Double, gains: (Float, Float),
                                   effects: Bool, fullVolume: Bool, capture: Range<Double>?,
                                   to destination: URL?, limiting: Bool = true) throws -> (length: Double, tail: [Float], captured: [Float]) {
        let rate = MixSchedule.sampleRate
        let plan = schedule.plan
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { throw RenderError.engine }
        let engine = AVAudioEngine()
        let block = MixSchedule.blockFrames
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: AVAudioFrameCount(block))
        // Two songs at once can go over full scale: a peak limiter keeps them from clipping.
        let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
        engine.attach(limiter)
        limiter.bypass = !limiting
        engine.connect(engine.mainMixerNode, to: limiter, format: format)
        engine.connect(limiter, to: engine.outputNode, format: format)
        let decks = [Deck(), Deck()]
        for (deck, gain) in zip(decks, [gains.0, gains.1]) {
            deck.attach(to: engine, format: format, gain: gain)
        }
        decks[0].delay.delayTime = max(0.05, min(2, plan.echoTime))
        decks[0].delay.feedback = Float(plan.echoFeedback * 100)
        // The noise sweep ("Rumore in uscita"): white noise through a rising high-pass.
        let noise = NoiseSource()
        let noiseNode = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList -> OSStatus in
            let level = noise.level
            for buffer in UnsafeMutableAudioBufferListPointer(bufferList) {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for frame in 0..<Int(frameCount) {
                    noise.state = noise.state &* 1_664_525 &+ 1_013_904_223
                    data[frame] = (Float(noise.state >> 8) / Float(1 << 24) * 2 - 1) * level * 0.2
                }
            }
            return noErr
        }
        let noiseFilter = AVAudioUnitEQ(numberOfBands: 1)
        noiseFilter.bands[0].filterType = .highPass
        noiseFilter.bands[0].bypass = false
        engine.attach(noiseNode)
        engine.attach(noiseFilter)
        engine.connect(noiseNode, to: noiseFilter, format: format)
        engine.connect(noiseFilter, to: engine.mainMixerNode, format: format)
        try engine.start()
        defer { engine.stop() }

        // The next song's player starts when, by its own clock, the mix reaches the entry.
        decks[0].player.scheduleBuffer(outgoingAudio, at: nil, options: [], completionHandler: nil)
        let entry = AVAudioFramePosition(((schedule.incomingClockAtEntry + delay) * rate).rounded())
        decks[1].player.scheduleBuffer(incomingAudio, at: AVAudioTime(sampleTime: max(0, entry), atRate: rate),
                                       options: [], completionHandler: nil)
        decks[0].player.play()
        decks[1].player.play()

        // The stretchers hold back a little audio: that much is rendered extra at the start and left
        // out, so the file begins exactly at the handover. Rates follow the mix clock; volumes,
        // filters and effects follow what is being heard.
        let latency = decks[0].latency + limiter.latency
        let latencyFrames = max(0, Int((latency * rate).rounded()))
        let total = schedule.steps.count * block + latencyFrames
        guard let output = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                            frameCapacity: AVAudioFrameCount(block)) else { throw RenderError.engine }
        var file: AVAudioFile?
        if let destination {
            try? FileManager.default.removeItem(at: destination)
            file = try AVAudioFile(forWriting: destination, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
        }
        let captureFrames = capture.map { Int(($0.lowerBound * rate).rounded())..<Int(($0.upperBound * rate).rounded()) }
        var captured: [Float] = []
        captured.reserveCapacity(captureFrames?.count ?? 0)
        let tailLength = Int(0.5 * rate)
        var tail = [Float](repeating: 0, count: tailLength)
        var rendered = 0
        var written = 0
        while rendered < total {
            if rendered % (block * 256) == 0 { try Task.checkCancellation() }
            let time = Double(rendered) / rate
            let pace = schedule.step(at: time)
            let heard = schedule.step(at: max(0, time - latency)).levels
            let dry = fullVolume ? (Float(1), Float(1)) : (heard.outgoing, heard.incoming)
            decks[0].set(rate: pace.outgoingRate, dry: dry.0, bass: heard.outgoingBassCut, mid: heard.outgoingMidCut,
                         high: heard.outgoingHighCut, lowPass: heard.outgoingLowPass, highPass: heard.outgoingHighPass,
                         reverb: heard.reverb, echo: heard.echo, effects: effects)
            decks[1].set(rate: pace.incomingRate, dry: dry.1, bass: heard.incomingBassCut, mid: heard.incomingMidCut,
                         high: heard.incomingHighCut, lowPass: heard.incomingLowPass, highPass: heard.incomingHighPass,
                         reverb: 0, echo: 0, effects: effects)
            noise.level = effects && !fullVolume ? heard.noise : 0
            noiseFilter.bands[0].frequency = Float(400 * pow(20, Double(heard.noise)))
            let frames = min(block, total - rendered)
            let status = try engine.renderOffline(AVAudioFrameCount(frames), to: output)
            guard status == .success, let channels = output.floatChannelData else { throw RenderError.engine }
            let skip = max(0, latencyFrames - rendered)
            if skip < frames {
                if let file { try write(output, from: skip, count: frames - skip, to: file) }
                // Keep the last half second, and the stretch asked for, as mono.
                for frame in skip..<frames {
                    let value = (channels[0][frame] + channels[1][frame]) / 2
                    tail[written % tailLength] = value
                    if let captureFrames, captureFrames.contains(written) { captured.append(value) }
                    written += 1
                }
            }
            rendered += frames
        }
        let start = written % tailLength
        let ordered = Array(tail[start...]) + Array(tail[..<start])
        return (Double(written) / rate, ordered, captured)
    }

    /// How much later in the next song (seconds) the end of the mix is than `end` (its time counted
    /// from where it starts in the mix): the lag at which the mix's last half second best matches
    /// the song, within 25 ms either way.
    private static func contentOffset(_ tail: [Float], _ incomingAudio: AVAudioPCMBuffer, end: Double) -> Double {
        let rate = MixSchedule.sampleRate
        guard let channels = incomingAudio.floatChannelData else { return 0 }
        let count = Int(incomingAudio.frameLength)
        let range = Int(0.025 * rate)
        let length = tail.count
        let first = Int((end * rate).rounded()) - length
        guard first - range >= 0, first + range + length <= count else { return 0 }
        var source = [Float](repeating: 0, count: count)
        for frame in 0..<count { source[frame] = (channels[0][frame] + channels[1][frame]) / 2 }
        var bestLag = 0
        var bestScore = -Float.infinity
        tail.withUnsafeBufferPointer { mix in
            source.withUnsafeBufferPointer { song in
                guard let mixStart = mix.baseAddress, let songStart = song.baseAddress else { return }
                var mixEnergy: Float = 0
                vDSP_svesq(mixStart, 1, &mixEnergy, vDSP_Length(length))
                for lag in -range...range {
                    var dot: Float = 0, energy: Float = 0
                    let window = songStart + first + lag
                    vDSP_dotpr(mixStart, 1, window, 1, &dot, vDSP_Length(length))
                    vDSP_svesq(window, 1, &energy, vDSP_Length(length))
                    let score = dot / ((mixEnergy * energy).squareRoot() + 1e-12)
                    if score > bestScore {
                        bestScore = score
                        bestLag = lag
                    }
                }
            }
        }
        // A quiet or unclear ending says nothing reliable: no correction then.
        return bestScore > 0.5 ? Double(bestLag) / rate : 0
    }

    /// One song's chain in the mix: time stretch, a five-band EQ (bass, mids and treble cuts, low-
    /// and high-pass), reverb and echo, then its own mixer for its volume.
    private final class Deck {
        let player = AVAudioPlayerNode()
        let pitch = AVAudioUnitTimePitch()
        let eq = AVAudioUnitEQ(numberOfBands: 5)
        let reverb = AVAudioUnitReverb()
        let delay = AVAudioUnitDelay()
        let mixer = AVAudioMixerNode()

        init() {
            let bands = eq.bands
            bands[0].filterType = .lowShelf
            bands[0].frequency = Float(MixFilters.bassFrequency)
            bands[1].filterType = .parametric
            bands[1].frequency = 1_000
            bands[1].bandwidth = 2
            bands[2].filterType = .highShelf
            bands[2].frequency = 4_000
            bands[3].filterType = .lowPass
            bands[3].frequency = 20_000
            bands[4].filterType = .highPass
            bands[4].frequency = 20
            for (index, band) in bands.enumerated() {
                band.gain = 0
                band.bypass = index >= 3
            }
            reverb.loadFactoryPreset(.largeHall)
            reverb.wetDryMix = 0
            delay.wetDryMix = 0
            delay.feedback = 0
            delay.lowPassCutoff = 8_000
        }

        var latency: TimeInterval { pitch.latency + eq.latency + reverb.latency + delay.latency }

        func attach(to engine: AVAudioEngine, format: AVAudioFormat, gain: Float) {
            for node in [player, pitch, eq, reverb, delay, mixer] as [AVAudioNode] { engine.attach(node) }
            engine.connect(player, to: pitch, format: format)
            engine.connect(pitch, to: eq, format: format)
            engine.connect(eq, to: reverb, format: format)
            engine.connect(reverb, to: delay, format: format)
            engine.connect(delay, to: mixer, format: format)
            engine.connect(mixer, to: engine.mainMixerNode, format: format)
            mixer.outputVolume = gain
        }

        /// `dry` is the song's own volume, before the effects (so their tails carry on after it).
        func set(rate: Double, dry: Float, bass: Float, mid: Float, high: Float, lowPass: Float, highPass: Float,
                 reverb wet: Float, echo: Float, effects: Bool) {
            pitch.rate = Float(rate)
            eq.globalGain = dry > 0.000_02 ? max(-96, 20 * log10(dry)) : -96
            let bands = eq.bands
            // As `MixFilters` has them, which the planner expects.
            bands[0].gain = effects ? MixFilters.bassShelfGain(cut: bass) : 0
            bands[1].gain = effects ? -24 * mid : 0
            bands[2].gain = effects ? -30 * high : 0
            bands[3].bypass = !effects || lowPass <= 0.001
            bands[3].frequency = MixFilters.lowPassFrequency(lowPass)
            bands[4].bypass = !effects || highPass <= 0.001
            bands[4].frequency = MixFilters.highPassFrequency(highPass)
            reverb.wetDryMix = effects ? 100 * wet : 0
            delay.wetDryMix = effects ? 50 * echo : 0
        }
    }

    /// The noise sweep's state, read by its render block (on the rendering thread only).
    private final class NoiseSource {
        var level: Float = 0
        var state: UInt32 = 0x1234_5678
    }

    /// The song leaving with a stretch of beats repeated from `loop.start` (its own time) to the
    /// end of the buffer, each repeat joined with a 3 ms crossfade.
    private static func looped(_ buffer: AVAudioPCMBuffer, from handover: Double, loop: MixLoopPlan) -> AVAudioPCMBuffer {
        let rate = MixSchedule.sampleRate
        let total = Int(buffer.frameLength)
        let end = Int(((loop.start - handover) * rate).rounded())
        let length = Int((loop.length * rate).rounded())
        let fade = Int(0.003 * rate)
        guard length > 4 * fade, end - length > 0, end < total,
              let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity),
              let source = buffer.floatChannelData, let target = out.floatChannelData else { return buffer }
        out.frameLength = buffer.frameLength
        for channel in 0..<Int(buffer.format.channelCount) {
            let from = source[channel], to = target[channel]
            to.update(from: from, count: end)
            var position = end
            while position < total {
                let count = min(length, total - position)
                for frame in 0..<count {
                    var value = from[end - length + frame]
                    // Into each repeat: fade in over 3 ms from where the previous one would carry on.
                    if frame < fade {
                        let weight = Float(frame) / Float(fade)
                        value = value * weight + from[min(total - 1, end + frame)] * (1 - weight)
                    }
                    to[position + frame] = value
                }
                position += count
            }
        }
        return out
    }

    private static func write(_ buffer: AVAudioPCMBuffer, from start: Int, count: Int, to file: AVAudioFile) throws {
        guard start > 0 || count < Int(buffer.frameLength) else { return try file.write(from: buffer) }
        guard let part = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(count)),
              let source = buffer.floatChannelData, let target = part.floatChannelData else { throw RenderError.engine }
        part.frameLength = AVAudioFrameCount(count)
        for channel in 0..<Int(buffer.format.channelCount) {
            (target[channel]).update(from: source[channel] + start, count: count)
        }
        try file.write(from: part)
    }

    /// A stretch of a song's audio as 44.1 kHz stereo, starting exactly at `start` (its own time).
    static func decode(_ url: URL, from start: Double, duration: Double) async throws -> AVAudioPCMBuffer {
        let rate = MixSchedule.sampleRate
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw RenderError.noAudio }
        let reader = try AVAssetReader(asset: asset)
        // A little earlier than needed: the decoder's first buffer tells where it really starts.
        let from = max(0, start - 0.5)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 44_100),
                                       duration: CMTime(seconds: duration + (start - from), preferredTimescale: 44_100))
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
        var interleaved: [Float] = []
        interleaved.reserveCapacity(Int((duration + 1) * rate) * 2)
        var firstTime: Double?
        var chunk: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            if firstTime == nil { firstTime = CMSampleBufferGetPresentationTimeStamp(sample).seconds }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let count = length / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            if chunk.count < count { chunk = [Float](repeating: 0, count: count) }
            let status = chunk.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size,
                                           destination: bytes.baseAddress!)
            }
            guard status == noErr else { continue }
            interleaved.append(contentsOf: chunk[0..<count])
        }
        guard reader.status == .completed, let firstTime, firstTime.isFinite else { throw reader.error ?? RenderError.unreadable }
        let skip = max(0, Int(((start - firstTime) * rate).rounded()))
        let frames = max(0, interleaved.count / 2 - skip)
        guard frames > 0, let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData else { throw RenderError.noAudio }
        buffer.frameLength = AVAudioFrameCount(frames)
        let left = channels[0], right = channels[1]
        interleaved.withUnsafeBufferPointer { source in
            for frame in 0..<frames {
                left[frame] = source[(skip + frame) * 2]
                right[frame] = source[(skip + frame) * 2 + 1]
            }
        }
        return buffer
    }
}
