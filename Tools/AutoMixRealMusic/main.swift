// AutoMix on real songs: the Creative Commons songs of the JamendoLyrics dataset whose licence
// allows derivative works (see CREDITS.txt in the output), with every sung word timed by hand.
//
// 1. Voices: the app's vocal detection (`VocalDetector`, the karaoke's model) on each song's start
//    and end, compared with the words' timings (phrases: words less than 0.75 s apart), with the
//    thresholds swept to see which fit best; and how long it takes.
// 2. Transitions: for representative pairs (dance at close tempos, sung pop, rap whose voice starts
//    at once, acoustic, tempos far apart, and a few more), the plan of up to 1.16 and the new
//    choice are both rendered by the app's renderer, from the same files at the same gains, with
//    the same stretch of each song around them. Each pair is written as X and Y in random order
//    for blind listening (KEY.txt says which is which: open it afterwards), with the choice's
//    reasons and measurements (loudness bumps and dips, peaks) in REPORT.txt.
//
// Nothing here says how it sounds: that takes listening. Apple Music can't be rendered here.
// Usage: AutoMixRealMusic <VocFT.mlmodelc> <JamendoLyrics folder> <output folder> [songs]
import AVFoundation
import CoreML
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 4 else {
    print("usage: AutoMixRealMusic <VocFT.mlmodelc> <JamendoLyrics folder> <output folder> [songs]")
    exit(2)
}
let modelURL = URL(fileURLWithPath: arguments[1])
let dataset = URL(fileURLWithPath: arguments[2])
let output = URL(fileURLWithPath: arguments[3])
let songLimit = arguments.count > 4 ? Int(arguments[4]) ?? 1000 : 1000
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func format(_ value: Double, _ digits: Int = 2) -> String { String(format: "%.\(digits)f", value) }
var report = ""
func note(_ line: String) {
    print(line)
    report += line + "\n"
}

/// The model, used by one piece at a time.
actor Model {
    let separator: MDXSeparator
    var pieces = 0
    var seconds = 0.0
    init(url: URL) throws {
        separator = try MDXSeparator(modelURL: url, computeUnits: .all)
    }
    func vocals(_ left: ArraySlice<Float>, _ right: ArraySlice<Float>) throws -> (left: [Float], right: [Float]) {
        let started = Date()
        defer {
            pieces += 1
            seconds += Date().timeIntervalSince(started)
        }
        return try separator.vocals(left: left, right: right)
    }
}

struct Song {
    let file: URL
    let artist: String
    let title: String
    let genre: String
    let license: String
    let page: String
    /// Sung phrases from the words' timings.
    let phrases: [(start: Double, end: Double)]
    var analysis: TrackAnalysis
    var vocals = VocalActivity()
    var shares: [VocalDetector.Part: (start: Double, values: [Float])] = [:]

    var name: String { "\(artist) – \(title)" }

    func sung(at time: Double) -> Bool { phrases.contains { time >= $0.start && time < $0.end } }
}

// MARK: Songs

let csv = (try? String(contentsOf: dataset.appending(path: "JamendoLyrics.csv"), encoding: .utf8)) ?? ""
let rows = csv.split(whereSeparator: \.isNewline).dropFirst().map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
let model: Model
do {
    model = try Model(url: modelURL)
} catch {
    print("model: \(error)")
    exit(1)
}

