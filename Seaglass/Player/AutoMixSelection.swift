import Foundation

// How AutoMix chooses a transition: it builds many ways of taking one song into the next (matched
// beats over 2, 4, 8 or 16 bars with either song's tempo kept or both meeting, crossfades of a few
// seconds without tempo changes, the next song entering in a fade-out, the silence between the two
// left out, or the two one after the other), works out from the analyses how each would sound
// (without rendering any), gives each a cost for every problem it would have, and plays the
// cheapest. The problems are measured where the two songs actually play together: how steady the
// beats are there, whether the harmonies clash, whether two voices sing at once or a phrase is cut,
// how the loudness moves, how much the tempo changes and where, whether the mix starts and ends on
// a phrase, and how much of either song is left out. When nothing is good enough it falls back to a
// short, plain crossfade; songs that follow each other on their album, played in order, stay as
// the album has them.

// MARK: Vocals

/// Where a song is sung near its start and its end, from the karaoke's vocal model (see
/// `VocalDetector`): the chance (0…255 for 0…1) that a voice sings, every `step` seconds of the
/// song, over the stretches that were measured.
struct VocalActivity: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let step = 0.25

    struct Region: Codable, Equatable, Sendable {
        var start: Double
        var values: [UInt8]
        var end: Double { start + Double(values.count) * VocalActivity.step }
    }

    var version = VocalActivity.currentVersion
    var regions: [Region] = []

    /// The chance a voice sings at a time of the song; nil where it wasn't measured.
    func presence(at time: Double) -> Double? {
        for region in regions where time >= region.start && time < region.end && !region.values.isEmpty {
            let index = min(region.values.count - 1, Int((time - region.start) / Self.step))
            return Double(region.values[index]) / 255
        }
        return nil
    }

    /// Whether the stretch from `start` to `end` was measured.
    func covers(from start: Double, to end: Double) -> Bool {
        regions.contains { $0.start <= start + 0.01 && $0.end >= end - 0.01 }
    }

    /// The first time from `start` at which a voice sings for at least `hold` seconds.
    func firstVoice(after start: Double, hold: Double = 1) -> Double? {
        let needed = max(1, Int((hold / Self.step).rounded()))
        for region in regions.sorted(by: { $0.start < $1.start }) where region.end > start {
            var run = 0
            for (index, value) in region.values.enumerated() {
                let time = region.start + Double(index) * Self.step
                guard time >= start else { continue }
                run = value >= 128 ? run + 1 : 0
                if run >= needed { return time - Double(needed - 1) * Self.step }
            }
        }
        return nil
    }

    /// Where the last stretch of voice (at least `hold` seconds) before `end` stops.
    func lastVoice(before end: Double, hold: Double = 1) -> Double? {
        let needed = max(1, Int((hold / Self.step).rounded()))
        for region in regions.sorted(by: { $0.start > $1.start }) where region.start < end {
            var run = 0
            for index in region.values.indices.reversed() {
                let time = region.start + Double(index) * Self.step
                guard time < end else { continue }
                run = region.values[index] >= 128 ? run + 1 : 0
                if run >= needed { return time + Double(needed) * Self.step }
            }
        }
        return nil
    }
}

// MARK: Settings

/// The problems a transition can have, each measured by `TransitionPlanner`.
enum TransitionCriterion: String, CaseIterable, Sendable {
    /// Beat-matched where the beats don't sit on the grid (live or freely played): they flam.
    case rhythm
    /// Two beats heard together without being matched.
    case unsyncedBeats
    /// A rhythm that stops and starts again off its beat (no overlap between two songs with a beat).
    case grooveBreak
    /// The song leaving stops while still loud (no overlap after a song that doesn't end by itself).
    case abruptEnd
    /// Harmonies that clash while both play, the more the longer and the more melodic.
    case harmony
    /// Two voices singing at once.
    case vocalClash
    /// The song leaving faded or left out while it sings.
    case vocalCut
    /// The next song's voice coming in while it is still low, or over the song leaving while that
    /// is still up, or its first words left out.
    case buriedEntry
    /// Both songs at full for a while: two whole arrangements at once.
    case crowded
    /// A jump in loudness from the song leaving to the next one.
    case energy
    /// A hole in the sound: quieter than either song for a while (worse between songs with a beat).
    case gap
    /// Tempo changed, the more where a voice is heard.
    case tempo
    /// A mix that doesn't start or end on a phrase (every 4 or 8 bars).
    case phrase
    /// Loud music of either song left out.
    case skipped
    /// Long transitions and pauses cost a little: they must be better to be chosen.
    case length

    var title: String {
        switch self {
        case .rhythm: return String(localized: "ritmo instabile")
        case .unsyncedBeats: return String(localized: "ritmi sfasati")
        case .grooveBreak: return String(localized: "ritmo interrotto")
        case .abruptEnd: return String(localized: "finale troncato")
        case .harmony: return String(localized: "tonalità in contrasto")
        case .vocalClash: return String(localized: "voci sovrapposte")
        case .vocalCut: return String(localized: "frase tagliata")
        case .buriedEntry: return String(localized: "voce in entrata coperta")
        case .crowded: return String(localized: "due brani pieni insieme")
        case .energy: return String(localized: "salto di volume")
        case .gap: return String(localized: "calo di energia")
        case .tempo: return String(localized: "cambio di tempo")
        case .phrase: return String(localized: "fuori frase")
        case .skipped: return String(localized: "parti saltate")
        case .length: return String(localized: "lunghezza")
        }
    }
}

/// What AutoMix chooses its transitions by: limits, and how much each problem weighs (each
/// problem's cost is about 1 when it is clearly heard). These are starting points, set on songs
/// made for the checks and to be tuned by listening; they don't come from any other app.
struct AutoMixTuning: Sendable {
    /// The most either song's tempo may change (5 %): beyond it the change is heard, and the two
    /// are crossfaded at their own tempos.
    var maximumRateChange = 0.05
    /// The share of a stretch's sound below 150 Hz from which it is carried by its bass: then,
    /// and only then, the bass passes from one song to the other (two basslines at once are mud).
    var bassRich = 0.3
    /// When a voice wasn't measured: the chance assumed where the song plays at full, and within
    /// its first and last 20 seconds (intros and outros are more often played than sung); less
    /// where it is quiet. Overlaps then cost more: AutoMix stays careful when it doesn't know.
    var unknownVocal = 0.5
    var unknownVocalAtEdges = 0.3
    /// How far (dB, as heard: K-weighted) the two together may sound above the louder of the two
    /// alone. Not a target: equal-power curves keep two songs about as loud as one; this is room
    /// for where both play at full (a beat-matched mix's middle bars), so two arrangements at once
    /// may sound a little fuller without a jump, and the trims hold them down only past it. The
    /// checks measure the drops as well (Tools/AutoMixLevels).
    var headroom = 1.0
    /// The beat-matched length that costs nothing (bars): shorter or longer costs `lengthCost`
    /// per halving or doubling (so equally good candidates don't default to the shortest).
    var preferredBars = 8.0
    /// The same for crossfades without beatmatching (seconds).
    var preferredCrossfade = 4.0
    /// How long before the end of the song playing the mix may be over (its outro left out), and
    /// how far into the next song it may start (its intro left out), in seconds.
    var longestSkip = 40.0
    var lengthCost = 0.15
    /// Above this total no candidate is good enough: a short plain crossfade instead.
    var acceptableCost = 3.0
    var weights: [TransitionCriterion: Double] = [
        .rhythm: 1.5, .unsyncedBeats: 1.2, .grooveBreak: 1.5, .abruptEnd: 1.2, .harmony: 1.5, .vocalClash: 2.0, .vocalCut: 1.0,
        .buriedEntry: 0.6, .crowded: 0.6, .energy: 0.8, .gap: 1.0, .tempo: 0.8, .phrase: 0.6, .skipped: 1.0, .length: 1.0,
    ]

