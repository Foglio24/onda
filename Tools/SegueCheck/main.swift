// Checks AutoMix's live transitions (Seaglass/Player/Segue) on songs made here, whose beats,
// bars and voices are known: which level the policy reaches and why the others weren't used, the
// plans it writes (valid, the same for the same songs, the faders' sum bounded, the incoming song
// silent before its window and the outgoing one after it), and the decks' sound on samples
// (untouched unarmed, silence and full level where the lanes say, a release back to plain, filters
// that stay stable while they sweep, a whole mix within range and without a click).
// Run from the repository root: bash Tools/SegueCheck/run.sh
import CoreAudio
import Foundation

var failures = 0
func expect(_ condition: Bool, _ message: String) {
    print(condition ? "ok   \(message)" : "FAIL \(message)")
    if !condition { failures += 1 }
}
func format(_ value: Double, _ digits: Int = 3) -> String { String(format: "%.\(digits)f", value) }
let rate = TrackAnalyzer.sampleRate

/// SplitMix64, so the noise is the same on every run.
struct Random {
    var state: UInt64
    mutating func next() -> Float {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Float(Double(z >> 11) / Double(1 << 53)) * 2 - 1
    }
}
var random = Random(state: 7)

func note(_ midi: Int) -> Double { 440 * pow(2, Double(midi - 69) / 12) }

let major = [(60, false), (65, false), (67, false), (60, false)]
let aMinor = [(57, true), (62, true), (64, true), (57, true)]

/// A song made to a click: a kick on every beat (stronger on the first of the bar), a hi-hat
/// between beats and a chord on every bar, with silence before and after.
func song(bpm: Double, seconds: Double = 60, lead: Double = 1.5, tail: Double = 2,
          chords: [(Int, Bool)] = major, introBars: Int = 0, kick: Double = 1) -> (samples: [Float], onsets: [Double]) {
    let beat = 60 / bpm
    let count = Int((seconds - lead - tail) / beat)
    var x = [Float](repeating: 0, count: Int(seconds * rate))
    var onsets: [Double] = []
    for k in 0..<count {
        let t = lead + Double(k) * beat
        let start = Int(t * rate)
        onsets.append(t)
        // The intro plays 10 dB lower.
        let level: Double = k < introBars * 4 ? 0.3 : 1
        for i in 0..<Int(0.25 * rate) where start + i < x.count {
            let time = Double(i) / rate
            let accent: Double = k % 4 == 0 ? 1.4 : 1
            let envelope: Double = exp(-time * 18) * accent * level * kick
            let sweep: Double = 55 + 90 * exp(-time * 40)
            x[start + i] += Float(0.8 * sin(2 * Double.pi * sweep * time) * envelope)
        }
        let hat = Int((t + beat / 2) * rate)
        for i in 0..<Int(0.05 * rate) where hat + i < x.count {
            x[hat + i] += 0.15 * Float(level) * random.next() * Float(exp(-Double(i) / rate * 60))
        }
        if k % 4 == 0 {
            let (root, minor) = chords[(k / 4) % chords.count]
            let pitches = [root, root + (minor ? 3 : 4), root + 7, root + 12].map(note)
            for i in 0..<Int(4 * beat * rate) where start + i < x.count {
                let time = Double(i) / rate
                var value = 0.0
                for pitch in pitches {
                    value += sin(2 * .pi * pitch * time) + 0.4 * sin(4 * .pi * pitch * time) + 0.2 * sin(6 * .pi * pitch * time)
                }
                x[start + i] += Float(value * min(1, time / 0.02) * 0.08 * level)
            }
        }
    }
    let peak = x.map { abs($0) }.max() ?? 1
    return (x.map { $0 / peak * 0.8 }, onsets)
}

/// Slowly swelling chords without any beat.
func ambient(seconds: Double = 60) -> [Float] {
    let partials: [(Int, Double, Double)] = [(48, 0.3, 0.05), (55, 1.7, 0.07), (60, 2.9, 0.04), (64, 4.1, 0.08), (67, 5.3, 0.06)]
    var x = [Float](repeating: 0, count: Int(seconds * rate))
    for i in x.indices {
        let t = Double(i) / rate
        var value = 0.0
        for (midi, phase, swell) in partials {
            value += sin(2 * .pi * note(midi) * t + phase) * (0.6 + 0.4 * sin(2 * .pi * swell * t))
        }
        x[i] = Float(value) * 0.1 + 0.002 * random.next()
    }
    return x
}


