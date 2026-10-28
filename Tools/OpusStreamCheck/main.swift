// Plays Opus while it arrives (see OpusStream), on a WebM made here like YouTube's: a test signal
// encoded with Apple's Opus encoder, in clusters of SimpleBlocks after the head and an index.
// The progressive parser finds the same packets as the whole-file one, whatever the pieces; the
// PCM decoded piece by piece is the PCM of the whole-file conversion (to Apple Lossless); the
// first half second is ready after the first kilobytes; a prepared stream stops after its first
// range and carries on when resumed; and AVPlayer opens the stream through the resource loader
// (WAV, its length, a seek), where it can play here.
// Run from the repository root: bash Tools/OpusStreamCheck/run.sh
import AVFoundation
import Foundation

var failures = 0
func expect(_ condition: Bool, _ message: String) {
    print(condition ? "ok   \(message)" : "FAIL \(message)")
    if !condition { failures += 1 }
}

func format(_ value: Double, _ digits: Int = 1) -> String { String(format: "%.\(digits)f", value) }
func milliseconds(_ seconds: TimeInterval) -> String { "\(Int((seconds * 1000).rounded())) ms" }

// MARK: A test signal, encoded with Apple's Opus encoder

let rate = 48_000.0
let seconds = 12.0
let frames = Int(seconds * rate)

func signal() -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    var noise: UInt32 = 12_345
    for frame in 0..<frames {
        let t = Double(frame) / rate
        // A chord, a kick every half second and a little noise.
        var value = 0.2 * sin(2 * .pi * 220 * t) + 0.15 * sin(2 * .pi * 277.2 * t) + 0.1 * sin(2 * .pi * 329.6 * t)
        let beat = t.truncatingRemainder(dividingBy: 0.5)
        value += 0.5 * sin(2 * .pi * (50 + 80 * exp(-beat * 30)) * beat) * exp(-beat * 12)
        noise = noise &* 1_664_525 &+ 1_013_904_223
        value += 0.02 * (Double(noise >> 8) / Double(1 << 24) * 2 - 1)
        buffer.floatChannelData![0][frame] = Float(value)
        buffer.floatChannelData![1][frame] = Float(value * 0.9)
    }
    return buffer
}

func encode(_ pcm: AVAudioPCMBuffer) -> (packets: [Data], preSkip: Int)? {
    var description = AudioStreamBasicDescription(
        mSampleRate: rate, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
        mFramesPerPacket: 960, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
    guard let opus = AVAudioFormat(streamDescription: &description),
          let converter = AVAudioConverter(from: pcm.format, to: opus) else { return nil }
    converter.bitRate = 128_000
    var given = false
    var packets: [Data] = []
    while true {
        let output = AVAudioCompressedBuffer(format: opus, packetCapacity: 64,
                                             maximumPacketSize: max(1, converter.maximumOutputPacketSize))
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if given {
                inputStatus.pointee = .endOfStream
                return nil
            }
            given = true
            inputStatus.pointee = .haveData
            return pcm
        }
        if status == .error { return nil }
        for index in 0..<Int(output.packetCount) {
            guard let description = output.packetDescriptions?[index] else { continue }
            packets.append(Data(bytes: output.data.advanced(by: Int(description.mStartOffset)),
                                count: Int(description.mDataByteSize)))
        }
        if status == .endOfStream || (status == .inputRanDry && output.packetCount == 0) { break }
    }
    return (packets, Int(converter.primeInfo.leadingFrames))
}

// MARK: A WebM like YouTube's

func vint(_ value: Int) -> [UInt8] {
    // Eight-byte sizes: valid EBML, and simple.
    [0x01] + (0..<7).map { UInt8((value >> (8 * (6 - $0))) & 0xFF) }
}

func element(_ id: UInt32, _ body: [UInt8]) -> [UInt8] {
    var bytes: [UInt8] = []
    var started = false
    for shift in stride(from: 24, through: 0, by: -8) {
        let byte = UInt8((id >> UInt32(shift)) & 0xFF)
        if byte != 0 || started || shift == 0 {
            bytes.append(byte)
            started = true
        }
    }
    return bytes + vint(body.count) + body
}

func uint(_ id: UInt32, _ value: Int, bytes count: Int = 4) -> [UInt8] {
    element(id, (0..<count).map { UInt8((value >> (8 * (count - 1 - $0))) & 0xFF) })
}