    static let standard = AutoMixTuning()
}

/// What the planner knows besides the two analyses.
struct TransitionContext: Sendable {
    /// The gains the two songs play at ("Volume uniforme"), for their loudness in the mix.
    var outgoingGain: Float = 1
    var incomingGain: Float = 1
    /// Their voices, where measured (nil: not known).
    var outgoingVocals: VocalActivity? = nil
    var incomingVocals: VocalActivity? = nil
    /// The two follow each other on their album, played in order.
    var albumOrder = false
    var tuning = AutoMixTuning.standard
}

/// One way of mixing the two songs, with what each problem costs (already weighted).
struct TransitionCandidate: Sendable {
    enum Kind: Equatable, Sendable {
        case beatMatched(bars: Int, keeps: KeptTempo)
        case blend(seconds: Int)
        case fade
        case gapless
        case sequence
        case album
    }

    /// Whose tempo the two play at while beat-matched.
    enum KeptTempo: Equatable, Sendable {
        case outgoing, incoming, both
    }

    var kind: Kind
    var plan: TransitionPlan
    var costs: [TransitionCriterion: Double] = [:]
    var total = 0.0
    /// Why it can't be played at all (nil: it can).
    var veto: String?

    var title: String {
        switch kind {
        case .beatMatched(let bars, let keeps):
            switch keeps {
            case .outgoing: return String(localized: "a tempo, \(bars) battute, tempo del primo")
            case .incoming: return String(localized: "a tempo, \(bars) battute, tempo del secondo")
            case .both: return String(localized: "a tempo, \(bars) battute")
            }
        case .blend(let seconds): return String(localized: "dissolvenza di \(seconds) s")
        case .fade: return String(localized: "nella dissolvenza finale")
        case .gapless: return String(localized: "senza silenzio tra i brani")
        case .sequence: return String(localized: "uno dopo l'altro")
        case .album: return String(localized: "come nell'album")
        }
    }

    /// The family it belongs to, for the runners-up (one of each).
    var family: Int {
        switch kind {
        case .beatMatched: return 0
        case .blend: return 1
        case .fade: return 2
        case .gapless, .sequence: return 3
        case .album: return 4
        }
    }

    /// Its biggest problems, for the diagnostics.
    func mainProblems(_ count: Int = 2) -> [TransitionCriterion] {
        costs.filter { $0.value >= 0.15 }.sorted { $0.value > $1.value }.prefix(count).map(\.key)
    }
}

/// The transition chosen and the best of the other kinds, with why.
struct TransitionChoice: Sendable {
    var chosen: TransitionCandidate
    var runnersUp: [TransitionCandidate]
    var considered: Int
    /// No candidate was good enough: a short plain crossfade.
    var fallback: Bool
    var outgoingVocalsMeasured: Bool
    var incomingVocalsMeasured: Bool

    var plan: TransitionPlan { chosen.plan }

    /// In words, for Settings → Diagnostica.
    var summary: String {
        func cost(_ value: Double) -> String { String(format: "%.2f", value) }
        func problems(_ candidate: TransitionCandidate) -> String {
            let names = candidate.mainProblems().map(\.title)
            return names.isEmpty ? String(localized: "nessun problema") : names.joined(separator: ", ")
        }
        var text = fallback
            ? String(localized: "Nessun candidato abbastanza buono: \(chosen.title)")
            : String(localized: "Scelta: \(chosen.title) (costo \(cost(chosen.total)); \(problems(chosen)))")
        text += " · " + String(localized: "\(considered) candidati")
        let vocals: String
        switch (outgoingVocalsMeasured, incomingVocalsMeasured) {
        case (true, true): vocals = String(localized: "voci misurate")
        case (false, false): vocals = String(localized: "voci non misurate")
        default: vocals = String(localized: "voci misurate in parte")
        }
        text += " · " + vocals
        for other in runnersUp {
            let reason = other.veto ?? problems(other)
            text += "\n" + String(localized: "Scartata: \(other.title) (costo \(cost(other.total)); \(reason))")
        }
        return text
    }
}

// MARK: Choosing

extension TransitionPlanner {
    /// Weighs every way of mixing the two songs and returns the cheapest (see the top of this file).
    static func choose(from a: TrackAnalysis, to b: TrackAnalysis,
                       context: TransitionContext = TransitionContext()) -> TransitionChoice {
        let judge = TransitionJudge(a, b, context)
        let outgoingMeasured = context.outgoingVocals.map { $0.covers(from: max(a.soundStart, a.audibleEnd - 30), to: a.audibleEnd) } ?? false
        let incomingMeasured = context.incomingVocals.map { $0.covers(from: b.soundStart, to: min(b.soundEnd, b.soundStart + 30)) } ?? false
        if context.albumOrder {
            let candidate = judge.evaluate(albumPlan(a, b), .album)
            return TransitionChoice(chosen: candidate, runnersUp: [], considered: 1, fallback: false,
                                    outgoingVocalsMeasured: outgoingMeasured, incomingVocalsMeasured: incomingMeasured)
        }
        let candidates = candidates(a, b, judge: judge)
        let playable = candidates.filter { $0.veto == nil }.sorted { $0.total < $1.total }
        var runnersUp: [TransitionCandidate] = []
        guard let best = playable.first, best.total <= context.tuning.acceptableCost else {
            let fallback = judge.evaluate(prudent(a, b), .blend(seconds: 3))
            for family in 0..<4 {
                if let other = playable.first(where: { $0.family == family }) { runnersUp.append(other) }
            }
            return TransitionChoice(chosen: fallback, runnersUp: runnersUp, considered: candidates.count, fallback: true,
                                    outgoingVocalsMeasured: outgoingMeasured, incomingVocalsMeasured: incomingMeasured)
        }
        for family in 0..<4 where family != best.family {
            if let other = playable.first(where: { $0.family == family }) {
                runnersUp.append(other)
            } else if let vetoed = candidates.first(where: { $0.family == family && $0.veto != nil }) {
                runnersUp.append(vetoed)
            }
        }
        // And the best other length of the same kind.
        if let same = playable.dropFirst().first(where: { $0.family == best.family && $0.kind != best.kind }) {
            runnersUp.insert(same, at: 0)
        }
        return TransitionChoice(chosen: best, runnersUp: runnersUp, considered: candidates.count, fallback: false,
                                outgoingVocalsMeasured: outgoingMeasured, incomingVocalsMeasured: incomingMeasured)
    }

    typealias Option = (plan: TransitionPlan, kind: TransitionCandidate.Kind)

