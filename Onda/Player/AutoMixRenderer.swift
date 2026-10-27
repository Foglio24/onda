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
    }

    enum RenderError: Error {
        case noAudio
        case unreadable
        case engine
    }

    /// `effects` false leaves out the filters (for checks that look at the beats).
    static func render(_ schedule: MixSchedule, outgoing: URL, incoming: URL, outgoingGain: Float,
                       incomingGain: Float, to destination: URL, effects: Bool = true) async throws -> Mix {
        let rate = MixSchedule.sampleRate
        let plan = schedule.plan
        let outgoingAudio = try await decode(outgoing, from: plan.handover, duration: plan.outEnd - plan.handover + 2)
        let incomingAudio = try await decode(incoming, from: plan.inStart, duration: schedule.join - plan.inStart + 2)
        try Task.checkCancellation()

        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { throw RenderError.engine }
        let engine = AVAudioEngine()
        let block = MixSchedule.blockFrames
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: AVAudioFrameCount(block))
        let decks = [Deck(), Deck()]
        for deck in decks {
            engine.attach(deck.player)
            engine.attach(deck.pitch)
            engine.attach(deck.eq)
            engine.connect(deck.player, to: deck.pitch, format: format)
            engine.connect(deck.pitch, to: deck.eq, format: format)
            engine.connect(deck.eq, to: engine.mainMixerNode, format: format)
        }
        // Two songs at once can go over full scale: a peak limiter keeps them from clipping.
        let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
        engine.attach(limiter)
        engine.connect(engine.mainMixerNode, to: limiter, format: format)
        engine.connect(limiter, to: engine.outputNode, format: format)
        try engine.start()
        defer { engine.stop() }

        // The next song's player starts when, by its own clock, the mix reaches the entry.
        decks[0].player.scheduleBuffer(outgoingAudio, at: nil, options: [], completionHandler: nil)
        let entry = AVAudioFramePosition((schedule.incomingClockAtEntry * rate).rounded())
        decks[1].player.scheduleBuffer(incomingAudio, at: AVAudioTime(sampleTime: entry, atRate: rate), options: [],
                                       completionHandler: nil)
        decks[0].player.play()
        decks[1].player.play()

        // The stretchers hold back a little audio: that much is rendered extra at the start and left
        // out, so the file begins exactly at the handover. Rates follow the mix clock; volumes and
        // filters follow what is being heard.
        let latency = decks[0].pitch.latency + decks[0].eq.latency + limiter.latency
        let latencyFrames = max(0, Int((latency * rate).rounded()))
        let total = schedule.steps.count * block + latencyFrames
        guard let output = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                            frameCapacity: AVAudioFrameCount(block)) else { throw RenderError.engine }
        let file = try AVAudioFile(forWriting: destination, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        var rendered = 0
        var written = 0
        while rendered < total {
            if rendered % (block * 256) == 0 { try Task.checkCancellation() }
            let time = Double(rendered) / rate
            let pace = schedule.step(at: time)
            let heard = schedule.step(at: max(0, time - latency)).levels
            decks[0].set(rate: pace.outgoingRate, volume: heard.outgoing * outgoingGain, bassCut: heard.outgoingBassCut,
                         highPass: heard.outgoingHighPass, effects: effects)
            decks[1].set(rate: pace.incomingRate, volume: heard.incoming * incomingGain, bassCut: heard.incomingBassCut,
                         highPass: 0, effects: effects)
            let frames = min(block, total - rendered)
            let status = try engine.renderOffline(AVAudioFrameCount(frames), to: output)
            guard status == .success else { throw RenderError.engine }
            let skip = max(0, latencyFrames - rendered)
            if skip < frames {
                try write(output, from: skip, count: frames - skip, to: file)
                written += frames - skip
            }
            rendered += frames
        }
        return Mix(url: destination, length: Double(written) / rate, join: schedule.join)
    }

    /// One song's chain in the mix.
    private final class Deck {
        let player = AVAudioPlayerNode()
        let pitch = AVAudioUnitTimePitch()
        let eq = AVAudioUnitEQ(numberOfBands: 2)

        init() {
            let shelf = eq.bands[0]
            shelf.filterType = .lowShelf
            shelf.frequency = 150
            shelf.gain = 0
            shelf.bypass = false
            let highPass = eq.bands[1]
            highPass.filterType = .highPass
            highPass.frequency = 20
            highPass.bypass = true
        }

        func set(rate: Double, volume: Float, bassCut: Float, highPass: Float, effects: Bool) {
            pitch.rate = Float(rate)
            player.volume = volume
            eq.bands[0].gain = effects ? -30 * bassCut : 0
            eq.bands[1].bypass = !effects || highPass <= 0.001
            // 20 Hz to 1.2 kHz, evenly in pitch.
            eq.bands[1].frequency = Float(20 * pow(60, Double(highPass)))
        }
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
