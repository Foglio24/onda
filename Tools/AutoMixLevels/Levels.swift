// How loud an AutoMix mix is against the songs it is made of, measured on the rendered audio:
// shared by Tools/AutoMixLevels (songs made here) and Tools/AutoMixRealMusic (real songs).
//
// Everything is compared with the same stretch of the songs as normal playback plays it, at the
// same gains ("Volume uniforme"): where the mix takes over and hands back, through the overlap
// (each song alone, at the point of it heard there), in the bass, at the peaks, and against what
// the planner expected (`TransitionJudge.loudness(of:)`).
import AVFoundation
import Foundation

/// Stereo audio at `rate`.
struct Stereo {
    var left: [Float]
    var right: [Float]
    let rate: Double

    var count: Int { left.count }

    static func read(_ url: URL) throws -> Stereo {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { throw CocoaError(.fileReadUnknown) }
        try file.read(into: buffer)
        return Stereo(buffer)
    }

    init(left: [Float], right: [Float], rate: Double) {
        self.left = left
        self.right = right
        self.rate = rate
    }

    init(_ buffer: AVAudioPCMBuffer) {
        let count = Int(buffer.frameLength)
        let channels = buffer.floatChannelData!
        left = Array(UnsafeBufferPointer(start: channels[0], count: count))
        right = buffer.format.channelCount > 1 ? Array(UnsafeBufferPointer(start: channels[1], count: count)) : left
        rate = buffer.format.sampleRate
    }

    /// A stretch of a song as normal playback plays it (`AutoMixRenderer.decode`), times `gain`.
    static func decode(_ url: URL, from start: Double, duration: Double, gain: Float) async throws -> Stereo {
        var song = Stereo(try await AutoMixRenderer.decode(url, from: max(0, start), duration: duration))
        if start < 0 {
            let silence = [Float](repeating: 0, count: Int(-start * song.rate))
            song.left = silence + song.left
            song.right = silence + song.right
        }
        if gain != 1 {
            song.left = song.left.map { $0 * gain }
            song.right = song.right.map { $0 * gain }
        }
        return song
    }

    func filtered(_ sections: [LevelFilter]) -> Stereo {
        Stereo(left: LevelFilter.run(sections, left), right: LevelFilter.run(sections, right), rate: rate)
    }

    /// Through the app's equalizer at these six gains (dB), as playback runs it on every song and
    /// on the mix alike (see `Equalizer`): the preamp, then the six sections.
    func equalized(_ gains: [Float]) -> Stereo {
        var vector = SIMD8<Float>()
        for (band, gain) in gains.prefix(EqualizerBands.count).enumerated() { vector[band] = gain }
        let preamp = EqualizerDesign.preamp(vector)
        let sections = (0..<EqualizerBands.count).map { band -> LevelFilter in
            let section = EqualizerDesign.section(band: band, gain: vector[band], sampleRate: rate)
            return LevelFilter(b0: section.b0, b1: section.b1, b2: section.b2, a1: section.a1, a2: section.a2)
        }
        return Stereo(left: LevelFilter.run(sections, left.map { $0 * preamp }),
                      right: LevelFilter.run(sections, right.map { $0 * preamp }), rate: rate)
    }

    /// Mean power over both channels between two times (seconds), as dB.
    func level(from start: Double, to end: Double) -> Double {
        let first = max(0, Int(start * rate)), last = min(count, Int(end * rate))
        guard last > first else { return -120 }
        var power = 0.0
        for index in first..<last {
            power += Double(left[index] * left[index]) + Double(right[index] * right[index])
        }
        return 10 * log10(power / Double(2 * (last - first)) + 1e-12)
    }

    /// How many frames later `other` is than `reference` (within 50 ms), where they match best
    /// over half a second around `time`.
    static func lag(of other: Stereo, behind reference: Stereo, around time: Double) -> Int {
        let range = Int(0.05 * reference.rate), span = Int(0.5 * reference.rate)
        let start = max(range, Int(time * reference.rate) - span / 2)
        guard start + span + range < min(reference.count, other.count) else { return 0 }
        var best = (lag: 0, score: -Double.infinity)
        for lag in -range...range {
            var dot = 0.0, energy = 0.0
            for index in start..<(start + span) {
                let x = Double(reference.left[index]), y = Double(other.left[index + lag])
                dot += x * y
                energy += y * y
            }
            let score = dot / (energy.squareRoot() + 1e-12)
            if score > best.score { best = (lag, score) }
        }
        return best.lag
    }