func analyze(_ samples: [Float], _ name: String) -> TrackAnalysis? {
    let analysis = TrackAnalyzer.analyze(samples, sampleRate: rate)
    expect(analysis != nil, "\(name): analysed")
    return analysis
}

// MARK: Policy

let songA = song(bpm: 124, seconds: 150)
let songB = song(bpm: 126, seconds: 150)
let songSlow = song(bpm: 90, seconds: 150)
guard let a = analyze(songA.samples, "124 BPM"), let b = analyze(songB.samples, "126 BPM"),
      let slow = analyze(songSlow.samples, "90 BPM"), let still = analyze(ambient(seconds: 150), "ambient") else {
    print("SegueCheck: analysis failed")
    exit(1)
}

func decide(_ x: TrackAnalysis, _ y: TrackAnalysis, voicesA: VocalActivity? = nil, voicesB: VocalActivity? = nil,
            sameAlbum: Bool = false) -> SegueDecision {
    SeguePolicy.decide(SegueRequest(outgoing: SegueSong(x, voices: voicesA), incoming: SegueSong(y, voices: voicesB),
                                    earliestExit: 0, sameAlbum: sameAlbum))
}

func checkPlan(_ plan: SeguePlan, _ x: TrackAnalysis, _ y: TrackAnalysis, _ name: String) {
    let problems = SegueValidator.problems(plan, outgoingDuration: x.duration, incomingDuration: y.duration)
    expect(problems.isEmpty, "\(name): the plan is valid \(problems)")
    guard let outgoing = plan.lanes.first(where: { $0.side == .outgoing && $0.target == .level }),
          let incoming = plan.lanes.first(where: { $0.side == .incoming && $0.target == .level }) else {
        return expect(false, "\(name): a level lane per side")
    }
    var worstSum = 0.0
    for step in 0...200 {
        let position = Double(step) / 200
        let ga = outgoing.isSilent(at: position) ? 0 : pow(10, outgoing.value(at: position) / 20)
        let gb = incoming.isSilent(at: position) ? 0 : pow(10, incoming.value(at: position) / 20)
        worstSum = max(worstSum, ga + gb)
    }
    expect(worstSum <= 1.1 + 1e-6, "\(name): the two faders never add up past 1.1 (\(format(worstSum)))")
    expect(incoming.isSilent(at: -0.01) || incoming.value(at: -0.01) <= -59, "\(name): the incoming song is silent before its window")
    expect(outgoing.isSilent(at: 1.01) || outgoing.value(at: 1.01) <= -59, "\(name): the outgoing song is silent after its window")
    expect(incoming.value(at: 1.01) > -0.5, "\(name): the incoming song at its full level after the window")
    expect(plan.outgoingStart >= x.soundStart + 60 - 0.05, "\(name): the outgoing song plays at least a minute (\(format(plan.outgoingStart, 1)) s)")
}

let close = decide(a, b)
print("124 → 126: \(close.level.rawValue) \(close.plan.map { "\($0.shape.rawValue), \($0.bars ?? 0) bars, rate \(format($0.rate, 4)), phase \(format(($0.phaseMedian ?? 0) * 1000, 1)) ms" } ?? "") — \(close.why)")
expect(close.level.isLocked, "close tempos and steady grids: beat-matched")
if let plan = close.plan {
    checkPlan(plan, a, b, "124 → 126")
    // Its bars as long as the outgoing song's: a 126 BPM song slowed to 124 BPM.
    expect(abs(plan.rate - 124.0 / 126.0) < 0.005, "the incoming song plays at the outgoing one's tempo (rate \(format(plan.rate, 4)))")
    expect((plan.phaseMedian ?? 1) <= 0.02, "beats within 20 ms (median \(format((plan.phaseMedian ?? 1) * 1000, 1)) ms)")
    expect(plan.restoreSeconds > 0, "the incoming song goes back to its own speed afterwards (\(format(plan.restoreSeconds, 1)) s)")
}
let again = decide(a, b)
expect(again.plan == close.plan, "the same songs, the same plan")

