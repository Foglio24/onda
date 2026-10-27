import Foundation

/// How AutoMix takes one song into the next, in the outgoing song's time.
struct TransitionPlan: Equatable, Sendable {
    enum Style: String, Sendable {
        /// Beats matched like a DJ: the next song starts on a downbeat at the tempo of this one,
        /// they play together for a few bars and the bass passes from one to the other.
        case beatMatched
        /// A blend without matching beats, when one of the two has no beat at that point, or their
        /// tempos are too far apart: shorter, and with the bass passed over halfway when both have one.
        case blend
        /// The song fades out on its own: the next one comes in during the fade.
        case fade
        /// The song ends on its own: the next one starts as it ends, the silence in between left out.
        case cut
    }

    var style: Style
    /// Outgoing song's time when the next song starts, and when it has faded out.
    var outStart: Double
    var outEnd: Double
    /// Where the next song starts, and its playback rate while the two play together (1 unless
    /// beat-matched); it goes back to its own tempo afterwards.
    var inStart: Double
    var rate: Double
    /// Beat-matched: the outgoing song's downbeat the next song's first downbeat lands on.
    var alignment: Double?
    /// Progress (0…1) at which the bass starts and ends passing from one song to the other; nil
    /// when it doesn't.
    var swapStart: Double?
    var swapEnd: Double?
    /// Progress at which the next song has come in.
    var fadeIn: Double

    var overlap: Double { outEnd - outStart }

    func progress(atOutgoingTime time: Double) -> Double {
        guard overlap > 0 else { return time >= outStart ? 1 : 0 }
        return max(0, min(1, (time - outStart) / overlap))
    }

    /// Volumes (0…1) and bass cuts (0 none … 1 all) of both songs at a point of the transition.
    func levels(at progress: Double) -> TransitionLevels {
        let p = max(0, min(1, progress))
        let comeIn = fadeIn > 0 ? min(1, p / fadeIn) : 1
        guard let swapStart, let swapEnd, swapEnd > swapStart else {
            // Equal-power crossfade: the overall loudness stays steady.
            return TransitionLevels(outgoing: Float(cos(p * .pi / 2)), incoming: Float(sin(comeIn * .pi / 2)),
                                    outgoingBassCut: 0, incomingBassCut: 0)
        }
        let swap = p <= swapStart ? 0 : p >= swapEnd ? 1 : (p - swapStart) / (swapEnd - swapStart)
        if style == .beatMatched {
            // Before the swap the next song plays a little lower and without bass over this one;
            // after it, this one plays on without bass and fades out.
            let incoming = p < swapStart ? 0.8 * sin(comeIn * .pi / 2) : 0.8 + 0.2 * swap
            let outgoing: Double
            if p < swapStart {
                outgoing = 1 - 0.1 * (swapStart > 0 ? p / swapStart : 1)
            } else if p < swapEnd {
                outgoing = 0.9
            } else {
                outgoing = 0.9 * cos((p - swapEnd) / max(1e-6, 1 - swapEnd) * .pi / 2)
            }
            return TransitionLevels(outgoing: Float(outgoing), incoming: Float(incoming),
                                    outgoingBassCut: Float(swap), incomingBassCut: Float(1 - swap))
        }
        return TransitionLevels(outgoing: Float(cos(p * .pi / 2)), incoming: Float(sin(comeIn * .pi / 2)),
                                outgoingBassCut: Float(swap), incomingBassCut: Float(1 - swap))
    }
}

struct TransitionLevels: Equatable, Sendable {
    var outgoing: Float
    var incoming: Float
    var outgoingBassCut: Float
    var incomingBassCut: Float
}

/// Picks the transition between two analysed songs, the way Apple Music's AutoMix does: matched
/// beats when both are made to a steady grid at close tempos, otherwise a crossfade that leaves out
/// the silence and follows the songs' own fades. Songs of the same album play as they are.
enum TransitionPlanner {
    /// How much the next song's tempo may change to match (DJs stay within about 6 %).
    static let maximumRateChange = 0.06
    /// The longest beat-matched overlap.
    static let longestOverlap = 24.0

    static func plan(from outgoing: TrackAnalysis, to incoming: TrackAnalysis, sameAlbum: Bool) -> TransitionPlan? {
        guard !sameAlbum else { return nil }
        if let matched = beatMatched(outgoing, incoming) { return matched }
        return crossfade(outgoing, incoming)
    }

    // MARK: Beat-matched