var songs: [Song] = []
for row in rows where row.count >= 10 && !row[5].contains("ND") && songs.count < songLimit {
    let file = dataset.appending(path: "mp3").appending(path: row[1])
    let stem = (row[1] as NSString).deletingPathExtension
    guard FileManager.default.fileExists(atPath: file.path) else { continue }
    let words = (try? String(contentsOf: dataset.appending(path: "annotations/words/\(stem).csv"), encoding: .utf8)) ?? ""
    var phrases: [(start: Double, end: Double)] = []
    for line in words.split(whereSeparator: \.isNewline).dropFirst() {
        let fields = line.split(separator: ",")
        guard fields.count >= 2, let start = Double(fields[0]), let end = Double(fields[1]) else { continue }
        if let last = phrases.last, start - last.end < VocalDetector.phraseGap {
            phrases[phrases.count - 1].end = max(last.end, end)
        } else {
            phrases.append((start, end))
        }
    }
    let started = Date()
    guard let samples = try? await AutoMixDecoder.samples(of: file),
          let analysis = TrackAnalyzer.analyze(samples, sampleRate: TrackAnalyzer.sampleRate) else {
        print("\(row[2]) – \(row[3]): not analysed")
        continue
    }
    var song = Song(file: file, artist: row[2], title: row[3], genre: row[4], license: row[5], page: row[0],
                    phrases: phrases, analysis: analysis)
    let separate: VocalDetector.Separate = { try await model.vocals($0, $1) }
    for part in [VocalDetector.Part.head, .tail] {
        let stretch = VocalDetector.range(part, of: analysis)
        do {
            let audio = try await AutoMixRenderer.decode(file, from: stretch.start, duration: stretch.end - stretch.start)
            guard let channels = audio.floatChannelData else { continue }
            let count = Int(audio.frameLength)
            let left = Array(UnsafeBufferPointer(start: channels[0], count: count))
            let right = Array(UnsafeBufferPointer(start: channels[1], count: count))
            let values = try await VocalDetector.shares(left: left, right: right, separate: separate)
            song.shares[part] = (stretch.start, values)
            song.vocals.regions.append(VocalDetector.region(start: stretch.start, shares: values))
        } catch {
            print("\(song.name) \(part.rawValue): \(error)")
        }
    }
    print("\(song.name) [\(song.genre)]: \(format(analysis.tempo, 1)) BPM, grid \(format(analysis.gridFit)), "
          + "bass \(format(analysis.bassShare(0..<analysis.beatCount))), in \(format(Date().timeIntervalSince(started), 1)) s")
    songs.append(song)
}
let (pieces, modelSeconds) = await (model.pieces, model.seconds)
note("== \(songs.count) songs; the vocal model took \(format(modelSeconds / Double(max(1, pieces)))) s per piece of "
    + "\(format(Double(MDXSeparator.maxPieceLength) / 44_100, 1)) s on this machine (\(pieces) pieces)")

// MARK: Voices against the words

/// Frame by frame where the words were timed: how often the detection agrees, with given thresholds.
func score(absent: Float, present: Float) -> (precision: Double, recall: Double, f1: Double, accuracy: Double) {
    var tp = 0.0, fp = 0.0, fn = 0.0, tn = 0.0
    for song in songs where !song.phrases.isEmpty {
        for (_, measured) in song.shares {
            let region = VocalDetector.region(start: measured.start, shares: measured.values, absent: absent, present: present)
            for (index, value) in region.values.enumerated() {
                let time = region.start + (Double(index) + 0.5) * VocalActivity.step
                let truth = song.sung(at: time), said = value >= 128
                switch (truth, said) {
                case (true, true): tp += 1
                case (false, true): fp += 1
                case (true, false): fn += 1
                case (false, false): tn += 1
                }
            }
        }
    }
    let precision = tp / max(1, tp + fp), recall = tp / max(1, tp + fn)
    return (precision, recall, 2 * precision * recall / max(1e-9, precision + recall), (tp + tn) / max(1, tp + fp + fn + tn))
}

let current = score(absent: VocalDetector.absentShare, present: VocalDetector.presentShare)
note("== Voices, quarter second by quarter second, against the timed words (phrases):")
note("   app thresholds \(VocalDetector.absentShare)/\(VocalDetector.presentShare) dB: precision \(format(current.precision)), "
    + "recall \(format(current.recall)), F1 \(format(current.f1)), agreement \(format(current.accuracy))")
var best = (absent: VocalDetector.absentShare, present: VocalDetector.presentShare, f1: current.f1)
for absent in stride(from: Float(-24), through: -6, by: 3) {
    for width in [Float(4), 6, 8, 10] {
        let result = score(absent: absent, present: absent + width)
        if result.f1 > best.f1 { best = (absent, absent + width, result.f1) }
    }
}
note("   best of the sweep: \(best.absent)/\(best.present) dB, F1 \(format(best.f1))")
// The moments that matter most for a mix: where the first song's last phrase ends, where the
// next song's first one starts.
var startErrors: [Double] = [], endErrors: [Double] = []
var missedStarts = 0, missedEnds = 0
for song in songs where !song.phrases.isEmpty {
    let head = VocalDetector.range(.head, of: song.analysis), tail = VocalDetector.range(.tail, of: song.analysis)
    if let first = song.phrases.first(where: { $0.end > head.start }), first.start < head.end {
        if let found = song.vocals.firstVoice(after: head.start) { startErrors.append(found - first.start) } else { missedStarts += 1 }
    }
    if let last = song.phrases.last(where: { $0.start < tail.end }), last.end > tail.start {
        if let found = song.vocals.lastVoice(before: tail.end) { endErrors.append(found - last.end) } else { missedEnds += 1 }
    }
}
func describe(_ errors: [Double]) -> String {
    guard !errors.isEmpty else { return "none" }
    let sorted = errors.map(abs).sorted()
    return "median \(format(sorted[sorted.count / 2])) s, 80 % within \(format(sorted[min(sorted.count - 1, sorted.count * 4 / 5)])) s"
}
note("   first words of a song: \(describe(startErrors)) off (\(startErrors.count) found, \(missedStarts) missed)")
note("   last words of a song: \(describe(endErrors)) off (\(endErrors.count) found, \(missedEnds) missed)")
note("   (Only lyrics were timed: backing vocals, \"ooh\"s and spoken parts count as no voice there.)")

