import Foundation

/// Every number the policy uses, in one place. They are starting values from DJ practice, to be
/// confirmed by listening (none is measured on a corpus yet).
struct SegueTuning: Sendable {
    // Guards: crossing one rejects a candidate, whatever its score.
    /// Largest speed change of the incoming song in a locked mix (it keeps its pitch).
    var maxRateChange = 0.08
    /// Expected beat misalignment in a locked mix: median and 95th percentile, seconds.
    var phaseMedianMax = 0.020
    var phaseP95Max = 0.040
    /// Drift over the window, in beats.
    var driftMaxBeats = 0.1
    /// A stretch of bars: share of its beats clearly marked, worst bar's slide off its line (s).
    var stretchMinBeatShare = 0.85
    var stretchMaxBarDrift = 0.030
    /// Two voices at once, at comparable levels: tolerated seconds in total.
    var voiceOverlapMax = 1.0
    /// Music left out of the outgoing song: share of it, and seconds.
    var contentCutMaxShare = 0.20
    var contentCutMax = 60.0
    /// The least the outgoing song plays before it may leave.
    var minPlayed = 60.0
    /// Loudness jump allowed at a cut, dB.
    var loudnessJumpMax = 3.0
    /// Silence on both sides of an album's junction under which the songs run into each other.
    var gaplessMaxSilence = 0.3

    // Score: notes (weighted by how reliable their measure is) and penalties.
    var weightRhythm = 1.0, weightPhrase = 1.0, weightEnergy = 0.5, weightExit = 0.5, weightEntry = 0.5, weightKey = 0.2
    var penaltySpeed = 0.5, penaltyVoice = 1.0, penaltyVoiceCut = 0.5, penaltyBass = 0.5, penaltyLost = 0.35, penaltySobriety = 0.2
    /// Rhythm note full under this misalignment, nothing at the guard.
    var rhythmFull = 0.010
    /// Speed change that costs nothing.
    var rateFree = 0.02
    /// Width of the energy continuity's bell, dB.
    var energySigma = 3.0
    /// Entry notes: the first attack 1, a later section start, anywhere else.
    var entrySection = 0.6, entryOther = 0.3
    /// Seconds of music left out (both songs) at which the "lost" defect is full.
    var lostFull = 20.0
    /// Choosing within a level: the cost of the music nobody hears, locked and faded.
    var lostPickLocked = 0.4, lostPickFade = 1.0
    /// A cut leaving out more than this (both songs) is left to the short fade.
    var hardLostMax = 12.0

    // Thresholds a family's best candidate must reach.
    var thresholdLocked = 0.5, thresholdFiltered = 0.25, thresholdHard = 0.25

    // Placement.
    var lockedLongBars = 16, lockedMiddleBars = 8, lockedShortBars = 4, lockedTinyBars = 2
    /// The lengths tried at the long level, longest first (the long mix length adds 32 bars).
    var longLengths = [16]
    /// Reliability from which the long, then the middle length is allowed.
    var reliabilityForLong = 0.8, reliabilityForMiddle = 0.6
    var filteredLengths: [Double] = [8, 6, 4]
    var simpleFade = 6.0
    /// The last resort over a voice: a fade this short at the very end.
    var simpleVoiceFade = 2.5
    /// Exits lie in this last share of the outgoing song's music; entries within this much of the
    /// incoming song's first attack.
    var exitZoneShare = 1.0 / 3.0
    var entryZone = 40.0
    var candidatesPerSide = 8
    var lateCandidates = 4
    /// The anti-click ramp of a cut.
    var microFade = 0.03
    /// Downbeats the model must be sure of, on average, over a stretch (0…1).
    var stretchMinDownConfidence = 0.5
    /// A build-up's beat carried back from this many bars after it, searched this many bars on,
    /// landing this near its start (s).
    var carryFromBars = 4
    var carrySearchBars = 8
    var carryMaxOff = 0.08
    /// How much the incoming song's level rises past an entry for it to arrive there (dB): from the
    /// least to a full arrival; and what a full arrival is worth over its start, choosing within a level.
    var arrivalRiseMin = 2.0, arrivalRiseFull = 6.0
    var arrivalPick = 0.5

    // Lanes.
    var bassKillDB = -30.0
    var outgoingTopFrom = 0.7, outgoingTopDB = -15.0, incomingTopDB = -6.0
    var incomingBed = 0.8
    var filteredSwap = 0.6, filteredBed = 0.6
    var sweepClosedHz = 400.0, riseClosedHz = 1_200.0
    var coreOutDB = -24.0, coreInDB = -12.0, topInDB = -12.0
    /// The echo send at its height, and where in a filtered fade the outgoing song is thrown into it
    /// (late, so its repeats have the end of the window to themselves); its delay stays between
    /// these (s: shorter is a flam, longer loses the pulse).
    var echoSend = 0.5, echoThrowShare = 0.72
    var echoMin = 0.24, echoMax = 0.62
    /// The two faders' largest sum: under it two peaks meeting on a beat stay in range.
    var overlapMaxSum = 1.1
    var curveKnots = 16
    /// Loudness gap left alone, and the largest corrected, dB.
    var matchFromDB = 1.5, matchToDB = 6.0
}

/// What the policy reads of one song: its analysis, its bars, sections and measured voices. With
/// Beat This!'s beats and downbeats in the analysis (see `BeatThis`) the bars are the model's: its
/// beats, every fourth starting a bar, the phase chosen by its downbeats near the song's start and
/// near its end, each bar with how sure the model was of its downbeat; the stretches are measured on
/// those beats. Without them (an analysis without the model) the bars are the analysis' grid.
struct SegueSong {
    let analysis: TrackAnalysis
    let shape: SongShape
    let voices: VocalActivity?
    /// The model's beats inside the sound, seconds (empty without the model).
    let beats: [Double]
    var fromModel: Bool { !beats.isEmpty }
    /// Each bar's start (seconds), from the song's first whole bar.
    let barStarts: [Double]
    /// For each bar, how sure the model is that a downbeat starts it (0…1, 0 where it put none); nil
    /// without the model.
    let barDown: [Double]?
    /// How clearly the model's downbeats chose one beat of four near the start and near the end (0…1;
    /// 1 without the model, where the analysis' downbeat stands).
    let headMetre: Double
    let tailMetre: Double
    /// Each bar's loudness and its bass's (dB).
    let barLevel: [Double]
    let barBass: [Double]
    /// Each bar's novelty (how much the harmony and the loudness change there), the bars where
    /// sections start, and the bar offset of 8-bar phrases where no section start says otherwise.
    let novelty: [Double]
    let sectionStarts: [Int]
    let phraseOffset: Int
    /// A beat's length (seconds): the model's median beat, else the grid's.
    let beatPeriod: Double

    /// Where the model's downbeats are read for the bars of the song's first and second half (s).
    static let headSpan = 75.0
    static let tailSpan = 90.0
    /// How near a bar start a model downbeat must be to speak for it (s).
    static let downbeatNear = 0.07