    /// Every candidate for the two songs (not for an album in order), weighed.
    static func candidates(from a: TrackAnalysis, to b: TrackAnalysis,
                           context: TransitionContext = TransitionContext()) -> [TransitionCandidate] {
        candidates(a, b, judge: TransitionJudge(a, b, context))
    }

    private static func candidates(_ a: TrackAnalysis, _ b: TrackAnalysis, judge: TransitionJudge) -> [TransitionCandidate] {
        var options = beatMatchedOptions(a, b, judge: judge)
        options += blendOptions(a, b, judge: judge)
        options += fadeOptions(a, b)
        options += pauseOptions(a, b)
        return options.map { judge.evaluate($0.plan, $0.kind) }
    }

    /// The earliest the song leaving may start to go: it keeps its first ten seconds and half.
    private static func earliestExit(_ a: TrackAnalysis) -> Double { max(a.soundStart + 10, a.duration * 0.5) }

    // MARK: Beat-matched

    /// Beats matched over 2, 4, 8 and 16 bars; the overlap ending on the downbeat by the song's end
    /// or on a phrase up to `longestSkip` seconds before it; the next song coming in from its first
    /// downbeat, so that its main part or its first words arrive as the overlap ends, or from a
    /// phrase up to `longestSkip` seconds into it; the two at the tempo of either or meeting
    /// between. Only within `maximumRateChange` for each song.
    private static func beatMatchedOptions(_ a: TrackAnalysis, _ b: TrackAnalysis, judge: TransitionJudge) -> [Option] {
        let tuning = judge.context.tuning
        guard a.isGridLocked, b.isGridLocked, let match = tempoMatch(a, b) else { return [] }
        let limit = log(1 + tuning.maximumRateChange)
        guard abs(log(match.ratio)) <= 2 * limit + 1e-9 else { return [] }
        let beat = a.beatLength
        let latestEnd = a.audibleEnd + 0.5 * beat
        var latest = a.beat(atOrAfter: latestEnd)
        while latest > 0, a.beatTime(latest) > latestEnd || !a.isDownbeat(latest) { latest -= 1 }
        guard latest > 0 else { return [] }
        var ends: [Int] = []
        var end = latest
        while end > 0, a.beatTime(end) >= latestEnd - tuning.longestSkip, ends.count < 10 {
            if end == latest || judge.shapeA.phrase(atBeat: end) >= 0.75 { ends.append(end) }
            end -= 4
        }
        let tempoOut = a.tempo, tempoIn = b.tempo * match.octave
        var meets: [(tempo: Double, keeps: TransitionCandidate.KeptTempo)] = []
        if abs(log(tempoOut / tempoIn)) < 0.002 {
            meets = [(tempoOut, .both)]
        } else {
            if abs(log(tempoOut / tempoIn)) <= limit + 1e-9 { meets += [(tempoOut, .outgoing), (tempoIn, .incoming)] }
            meets.append(((tempoOut * tempoIn).squareRoot(), .both))
        }
        let voice = judge.context.incomingVocals?.firstVoice(after: b.soundStart)
        // The next song's phrases it may start on, up to `longestSkip` seconds in.
        var phrases: [Int] = []
        var downbeat = b.firstDownbeat + 4
        while b.beatTime(downbeat) <= b.soundStart + tuning.longestSkip, downbeat < b.beatCount {
            if judge.shapeB.phrase(atBeat: downbeat) >= 0.75 { phrases.append(downbeat) }
            downbeat += 4
        }
        var options: [Option] = []
        for bars in [2, 4, 8, 16] {
            let incomingBeats = Int((Double(bars * 4) / match.octave).rounded())
            var entries = [b.firstDownbeat]
            if let main = b.mainStart(), main - incomingBeats > b.firstDownbeat { entries.append(main - incomingBeats) }
            if let voice {
                // The downbeat at or before the first words: the overlap ends there.
                var words = b.beat(atOrAfter: voice)
                while words > 0, b.beatTime(words) > voice + 0.05 || !b.isDownbeat(words) { words -= 1 }
                if words - incomingBeats >= b.firstDownbeat { entries.append(words - incomingBeats) }
            }
            entries += phrases
            // At most `longestSkip` seconds of the next song left out, and a few entries.
            var seen = Set<Int>()
            entries = entries.filter {
                b.beatTime($0) - b.soundStart <= tuning.longestSkip + 0.05 && seen.insert($0).inserted
            }
            entries = Array(entries.prefix(6))
            for end in ends {
                let start = end - 4 * bars
                guard start > 0 else { continue }
                for entry in entries {
                    for meet in meets {
                        guard let plan = beatMatched(a, b, bars: bars, from: start, to: entry, minimumHandover: 30,
                                                     meet: meet.tempo) else { continue }
                        for fadeOut in [0.5, 0.75, 1 - a.beatLength / max(plan.overlap, a.beatLength)] {
                            var shaped = plan
                            shapeBeatMatched(&shaped, a, b, bars: bars, fadeOutFrom: fadeOut, tuning: tuning)
                            options.append((shaped, .beatMatched(bars: bars, keeps: meet.keeps)))
                        }
                    }
                }
            }
        }
        return options
    }

    /// The curves of a beat-matched mix: the next song comes in over the first half, the song
    /// leaving goes over the second (or, from `fadeOutFrom`, over the last quarter or the last
    /// beat, holding the sound up while the next song's start is quiet); the bass passes from one to the other in the middle when both
    /// are carried by it (over a bar, two beats in a two-bar mix), and the song leaving thins out
    /// at the end when it is.
    private static func shapeBeatMatched(_ plan: inout TransitionPlan, _ a: TrackAnalysis, _ b: TrackAnalysis,
                                         bars: Int, fadeOutFrom: Double, tuning: AutoMixTuning) {
        let overlap = max(0.001, plan.overlap)
        plan.fadeInFrom = 0
        plan.fadeIn = 0.5
        plan.fadeOutFrom = fadeOutFrom
        let outgoingBeats = a.beat(atOrAfter: plan.outStart)..<a.beat(atOrAfter: plan.outEnd)
        let incomingEnd = plan.inStart + plan.overlap * plan.tempoOut / plan.tempoIn
        let incomingBeats = b.beat(atOrAfter: plan.inStart)..<b.beat(atOrAfter: incomingEnd)
        let bassOut = a.bassShare(outgoingBeats) >= tuning.bassRich
        let bassIn = b.bassShare(incomingBeats) >= tuning.bassRich
        if bassOut, bassIn, let alignment = plan.alignment {
            let width = bars >= 4 ? 4 * a.beatLength : 2 * a.beatLength
            let centre = alignment + Double(bars * 2) * a.beatLength
            plan.swapStart = max(0, (centre - width / 2 - plan.outStart) / overlap)
            plan.swapEnd = min(1, (centre + width / 2 - plan.outStart) / overlap)
        } else {
            plan.swapStart = nil
            plan.swapEnd = nil
        }
        plan.filterOut = bassOut && bars >= 4 && a.timing(outgoingBeats).marked >= 0.6 ? 0.7 : nil
    }

    // MARK: Crossfades

