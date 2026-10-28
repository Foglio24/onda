import Foundation

/// How AutoMix takes one song into the next. Times are in each song's own time; tempos in BPM.
/// The mix itself is rendered ahead (see `MixSchedule` and `AutoMixRenderer`) and takes over from
/// the playing song at `handover`.
struct TransitionPlan: Equatable, Sendable {
    enum Style: String, Sendable {
        /// Beats matched like a DJ: the playing song glides to a tempo between the two, the next one
        /// comes in on a downbeat at that tempo (skipping a long intro), they play together for
        /// several bars while the bass passes from one to the other, then the new song glides back
        /// to its own tempo.
        case beatMatched
        /// No beats to match (or tempos too far apart): a long crossfade on the song's ending,
        /// filtered when the outgoing song has a beat.
        case blend
        /// The song fades out on its own: the next one comes in during the fade.
        case fade
        /// No overlap: the next song starts as this one's sound ends, the silence between them
        /// left out.
        case gapless
        /// No overlap: this song ends in full, then the next one starts after a short breath.
        case sequence
        /// Two songs that follow each other on their album, played in order: as the album has
        /// them, nothing left out (a song running into the next stays joined).
        case album
    }

    var style: Style
    /// Outgoing song's time where the mix takes over from normal playback (the song plays on alone
    /// in the mix until `outStart`).
    var handover: Double
    /// Outgoing song's time when the next song starts, and when it has faded out.
    var outStart: Double
    var outEnd: Double
    /// Where the next song starts, in its own time.
    var inStart: Double
    /// The outgoing song's tempo, the tempo both play at while together, and the next song's tempo.
    /// All equal when the beats aren't matched (nothing changes speed).
    var tempoOut: Double
    var tempoMeet: Double
    var tempoIn: Double
    /// The outgoing song's downbeat the next song's first downbeat lands on.
    var alignment: Double?
    /// Progress (0…1) at which the bass starts and ends passing from one song to the other; nil
    /// when it doesn't.
    var swapStart: Double?
    var swapEnd: Double?
    /// Progress at which the next song has fully come in.
    var fadeIn: Double
    /// Progress from which a high-pass filter sweeps up through the outgoing song; nil for none.
    var filterOut: Double?
    /// Beat-matched: how many of the outgoing song's bars the two play together.
    var bars: Int?
    /// A playlist Mix's choices (see `MixDesign`): when set, they give the curves.
    var design: MixDesign? = nil
    /// One bar of the song leaving, in seconds.
    var barLength: Double = 2
    /// Echo effects: the time between repeats and how much each feeds the next.
    var echoTime: Double = 0.5
    var echoFeedback: Double = 0
    /// The song leaving repeats a stretch of beats, from `loop.start` on.
    var loop: MixLoopPlan? = nil
    /// Automatic plans: the progress at which the next song starts coming in (it is fully in at
    /// `fadeIn`) and at which this one starts going (it has gone at the end), each along an
    /// equal-power curve. Where the two overlap at full, the trims hold them down.
    var fadeInFrom: Double = 0
    var fadeOutFrom: Double = 0
    /// Gains on each song, sampled evenly through the overlap (empty: none), so that together they
    /// never sound louder than the louder of the two alone (see `TransitionJudge`). The song leaving
    /// only goes down, the next only up: neither pumps.
    var outgoingTrim: [Float] = []
    var incomingTrim: [Float] = []
    /// The curves of AutoMix up to 1.16 (see `TransitionPlanner.reference`), to compare with.
    var legacyCurves = false

    var overlap: Double { outEnd - outStart }
    /// The playback rates while the two play together.
    var outgoingRate: Double { tempoMeet / tempoOut }
    var incomingRate: Double { tempoMeet / tempoIn }

    func progress(atOutgoingTime time: Double) -> Double {
        guard overlap > 0 else { return time >= outStart ? 1 : 0 }
        return max(0, min(1, (time - outStart) / overlap))
    }

