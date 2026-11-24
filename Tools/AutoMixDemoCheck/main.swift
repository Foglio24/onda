// Checks the Home's AutoMix demo (Seaglass/Player/DemoSongs.swift, Seaglass/Player/TransitionClip.swift)
// on its own two songs, made as the app makes them:
// - AutoMix, with its defaults, mixes them (the app falls back to these when the listener's settings
//   find no mix);
// - the plain listen is the first song's end and the second's start, one after the other; the AutoMix
//   one is the first song's own samples up to the frame the mix's file starts on, the mix, and the
//   second song's own samples from the frame the mix hands back on: the clip follows the songs sample
//   for sample across both joins (no jump, no click);
// - both listens hold each song at the same gain: the first song alone is as loud in both, the second
//   alone too, and the two songs as loud as each other;
// - through the mix the sound never gets much louder than the songs alone, nor drops out;
// - the passage comes after the same seconds of the first song in both listens;
// - written to a file and read back, a clip keeps its length.
// Run from the repository root: bash Tools/AutoMixDemoCheck/run.sh
import AVFoundation
import Foundation

var failures = 0
func expect(_ condition: Bool, _ message: String) {
    print(condition ? "ok   \(message)" : "FAIL \(message)")
    if !condition { failures += 1 }
}
func format(_ value: Double, _ digits: Int = 2) -> String { String(format: "%.\(digits)f", value) }

let specs = DemoSongs.autoMixPair
expect(specs.count == 2 && specs[0].id != specs[1].id, "the demo has two songs")

// MARK: Analysis and plan, as the app makes them

var analyses: [TrackAnalysis] = []
for spec in specs {
    let samples = DemoSongs.samples(bpm: spec.bpm, root: spec.root, introBars: spec.introBars, seconds: spec.seconds,
                                    sampleRate: TrackAnalyzer.sampleRate)
    guard var analysis = TrackAnalyzer.analyze(samples, sampleRate: TrackAnalyzer.sampleRate) else {
        print("AutoMixDemoCheck: the analysis of \(spec.title) failed")
        exit(1)
    }
    analysis.pauses = TrackAnalyzer.pauses(samples, sampleRate: TrackAnalyzer.sampleRate)
    print("\(spec.title): \(format(analysis.tempo, 1)) BPM (made at \(format(spec.bpm, 0))), grid fit \(format(analysis.gridFit)), "
          + "key \(analysis.key)\(analysis.minor ? "m" : "") clarity \(format(analysis.keyClarity))")
    expect(abs(analysis.tempo - spec.bpm) < 1, "\(spec.title)'s tempo is measured (\(format(analysis.tempo, 1)) BPM)")
    analyses.append(analysis)
}
let decision = SeguePolicy.decide(DemoSongs.autoMixRequest(analyses[0], analyses[1]))
guard let plan = decision.plan, decision.level != .normal else {
    print("FAIL AutoMix finds no mix for the demo's songs (\(decision.level.rawValue)): \(decision.why)")
    exit(1)
}
print("plan: \(plan.level.rawValue) \(plan.shape.rawValue), \(format(plan.length, 1)) s from \(format(plan.outgoingStart, 1)) s into \(format(plan.incomingStart, 1)) s")
expect(plan.level.isLocked, "the demo's songs are mixed beat on beat (\(plan.level.rawValue))")
expect(plan.outgoingStart >= DemoSongs.autoMixEarliestExit, "the mix starts after the demo's earliest exit (\(format(plan.outgoingStart, 1)) s)")

// MARK: The two listens