let far = decide(a, slow)
print("124 → 90: \(far.level.rawValue) — \(far.why)")
expect(!far.level.isLocked, "tempos 30 % apart: not beat-matched")
expect(far.attempts.contains { $0.level == .lockedLong && $0.cause != .noGrid }, "and the reason is the tempo, not the grid")
if let plan = far.plan { checkPlan(plan, a, slow, "124 → 90") }

let ambientPair = decide(still, b)
print("ambient → 126: \(ambientPair.level.rawValue) — \(ambientPair.why)")
expect(!ambientPair.level.isLocked && ambientPair.level != .hard, "no beat: neither locked nor a cut")
if let plan = ambientPair.plan { checkPlan(plan, still, b, "ambient → 126") }

// An album's songs that run into each other (no silence at the junction) play as they are; with
// silence between them they are mixed like any two songs.
var gaplessA = a, gaplessB = b
gaplessA.soundEnd = a.duration - 0.1
gaplessB.soundStart = 0.1
expect(decide(gaplessA, gaplessB, sameAlbum: true).level == .normal, "an album's songs that run into each other: played as they are")
expect(decide(a, b, sameAlbum: true).level == close.level, "an album's songs with silence between them: mixed as any two")

// Voices: both songs sing all over their edges (measured).
func voices(_ analysis: TrackAnalysis) -> VocalActivity {
    let count = Int(analysis.duration / VocalActivity.step)
    return VocalActivity(regions: [VocalActivity.Region(start: 0, values: [UInt8](repeating: 230, count: count))])
}
let singing = decide(a, b, voicesA: voices(a), voicesB: voices(b))
print("singing → singing: \(singing.level.rawValue) \(singing.plan?.shape.rawValue ?? "") — \(singing.why)")
if let plan = singing.plan {
    checkPlan(plan, a, b, "singing → singing")
    // Two voices at once: at most the guard's second, or the last-resort fade's short overlap.
    let overlapOK = plan.level == .hard || plan.shape == .cutOnBeat || plan.length <= 2.6
        || plan.attempts.contains { $0.cause == .guards && $0.detail.contains("voice") }
    expect(overlapOK, "two voices never sung over each other for long (\(plan.level.rawValue), \(format(plan.length, 1)) s)")
}

// MARK: Beat This!'s beats

/// A song whose tempo moves from `from` to `to` BPM over its length, as a band without a click does:
/// a kick on every beat (stronger on the first of the bar), a hi-hat between, a chord on every bar.
func drifting(from: Double, to: Double, seconds: Double) -> (samples: [Float], beats: [Double]) {
    var x = [Float](repeating: 0, count: Int(seconds * rate))
    var beats: [Double] = []
    var time = 1.5
    var k = 0
    while time < seconds - 2 {
        beats.append(time)
        let beat = 60 / (from + (to - from) * time / seconds)
        let start = Int(time * rate)
        for i in 0..<Int(0.25 * rate) where start + i < x.count {
            let t = Double(i) / rate
            let accent: Double = k % 4 == 0 ? 1.4 : 1
            x[start + i] += Float(0.8 * sin(2 * Double.pi * (55 + 90 * exp(-t * 40)) * t) * exp(-t * 18) * accent)
        }
        let hat = Int((time + beat / 2) * rate)
        for i in 0..<Int(0.05 * rate) where hat + i < x.count {
            x[hat + i] += 0.15 * random.next() * Float(exp(-Double(i) / rate * 60))
        }
        if k % 4 == 0 {
            let root = [57, 62, 64, 57][(k / 4) % 4]
            for i in 0..<Int(4 * beat * rate) where start + i < x.count {
                let t = Double(i) / rate
                var value = 0.0
                for pitch in [root, root + 4, root + 7].map(note) { value += sin(2 * .pi * pitch * t) }
                x[start + i] += Float(value * min(1, t / 0.02) * 0.08)
            }
        }
        time += beat
        k += 1
    }
    let peak = x.map { abs($0) }.max() ?? 1
    return (x.map { $0 / peak * 0.8 }, beats)
}