    init(_ analysis: TrackAnalysis, voices: VocalActivity?) {
        self.analysis = analysis
        self.voices = voices
        let shape = SongShape(analysis)
        self.shape = shape
        let a = analysis
        let modelBeats = (a.modelBeats ?? []).map { Double($0) }.filter { $0 >= a.soundStart - 0.05 && $0 < a.soundEnd }
        guard modelBeats.count >= 16 else {
            // The analysis' grid.
            beats = []
            let first = a.firstBarBeat
            let count = max(0, (a.beatCount - first) / 4)
            let starts = (0..<count).map { a.beatTime(first + 4 * $0) }
            barStarts = starts
            barDown = nil
            headMetre = 1
            tailMetre = 1
            beatPeriod = a.beatLength
            barLevel = (0..<count).map { Double(a.meanLoudness(first + 4 * $0, 4) ?? -100) }
            barBass = (0..<count).map { bar in
                let beats = (first + 4 * bar)..<(first + 4 * bar + 4)
                let share = max(0.001, a.bassShare(beats))
                return Double(a.meanLoudness(beats.lowerBound, 4) ?? -100) + 10 * log10(share)
            }
            novelty = (0..<count).map { shape.novelty.indices.contains($0) ? shape.novelty[$0] : 0 }
            sectionStarts = shape.sectionStarts.filter { $0 < count }
            phraseOffset = 0
            return
        }
        beats = modelBeats
        // The median gap between beats, among those of a plausible tempo (55 to 210 BPM).
        var gaps: [Double] = []
        for index in modelBeats.indices.dropFirst() {
            let gap = modelBeats[index] - modelBeats[index - 1]
            if gap > 0.285, gap < 1.091 { gaps.append(gap) }
        }
        gaps.sort()
        let period = gaps.isEmpty ? a.beatLength : gaps[gaps.count / 2]
        beatPeriod = period
        // The downbeats as votes for which beat of four starts the bars, near the start and the end.
        let downbeats = zip((a.modelDownbeats ?? []).map { Double($0) }, (a.modelDownbeatLogits ?? []).map { Double($0) }).map { $0 }
        func nearestBeat(_ time: Double) -> Int? {
            var low = 0, high = modelBeats.count - 1
            while high - low > 1 {
                let middle = (low + high) / 2
                if modelBeats[middle] <= time { low = middle } else { high = middle }
            }
            let k = abs(modelBeats[low] - time) <= abs(modelBeats[high] - time) ? low : high
            return abs(modelBeats[k] - time) < 0.3 * period ? k : nil
        }
        func vote(_ votes: [(time: Double, weight: Double)]) -> (phase: Int, metre: Double)? {
            var tally = [Double](repeating: 0, count: 4)
            for (time, weight) in votes where weight > 0 {
                if let k = nearestBeat(time) { tally[k % 4] += weight }
            }
            let sum = tally.reduce(0, +)
            guard sum > 0, let best = tally.indices.max(by: { tally[$0] < tally[$1] }) else { return nil }
            return (best, max(0, min(1, (tally[best] / sum - 0.25) / 0.75)))
        }
        let head = vote(downbeats.filter { $0.0 < a.soundStart + SegueSong.headSpan }.map { (time: $0.0, weight: $0.1) })
        let tail = vote(downbeats.filter { $0.0 > a.soundEnd - SegueSong.tailSpan }.map { (time: $0.0, weight: $0.1) })
        // Without the model's word, the analysis' downbeats.
        let gridBars = stride(from: a.firstBarBeat, to: a.beatCount, by: 4).map { (time: a.beatTime($0), weight: 1.0) }
        let fallback = vote(gridBars)?.phase ?? 0
        headMetre = head?.metre ?? 0
        tailMetre = tail?.metre ?? 0
        let middle = (a.soundStart + a.soundEnd) / 2
        var starts: [Double] = []
        for (k, time) in modelBeats.enumerated() {
            let phase = (time < middle ? head?.phase : tail?.phase) ?? fallback
            if ((k - phase) % 4 + 4) % 4 == 0 { starts.append(time) }
        }
        barStarts = starts
        func sigmoid(_ x: Double) -> Double { 1 / (1 + exp(-x)) }
        barDown = starts.map { start in
            downbeats.filter { abs($0.0 - start) <= SegueSong.downbeatNear }.map { sigmoid($0.1) }.max() ?? 0
        }
        func end(_ bar: Int) -> Double { bar + 1 < starts.count ? starts[bar + 1] : min(a.soundEnd, starts[bar] + 4 * period) }
        barLevel = starts.indices.map { bar in
            let power = a.power(from: starts[bar], to: end(bar))
            return power > 0 ? 10 * log10(power) : -100
        }
        barBass = starts.indices.map { bar in
            let first = Int(((starts[bar] - a.gridStart) / a.beatLength).rounded())
            let last = Int(((end(bar) - a.gridStart) / a.beatLength).rounded())
            let power = a.power(from: starts[bar], to: end(bar))
            let level = power > 0 ? 10 * log10(power) : -100
            guard last > first, first >= 0, last <= a.beatCount else { return level - 30 }
            return level + 10 * log10(max(0.001, a.bassShare(first..<last)))
        }
        // The analysis' sections (on its grid's bars), on the model's bars by time.
        let origin = a.beatTime(a.firstBarBeat), gridBar = 4 * a.beatLength
        func barNear(_ time: Double) -> Int? {
            guard let index = starts.indices.min(by: { abs(starts[$0] - time) < abs(starts[$1] - time) }),
                  abs(starts[index] - time) < 2 * period else { return nil }
            return index
        }
        novelty = starts.map { start in
            let index = Int(((start - origin) / gridBar).rounded(.down))
            return shape.novelty.indices.contains(index) ? shape.novelty[index] : 0
        }
        sectionStarts = Array(Set(shape.sectionStarts.compactMap { barNear(origin + Double($0) * gridBar) })).sorted()
        var perEight = [Double](repeating: 0, count: 8)
        for (bar, value) in novelty.enumerated() { perEight[bar % 8] += value }
        phraseOffset = starts.count >= 16 ? (perEight.indices.max { perEight[$0] < perEight[$1] } ?? 0) : 0
    }

    var bars: Int { barStarts.count }
    var barLength: Double { 4 * beatPeriod }