let rate = 44_100.0
var songs: [SegueAudio] = []
var levels: [DemoSongs.Level] = []
for spec in specs {
    let samples = DemoSongs.samples(bpm: spec.bpm, root: spec.root, introBars: spec.introBars, seconds: spec.seconds, sampleRate: rate)
    songs.append(SegueAudio(left: samples, right: samples, origin: 0, sampleRate: rate))
    levels.append(DemoSongs.level(of: samples, from: Int((1 + Double(spec.introBars) * 4 * 60 / spec.bpm) * rate)))
}
let gains = DemoSongs.matchedGains(levels)
print("levels: rms \(levels.map { format(20 * log10($0.rms), 1) }) dB, peaks \(levels.map { format($0.peak, 2) }), gains \(gains.map { format(Double($0), 3) })")
expect(gains.allSatisfy { $0 > 0.2 && $0 < 4 }, "the gains are sensible")
expect(zip(levels, gains).allSatisfy { Double($1) * $0.peak <= 0.9 + 1e-6 }, "no song peaks above 0.9 at its gain")

let pair = (outgoing: gains[0], incoming: gains[1])
let plain: TransitionClipMaker.Mixed
let mixed: TransitionClipMaker.Mixed
do {
    plain = try TransitionClipMaker.plain(a: songs[0], b: songs[1], gains: pair)
    mixed = try TransitionClipMaker.autoMix(plan, a: songs[0], b: songs[1], gains: pair)
} catch {
    print("FAIL the listens can't be made (\(error))")
    exit(1)
}
print("plain: \(format(plain.length, 1)) s, passage \(format(plain.passageStart))–\(format(plain.passageEnd)) s, seams \(plain.seams)")
print("automix: \(format(mixed.length, 1)) s, passage \(format(mixed.passageStart))–\(format(mixed.passageEnd)) s, seams \(mixed.seams)")

// MARK: No jump where pieces meet

/// The clip against a song's own samples at its gain over `count` frames on each side of `seam`,
/// `songFrame` being the song's frame at the clip's `seam`: the largest difference (0 when exact).
func difference(_ clip: TransitionClipMaker.Mixed, seam: Int, song: SegueAudio, songFrame: Int, gain: Float, count: Int) -> Float {
    var largest: Float = 0
    for k in -count..<count {
        let i = seam + k, j = songFrame + k
        guard i >= 0, i < clip.left.count, j >= 0, j < song.frames else { continue }
        largest = max(largest, abs(clip.left[i] - song.left[j] * gain), abs(clip.right[i] - song.right[j] * gain))
    }
    return largest
}

if let first = mixed.mixFrom, let seamIn = mixed.seams.first {
    let around = difference(mixed, seam: seamIn, song: songs[0], songFrame: first, gain: gains[0], count: 2048)
    expect(around < 1e-5, "the AutoMix listen is the first song's own samples across the mix's start (\(String(format: "%.1e", around)))")
} else {
    expect(false, "the AutoMix listen says where the mix's file starts")
}
if mixed.seams.count > 1 {
    if let next = mixed.tailFrom {
        let around = difference(mixed, seam: mixed.seams[1], song: songs[1], songFrame: next, gain: gains[1], count: 2048)
        expect(around < 1e-5, "the AutoMix listen is the second song's own samples across the mix's end (\(String(format: "%.1e", around)))")
    } else {
        expect(false, "the AutoMix listen says where the second song goes on")
    }
}
// The plain one: the first song's end is silence and so is the second's start, as they are made.
if let seam = plain.seams.first {
    let step = TransitionClipMaker.largestStep(plain, around: seam, radius: 2)
    expect(step < 0.01, "the plain listen goes from the first song's end to the second's start without a click (\(format(Double(step), 4)))")
}
// Nowhere in either listen a step larger than both songs' own together (a hi-hat's noise is their
// largest; in the mix two can meet).
func largestStepOf(_ audio: SegueAudio, gain: Float) -> Float {
    var step: Float = 0
    for i in 1..<audio.frames { step = max(step, abs(audio.left[i] - audio.left[i - 1]) * gain) }
    return step
}
let songStep = max(largestStepOf(songs[0], gain: gains[0]), largestStepOf(songs[1], gain: gains[1]))
for (name, clip) in [("plain", plain), ("AutoMix", mixed)] {
    let step = TransitionClipMaker.largestStep(clip, around: clip.left.count / 2, radius: clip.left.count)
    expect(step <= songStep * 2.05, "no click anywhere in the \(name) listen (largest step \(format(Double(step), 3)), the songs' own \(format(Double(songStep), 3)))")
}