    /// Volumes (0…1), bass cuts (0 none … 1 all) and the outgoing song's high-pass (0 none … 1
    /// fully up) at a point of the overlap.
    func levels(at progress: Double) -> TransitionLevels {
        if let design {
            let span = max(0.001, overlap)
            return design.levels(at: progress, bar: barLength / span, ramp: 0.05 / span)
        }
        if legacyCurves { return legacyLevels(at: progress) }
        let p = max(0, min(1, progress))
        // Equal-power curves: over the same stretch the two add up to a steady loudness.
        let comeIn = fadeIn > fadeInFrom ? max(0, min(1, (p - fadeInFrom) / (fadeIn - fadeInFrom))) : (p >= fadeInFrom ? 1 : 0)
        let goOut = fadeOutFrom < 1 ? max(0, min(1, (p - fadeOutFrom) / (1 - fadeOutFrom))) : (p >= 1 ? 1 : 0)
        var swap = 0.0
        if let swapStart, let swapEnd {
            let x = swapEnd > swapStart ? max(0, min(1, (p - swapStart) / (swapEnd - swapStart))) : (p >= swapStart ? 1 : 0)
            swap = x * x * (3 - 2 * x)
        }
        var highPass = 0.0
        if let filterOut, p > filterOut {
            let x = filterOut < 1 ? (p - filterOut) / (1 - filterOut) : 1
            highPass = x * x * (3 - 2 * x)
        }
        let hasSwap = swapStart != nil && swapEnd != nil
        let outgoing = cos(goOut * .pi / 2) * Double(Self.value(of: outgoingTrim, at: p))
        let incoming = sin(comeIn * .pi / 2) * Double(Self.value(of: incomingTrim, at: p))
        return TransitionLevels(outgoing: Float(outgoing), incoming: Float(incoming),
                                outgoingBassCut: hasSwap ? Float(swap) : 0, incomingBassCut: hasSwap ? Float(1 - swap) : 0,
                                outgoingHighPass: Float(highPass))
    }

    /// The curves of up to 1.16: the next song fully in by `fadeIn` (half way in a crossfade, while
    /// the song leaving was still at 71 %: 1.76 dB louder together), and in a beat-matched mix both
    /// held at 80–90 % around the bass swap.
    private func legacyLevels(at progress: Double) -> TransitionLevels {
        let p = max(0, min(1, progress))
        let comeIn = fadeIn > 0 ? min(1, p / fadeIn) : 1
        var swap = 0.0
        if let swapStart, let swapEnd, swapEnd > swapStart {
            swap = p <= swapStart ? 0 : (p >= swapEnd ? 1 : (p - swapStart) / (swapEnd - swapStart))
        }
        var highPass = 0.0
        if let filterOut, p > filterOut {
            let x = filterOut < 1 ? (p - filterOut) / (1 - filterOut) : 1
            highPass = x * x * (3 - 2 * x)
        }
        let hasSwap = swapStart != nil && swapEnd != nil
        let incomingBassCut: Double = hasSwap ? 1 - swap : 0
        let outgoingBassCut: Double = hasSwap ? swap : 0
        guard style == .beatMatched, let swapStart, let swapEnd else {
            return TransitionLevels(outgoing: Float(cos(p * .pi / 2)), incoming: Float(sin(comeIn * .pi / 2)),
                                    outgoingBassCut: Float(outgoingBassCut), incomingBassCut: Float(incomingBassCut),
                                    outgoingHighPass: Float(highPass))
        }
        let incoming: Double = p < swapStart ? 0.8 * sin(comeIn * .pi / 2) : 0.8 + 0.2 * swap
        let outgoing: Double
        if p < swapStart {
            outgoing = 1 - 0.1 * (swapStart > 0 ? p / swapStart : 1)
        } else if p < swapEnd {
            outgoing = 0.9
        } else {
            let tail: Double = (p - swapEnd) / max(1e-6, 1 - swapEnd)
            outgoing = 0.9 * cos(tail * .pi / 2)
        }
        return TransitionLevels(outgoing: Float(outgoing), incoming: Float(incoming),
                                outgoingBassCut: Float(outgoingBassCut), incomingBassCut: Float(incomingBassCut),
                                outgoingHighPass: Float(highPass))
    }

