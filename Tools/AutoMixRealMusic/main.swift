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

/// The song as a file of floats decoded from its start. These MP3s are VBR without a seek table,
/// so one read from a point lands only near it, a different place each time (the app's own files,
/// MP4 and the like, are read exactly where asked): everything here reads the copy.
let copies = FileManager.default.temporaryDirectory.appending(path: "automix-real-copies-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: copies, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: copies) }
func exactCopy(of source: URL) throws -> URL {
    let input = try AVAudioFile(forReading: source)
    let format = input.processingFormat
    let url = copies.appending(path: source.deletingPathExtension().lastPathComponent + ".caf")
    let output = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: format.commonFormat,
                                 interleaved: format.isInterleaved)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else { throw CocoaError(.fileReadUnknown) }
    while input.framePosition < input.length {
        try input.read(into: buffer, frameCount: 65_536)
        guard buffer.frameLength > 0 else { break }
        try output.write(from: buffer)
    }
    return url
}

var songs: [Song] = []
for row in rows where row.count >= 10 && !row[5].contains("ND") && songs.count < songLimit {
    let mp3 = dataset.appending(path: "mp3").appending(path: row[1])
    let stem = (row[1] as NSString).deletingPathExtension
    guard FileManager.default.fileExists(atPath: mp3.path) else { continue }
    guard let file = try? exactCopy(of: mp3) else {
        print("\(row[2]) – \(row[3]): not decoded")
        continue
    }
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
pick("levels far apart", { abs($0.analysis.bodyLoudness - $1.analysis.bodyLoudness) >= 4 },
     score: { -Double(abs($0.analysis.bodyLoudness - $1.analysis.bodyLoudness)) })
note("   (No live recordings in this set: they are still to be tried.)")

// MARK: Rendering

let rate = MixSchedule.sampleRate
var key = "Which is which (open after listening):\n"
var credits = "Songs (Creative Commons, from the JamendoLyrics dataset; the excerpts are mixes of them, made to\n"
    + "evaluate Seaglass's AutoMix, not for any commercial use):\n"
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

/// The gain "Volume uniforme" gives a song: louder songs down to a reference (here -16 dB of
/// K-weighted power, measured over the whole song), never up.
func uniformGain(_ song: Song) -> Float {
    guard let whole = try? Stereo.read(song.file) else { return 1 }
    let loudness = whole.filtered(LevelFilter.kWeighting(rate: whole.rate)).level(from: 0, to: Double(whole.count) / whole.rate)
    return Float(min(1, pow(10, (-16 - loudness) / 20)))
}

/// The pieces one after the other, as AAC at 256 kbps.
func write(_ parts: [AVAudioPCMBuffer], to url: URL) throws {
    let file = try AVAudioFile(forWriting: url, settings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000,
    ], commonFormat: .pcmFormatFloat32, interleaved: false)
    for part in parts where part.frameLength > 0 { try file.write(from: part) }
}

/// Loudness (dB) of each second of a buffer, half a second apart.
func levels(_ buffer: AVAudioPCMBuffer, from start: Double = 0, to end: Double = .infinity) -> [Double] {
    guard let channels = buffer.floatChannelData else { return [] }
    let count = Int(buffer.frameLength), window = Int(rate)
    var result: [Double] = []
    var frame = max(0, Int(start * rate))
    while frame + window <= min(count, end.isFinite ? Int(end * rate) : count) {
        var power = 0.0
        for index in frame..<(frame + window) {
            let value = Double((channels[0][index] + channels[1][index]) / 2)
            power += value * value
        }
        result.append(10 * log10(power / Double(window) + 1e-12))
        frame += window / 2
    }
    return result
}

/// Loudness (dB) of a stretch of a buffer, as one.
func level(_ buffer: AVAudioPCMBuffer, from start: Double = 0, to end: Double = .infinity) -> Double {
    guard let channels = buffer.floatChannelData else { return -120 }
    let count = Int(buffer.frameLength)
    let first = max(0, min(count, Int(start * rate))), last = max(first, min(count, end.isFinite ? Int(end * rate) : count))
    var power = 0.0
    for index in first..<last {
        power += Double(channels[0][index] * channels[0][index] + channels[1][index] * channels[1][index]) / 2
    }
    return 10 * log10(power / Double(max(1, last - first)) + 1e-12)
}

/// Where the mix takes over and hands back, it should be the song itself: its first second
/// against the same second of the song playing, its last against the same second of the next
/// song, at the gains it was made with (dB; 0 when the same).
func seams(_ mix: AutoMixRenderer.Mix, _ plan: TransitionPlan, from a: Song, to b: Song, gain: Double) async throws -> (start: Double, end: Double) {
    let mixed = try read(mix.url)
    let length = Double(mixed.frameLength) / rate
    let first = try await AutoMixRenderer.decode(a.file, from: plan.handover, duration: 1)
    let last = try await AutoMixRenderer.decode(b.file, from: mix.join - 1, duration: 1)
    let offset = 20 * log10(gain)
    return (level(mixed, to: 1) - level(first, to: 1) - offset, level(mixed, from: length - 1, to: length) - level(last, to: 1) - offset)
}

