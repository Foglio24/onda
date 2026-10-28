// Checks AutoMix on songs made here, whose beats, bars, key, voices and silences are known: the
// analysis (tempo, beat grid, downbeats, key, bass, where the sound starts and ends, songs without
// a beat) and the choice of transition (beats matched only within 5 % per song, over the bars that
// avoid two voices at once, the tempo of the sung song kept, the next song's voice after this one
// has gone, clashing keys kept short, a long intro skipped, a fade-out mixed into, an album played
// as it is; the curves equal-power, never pumping, never louder together than the louder alone,
// the bass swapped only when both are carried by it), and the plan of up to 1.16 that playlist
// Mixes still start from.
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
for bpm in [124.0, 126, 118, 128, 140, 100, 96] {
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

// Sound from the very first sample (the grid's first beat falls before the file starts).
if let early = analyze(song(bpm: 124, lead: 0).samples, "124 BPM from the first sample") {
    expect(early.soundStart < 0.05 && abs(early.tempo - 124) < 0.15, "sound from the start: analysed (tempo \(format(early.tempo)))")
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

/// Voices: none at all, or sung from one time to another (the rest measured as not sung).
func instrumental(_ analysis: TrackAnalysis) -> VocalActivity { sung(analysis, from: 0, to: 0) }
func sung(_ analysis: TrackAnalysis, from start: Double, to end: Double) -> VocalActivity {
    let count = Int(analysis.duration / VocalActivity.step) + 1
    let values = (0..<count).map { index -> UInt8 in
        let time = Double(index) * VocalActivity.step
        return time >= start && time < end ? 255 : 0
    }
    return VocalActivity(regions: [VocalActivity.Region(start: 0, values: values)])
}

/// The song leaving alone at the start and the next alone at the end; the one only quieter, the
/// other only louder; and, from the analyses, together never louder than the louder of the two
/// alone (plus the headroom) nor much quieter.
func checkLevels(_ plan: TransitionPlan, _ a: TrackAnalysis, _ b: TrackAnalysis, _ name: String,
                 context: TransitionContext = TransitionContext()) {
    let start = plan.levels(at: 0), end = plan.levels(at: 1)
    expect(start.outgoing > 0.99 && start.incoming < 0.01 || plan.style == .gapless || plan.style == .sequence || plan.style == .album,
           "\(name): starts with the outgoing song alone")
    expect(end.outgoing < 0.01 && end.incoming > 0.99, "\(name): ends with the next song alone")
    var monotonic = true
    var previous = start
    for step in 1...200 {
        let levels = plan.levels(at: Double(step) / 200)
        if levels.outgoing > previous.outgoing + 1e-4 || levels.incoming < previous.incoming - 1e-4 { monotonic = false }
        previous = levels
    }
    expect(monotonic, "\(name): the outgoing song only gets quieter, the next only louder (no pumping)")
    let loudness = TransitionJudge(a, b, context).loudness(of: plan)
    let bump = loudness.map { $0.together - $0.louder }.max() ?? 0
    let step = loudness.count > 1 ? plan.overlap / Double(loudness.count - 1) : 0
    let deep = Double(loudness.filter { $0.louder - $0.together > 6 }.count) * step
    expect(bump <= context.tuning.headroom + 0.5, "\(name): together at most \(format(bump, 2)) dB over the louder alone")
    expect(deep <= 0.5, "\(name): more than 6 dB under the louder alone for \(format(deep, 2)) s at most")
}

/// Where a time of the next song falls in the outgoing song's time, once it has started.
func outgoingTime(_ plan: TransitionPlan, _ time: Double) -> Double {
    plan.outStart + (time - plan.inStart) / plan.incomingRate * plan.outgoingRate
}

/// The worst distance between the next song's beats in the overlap and the outgoing song's grid.
func worstBeat(_ plan: TransitionPlan, _ a: TrackAnalysis, _ b: TrackAnalysis) -> Double {
    var worst = 0.0
    var beat = b.beat(atOrAfter: plan.inStart)
    while outgoingTime(plan, b.beatTime(beat)) < plan.outEnd {
        let time = outgoingTime(plan, b.beatTime(beat))
        let nearest = a.beatTime(Int(((time - a.gridStart) / a.beatLength).rounded()))
        worst = max(worst, abs(nearest - time))
        beat += 1
    }
    return worst
}

/// Seconds where both songs sing and both are heard (each at least at 0.3).
func doubleVoice(_ plan: TransitionPlan, _ outgoing: VocalActivity, _ incoming: VocalActivity) -> Double {
    var seconds = 0.0
    let step = 0.05
    for time in stride(from: plan.outStart, to: plan.outEnd, by: step) {
        let p = plan.progress(atOutgoingTime: time)
        let levels = plan.levels(at: p)
        let incomingTime = plan.inStart + (time - plan.outStart) * plan.tempoOut / plan.tempoIn
        if levels.outgoing >= 0.3, levels.incoming >= 0.3, (outgoing.presence(at: time) ?? 0) > 0.5,
           (incoming.presence(at: incomingTime) ?? 0) > 0.5 {
            seconds += step
        }
    }
    return seconds
}

/// The rendered mix's timeline: the playing song glides to the meeting tempo before the next one
/// comes in, both stay on the same beat while together (also while the tempo moves), and the next
/// song ends back at its own tempo.
func checkSchedule(_ plan: TransitionPlan, _ a: TrackAnalysis, _ b: TrackAnalysis, _ name: String) {
    let schedule = MixSchedule(plan: plan)
    guard let first = schedule.steps.first, let last = schedule.steps.last else { return expect(false, "\(name): a schedule") }
    expect(abs(first.outgoingRate - 1) < 1e-9 && abs(last.incomingRate - 1) < 1e-6,
           "\(name): the mix starts at this song's tempo and ends at the next one's")
    let atEntry = schedule.positions(at: schedule.entry)
    expect(abs(atEntry.outgoing - plan.outStart) < 0.002 && schedule.entry > 1,
           "\(name): the next song comes in \(format(schedule.entry, 1)) s into the mix, at \(format(atEntry.outgoing, 2)) s of this one")
    let maximum = schedule.steps.map { max(abs(log($0.outgoingRate)), abs(log($0.incomingRate))) }.max() ?? 0
    expect(maximum <= log(1.05) + 1e-9, "\(name): no song's tempo changes by more than 5 % (\(format((exp(maximum) - 1) * 100, 2)) %)")
    guard plan.style == .beatMatched else { return }
    // Both songs' beat phases, through the overlap.
    // The next song's beat as matched (half or double time already counted in `tempoIn`).
    let beatIn = 60 / plan.tempoIn
    var worst = 0.0
    var time = schedule.entry + 0.05
    while true {
        let positions = schedule.positions(at: time)
        guard let incoming = positions.incoming, positions.outgoing < plan.outEnd else { break }
        let phaseOut = (positions.outgoing - a.gridStart) / a.beatLength
        let phaseIn = (incoming - b.gridStart) / beatIn
        var difference = (phaseOut - phaseIn).truncatingRemainder(dividingBy: 1)
        if difference > 0.5 { difference -= 1 }
        if difference < -0.5 { difference += 1 }
        worst = max(worst, abs(difference) * 60 / plan.tempoMeet)
        time += 0.25
    }
    expect(worst < 0.003, "\(name): on the same beat all through the overlap (worst \(format(worst * 1000, 2)) ms)")
    expect(schedule.join > plan.inStart && schedule.length < 120,
           "\(name): a mix of \(format(schedule.length, 1)) s, the next song carrying on from \(format(schedule.join, 1)) s")
}

let tritone = [(66, false), (71, false), (73, false), (66, false)]

if let a = analyses[124], let b = analyses[126] {
    let quiet = TransitionContext(outgoingVocals: instrumental(a), incomingVocals: instrumental(b))
    let choice = TransitionPlanner.choose(from: a, to: b, context: quiet)
    let plan = choice.plan
    print("     124 → 126, no voices: " + choice.summary.replacingOccurrences(of: "\n", with: "\n     "))
    expect(plan.style == .beatMatched && (plan.bars ?? 0) >= 4,
           "124 → 126 BPM without voices: beats matched over \(plan.bars ?? 0) bars (\(choice.chosen.title))")
    expect(abs(log(plan.outgoingRate)) <= log(1.05) && abs(log(plan.incomingRate)) <= log(1.05)
           && abs(plan.incomingRate / plan.outgoingRate - b.beatLength / a.beatLength) < 1e-9,
           "124 → 126 BPM: within 5 % each (this \(format(plan.outgoingRate, 4)), next \(format(plan.incomingRate, 4)))")
    expect(abs(b.beatLength / plan.incomingRate - a.beatLength / plan.outgoingRate) < 1e-9,
           "124 → 126 BPM: the same beat length while together")
    expect(plan.outStart >= a.duration * 0.45 && plan.outEnd <= a.duration && plan.overlap <= 48,
           "124 → 126 BPM: overlap \(format(plan.outStart, 2))–\(format(plan.outEnd, 2)) s (\(format(plan.overlap, 1)) s)")
    let worst = worstBeat(plan, a, b)
    expect(worst < 0.002, "124 → 126 BPM: the next song's beats land on this one's (worst \(format(worst * 1000, 2)) ms)")
    if let alignment = plan.alignment {
        let alignedBeat = Int(((alignment - a.gridStart) / a.beatLength).rounded())
        expect(a.isDownbeat(alignedBeat), "124 → 126 BPM: the next song's first counted downbeat lands on a downbeat")
    } else {
        expect(false, "124 → 126 BPM: alignment given")
    }
    if let swapStart = plan.swapStart, let swapEnd = plan.swapEnd {
        let before = plan.levels(at: swapStart / 2), after = plan.levels(at: (swapEnd + 1) / 2)
        expect(swapStart > 0.3 && swapEnd < 0.7 && swapEnd > swapStart && before.incomingBassCut == 1 && before.outgoingBassCut == 0
               && after.incomingBassCut == 0 && after.outgoingBassCut == 1,
               "124 → 126 BPM (both carried by the bass): the bass passes over the middle, one at a time")
        let middle = plan.levels(at: (swapStart + swapEnd) / 2)
        expect(middle.incomingBassCut > 0.05 && middle.incomingBassCut < 0.95, "124 → 126 BPM: … gradually")
    } else {
        expect(false, "124 → 126 BPM: bass swap planned")
    }
    checkLevels(plan, a, b, "124 → 126 BPM", context: quiet)
    checkSchedule(plan, a, b, "124 → 126 BPM")
    expect(choice.runnersUp.count >= 2 && choice.summary.contains(choice.chosen.title),
           "diagnostics: the choice and \(choice.runnersUp.count) alternatives, in words")

    // Not knowing the voices: careful, no long overlap.
    let unknown = TransitionPlanner.plan(from: a, to: b)
    expect(unknown.overlap <= 4 * 4 * a.beatLength + 0.5,
           "voices unknown: at most four bars together (\(format(unknown.overlap, 1)) s, \(unknown.style.rawValue))")

    // A sung to its end, the next sung from its first bar: never two singers at once for long.
    let singingA = sung(a, from: 10, to: a.soundEnd), singingB = sung(b, from: b.soundStart, to: b.soundEnd)
    let both = TransitionPlanner.plan(from: a, to: b, context: TransitionContext(outgoingVocals: singingA, incomingVocals: singingB))
    let doubled = doubleVoice(both, singingA, singingB)
    expect(doubled <= 1, "both sung at the junction: \(format(doubled, 2)) s of two voices (\(both.style.rawValue), \(format(both.overlap, 1)) s)")
    checkLevels(both, a, b, "both sung")

    // A's phrase ends; the next song has eight bars without voice: they come in under the end of
    // this one, and its voice after this one has gone.
    let phraseEnd = a.beatTime(a.beat(atOrAfter: a.audibleEnd - 16 * a.beatLength))
    let wordsAt = b.beatTime(b.firstDownbeat + 32)
    let endingA = sung(a, from: 10, to: phraseEnd), laterB = sung(b, from: wordsAt, to: b.soundEnd)
    let handed = TransitionPlanner.choose(from: a, to: b, context: TransitionContext(outgoingVocals: endingA, incomingVocals: laterB))
    let entryWords = outgoingTime(handed.plan, wordsAt)
    expect(handed.plan.style == .beatMatched && entryWords >= handed.plan.outEnd - 0.3
           && doubleVoice(handed.plan, endingA, laterB) == 0,
           "phrase ends, next song's voice later: \(handed.chosen.title), its words at \(format(entryWords, 1)) s, this song gone at \(format(handed.plan.outEnd, 1)) s")
    var dropAt = handed.plan.outEnd
    for time in stride(from: handed.plan.outStart, to: handed.plan.outEnd, by: 0.05)
    where handed.plan.levels(at: handed.plan.progress(atOutgoingTime: time)).outgoing < 0.9 {
        dropAt = time
        break
    }
    expect(dropAt >= phraseEnd - 0.3, "… and this song's phrase ends (\(format(phraseEnd, 1)) s) before it goes down (\(format(dropAt, 1)) s)")

    // The tempo of the song whose voice is heard stays.
    if let c = analyses[128] {
        let keepsA = TransitionPlanner.plan(from: a, to: c, context: TransitionContext(outgoingVocals: sung(a, from: 10, to: a.soundEnd),
                                                                                       incomingVocals: instrumental(c)))
        expect(keepsA.style == .beatMatched && abs(keepsA.outgoingRate - 1) < 1e-9 && abs(log(keepsA.incomingRate)) <= log(1.05),
               "124 → 128, this one sung: its tempo kept, the next one's changed \(format((keepsA.incomingRate - 1) * 100, 2)) %")
        let keepsB = TransitionPlanner.plan(from: a, to: c, context: TransitionContext(outgoingVocals: sung(a, from: 10, to: 30),
                                                                                       incomingVocals: sung(c, from: c.soundStart, to: c.soundEnd)))
        expect(keepsB.style != .beatMatched || abs(keepsB.incomingRate - 1) < 1e-9,
               "124 → 128, the next one sung: its tempo kept (\(keepsB.style.rawValue), next at \(format(keepsB.incomingRate, 4)))")
        checkSchedule(keepsA, a, c, "124 → 128")
        checkLevels(keepsA, a, c, "124 → 128")
    }

    // Tempos more than 10 % apart: a crossfade at their own tempos.
    for other in [140.0, 100] {
        guard let c = analyses[other] else { continue }
        let far = TransitionPlanner.plan(from: a, to: c, context: TransitionContext(outgoingVocals: instrumental(a), incomingVocals: instrumental(c)))
        expect(far.style != .beatMatched && far.incomingRate == 1 && far.outgoingRate == 1,
               "124 → \(Int(other)) BPM: no tempo change (\(far.style.rawValue), \(format(far.overlap, 1)) s)")
        checkLevels(far, a, c, "124 → \(Int(other)) BPM")
        checkSchedule(far, a, c, "124 → \(Int(other)) BPM")
    }

    // A crossfade is equal-power: half way, both at 71 % (not one at full and the other at 71 %).
    var crossfade = TransitionPlan(style: .blend, handover: 40, outStart: 42, outEnd: 50, inStart: 1, tempoOut: 124,
                                   tempoMeet: 124, tempoIn: 124, alignment: nil, swapStart: nil, swapEnd: nil, fadeIn: 1,
                                   filterOut: nil, bars: nil)
    crossfade.fadeOutFrom = 0
    let half = crossfade.levels(at: 0.5)
    expect(abs(half.outgoing * half.outgoing + half.incoming * half.incoming - 1) < 0.01 && abs(half.outgoing - half.incoming) < 0.01,
           "crossfade half way: \(format(Double(half.outgoing), 2)) and \(format(Double(half.incoming), 2)), together 0 dB")

    // Keys that clash: no long overlap; the same song in a key that goes, longer.
    if let clash = analyze(song(bpm: 126, chords: tritone).samples, "126 BPM in F# major") {
        let context = TransitionContext(outgoingVocals: instrumental(a), incomingVocals: instrumental(clash))
        let choice = TransitionPlanner.choose(from: a, to: clash, context: context)
        let together = TransitionJudge(a, clash, context).loudness(of: choice.plan).count
        expect(choice.plan.overlap < plan.overlap / 2,
               "C major → F# major: \(format(choice.plan.overlap, 1)) s together, under half of C → C (\(format(plan.overlap, 1)) s; \(choice.chosen.title), \(together) points)")
    }

    // Without bass to speak of in the next song: no bass swap (nothing to cut).
    if let light = analyze(song(bpm: 126, kick: 0.1).samples, "126 BPM, light bass") {
        let choice = TransitionPlanner.plan(from: a, to: light, context: TransitionContext(outgoingVocals: instrumental(a), incomingVocals: instrumental(light)))
        expect(light.bassShare(0..<light.beatCount) < 0.3 && choice.swapStart == nil
               && (0...20).allSatisfy { choice.levels(at: Double($0) / 20).incomingBassCut == 0 },
               "next song light on bass (\(format(light.bassShare(0..<light.beatCount), 2))): no bass cut (\(choice.style.rawValue))")
        checkLevels(choice, a, light, "light bass")
    }

    if let still {
        let plan = TransitionPlanner.plan(from: still, to: b)
        expect(plan.style != .beatMatched && plan.incomingRate == 1 && plan.overlap >= 1 && plan.outEnd <= still.duration,
               "ambient → 126 BPM: no beat to follow, a crossfade on the ending (\(plan.style.rawValue), \(format(plan.overlap, 1)) s)")
        checkLevels(plan, still, b, "ambient → 126 BPM")
        let back = TransitionPlanner.plan(from: b, to: still)
        expect(back.style != .beatMatched && back.incomingRate == 1, "126 BPM → ambient: no tempo change (\(back.style.rawValue), \(format(back.overlap, 1)) s)")
        checkLevels(back, b, still, "126 BPM → ambient")
    }

    // A song fading out over its last ten seconds: the next one comes in before the fade is over.
    var faded = song(bpm: 124).samples
    for index in faded.indices {
        let time = Double(index) / rate
        if time > 48 { faded[index] *= Float(pow(10, -2 * min(1, (time - 48) / 10))) }
    }
    if let fading = analyze(faded, "124 BPM fading out"), let still {
        let plan = TransitionPlanner.plan(from: fading, to: still)
        expect(plan.style != .gapless && plan.style != .sequence && plan.outStart < fading.soundEnd - 2 && plan.overlap >= 1,
               "fade-out → ambient: the next song comes in before the fade ends (\(plan.style.rawValue), from \(format(plan.outStart, 1)) s)")
        checkLevels(plan, fading, still, "fade-out → ambient")
    }

    // A next song with a quiet 16-bar intro: its main part arrives as this song leaves.
    if let intro = analyze(song(bpm: 126, seconds: 90, introBars: 16).samples, "126 BPM with an intro") {
        let main = intro.mainStart()
        expect(main.map { abs(intro.beatTime($0) - (1.5 + 64 * 60 / 126)) < 0.05 } == true,
               "intro: the main part found at bar 16 (\(main.map { format(intro.beatTime($0), 2) } ?? "none") s)")
        let context = TransitionContext(outgoingVocals: instrumental(a), incomingVocals: instrumental(intro))
        let plan = TransitionPlanner.plan(from: a, to: intro, context: context)
        expect(plan.style == .beatMatched && main.map { abs(outgoingTime(plan, intro.beatTime($0)) - plan.outEnd) < 0.05 } == true,
               "intro: its main part arrives as this song leaves (from \(format(plan.inStart, 1)) s, \(plan.bars ?? 0) bars)")
        expect(worstBeat(plan, a, intro) < 0.002, "intro: beats matched")
        checkSchedule(plan, a, intro, "intro")
        checkLevels(plan, a, intro, "intro", context: context)
    }

    // Two songs that follow each other on their album, played in order: as the album has them.
    let album = TransitionPlanner.choose(from: a, to: b, context: TransitionContext(albumOrder: true))
    let albumSchedule = MixSchedule(plan: album.plan)
    expect(album.plan.style == .album && album.plan.inStart == 0 && album.plan.outStart == a.duration
           && album.plan.levels(at: 0.5).outgoing == 1 && album.plan.levels(at: 0).incoming == 1
           && abs(albumSchedule.positions(at: albumSchedule.entry).outgoing - a.duration) < 0.002,
           "album in order: the next song from its first sample as this one's last ends, nothing faded")

    // The plan of up to 1.16, which a playlist's Mix starts from, is unchanged.
    let reference = TransitionPlanner.reference(from: a, to: b)
    expect(reference.style == .beatMatched && [8, 16].contains(reference.bars ?? 0)
           && abs(reference.incomingRate * reference.outgoingRate - 1) < 1e-9,
           "reference plan (playlist Mixes): the longest that fits (\(reference.bars ?? 0) bars), meeting halfway, as before")
    if let c = analyses[140], let d = analyses[100] {
        expect(TransitionPlanner.reference(from: a, to: c).style == .beatMatched && TransitionPlanner.reference(from: a, to: d).style == .beatMatched
               && TransitionPlanner.reference(from: c, to: d).style == .blend,
               "reference plan: 124 → 140 and → 100 matched, 140 → 100 crossfaded, as before")
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

    // Half and double time count as the same tempo; 30 % is the limit (playlist Mixes).
    var halfTime = b
    halfTime.beatLength = b.beatLength * 2
    expect(TransitionPlanner.tempoMatch(a, halfTime).map { abs($0.ratio - 124.0 / 126) < 0.002 && $0.octave == 2 } == true,
           "half time: matched like the same tempo")
    var near = b
    near.beatLength = 60 / 145
    expect(TransitionPlanner.tempoMatch(a, near) != nil, "124 → 145 BPM: close enough to match in a playlist's Mix")
    var far = b
    far.beatLength = 60 / 170
    expect(TransitionPlanner.tempoMatch(a, far) == nil, "124 → 170 BPM: too far to match")
} else {
    expect(false, "planner: the songs were analysed")
}

// MARK: Playlist Mix

/// Every part's options, one at a time with the others automatic: values in range, the song
/// leaving alone at the start and the next one alone at the end, and no change faster than a
/// 50 ms ramp (a click) through a 15-second overlap.
func checkDesignCurves() {
    let overlap = 15.0
    var designs: [(String, MixDesign)] = []
    for option in MixVolume.allCases { designs.append(("volume \(option.rawValue)", MixDesign(volume: option))) }
    for option in MixEQ.allCases { designs.append(("EQ \(option.rawValue)", MixDesign(eq: option))) }
    for option in MixFilter.allCases { designs.append(("filter \(option.rawValue)", MixDesign(filter: option))) }
    for option in MixEffect.allCases { designs.append(("effect \(option.rawValue)", MixDesign(effect: option))) }
    for preset in MixPreset.allCases { designs.append(("preset \(preset.rawValue)", MixDesign.preset(preset))) }
    var bad: [String] = []
    for (name, design) in designs {
        let bar = 2 / overlap, ramp = 0.05 / overlap
        let first = design.levels(at: 0, bar: bar, ramp: ramp), last = design.levels(at: 1, bar: bar, ramp: ramp)
        var ok = first.outgoing > 0.99 && first.incoming < 0.01 && last.outgoing < 0.01 && last.incoming > 0.99
        var previous = first
        let steps = Int(overlap * 44_100 / 512)
        for step in 1...steps {
            let levels = design.levels(at: Double(step) / Double(steps), bar: bar, ramp: ramp)
            let values = [levels.outgoing, levels.incoming, levels.outgoingBassCut, levels.incomingBassCut,
                          levels.outgoingMidCut, levels.outgoingHighCut, levels.incomingMidCut, levels.incomingHighCut,
                          levels.outgoingLowPass, levels.outgoingHighPass, levels.incomingLowPass, levels.incomingHighPass,
                          levels.reverb, levels.echo, levels.noise]
            if values.contains(where: { !$0.isFinite || $0 < -1e-4 || $0 > 1 + 1e-4 }) { ok = false }
            if abs(levels.outgoing - previous.outgoing) > 0.5 || abs(levels.incoming - previous.incoming) > 0.5 { ok = false }
            previous = levels
        }
        if !ok { bad.append(name) }
    }
    expect(bad.isEmpty, "Mix: \(designs.count) options start and end right, in range, without clicks\(bad.isEmpty ? "" : " (not: \(bad.joined(separator: ", ")))")")
}
checkDesignCurves()

expect(Camelot.code(key: 0, minor: false) == "8B" && Camelot.code(key: 9, minor: true) == "8A"
       && Camelot.code(key: 5, minor: true) == "4A" && Camelot.code(key: 4, minor: false) == "12B",
       "Camelot: C 8B, Am 8A, Fm 4A, E 12B")

if let a = analyses[124], let b = analyses[126] {
    let bar = 4 * a.beatLength
    let automatic = TransitionPlanner.reference(from: a, to: b)
    let fade = MixDesigner.plan(from: a, to: b, design: .preset(.fade))
    expect(fade.design?.volume == .crossfade && fade.style == .beatMatched && abs(fade.outEnd - automatic.outEnd) < 0.01,
           "Mix: a preset keeps the automatic timing, with its own curves")
    var shorter = MixDesign.preset(.blend)
    shorter.overlap = 4 * bar
    shorter.shift = -8 * bar
    let moved = MixDesigner.plan(from: a, to: b, design: shorter)
    expect(moved.bars == 4 && abs(moved.overlap - 4 * bar) < 0.05,
           "Mix: four bars together when asked (\(moved.bars ?? 0) bars, \(format(moved.overlap, 2)) s)")
    expect(moved.outEnd < automatic.outEnd - 7 * bar && worstBeat(moved, a, b) < 0.002,
           "Mix: eight bars earlier, still on the beat (ends at \(format(moved.outEnd, 1)) s, was \(format(automatic.outEnd, 1)) s)")
    checkSchedule(moved, a, b, "Mix moved")
    var free = MixDesign.preset(.wave)
    free.beatmatch = false
    free.overlap = 9
    let unmatched = MixDesigner.plan(from: a, to: b, design: free)
    expect(unmatched.style == .blend && unmatched.incomingRate == 1 && unmatched.outgoingRate == 1
           && abs(unmatched.overlap - 9) < 0.01, "Mix: beatmatching off, nine seconds without tempo changes")
    var looped = MixDesign.preset(.peak)
    looped.effect = .echoCutHalf
    let peak = MixDesigner.plan(from: a, to: b, design: looped)
    expect(peak.loop.map { abs($0.length - 4 * a.beatLength) < 0.001 && $0.start > peak.outStart && $0.start < peak.outEnd } == true,
           "Mix: a four-beat loop inside the overlap")
    expect(abs(peak.echoTime - a.beatLength / 2) < 0.001 && peak.echoFeedback > 0, "Mix: half-beat echo")
    let schedule = MixSchedule(plan: peak)
    expect(schedule.join > peak.inStart && schedule.length > MixSchedule(plan: automatic).length - 30,
           "Mix: an effect's tail stays inside the mix (\(format(schedule.length, 1)) s)")
}

// MARK: Bars and moving the songs

// Two-minute songs: room for every choice of bars.
if let a = analyze(song(bpm: 124, seconds: 120).samples, "124 BPM, 2 minutes"),
   let b = analyze(song(bpm: 126, seconds: 120).samples, "126 BPM, 2 minutes") {
    let bar = 4 * a.beatLength, barIn = 4 * b.beatLength
    let choices = MixDesigner.barChoices(from: a, to: b, design: MixDesign())
    expect(choices.map(\.bars) == [2, 4, 8, 16] && choices.allSatisfy(\.available),
           "bars: 2, 4, 8 and 16 offered and possible (\(choices.filter(\.available).map(\.bars)))")
    for bars in [2, 4, 8, 16] {
        var design = MixDesign()
        design.overlap = Double(bars) * bar
        let plan = MixDesigner.plan(from: a, to: b, design: design)
        expect(plan.bars == bars && MixDesigner.bars(of: plan) == bars && worstBeat(plan, a, b) < 0.002,
               "bars: \(bars) bars together on the beat (\(plan.bars ?? 0), \(format(plan.overlap, 1)) s)")
    }

    var design = MixDesign()
    design.overlap = 8 * bar
    let base = MixDesigner.plan(from: a, to: b, design: design)
    // The song leaving moved two and five bars earlier: the box (the bars) stays, the overlap
    // moves by exactly that much.
    for move in [-2, -5] {
        var moved = design
        moved.shift = Double(move) * bar
        let plan = MixDesigner.plan(from: a, to: b, design: moved)
        let difference = (plan.alignment ?? 0) - (base.alignment ?? 0)
        expect(plan.bars == 8 && abs(difference - Double(move) * bar) < 0.001 && abs(plan.overlap - base.overlap) < 0.001
               && worstBeat(plan, a, b) < 0.002,
               "moving the song leaving \(move) bars: overlap moved \(format(difference / bar, 2)) bars, same length, on the beat")
    }
    // The next song moved two bars later: it starts that much further in, on the beat.
    var later = design
    later.incomingShift = 2 * barIn
    let laterPlan = MixDesigner.plan(from: a, to: b, design: later)
    expect(laterPlan.bars == 8 && abs(laterPlan.inStart - (b.beatTime(b.firstDownbeat + 8) - 0.05)) < 0.001
           && worstBeat(laterPlan, a, b) < 0.002 && abs((laterPlan.alignment ?? 0) - (base.alignment ?? 0)) < 0.001,
           "moving the next song 2 bars: it starts at \(format(laterPlan.inStart, 2)) s, on the beat, the song leaving unmoved")
    checkSchedule(laterPlan, a, b, "next song moved")
    // Too far: brought back to where the mix can be made (the mix already ends with the song, the
    // next song can't start before its first beat, the first song keeps its first part), and kept
    // there, so dragging back moves at once.
    var past = design
    past.shift = 100 * bar
    past.incomingShift = -100 * barIn
    let kept = MixDesigner.normalized(past, from: a, to: b)
    let keptPlan = MixDesigner.plan(from: a, to: b, design: kept)
    var further = kept
    further.shift += bar
    let beyond = MixDesigner.plan(from: a, to: b, design: further)
    expect(kept.shift >= 0 && kept.shift < 4 * bar && kept.incomingShift == nil && keptPlan.bars == 8
           && (keptPlan.alignment ?? 0) + 8 * bar <= a.duration && beyond.outEnd == keptPlan.outEnd,
           "moving past the ends: the song leaving as late as the whole mix fits (\(format(kept.shift / bar, 0)) bars, ends at \(format(keptPlan.outEnd, 1)) of \(format(a.duration, 1)) s), the next from its first beat")
    var early = design
    early.shift = -100 * bar
    let earliest = MixDesigner.normalized(early, from: a, to: b)
    let earlyPlan = MixDesigner.plan(from: a, to: b, design: earliest)
    let unkept = MixDesigner.plan(from: a, to: b, design: early)
    expect(earliest.shift > -100 * bar && earliest.shift < 0 && earlyPlan.bars == 8 && earlyPlan.handover >= 15
           && abs(earlyPlan.overlap - base.overlap) < 0.01 && unkept.outStart == earlyPlan.outStart && unkept.inStart == earlyPlan.inStart,
           "moving too early: kept at \(format(earliest.shift / bar, 0)) bars (from \(format(earlyPlan.handover, 1)) s), the same mix")
    // Without beatmatching the next song moves by seconds.
    var free = MixDesign(beatmatch: false, overlap: 8)
    let freeBase = MixDesigner.plan(from: a, to: b, design: free)
    free.incomingShift = 6
    let freePlan = MixDesigner.plan(from: a, to: b, design: free)
    expect(abs(freePlan.inStart - freeBase.inStart - 6) < 0.001 && abs(freePlan.overlap - 8) < 0.01,
           "beatmatching off: the next song starts 6 s further in (\(format(freePlan.inStart, 2)) s)")
} else {
    expect(false, "bars: the two-minute songs were analysed")
}

// MARK: Up to 40 seconds from the ends

// The mix may be over up to 40 s before the song's end (its outro left out) and start up to 40 s
// into the next song (its intro left out), never more; a song whose last half minute is quieter
// is left as that part starts, not played to its end.
if let a = analyze(song(bpm: 124, seconds: 120).samples, "124 BPM, 2 minutes, again"),
   let b = analyze(song(bpm: 126, seconds: 120).samples, "126 BPM, 2 minutes, again") {
    let context = TransitionContext(outgoingVocals: instrumental(a), incomingVocals: instrumental(b))
    let all = TransitionPlanner.candidates(from: a, to: b, context: context)
    let skipOut = all.map { a.audibleEnd - $0.plan.outEnd }.max() ?? 0
    let skipIn = all.map { $0.plan.inStart - b.soundStart }.max() ?? 0
    expect(skipOut >= 30 && skipOut <= 40.01 && skipIn >= 30 && skipIn <= 40.01,
           "\(all.count) candidates: this song left up to \(format(skipOut, 1)) s before its end, the next entered up to \(format(skipIn, 1)) s in (40 at most)")
    var quieter = song(bpm: 124, seconds: 120).samples
    for index in quieter.indices where Double(index) / rate > 83 { quieter[index] *= 0.25 }
    if let outro = analyze(quieter, "124 BPM with a quieter outro") {
        let plan = TransitionPlanner.plan(from: outro, to: b, context: TransitionContext(outgoingVocals: instrumental(outro),
                                                                                        incomingVocals: instrumental(b)))
        expect(plan.outStart <= 90 && outro.audibleEnd - plan.outEnd >= 20,
               "quieter outro from 83 s: mixed from \(format(plan.outStart, 1)) s, over \(format(outro.audibleEnd - plan.outEnd, 1)) s before the end (\(plan.style.rawValue))")
        checkLevels(plan, outro, b, "quieter outro")
    }
}

// MARK: Lines drawn by hand

/// A design with its parts' options drawn as lines: what the editor starts from.
func traced(_ design: MixDesign, overlap: Double = 15) -> MixDesign {
    var drawn = design
    for line in MixLine.allCases where line != .effect || design.effect != .none {
        drawn.setLine(line, MixCurve.tracing { design.levels(at: $0, bar: 2 / overlap, ramp: 0.05 / overlap).value(of: line) })
    }
    return drawn
}

extension TransitionLevels {
    func value(of line: MixLine) -> Double { line.value(in: self) }
}

/// Lines drawn from every option sound like the option (within 3 per cent outside its cuts),
/// start and end right and never click, even over a short overlap.
func checkDrawnLines() {
    var bad: [String] = []
    var designs: [(String, MixDesign)] = []
    for option in MixVolume.allCases { designs.append(("volume \(option.rawValue)", MixDesign(volume: option))) }
    for option in MixEQ.allCases { designs.append(("EQ \(option.rawValue)", MixDesign(eq: option))) }
    for option in MixFilter.allCases { designs.append(("filter \(option.rawValue)", MixDesign(filter: option))) }
    for option in MixEffect.allCases { designs.append(("effect \(option.rawValue)", MixDesign(effect: option))) }
    for overlap in [15.0, 3.5] {
        let bar = 2 / overlap, ramp = 0.05 / overlap
        for (name, design) in designs {
            let drawn = traced(design, overlap: overlap)
            let first = drawn.levels(at: 0, bar: bar, ramp: ramp), last = drawn.levels(at: 1, bar: bar, ramp: ramp)
            var ok = first.outgoing > 0.99 && first.incoming < 0.01 && last.outgoing < 0.01 && last.incoming > 0.99
                && first.outgoingBassCut < 0.01 && first.outgoingLowPass < 0.01 && first.outgoingHighPass < 0.01
                && last.incomingBassCut < 0.01 && last.incomingLowPass < 0.01 && last.incomingHighPass < 0.01
            var close = 0, total = 0
            var previous = first
            let steps = Int(overlap * 44_100 / 512)
            for step in 1...steps {
                let progress = Double(step) / Double(steps)
                let levels = drawn.levels(at: progress, bar: bar, ramp: ramp)
                let option = design.levels(at: progress, bar: bar, ramp: ramp)
                for line in MixLine.allCases {
                    total += 1
                    if abs(levels.value(of: line) - option.value(of: line)) < 0.03 { close += 1 }
                }
                if abs(levels.outgoing - previous.outgoing) > 0.5 || abs(levels.incoming - previous.incoming) > 0.5 { ok = false }
                previous = levels
            }
            if !ok || Double(close) / Double(total) < 0.97 { bad.append("\(name) over \(format(overlap, 1)) s") }
        }
    }
    expect(bad.isEmpty, "lines drawn from \(designs.count) options sound like them, start and end right, no clicks\(bad.isEmpty ? "" : " (not: \(bad.joined(separator: ", ")))")")
}
checkDrawnLines()

do {
    // A filter line is a DJ's knob: open in the middle, a high-pass above, a low-pass below.
    var design = MixDesign()
    design.setLine(.outgoingFilter, MixCurve(points: [MixPoint(x: 0, y: 0.5), MixPoint(x: 0.5, y: 0.8), MixPoint(x: 1, y: 0.2)]))
    let middle = design.levels(at: 0.5, bar: 0.1, ramp: 0.003), end = design.levels(at: 1, bar: 0.1, ramp: 0.003)
    expect(abs(middle.outgoingHighPass - 0.6) < 0.01 && middle.outgoingLowPass == 0
           && abs(end.outgoingLowPass - 0.6) < 0.01 && end.outgoingHighPass == 0,
           "filter line: above the middle a high-pass, below a low-pass")
    // The ends where a song plays alone stay fixed.
    design.setLine(.outgoingVolume, MixCurve(points: [MixPoint(x: 0, y: 0.3), MixPoint(x: 0.6, y: 0.9), MixPoint(x: 1, y: 0.7)]))
    design.setLine(.effect, MixCurve(points: [MixPoint(x: 0.2, y: 0.4), MixPoint(x: 0.8, y: 1)]))
    let volume = design.lines?[.outgoingVolume]?.points ?? []
    let effect = design.lines?[.effect]?.points ?? []
    expect(volume.first == MixPoint(x: 0, y: 1) && volume.last == MixPoint(x: 1, y: 0)
           && effect.first == MixPoint(x: 0, y: 0) && effect.last == MixPoint(x: 1, y: 1),
           "lines: the ends where a song plays alone are fixed, the others free")
    // An effect line needs an effect: with none it does nothing; with an echo it drives the echo.
    expect(design.levels(at: 0.5, bar: 0.1, ramp: 0.003).echo == 0, "effect line: nothing without an effect")
    design.effect = .echoOutHalf
    let echoed = design.levels(at: 0.8, bar: 0.1, ramp: 0.003)
    expect(abs(echoed.echo - 1) < 0.01 && echoed.reverb == 0, "effect line: drives the echo chosen")
    design.setLine(.effect, nil)
    expect(design.lines?[.effect] == nil && design.lines?.count == 2, "lines: one taken away, the others kept")

    // Saved designs: a 1.14 one (no lines, no move of the next song) still reads; lines are kept.
    let old = #"{"preset":"fade","volume":"crossfade","eq":"none","filter":"none","effect":"none","loop":0,"beatmatch":true,"shift":0}"#
    let decoded = try? JSONDecoder().decode(MixDesign.self, from: Data(old.utf8))
    expect(decoded?.preset == .fade && decoded?.lines == nil && decoded?.incomingShift == nil, "saved 1.14 design: still read")
    let again = (try? JSONEncoder().encode(design)).flatMap { try? JSONDecoder().decode(MixDesign.self, from: $0) }
    expect(again == design, "design with lines: saved and read back the same")
}

// Progress follows the outgoing song's time, clamped.
let sample = TransitionPlan(style: .fade, handover: 99.5, outStart: 100, outEnd: 110, inStart: 0, tempoOut: 120,
                            tempoMeet: 120, tempoIn: 120, alignment: nil, swapStart: nil, swapEnd: nil, fadeIn: 0.5,
                            filterOut: nil, bars: nil)
expect(sample.progress(atOutgoingTime: 95) == 0 && sample.progress(atOutgoingTime: 105) == 0.5
       && sample.progress(atOutgoingTime: 120) == 1, "progress: 0 before, half way, 1 after")

print(failures == 0 ? "AutoMixCheck: all checks passed" : "AutoMixCheck: \(failures) failed")
exit(failures == 0 ? 0 : 1)