/// An analysis with the model's beats: `beats`, every fourth from `phase` a downbeat of logit `logit`
/// (the model is sure of them from about 2).
func withModel(_ analysis: TrackAnalysis, beats: [Double], phase: Int = 0, logit: Float = 3, jitter: Double = 0.004) -> TrackAnalysis {
    var noise = Random(state: 11)
    var copy = analysis
    let timed = beats.map { $0 + jitter * Double(noise.next()) }
    copy.modelBeats = timed.map(Float.init)
    let downbeats = timed.enumerated().filter { ($0.offset - phase) % 4 == 0 }.map { Float($0.element) }
    copy.modelDownbeats = downbeats
    copy.modelDownbeatLogits = [Float](repeating: logit, count: downbeats.count)
    return copy
}

let liveSong = drifting(from: 120, to: 124, seconds: 150)
if let live = analyze(liveSong.samples, "120 → 124 BPM, drifting") {
    let liveModel = withModel(live, beats: liveSong.beats)
    let bModel = withModel(b, beats: songB.onsets)
    let plain = decide(live, b)
    let modelled = decide(liveModel, bModel)
    print("drifting → 126 on the analysis' grid: \(plain.level.rawValue) — \(plain.why)")
    print("drifting → 126 on the model's beats: \(modelled.level.rawValue) \(modelled.plan.map { "\($0.shape.rawValue), \($0.bars ?? 0) bars, rate \(format($0.rate, 4)), phase \(format(($0.phaseMedian ?? 0) * 1000, 1)) ms" } ?? "") — \(modelled.why)")
    expect(modelled.level.isLocked, "a song whose tempo drifts: beat-matched on the model's beats")
    if let plan = modelled.plan {
        checkPlan(plan, liveModel, bModel, "drifting → 126 (model)")
        expect((plan.phaseMedian ?? 1) <= 0.02, "its beats within 20 ms (median \(format((plan.phaseMedian ?? 1) * 1000, 1)) ms)")
        expect(abs(plan.rate - (plan.tempo ?? 0) / 126) < 0.01 || abs(plan.rate * 126 - (plan.tempo ?? 0)) < 2,
               "the incoming song at the outgoing one's local tempo (\(format(plan.tempo ?? 0, 1)) BPM, rate \(format(plan.rate, 4)))")
    }
    // Bars from the model's downbeats: on the beat it says, even off the analysis' own.
    let shifted = SegueSong(withModel(b, beats: songB.onsets, phase: 1), voices: nil)
    let first = SegueSong(bModel, voices: nil)
    expect(first.fromModel && abs((first.barStarts.first ?? 0) - songB.onsets[0]) < 0.01, "bars start on the model's first downbeat")
    expect(abs((shifted.barStarts.first ?? 0) - songB.onsets[1]) < 0.01, "a downbeat a beat later moves the bars with it")
    let barGap = zip(first.barStarts.dropFirst(), first.barStarts).map { $0 - $1 }
    expect(barGap.allSatisfy { abs($0 - 4 * 60 / 126) < 0.02 }, "a bar every four of the model's beats")
    expect((first.barDown ?? []).allSatisfy { $0 > 0.9 }, "a sure downbeat on every bar")
    // Downbeats the model wasn't sure of don't make a stretch to beat-match on.
    let unsure = decide(withModel(a, beats: songA.onsets, logit: -1), withModel(b, beats: songB.onsets, logit: -1))
    print("unsure downbeats: \(unsure.level.rawValue) — \(unsure.why)")
    expect(!unsure.level.isLocked, "downbeats the model wasn't sure of: not beat-matched")
    // The same songs on the model's beats as on their grid: still beat-matched.
    let both = decide(withModel(a, beats: songA.onsets), bModel)
    expect(both.level.isLocked, "steady songs on the model's beats: beat-matched too (\(both.level.rawValue))")
}

// MARK: Decks

/// Runs `stage` on a stereo copy of `samples` (one buffer per channel), in blocks of `block` frames
/// from song time `start`.
func process(_ stage: SegueStage, _ samples: [Float], start: Double, rate sampleRate: Double, block: Int = 512) -> [Float] {
    var left = samples, right = samples
    let list = AudioBufferList.allocate(maximumBuffers: 2)
    defer { free(list.unsafeMutablePointer) }
    var offset = 0
    while offset < samples.count {
        let count = min(block, samples.count - offset)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(count * 4), mData: l.baseAddress! + offset)
                list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(count * 4), mData: r.baseAddress! + offset)
                stage.process(list, frames: count, time: start + Double(offset) / sampleRate, duration: Double(count) / sampleRate)
            }
        }
        offset += count
    }
    return left
}