    private static func beatMatched(_ a: TrackAnalysis, _ b: TrackAnalysis) -> TransitionPlan? {
        guard a.isGridLocked, b.isGridLocked, let rate = matchingRate(a, b) else { return nil }
        let beat = a.beatLength
        // Beats right where the two would play together: otherwise matching them is pointless.
        let outBeats = a.beat(atOrAfter: a.soundEnd - 32 * beat)..<a.beat(atOrAfter: a.soundEnd)
        let inFirst = b.beat(atOrAfter: b.soundStart)
        let inBeats = inFirst..<(inFirst + Int((32 * beat * rate / b.beatLength).rounded()))
        guard a.pulse(outBeats) >= 0.45, b.pulse(inBeats) >= 0.45 else { return nil }

        // Eight bars when both ends are made for it, four otherwise.
        var bars = 8
        if a.tempo < 95 || !keysCompatible(a, b) { bars = 4 }
        while bars > 2, Double(bars * 4) * beat > longestOverlap { bars /= 2 }
        let length = Double(bars * 4) * beat

        // The next song starts where its sound starts and reaches its first downbeat on one of
        // this song's downbeats, the overlap ending as this song's sound ends.
        var downbeatIn = max(0, b.beat(atOrAfter: b.soundStart - 0.05 * b.beatLength))
        while !b.isDownbeat(downbeatIn) { downbeatIn += 1 }
        let inStart = max(0, b.soundStart - 0.01)
        let lead = (b.beatTime(downbeatIn) - inStart) / rate
        guard lead >= 0, lead < 8 * beat else { return nil }
        var downbeatOut = a.beat(atOrAfter: a.soundEnd + 0.25 * beat - length) - 1
        while downbeatOut > 0, !a.isDownbeat(downbeatOut) || a.beatTime(downbeatOut) + length > a.soundEnd + 0.25 * beat {
            downbeatOut -= 1
        }
        let alignment = a.beatTime(downbeatOut)
        let outStart = alignment - lead
        let outEnd = min(alignment + length, a.duration - 0.05)
        // Never cut more than the last third of a song.
        guard downbeatOut > 0, outStart >= max(20, a.duration * 0.6), outEnd > outStart + 2 else { return nil }
        let overlap = outEnd - outStart
        let swapStart = (alignment + Double(bars * 2) * beat - outStart) / overlap
        let swapEnd = min(1, swapStart + beat / overlap)
        return TransitionPlan(style: .beatMatched, outStart: outStart, outEnd: outEnd, inStart: inStart, rate: rate,
                              alignment: alignment, swapStart: swapStart, swapEnd: swapEnd, fadeIn: swapStart)
    }

    /// The rate that brings the next song to this one's tempo (counting half and double time),
    /// when it is close enough.
    static func matchingRate(_ a: TrackAnalysis, _ b: TrackAnalysis) -> Double? {
        let rates = [1.0, 2.0, 0.5].map { b.beatLength / $0 / a.beatLength }
        guard let rate = rates.min(by: { abs(log($0)) < abs(log($1)) }),
              abs(rate - 1) <= maximumRateChange else { return nil }
        return rate
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

    private static func crossfade(_ a: TrackAnalysis, _ b: TrackAnalysis) -> TransitionPlan? {
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
        // A quiet start of the next song can come in early, under this one's ending.
        var softIntro = 0.0
        var probe = b.soundStart
        while probe < b.soundStart + 6, b.level(at: probe) < b.bodyLoudness - 10 {
            softIntro += TrackAnalysis.loudnessStep
            probe += TrackAnalysis.loudnessStep
        }
        let bothRhythmic = a.pulse(a.beat(atOrAfter: end - 8 * a.beatLength)..<a.beat(atOrAfter: end)) >= 0.45
            && b.pulse(b.beat(atOrAfter: b.soundStart)..<b.beat(atOrAfter: b.soundStart + 8 * b.beatLength)) >= 0.45

        let plan: TransitionPlan
        if fade >= 4 {
            let overlap = min(10, max(3, fade * 0.7))
            plan = TransitionPlan(style: .fade, outStart: end - overlap, outEnd: end, inStart: inStart, rate: 1,
                                  alignment: nil, swapStart: nil, swapEnd: nil, fadeIn: min(1, 2.5 / overlap))
        } else if bothRhythmic {
            // Two beats that don't match: quick, the bass passed over halfway.
            let overlap = 2.5
            plan = TransitionPlan(style: .blend, outStart: end - overlap, outEnd: end, inStart: inStart, rate: 1,
                                  alignment: nil, swapStart: 0.45, swapEnd: 0.55, fadeIn: 0.5)
        } else if softIntro >= 1.5 {
            let overlap = min(4, softIntro)
            plan = TransitionPlan(style: .blend, outStart: end - overlap, outEnd: end, inStart: inStart, rate: 1,
                                  alignment: nil, swapStart: nil, swapEnd: nil, fadeIn: 1)
        } else {
            // The song ends: the next one starts right away, without the silence in between.
            let outEnd = min(a.duration, end + 0.2)
            plan = TransitionPlan(style: .cut, outStart: end - 0.3, outEnd: outEnd, inStart: inStart, rate: 1,
                                  alignment: nil, swapStart: nil, swapEnd: nil, fadeIn: 0.4)
        }
        guard plan.outStart >= max(10, a.soundStart + 10) else { return nil }
        return plan
    }
}