    /// Crossfades of 2 to 12 seconds at the songs' own tempos: ending as the song's sound does, or,
    /// when it winds down slowly, starting where it begins to (so its quieter ending isn't heard
    /// alone before the next song comes in); on a downbeat when it has a beat.
    private static func blendOptions(_ a: TrackAnalysis, _ b: TrackAnalysis, judge: TransitionJudge) -> [Option] {
        let tuning = judge.context.tuning
        let audibleEnd = a.audibleEnd
        let earliest = earliestExit(a)
        let lastBars = a.beat(atOrAfter: audibleEnd - 8 * a.beatLength)..<a.beat(atOrAfter: audibleEnd)
        let rhythmic = a.isGridLocked && a.timing(lastBars).marked >= 0.5
        let inStart = max(0, b.soundStart - 0.01)
        var spans: [(start: Double, end: Double, seconds: Int)] = [2, 4, 6, 8, 12].map {
            (audibleEnd - Double($0), audibleEnd, $0)
        }
        if let decline = declineStart(of: a, within: tuning.longestSkip), audibleEnd - decline >= 2 {
            for seconds in [2, 4, 6, 8] where decline + Double(seconds) < audibleEnd {
                spans.append((decline, decline + Double(seconds), seconds))
            }
        }
        // With a beat, also from the phrases where a new section starts in the song's last
        // `longestSkip` seconds (its outro left out).
        if rhythmic {
            var sections: [(beat: Int, novelty: Double)] = []
            var downbeat = a.beat(atOrAfter: audibleEnd - tuning.longestSkip)
            while a.beatTime(downbeat) < audibleEnd - 4 {
                if a.isDownbeat(downbeat), judge.shapeA.phrase(atBeat: downbeat) >= 0.75 {
                    sections.append((downbeat, judge.shapeA.novelty(atBeat: downbeat)))
                }
                downbeat += 1
            }
            for section in sections.sorted(by: { $0.novelty > $1.novelty }).prefix(3) {
                let start = a.beatTime(section.beat)
                for seconds in [4, 8] where start + Double(seconds) < audibleEnd {
                    spans.append((start, start + Double(seconds), seconds))
                }
            }
        }
        // Where the next song may start: at its sound, at its main part, or so that its first words
        // arrive as this song has gone (each at most `longestSkip` seconds in).
        let voice = judge.context.incomingVocals?.firstVoice(after: b.soundStart)
        let main = b.mainStart().map { b.beatTime($0) }
        var options: [Option] = []
        for span in spans {
            var outStart = span.start, end = span.end
            var alignment: Double?
            if rhythmic {
                // The downbeat at (or within a bar before) where the crossfade would start.
                let latest = outStart + 0.5 * a.beatLength
                var downbeat = a.beat(atOrAfter: latest)
                while downbeat > 0, a.beatTime(downbeat) > latest || !a.isDownbeat(downbeat) { downbeat -= 1 }
                if downbeat > 0, outStart - a.beatTime(downbeat) < 4 * a.beatLength, a.beatTime(downbeat) >= earliest,
                   end - a.beatTime(downbeat) >= 1 {
                    // A crossfade starting where the song winds down moves with its start.
                    if span.end < audibleEnd { end -= outStart - a.beatTime(downbeat) }
                    outStart = a.beatTime(downbeat)
                    alignment = outStart
                }
            }
            let seconds = span.seconds
            guard outStart >= earliest, end - outStart >= 1 else { continue }
            var starts = [inStart]
            if let main, main - 0.01 > inStart + 2 { starts.append(main - 0.01) }
            if let voice, voice - (end - outStart) > inStart + 2 { starts.append(voice - (end - outStart)) }
            for start in starts where start - b.soundStart <= tuning.longestSkip + 0.05 {
                options.append(blend(a, b, outStart: outStart, end: end, inStart: start, alignment: alignment,
                                     seconds: seconds, rhythmic: rhythmic, tuning: tuning))
            }
        }
        return options
    }

    /// A crossfade at the songs' own tempos.
    private static func blend(_ a: TrackAnalysis, _ b: TrackAnalysis, outStart: Double, end: Double, inStart: Double,
                              alignment: Double?, seconds: Int, rhythmic: Bool, tuning: AutoMixTuning) -> Option {
        let incomingEnd = inStart + (end - outStart)
        let bassOut = a.bassShare(a.beat(atOrAfter: outStart)..<a.beat(atOrAfter: end)) >= tuning.bassRich
        let bassIn = b.bassShare(b.beat(atOrAfter: inStart)..<b.beat(atOrAfter: incomingEnd)) >= tuning.bassRich
        let swap = bassOut && bassIn && seconds >= 4
        let tempo = a.tempo
        var plan = TransitionPlan(style: .blend, handover: max(0, outStart - 2), outStart: outStart, outEnd: end,
                                  inStart: inStart, tempoOut: tempo, tempoMeet: tempo, tempoIn: tempo,
                                  alignment: alignment, swapStart: swap ? 0.4 : nil, swapEnd: swap ? 0.6 : nil,
                                  fadeIn: 1, filterOut: bassOut && rhythmic && seconds >= 6 ? 0.4 : nil, bars: nil)
        plan.fadeInFrom = 0
        plan.fadeOutFrom = 0
        return (plan, .blend(seconds: seconds))
    }

    /// The last moment, within `window` seconds before the song's audible end, at which it still
    /// plays at nearly full loudness (over a second, not beat by beat).
    private static func declineStart(of a: TrackAnalysis, within window: Double) -> Double? {
        let full = Double(a.bodyLoudness) - 3
        var time = a.audibleEnd - 1
        while time >= max(earliestExit(a), a.audibleEnd - window) {
            if 10 * log10(max(a.power(from: time - 0.5, to: time + 0.5), 1e-12)) >= full { return time }
            time -= TrackAnalysis.loudnessStep
        }
        return nil
    }

    /// Where the song fades out on its own: back from its end to the last moment at nearly full
    /// loudness. Nil when it doesn't fade (for at least four seconds).
    static func fadeOut(of a: TrackAnalysis) -> (start: Double, length: Double)? {
        let end = a.soundEnd
        var fadeStart = end
        var time = end - 1
        while time >= max(a.soundStart, end - 20) {
            if a.level(at: time) >= a.bodyLoudness - 3 { break }
            fadeStart = time
            time -= TrackAnalysis.loudnessStep
        }
        let length = end - fadeStart
        return length >= 4 ? (fadeStart, length) : nil
    }

    /// The next song coming in during the song's own fade-out, a quarter or half way into it.
    private static func fadeOptions(_ a: TrackAnalysis, _ b: TrackAnalysis) -> [Option] {
        guard let fade = fadeOut(of: a) else { return [] }
        let end = a.soundEnd
        return [0.25, 0.5].compactMap { share -> Option? in
            let outStart = fade.start + share * fade.length
            guard outStart >= earliestExit(a), end - outStart >= 2 else { return nil }
            let tempo = a.tempo
            var plan = TransitionPlan(style: .fade, handover: max(0, outStart - 2), outStart: outStart, outEnd: end,
                                      inStart: max(0, b.soundStart - 0.01), tempoOut: tempo, tempoMeet: tempo, tempoIn: tempo,
                                      alignment: nil, swapStart: nil, swapEnd: nil, fadeIn: min(1, 3 / (end - outStart)),
                                      filterOut: nil, bars: nil)
            plan.fadeInFrom = 0
            plan.fadeOutFrom = 0.5
            return (plan, .fade)
        }
    }