let deckRate = 44_100.0
var noise = Random(state: 3)
let tone = (0..<Int(deckRate * 12)).map { i in Float(0.5 * sin(2 * Double.pi * 440 * Double(i) / deckRate)) + 0.05 * noise.next() }

let idle = SegueStage()
idle.prepare(sampleRate: deckRate, channels: 2, isFloat: true)
expect(process(idle, tone, start: 0, rate: deckRate) == tone, "unarmed, a deck leaves the samples untouched")

let compiler = SegueCompiler(tuning: SegueTuning())
let fadePlan = SeguePlan(level: .simpleFade, shape: .fade, outgoingStart: 4, incomingStart: 4, rate: 1, length: 4, bars: nil,
                         tempo: nil, phaseMedian: nil, phaseP95: nil, lanes: compiler.fade(), swap: 0.5, restoreSeconds: 0)
let incomingDeck = SegueStage()
incomingDeck.prepare(sampleRate: deckRate, channels: 2, isFloat: true)
incomingDeck.arm(fadePlan, side: .incoming)
let heardIn = process(incomingDeck, tone, start: 0, rate: deckRate)
func rms(_ x: [Float], from: Double, to: Double) -> Double {
    let range = Int(from * deckRate)..<min(x.count, Int(to * deckRate))
    guard !range.isEmpty else { return 0 }
    return (range.reduce(0.0) { $0 + Double(x[$1] * x[$1]) } / Double(range.count)).squareRoot()
}
let full = rms(tone, from: 1, to: 3)
expect(rms(heardIn, from: 0.5, to: 3.9) < full * 0.002, "the incoming deck is silent before its window")
expect(abs(rms(heardIn, from: 8.5, to: 11) / full - 1) < 0.02, "and at its full level after it")
let outgoingDeck = SegueStage()
outgoingDeck.prepare(sampleRate: deckRate, channels: 2, isFloat: true)
outgoingDeck.arm(fadePlan, side: .outgoing)
let heardOut = process(outgoingDeck, tone, start: 0, rate: deckRate)
expect(abs(rms(heardOut, from: 0.5, to: 3.9) / full - 1) < 0.02, "the outgoing deck is untouched before its window")
expect(rms(heardOut, from: 8.5, to: 11) < full * 0.002, "and silent after it")
// Halfway: neither a hole (the power at least half) nor peaks past the bound (the gains' sum).
let middle = rms(heardOut, from: 5.95, to: 6.05) / full, middleIn = rms(heardIn, from: 5.95, to: 6.05) / full
expect(middle * middle + middleIn * middleIn >= 0.5 && middle + middleIn <= 1.1 + 0.02,
       "halfway the two levels \(format(middle, 2)) and \(format(middleIn, 2)): no hole, sum bounded")
// On a constant signal the output is the gain itself: it must move without a step.
let constant = [Float](repeating: 0.5, count: Int(deckRate * 12))
for side in [SegueLane.Side.incoming, .outgoing] {
    let deck = SegueStage()
    deck.prepare(sampleRate: deckRate, channels: 2, isFloat: true)
    deck.arm(fadePlan, side: side)
    let heard = process(deck, constant, start: 0, rate: deckRate)
    var jump: Float = 0
    for i in 1..<heard.count { jump = max(jump, abs(heard[i] - heard[i - 1])) }
    expect(jump < 0.005 && heard.allSatisfy { $0.isFinite }, "\(side.rawValue): no step in the level (largest \(format(Double(jump), 5)))")
}

// A release from halfway: back to the plain sound.
let released = SegueStage()
released.prepare(sampleRate: deckRate, channels: 2, isFloat: true)
released.arm(fadePlan, side: .incoming)
_ = process(released, Array(tone[0..<Int(5 * deckRate)]), start: 0, rate: deckRate)
released.release(over: 0.4)
let afterRelease = process(released, Array(tone[Int(5 * deckRate)...]), start: 5, rate: deckRate)
expect(abs(rms(afterRelease, from: 1, to: 2) / full - 1) < 0.02, "released halfway, a deck is back to plain within half a second")

