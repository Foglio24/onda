// Checks AutoMix's Segue played ahead into a file (Seaglass/Player/Segue/SegueRender.swift) on songs
// made here, whose beats are known: the plan comes from the policy (as in the app), then
// - the file's first second is the playing song's own samples and its last ones the next song's,
//   exactly (the players hand over on the same music, unheard);
// - through the window the next song's beats stay on the playing song's while both tempos glide to
//   meet halfway (no drift);
// - after it the next song's tempo comes back to its own gradually: no step from one beat to the next,
//   and exactly its own at the end;
// - a deck's speed never changes in a step, the lanes' processing never jumps, and a mix of two sine
//   tones has no click anywhere.
// Run from the repository root: bash Tools/SegueRenderCheck/run.sh
import CoreAudio
import Foundation

var failures = 0
func expect(_ condition: Bool, _ message: String) {
    print(condition ? "ok   \(message)" : "FAIL \(message)")
    if !condition { failures += 1 }
}
func format(_ value: Double, _ digits: Int = 3) -> String { String(format: "%.\(digits)f", value) }
let rate = TrackAnalyzer.sampleRate

func note(_ midi: Int) -> Double { 440 * pow(2, Double(midi - 69) / 12) }

/// A song made to a click (as SegueCheck's): a kick on every beat, stronger on the bar's first, and a
/// chord on every bar, from `lead` seconds.
func song(bpm: Double, seconds: Double, lead: Double = 1.5, root: Int) -> [Float] {
    let beat = 60 / bpm
    let count = Int((seconds - lead - 2) / beat)
    var x = [Float](repeating: 0, count: Int(seconds * rate))
    for k in 0..<count {
        let t = lead + Double(k) * beat
        let start = Int(t * rate)
        for i in 0..<Int(0.25 * rate) where start + i < x.count {
            let time = Double(i) / rate
            let envelope = exp(-time * 18) * (k % 4 == 0 ? 1.4 : 1)
            x[start + i] += Float(0.8 * sin(2 * Double.pi * (55 + 90 * exp(-time * 40)) * time) * envelope)
        }
        if k % 4 == 0 {
            let pitches = [root, root + 4, root + 7, root + 12].map(note)
            for i in 0..<Int(4 * beat * rate) where start + i < x.count {
                let time = Double(i) / rate
                let value = pitches.reduce(0.0) { $0 + sin(2 * .pi * $1 * time) }
                x[start + i] += Float(value * min(1, time / 0.02) * 0.08)
            }
        }
    }
    let peak = x.map { abs($0) }.max() ?? 1
    return x.map { $0 / peak * 0.8 }
}

/// Only a short tick on every beat (a 2 kHz burst of 3 ms), for timing the beats in a mix.
func ticks(bpm: Double, seconds: Double, lead: Double = 1.5) -> [Float] {
    let beat = 60 / bpm
    var x = [Float](repeating: 0, count: Int(seconds * rate))
    var t = lead
    while t < seconds - 2 {
        let start = Int((t * rate).rounded())
        let length = Int(0.003 * rate)
        for i in 0..<length where start + i < x.count {
            let window = sin(Double.pi * Double(i) / Double(length))
            x[start + i] = Float(0.5 * window * window * sin(2 * .pi * 2000 * Double(i) / rate))
        }
        t += beat
    }
    return x
}

func sine(_ frequency: Double, seconds: Double, amplitude: Float = 0.4) -> [Float] {
    (0..<Int(seconds * rate)).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / rate)) }
}

func audio(_ samples: [Float], from origin: Double = 0) -> SegueAudio {
    SegueAudio(left: samples, right: samples, origin: origin, sampleRate: rate)
}

/// The mix, rendered into memory (left channel).
func render(_ plan: SeguePlan, _ a: SegueAudio, _ b: SegueAudio,
            gains: (outgoing: Float, incoming: Float)) -> (out: [Float], result: SegueRender.Result)? {
    var out: [Float] = []
    do {
        let result = try SegueRender.mix(plan, a: a, b: b, gains: gains) { left, _, count in
            out.append(contentsOf: UnsafeBufferPointer(start: left, count: count))
        }
        return (out, result)
    } catch {
        expect(false, "the mix renders (\(error))")
        return nil
    }
}