// MARK: Pairs

struct Pair {
    let kind: String
    let a: Int
    let b: Int
}

func tempoApart(_ x: TrackAnalysis, _ y: TrackAnalysis) -> Double {
    [1.0, 2, 0.5].map { abs(log(y.tempo * $0 / x.tempo)) }.min() ?? 1
}
func firstVoice(_ song: Song) -> Double? { song.vocals.firstVoice(after: song.analysis.soundStart) }
var pairs: [Pair] = []
var used = Set<Int>()
func pick(_ kind: String, _ condition: (Song, Song) -> Bool, score: (Song, Song) -> Double = { _, _ in 0 }) {
    var found: (Int, Int, Double)?
    for (i, a) in songs.enumerated() where !used.contains(i) {
        for (j, b) in songs.enumerated() where j != i && !used.contains(j) && condition(a, b) {
            let value = score(a, b)
            if found == nil || value < found!.2 { found = (i, j, value) }
        }
    }
    guard let found else { return note("   no pair for: \(kind)") }
    used.insert(found.0)
    used.insert(found.1)
    pairs.append(Pair(kind: kind, a: found.0, b: found.1))
}
let rhythmic = { (song: Song) -> Bool in song.analysis.isGridLocked }
pick("dance, close tempos", { ["Electronic", "Pop", "Hip-Hop", "RNB"].contains($0.genre) && ["Electronic", "Pop", "Hip-Hop", "RNB"].contains($1.genre)
    && rhythmic($0) && rhythmic($1) && tempoApart($0.analysis, $1.analysis) < 0.04 },
     score: { -$0.analysis.bassShare(0..<$0.analysis.beatCount) - $1.analysis.bassShare(0..<$1.analysis.beatCount) })
pick("sung pop", { $0.genre == "Pop" && $1.genre == "Pop" })
pick("rap, the voice from the first bar", { a, b in
    rhythmic(a) && b.genre == "Hip-Hop" && (firstVoice(b).map { $0 - b.analysis.soundStart } ?? 99) < 3
})
pick("acoustic", { ["Folk", "Country", "Jazz", "Indie"].contains($0.genre) && ["Folk", "Country", "Jazz", "Indie"].contains($1.genre)
    && $0.analysis.bassShare(0..<$0.analysis.beatCount) < 0.3 && $1.analysis.bassShare(0..<$1.analysis.beatCount) < 0.3 })
pick("tempos far apart", { rhythmic($0) && rhythmic($1) && tempoApart($0.analysis, $1.analysis) > log(1.15) })
pick("rock", { $0.genre == "Rock" && $1.genre == "Rock" })
pick("reggae", { $0.genre == "Reggae" && $1.genre == "Reggae" })
pick("any two", { _, _ in true })
note("   (No live recordings in this set: they are still to be tried.)")

// MARK: Rendering

let rate = MixSchedule.sampleRate
var key = "Which is which (open after listening):\n"
var credits = "Songs (Creative Commons, from the JamendoLyrics dataset; the excerpts are mixes of them, made to\n"
    + "evaluate Onda's AutoMix, not for any commercial use):\n"
var creditedSongs = Set<Int>()
let work = FileManager.default.temporaryDirectory.appending(path: "automix-real-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

func read(_ url: URL) throws -> AVAudioPCMBuffer {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
        throw AutoMixRenderer.RenderError.engine
    }
    try file.read(into: buffer)
    return buffer
}

/// The pieces one after the other, as AAC at 256 kbps.
func write(_ parts: [AVAudioPCMBuffer], to url: URL) throws {
    let file = try AVAudioFile(forWriting: url, settings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000,
    ], commonFormat: .pcmFormatFloat32, interleaved: false)
    for part in parts where part.frameLength > 0 { try file.write(from: part) }
}