    /// A trim at a point of the overlap (1 without one).
    static func value(of trim: [Float], at progress: Double) -> Float {
        guard trim.count > 1 else { return trim.first ?? 1 }
        let position = max(0, min(1, progress)) * Double(trim.count - 1)
        let lower = Int(position.rounded(.down)), upper = min(trim.count - 1, lower + 1)
        let weight = Float(position - Double(lower))
        return trim[lower] * (1 - weight) + trim[upper] * weight
    }
}

/// The state of a mix at one point: each song's dry volume (before effects), band cuts (0 none …
/// 1 all), filter sweeps (0 open … 1 fully closed), and the effects on the song leaving.
struct TransitionLevels: Equatable, Sendable {
    var outgoing: Float
    var incoming: Float
    var outgoingBassCut: Float
    var incomingBassCut: Float
    var outgoingHighPass: Float
    var outgoingMidCut: Float = 0
    var outgoingHighCut: Float = 0
    var incomingMidCut: Float = 0
    var incomingHighCut: Float = 0
    var outgoingLowPass: Float = 0
    var incomingLowPass: Float = 0
    var incomingHighPass: Float = 0
    /// Reverb and echo on the song leaving (0 dry … 1 full), and the noise sweep.
    var reverb: Float = 0
    var echo: Float = 0
    var noise: Float = 0
}

/// The song leaving repeats `length` seconds ending at `start` (its own time), from `start` on.
struct MixLoopPlan: Equatable, Sendable {
    var start: Double
    var length: Double
}

/// Mixes any two analysed songs. AutoMix weighs many ways of doing it against each other (see
/// `choose`, in AutoMixSelection.swift); `reference` is the single plan AutoMix made up to 1.16,
/// which a playlist's Mix still starts its timing from (so the Mixes made with it stay as they were).
enum TransitionPlanner {
    /// How far apart two tempos may be for their beats to be matched in a playlist's Mix (where
    /// beatmatching is asked for); each song changes by half of it. AutoMix keeps to much less
    /// (`AutoMixTuning.maximumRateChange`).
    static let maximumTempoChange = 0.3
    /// The longest beat-matched overlap, in seconds.
    static let longestOverlap = 48.0

    /// The transition AutoMix chooses (see `choose`).
    static func plan(from outgoing: TrackAnalysis, to incoming: TrackAnalysis,
                     context: TransitionContext = TransitionContext()) -> TransitionPlan {
        choose(from: outgoing, to: incoming, context: context).plan
    }

    /// The plan of AutoMix up to 1.16: the longest beat-matched mix that fits (16, 8 or 4 bars,
    /// both tempos meeting halfway, up to 30 % apart), otherwise a crossfade on the song's ending.
    static func reference(from outgoing: TrackAnalysis, to incoming: TrackAnalysis) -> TransitionPlan {
        var plan = beatMatched(outgoing, incoming) ?? blend(outgoing, incoming)
        plan.legacyCurves = true
        return plan
    }

    /// The next song's beat over this song's, counting half and double time: the ratio, and the
    /// octave used (2 when the next song's grid counts every other beat).
    static func tempoMatch(_ a: TrackAnalysis, _ b: TrackAnalysis) -> (ratio: Double, octave: Double)? {
        let options = [1.0, 2.0, 0.5].map { (ratio: b.beatLength / $0 / a.beatLength, octave: $0) }
        guard let best = options.min(by: { abs(log($0.ratio)) < abs(log($1.ratio)) }),
              abs(log(best.ratio)) <= log(1 + maximumTempoChange) else { return nil }
        return best
    }