/// The ticks' times (seconds of the file): the peaks of the energy in 0.5 ms steps, above a tenth of
/// the loudest, at least a fifth of a second apart; each refined to the sample.
func onsets(_ x: [Float]) -> [Double] {
    let hop = max(1, Int(0.0005 * rate))
    var energy: [Float] = []
    var i = 0
    while i + hop <= x.count {
        var sum: Float = 0
        for j in i..<(i + hop) { sum += x[j] * x[j] }
        energy.append(sum)
        i += hop
    }
    let threshold = (energy.max() ?? 0) * 0.01
    var times: [Double] = []
    var k = 1
    while k < energy.count - 1 {
        if energy[k] > threshold, energy[k] >= energy[k - 1], energy[k] >= energy[k + 1] {
            // The tick's centre: its energy's centroid over 6 ms around the peak.
            let from = max(0, k * hop - Int(0.003 * rate)), to = min(x.count, k * hop + Int(0.003 * rate))
            var weight = 0.0, moment = 0.0
            for j in from..<to {
                let e = Double(x[j] * x[j])
                weight += e
                moment += e * Double(j)
            }
            let time = weight > 0 ? moment / weight / rate : Double(k * hop) / rate
            if let last = times.last, time - last < 0.2 {
                k += 1
                continue
            }
            times.append(time)
            k += Int(0.2 * rate) / hop
            continue
        }
        k += 1
    }
    return times
}

// MARK: The plan, from the policy

let seconds = 150.0
let songA = song(bpm: 124, seconds: seconds, root: 57)
let songB = song(bpm: 126, seconds: seconds, root: 60)
guard let analysisA = TrackAnalyzer.analyze(songA, sampleRate: rate),
      let analysisB = TrackAnalyzer.analyze(songB, sampleRate: rate) else {
    print("SegueRenderCheck: analysis failed")
    exit(1)
}
let decision = SeguePolicy.decide(SegueRequest(outgoing: SegueSong(analysisA, voices: nil),
                                               incoming: SegueSong(analysisB, voices: nil), earliestExit: 0))
guard let plan = decision.plan, plan.level.isLocked else {
    print("SegueRenderCheck: no beat-matched plan (\(decision.level.rawValue))")
    exit(1)
}
print("plan: \(plan.level.rawValue) \(plan.shape.rawValue), \(format(plan.length, 1)) s from \(format(plan.outgoingStart, 1)) s, rate \(format(plan.rate, 4))")

// MARK: Speeds

let glide = SegueRender.glides(for: plan)
expect(abs(glide.outgoingRate * glide.incomingRate - 1) < 1e-9 && abs(glide.incomingRate / glide.outgoingRate - plan.rate) < 1e-9,
       "the two songs meet halfway: playing \(format(glide.outgoingRate, 4)), next \(format(glide.incomingRate, 4)) (rate \(format(plan.rate, 4)))")
expect(glide.incomingGlide >= 8 && glide.incomingGlide <= 24, "the next song comes back over \(format(glide.incomingGlide, 1)) s")
var unlocked = plan
unlocked.level = .simpleFade
expect(SegueRender.glides(for: unlocked) == SegueRender.Glide(outgoingRate: 1, incomingRate: 1, incomingGlide: 0),
       "a mix off the beat changes no speed")

// MARK: Exact at both ends, no step, no jump

if let mixed = render(plan, audio(songA), audio(songB), gains: (0.8, 0.9)) {
    let result = mixed.result
    print("file \(format(result.length, 1)) s, window \(format(result.windowStart, 2))–\(format(result.windowEnd, 2)) s, back at \(format(result.back, 2)) s, join \(format(result.join, 3)) s")
    expect(abs(result.handover - (plan.outgoingStart - SegueRender.lead)) < 1 / rate,
           "the file starts a second before the window (\(format(result.handover, 3)) s)")
    expect(result.headDifference == 0, "the file's start is the playing song's own samples exactly (\(result.headDifference))")
    expect(result.tailDifference == 0, "the file's end is the next song's own samples exactly (\(result.tailDifference))")
    expect(result.largestSpeedStep < 1e-4, "no deck's speed changes in a step (largest \(String(format: "%.1e", result.largestSpeedStep)) per frame)")
    expect(result.jumps == 0, "the lanes' processing never jumps (\(result.jumps))")
    expect(result.back > result.windowEnd + glide.incomingGlide * 0.9, "the next song is back at its own speed after its glide")
    // The join: the next song's own time right after the file, whole frames.
    let joinFrames = result.join * rate
    expect(abs(joinFrames - joinFrames.rounded()) < 1e-6, "the next song's file carries on from a whole frame (\(format(result.join, 5)) s)")
}

// MARK: Beats locked through the window, the tempo back gradually