    /// The bar a time falls in (-1 before the first).
    func bar(at time: Double) -> Int {
        guard let first = barStarts.first, time >= first else { return -1 }
        var low = 0, high = barStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if barStarts[middle] <= time { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// Where a bar falls in its 8-bar phrase: 0 on its first bar, counted from the last section start
    /// (from `phraseOffset` before any).
    func phrasePosition(_ bar: Int) -> Int {
        let anchor = sectionStarts.last { $0 <= bar } ?? phraseOffset
        return ((bar - anchor) % 8 + 8) % 8
    }

    /// A phrase or a section starts on this bar.
    func boundary(_ bar: Int) -> Bool {
        guard bar >= 0, bar < bars else { return false }
        if fromModel { return phrasePosition(bar) == 0 || sectionStrength(bar) > 0 }
        let beat = analysis.firstBarBeat + 4 * bar
        return shape.phrase(atBeat: beat) >= 0.75 || shape.sectionStarts.contains(bar)
    }

    /// How strongly a section starts there, 0…1 (0 for a plain phrase boundary).
    func sectionStrength(_ bar: Int) -> Double {
        guard sectionStarts.contains(bar), novelty.indices.contains(bar) else { return 0 }
        return min(1, novelty[bar])
    }

    /// The level of bars `from..<to` (dB, their mean power).
    func levelBars(_ from: Int, _ to: Int) -> Double {
        let range = max(0, from)..<min(bars, max(from, to))
        guard !range.isEmpty else { return -100 }
        let power = range.reduce(0.0) { $0 + pow(10, barLevel[$1] / 10) } / Double(range.count)
        return power > 0 ? 10 * log10(power) : -100
    }

    /// The chance a voice sings at a time, and whether it was measured.
    func voice(at time: Double) -> (chance: Double, known: Bool) {
        if let chance = voices?.presence(at: time) { return (chance, true) }
        return (0.5, false)
    }

    /// Share of the measured time with a voice between two times (nil: not measured).
    func voiceShare(from start: Double, to end: Double) -> Double? {
        guard end > start, let voices, voices.covers(from: start, to: end) else { return nil }
        var sung = 0.0, count = 0.0
        var time = start
        while time < end {
            if (voices.presence(at: time) ?? 0) >= 0.5 { sung += 1 }
            count += 1
            time += VocalActivity.step
        }
        return count > 0 ? sung / count : nil
    }

    func level(from start: Double, to end: Double) -> Double {
        let power = analysis.power(from: start, to: end)
        return power > 0 ? 10 * log10(power) : -100
    }
}

/// A run of whole bars judged on its own beats (a song whose ending holds no single grid can still
/// have one stretch that does, and a mix needs no more): a straight line through its marked beats
/// gives its own tempo and start.
struct SegueStretch: Equatable {
    var bar: Int
    var bars: Int
    var start: Double
    var period: Double
    /// The marked beats inside, seconds.
    var beats: [Double]
    /// 0…1: the worst of its beats' share and how clear its downbeats are.
    var reliability: Double
    /// The worst slide of a bar off the line, seconds.
    var drift: Double

    var length: Double { period * 4 * Double(bars) }
    var end: Double { start + length }

    /// The stretch of `bars` bars from `bar`, or nil when its beats can't be relied on. `metre` stands
    /// for how sure the downbeats are where the model gave none.
    static func measure(_ song: SegueSong, bar: Int, bars: Int, tuning: SegueTuning, metre: Double = 1) -> SegueStretch? {
        song.fromModel ? onModel(song, bar: bar, bars: bars, tuning: tuning, metre: metre)
            : onGrid(song, bar: bar, bars: bars, tuning: tuning)
    }

    /// On the model's beats: those between the stretch's first bar start and the bar after its last
    /// (a quarter of a beat early on both), at least 85 % of the beats it should hold and no more than
    /// one extra; a straight line through them by their place in it, within 5 % of its rough tempo,
    /// 95 % of them within the phase guard of the line and no bar sliding off it; downbeats the model
    /// was sure of on average. Its reliability is the worse of its beats' share and that confidence.
    private static func onModel(_ song: SegueSong, bar: Int, bars: Int, tuning: SegueTuning, metre: Double) -> SegueStretch? {
        guard bar >= 0, bars > 0, bar + bars < song.bars else { return nil }
        let from = song.barStarts[bar], to = song.barStarts[bar + bars]
        let count = 4 * bars
        let rough = (to - from) / Double(count)
        guard rough > 0, 60 / rough >= 55, 60 / rough <= 210 else { return nil }
        let beats = song.beats.filter { $0 >= from - rough / 4 && $0 < to - rough / 4 }
        let n = beats.count
        guard Double(n) >= tuning.stretchMinBeatShare * Double(count), n <= count + 1, n >= 2 else { return nil }
        let places = beats.map { (($0 - from) / rough).rounded() }
        let sk = places.reduce(0, +), st = beats.reduce(0, +)
        let skk = places.reduce(0) { $0 + $1 * $1 }
        let skt = zip(places, beats).reduce(0) { $0 + $1.0 * $1.1 }
        let denominator = Double(n) * skk - sk * sk
        guard denominator > 0 else { return nil }
        let period = (Double(n) * skt - sk * st) / denominator
        let start = (st - period * sk) / Double(n)
        guard period > 0, abs(period / rough - 1) <= 0.05 else { return nil }
        let residuals = zip(places, beats).map { $0.1 - (start + period * $0.0) }
        let sorted = residuals.map(abs).sorted()
        guard sorted[Int(Double(n - 1) * 0.95)] <= tuning.phaseP95Max else { return nil }
        var drift = 0.0
        var index = 0
        while index < n {
            let group = residuals[index..<min(n, index + 4)]
            drift = max(drift, abs(group.reduce(0, +) / Double(group.count)))
            index += 4
        }
        guard drift <= tuning.stretchMaxBarDrift else { return nil }
        let down: Double
        if let barDown = song.barDown {
            down = (bar..<(bar + bars)).reduce(0.0) { $0 + (barDown.indices.contains($1) ? barDown[$1] : 0) } / Double(bars)
        } else {
            down = metre
        }
        guard down >= tuning.stretchMinDownConfidence else { return nil }
        let share = min(1, Double(n) / Double(count))
        return SegueStretch(bar: bar, bars: bars, start: start, period: period, beats: beats,
                            reliability: min(share, down), drift: drift)
    }

    /// A build-up has too few clear beats of its own, and the song arrives right after it: the `bars`
    /// bars from `bar` take the beat of the bars they lead into, carried back, when it lands on their
    /// start. Nil when what follows doesn't hold or doesn't line up.
    static func carried(_ song: SegueSong, bar: Int, bars: Int, tuning: SegueTuning, metre: Double = 1) -> SegueStretch? {
        guard bar >= 0, bar < song.bars else { return nil }
        let count = 4 * bars
        for gap in 0...tuning.carrySearchBars {
            guard let next = measure(song, bar: bar + bars + gap, bars: tuning.carryFromBars, tuning: tuning, metre: metre) else { continue }
            let first = next.start - Double(count + 4 * gap) * next.period
            guard abs(first - song.barStarts[bar]) <= tuning.carryMaxOff else { return nil }
            return SegueStretch(bar: bar, bars: bars, start: first, period: next.period,
                                beats: (0..<count).map { first + Double($0) * next.period },
                                reliability: min(next.reliability, tuning.reliabilityForMiddle), drift: next.drift)
        }
        return nil
    }

    /// On the analysis' grid (no model): its marked beats, where the onsets fall.
    private static func onGrid(_ song: SegueSong, bar: Int, bars: Int, tuning: SegueTuning) -> SegueStretch? {
        let a = song.analysis
        guard bar >= 0, bar + bars <= song.bars, a.beatLength > 0 else { return nil }
        let firstBeat = a.firstBarBeat + 4 * bar
        let count = 4 * bars
        var indices: [Double] = [], times: [Double] = []
        for k in 0..<count {
            let beat = firstBeat + k
            guard beat < a.beatPulse.count, beat < a.beatOffset.count, a.beatPulse[beat] >= 0.5,
                  abs(Int(a.beatOffset[beat])) < 100 else { continue }
            indices.append(Double(k))
            times.append(a.beatTime(beat) + Double(a.beatOffset[beat]) / 1000)
        }
        let n = Double(indices.count)
        guard n >= tuning.stretchMinBeatShare * Double(count), n >= 2 else { return nil }
        let sk = indices.reduce(0, +), st = times.reduce(0, +)
        let skk = indices.reduce(0) { $0 + $1 * $1 }
        let skt = zip(indices, times).reduce(0) { $0 + $1.0 * $1.1 }
        let denominator = n * skk - sk * sk
        guard denominator > 0 else { return nil }
        let period = (n * skt - sk * st) / denominator
        let start = (st - period * sk) / n
        guard period > 0, abs(period / a.beatLength - 1) <= 0.05 else { return nil }
        let residuals = zip(indices, times).map { $0.1 - (start + period * $0.0) }
        let sorted = residuals.map(abs).sorted()
        guard sorted[Int(Double(sorted.count - 1) * 0.95)] <= tuning.phaseP95Max else { return nil }
        // The worst bar's average off the line.
        var drift = 0.0
        for barIndex in 0..<bars {
            let inBar = zip(indices, residuals).filter { Int($0.0) / 4 == barIndex }.map(\.1)
            guard !inBar.isEmpty else { continue }
            drift = max(drift, abs(inBar.reduce(0, +) / Double(inBar.count)))
        }
        guard drift <= tuning.stretchMaxBarDrift else { return nil }
        // How clear the downbeats are: their pulse against the other beats' (a song made to a
        // four-on-the-floor kick has little to tell them apart, and isn't penalised below half).
        var down = 0.0, other = 0.0, downCount = 0.0, otherCount = 0.0
        for k in 0..<count where firstBeat + k < a.beatPulse.count {
            if k % 4 == 0 { down += Double(a.beatPulse[firstBeat + k]); downCount += 1 } else { other += Double(a.beatPulse[firstBeat + k]); otherCount += 1 }
        }
        let ratio = downCount > 0 && otherCount > 0 && other > 0 ? (down / downCount) / (other / otherCount) : 1
        let downbeats = 0.5 + 0.5 * max(0, min(1, (ratio - 1) / 0.3))
        let share = min(1, n / Double(count))
        return SegueStretch(bar: bar, bars: bars, start: start, period: period, beats: times,
                            reliability: min(share, downbeats) * min(1, a.gridFit + 0.35), drift: drift)
    }

    /// How far the two stretches' beats fall apart once the incoming one plays at `rate` from its start
    /// on the outgoing one's: the sparser beats against the nearest of the denser. Median and 95th
    /// percentile, seconds; nil with too few to tell.
    static func phase(_ outgoing: SegueStretch, _ incoming: SegueStretch, rate: Double) -> (median: Double, p95: Double)? {
        let xa = outgoing.beats.map { $0 - outgoing.start }
        let xb = incoming.beats.map { ($0 - incoming.start) / rate }
        let (sparse, dense) = xa.count <= xb.count ? (xa, xb) : (xb, xa)
        guard sparse.count >= 2, !dense.isEmpty else { return nil }
        let gaps = sparse.map { value -> Double in
            var best = Double.greatestFiniteMagnitude
            for other in dense { best = min(best, abs(other - value)) }
            return best
        }.sorted()
        return (gaps[gaps.count / 2], gaps[Int(Double(gaps.count - 1) * 0.95)])
    }
}

/// The policy's answer: the level, the plan (none for plain playback), and why the levels above weren't used.
struct SegueDecision: Sendable {
    var level: SegueLevel
    var plan: SeguePlan?
    var attempts: [SegueAttempt]
    var why: String { attempts.map(\.description).joined(separator: "; ") }
}

/// How long a mix may be, as the listener sets it (Settings › Riproduzione › Durata del mix): short
/// up to 8 bars, normal up to 16, long up to 32, with the fades shorter or longer to match. The
/// longest length the two songs allow is played; a shorter one only when no longer one fits.
enum SegueLength: Int, CaseIterable, Sendable {
    case short = 0, normal = 1, long = 2

    var maxBars: Int { [8, 16, 32][rawValue] }

    /// The tuning for this length: the beat-matched lengths tried at the top level, the filtered
    /// fades' and the plain fade's lengths, and how far from the end the outgoing song may leave.
    func apply(to tuning: SegueTuning) -> SegueTuning {
        var t = tuning
        switch self {
        case .short:
            t.filteredLengths = [6, 4]
            t.simpleFade = 4
        case .normal:
            break
        case .long:
            t.longLengths = [32, 16]
            t.filteredLengths = [14, 10, 8]
            t.simpleFade = 10
            t.exitZoneShare = 0.45
        }
        return t
    }
}

struct SegueRequest {
    var outgoing: SegueSong
    var incoming: SegueSong
    /// Nothing may start before this time of the outgoing song (its preparation is counted in).
    var earliestExit: Double = 0
    /// The two songs follow each other on their album, played in order.
    var sameAlbum = false
    var harmonic = true
    var length = SegueLength.normal
    /// The automatic equaliser: the bass, the bands, the filters and the echo change hands; off,
    /// only the levels move (and no beat-matched cut between two songs' basses is risked).
    var eq = true
    /// The speed the outgoing song plays at: a song a live mix brought in keeps the speed it was
    /// matched at, so the next one is matched to that. A beat-matched window's speed change is the
    /// incoming song's own against it (`rate` × this).
    var outgoingRate = 1.0
    var tuning = SegueTuning()
}

/// Writes the transition between two songs: candidates are generated, rejected by the guards (a
/// crossed guard is never bought back by a good score), scored, and the best kept if it clears its
/// family's threshold; otherwise the next level is tried. The same request always gives the same plan.
enum SeguePolicy {
    static func decide(_ request: SegueRequest) -> SegueDecision {
        var run = Run(request)
        return run.decide()
    }

    private struct Point {
        var time: Double
        var bar: Int
        var rank: Double
        var boundary: Bool
        /// The incoming song arrives here (its level rises past the window): see `arrival`.
        var arrives = false
    }

    private struct Found {
        var plan: SeguePlan
        var score: Double
        var pick: Double
    }

    /// What the guards read of a candidate, apart from any score.
    private struct Measures {
        var rateChange = 0.0
        var phaseMedian: Double? = 0
        var phaseP95: Double? = 0
        var driftBeats = 0.0
        var voiceOverlap = 0.0
        var contentCut = 0.0
        var contentCutShare = 0.0
        var played = Double.infinity
        var loudnessJump = 0.0
    }

    private struct Run {
        let r: SegueRequest
        let a: SegueSong
        let b: SegueSong
        let t: SegueTuning
        var attempts: [SegueAttempt] = []
        let zoneStart: Double

        init(_ request: SegueRequest) {
            r = request
            a = request.outgoing
            b = request.incoming
            t = request.length.apply(to: request.tuning)
            let music = a.analysis.soundEnd - a.analysis.soundStart
            zoneStart = max(a.analysis.soundStart + music * (1 - t.exitZoneShare), request.earliestExit)
        }

        mutating func decide() -> SegueDecision {
            if albumContinuity {
                return SegueDecision(level: .normal, plan: nil,
                                     attempts: SegueLevel.allCases.filter { $0 != .normal }.map { SegueAttempt(level: $0, cause: .albumContinuity) })
            }
            for level in SegueLevel.allCases where level != .normal {
                guard let found = attempt(level) else { continue }
                var plan = found.plan
                let problems = SegueValidator.problems(plan, outgoingDuration: a.analysis.duration, incomingDuration: b.analysis.duration)
                guard problems.isEmpty else {
                    attempts.append(SegueAttempt(level: level, cause: .invalidPlan, detail: problems.joined(separator: ", ")))
                    continue
                }
                plan.score = found.score
                plan.attempts = attempts
                return SegueDecision(level: level, plan: plan, attempts: attempts)
            }
            return SegueDecision(level: .normal, plan: nil, attempts: attempts)
        }

        var albumContinuity: Bool {
            r.sameAlbum && a.analysis.duration - a.analysis.soundEnd <= t.gaplessMaxSilence
                && b.analysis.soundStart <= t.gaplessMaxSilence
        }

        mutating func fail(_ level: SegueLevel, _ cause: SegueCause, _ detail: String = "") -> Found? {
            attempts.append(SegueAttempt(level: level, cause: cause, detail: detail))
            return nil
        }

        mutating func attempt(_ level: SegueLevel) -> Found? {
            switch level {
            case .lockedLong: return locked(level, lengths: t.longLengths, phrases: true)
            case .lockedShort: return locked(level, lengths: [t.lockedMiddleBars, t.lockedShortBars], phrases: true)
            case .lockedBeat:
                // On any bar, short: only with the bass handed over by the equaliser.
                guard r.eq else { return fail(level, .disabled, "equaliser off") }
                return locked(level, lengths: [t.lockedShortBars, t.lockedTinyBars], phrases: false)
            case .filtered: return filtered(level)
            case .hard: return hard(level)
            case .simpleFade: return simple(level)
            case .normal: return nil
            }
        }

        // MARK: Reliability

        var vocalReliability: Double {
            let aKnown = a.voices.map { !$0.regions.isEmpty } ?? false
            let bKnown = b.voices.map { !$0.regions.isEmpty } ?? false
            return aKnown && bKnown ? 1 : (aKnown || bKnown ? 0.5 : 0.2)
        }

        var keyReliability: Double { min(a.analysis.keyClarity, b.analysis.keyClarity) }

        // MARK: Candidates

        /// The outgoing song's bars from the exit zone, instrumental endings first, the latest kept too.
        func exits(phrases: Bool, fitting length: Double) -> [Point] {
            let limit = a.analysis.soundEnd
            var points: [Point] = []
            for (bar, start) in a.barStarts.enumerated() where start >= zoneStart - 0.05 && start + length <= limit {
                let on = a.boundary(bar)
                if phrases && !on { continue }
                points.append(Point(time: start, bar: bar, rank: instrumental(after: start) + start / max(1, limit) * 1e-3, boundary: on))
            }
            return best(points)
        }

        func best(_ points: [Point]) -> [Point] {
            let ranked = points.sorted { $0.rank > $1.rank }.prefix(t.candidatesPerSide)
            let late = points.sorted { $0.time > $1.time }.prefix(t.lateCandidates)
            var seen = Set<Int>(), out: [Point] = []
            for point in ranked + late where seen.insert(Int(point.time * 1000)).inserted { out.append(point) }
            return out
        }

        /// The share of the outgoing song from `time` to its end without a voice (0.5 unmeasured).
        func instrumental(after time: Double) -> Double {
            guard let share = a.voiceShare(from: time, to: a.analysis.soundEnd) else { return 0.5 }
            return 1 - share
        }

        /// How far the incoming song arrives right after a window of `bars` bars from `bar`, 0…1: its
        /// level over the next 4 bars against the window's, from `arrivalRiseMin` to `arrivalRiseFull` dB.
        func arrival(_ bar: Int, bars: Int) -> Double {
            let end = bar + bars
            guard bars > 0, end + 5 <= b.bars else { return 0 }
            let rise = b.levelBars(end, end + 4) - b.levelBars(max(0, end - bars), end)
            return max(0, min(1, (rise - t.arrivalRiseMin) / (t.arrivalRiseFull - t.arrivalRiseMin)))
        }

        /// The incoming song's first downbeat at its attack, then later section and phrase starts,
        /// and, for a window of `bars` bars, where the song arrives after it.
        func entries(phrases: Bool, span: Double, bars: Int = 0) -> [Point] {
            let first = b.barStarts.firstIndex { $0 >= b.analysis.soundStart - 0.08 }
            var points: [Point] = []
            if let first {
                points.append(Point(time: b.barStarts[first], bar: first, rank: 1, boundary: true))
                let zone = min(b.analysis.soundStart + t.entryZone, b.analysis.soundEnd / 3)
                var bar = first + 1
                while bar < b.bars, b.barStarts[bar] < zone {
                    let on = b.boundary(bar)
                    let arrives = bars > 0 ? arrival(bar, bars: bars) : 0
                    if on || !phrases || arrives > 0 {
                        let base = b.sectionStrength(bar) > 0 ? t.entrySection : t.entryOther
                        let skipped = b.barStarts[bar] - b.analysis.soundStart
                        points.append(Point(time: b.barStarts[bar], bar: bar, rank: max(arrives, base * (1 - skipped / t.entryZone)),
                                            boundary: on, arrives: arrives > 0))
                    }
                    bar += 1
                }
            } else {
                points.append(Point(time: b.analysis.soundStart, bar: -1, rank: 1, boundary: true))
            }
            return points.filter { $0.time + span <= b.analysis.soundEnd }.sorted { $0.rank > $1.rank }.prefix(t.candidatesPerSide).map { $0 }
        }

        // MARK: Measures

        /// Guards' measures for a window from `exit` (outgoing) and `entry` (incoming), `length` long
        /// in the outgoing song's time and `span` in the incoming one's, with `lanes` as heard.
        func measures(exit: Double, entry: Double, length: Double, span: Double, lanes: [SegueLane]) -> Measures {
            var m = Measures()
            m.contentCut = max(0, a.analysis.soundEnd - (exit + length))
            let music = max(1, a.analysis.soundEnd - a.analysis.soundStart)
            m.contentCutShare = m.contentCut / music
            m.played = exit - a.analysis.soundStart
            m.voiceOverlap = overlap(exit: exit, entry: entry, length: length, span: span, lanes: lanes)
            return m
        }

        /// Seconds where both songs sing and both are clearly heard (each within 10 dB of full).
        func overlap(exit: Double, entry: Double, length: Double, span: Double, lanes: [SegueLane]) -> Double {
            guard let levelA = lanes.first(where: { $0.side == .outgoing && $0.target == .level }),
                  let levelB = lanes.first(where: { $0.side == .incoming && $0.target == .level }) else { return 0 }
            let steps = max(1, Int(length / 0.25))
            var both = 0.0
            for step in 0..<steps {
                let x = (Double(step) + 0.5) / Double(steps)
                guard levelA.value(at: x) > -10, levelB.value(at: x) > -10 else { continue }
                let va = a.voice(at: exit + x * length), vb = b.voice(at: entry + x * span)
                guard va.known, vb.known else { continue }
                if va.chance >= 0.5, vb.chance >= 0.5 { both += length / Double(steps) }
            }
            return both
        }

        func crossed(_ family: SegueFamily, _ m: Measures) -> [String] {
            var out: [String] = []
            if m.contentCut > t.contentCutMax || m.contentCutShare > t.contentCutMaxShare { out.append("content cut") }
            if m.played < t.minPlayed { out.append("min played") }
            if family != .hard, m.voiceOverlap > t.voiceOverlapMax { out.append("voice") }
            if family == .locked {
                if m.rateChange > t.maxRateChange { out.append("rate") }
                if m.phaseMedian == nil || (m.phaseMedian ?? 1) > t.phaseMedianMax { out.append("phase median") }
                if m.phaseP95 == nil || (m.phaseP95 ?? 1) > t.phaseP95Max { out.append("phase p95") }
                if m.driftBeats > t.driftMaxBeats { out.append("drift") }
            }
            if family == .hard, m.loudnessJump > t.loudnessJumpMax { out.append("loudness jump") }
            return out
        }

        // MARK: Score

        /// Σ weight × reliability × note − Σ penalty × defect: an uncertain measure weighs less.
        func score(exit: Point, entry: Point, length: Double, span: Double, lanes: [SegueLane], phaseMedian: Double?,
                   rateChange: Double, pulse: Double, effects: Int) -> Double {
            var total = 0.0
            if let phaseMedian {
                let note = Self.falling(phaseMedian, full: t.rhythmFull, zero: t.phaseMedianMax)
                total += t.weightRhythm * pulse * note
            }
            let phrase = (exit.boundary ? 0.5 : 0) + (entry.boundary ? 0.5 : 0)
            let phraseReliability = max(0.3, max(a.sectionStrength(exit.bar), b.sectionStrength(entry.bar)))
            total += t.weightPhrase * phraseReliability * phrase
            let levelA = a.level(from: exit.time, to: exit.time + min(4, length))
            let levelB = b.level(from: entry.time + max(0, span - 4), to: entry.time + span)
            total += t.weightEnergy * Self.bell(levelA - levelB, sigma: t.energySigma)
            let exitNote = 1 - (a.voiceShare(from: exit.time + length / 2, to: exit.time + length) ?? 0.5)
            total += t.weightExit * vocalReliability * exitNote
            total += t.weightEntry * entry.rank
            if r.harmonic {
                let keys = TransitionJudge.compatibility(
                    (a.analysis.key, a.analysis.minor, a.analysis.keyClarity), (b.analysis.key, b.analysis.minor, b.analysis.keyClarity),
                    a.analysis.chroma(from: exit.time, to: exit.time + length), b.analysis.chroma(from: entry.time, to: entry.time + span))
                total += t.weightKey * max(0.2, keyReliability) * keys
            }
            total -= t.penaltySpeed * Self.rising(rateChange, free: t.rateFree, full: t.maxRateChange)
            let overlap = self.overlap(exit: exit.time, entry: entry.time, length: length, span: span, lanes: lanes)
            total -= t.penaltyVoice * min(1, overlap / max(0.1, t.voiceOverlapMax))
            let voiceAfter = a.voiceShare(from: exit.time + length, to: a.analysis.soundEnd) ?? 0
            let voiceBefore = b.voiceShare(from: b.analysis.soundStart, to: entry.time) ?? 0
            total -= t.penaltyVoiceCut * max(voiceAfter, voiceBefore)
            total -= t.penaltyBass * bassClash(exit: exit.time, entry: entry.time, length: length, span: span, lanes: lanes)
            let lost = max(0, a.analysis.soundEnd - (exit.time + length)) + max(0, entry.time - b.analysis.soundStart)
            total -= t.penaltyLost * min(1, lost / t.lostFull)
            total -= t.penaltySobriety * min(1, Double(effects) / 3)
            return total
        }

        /// The bass the two songs play at once, against the bass they play in all, through the lanes.
        func bassClash(exit: Double, entry: Double, length: Double, span: Double, lanes: [SegueLane]) -> Double {
            func lane(_ side: SegueLane.Side, _ target: SegueLane.Target) -> SegueLane? {
                lanes.first { $0.side == side && $0.target == target }
            }
            let levelA = lane(.outgoing, .level), levelB = lane(.incoming, .level)
            let bassA = lane(.outgoing, .lowShelf), bassB = lane(.incoming, .lowShelf)
            var common = 0.0, total = 0.0
            for step in 0..<32 {
                let x = (Double(step) + 0.5) / 32
                let ga = pow(10, ((levelA?.value(at: x) ?? 0) + (bassA?.value(at: x) ?? 0)) / 20)
                let gb = pow(10, ((levelB?.value(at: x) ?? 0) + (bassB?.value(at: x) ?? 0)) / 20)
                let ea = pow(10, Self.quiet(a.barBass, a.bar(at: exit + x * length)) / 20) * ga
                let eb = pow(10, Self.quiet(b.barBass, b.bar(at: entry + x * span)) / 20) * gb
                common += min(ea, eb)
                total += max(ea, eb)
            }
            return total > 0 ? common / total : 0
        }

        /// A bar's value, or very quiet past either end.
        static func quiet(_ values: [Double], _ index: Int) -> Double { values.indices.contains(index) ? values[index] : -100 }

        static func falling(_ value: Double, full: Double, zero: Double) -> Double {
            value <= full ? 1 : (value >= zero || zero <= full ? 0 : (zero - value) / (zero - full))
        }

        static func rising(_ value: Double, free: Double, full: Double) -> Double { 1 - falling(value, full: free, zero: full) }

        static func bell(_ distance: Double, sigma: Double) -> Double { exp(-distance * distance / (2 * sigma * sigma)) }

        /// How much louder the incoming song is than the outgoing one around the window (positive:
        /// louder), corrected only past `matchFromDB`, at most `matchToDB`.
        func loudnessMatch(exit: Double, entry: Double, length: Double, span: Double) -> (a: Double, b: Double) {
            let levelA = a.level(from: exit, to: exit + length), levelB = b.level(from: entry, to: entry + span)
            let gap = levelB - levelA
            guard abs(gap) > t.matchFromDB else { return (1, 1) }
            let corrected = min(t.matchToDB, abs(gap))
            let factor = pow(10, -corrected / 20)
            return gap > 0 ? (1, factor) : (factor, 1)
        }

        // MARK: Levels

        mutating func locked(_ level: SegueLevel, lengths asked: [Int], phrases: Bool) -> Found? {
            let lengths = asked.filter { $0 <= r.length.maxBars }
            guard !lengths.isEmpty else { return fail(level, .lengthNotAllowed, "mix length") }
            guard a.analysis.beatLength > 0, b.analysis.beatLength > 0, a.bars > 0, b.bars > 0 else {
                return fail(level, .noGrid)
            }
            var best: Found?
            var seen = 0, stretches = false, tooLong = false
            var closest = Double.infinity
            var refused: [String: Int] = [:]
            let compiler = SegueCompiler(tuning: t)
            for bars in lengths {
                // Only the bars a window of this length fits after: the latest exits first would
                // otherwise all lie too near the end for a long one.
                let outs = exits(phrases: phrases, fitting: Double(bars) * a.barLength).compactMap { point -> (Point, SegueStretch)? in
                    guard let stretch = SegueStretch.measure(a, bar: point.bar, bars: bars, tuning: t, metre: a.tailMetre),
                          stretch.start >= zoneStart - 0.05, stretch.end <= a.analysis.soundEnd else { return nil }
                    return (point, stretch)
                }
                stretches = stretches || !outs.isEmpty
                // The incoming bars over the same time: as many, or half or twice as many (half or double tempo).
                for (barsB, factor) in [(bars, 1.0), (bars / 2, 2.0), (bars * 2, 0.5)] {
                    if factor != 1, bars > t.lockedMiddleBars || barsB < t.lockedTinyBars { continue }
                    let ins = entries(phrases: phrases, span: 0, bars: barsB).compactMap { point -> (Point, SegueStretch)? in
                        guard point.bar >= 0 else { return nil }
                        // A build-up the song arrives after takes the beat of what follows it.
                        let stretch = SegueStretch.measure(b, bar: point.bar, bars: barsB, tuning: t, metre: b.headMetre)
                            ?? (point.arrives ? SegueStretch.carried(b, bar: point.bar, bars: barsB, tuning: t, metre: b.headMetre) : nil)
                        return stretch.map { (point, $0) }
                    }
                    for (exit, sa) in outs {
                        for (entry, sb) in ins {
                            let rate = sb.length / sa.length
                            let change = abs(rate * r.outgoingRate - 1)
                            closest = min(closest, change)
                            if change > t.maxRateChange { continue }
                            let pulse = min(sa.reliability, sb.reliability)
                            let cap = pulse >= t.reliabilityForLong ? r.length.maxBars : (pulse >= t.reliabilityForMiddle ? t.lockedMiddleBars : t.lockedShortBars)
                            if bars > cap { tooLong = true; continue }
                            seen += 1
                            let phase = SegueStretch.phase(sa, sb, rate: rate)
                            let shape = Self.lockedShape(exitTime: sa.start, entryTime: sb.start, bars: bars, overlapRisk: voiceRisk(sa, sb),
                                                         eq: r.eq, rings: rings(after: sa.end))
                            let swap = swapShare(exit: sa, entry: sb, bars: bars, rate: rate)
                            let match = loudnessMatch(exit: sa.start, entry: sb.start, length: sa.length, span: sb.length)
                            let lanes = equalised(compiler.locked(shape, swap: swap, beatShare: 1 / Double(bars * 4), matchA: match.a, matchB: match.b))
                            var m = measures(exit: sa.start, entry: sb.start, length: sa.length, span: sb.length, lanes: lanes)
                            m.rateChange = change
                            m.phaseMedian = phase?.median
                            m.phaseP95 = phase?.p95
                            m.driftBeats = (sa.drift * sa.drift + sb.drift * sb.drift).squareRoot() / sa.period
                            let crossed = crossed(.locked, m)
                            if !crossed.isEmpty { for guardName in crossed { refused[guardName, default: 0] += 1 }; continue }
                            let effects = Set(lanes.map(\.target)).count - 1
                            let score = score(exit: exit, entry: entry, length: sa.length, span: sb.length, lanes: lanes,
                                              phaseMedian: phase?.median, rateChange: change, pulse: pulse, effects: effects)
                            let lost = max(0, a.analysis.soundEnd - sa.end) + max(0, sb.start - b.analysis.soundStart)
                            let arrival = entry.arrives && score >= t.thresholdLocked ? t.arrivalPick * entry.rank : 0
                            let pick = score - t.lostPickLocked * min(1, lost / t.lostFull) + arrival
                            guard best.map({ pick > $0.pick }) ?? true else { continue }
                            let plan = SeguePlan(level: level, shape: shape, outgoingStart: sa.start, incomingStart: sb.start, rate: rate,
                                                 length: sa.length, bars: bars, tempo: 60 / sa.period, phaseMedian: phase?.median,
                                                 phaseP95: phase?.p95, lanes: lanes, swap: swap,
                                                 echoDelay: shape == .echoTail ? echoDelay(sa.period) : nil)
                            best = Found(plan: plan, score: score, pick: pick)
                        }
                    }
                }
                // The longest length that works: shorter only when it has to be.
                if let best, best.score >= t.thresholdLocked { break }
            }
            if seen == 0 {
                if !stretches { return fail(level, .noGrid) }
                if tooLong { return fail(level, .lengthNotAllowed, "reliability") }
                if closest == .infinity { return fail(level, .noCandidate) }
                return fail(level, .tempoOutOfReach, String(format: "%.1f %%", closest * 100))
            }
            return settle(level, best, threshold: t.thresholdLocked, refused: refused)
        }

        mutating func settle(_ level: SegueLevel, _ best: Found?, threshold: Double, refused: [String: Int]) -> Found? {
            guard let best else {
                return fail(level, .guards, refused.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
            }
            guard best.score >= threshold else { return fail(level, .belowThreshold, String(format: "%.2f", best.score)) }
            return best
        }

        /// Whether two voices are likely to meet: measured on both sides over the window.
        func voiceRisk(_ sa: SegueStretch, _ sb: SegueStretch) -> Bool {
            let va = a.voiceShare(from: sa.start, to: sa.end) ?? 0
            let vb = b.voiceShare(from: sb.start, to: sb.end) ?? 0
            return va > 0.3 && vb > 0.3
        }

        /// Where the bass changes hands: a section start in the incoming song's stretch if there is one
        /// between a quarter and three quarters of it, else the middle; on a bar line.
        func swapShare(exit: SegueStretch, entry: SegueStretch, bars: Int, rate: Double) -> Double {
            guard bars >= 2 else { return 0.5 }
            let candidates = (1..<bars).filter { Double($0) / Double(bars) >= 0.25 && Double($0) / Double(bars) <= 0.75 }
            let section = candidates.first { b.sectionStrength(entry.bar + $0 * entry.bars / max(1, bars)) > 0 }
            return Double(section ?? bars / 2) / Double(bars)
        }

        /// The locked shape: a cut when voices would meet in a short window, otherwise one of the
        /// shapes chosen from the pair itself, so a pair always sounds the same and a playlist varies.
        /// Without the equaliser only the levels move (a bass swap of levels, or a cut); the echo needs
        /// room after the window for its repeats.
        static func lockedShape(exitTime: Double, entryTime: Double, bars: Int, overlapRisk: Bool, eq: Bool = true,
                                rings: Bool = false) -> SegueShape {
            if overlapRisk && bars <= 4 { return .cutOnBeat }
            let hash = Int((exitTime * 1000).rounded()) &* 31 &+ Int((entryTime * 1000).rounded())
            var shapes: [SegueShape] = bars >= 8 ? [.bassSwap, .threeBand, .filterOpen, .riseOut] : [.bassSwap, .filterOpen]
            if !eq { shapes = bars >= 8 ? [.bassSwap] : [.bassSwap, .cutOnBeat] }
            if eq, rings, bars >= 4 { shapes.append(.echoTail) }
            return shapes[abs(hash) % shapes.count]
        }

        /// The outgoing song has the time after a window ending at `end` for an echo to ring out.
        func rings(after end: Double) -> Bool { a.analysis.duration - end >= SeguePlan.echoTail }

        /// The echo's delay on the outgoing song's beat: a dotted eighth, a beat, an eighth or a
        /// beat and a half, the first between `echoMin` and `echoMax`.
        func echoDelay(_ period: Double) -> Double {
            for share in [0.75, 1, 0.5, 1.5] where period * share >= t.echoMin && period * share <= t.echoMax {
                return period * share
            }
            return max(t.echoMin, min(t.echoMax, period))
        }

        /// The lanes as the equaliser setting allows: without it, only the levels.
        func equalised(_ lanes: [SegueLane]) -> [SegueLane] { r.eq ? lanes : lanes.filter { $0.target == .level } }

        mutating func filtered(_ level: SegueLevel) -> Found? {
            var best: Found?
            var refused: [String: Int] = [:]
            let compiler = SegueCompiler(tuning: t)
            for length in t.filteredLengths {
                let outs = a.bars > 0 ? exits(phrases: false, fitting: length)
                    : [Point(time: max(zoneStart, a.analysis.soundEnd - length), bar: -1, rank: 0.5, boundary: false)]
                for exit in outs {
                    for entry in entries(phrases: false, span: length) {
                        let voiceOut = a.voiceShare(from: exit.time, to: exit.time + length) ?? 0
                        let voiceIn = b.voiceShare(from: entry.time, to: entry.time + length) ?? 0
                        // What the music asks for first, then a choice from the pair itself.
                        let variant = abs(Int(exit.time * 10) &+ Int(entry.time * 10))
                        var choices: [SegueShape] = r.eq ? [.sweepOut, .evenFade] : [.evenFade]
                        if r.eq, a.fromModel || a.analysis.isGridLocked, rings(after: exit.time + length) { choices.append(.echoOut) }
                        let shape: SegueShape = voiceOut > 0.3 ? .quickOut : (voiceIn > 0.3 ? .lateOut : choices[variant % choices.count])
                        let match = loudnessMatch(exit: exit.time, entry: entry.time, length: length, span: length)
                        let lanes = equalised(compiler.filtered(shape, matchA: match.a, matchB: match.b))
                        let m = measures(exit: exit.time, entry: entry.time, length: length, span: length, lanes: lanes)
                        let crossed = crossed(.filtered, m)
                        if !crossed.isEmpty { for name in crossed { refused[name, default: 0] += 1 }; continue }
                        let score = score(exit: exit, entry: entry, length: length, span: length, lanes: lanes, phaseMedian: nil,
                                          rateChange: 0, pulse: 0, effects: Set(lanes.map(\.target)).count - 1)
                        let lost = max(0, a.analysis.soundEnd - (exit.time + length)) + max(0, entry.time - b.analysis.soundStart)
                        let pick = score - t.lostPickFade * min(1, lost / t.lostFull)
                        guard best.map({ pick > $0.pick }) ?? true else { continue }
                        let plan = SeguePlan(level: level, shape: shape, outgoingStart: exit.time, incomingStart: entry.time, rate: 1,
                                             length: length, bars: nil, tempo: nil, phaseMedian: nil, phaseP95: nil, lanes: lanes,
                                             swap: t.filteredSwap,
                                             echoDelay: shape == .echoOut ? echoDelay(a.beatPeriod) : nil)
                        best = Found(plan: plan, score: score, pick: pick)
                    }
                }
                if let best, best.score >= t.thresholdFiltered { break }
            }
            return settle(level, best, threshold: t.thresholdFiltered, refused: refused)
        }

        mutating func hard(_ level: SegueLevel) -> Found? {
            guard a.bars > 0, a.fromModel || a.analysis.isGridLocked else { return fail(level, .noGrid) }
            var best: Found?
            var refused: [String: Int] = [:]
            let compiler = SegueCompiler(tuning: t)
            let beat = a.beatPeriod
            for exit in exits(phrases: true, fitting: beat) {
                for entry in entries(phrases: true, span: beat) {
                    let length = 2 * beat
                    let lanes = compiler.cut(at: 0.5, ramp: t.microFade / length)
                    var m = measures(exit: exit.time - beat, entry: entry.time - beat, length: length, span: length, lanes: lanes)
                    // Left out is what follows the cut in A and what precedes the entry in B.
                    let lost = max(0, a.analysis.soundEnd - exit.time) + max(0, entry.time - b.analysis.soundStart)
                    if lost > t.hardLostMax { refused["lost", default: 0] += 1; continue }
                    m.loudnessJump = abs(a.level(from: exit.time - 2, to: exit.time) - b.level(from: entry.time, to: entry.time + 2))
                    let crossed = crossed(.hard, m)
                    if !crossed.isEmpty { for name in crossed { refused[name, default: 0] += 1 }; continue }
                    let score = score(exit: exit, entry: entry, length: length, span: length, lanes: lanes, phaseMedian: nil,
                                      rateChange: 0, pulse: 0, effects: 0)
                    guard best.map({ score > $0.pick }) ?? true else { continue }
                    // The window: a beat before the cut in each song, so the cut lands on both downbeats.
                    let start = max(0, exit.time - beat), entryStart = max(0, entry.time - beat)
                    let plan = SeguePlan(level: level, shape: .cut, outgoingStart: start, incomingStart: entryStart, rate: 1,
                                         length: length, bars: nil, tempo: nil, phaseMedian: nil, phaseP95: nil, lanes: lanes,
                                         swap: 0.5)
                    best = Found(plan: plan, score: score, pick: score)
                }
            }
            return settle(level, best, threshold: t.thresholdHard, refused: refused)
        }

        mutating func simple(_ level: SegueLevel) -> Found? {
            let compiler = SegueCompiler(tuning: t)
            let entry = b.barStarts.first { $0 >= b.analysis.soundStart - 0.08 } ?? b.analysis.soundStart
            // A fade that ends with the outgoing song's music.
            var length = min(t.simpleFade, max(1, a.analysis.soundEnd - zoneStart))
            var start = max(zoneStart, a.analysis.soundEnd - length)
            var lanes = equalised(compiler.fade())
            let overlapping = overlap(exit: start, entry: entry, length: length, span: length, lanes: lanes) > t.voiceOverlapMax
            if overlapping {
                // Over a voice: short, at the very end, without the voice guard.
                length = t.simpleVoiceFade
                start = max(zoneStart, a.analysis.soundEnd - length)
                lanes = equalised(compiler.fade())
            }
            guard start + length <= a.analysis.duration, entry + length <= b.analysis.duration else {
                return fail(level, .noCandidate)
            }
            let plan = SeguePlan(level: level, shape: .fade, outgoingStart: start, incomingStart: entry, rate: 1, length: length,
                                 bars: nil, tempo: nil, phaseMedian: nil, phaseP95: nil, lanes: lanes, swap: 0.5)
            return Found(plan: plan, score: 0, pick: 0)
        }
    }
}