    // MARK: Beat-matched

    private static func beatMatched(_ a: TrackAnalysis, _ b: TrackAnalysis) -> TransitionPlan? {
        guard a.isGridLocked, b.isGridLocked, let match = tempoMatch(a, b) else { return nil }
        let end = a.audibleEnd
        let outBeats = a.beat(atOrAfter: end - 32 * a.beatLength)..<a.beat(atOrAfter: end)
        let inBeats = b.beat(atOrAfter: b.soundStart)..<b.beat(atOrAfter: b.soundStart + 32 * b.beatLength)
        let rhythmic = a.pulse(outBeats) >= 0.45 && b.pulse(inBeats) >= 0.45
        let close = abs(log(match.ratio)) <= log(1.12) && keysCompatible(a, b)
        // Sixteen bars when both ends have a beat and the songs are close; fewer otherwise, or when
        // the song is too short for them.
        for bars in rhythmic && close ? [16, 8, 4] : [8, 4] {
            if let plan = beatMatched(a, b, bars: bars, endingBy: a.audibleEnd) { return plan }
        }
        return nil
    }

    /// A beat-matched plan of `bars` bars, the overlap ending by `end` (the song's time).
    static func beatMatched(_ a: TrackAnalysis, _ b: TrackAnalysis, bars: Int, endingBy end: Double,
                            minimumHandover: Double = 30) -> TransitionPlan? {
        guard let found = cues(a, b, bars: bars, endingBy: end) else { return nil }
        return beatMatched(a, b, bars: bars, from: found.outgoing, to: found.incoming, minimumHandover: minimumHandover)
    }

    /// Where a beat-matched mix of `bars` bars ending by `end` puts the two songs: this song's
    /// downbeat the next one comes in on (as its sound ends, at a new section when there is one
    /// nearby), and the next song's downbeat landing there (so the overlap ends where its main part
    /// starts, skipping a long intro).
    static func cues(_ a: TrackAnalysis, _ b: TrackAnalysis, bars: Int, endingBy end: Double) -> (outgoing: Int, incoming: Int)? {
        guard let octave = tempoMatch(a, b)?.octave,
              let downbeatOut = a.downbeat(startingOverlapOf: Double(bars * 4) * a.beatLength, endingBy: end)
        else { return nil }
        let first = b.firstDownbeat
        let incomingBeats = Int((Double(bars * 4) / octave).rounded())
        if let main = b.mainStart(), main - incomingBeats > first { return (downbeatOut, main - incomingBeats) }
        return (downbeatOut, first)
    }

    /// A beat-matched plan of `bars` bars, the next song's downbeat `downbeatIn` landing on this
    /// song's downbeat `downbeatOut`.
    /// The two play together at `meet` (by default halfway between their tempos, in ratio: each
    /// changes speed by as little as possible).
    static func beatMatched(_ a: TrackAnalysis, _ b: TrackAnalysis, bars: Int, from downbeatOut: Int, to downbeatIn: Int,
                            minimumHandover: Double, meet: Double? = nil) -> TransitionPlan? {
        guard let octave = tempoMatch(a, b)?.octave, downbeatIn >= b.firstDownbeat, downbeatOut > 0 else { return nil }
        let tempoOut = a.tempo
        let tempoIn = b.tempo * octave
        let tempoMeet = meet ?? (tempoOut * tempoIn).squareRoot()
        let beat = a.beatLength
        let length = Double(bars * 4) * beat
        guard length * tempoOut / tempoMeet <= longestOverlap else { return nil }
        // The next song starts where its sound does, or just before the downbeat it comes in on.
        let inStart = downbeatIn == b.firstDownbeat ? max(0, b.soundStart - 0.01) : max(0, b.beatTime(downbeatIn) - 0.05)
        // While the next song plays up to its first downbeat, this one moves on by as many of its
        // own beats (both at the meeting tempo).
        let leadOut = (b.beatTime(downbeatIn) - inStart) * tempoIn / tempoOut
        guard leadOut >= 0, leadOut < 8 * beat else { return nil }
        let alignment = a.beatTime(downbeatOut)
        let outStart = alignment - leadOut
        let outEnd = min(alignment + length, a.duration - 0.05)
        // Four bars before the next song comes in, this song starts gliding to the meeting tempo.
        let handover = outStart - 16 * beat
        guard handover >= max(minimumHandover, a.duration * (minimumHandover < 30 ? 0.2 : 0.45)),
              outEnd > outStart + 2 else { return nil }
        let overlap = outEnd - outStart
        let swapStart = (alignment + Double(bars * 2) * beat - outStart) / overlap
        let swapEnd = min(1, swapStart + beat / overlap)
        return TransitionPlan(style: .beatMatched, handover: handover, outStart: outStart, outEnd: outEnd,
                              inStart: inStart, tempoOut: tempoOut, tempoMeet: tempoMeet, tempoIn: tempoIn,
                              alignment: alignment, swapStart: swapStart, swapEnd: swapEnd, fadeIn: swapStart,
                              filterOut: 0.75, bars: bars)
    }

