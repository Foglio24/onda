// Checks AutoMix on songs made here, whose beats, bars, key and silences are known: the analysis
// (tempo, beat grid, downbeats, key, where the sound starts and ends, songs without a beat) and
// the planner (matched beats land on each other, tempos too far apart and fades get crossfades,
// albums play as they are, volumes and bass cuts move the right way).
// Run from the repository root: bash Tools/AutoMixCheck/run.sh
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
          chords: [(Int, Bool)] = major) -> (samples: [Float], onsets: [Double]) {
    let beat = 60 / bpm
    let count = Int((seconds - lead - tail) / beat)
    var x = [Float](repeating: 0, count: Int(seconds * rate))
    var onsets: [Double] = []
    for k in 0..<count {
        let t = lead + Double(k) * beat
        let start = Int(t * rate)
        onsets.append(t)
        for i in 0..<Int(0.25 * rate) where start + i < x.count {
            let time = Double(i) / rate
            let envelope = exp(-time * 18) * (k % 4 == 0 ? 1.4 : 1)
            x[start + i] += Float(0.8 * sin(2 * .pi * (55 + 90 * exp(-time * 40)) * time) * envelope)
        }
        let hat = Int((t + beat / 2) * rate)
        for i in 0..<Int(0.05 * rate) where hat + i < x.count {
            x[hat + i] += 0.15 * random.next() * Float(exp(-Double(i) / rate * 60))
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
                x[start + i] += Float(value * min(1, time / 0.02) * 0.08)
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
    let started = Date()
    let analysis = TrackAnalyzer.analyze(samples, sampleRate: rate)
    expect(analysis != nil, "\(name): analysed in \(format(Date().timeIntervalSince(started), 2)) s")
    return analysis
}

/// How far each true beat is from the nearest beat of the grid.
func deviations(_ analysis: TrackAnalysis, _ onsets: [Double]) -> [Double] {
    onsets.map { onset in
        let beat = ((onset - analysis.gridStart) / analysis.beatLength).rounded()
        return onset - analysis.beatTime(Int(beat))
    }
}

// MARK: Analysis

var analyses: [Double: TrackAnalysis] = [:]
var onsetsByTempo: [Double: [Double]] = [:]
for bpm in [124.0, 126, 118, 128, 100, 96] {
    let made = song(bpm: bpm)
    guard let analysis = analyze(made.samples, "\(Int(bpm)) BPM") else { continue }
    analyses[bpm] = analysis
    onsetsByTempo[bpm] = made.onsets
    let tempo = analysis.tempo
    let sameOrOctave = [bpm, bpm * 2, bpm / 2].contains { abs(tempo - $0) < 0.15 }
    expect(bpm == 96 ? sameOrOctave : abs(tempo - bpm) < 0.15, "\(Int(bpm)) BPM: tempo \(format(tempo))")
    expect(analysis.gridFit >= 0.9 && analysis.isGridLocked, "\(Int(bpm)) BPM: steady grid (fit \(format(analysis.gridFit, 2)))")
    let deviation = deviations(analysis, made.onsets)
    let mean = deviation.reduce(0, +) / Double(deviation.count)
    let spread = (deviation.max() ?? 0) - (deviation.min() ?? 0)
    expect(abs(mean) < 0.03 && spread < 0.006,
           "\(Int(bpm)) BPM: grid on the kicks (offset \(format(mean * 1000, 1)) ms, spread \(format(spread * 1000, 1)) ms)")
    expect(abs(analysis.soundStart - 1.5) < 0.05, "\(Int(bpm)) BPM: sound starts at \(format(analysis.soundStart)) s (1.5)")
    expect(analysis.soundEnd > (made.onsets.last ?? 0) && analysis.soundEnd <= 60,
           "\(Int(bpm)) BPM: sound ends at \(format(analysis.soundEnd)) s, after the last beat")
    expect(analysis.key == 0 && !analysis.minor, "\(Int(bpm)) BPM: key C major (got \(analysis.key)\(analysis.minor ? "m" : ""))")
    if bpm != 96 {
        let first = Int(((made.onsets[0] - analysis.gridStart) / analysis.beatLength).rounded())
        expect(analysis.isDownbeat(first) && analysis.isDownbeat(first + 4) && !analysis.isDownbeat(first + 1),
               "\(Int(bpm)) BPM: bars start on the strong kicks (downbeat \(analysis.downbeat))")
    }
    expect(analysis.beatCount == analysis.beatPulse.count && analysis.pulse(0..<analysis.beatCount) > 0.5,
           "\(Int(bpm)) BPM: every beat marked (pulse \(format(Double(analysis.pulse(0..<analysis.beatCount)), 2)))")
}

if let minor = analyze(song(bpm: 124, chords: aMinor).samples, "A minor") {
    expect(minor.key == 9 && minor.minor, "A minor progression: key A minor (got \(minor.key)\(minor.minor ? "m" : ""))")
}
let still = analyze(ambient(), "ambient")
if let still {
    expect(!still.isGridLocked, "ambient: no steady beat (fit \(format(still.gridFit, 2)))")
}
expect(TrackAnalyzer.analyze([Float](repeating: 0, count: Int(5 * rate)), sampleRate: rate) == nil,
       "a 5-second file isn't analysed")

// MARK: Planner

func checkLevels(_ plan: TransitionPlan, _ name: String) {
    let start = plan.levels(at: 0), end = plan.levels(at: 1)
    expect(start.outgoing > 0.99 && start.incoming < 0.01, "\(name): starts with the outgoing song alone")
    expect(end.outgoing < 0.01 && end.incoming > 0.99, "\(name): ends with the next song alone")
    var monotonic = true, steady = true
    var previous = start
    for step in 1...100 {
        let levels = plan.levels(at: Double(step) / 100)
        if levels.outgoing > previous.outgoing + 1e-4 || levels.incoming < previous.incoming - 1e-4 { monotonic = false }
        if levels.outgoing * levels.outgoing + levels.incoming * levels.incoming < 0.6 { steady = false }
        previous = levels
    }
    expect(monotonic, "\(name): the outgoing song only gets quieter, the next only louder")
    expect(steady, "\(name): no dip in loudness")
}

if let a = analyses[124], let b = analyses[126] {
    if let plan = TransitionPlanner.plan(from: a, to: b, sameAlbum: false) {
        expect(plan.style == .beatMatched, "124 → 126 BPM: beats matched (\(plan.style.rawValue))")
        expect(abs(plan.rate - b.beatLength / a.beatLength) < 1e-9 && abs(plan.rate - 124.0 / 126) < 0.002,
               "124 → 126 BPM: next song slowed to 124 (rate \(format(plan.rate, 4)))")
        expect(abs(plan.inStart - b.soundStart) < 0.02, "124 → 126 BPM: next song starts where its sound starts")
        expect(plan.outStart >= a.duration * 0.6 && plan.outEnd <= a.duration && plan.overlap > 6 && plan.overlap <= 24,
               "124 → 126 BPM: overlap \(format(plan.outStart, 2))–\(format(plan.outEnd, 2)) s (\(format(plan.overlap, 1)) s)")
        // Every beat of the next song, in the outgoing song's time, falls on a beat of the outgoing song.
        let toOutgoing = { (time: Double) in plan.outStart + (time - plan.inStart) / plan.rate }
        var gridWorst = 0.0
        var beat = b.beat(atOrAfter: plan.inStart)
        while toOutgoing(b.beatTime(beat)) < plan.outEnd {
            let time = toOutgoing(b.beatTime(beat))
            let nearest = a.beatTime(Int(((time - a.gridStart) / a.beatLength).rounded()))
            gridWorst = max(gridWorst, abs(nearest - time))
            beat += 1
        }
        expect(gridWorst < 0.002, "124 → 126 BPM: the next song's beats land on this one's (worst \(format(gridWorst * 1000, 2)) ms)")
        if let alignment = plan.alignment {
            let alignedBeat = Int(((alignment - a.gridStart) / a.beatLength).rounded())
            expect(a.isDownbeat(alignedBeat), "124 → 126 BPM: the next song's first downbeat lands on a downbeat")
            var firstDownbeat = b.beat(atOrAfter: b.soundStart - 0.05 * b.beatLength)
            while !b.isDownbeat(firstDownbeat) { firstDownbeat += 1 }
            expect(abs(toOutgoing(b.beatTime(firstDownbeat)) - alignment) < 0.001, "124 → 126 BPM: … exactly")
        } else {
            expect(false, "124 → 126 BPM: alignment given")
        }
        if let swapStart = plan.swapStart, let swapEnd = plan.swapEnd {
            expect(swapStart > 0.3 && swapStart < 0.7 && swapEnd > swapStart, "124 → 126 BPM: the bass passes over halfway")
            let before = plan.levels(at: swapStart / 2), after = plan.levels(at: (swapEnd + 1) / 2)
            expect(before.incomingBassCut == 1 && before.outgoingBassCut == 0 && after.incomingBassCut == 0 && after.outgoingBassCut == 1,
                   "124 → 126 BPM: one bass at a time")
        } else {
            expect(false, "124 → 126 BPM: bass swap planned")
        }
        checkLevels(plan, "124 → 126 BPM")
    } else {
        expect(false, "124 → 126 BPM: a plan")
    }

    expect(TransitionPlanner.plan(from: a, to: b, sameAlbum: true) == nil, "same album: no transition")

    if let c = analyses[100], let plan = TransitionPlanner.plan(from: a, to: c, sameAlbum: false) {
        expect(plan.style == .blend && plan.rate == 1 && plan.swapStart != nil,
               "124 → 100 BPM: too far apart, a short blend passing the bass (\(plan.style.rawValue), \(format(plan.overlap, 1)) s)")
        checkLevels(plan, "124 → 100 BPM")
    } else {
        expect(false, "124 → 100 BPM: a plan")
    }

    if let still, let plan = TransitionPlanner.plan(from: still, to: b, sameAlbum: false) {
        expect((plan.style == .cut || plan.style == .fade) && plan.rate == 1 && plan.outEnd <= still.duration,
               "ambient → 126 BPM: no beats to match, a crossfade at the end (\(plan.style.rawValue))")
        checkLevels(plan, "ambient → 126 BPM")
    } else {
        expect(false, "ambient → 126 BPM: a plan")
    }

    // A song fading out over its last ten seconds.
    var faded = song(bpm: 124).samples
    for index in faded.indices {
        let time = Double(index) / rate
        if time > 48 { faded[index] *= Float(pow(10, -2 * min(1, (time - 48) / 10))) }
    }
    if let fading = analyze(faded, "124 BPM fading out"), let still,
       let plan = TransitionPlanner.plan(from: fading, to: still, sameAlbum: false) {
        expect(plan.style == .fade && plan.overlap >= 3 && plan.overlap <= 10 && plan.outEnd <= fading.soundEnd + 0.01,
               "fade-out → ambient: the next song comes in during the fade (\(plan.style.rawValue), \(format(plan.overlap, 1)) s)")
        checkLevels(plan, "fade-out → ambient")
    } else {
        expect(false, "fade-out → ambient: a plan")
    }

    // Keys: the Camelot neighbours mix, a tritone apart doesn't.
    func keyed(_ key: Int, minor: Bool) -> TrackAnalysis {
        var copy = a
        copy.key = key
        copy.minor = minor
        copy.keyClarity = 0.9
        return copy
    }
    expect(TransitionPlanner.keysCompatible(keyed(0, minor: false), keyed(9, minor: true)), "keys: C major and A minor mix")
    expect(TransitionPlanner.keysCompatible(keyed(0, minor: false), keyed(7, minor: false)), "keys: C and G major mix")
    expect(TransitionPlanner.keysCompatible(keyed(9, minor: true), keyed(4, minor: true)), "keys: A and E minor mix")
    expect(!TransitionPlanner.keysCompatible(keyed(0, minor: false), keyed(6, minor: false)), "keys: C and F# major don't")
    var unclear = keyed(6, minor: false)
    unclear.keyClarity = 0.3
    expect(TransitionPlanner.keysCompatible(keyed(0, minor: false), unclear), "keys: an unclear key doesn't stand in the way")

    // Half and double time count as the same tempo.
    var half = b
    half.beatLength = b.beatLength * 2
    expect(TransitionPlanner.matchingRate(a, half).map { abs($0 - 124.0 / 126) < 0.002 } == true,
           "half time: matched like the same tempo")
    var far = b
    far.beatLength = 60 / 135
    expect(TransitionPlanner.matchingRate(a, far) == nil, "124 → 135 BPM: too far to match")
} else {
    expect(false, "planner: the songs were analysed")
}

// Progress follows the outgoing song's time, clamped.
let sample = TransitionPlan(style: .fade, outStart: 100, outEnd: 110, inStart: 0, rate: 1, alignment: nil,
                            swapStart: nil, swapEnd: nil, fadeIn: 0.5)
expect(sample.progress(atOutgoingTime: 95) == 0 && sample.progress(atOutgoingTime: 105) == 0.5
       && sample.progress(atOutgoingTime: 120) == 1, "progress: 0 before, half way, 1 after")

print(failures == 0 ? "AutoMixCheck: all checks passed" : "AutoMixCheck: \(failures) failed")
exit(failures == 0 ? 0 : 1)
