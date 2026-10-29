import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation
import MediaToolbox

// Probe the same two-track composition and audio-mix ramps used by PlayerController.
// It deliberately uses synthetic, non-silent inputs so a muted mix is detectable.
final class Capture {
    private let lock = NSLock()
    private var format = AudioStreamBasicDescription()
    private var sums: [Int: Double] = [:]
    private var counts: [Int: Int] = [:]

    func prepare(_ value: AudioStreamBasicDescription) {
        lock.lock(); format = value; lock.unlock()
    }

    func record(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int, start: Double) {
        guard frames > 0, start.isFinite else { return }
        lock.lock(); let f = format; lock.unlock()
        guard f.mSampleRate > 0 else { return }
        let isFloat = f.mFormatFlags & kAudioFormatFlagIsFloat != 0 && f.mBitsPerChannel == 32
        let isInt16 = f.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 && f.mBitsPerChannel == 16
        guard isFloat || isInt16 else { return }
        var localSums: [Int: Double] = [:], localCounts: [Int: Int] = [:]
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let channels = max(1, Int(buffer.mNumberChannels))
            let available = Int(buffer.mDataByteSize) / (Int(f.mBitsPerChannel) / 8 * channels)
            for frame in 0..<min(frames, available) {
                let bucket = Int(start + Double(frame) / f.mSampleRate)
                for channel in 0..<channels {
                    let index = frame * channels + channel
                    let sample = isFloat ? Double(data.assumingMemoryBound(to: Float.self)[index])
                        : Double(data.assumingMemoryBound(to: Int16.self)[index]) / 32768
                    localSums[bucket, default: 0] += sample * sample
                    localCounts[bucket, default: 0] += 1
                }
            }
        }
        lock.lock()
        for (bucket, sum) in localSums { sums[bucket, default: 0] += sum }
        for (bucket, count) in localCounts { counts[bucket, default: 0] += count }
        lock.unlock()
    }

    func report(_ label: String) {
        lock.lock()
        let keys = counts.keys.sorted()
        let values = keys.map { "\($0):\(String(format: "%.4f", sqrt((sums[$0] ?? 0) / Double(counts[$0] ?? 1))))" }
        let f = format
        lock.unlock()
        print("\(label) format=\(f.mBitsPerChannel) bits flags=\(f.mFormatFlags) rate=\(f.mSampleRate): \(values.joined(separator: ", "))")
    }

    func rms(_ second: Int) -> Double {
        lock.lock(); defer { lock.unlock() }
        return sqrt((sums[second] ?? 0) / Double(max(1, counts[second] ?? 0)))
    }
}

func tap(_ capture: Capture) -> MTAudioProcessingTap? {
    let context = Unmanaged.passRetained(capture).toOpaque()
    var callbacks = MTAudioProcessingTapCallbacks(
        version: kMTAudioProcessingTapCallbacksVersion_0, clientInfo: context,
        init: { _, clientInfo, storage in storage.pointee = clientInfo },
        finalize: { tap in Unmanaged<Capture>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
        prepare: { tap, _, format in
            Unmanaged<Capture>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().prepare(format.pointee)
        },
        unprepare: { _ in },
        process: { tap, frames, _, buffers, framesOut, flagsOut in
            var range = CMTimeRange()
            guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, &range, framesOut) == noErr else { return }
            let capture = Unmanaged<Capture>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
            capture.record(UnsafeMutableAudioBufferListPointer(buffers), frames: Int(framesOut.pointee), start: range.start.seconds)
        })
    var result: MTAudioProcessingTap?
    let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &result)
    if status != noErr || result == nil { Unmanaged<Capture>.fromOpaque(context).release() }
    return result
}

func writeTone(_ url: URL, frequency: Double, seconds: Double) throws {
    let rate = 44_100.0
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: rate, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false],
        commonFormat: .pcmFormatFloat32, interleaved: false)
    let count = AVAudioFrameCount(seconds * rate)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
    buffer.frameLength = count
    for index in 0..<Int(count) {
        let value = Float(0.2 * sin(2 * Double.pi * frequency * Double(index) / rate))
        buffer.floatChannelData![0][index] = value
        buffer.floatChannelData![1][index] = value
    }
    try file.write(from: buffer)
}

@MainActor
func makeItem(_ mixURL: URL, _ songURL: URL, lengthSeconds: Double = 6, joinSeconds: Double = 2,
              incomingGain: Float = 1, firstCapture: Capture, secondCapture: Capture,
              attachTaps: Bool = true) async -> AVPlayerItem {
    guard let parts = await AutoMixPlayback.compose(mixURL: mixURL, songURL: songURL, length: lengthSeconds,
        join: joinSeconds, incomingGain: incomingGain, crossing: 0, fade: AutoMixPlayback.handoverFade)
    else { fatalError("Could not create production AutoMix composition") }
    if attachTaps {
        parts.mixPart.audioTapProcessor = tap(firstCapture)
        parts.songPart.audioTapProcessor = tap(secondCapture)
    }
    let audioMix = AVMutableAudioMix()
    audioMix.inputParameters = [parts.mixPart, parts.songPart]
    let item = AVPlayerItem(asset: parts.composition)
    item.audioMix = audioMix
    return item
}