    // MARK: Without overlap

    /// The next song as this one's sound ends (the silence between left out), or after a short
    /// breath; the song leaving goes down over a quarter of a second at its very end.
    private static func pauseOptions(_ a: TrackAnalysis, _ b: TrackAnalysis) -> [Option] {
        let tempo = a.tempo
        func plan(_ style: TransitionPlan.Style, outStart: Double, inStart: Double) -> TransitionPlan {
            var plan = TransitionPlan(style: style, handover: max(0, outStart - 2), outStart: outStart,
                                      outEnd: outStart + 0.25, inStart: inStart, tempoOut: tempo, tempoMeet: tempo,
                                      tempoIn: tempo, alignment: nil, swapStart: nil, swapEnd: nil, fadeIn: 0,
                                      filterOut: nil, bars: nil)
            plan.fadeInFrom = 0
            plan.fadeOutFrom = 0
            return plan
        }
        guard a.duration - 0.25 >= earliestExit(a) else { return [] }
        let gapless = min(max(earliestExit(a), a.soundEnd - 0.05), a.duration - 0.25)
        // A breath of 0.6 s: taken from the silence after this song, then before the next.
        let breath = 0.6
        let pause = min(a.soundEnd + breath, a.duration - 0.25)
        let fromNext = max(0, a.soundEnd + breath - pause)
        return [
            (plan(.gapless, outStart: gapless, inStart: max(0, b.soundStart - 0.01)), .gapless),
            (plan(.sequence, outStart: pause, inStart: max(0, b.soundStart - 0.01 - fromNext)), .sequence),
        ]
    }

    /// As the album has them: the song to its last sample, the next from its first.
    private static func albumPlan(_ a: TrackAnalysis, _ b: TrackAnalysis) -> TransitionPlan {
        let tempo = a.tempo
        var plan = TransitionPlan(style: .album, handover: max(0, a.duration - 3), outStart: a.duration,
                                  outEnd: a.duration + 0.05, inStart: 0, tempoOut: tempo, tempoMeet: tempo, tempoIn: tempo,
                                  alignment: nil, swapStart: nil, swapEnd: nil, fadeIn: 0, filterOut: nil, bars: nil)
        plan.fadeInFrom = 0
        plan.fadeOutFrom = 1
        return plan
    }

    /// When nothing is good enough: three seconds of equal-power crossfade on the song's ending
    /// (or into its fade-out), nothing else.
    private static func prudent(_ a: TrackAnalysis, _ b: TrackAnalysis) -> TransitionPlan {
        let end = a.audibleEnd
        let outStart = max(min(end - 1, earliestExit(a)), end - 3)
        let tempo = a.tempo
        var plan = TransitionPlan(style: .blend, handover: max(0, outStart - 2), outStart: outStart, outEnd: end,
                                  inStart: max(0, b.soundStart - 0.01), tempoOut: tempo, tempoMeet: tempo, tempoIn: tempo,
                                  alignment: nil, swapStart: nil, swapEnd: nil, fadeIn: 1, filterOut: nil, bars: nil)
        plan.fadeInFrom = 0
        plan.fadeOutFrom = 0
        return plan
    }
}

// MARK: Judging

/// A song's phrases: bars counted from the start of the section they are in (where the harmony and
/// the loudness change clearly), so a section of odd length or a pickup doesn't shift the rest.
struct SongShape {
    let analysis: TrackAnalysis
    /// The bars where sections start (the first bar among them).
    let sectionStarts: [Int]
    /// For each bar: how much the harmony and the loudness change there (a new section).
    let novelty: [Double]

    init(_ a: TrackAnalysis) {
        analysis = a
        let bars = a.barChroma.count / 12
        let loudness = (0..<bars).map { Double(a.meanLoudness(a.firstBarBeat + 4 * $0, 4) ?? -100) }
        func chroma(_ range: Range<Int>) -> [Double] {
            var sum = [Double](repeating: 0, count: 12)
            for bar in range { for pitch in 0..<12 { sum[pitch] += Double(a.barChroma[bar * 12 + pitch]) } }
            return sum
        }
        func cosine(_ x: [Double], _ y: [Double]) -> Double {
            var dot = 0.0, nx = 0.0, ny = 0.0
            for index in x.indices {
                dot += x[index] * y[index]
                nx += x[index] * x[index]
                ny += y[index] * y[index]
            }
            return dot / ((nx * ny).squareRoot() + 1e-9)
        }
        func mean(_ values: ArraySlice<Double>) -> Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }
        let novelty = (0..<bars).map { bar -> Double in
            guard bar >= 2, bar + 2 <= bars else { return 0 }
            let harmony = 1 - cosine(chroma((bar - 2)..<bar), chroma(bar..<(bar + 2)))
            let before = mean(loudness[max(0, bar - 4)..<bar]), after = mean(loudness[bar..<min(bars, bar + 4)])
            return harmony + abs(after - before) / 6
        }
        self.novelty = novelty
        // A section starts where the change stands out: a peak at least one deviation above the mean.
        let mean = novelty.isEmpty ? 0 : novelty.reduce(0, +) / Double(novelty.count)
        let deviation = novelty.isEmpty ? 0
            : (novelty.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(novelty.count)).squareRoot()
        var starts = [0]
        for bar in novelty.indices where bar >= 2 && bar + 1 < novelty.count {
            if novelty[bar] >= mean + deviation, novelty[bar] >= novelty[bar - 1], novelty[bar] >= novelty[bar + 1] {
                starts.append(bar)
            }
        }
        sectionStarts = starts
    }

    private func bar(ofBeat beat: Int) -> Int? {
        guard analysis.isDownbeat(beat), beat >= analysis.firstBarBeat else { return nil }
        return (beat - analysis.firstBarBeat) / 4
    }

    /// How well a beat starts a phrase: 1 on an eight-bar boundary of its section (or where a section
    /// starts), 0.75 on a four-bar one, 0.35 every two bars, 0 elsewhere (and off a downbeat).
    func phrase(atBeat beat: Int) -> Double {
        guard let bar = bar(ofBeat: beat) else { return 0 }
        let counted = bar - (sectionStarts.last { $0 <= bar } ?? 0)
        if counted % 8 == 0 { return 1 }
        if counted % 4 == 0 { return 0.75 }
        if counted % 2 == 0 { return 0.35 }
        return 0
    }

    func novelty(atBeat beat: Int) -> Double {
        guard let bar = bar(ofBeat: beat), novelty.indices.contains(bar) else { return 0 }
        return novelty[bar]
    }
}

/// Works out how a plan would sound from the two analyses, and what its problems cost.
struct TransitionJudge {
    let a: TrackAnalysis
    let b: TrackAnalysis
    let context: TransitionContext
    let shapeA: SongShape
    let shapeB: SongShape
    /// The songs' gains, as power.
    private let gainA: Double
    private let gainB: Double

    init(_ a: TrackAnalysis, _ b: TrackAnalysis, _ context: TransitionContext) {
        self.a = a
        self.b = b
        self.context = context
        shapeA = SongShape(a)
        shapeB = SongShape(b)
        gainA = Double(context.outgoingGain * context.outgoingGain)
        gainB = Double(context.incomingGain * context.incomingGain)
    }