/// The handover as the player makes it, the mix (a copy of the song there) `lag` seconds ahead of
/// the song, crossing at `crossing` over `length` seconds: the quietest tenth of a second against
/// the song's (dB).
func handoverDip(_ song: MonoStretch, lag: Double, at crossing: Double, over length: Double) -> Double {
    let x = song.mono
    let start = Int(crossing * rate), span = Int(length * rate), shift = Int(lag * rate), tenth = Int(0.1 * rate)
    guard x.count > start + span + shift + 2 * tenth else { return 0 }
    var worst = 0.0
    var frame = start - tenth
    while frame + tenth < start + span + tenth {
        var own = 0.0, heard = 0.0
        for index in frame..<(frame + tenth) {
            let r = Float(max(0, min(1, Double(index - start) / Double(span))))
            let value = x[index] * (1 - r) + x[index + shift] * r
            own += Double(x[index] * x[index])
            heard += Double(value * value)
        }
        if own > 1e-9 { worst = min(worst, 10 * log10(heard / own)) }
        frame += tenth / 10
    }
    return worst
}

/// A stretch of a song as mono samples.
struct MonoStretch {
    let mono: [Float]
    init(_ buffer: AVAudioPCMBuffer) {
        let count = Int(buffer.frameLength)
        guard let channels = buffer.floatChannelData else { mono = []; return }
        mono = (0..<count).map { (channels[0][$0] + channels[1][$0]) / 2 }
    }
}

/// How much the next song alone comes up within a second once it has fully come in (the trims
/// letting go as the first song leaves), in dB.
func rise(_ plan: TransitionPlan) -> Double {
    let step = 0.05
    var points: [(time: Double, level: Double)] = []
    for time in stride(from: plan.outStart, through: plan.outEnd, by: step) {
        let p = plan.progress(atOutgoingTime: time)
        guard p >= plan.fadeIn else { continue }
        points.append((time, 20 * log10(Double(max(plan.levels(at: p).incoming, 1e-6)))))
    }
    var largest = 0.0
    for (index, point) in points.enumerated() {
        for later in points[index...] where later.time - point.time <= 1 { largest = max(largest, later.level - point.level) }
    }
    return largest
}

/// The mix against the songs around it: how much louder than the louder of the two (the last
/// four seconds before it, the first four after) and how much quieter than the quieter it gets,
/// over seconds; and its peak.
func measure(before: AVAudioPCMBuffer, mix: AVAudioPCMBuffer, after: AVAudioPCMBuffer) -> (bump: Double, dip: Double, peak: Float) {
    func mean(_ values: [Double]) -> Double {
        10 * log10(values.map { pow(10, $0 / 10) }.reduce(0, +) / Double(max(1, values.count)) + 1e-12)
    }
    let length = Double(before.frameLength) / rate
    let levelA = mean(levels(before, from: max(0, length - 4))), levelB = mean(levels(after, to: 4))
    let mixed = levels(mix)
    var peak: Float = 0
    if let channels = mix.floatChannelData {
        for index in 0..<Int(mix.frameLength) { peak = max(peak, abs(channels[0][index]), abs(channels[1][index])) }
    }
    return ((mixed.max() ?? -100) - max(levelA, levelB), min(levelA, levelB) - (mixed.min() ?? -100), peak)
}