    func peak(from start: Double, to end: Double) -> Float {
        let first = max(0, Int(start * rate)), last = min(count, Int(end * rate))
        guard last > first else { return 0 }
        var peak: Float = 0
        for index in first..<last { peak = max(peak, abs(left[index]), abs(right[index])) }
        return peak
    }
}

/// A second-order filter section (RBJ's cookbook; ITU-R BS.1770's K-weighting), run in direct form I.
struct LevelFilter {
    var b0, b1, b2, a1, a2: Double

    private static func normalized(_ b: (Double, Double, Double), _ a: (Double, Double, Double)) -> LevelFilter {
        LevelFilter(b0: b.0 / a.0, b1: b.1 / a.0, b2: b.2 / a.0, a1: a.1 / a.0, a2: a.2 / a.0)
    }

    static func lowPass(_ frequency: Double, q: Double, rate: Double) -> LevelFilter {
        let w = 2 * Double.pi * frequency / rate, alpha = sin(w) / (2 * q), c = cos(w)
        return normalized(((1 - c) / 2, 1 - c, (1 - c) / 2), (1 + alpha, -2 * c, 1 - alpha))
    }

    static func highPass(_ frequency: Double, q: Double, rate: Double) -> LevelFilter {
        let w = 2 * Double.pi * frequency / rate, alpha = sin(w) / (2 * q), c = cos(w)
        return normalized(((1 + c) / 2, -(1 + c), (1 + c) / 2), (1 + alpha, -2 * c, 1 - alpha))
    }

    static func highShelf(_ frequency: Double, gain: Double, q: Double, rate: Double) -> LevelFilter {
        let a = pow(10, gain / 40), w = 2 * Double.pi * frequency / rate, alpha = sin(w) / (2 * q), c = cos(w)
        let root = 2 * a.squareRoot() * alpha
        return normalized((a * ((a + 1) + (a - 1) * c + root), -2 * a * ((a - 1) + (a + 1) * c), a * ((a + 1) + (a - 1) * c - root)),
                          ((a + 1) - (a - 1) * c + root, 2 * ((a - 1) - (a + 1) * c), (a + 1) - (a - 1) * c - root))
    }

    /// K-weighting (BS.1770): the head's high shelf, then the low cut.
    static func kWeighting(rate: Double) -> [LevelFilter] {
        [highShelf(1_681.974450955533, gain: 3.999843853973347, q: 0.7071752369554196, rate: rate),
         highPass(38.13547087602444, q: 0.5003270373238773, rate: rate)]
    }

    /// Below 150 Hz (the kick drum and the bass, as the analysis counts them): 4th-order Butterworth.
    static func bass(rate: Double) -> [LevelFilter] {
        [lowPass(150, q: 0.541_196_1, rate: rate), lowPass(150, q: 1.306_563, rate: rate)]
    }

    static func run(_ sections: [LevelFilter], _ input: [Float]) -> [Float] {
        var signal = input
        for section in sections {
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for index in signal.indices {
                let x = Double(signal[index])
                let y = section.b0 * x + section.b1 * x1 + section.b2 * x2 - section.a1 * y1 - section.a2 * y2
                x2 = x1
                x1 = x
                y2 = y1
                y1 = y
                signal[index] = Float(y)
            }
        }
        return signal
    }
}

/// What a rendered mix does to the level, against normal playback of the same songs.
struct MixLevels {
    /// The mix's first and last second against the same second of the songs (dB, K-weighted).
    var takeOver = 0.0
    var handBack = 0.0
    /// Through the overlap, every 0.1 s over 0.4 s (momentary loudness, K-weighted): how much louder
    /// than the louder song alone it gets at most, and how much quieter at most.
    var rise = 0.0
    var dip = 0.0
    /// The same against what the volume curves alone would give (each song's level at its curve,
    /// no filters, no trims): what the filters and the trims add.
    var riseOverCurves = 0.0
    var dipUnderCurves = 0.0
    /// The bass (below 150 Hz) against the bassier song alone, at most up and down, through the
    /// overlap and where the bass passes from one song to the other.
    var bassRise = 0.0
    var bassDip = 0.0
    var swapBassRise: Double?
    var swapBassDip: Double?
    /// Where the bass passes over: how far it drops under the lower of the bass just before and
    /// just after (a hole), and how far it goes over the higher (a pile-up).
    var swapHole: Double?
    var swapPileUp: Double?
    /// The planner's expectation (loudness against the louder song alone) against the same
    /// measured, through the overlap: the median and the largest difference (dB).
    var predictionError = 0.0
    var predictionWorst = 0.0
    /// Peak (dBFS) and the limiter: how much it took off at most (dB, over 50 ms), for how long
    /// more than half a dB, and at most within two seconds of either end.
    var peak = 0.0
    var limiterMost = 0.0
    var limiterSeconds = 0.0
    var limiterAtEnds = 0.0

