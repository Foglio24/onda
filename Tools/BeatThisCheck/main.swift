// Checks Beat This! as the app runs it against upstream's PyTorch inference (the fixture written by
// Tools/convert_beat_model.py): a test signal at 128 BPM then 100 BPM, its log-mel spectrogram and
// the beat and downbeat logits of every frame.
import CoreML
import Foundation

var failures = 0
func expect(_ condition: Bool, _ message: String) {
    print(condition ? "ok   \(message)" : "FAIL \(message)")
    if !condition { failures += 1 }
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    print("usage: BeatThisCheck <BeatThis.mlmodelc> <beat-fixture.bin>")
    exit(2)
}
guard let data = FileManager.default.contents(atPath: arguments[2]), data.count > 16 else {
    print("BeatThisCheck: no fixture")
    exit(1)
}
func ints(_ offset: Int) -> Int32 { data.subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) } }
func floats(_ offset: Int, _ count: Int) -> [Float] {
    data.subdata(in: offset..<(offset + 4 * count)).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}
let samples = Int(ints(0)), frames = Int(ints(4)), mels = Int(ints(8)), logitCount = Int(ints(12))
var offset = 16
let audio = floats(offset, samples); offset += 4 * samples
let spect = floats(offset, frames * mels); offset += 4 * frames * mels
let beatRef = floats(offset, logitCount); offset += 4 * logitCount
let downRef = floats(offset, logitCount)
print("fixture: \(samples) samples, \(frames) frames of \(mels) bands")

// The front end.
let (mine, myFrames) = BeatThisFrontEnd.spectrogram(audio)
expect(myFrames == frames && mels == BeatThis.mels, "the spectrogram has upstream's \(frames) frames of 128 bands (\(myFrames))")
if myFrames == frames {
    var worst: Float = 0
    for index in 0..<mine.count { worst = max(worst, abs(mine[index] - spect[index])) }
    expect(worst < 2e-3, "the log-mel spectrogram matches upstream's (largest difference \(worst))")
}

// The model, run in chunks on upstream's spectrogram.
let model: BeatThis
do {
    model = try BeatThis(modelURL: URL(fileURLWithPath: arguments[1]), computeUnits: .cpuOnly)
} catch {
    print("FAIL the model doesn't load: \(error)")
    exit(1)
}
expect(BeatThis.chunkStarts(frames: frames) == [-6, 907], "chunks as upstream splits \(frames) frames (\(BeatThis.chunkStarts(frames: frames)))")
let started = Date()
guard let (beat, down) = try? model.logits(spect, frames: frames) else {
    print("FAIL the model doesn't run")
    exit(1)
}
print(String(format: "inference: %.2f s for %.0f s of audio (CPU)", Date().timeIntervalSince(started), Double(samples) / 22_050))
var worstBeat: Float = 0, worstDown: Float = 0
for index in 0..<frames {
    worstBeat = max(worstBeat, abs(beat[index] - beatRef[index]))
    worstDown = max(worstDown, abs(down[index] - downRef[index]))
}
expect(worstBeat < 0.05 && worstDown < 0.05, "logits match upstream's (largest difference \(worstBeat), \(worstDown))")

// The peaks: the same beats from the app's logits as from upstream's.
let reference = BeatThis.result(beat: beatRef, downbeat: downRef)
let result = BeatThis.result(beat: beat, downbeat: down)
let beatShift = zip(result.beats, reference.beats).map { abs($0 - $1) }.max() ?? 1
expect(result.beats.count == reference.beats.count && beatShift < 0.005,
       "the same \(reference.beats.count) beats (\(result.beats.count), largest shift \(Int(beatShift * 1000)) ms)")
expect(result.downbeats.count == reference.downbeats.count, "the same \(reference.downbeats.count) downbeats (\(result.downbeats.count))")

// What they say about the signal: 128 BPM, then 100 BPM, a downbeat every four beats.
func median(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.sorted()[values.count / 2] }
var gaps: [(time: Double, gap: Double)] = []
for index in result.beats.indices.dropFirst() { gaps.append((result.beats[index - 1], result.beats[index] - result.beats[index - 1])) }
let first = 60 / median(gaps.filter { $0.time > 5 && $0.time < 26 }.map(\.gap))
let second = 60 / median(gaps.filter { $0.time > 31 }.map(\.gap))
expect(abs(first - 128) < 2.5 && abs(second - 100) < 2, String(format: "the tempos: %.1f and %.1f BPM", first, second))
var bars: [Double] = []
for index in result.downbeats.indices.dropFirst() where result.downbeats[index] - result.downbeats[index - 1] < 3 {
    bars.append(result.downbeats[index] - result.downbeats[index - 1])
}
let barMedian = median(bars)
expect(abs(barMedian - 4 * 60 / 128.0) < 0.05 || abs(barMedian - 4 * 60 / 100.0) < 0.05,
       String(format: "a downbeat every four beats (median bar %.3f s)", barMedian))

// The whole way, as AutoMix runs it: from the samples.
if let whole = try? model.analyze(audio) {
    let shift = zip(whole.beats, reference.beats).map { abs($0 - $1) }.max() ?? 1
    expect(whole.beats.count == reference.beats.count && shift < 0.01, "from the samples, the same beats (largest shift \(Int(shift * 1000)) ms)")
} else {
    expect(false, "the model runs from the samples")
}

if failures > 0 {
    print("BeatThisCheck: \(failures) failed")
    exit(1)
}
print("BeatThisCheck passed")