// MARK: As loud as each other

let soloA = 2.0
func alone(_ clip: TransitionClipMaker.Mixed, first: Bool) -> Double {
    if first {
        let end = clip.passageStart - 0.5
        return TransitionClipMaker.loudness(clip, from: end - soloA, to: end)
    }
    let end = clip.length - TransitionClipMaker.fadeOut - 0.5
    return TransitionClipMaker.loudness(clip, from: end - soloA, to: end)
}
let plainA = alone(plain, first: true), plainB = alone(plain, first: false)
let mixA = alone(mixed, first: true), mixB = alone(mixed, first: false)
print("alone: plain \(format(plainA, 1)) / \(format(plainB, 1)) dB, AutoMix \(format(mixA, 1)) / \(format(mixB, 1)) dB")
expect(abs(plainA - mixA) < 1, "the first song is as loud in both listens (\(format(plainA - mixA, 2)) dB)")
expect(abs(plainB - mixB) < 1, "the second song is as loud in both listens (\(format(plainB - mixB, 2)) dB)")
expect(abs(plainA - plainB) < 1.5 && abs(mixA - mixB) < 1.5, "the two songs are as loud as each other (\(format(plainA - plainB, 2)), \(format(mixA - mixB, 2)) dB)")

// Through the mix, one-second windows every quarter of a second.
var loudest = -120.0, quietest = 0.0
var t = mixed.passageStart
while t + 1 <= mixed.passageEnd {
    let level = TransitionClipMaker.loudness(mixed, from: t, to: t + 1)
    loudest = max(loudest, level)
    quietest = min(quietest, level)
    t += 0.25
}
let louder = max(mixA, mixB), softer = min(mixA, mixB)
print("through the mix: \(format(quietest, 1)) to \(format(loudest, 1)) dB (songs alone \(format(softer, 1)) / \(format(louder, 1)) dB)")
expect(loudest <= louder + 2.5, "the mix is never much louder than the louder song alone (+\(format(loudest - louder, 1)) dB)")
expect(quietest >= softer - 9, "the mix never drops out (\(format(quietest - softer, 1)) dB)")

// MARK: Timing and files

expect(abs(plain.passageStart - TransitionClipMaker.before) < 0.05, "the plain passage comes after \(format(TransitionClipMaker.before, 0)) s (\(format(plain.passageStart)) s)")
expect(abs(mixed.passageStart - plain.passageStart) < 0.1, "both passages come after the same seconds of the first song (\(format(mixed.passageStart)) and \(format(plain.passageStart)) s)")
expect(mixed.passageEnd > mixed.passageStart + 2, "the mix lasts (\(format(mixed.passageEnd - mixed.passageStart, 1)) s)")
expect(abs(mixed.length - (mixed.passageEnd + TransitionClipMaker.after)) < 0.05, "the AutoMix listen goes on \(format(TransitionClipMaker.after, 0)) s after the mix")

let folder = FileManager.default.temporaryDirectory.appending(path: "seaglass-automix-demo-check-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for (name, clip) in [("plain", plain), ("automix", mixed)] {
    let url = folder.appending(path: "\(name).caf")
    do {
        try TransitionClipMaker.write(clip, to: url)
        let file = try AVAudioFile(forReading: url)
        let seconds = Double(file.length) / file.fileFormat.sampleRate
        expect(abs(seconds - clip.length) < 0.01, "the \(name) listen is written whole (\(format(seconds, 2)) s)")
    } catch {
        expect(false, "the \(name) listen is written (\(error))")
    }
}
try? FileManager.default.removeItem(at: folder)

print(failures == 0 ? "AutoMixDemoCheck: all passed" : "AutoMixDemoCheck: \(failures) failed")
exit(failures == 0 ? 0 : 1)