    var summary: String {
        func f(_ value: Double, _ digits: Int = 1) -> String { String(format: "%+.\(digits)f", value) }
        var parts = ["takes over \(f(takeOver, 2)), hands back \(f(handBack, 2)) dB",
                     "overlap \(f(rise)) / \(f(dip)) dB against the louder song alone (\(f(riseOverCurves)) / \(f(dipUnderCurves)) against the curves alone)",
                     "bass \(f(bassRise)) / \(f(bassDip)) dB"]
        if let up = swapBassRise, let down = swapBassDip { parts.append("in the bass swap \(f(up)) / \(f(down)) dB") }
        if let hole = swapHole, let pile = swapPileUp {
            parts.append("against the bass before and after it \(f(pile)) / \(f(hole)) dB")
        }
        parts.append("planner off by \(String(format: "%.1f", predictionError)) dB (median), \(String(format: "%.1f", predictionWorst)) at most")
        parts.append("peak \(String(format: "%.1f", peak)) dBFS, limiter \(String(format: "%.1f", limiterMost)) dB at most, "
                     + "\(String(format: "%.1f", limiterSeconds)) s over 0.5 dB, \(String(format: "%.2f", limiterAtEnds)) dB near the ends")
        return parts.joined(separator: "; ")
    }

    /// Measures `mix` (rendered from `schedule` at `gains`), and `unlimited`, the same rendered
    /// without the limiter, against the two songs' files.
    /// With `equalizer` (six gains), the songs and the mix are heard through the app's equalizer.
    static func measure(_ heardMix: Stereo, unlimited: Stereo?, schedule: MixSchedule, join: Double,
                        outgoing: URL, incoming: URL, gains: (Float, Float), judge: TransitionJudge,
                        equalizer: [Float]? = nil) async throws -> MixLevels {
        let plan = schedule.plan
        let rate = heardMix.rate
        let length = Double(heardMix.count) / rate
        // Normal playback of each song over the stretch the mix covers (with a second either side).
        let firstOut = plan.handover - 1, firstIn = plan.inStart - 1
        let lastOut = schedule.positions(at: length).outgoing + 1
        var songA = try await Stereo.decode(outgoing, from: firstOut, duration: lastOut - firstOut, gain: gains.0)
        var songB = try await Stereo.decode(incoming, from: firstIn, duration: join - firstIn + 1, gain: gains.1)
        var mix = heardMix
        if let equalizer {
            songA = songA.equalized(equalizer)
            songB = songB.equalized(equalizer)
            mix = mix.equalized(equalizer)
        }
        let kWeights = LevelFilter.kWeighting(rate: rate), bassBand = LevelFilter.bass(rate: rate)
        let mixK = mix.filtered(kWeights), aK = songA.filtered(kWeights), bK = songB.filtered(kWeights)
        let mixBass = mix.filtered(bassBand), aBass = songA.filtered(bassBand), bBass = songB.filtered(bassBand)
        var levels = MixLevels()

        levels.takeOver = mixK.level(from: 0, to: 1) - aK.level(from: plan.handover - firstOut, to: plan.handover - firstOut + 1)
        levels.handBack = mixK.level(from: length - 1, to: length) - bK.level(from: join - 1 - firstIn, to: join - firstIn)

        // Through the overlap.
        var rises: [Double] = [], dips: [Double] = [], overCurves: [Double] = [], bassChanges: [(Double, Bool)] = []
        var bassLevels: [(level: Double, swapping: Bool)] = []
        var errors: [Double] = []
        let predicted = judge.loudness(of: plan)
        let window = 0.4
        var time = schedule.entry
        while time + window <= length {
            let centre = time + window / 2
            let position = schedule.positions(at: centre)
            guard let incomingTime = position.incoming, position.outgoing <= plan.outEnd else { break }
            let p = plan.progress(atOutgoingTime: position.outgoing)
            let curves = plan.levels(at: p)
            let a0 = position.outgoing - firstOut - window / 2, b0 = incomingTime - firstIn - window / 2
            let heard = mixK.level(from: time, to: time + window)
            let aloneA = aK.level(from: a0, to: a0 + window), aloneB = bK.level(from: b0, to: b0 + window)
            let louder = max(aloneA, aloneB)
            rises.append(heard - louder)
            dips.append(heard - louder)
            let o = Double(curves.outgoing), i = Double(curves.incoming)
            let expected = 10 * log10(o * o * pow(10, aloneA / 10) + i * i * pow(10, aloneB / 10) + 1e-12)
            overCurves.append(heard - expected)
            let bassHeard = mixBass.level(from: time, to: time + window)
            let bassLouder = max(aBass.level(from: a0, to: a0 + window), bBass.level(from: b0, to: b0 + window))
            // Passing from one to the other: both basses partly cut.
            let swapping = min(curves.outgoingBassCut, curves.incomingBassCut) > 0.02
                && max(curves.outgoingBassCut, curves.incomingBassCut) < 0.98
            if bassLouder > -60 { bassChanges.append((bassHeard - bassLouder, swapping)) }
            bassLevels.append((bassHeard, swapping))
            // The planner's figures are loudness as heard (K-weighted), a second at a time, against
            // the louder alone.
            if let nearest = predicted.min(by: { abs($0.progress - p) < abs($1.progress - p) }), p > 0.02, p < 0.98 {
                let second = 1.0
                let m0 = centre - second / 2, a1 = position.outgoing - firstOut - second / 2, b1 = incomingTime - firstIn - second / 2
                let measured = mixK.level(from: m0, to: m0 + second)
                    - max(aK.level(from: a1, to: a1 + second), bK.level(from: b1, to: b1 + second))
                errors.append(abs((nearest.together - nearest.louder) - measured))
            }
            time += 0.1
        }
        levels.rise = rises.max() ?? 0
        levels.dip = dips.min() ?? 0
        levels.riseOverCurves = overCurves.max() ?? 0
        levels.dipUnderCurves = overCurves.min() ?? 0
        levels.bassRise = bassChanges.map { $0.0 }.max() ?? 0
        levels.bassDip = bassChanges.map { $0.0 }.min() ?? 0
        let swap = bassChanges.filter { $0.1 }.map { $0.0 }
        if !swap.isEmpty {
            levels.swapBassRise = swap.max()
            levels.swapBassDip = swap.min()
        }
        if let first = bassLevels.firstIndex(where: { $0.swapping }), let last = bassLevels.lastIndex(where: { $0.swapping }) {
            // The windows 0.4 s before and after (they don't overlap the swap).
            let before = bassLevels[max(0, first - 4)].level, after = bassLevels[min(bassLevels.count - 1, last + 4)].level
            let during = bassLevels[first...last].map { $0.level }
            levels.swapHole = (during.min() ?? 0) - min(before, after)
            levels.swapPileUp = (during.max() ?? 0) - max(before, after)
        }
        let sorted = errors.sorted()
        levels.predictionError = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        levels.predictionWorst = sorted.last ?? 0
        // Peaks and the limiter as the mix is rendered (before the equalizer, which runs on playback).
        levels.peak = 20 * log10(Double(max(heardMix.peak(from: 0, to: length), 1e-9)))

        // The limiter: the mix against the same rendered without it (lined up: the limiter holds the
        // sound back a little), 50 ms at a time.
        if let unlimited {
            let lag = Double(Stereo.lag(of: unlimited, behind: heardMix, around: length / 2)) / rate
            let step = 0.05
            var most = 0.0, over = 0.0, atEnds = 0.0
            var start = max(0, -lag)
            while start + step <= min(length, Double(unlimited.count) / rate - lag) {
                let reduction = unlimited.level(from: start + lag, to: start + lag + step) - heardMix.level(from: start, to: start + step)
                if reduction.isFinite {
                    most = max(most, reduction)
                    if reduction > 0.5 { over += step }
                    if start < 2 || start + step > length - 2 { atEnds = max(atEnds, reduction) }
                }
                start += step
            }
            levels.limiterMost = most
            levels.limiterSeconds = over
            levels.limiterAtEnds = atEnds
        }
        return levels
    }
}