let tickA = ticks(bpm: 124, seconds: seconds), tickB = ticks(bpm: 126, seconds: seconds)
// Both songs at their full level through the window (a lane-less stage would be silent), no echo, and
// the songs' exact ratio of tempos: the policy's estimate (from the analysis) may be off by a few
// hundred-thousandths, a few milliseconds over a long window, which is the plan's, not the render's.
print("the policy's rate \(format(plan.rate, 5)) against the songs' own \(format(124.0 / 126.0, 5))")
var timing = plan
timing.rate = 124.0 / 126.0
let flat = [SegueLane.Knot(at: 0, value: 0), SegueLane.Knot(at: 1, value: 0)]
timing.lanes = [SegueLane(side: .outgoing, target: .level, knots: flat), SegueLane(side: .incoming, target: .level, knots: flat)]
timing.echoDelay = nil
if let alone = render(timing, audio(tickA), audio(tickB), gains: (1, 0)),
   let other = render(timing, audio(tickA), audio(tickB), gains: (0, 1)) {
    let result = alone.result
    let beatsA = onsets(alone.out).filter { $0 >= result.windowStart && $0 <= result.windowEnd }
    let beatsB = onsets(other.out)
    let inWindow = beatsB.filter { $0 >= result.windowStart && $0 <= result.windowEnd }
    var offsets: [Double] = []
    for time in inWindow {
        if let nearest = beatsA.min(by: { abs($0 - time) < abs($1 - time) }), abs(nearest - time) < 0.1 {
            offsets.append(time - nearest)
        }
    }
    let spread = (offsets.max() ?? 0) - (offsets.min() ?? 0)
    expect(offsets.count >= inWindow.count - 1 && offsets.count >= 8,
           "the next song's beats meet the playing song's through the window (\(offsets.count) of \(inWindow.count))")
    expect(offsets.allSatisfy { abs($0) < 0.012 }, "within 12 ms (worst \(format((offsets.map(abs).max() ?? 0) * 1000, 1)) ms)")
    expect(spread < 0.001, "and they don't drift while both tempos glide (\(format(spread * 1000, 2)) ms from first to last)")
    // The playing song's tempo through the window: from its own to the middle one, without a step.
    let gapsA = zip(beatsA, beatsA.dropFirst()).map { $1 - $0 }
    let stepsA = zip(gapsA, gapsA.dropFirst()).map { abs($1 - $0) }
    expect((stepsA.max() ?? 1) < 0.0006, "the playing song's tempo glides through the window (largest change \(format((stepsA.max() ?? 0) * 1000, 2)) ms a beat)")
    let ownA = 60.0 / 124, ownB = 60.0 / 126
    let glide = SegueRender.glides(for: timing)
    if let last = gapsA.last {
        expect(abs(last - ownA / glide.outgoingRate) < 0.0005,
               "and ends at the middle tempo (beat \(format(last * 1000, 2)) ms, \(format(ownA / glide.outgoingRate * 1000, 2)) expected)")
    }
    // The next song after the window: from the middle tempo back to its own, beat by beat.
    let after = beatsB.filter { $0 > result.windowEnd }
    let gapsB = zip(after, after.dropFirst()).map { $1 - $0 }
    let stepsB = zip(gapsB, gapsB.dropFirst()).map { abs($1 - $0) }
    expect(gapsB.count >= 16, "the next song's beats after the window (\(gapsB.count))")
    expect((stepsB.max() ?? 1) < 0.0006, "its tempo comes back without a step (largest change \(format((stepsB.max() ?? 0) * 1000, 2)) ms a beat)")
    if let firstGap = gapsB.first {
        expect(abs(firstGap - ownB / glide.incomingRate) < 0.0005,
               "it leaves the window at the middle tempo (beat \(format(firstGap * 1000, 2)) ms, \(format(ownB / glide.incomingRate * 1000, 2)) expected)")
    }
    let ownBeats = zip(after, after.dropFirst()).filter { $0.0 >= result.back }.map { $1 - $0 }
    expect(!ownBeats.isEmpty && ownBeats.allSatisfy { abs($0 - ownB) < 0.0002 },
           "and ends at its own tempo (\(ownBeats.map { format($0 * 1000, 2) }.joined(separator: ", ")) ms; \(format(ownB * 1000, 2)) expected)")
}

// MARK: No click

// Two sine tones through the whole plan, lanes and all: from one sample to the next the sound may
// move no more than the tones themselves can (with room for the filters), so any step is a click.
// Without the echo (its repeats add up, legitimately, past what one tone can move).
var smooth = plan
smooth.lanes.removeAll { $0.target == .echo }
smooth.echoDelay = nil
if let tones = render(smooth, audio(sine(220, seconds: seconds)), audio(sine(330, seconds: seconds)), gains: (0.8, 0.9)) {
    var largest: Float = 0
    var at = 0
    for i in 1..<tones.out.count {
        let step = abs(tones.out[i] - tones.out[i - 1])
        if step > largest { largest = step; at = i }
    }
    let bound = Float(1.6 * 2 * Double.pi * (220 * 0.8 + 330 * 0.9) * 1.06 * 0.4 / rate)
    expect(largest <= bound, "no click from start to end (largest step \(format(Double(largest), 4)) at \(format(Double(at) / rate, 3)) s, bound \(format(Double(bound), 4)))")
}

if failures > 0 {
    print("SegueRenderCheck: \(failures) failed")
    exit(1)
}
print("SegueRenderCheck passed")