    /// Keys that sound well together: the same, relative major and minor, or a fifth apart
    /// (neighbours on the Camelot wheel). Unclear keys never stand in the way.
    static func keysCompatible(_ a: TrackAnalysis, _ b: TrackAnalysis) -> Bool {
        guard a.keyClarity >= 0.6, b.keyClarity >= 0.6 else { return true }
        let fifthsA = fifths(a), fifthsB = fifths(b)
        let distance = min((fifthsA - fifthsB + 12) % 12, (fifthsB - fifthsA + 12) % 12)
        return a.minor == b.minor ? distance <= 1 : distance == 0
    }

    /// Position on the circle of fifths of the key's signature (a minor key at its relative major's).
    private static func fifths(_ analysis: TrackAnalysis) -> Int {
        let major = analysis.minor ? (analysis.key + 3) % 12 : analysis.key
        return (major * 7) % 12
    }

    // MARK: Crossfades

    private static func blend(_ a: TrackAnalysis, _ b: TrackAnalysis) -> TransitionPlan {
        let end = a.soundEnd
        let inStart = max(0, b.soundStart - 0.01)
        // How long the outgoing song has been fading: back from its end to the last moment at
        // nearly full loudness.
        var fadeStart = end
        var time = end - 1
        while time >= max(a.soundStart, end - 20) {
            if a.level(at: time) >= a.bodyLoudness - 3 { break }
            fadeStart = time
            time -= TrackAnalysis.loudnessStep
        }
        let fade = end - fadeStart
        // A quiet start of the next song can come in earlier, under this one's ending.
        var softIntro = 0.0
        var probe = b.soundStart
        while probe < b.soundStart + 6, b.level(at: probe) < b.bodyLoudness - 10 {
            softIntro += TrackAnalysis.loudnessStep
            probe += TrackAnalysis.loudnessStep
        }
        let rhythmic = a.isGridLocked
            && a.pulse(a.beat(atOrAfter: end - 8 * a.beatLength)..<a.beat(atOrAfter: end)) >= 0.45

        let style: TransitionPlan.Style = fade >= 4 ? .fade : .blend
        var overlap = style == .fade ? min(12, max(6, fade)) : min(12, 8 + softIntro)
        // Short songs keep at least their first ten seconds and half.
        overlap = min(overlap, max(1, end - max(a.soundStart + 10, a.duration * 0.5)))
        var outStart = end - overlap
        var alignment: Double?
        // On a steady beat, the next song starts on a downbeat.
        if rhythmic, let downbeat = a.downbeat(startingOverlapOf: overlap, endingBy: end),
           a.beatTime(downbeat) >= max(a.soundStart + 10, a.duration * 0.5) {
            outStart = a.beatTime(downbeat)
            alignment = outStart
        }
        let tempo = a.tempo
        return TransitionPlan(style: style, handover: max(0, outStart - 0.5), outStart: outStart, outEnd: end,
                              inStart: inStart, tempoOut: tempo, tempoMeet: tempo, tempoIn: tempo,
                              alignment: alignment, swapStart: rhythmic ? 0.45 : nil, swapEnd: rhythmic ? 0.55 : nil,
                              fadeIn: style == .fade ? min(1, 3 / (end - outStart)) : 0.5,
                              filterOut: rhythmic ? 0.4 : nil, bars: nil)
    }
}

