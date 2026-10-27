import Foundation

/// How AutoMix takes one song into the next, in the outgoing song's time.
struct TransitionPlan: Equatable, Sendable {
    enum Style: String, Sendable {
        /// Beats matched like a DJ: both songs change tempo to meet halfway, the next one comes in on
        /// a downbeat (skipping a long intro), they play together for several bars and the bass
        /// passes from one to the other.
        case beatMatched
        /// Two steady beats too far apart in tempo: this song thins out (bass cut, rising high-pass)
        /// while the next one comes in on one of its downbeats, like a DJ cutting on the one.
        case drop
        /// No steady beat to follow: a crossfade on the song's ending, filtered when this song has a beat.
        case blend
        /// The song fades out on its own: the next one comes in during the fade.
        case fade
    }

    var style: Style
    /// Outgoing song's time when the next song starts, and when it has faded out.
    var outStart: Double
    var outEnd: Double
    /// Where the next song starts, and its playback rate while the two play together; it goes back
    /// to its own tempo afterwards.
    var inStart: Double
    var rate: Double
    /// The outgoing song's rate while the two play together (reached before the next song starts).
    var outgoingRate: Double
    /// The outgoing song's downbeat the next song's first downbeat lands on.
    var alignment: Double?
    /// Progress (0…1) at which the bass starts and ends passing from one song to the other; nil
    /// when it doesn't.
    var swapStart: Double?
    var swapEnd: Double?
    /// Progress at which the next song has come in.
    var fadeIn: Double
    /// Progress from which a high-pass filter sweeps up through the outgoing song; nil for none.
    var filterOut: Double?
    /// Beat-matched: how many of the outgoing song's bars the two play together.
    var bars: Int?

    var overlap: Double { outEnd - outStart }

    func progress(atOutgoingTime time: Double) -> Double {
        guard overlap > 0 else { return time >= outStart ? 1 : 0 }
        return max(0, min(1, (time - outStart) / overlap))
    }

    /// Volumes (0…1), bass cuts (0 none … 1 all) and the outgoing song's high-pass (0 none … 1
    /// fully up) at a point of the transition.
    func levels(at progress: Double) -> TransitionLevels {
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
            // Equal-power crossfade: the overall loudness stays steady.
            let outgoing: Double = cos(p * .pi / 2)
            let incoming: Double = sin(comeIn * .pi / 2)
            return TransitionLevels(outgoing: Float(outgoing), incoming: Float(incoming),
                                    outgoingBassCut: Float(outgoingBassCut), incomingBassCut: Float(incomingBassCut),
                                    outgoingHighPass: Float(highPass))
        }
        // Before the swap the next song plays a little lower and without bass over this one;
        // after it, this one plays on without bass, thins out and fades.
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
}

struct TransitionLevels: Equatable, Sendable {
    var outgoing: Float
    var incoming: Float
    var outgoingBassCut: Float
    var incomingBassCut: Float
    var outgoingHighPass: Float
}

/// Mixes any two analysed songs, the way Apple Music's AutoMix does: matched beats when both are
/// made to a steady grid (both tempos meeting halfway, up to 20 % apart), a cut on the one when
/// their tempos are further apart, otherwise a crossfade on the song's ending.
enum TransitionPlanner {
    /// How far apart two tempos may be for their beats to be matched; each song changes by half of it.
    static let maximumTempoChange = 0.2
    /// The longest beat-matched overlap, in seconds.
    static let longestOverlap = 48.0

    static func plan(from outgoing: TrackAnalysis, to incoming: TrackAnalysis) -> TransitionPlan {
        if let matched = beatMatched(outgoing, incoming) { return matched }
        if let dropped = drop(outgoing, incoming) { return dropped }
        return blend(outgoing, incoming)
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
        // The two meet halfway: the next song slows down or speeds up by as much as this one.
        let incomingRate = match.ratio.squareRoot()
        let end = a.audibleEnd
        let outBeats = a.beat(atOrAfter: end - 32 * a.beatLength)..<a.beat(atOrAfter: end)
        let inBeats = b.beat(atOrAfter: b.soundStart)..<b.beat(atOrAfter: b.soundStart + 32 * b.beatLength)
        let rhythmic = a.pulse(outBeats) >= 0.45 && b.pulse(inBeats) >= 0.45
        let close = abs(log(match.ratio)) <= log(1.12) && keysCompatible(a, b)
        // Sixteen bars when both ends have a beat and the songs are close; fewer otherwise, or when
        // the song is too short for them.
        for bars in rhythmic && close ? [16, 8, 4] : [8, 4] {
            if let plan = beatMatched(a, b, bars: bars, octave: match.octave, incomingRate: incomingRate) {
                return plan
            }
        }
        return nil
    }