@main struct Probe {
    @MainActor static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let mixURL = folder.appendingPathComponent("mix.caf"), songURL = folder.appendingPathComponent("song.caf")
        try writeTone(mixURL, frequency: 440, seconds: 6)
        try writeTone(songURL, frequency: 660, seconds: 10)
        let first = Capture(), second = Capture()
        let item = await makeItem(mixURL, songURL, firstCapture: first, secondCapture: second, attachTaps: false)
        let tracks = try await item.asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: item.asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        output.audioMix = item.audioMix
        guard reader.canAdd(output) else { fatalError("Cannot add audio mix output") }
        reader.add(output)
        guard reader.startReading() else { fatalError("Cannot start reader: \(String(describing: reader.error))") }
        var sums = [Double](repeating: 0, count: 10), counts = [Int](repeating: 0, count: 10)
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let bytes = CMBlockBufferGetDataLength(block), number = bytes / MemoryLayout<Float>.size
            var samples = [Float](repeating: 0, count: number)
            let copied = samples.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!) }
            guard copied == noErr else { fatalError("Could not read samples") }
            let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            for frame in 0..<(number / 2) {
                let bucket = Int(start + Double(frame) / 44_100)
                guard sums.indices.contains(bucket) else { continue }
                for channel in 0..<2 { let x = Double(samples[2 * frame + channel]); sums[bucket] += x * x; counts[bucket] += 1 }
            }
        }
        guard reader.status == .completed else { fatalError("Reader failed: \(String(describing: reader.error))") }
        let rms = sums.indices.map { sqrt(sums[$0] / Double(max(1, counts[$0]))) }
        print("READER mixed RMS per second: \(rms)")
        first.report("READER first track tap")
        second.report("READER second track tap")
        guard rms[1...5].allSatisfy({ $0 > 0.05 }), rms[6] > 0.05 else { fatalError("Composition output is silent") }

        #if os(iOS)
        try AVAudioSession.sharedInstance().setCategory(.playback)
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
        let liveFirst = Capture(), liveSecond = Capture()
        let liveItem = await makeItem(mixURL, songURL, firstCapture: liveFirst, secondCapture: liveSecond)
        let player = AVPlayer(playerItem: liveItem)
        player.play()
        try await Task.sleep(for: .seconds(8))
        print("PLAYER time=\(liveItem.currentTime().seconds) itemStatus=\(liveItem.status.rawValue) playerStatus=\(player.timeControlStatus.rawValue) error=\(String(describing: liveItem.error))")
        liveFirst.report("PLAYER first track tap")
        liveSecond.report("PLAYER second track tap")
        guard liveFirst.rms(1) > 0.05, liveSecond.rms(6) > 0.05 else { fatalError("Player did not receive audible transition and song audio") }
        // Keep the original player running during rendering, as the app does.

        // Use the actual app renderer with a gapless transition and the user's approximate
        // normalized gains. Check the bytes read from disk as well as the in-memory levels.
        let outgoingURL = folder.appendingPathComponent("outgoing.caf")
        let renderedURL = folder.appendingPathComponent("rendered.caf")
        try writeTone(outgoingURL, frequency: 440, seconds: 10)
        var plan = TransitionPlan(style: .gapless, handover: 4, outStart: 6, outEnd: 6.25,
            inStart: 0.5, tempoOut: 120, tempoMeet: 120, tempoIn: 120, alignment: nil,
            swapStart: nil, swapEnd: nil, fadeIn: 1, filterOut: nil, bars: nil)
        plan.fadeInFrom = 0
        plan.fadeOutFrom = 0
        let rendered = try await AutoMixRenderer.render(MixSchedule(plan: plan), outgoing: outgoingURL,
            incoming: songURL, outgoingGain: Float(pow(10, -6.9 / 20)), incomingGain: Float(pow(10, -8.0 / 20)), to: renderedURL)
        player.pause()
        print("RENDER actual length=\(rendered.length) join=\(rendered.join) takeOver=\(String(describing: rendered.takeOver)) handBack=\(String(describing: rendered.handBack))")
        let actualFile = try AVAudioFile(forReading: renderedURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        let actualBuffer = AVAudioPCMBuffer(pcmFormat: actualFile.processingFormat, frameCapacity: AVAudioFrameCount(actualFile.length))!
        try actualFile.read(into: actualBuffer)
        let actualChannels = actualBuffer.floatChannelData!
        let actualRate = actualFile.processingFormat.sampleRate
        var actualRMS: [Double] = []
        for second in 0..<Int(rendered.length) {
            let start = Int(Double(second) * actualRate), end = min(Int(Double(second + 1) * actualRate), Int(actualBuffer.frameLength))
            var sum = 0.0
            for index in start..<end { let x = Double(actualChannels[0][index]); sum += x * x }
            actualRMS.append(sqrt(sum / Double(max(1, end - start))))
        }
        print("RENDER file RMS per second: \(actualRMS)")
        guard actualRMS.count >= 3, actualRMS.allSatisfy({ $0 > 0.01 }) else { fatalError("Actual rendered file is silent") }
        let realFirst = Capture(), realSecond = Capture()
        let realItem = await makeItem(renderedURL, songURL, lengthSeconds: rendered.length, joinSeconds: rendered.join,
                                          incomingGain: Float(pow(10, -8.0 / 20)), firstCapture: realFirst, secondCapture: realSecond)
        let realPlayer = AVPlayer(playerItem: realItem)
        realPlayer.play()
        try await Task.sleep(for: .seconds(5))
        print("RENDER PLAYER time=\(realItem.currentTime().seconds) status=\(realItem.status.rawValue) error=\(String(describing: realItem.error))")
        realFirst.report("RENDER PLAYER first track tap")
        realSecond.report("RENDER PLAYER second track tap")
        guard realFirst.rms(1) > 0.01, realSecond.rms(3) > 0.005 else { fatalError("Player did not receive the rendered mix and song") }
        realPlayer.pause()
    }
}
