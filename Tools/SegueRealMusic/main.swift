// AutoMix's live transitions on real songs: each song of the JamendoLyrics dataset (Creative Commons)
// analysed as the app does (TrackAnalyzer) and run through Beat This! (the app's Core ML model); then,
// for each pair of songs that follow each other in the list, the level SeguePolicy reaches on the
// analysis' grid alone and on the model's beats, with why the levels above weren't used. It measures
// what the model changes, not how a mix sounds. Voices aren't measured here (the app measures them
// near the junction), so the voice guard can't refuse a candidate, as on a device without the
// karaoke's model.
import AVFoundation
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    print("usage: SegueRealMusic <BeatThis.mlmodelc> <jamendolyrics> [songs]")
    exit(2)
}
let modelURL = URL(fileURLWithPath: arguments[1])
let dataset = URL(fileURLWithPath: arguments[2])
let limit = arguments.count > 3 ? Int(arguments[3]) ?? 40 : 40

/// A file's audio as mono samples at 22,050 Hz, as the app's AutoMixDecoder makes them.
func samples(of url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: TrackAnalyzer.sampleRate, channels: 1, interleaved: false),
          let converter = AVAudioConverter(from: file.processingFormat, to: target) else { return [] }
    var output: [Float] = []
    let chunk: AVAudioFrameCount = 32_768
    var finished = false
    while !finished {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: chunk) else { break }
        var error: NSError?
        let status = converter.convert(to: buffer, error: &error) { count, state in
            guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count),
                  (try? file.read(into: input, frameCount: count)) != nil, input.frameLength > 0 else {
                state.pointee = .endOfStream
                return nil
            }
            state.pointee = .haveData
            return input
        }
        if let data = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            output.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        }
        if status == .endOfStream || status == .error || buffer.frameLength == 0 { finished = true }
    }
    return output
}

let csv = (try? String(contentsOf: dataset.appending(path: "JamendoLyrics.csv"), encoding: .utf8)) ?? ""
let rows = csv.split(separator: "\n").dropFirst().map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
let files = rows.compactMap { row -> String? in row.first { $0.hasSuffix(".mp3") } }
    .filter { FileManager.default.fileExists(atPath: dataset.appending(path: "mp3/\($0)").path) }
    .sorted().prefix(limit)
print("\(files.count) songs")

guard let model = try? BeatThis(modelURL: modelURL) else {
    print("SegueRealMusic: the model doesn't load")
    exit(1)
}

struct Song {
    let name: String
    let grid: TrackAnalysis
    let modelled: TrackAnalysis
}
var songs: [Song] = []
var modelSeconds = 0.0, audioSeconds = 0.0
for name in files {
    guard let mono = try? samples(of: dataset.appending(path: "mp3/\(name)")), mono.count > 22_050 * 30,
          let analysis = TrackAnalyzer.analyze(mono, sampleRate: TrackAnalyzer.sampleRate) else {
        print("skipped \(name)")
        continue
    }
    let started = Date()
    guard let found = try? model.analyze(mono) else {
        print("the model failed on \(name)")
        continue
    }
    modelSeconds += Date().timeIntervalSince(started)
    audioSeconds += Double(mono.count) / 22_050
    var modelled = analysis
    modelled.modelBeats = found.beats.map { Float($0) }
    modelled.modelDownbeats = found.downbeats.map { Float($0) }
    modelled.modelDownbeatLogits = found.downbeatLogits
    let song = SegueSong(modelled, voices: nil)
    let gaps = zip(found.beats.dropFirst(), found.beats).map { $0 - $1 }.sorted()
    let modelBPM = gaps.isEmpty ? 0 : 60 / gaps[gaps.count / 2]
    let sure = (song.barDown ?? []).filter { $0 >= 0.5 }.count
    print(String(format: "%@: grid %.1f BPM fit %.2f; model %.1f BPM, %d beats, %d bars (%d sure), metre %.2f/%.2f",
                 name, analysis.tempo, analysis.gridFit, modelBPM, found.beats.count, song.bars, sure, song.headMetre, song.tailMetre))
    songs.append(Song(name: name, grid: analysis, modelled: modelled))
}
print(String(format: "Beat This! on the build Mac: %.1f s for %.0f min of music", modelSeconds, audioSeconds / 60))

var counts: [String: (grid: Int, model: Int)] = [:]
for level in SegueLevel.allCases { counts[level.rawValue] = (0, 0) }
for (a, b) in zip(songs, songs.dropFirst()) {
    let grid = SeguePolicy.decide(SegueRequest(outgoing: SegueSong(a.grid, voices: nil), incoming: SegueSong(b.grid, voices: nil)))
    let modelled = SeguePolicy.decide(SegueRequest(outgoing: SegueSong(a.modelled, voices: nil), incoming: SegueSong(b.modelled, voices: nil)))
    counts[grid.level.rawValue]!.grid += 1
    counts[modelled.level.rawValue]!.model += 1
    func plan(_ decision: SegueDecision) -> String {
        guard let plan = decision.plan else { return decision.level.rawValue }
        let bars = plan.bars.map { "\($0) bars, " } ?? ""
        let phase = plan.phaseMedian.map { String(format: ", phase %.0f/%.0f ms", $0 * 1000, (plan.phaseP95 ?? 0) * 1000) } ?? ""
        return "\(plan.level.rawValue) \(plan.shape.rawValue) (\(bars)\(String(format: "%.1f s, rate %.3f", plan.length, plan.rate))\(phase))"
    }
    print("\n\(a.name) → \(b.name)")
    print("  grid:  \(plan(grid)) — \(grid.why)")
    print("  model: \(plan(modelled)) — \(modelled.why)")
}
print("\nLevels over \(max(0, songs.count - 1)) pairs (grid → model):")
for level in SegueLevel.allCases {
    let count = counts[level.rawValue]!
    print("  \(level.rawValue): \(count.grid) → \(count.model)")
}