func webm(_ packets: [Data], preSkip: Int, duration: Double) -> Data {
    let ebml = element(0x1A45_DFA3, uint(0x4286, 1, bytes: 1) + uint(0x42F7, 1, bytes: 1) + uint(0x42F2, 4, bytes: 1)
                       + uint(0x42F3, 8, bytes: 1) + element(0x4282, Array("webm".utf8))
                       + uint(0x4287, 4, bytes: 1) + uint(0x4285, 2, bytes: 1))
    let info = element(0x1549_A966, uint(0x2A_D7B1, 1_000_000)
                       + element(0x4489, withUnsafeBytes(of: (duration * 1000).bitPattern.bigEndian) { Array($0) }))
    var opusHead = Array("OpusHead".utf8) + [1, 2, UInt8(preSkip & 0xFF), UInt8(preSkip >> 8)]
    opusHead += [0x80, 0xBB, 0, 0, 0, 0, 0]
    let track = element(0xAE, uint(0xD7, 1, bytes: 1) + uint(0x83, 2, bytes: 1) + element(0x86, Array("A_OPUS".utf8))
                        + element(0x63A2, opusHead))
    let tracks = element(0x1654_AE6B, track)
    // An index the parser has to skip.
    let cues = element(0x1C53_BB6B, Array(repeating: 0xEC, count: 300))
    var clusters: [UInt8] = []
    let perCluster = 250 // five seconds
    for first in stride(from: 0, to: packets.count, by: perCluster) {
        let time = first * 20
        var body = uint(0xE7, time)
        for index in first..<min(packets.count, first + perCluster) {
            let relative = UInt16(index * 20 - time)
            body += element(0xA3, [0x81, UInt8(relative >> 8), UInt8(relative & 0xFF), 0x80] + [UInt8](packets[index]))
        }
        clusters += element(0x1F43_B675, body)
    }
    // The segment's size unknown, as in a stream.
    let segment: [UInt8] = [0x18, 0x53, 0x80, 0x67, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
    return Data(ebml + segment + info + tracks + cues + clusters)
}

func samples(of url: URL) -> [Int16]? {
    guard let file = try? AVAudioFile(forReading: url),
          let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
          (try? file.read(into: buffer)) != nil, let data = buffer.floatChannelData else { return nil }
    let channels = Int(file.processingFormat.channelCount)
    var out = [Int16](repeating: 0, count: Int(buffer.frameLength) * channels)
    for frame in 0..<Int(buffer.frameLength) {
        for channel in 0..<channels {
            out[frame * channels + channel] = Int16(max(-32_768, min(32_767, (data[channel][frame] * 32_768).rounded())))
        }
    }
    return out
}

@main
struct OpusStreamCheck {
    static func main() async {
        let folder = FileManager.default.temporaryDirectory.appending(path: "opus-stream-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        guard let encoded = encode(signal()), encoded.packets.count > 500 else {
            expect(false, "Apple's Opus encoder made the test signal")
            exit(1)
        }
        let file = webm(encoded.packets, preSkip: encoded.preSkip, duration: seconds)
        print("     test file: \(encoded.packets.count) packets, pre-skip \(encoded.preSkip), \(file.count / 1024) KB")

        // The progressive parser finds the whole-file parser's packets, whatever the pieces.
        let whole = try? WebMDemuxer.opusTrack(in: file)
        for size in [1, 7, 333, 4_096, 65_536, 1 << 20] {
            var parser = WebMStreamParser()
            var packets: [Data] = []
            var offset = 0
            var failed = false
            while offset < file.count {
                let end = min(file.count, offset + size)
                guard let found = try? parser.append(file.subdata(in: offset..<end)) else {
                    failed = true
                    break
                }
                packets += found.map(\.data)
                offset = end
            }
            expect(!failed && packets == whole?.packets && parser.head.preSkip == encoded.preSkip
                   && abs((parser.head.duration ?? 0) - seconds) < 0.001 && parser.consumed == file.count,
                   "pieces of \(size) bytes: the same \(packets.count) packets, pre-skip and length")
        }
        var notWebM = WebMStreamParser()
        expect((try? notWebM.append(Data("RIFF\u{0}\u{0}\u{0}\u{0}WAVE".utf8))) == nil, "a file that isn't WebM is refused")

        // The whole-file conversion (as up to 1.15), the reference.
        let webmURL = folder.appending(path: "test.webm")
        let reference = folder.appending(path: "reference.m4a")
        try? file.write(to: webmURL)
        do {
            try OpusPipeline.transcode(webm: webmURL, to: reference)
        } catch {
            expect(false, "whole-file conversion (\(error))")
        }
        let expected = samples(of: reference) ?? []

        // Piece by piece: the same PCM, the first half second after a few kilobytes.
        for chunk in [997, 16_384] {
            let destination = folder.appending(path: "stream-\(chunk).wav")
            let stream = OpusStream(source: .local(file, chunk: chunk), destination: destination, duration: nil,
                                    firstRange: 64 << 10)
            stream.start()
            do {
                try await stream.waitForAudio(seconds: 0.5)
                let timing = stream.timing
                let first = (timing.firstAudio ?? 0) - (timing.started ?? 0)
                let url = try await stream.completedFile()
                let got = samples(of: url) ?? []
                let frames = min(got.count, expected.count)
                var worst = 0
                for index in 0..<frames { worst = max(worst, abs(Int(got[index]) - Int(expected[index]))) }
                expect(url == destination && abs(got.count - expected.count) <= 2 * 960 && frames > Int(rate) && worst <= 2,
                       "pieces of \(chunk) bytes: the PCM of the whole-file conversion (\(got.count / 2) frames, "
                       + "\(expected.count / 2) expected, largest difference \(worst)), first audio after \(milliseconds(first))")
            } catch {
                expect(false, "pieces of \(chunk) bytes: decoded (\(error))")
            }
        }

        // Prepared: only the first range, then the rest once resumed.
        let prepared = OpusStream(source: .local(file, chunk: 4_096), destination: nil, duration: nil, firstRange: 64 << 10)
        prepared.start(prepareOnly: true)
        try? await prepared.waitForAudio(seconds: 1)
        try? await Task.sleep(for: .milliseconds(300))
        let early = prepared.decodedSeconds
        prepared.resume()
        let finished = try? await prepared.completedFile()
        expect(early > 1 && early < 6 && finished != nil && prepared.decodedSeconds > seconds - 0.1,
               "prepared: \(format(early)) s decoded from the first range, all \(format(prepared.decodedSeconds)) s once resumed")
        if let finished { try? FileManager.default.removeItem(at: finished) }

        // A cancelled stream gives up, and says so.
        let cancelled = OpusStream(source: .local(file, chunk: 512), destination: nil, duration: nil, firstRange: 64 << 10)
        cancelled.start(prepareOnly: true)
        try? await cancelled.waitForAudio(seconds: 0.2)
        cancelled.cancel()
        let refused = (try? await cancelled.completedFile()) == nil
        expect(refused && cancelled.failure != nil, "a cancelled stream ends with an error")

        // AVPlayer through the resource loader: a WAV of the right length, opened while it decodes.
        let playing = OpusStream(source: .local(file, chunk: 8_192), destination: nil, duration: nil, firstRange: 64 << 10)
        playing.start()
        let item = playing.makeItem()
        let opened = Date()
        let duration = try? await item.asset.load(.duration)
        let tracks = (try? await item.asset.loadTracks(withMediaType: .audio)) ?? []
        expect(abs((duration?.seconds ?? 0) - seconds) < 0.05 && tracks.count == 1,
               "AVFoundation opens the stream: \(format(duration?.seconds ?? 0, 3)) s, \(tracks.count) audio track, "
               + "in \(milliseconds(Date().timeIntervalSince(opened)))")
        let player = AVPlayer(playerItem: item)
        var waited = 0
        while item.status == .unknown, waited < 50 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        expect(item.status == .readyToPlay, "the item is ready to play after \(waited * 100) ms (\(item.error.map { "\($0)" } ?? "no error"))")
        player.playImmediately(atRate: 1)
        try? await Task.sleep(for: .seconds(1.5))
        let advanced = player.currentTime().seconds
        // Without a sound card (some build machines) AVPlayer doesn't move: only reported.
        print("     playing: \(format(advanced, 2)) s after 1.5 s (\(player.timeControlStatus == .playing ? "playing" : "not playing"))")
        let sought = await item.seek(to: CMTime(seconds: 8, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        expect(sought, "seeks to 8 s in the stream")
        player.pause()
        _ = try? await playing.completedFile()

        print(failures == 0 ? "OpusStreamCheck: all checks passed" : "OpusStreamCheck: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