    private static func beatMatched(_ a: TrackAnalysis, _ b: TrackAnalysis, bars: Int, octave: Double,
                                    incomingRate: Double) -> TransitionPlan? {
        let outgoingRate = 1 / incomingRate
        let beat = a.beatLength
        let length = Double(bars * 4) * beat
        guard length / outgoingRate <= longestOverlap else { return nil }
        // The next song: the overlap ends where its main part starts, so a long intro is skipped.
        let first = b.firstDownbeat
        let incomingBeats = Int((Double(bars * 4) / octave).rounded())
        var downbeatIn = first
        var inStart = max(0, b.soundStart - 0.01)
        if let main = b.mainStart(), main - incomingBeats > first {
            downbeatIn = main - incomingBeats
            inStart = max(0, b.beatTime(downbeatIn) - 0.05)
        }
        let lead = (b.beatTime(downbeatIn) - inStart) / incomingRate
        // This song: the overlap ends as its sound does, starting on a downbeat (at a new section
        // when there is one nearby).
        guard lead >= 0, lead < 8 * beat,
              let downbeatOut = a.downbeat(startingOverlapOf: length, endingBy: a.audibleEnd) else { return nil }
        let alignment = a.beatTime(downbeatOut)
        let outStart = alignment - lead * outgoingRate
        let outEnd = min(alignment + length, a.duration - 0.05)
        guard outStart >= max(30, a.duration * 0.5), outEnd > outStart + 2 else { return nil }
        let overlap = outEnd - outStart
        let swapStart = (alignment + Double(bars * 2) * beat - outStart) / overlap
        let swapEnd = min(1, swapStart + beat / overlap)
        return TransitionPlan(style: .beatMatched, outStart: outStart, outEnd: outEnd, inStart: inStart,
                              rate: incomingRate, outgoingRate: outgoingRate, alignment: alignment,
                              swapStart: swapStart, swapEnd: swapEnd, fadeIn: swapStart, filterOut: 0.75, bars: bars)
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

    // MARK: Cut on the one

    private static func drop(_ a: TrackAnalysis, _ b: TrackAnalysis) -> TransitionPlan? {
        guard a.isGridLocked, b.isGridLocked else { return nil }
        let beat = a.beatLength
        // Straight into the next song's main part (a bar before it), or from its start.
        let first = b.firstDownbeat
        var downbeatIn = first
        var inStart = max(0, b.soundStart - 0.01)
        if let main = b.mainStart(), main - 4 > first {
            downbeatIn = main - 4
            inStart = max(0, b.beatTime(downbeatIn) - 0.05)
        }
        let lead = b.beatTime(downbeatIn) - inStart
        let length = 4 * beat
        guard lead < 4 * b.beatLength,
              let downbeatOut = a.downbeat(startingOverlapOf: length, endingBy: a.audibleEnd) else { return nil }
        let alignment = a.beatTime(downbeatOut)
        let outStart = alignment - lead
        let outEnd = min(alignment + length, a.duration - 0.05)
        guard outStart >= max(20, a.duration * 0.5), outEnd > outStart + 1 else { return nil }
        let overlap = outEnd - outStart
        let landing = (alignment - outStart) / overlap
        let swapStart = (alignment + 2 * beat - outStart) / overlap
        return TransitionPlan(style: .drop, outStart: outStart, outEnd: outEnd, inStart: inStart, rate: 1,
                              outgoingRate: 1, alignment: alignment, swapStart: swapStart,
                              swapEnd: min(1, swapStart + beat / overlap), fadeIn: max(0.15, landing),
                              filterOut: 0, bars: 1)
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
        var overlap = style == .fade ? min(12, max(5, fade)) : min(10, 6 + softIntro)
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
        return TransitionPlan(style: style, outStart: outStart, outEnd: end, inStart: inStart, rate: 1,
                              outgoingRate: 1, alignment: alignment,
                              swapStart: rhythmic ? 0.45 : nil, swapEnd: rhythmic ? 0.55 : nil,
                              fadeIn: style == .fade ? min(1, 3 / (end - outStart)) : 0.5,
                              filterOut: rhythmic ? 0.4 : nil, bars: nil)
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