    private var tuning: AutoMixTuning { context.tuning }

    /// The chance a voice sings at a time: measured, or assumed (`unknownVocal`, less where the
    /// song is quiet); none outside its sound.
    func voice(_ song: TrackAnalysis, _ activity: VocalActivity?, at time: Double) -> Double {
        guard time >= song.soundStart, time <= song.soundEnd else { return 0 }
        if let value = activity?.presence(at: time) { return value }
        let edge = time < song.soundStart + 20 || time > song.soundEnd - 20
        return (edge ? tuning.unknownVocalAtEdges : tuning.unknownVocal) * (song.level(at: time) >= song.bodyLoudness - 10 ? 1 : 0.4)
    }

    private func voiceA(_ time: Double) -> Double { voice(a, context.outgoingVocals, at: time) }
    private func voiceB(_ time: Double) -> Double { voice(b, context.incomingVocals, at: time) }

    /// A song's power (linear) over the second around a time (as it is heard: not beat by beat),
    /// or over less (down to a quarter of a second) for a mix shorter than that.
    private static func power(_ song: TrackAnalysis, _ time: Double, over window: Double = 1) -> Double {
        let steps = max(1, min(4, Int((window / TrackAnalysis.loudnessStep).rounded())))
        let values = (0..<steps).map { step -> Double in
            let at = time + (Double(step) - Double(steps) / 2) * TrackAnalysis.loudnessStep
            guard at >= 0, at < song.duration else { return 0 }
            return pow(10, Double(song.level(at: at)) / 10)
        }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Its share of bass over the beats around a time (as `power`, a second or less).
    private static func bass(_ song: TrackAnalysis, _ time: Double, over window: Double = 1) -> Double {
        let span = max(TrackAnalysis.loudnessStep, min(1, window)) / 2
        let first = Int(((time - span - song.gridStart) / song.beatLength).rounded(.down))
        let last = Int(((time + span - song.gridStart) / song.beatLength).rounded(.down))
        return song.bassShare(first..<max(first + 1, last + 1))
    }

    /// A song of unweighted `power` (as the analysis measures it) with `bass` of it below 150 Hz,
    /// heard alone and through its filters (see `MixFilters`): loudness as the ear weighs it
    /// (K-weighted power), and through the filters unweighted too.
    private static func heard(_ power: Double, bass: Double, bassCut: Float,
                              highPass: Float) -> (alone: Double, heard: Double, unweighted: Double) {
        let filters = MixFilters.response(bassCut: bassCut, highPass: highPass)
        return (MixFilters.heard(power, bass: bass, through: MixFilters.open), MixFilters.heard(power, bass: bass, through: filters),
                MixFilters.heard(power, bass: bass, through: filters, weighted: false))
    }

    private static func decibels(_ power: Double) -> Double { 10 * log10(max(power, 1e-12)) }

    func evaluate(_ input: TransitionPlan, _ kind: TransitionCandidate.Kind) -> TransitionCandidate {
        var plan = input
        plan.outgoingCeiling = []
        plan.incomingCeiling = []
        // As the album has it: nothing to weigh.
        if kind == .album { return TransitionCandidate(kind: kind, plan: plan) }
        let step = 0.25
        // The next song's seconds for each of this one's while together.
        let ratio = plan.tempoOut / plan.tempoIn
        let overlap = max(0, plan.overlap)
        let count = max(2, Int((overlap / step).rounded(.up)) + 1)
        let dt = overlap / Double(count - 1)
        struct Sample {
            var outgoing: Double
            var incoming: Double
            var levels: TransitionLevels
            /// Each song's loudness alone and through its filters (K-weighted power), and alone and
            /// through its filters unweighted (as the analysis measures loudness).
            var alone: (Double, Double)
            var heard: (Double, Double)
            var unweighted: (Double, Double)
            var heardUnweighted: (Double, Double)
        }
        var samples: [Sample] = []
        samples.reserveCapacity(count)
        for index in 0..<count {
            let p = Double(index) / Double(count - 1)
            let timeA = plan.outStart + p * overlap
            let timeB = plan.inStart + p * overlap * ratio
            let levels = plan.levels(at: p)
            let powerA = Self.power(a, timeA, over: overlap) * gainA, powerB = Self.power(b, timeB, over: overlap) * gainB
            let songA = Self.heard(powerA, bass: Self.bass(a, timeA, over: overlap), bassCut: levels.outgoingBassCut,
                                   highPass: levels.outgoingHighPass)
            let songB = Self.heard(powerB, bass: Self.bass(b, timeB, over: overlap), bassCut: levels.incomingBassCut,
                                   highPass: levels.incomingHighPass)
            samples.append(Sample(outgoing: timeA, incoming: timeB, levels: levels, alone: (songA.alone, songB.alone),
                                  heard: (songA.heard, songB.heard), unweighted: (powerA, powerB),
                                  heardUnweighted: (songA.unweighted, songB.unweighted)))
        }

        // Together never sounding louder than the louder alone (plus `headroom`): both held down,
        // gently.
        let cap = pow(10, tuning.headroom / 10)
        var raw = samples.map { sample -> Double in
            let o = Double(sample.levels.outgoing), i = Double(sample.levels.incoming)
            let total = o * o * sample.heard.0 + i * i * sample.heard.1
            let limit = max(sample.alone.0, sample.alone.1) * cap
            return total > limit && total > 0 ? (limit / total).squareRoot() : 1
        }
        let reach = max(1, Int((1 / max(dt, 1e-3)).rounded()))
        raw = raw.indices.map { index in raw[max(0, index - reach)...min(raw.count - 1, index + reach)].min() ?? 1 }
        var trim = raw.indices.map { index -> Double in
            let window = raw[max(0, index - reach / 2)...min(raw.count - 1, index + reach / 2)]
            return window.reduce(0, +) / Double(window.count)
        }
        // From and back to 1 at the ends (where a song plays alone), at most 1 dB a quarter second.
        let fall = (1 - pow(10, -1.0 / 20)) * max(dt, 1e-3) / 0.25
        trim[0] = 1
        trim[trim.count - 1] = 1
        for index in 1..<trim.count { trim[index] = max(trim[index], trim[index - 1] - fall) }
        for index in stride(from: trim.count - 2, through: 0, by: -1) { trim[index] = max(trim[index], trim[index + 1] - fall) }
        // Each song as heard (its curve times its trim) only goes one way, the song leaving only
        // down and the next only up, so neither pumps; within that, the trim is let go as soon as it
        // can be. Up to 1.18 the trims themselves only went one way: the song leaving stayed held
        // down to its end, and the next was held down from its very start, even where nothing
        // needed it.
        var trimOut = trim, trimIn = trim
        var ceilingOut = trim, ceilingIn = trim
        var lowest = Double.infinity
        for index in trim.indices {
            let curve = Double(samples[index].levels.outgoing)
            lowest = min(lowest, curve * trim[index])
            ceilingOut[index] = lowest
            if curve > 1e-4 { trimOut[index] = min(trim[index], lowest / curve) }
        }
        lowest = .infinity
        for index in trim.indices.reversed() {
            let curve = Double(samples[index].levels.incoming)
            lowest = min(lowest, curve * trim[index])
            ceilingIn[index] = lowest
            if curve > 1e-4 { trimIn[index] = min(trim[index], lowest / curve) }
        }
        if trim.contains(where: { $0 < 0.99 }) {
            func sampled(_ values: [Double]) -> [Float] {
                let points = 65
                return (0..<points).map { point in
                    let position = Double(point) / Double(points - 1) * Double(values.count - 1)
                    let lower = Int(position.rounded(.down)), upper = min(values.count - 1, lower + 1)
                    return Float(values[lower] + (values[upper] - values[lower]) * (position - Double(lower)))
                }
            }
            plan.outgoingCeiling = sampled(ceilingOut)
            plan.incomingCeiling = sampled(ceilingIn)
        }

        var costs: [TransitionCriterion: Double] = [:]
        let incomingEnd = plan.inStart + overlap * ratio
        // Seconds where both are clearly heard (each at least a tenth of the sound).
        var together = 0.0
        var clash = 0.0, cut = 0.0, buried = 0.0, crowded = 0.0
        let fullA = Double(a.bodyLoudness) - 6 + Self.decibels(gainA), fullB = Double(b.bodyLoudness) - 6 + Self.decibels(gainB)
        for (index, sample) in samples.enumerated() {
            let gainA = trimOut[index], gainB = trimIn[index]
            let o = Double(sample.levels.outgoing), i = Double(sample.levels.incoming)
            let heardA = o * o * gainA * gainA * sample.heard.0, heardB = i * i * gainB * gainB * sample.heard.1
            let total = heardA + heardB
            let weight = index == 0 || index == samples.count - 1 ? dt / 2 : dt
            if total > 0, heardA >= 0.1 * total, heardB >= 0.1 * total { together += weight }
            let va = voiceA(sample.outgoing), vb = sample.incoming >= b.soundStart ? voiceB(sample.incoming) : 0
            if o * gainA >= 0.3, i * gainB >= 0.3 { clash += va * vb * weight }
            if o > 0.05, o < 0.9 { cut += va * weight }
            if i > 0.02, i < 0.7 {
                buried += vb * weight
            } else if o * gainA >= 0.5 {
                // Its words over the song leaving, still up.
                buried += 0.5 * vb * weight
            }
            if o * gainA >= 0.6, i * gainB >= 0.6, Self.decibels(sample.unweighted.0) >= fullA,
               Self.decibels(sample.unweighted.1) >= fullB {
                crowded += weight
            }
        }
        // The words left out: the end of the song leaving, the start of the next.
        for time in stride(from: plan.outEnd, to: a.audibleEnd, by: step) { cut += 2 * voiceA(time) * step }
        for time in stride(from: b.soundStart, to: plan.inStart, by: step) { buried += 2 * voiceB(time) * step }
        costs[.vocalClash] = clash / 3
        costs[.vocalCut] = cut / 3
        costs[.buriedEntry] = buried / 3
        costs[.crowded] = crowded / 8

        // Rhythm where they play together.
        let beatsA = a.beat(atOrAfter: plan.outStart)..<max(a.beat(atOrAfter: plan.outStart), a.beat(atOrAfter: plan.outEnd))
        let beatsB = b.beat(atOrAfter: plan.inStart)..<max(b.beat(atOrAfter: plan.inStart), b.beat(atOrAfter: incomingEnd))
        let edgeA = a.beat(atOrAfter: plan.outEnd - 8 * a.beatLength)..<a.beat(atOrAfter: plan.outEnd)
        let edgeB = b.beat(atOrAfter: max(plan.inStart, b.soundStart))..<b.beat(atOrAfter: max(plan.inStart, b.soundStart) + 8 * b.beatLength)
        let timingA = a.timing(beatsA.isEmpty ? edgeA : beatsA), timingB = b.timing(beatsB.isEmpty ? edgeB : beatsB)
        let rhythmicA = a.isGridLocked ? a.timing(edgeA).marked : 0, rhythmicB = b.isGridLocked ? b.timing(edgeB).marked : 0
        if plan.style == .beatMatched {
            let flam = max(timingA.marked * (1 - timingA.onGrid), timingB.marked * (1 - timingB.onGrid))
            costs[.rhythm] = min(2, flam / 0.25) + (max(timingA.marked, timingB.marked) < 0.3 ? 0.3 : 0)
        } else {
            costs[.unsyncedBeats] = together * timingA.marked * timingB.marked / 2
        }
        if plan.style == .gapless || plan.style == .sequence {
            // Two beats one after the other: unless the next song's first bar lands where this
            // one's next bar would (within 40 ms, at nearly the same tempo), the groove stops.
            var offBeat = 1.0
            if a.isGridLocked, b.isGridLocked, abs(log(a.beatLength / b.beatLength)) <= 0.02 {
                let landing = plan.outStart + (b.beatTime(b.firstDownbeat) - plan.inStart)
                let bar = 4 * a.beatLength
                var phase = ((landing - a.beatTime(a.firstBarBeat)) / bar).truncatingRemainder(dividingBy: 1)
                if phase < 0 { phase += 1 }
                if min(phase, 1 - phase) * bar <= 0.04 { offBeat = 0.2 }
            }
            costs[.grooveBreak] = rhythmicA * rhythmicB * offBeat
            // A song whose sound runs on until it is stopped: loud in its last second.
            let last = Self.decibels(averagePower(a, from: a.soundEnd - 1, to: a.soundEnd - 0.25))
            costs[.abruptEnd] = max(0, min(1, (last - Double(a.bodyLoudness) + 12) / 9))
        }

        // Harmony while both are heard: the keys of the two stretches (or how alike their pitch
        // classes are, when the keys are unclear), the more it counts the longer and the more tonal.
        if together > 0 {
            let chromaA = a.chroma(from: plan.outStart, to: plan.outEnd), chromaB = b.chroma(from: plan.inStart, to: incomingEnd)
            let keyA = KeyProfile.key(of: chromaA), keyB = KeyProfile.key(of: chromaB)
            let tonal = min(keyA.clarity, keyB.clarity)
            let compatibility = Self.compatibility(keyA, keyB, chromaA, chromaB)
            costs[.harmony] = (1 - compatibility) * tonal * together / 6
        }

        // Loudness: from the song leaving just before to the next just after, and holes on the way
        // (from six seconds before the mix: a fade-out played to its end counts).
        let before = Self.decibels(averagePower(a, from: plan.outStart - 4, to: plan.outStart) * gainA)
        let after = Self.decibels(averagePower(b, from: incomingEnd, to: incomingEnd + 4) * gainB)
        costs[.energy] = max(0, abs(after - before) - 3) / 6
        let reference = min(Double(a.bodyLoudness) + Self.decibels(gainA), Double(b.bodyLoudness) + Self.decibels(gainB))
        var hole = 0.0
        for time in stride(from: plan.outStart - 6, to: plan.outStart, by: step)
        where Self.decibels(Self.power(a, time) * gainA) < reference - 8 {
            hole += step
        }
        for (index, sample) in samples.enumerated() {
            let o = Double(sample.levels.outgoing) * trimOut[index], i = Double(sample.levels.incoming) * trimIn[index]
            let total = o * o * sample.heardUnweighted.0 + i * i * sample.heardUnweighted.1
            let weight = index == 0 || index == samples.count - 1 ? dt / 2 : dt
            if Self.decibels(total) < reference - 8 { hole += weight }
        }
        for time in stride(from: incomingEnd, to: incomingEnd + 2, by: step)
        where Self.decibels(Self.power(b, time) * gainB) < reference - 8 {
            hole += step
        }
        costs[.gap] = hole / 2 * (0.5 + 0.5 * min(rhythmicA, rhythmicB))

        // Tempo: how much each song changes, the more where its voice is heard meanwhile.
        var veto: String?
        if plan.style == .beatMatched {
            let limit = log(1 + tuning.maximumRateChange)
            let changeA = abs(log(plan.outgoingRate)), changeB = abs(log(plan.incomingRate))
            if changeA > limit + 1e-9 || changeB > limit + 1e-9 {
                veto = String(localized: "cambio di tempo oltre il limite")
            }
            func exposure(_ voice: (Double) -> Double, from start: Double, to end: Double) -> Double {
                let times = Array(stride(from: start, to: max(start + 0.5, end), by: 0.5))
                return times.map(voice).reduce(0, +) / Double(max(1, times.count))
            }
            let exposedA = exposure(voiceA, from: plan.handover + 1, to: plan.outEnd)
            let exposedB = exposure(voiceB, from: plan.inStart, to: incomingEnd + 16 * b.beatLength)
            // Small changes are hardly heard: the cost grows faster than the change (so, with no
            // voice on either side, meeting halfway is cheapest).
            costs[.tempo] = pow(changeA / limit, 1.5) * (0.3 + 0.7 * exposedA) + pow(changeB / limit, 1.5) * (0.3 + 0.7 * exposedB)
        }

        // Phrases: the mix starting and ending where they start.
        if let alignment = plan.alignment {
            let start = Int(((alignment - a.gridStart) / a.beatLength).rounded())
            var phrase = (1 - shapeA.phrase(atBeat: start)) * 0.5
            if plan.style == .beatMatched {
                let end = Int(((plan.outEnd - a.gridStart) / a.beatLength).rounded())
                let incomingBar = Int(((incomingEnd - b.gridStart) / b.beatLength).rounded())
                phrase += (1 - shapeA.phrase(atBeat: end)) * 0.25 + (1 - shapeB.phrase(atBeat: incomingBar)) * 0.5
            }
            costs[.phrase] = max(0, phrase - min(0.25, shapeA.novelty(atBeat: start) / 4))
        }

        // Loud music left out: the end of the song leaving (a fade's tail costs nothing), the start
        // of the next (a quiet intro costs little).
        func loud(_ song: TrackAnalysis, from start: Double, to end: Double) -> Double {
            stride(from: start, to: end, by: step).reduce(0.0) { sum, time in
                sum + step * max(0, min(1, (Double(song.level(at: time)) - Double(song.bodyLoudness) + 12) / 12))
            }
        }
        costs[.skipped] = loud(a, from: plan.outEnd, to: a.audibleEnd) / 20 + loud(b, from: b.soundStart, to: plan.inStart) / 20

        switch kind {
        case .beatMatched(let bars, _):
            costs[.length] = tuning.lengthCost * abs(log2(Double(bars) / tuning.preferredBars))
        case .blend(let seconds):
            costs[.length] = tuning.lengthCost * abs(log2(Double(seconds) / tuning.preferredCrossfade))
        case .gapless:
            costs[.length] = 0.1
        case .sequence:
            costs[.length] = 0.15
        case .fade, .album:
            costs[.length] = 0
        }

        var weighted: [TransitionCriterion: Double] = [:]
        for (criterion, value) in costs where value > 0 { weighted[criterion] = value * (tuning.weights[criterion] ?? 1) }
        return TransitionCandidate(kind: kind, plan: plan, costs: weighted,
                                   total: weighted.values.reduce(0, +), veto: veto)
    }

    /// How loud (dB, K-weighted power) the mix would sound through the overlap as planned (filters
    /// and trims included), and the louder of the two songs alone at each point: for the checks and
    /// the diagnostics.
    func loudness(of plan: TransitionPlan, step: Double = 0.25) -> [(progress: Double, together: Double, louder: Double)] {
        let overlap = max(0, plan.overlap)
        let count = max(2, Int((overlap / step).rounded(.up)) + 1)
        let ratio = plan.tempoOut / plan.tempoIn
        return (0..<count).map { index in
            let p = Double(index) / Double(count - 1)
            let timeA = plan.outStart + p * overlap, timeB = plan.inStart + p * overlap * ratio
            let levels = plan.levels(at: p)
            let songA = Self.heard(Self.power(a, timeA, over: overlap) * gainA, bass: Self.bass(a, timeA, over: overlap),
                                   bassCut: levels.outgoingBassCut, highPass: levels.outgoingHighPass)
            let songB = Self.heard(Self.power(b, timeB, over: overlap) * gainB, bass: Self.bass(b, timeB, over: overlap),
                                   bassCut: levels.incomingBassCut, highPass: levels.incomingHighPass)
            let o = Double(levels.outgoing), i = Double(levels.incoming)
            return (p, Self.decibels(o * o * songA.heard + i * i * songB.heard), Self.decibels(max(songA.alone, songB.alone)))
        }
    }

    /// Mean power of a song between two times (none outside it).
    private func averagePower(_ song: TrackAnalysis, from start: Double, to end: Double) -> Double {
        let times = Array(stride(from: start, to: max(start + 0.25, end), by: 0.25))
        return times.map { Self.power(song, $0) }.reduce(0, +) / Double(max(1, times.count))
    }

    /// How well two stretches go together in harmony (0 clash … 1 fine): the Camelot wheel when
    /// both keys are clear, how alike their pitch classes are when not, in between in between.
    static func compatibility(_ keyA: (tonic: Int, minor: Bool, clarity: Double), _ keyB: (tonic: Int, minor: Bool, clarity: Double),
                              _ chromaA: [Double], _ chromaB: [Double]) -> Double {
        func fifths(_ key: (tonic: Int, minor: Bool, clarity: Double)) -> Int {
            let major = key.minor ? (key.tonic + 3) % 12 : key.tonic
            return (major * 7) % 12
        }
        let distance = min((fifths(keyA) - fifths(keyB) + 12) % 12, (fifths(keyB) - fifths(keyA) + 12) % 12)
        let wheel: Double
        if keyA.minor == keyB.minor {
            wheel = distance <= 1 ? 1 : (distance == 2 ? 0.4 : 0)
        } else {
            wheel = distance == 0 ? 1 : (distance == 1 ? 0.5 : 0)
        }
        var dot = 0.0, normA = 0.0, normB = 0.0
        for index in 0..<min(chromaA.count, chromaB.count) {
            dot += chromaA[index] * chromaB[index]
            normA += chromaA[index] * chromaA[index]
            normB += chromaB[index] * chromaB[index]
        }
        let alike = max(0, min(1, (dot / ((normA * normB).squareRoot() + 1e-9) - 0.5) / 0.35))
        let clear = max(0, min(1, (min(keyA.clarity, keyB.clarity) - 0.4) / 0.3))
        return clear * wheel + (1 - clear) * alike
    }
}