/// The mix as the renderer plays it, block by block (512 frames at 44.1 kHz): both songs' playback
/// rates, volumes and filters. The tempo glides smoothly: from the playing song's to the meeting
/// tempo before the next song comes in, then from the meeting tempo to the next song's own once the
/// first has gone. Both songs always share the tempo, so their beats stay together.
struct MixSchedule: Sendable {
    static let sampleRate = 44_100.0
    static let blockFrames = 512

    struct Step: Equatable, Sendable {
        var outgoingRate: Double
        var incomingRate: Double
        var levels: TransitionLevels
    }

    let plan: TransitionPlan
    private(set) var steps: [Step] = []
    /// Mix time (seconds) when the next song starts, and how much of its player's time has gone by
    /// then (its rate applies from the start of the mix, on silence).
    private(set) var entry = 0.0
    private(set) var incomingClockAtEntry = 0.0
    /// The next song's own time when the mix ends, where its normal playback carries on.
    private(set) var join = 0.0

    var length: Double { Double(steps.count * Self.blockFrames) / Self.sampleRate }

    init(plan: TransitionPlan) {
        self.plan = plan
        let dt = Double(Self.blockFrames) / Self.sampleRate
        // The next song takes 16 of its beats to get back to its own tempo (when it changed at all).
        let glideBack = plan.tempoMeet == plan.tempoIn ? 0 : 16 * 60 / plan.tempoIn
        let tail = plan.design.map { $0.effect != .none || $0.filter == .noiseOut ? 5.0 : 1.0 } ?? 1
        // The playing song keeps its own tempo for a second after the handover (so the mix starts
        // exactly as the song sounds), then glides.
        let glideFrom = plan.handover + 1
        let preGlide = max(1e-6, plan.outStart - glideFrom)
        var outgoing = plan.handover
        var incoming: Double?
        var incomingClock = 0.0
        var aloneFrom: Double?
        var time = 0.0
        let limit = Int(180 / dt)
        while steps.count < limit {
            let tempo: Double
            if let from = aloneFrom, let position = incoming {
                let progress = glideBack > 0 ? (position - from) / glideBack : 1
                tempo = plan.tempoMeet + (plan.tempoIn - plan.tempoMeet) * Self.smooth(progress)
            } else {
                tempo = plan.tempoOut + (plan.tempoMeet - plan.tempoOut) * Self.smooth((outgoing - glideFrom) / preGlide)
            }
            let outgoingRate = tempo / plan.tempoOut, incomingRate = tempo / plan.tempoIn
            steps.append(Step(outgoingRate: outgoingRate, incomingRate: incomingRate,
                              levels: plan.levels(at: plan.progress(atOutgoingTime: outgoing))))
            let next = outgoing + outgoingRate * dt
            if let position = incoming {
                incoming = position + incomingRate * dt
            } else if next >= plan.outStart {
                // The next song starts inside this block, exactly when this one reaches `outStart`.
                let fraction = max(0, min(1, (plan.outStart - outgoing) / (outgoingRate * dt)))
                entry = time + fraction * dt
                incomingClockAtEntry = incomingClock + fraction * incomingRate * dt
                incoming = plan.inStart + (1 - fraction) * incomingRate * dt
            }
            incomingClock += incomingRate * dt
            outgoing = next
            time += dt
            if aloneFrom == nil, outgoing >= plan.outEnd, let position = incoming { aloneFrom = position }
            // The mix ends a second after the new song is back at its own tempo (later with an
            // effect, whose tail must die out inside the mix).
            if let from = aloneFrom, let position = incoming, position - from >= glideBack + tail {
                join = position
                break
            }
        }
    }