/// Loudness every 0.4 s (dB), the peak, and the largest rise and fall within two seconds.
func measure(_ parts: [AVAudioPCMBuffer]) -> (peak: Float, rise: Double, fall: Double) {
    var mono: [Float] = []
    for part in parts {
        guard let channels = part.floatChannelData else { continue }
        for frame in 0..<Int(part.frameLength) { mono.append((channels[0][frame] + channels[1][frame]) / 2) }
    }
    let window = Int(0.4 * rate)
    var levels: [Double] = []
    var start = 0
    while start + window <= mono.count {
        let power = mono[start..<(start + window)].reduce(0.0) { $0 + Double($1 * $1) } / Double(window)
        levels.append(10 * log10(power + 1e-12))
        start += window / 2
    }
    var rise = 0.0, fall = 0.0
    let reach = 10
    for index in levels.indices {
        for other in index..<min(levels.count, index + reach) {
            rise = max(rise, levels[other] - levels[index])
            fall = max(fall, levels[index] - levels[other])
        }
    }
    return (mono.map(abs).max() ?? 0, rise, fall)
}

for (number, pair) in pairs.enumerated() {
    let a = songs[pair.a], b = songs[pair.b]
    let label = String(format: "%02d", number + 1)
    note("\n== Pair \(label), \(pair.kind): \(a.name) [\(format(a.analysis.tempo, 1)) BPM] → \(b.name) [\(format(b.analysis.tempo, 1)) BPM]")
    for index in [pair.a, pair.b] where creditedSongs.insert(index).inserted {
        let song = songs[index]
        credits += "- \(song.name) (\(song.genre)), \(song.license.trimmingCharacters(in: .whitespaces)), \(song.page)\n"
    }
    let old = TransitionPlanner.reference(from: a.analysis, to: b.analysis)
    let measured = TransitionPlanner.choose(from: a.analysis, to: b.analysis,
                                            context: TransitionContext(outgoingVocals: a.vocals, incomingVocals: b.vocals))
    let unknown = TransitionPlanner.choose(from: a.analysis, to: b.analysis)
    note("   up to 1.16: \(old.style.rawValue)\(old.bars.map { ", \($0) bars" } ?? ""), \(format(old.overlap, 1)) s together, "
        + "rates \(format(old.outgoingRate, 3))/\(format(old.incomingRate, 3)), from \(format(old.outStart, 1)) s")
    note("   new, voices measured: " + measured.summary.replacingOccurrences(of: "\n", with: "\n      "))
    note("      \(measured.plan.style.rawValue), \(format(measured.plan.overlap, 1)) s together, rates "
        + "\(format(measured.plan.outgoingRate, 3))/\(format(measured.plan.incomingRate, 3)), from \(format(measured.plan.outStart, 1)) s")
    note("   new, voices not measured: \(unknown.chosen.title) (\(format(unknown.chosen.total)))")
    // The same stretch of both songs around either mix.
    var mixes: [(name: String, plan: TransitionPlan, mix: AutoMixRenderer.Mix)] = []
    for (name, plan) in [("1.16", old), ("new", measured.plan)] {
        do {
            let mix = try await AutoMixRenderer.render(MixSchedule(plan: plan), outgoing: a.file, incoming: b.file,
                                                       outgoingGain: 1, incomingGain: 1,
                                                       to: work.appending(path: "\(label)-\(name).caf"))
            mixes.append((name, plan, mix))
        } catch {
            note("   \(name): not rendered (\(error))")
        }
    }
    guard mixes.count == 2 else { continue }
    let from = max(0, mixes.map(\.plan.handover).min()! - 10)
    let to = mixes.map(\.mix.join).max()! + 10
    var files: [String: String] = [:]
    let names = Bool.random() ? ["X", "Y"] : ["Y", "X"]
    for (index, entry) in mixes.enumerated() {
        do {
            let before = try await AutoMixRenderer.decode(a.file, from: from, duration: entry.plan.handover - from)
            let mixed = try read(entry.mix.url)
            let after = try await AutoMixRenderer.decode(b.file, from: entry.mix.join, duration: to - entry.mix.join)
            let parts = [before, mixed, after]
            let url = output.appending(path: "pair-\(label)-\(names[index]).m4a")
            try write(parts, to: url)
            let levels = measure(parts)
            files[entry.name] = names[index]
            note("   \(entry.name): peak \(format(20 * log10(Double(max(levels.peak, 1e-9))), 1)) dBFS, "
                + "largest rise \(format(levels.rise, 1)) dB and fall \(format(levels.fall, 1)) dB within 2 s")
        } catch {
            note("   \(entry.name): excerpt not written (\(error))")
        }
    }
    key += "pair \(label) (\(pair.kind)): 1.16 = \(files["1.16"] ?? "?"), new = \(files["new"] ?? "?")\n"
}

try? report.write(to: output.appending(path: "REPORT.txt"), atomically: true, encoding: .utf8)
try? key.write(to: output.appending(path: "KEY.txt"), atomically: true, encoding: .utf8)
try? credits.write(to: output.appending(path: "CREDITS.txt"), atomically: true, encoding: .utf8)
print("written to \(output.path)")
