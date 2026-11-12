// Checks LocalPlayable: a song AVPlayer won't open is decoded by the app into a PCM copy that has the
// same length, rate, channels and samples (to the depth it was kept at), whatever the container, with no
// video and no cover; the copy is made once, and what can't be decoded gives nil.
// Run from the repository root: bash Tools/LocalPlayableCheck/run.sh
import AVFoundation
import Foundation

var failures = 0
func expect(_ condition: Bool, _ message: String) {
    print(condition ? "ok   \(message)" : "FAIL \(message)")
    if !condition { failures += 1 }
}

let work = FileManager.default.temporaryDirectory.appending(path: "seaglass-local-playable-\(UUID().uuidString)", directoryHint: .isDirectory)
let cache = work.appending(path: "cache", directoryHint: .isDirectory)
try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

/// A stereo tone (440 Hz left, 660 Hz right) written as `file`, in the given container settings.
func write(_ name: String, rate: Double, seconds: Double, settings: [String: Any]) throws -> (URL, [Float], [Float]) {
    let url = work.appending(path: name)
    let frames = Int(rate * seconds)
    var left = [Float](repeating: 0, count: frames), right = left
    for i in 0..<frames {
        left[i] = Float(0.5 * sin(2 * Double.pi * 440 * Double(i) / rate))
        right[i] = Float(0.4 * sin(2 * Double.pi * 660 * Double(i) / rate))
    }
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    left.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: frames) }
    right.withUnsafeBufferPointer { buffer.floatChannelData![1].update(from: $0.baseAddress!, count: frames) }
    try file.write(from: buffer)
    return (url, left, right)
}

func pcm(depth: Int, rate: Double) -> [String: Any] {
    [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: depth,
     AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
}

func samples(of url: URL) throws -> (rate: Double, channels: Int, left: [Float], right: [Float]) {
    let file = try AVAudioFile(forReading: url)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    let n = Int(buffer.frameLength)
    let l = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: n))
    let r = Array(UnsafeBufferPointer(start: buffer.floatChannelData![1], count: n))
    return (file.processingFormat.sampleRate, Int(file.processingFormat.channelCount), l, r)
}

for (name, depth, rate) in [("a16.wav", 16, 44_100.0), ("b24.caf", 24, 48_000.0), ("c24-96k.aiff", 24, 96_000.0)] {
    do {
        let (url, left, right) = try write(name, rate: rate, seconds: 3, settings: pcm(depth: depth, rate: rate))
        let copy = await LocalPlayable.copy(of: url, key: "local-\(name)", in: cache)
        guard let copy else { expect(false, "\(name): no copy made"); continue }
        let heard = try samples(of: copy)
        expect(copy.pathExtension == "caf", "\(name): the copy is a CAF")
        expect(heard.rate == rate && heard.channels == 2, "\(name): \(Int(heard.rate)) Hz, \(heard.channels) channels, as it was")
        expect(heard.left.count == left.count, "\(name): the same length (\(heard.left.count) frames)")
        // The depth the copy was written at: 16 bits to 1/32768, 24 bits to 1/8388608 (a little more for rounding).
        let tolerance: Float = depth == 16 ? 1.0 / 16_000 : 1.0 / 4_000_000
        var worst: Float = 0
        for i in 0..<min(left.count, heard.left.count) {
            worst = max(worst, abs(left[i] - heard.left[i]), abs(right[i] - heard.right[i]))
        }
        expect(worst <= tolerance, "\(name): the samples agree to \(worst) (within \(tolerance))")
        // Once made, it is not made again.
        let again = await LocalPlayable.copy(of: url, key: "local-\(name)", in: cache)
        expect(again == copy, "\(name): the second time it is the same file")
    } catch {
        expect(false, "\(name): \(error)")
    }
}

// What isn't audio gives nothing, and leaves no half-made copy behind.
let bad = work.appending(path: "notmusic.mp3")
try Data(repeating: 7, count: 4_000).write(to: bad)
let none = await LocalPlayable.copy(of: bad, key: "local-bad", in: cache)
expect(none == nil, "a file that isn't audio gives no copy")
let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []).filter { $0.hasPrefix("writing-") || $0.contains("local-bad") }
expect(leftovers.isEmpty, "and leaves nothing behind (\(leftovers.count) files)")
let missing = await LocalPlayable.copy(of: work.appending(path: "gone.mp3"), key: "local-gone", in: cache)
expect(missing == nil, "a file that isn't there gives no copy")

// The copies kept are bounded.
for index in 0..<16 {
    let (url, _, _) = try write("many\(index).wav", rate: 22_050, seconds: 0.2, settings: pcm(depth: 16, rate: 22_050))
    _ = await LocalPlayable.copy(of: url, key: "local-many\(index)", in: cache)
}
let kept = ((try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []).filter { $0.hasSuffix(".caf") }.count
expect(kept <= 12, "no more than 12 copies are kept (\(kept))")

if failures > 0 {
    print("LocalPlayableCheck: \(failures) failed")
    exit(1)
}
print("LocalPlayableCheck passed")