// A sweep from open to 400 Hz on noise: finite, never louder than it came in.
let sweepPlan = SeguePlan(level: .filtered, shape: .sweepOut, outgoingStart: 1, incomingStart: 1, rate: 1, length: 8, bars: nil,
                          tempo: nil, phaseMedian: nil, phaseP95: nil, lanes: compiler.filtered(.sweepOut, matchA: 1, matchB: 1),
                          swap: 0.6, restoreSeconds: 0)
var white = Random(state: 9)
let noiseIn = (0..<Int(deckRate * 10)).map { _ in 0.5 * white.next() }
let sweeper = SegueStage()
sweeper.prepare(sampleRate: deckRate, channels: 2, isFloat: true)
sweeper.arm(sweepPlan, side: .outgoing)
let swept = process(sweeper, noiseIn, start: 0, rate: deckRate, block: 37)
expect(swept.allSatisfy { $0.isFinite } && (swept.map(abs).max() ?? 9) <= 0.75, "a filter sweep stays stable (peak \(format(Double(swept.map(abs).max() ?? 0), 3)))")

// MARK: A whole mix

/// The beat-matched mix of the two songs made here, rendered through two decks: the incoming song
/// resampled to the plan's rate, as its player plays it.
if let plan = close.plan {
    let r = TrackAnalyzer.sampleRate
    let outDeck = SegueStage(), inDeck = SegueStage()
    outDeck.prepare(sampleRate: r, channels: 2, isFloat: true)
    inDeck.prepare(sampleRate: r, channels: 1, isFloat: true)
    outDeck.arm(plan, side: .outgoing)
    inDeck.arm(plan, side: .incoming)
    let from = plan.outgoingStart - 4, to = min(a.duration, plan.outgoingEnd + 4)
    let frames = Int((to - from) * r)
    let aPart = Array(songA.samples[Int(from * r)..<Int(from * r) + frames])
    // B's samples at the plan's rate, from its time at `from`.
    let bStart = plan.incomingTime(atOutgoing: from)
    let bPart = (0..<frames).map { i -> Float in
        let t = (bStart + Double(i) / r * plan.rate) * r
        let k = Int(t), u = Float(t - Double(k))
        guard k >= 0, k + 1 < songB.samples.count else { return 0 }
        return songB.samples[k] * (1 - u) + songB.samples[k + 1] * u
    }
    let heardA = process(outDeck, aPart, start: from, rate: r)
    // The incoming deck reads its song's own time: its blocks cover `rate` times as much of it.
    var heardB = bPart, offsetB = 0
    let list = AudioBufferList.allocate(maximumBuffers: 1)
    while offsetB < frames {
        let count = min(512, frames - offsetB)
        heardB.withUnsafeMutableBufferPointer { p in
            list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(count * 4), mData: p.baseAddress! + offsetB)
            inDeck.process(list, frames: count, time: bStart + Double(offsetB) / r * plan.rate, duration: Double(count) / r * plan.rate)
        }
        offsetB += count
    }
    free(list.unsafeMutablePointer)
    let mixed = zip(heardA, heardB).map { $0 + $1 }
    let peak = mixed.map(abs).max() ?? 0
    expect(peak <= 1.0, "the mix stays in range (peak \(format(Double(peak), 3)) from songs peaking at 0.8)")
    // Loudness through the mix: no hole and no bulge against the songs alone.
    let window = Int(0.5 * r)
    var lowest = 1e9, highest = 0.0
    var index = 0
    while index + window <= frames {
        let e = (mixed[index..<(index + window)].reduce(0.0) { $0 + Double($1 * $1) } / Double(window)).squareRoot()
        let ref = (aPart[index..<(index + window)].reduce(0.0) { $0 + Double($1 * $1) } / Double(window)).squareRoot()
        if ref > 0.01 { lowest = min(lowest, e / ref); highest = max(highest, e / ref) }
        index += window
    }
    expect(lowest > 0.35 && highest < 2.0, "through the mix the level stays near the songs' (\(format(20 * log10(lowest), 1)) to \(format(20 * log10(highest), 1)) dB)")
}

if failures > 0 {
    print("SegueCheck: \(failures) failed")
    exit(1)
}
print("SegueCheck passed")