/// What a plan does to the songs' sung words (the timed lyrics, not the detection): seconds of
/// two voices heard at once (both at least at 0.3), of the first song's words while it is taken
/// away or left out, and of the next song's words while it is still low or left out.
func words(_ plan: TransitionPlan, _ a: Song, _ b: Song) -> (together: Double, faded: Double, buried: Double) {
    var together = 0.0, faded = 0.0, buried = 0.0
    let step = 0.05
    for time in stride(from: plan.outStart, to: plan.outEnd, by: step) {
        let levels = plan.levels(at: plan.progress(atOutgoingTime: time))
        let incoming = plan.inStart + (time - plan.outStart) * plan.tempoOut / plan.tempoIn
        let sungA = a.sung(at: time), sungB = b.sung(at: incoming)
        if sungA, sungB, levels.outgoing >= 0.3, levels.incoming >= 0.3 { together += step }
        if sungA, levels.outgoing < 0.9 { faded += step }
        if sungB, levels.incoming < 0.7 { buried += step }
    }
    for time in stride(from: plan.outEnd, to: a.analysis.soundEnd, by: step) where a.sung(at: time) { faded += step }
    for time in stride(from: 0, to: plan.inStart, by: step) where b.sung(at: time) { buried += step }
    return (together, faded, buried)
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
    for (name, plan) in [("1.16", old), ("new", measured.plan)] {
        let sung = words(plan, a, b)
        note("   \(name), timed words: two voices at once \(format(sung.together, 1)) s, the first song's words faded or "
             + "left out \(format(sung.faded, 1)) s, the next song's under 70 % or left out \(format(sung.buried, 1)) s")
    }
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
            let loudness = measure(before: before, mix: mixed, after: after)
            files[entry.name] = names[index]
            note("   \(entry.name), rendered: at most \(format(loudness.bump, 1)) dB over the louder song and "
                + "\(format(loudness.dip, 1)) dB under the quieter (second by second), peak "
                + "\(format(20 * log10(Double(max(loudness.peak, 1e-9))), 1)) dBFS")
        } catch {
            note("   \(entry.name): excerpt not written (\(error))")
        }
    }
    // The seams, at full gain (the limiter has the most to do) and 6 dB down (as "Volume uniforme"
    // has most songs).
    for entry in mixes {
        do {
            let full = try await seams(entry.mix, entry.plan, from: a, to: b, gain: 1)
            let down = try await AutoMixRenderer.render(MixSchedule(plan: entry.plan), outgoing: a.file, incoming: b.file,
                                                        outgoingGain: 0.5, incomingGain: 0.5,
                                                        to: work.appending(path: "\(label)-\(entry.name)-down.caf"))
            let half = try await seams(down, entry.plan, from: a, to: b, gain: 0.5)
            if entry.name == "new" {
                let song = MonoStretch(try await AutoMixRenderer.decode(a.file, from: entry.plan.handover, duration: 1.5))
                let fade = HandoverFader.exactLength
                let quiet = HandoverFader.quietMoment(in: song.mono, rate: rate, from: 0.45, to: 0.9 + fade, length: fade)
                let lags = [0.001, 0.002, 0.005]
                let now = lags.map { handoverDip(song, lag: $0, at: quiet, over: fade) }
                let before = lags.map { handoverDip(song, lag: $0, at: 0.5, over: 0.25) }
                note("   handover with the players 1, 2 and 5 ms apart: down at most "
                    + now.map { format(-$0, 1) }.joined(separator: ", ") + " dB over a tenth of a second (up to 1.18: "
                    + before.map { format(-$0, 1) }.joined(separator: ", ") + " dB)")
            }
            note("   \(entry.name), seams (the mix against the same second of the song): taking over \(format(full.start, 2)) dB, "
                + "handing back \(format(full.end, 2)) dB; 6 dB down: \(format(half.start, 2)) and \(format(half.end, 2)) dB; "
                + "the next song comes up by \(format(rise(entry.plan), 1)) dB within a second once in")
        } catch {
            note("   \(entry.name): seams not measured (\(error))")
        }
    }
    // How loud AutoMix's choice is against normal playback of the same songs (see
    // Tools/AutoMixLevels/Levels.swift), "Volume uniforme" off and on.
    for uniform in [false, true] {
        let gains: (Float, Float) = uniform ? (uniformGain(a), uniformGain(b)) : (1, 1)
        let context = TransitionContext(outgoingGain: gains.0, incomingGain: gains.1,
                                        outgoingVocals: a.vocals, incomingVocals: b.vocals)
        let plan = TransitionPlanner.choose(from: a.analysis, to: b.analysis, context: context).plan
        let schedule = MixSchedule(plan: plan)
        let limited = work.appending(path: "\(label)-levels.caf"), open = work.appending(path: "\(label)-open.caf")
        do {
            let mix = try await AutoMixRenderer.render(schedule, outgoing: a.file, incoming: b.file, outgoingGain: gains.0,
                                                       incomingGain: gains.1, to: limited)
            _ = try await AutoMixRenderer.render(schedule, outgoing: a.file, incoming: b.file, outgoingGain: gains.0,
                                                 incomingGain: gains.1, to: open, limiter: false)
            let levels = try await MixLevels.measure(try Stereo.read(limited), unlimited: try Stereo.read(open), schedule: schedule,
                                                     join: mix.join, outgoing: a.file, incoming: b.file, gains: gains,
                                                     judge: TransitionJudge(a.analysis, b.analysis, context))
            let swap = plan.swapStart.map { String(format: ", bass swap %.2f–%.2f", $0, plan.swapEnd ?? $0) } ?? ""
            note("   levels, \"Volume uniforme\" \(uniform ? "on (\(format(20 * log10(Double(gains.0)), 1)) and \(format(20 * log10(Double(gains.1)), 1)) dB)" : "off"): "
                + "\(plan.style.rawValue), \(format(plan.overlap, 1)) s\(swap)")
            note("      " + levels.summary)
        } catch {
            note("   levels not measured (\(error))")
        }
    }
    key += "pair \(label) (\(pair.kind)): 1.16 = \(files["1.16"] ?? "?"), new = \(files["new"] ?? "?")\n"
}

try? report.write(to: output.appending(path: "REPORT.txt"), atomically: true, encoding: .utf8)
try? key.write(to: output.appending(path: "KEY.txt"), atomically: true, encoding: .utf8)
try? credits.write(to: output.appending(path: "CREDITS.txt"), atomically: true, encoding: .utf8)
print("written to \(output.path)")