    /// The step in force at a mix time (the last one past the end).
    func step(at time: Double) -> Step {
        let index = Int(time * Self.sampleRate) / Self.blockFrames
        return steps[max(0, min(steps.count - 1, index))]
    }

    /// Where each song is at a mix time: the outgoing song's time, and the next song's (nil before it starts).
    func positions(at time: Double) -> (outgoing: Double, incoming: Double?) {
        let dt = Double(Self.blockFrames) / Self.sampleRate
        var outgoing = plan.handover
        var incoming: Double?
        var clock = 0.0
        for step in steps {
            let span = min(dt, time - clock)
            guard span > 0 else { break }
            if let position = incoming {
                incoming = position + step.incomingRate * span
            } else if clock + span >= entry {
                let before = max(0, entry - clock)
                incoming = plan.inStart + step.incomingRate * (span - before)
            }
            outgoing += step.outgoingRate * span
            clock += span
        }
        return (outgoing, incoming)
    }

    private static func smooth(_ x: Double) -> Double {
        let t = max(0, min(1, x))
        return t * t * (3 - 2 * t)
    }
}

extension TrackAnalysis {
    /// Where the song is still clearly audible: the end of its sound, or the deep part of its fade-out.
    var audibleEnd: Double {
        let threshold = bodyLoudness - 15
        guard let last = loudness.lastIndex(where: { $0 >= threshold }) else { return soundEnd }
        return max(soundStart + 1, min(soundEnd, Double(last + 1) * TrackAnalysis.loudnessStep))
    }

    /// The first downbeat at the start of the sound.
    var firstDownbeat: Int {
        var beat = max(0, self.beat(atOrAfter: soundStart - 0.05 * beatLength))
        while !isDownbeat(beat) { beat += 1 }
        return beat
    }

    /// Mean loudness (dB) of `count` beats from `start`; nil outside the song.
    func meanLoudness(_ start: Int, _ count: Int) -> Float? {
        let range = (start..<(start + count)).clamped(to: 0..<beatLoudness.count)
        guard !range.isEmpty else { return nil }
        return beatLoudness[range].reduce(0, +) / Float(range.count)
    }

    /// The downbeat where the main part starts after an intro: a jump in loudness on a four-bar
    /// boundary within the first 90 seconds. Nil when the song starts in full.
    func mainStart() -> Int? {
        var beat = firstDownbeat + 16
        while beatTime(beat) < soundStart + 90, beat + 16 <= beatCount {
            if let before = meanLoudness(beat - 16, 16), let after = meanLoudness(beat, 16),
               after >= bodyLoudness - 2, after - before >= 2 {
                return beat
            }
            beat += 16
        }
        return nil
    }

    /// The downbeat an overlap of `length` seconds should start on to end by `end`: the latest one,
    /// or, within the four bars before it, one where the loudness changes clearly more (a new section).
    func downbeat(startingOverlapOf length: Double, endingBy end: Double) -> Int? {
        let latestTime = end + 0.5 * beatLength - length
        var latest = beat(atOrAfter: latestTime)
        while latest > 0, beatTime(latest) > latestTime || !isDownbeat(latest) { latest -= 1 }
        guard latest > 0 else { return nil }
        func change(_ beat: Int) -> Float {
            guard let before = meanLoudness(beat - 8, 8), let after = meanLoudness(beat, 8) else { return 0 }
            return abs(after - before)
        }
        var best = latest
        var bestChange = change(latest)
        for candidate in stride(from: latest - 4, through: max(1, latest - 16), by: -4) {
            let value = change(candidate)
            if value > bestChange + 1.5 {
                best = candidate
                bestChange = value
            }
        }
        return best
    }
}
