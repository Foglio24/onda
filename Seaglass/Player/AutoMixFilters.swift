import Foundation

/// The filters of a mix as the renderer sets them (`AutoMixRenderer`'s decks, on `AVAudioUnitEQ`),
/// and what they leave of a song's loudness, for the planner (`TransitionJudge`) to expect what the
/// render will sound like rather than guess it.
///
/// A song's sound is known from its analysis in two parts, below and above 150 Hz, unweighted and
/// as the ear weighs it (K-weighting, ITU-R BS.1770: the deep bass counts less, the treble more),
/// beat by beat (`TrackAnalysis.heard(near:)`). How the filters act within each part is worked out
/// frequency by frequency on a typical spread of music's power there (even across octaves in the
/// bass, below 40 Hz less; 2 dB less every octave above). Analyses made before 1.19, without the
/// weighted parts, are taken to have that spread throughout.
enum MixFilters {
    // MARK: As the renderer sets them

    /// The bass cut is a low shelf at 150 Hz, down by `bassFloor` dB at a full cut.
    static let bassFrequency = 150.0
    static let bassFloor: Float = 30

    /// The shelf's gain (dB) for a bass cut (0 none … 1 all), evenly in decibels.
    static func bassShelfGain(cut: Float) -> Float { -bassFloor * max(0, min(1, cut)) }

    /// The cut that leaves `amplitude` (0…1) of the bass: a swap passes the bass from one song to
    /// the other at equal power with it (each at -3 dB half way, never both deep down at once).
    static func bassCut(keeping amplitude: Double) -> Float {
        guard amplitude > 0 else { return 1 }
        return Float(max(0, min(1, -20 * log10(min(1, amplitude)) / Double(bassFloor))))
    }

    /// The high-pass sweeps from 20 Hz up to 1.2 kHz, the low-pass from 20 kHz down to 300 Hz,
    /// evenly in pitch; each is off below 0.001.
    static func highPassFrequency(_ sweep: Float) -> Float { Float(20 * pow(60, Double(max(0, min(1, sweep))))) }
    static func lowPassFrequency(_ sweep: Float) -> Float {
        Float(20_000 * pow(300.0 / 20_000, Double(max(0, min(1, sweep)))))
    }

    // MARK: What they leave

    /// How much of the loudness of a song's power below 150 Hz (`bass`) and above (`rest`) is heard,
    /// per unit of each (K-weighted), and the same unweighted.
    struct Share: Equatable, Sendable {
        var bass: Double
        var rest: Double
        var bassPower: Double
        var restPower: Double
    }

    /// No filter: the K-weighting alone.
    static let open = response(bassCut: 0, highPass: 0)

    /// With the bass cut and the high-pass at these settings (as in `TransitionLevels`).
    static func response(bassCut: Float, highPass: Float) -> Share {
        let cut = Double(max(0, min(1, bassCut))) * Double(cutSteps), sweep = Double(max(0, min(1, highPass))) * Double(sweepSteps)
        let c0 = min(cutSteps - 1, Int(cut)), s0 = min(sweepSteps - 1, Int(sweep))
        let cw = cut - Double(c0), sw = sweep - Double(s0)
        func at(_ c: Int, _ s: Int) -> Share { table[c * (sweepSteps + 1) + s] }
        func mix(_ x: Share, _ y: Share, _ w: Double) -> Share {
            Share(bass: x.bass + (y.bass - x.bass) * w, rest: x.rest + (y.rest - x.rest) * w,
                  bassPower: x.bassPower + (y.bassPower - x.bassPower) * w, restPower: x.restPower + (y.restPower - x.restPower) * w)
        }
        return mix(mix(at(c0, s0), at(c0, s0 + 1), sw), mix(at(c0 + 1, s0), at(c0 + 1, s0 + 1), sw), cw)
    }

    /// The loudness heard of a song of `power` (unweighted, as the analysis has it) with `bass` of
    /// it below 150 Hz, through `share`, as power: K-weighted (`weighted`) or not.
    static func heard(_ power: Double, bass: Double, through share: Share, weighted: Bool = true) -> Double {
        let b = max(0, min(1, bass))
        return weighted ? power * (b * share.bass + (1 - b) * share.rest)
            : power * (b * share.bassPower + (1 - b) * share.restPower)
    }

    private static let cutSteps = 60, sweepSteps = 50

    /// Every bass cut (half a decibel apart) by every high-pass setting (2 % of the sweep apart).
    private static let table: [Share] = {
        let grid = frequencies
        let kWeight = grid.map { heardWeight(at: $0) }
        var table: [Share] = []
        table.reserveCapacity((cutSteps + 1) * (sweepSteps + 1))
        for c in 0...cutSteps {
            let gain = Double(bassShelfGain(cut: Float(c) / Float(cutSteps)))
            let shelf = lowShelf(gain: gain)
            for s in 0...sweepSteps {
                let sweep = Float(s) / Float(sweepSteps)
                let highPass = sweep > 0.001 ? Biquad.highPass(Double(highPassFrequency(sweep)), q: 0.5.squareRoot(), rate: rate) : nil
                var share = Share(bass: 0, rest: 0, bassPower: 0, restPower: 0)
                var bassWeight = 0.0, restWeight = 0.0
                for (index, frequency) in grid.enumerated() {
                    var response = shelf.power(at: frequency, rate: rate)
                    if let highPass { response *= highPass.power(at: frequency, rate: rate) }
                    let weight = spread(frequency)
                    if frequency < bassFrequency {
                        share.bass += weight * kWeight[index] * response
                        share.bassPower += weight * response
                        bassWeight += weight
                    } else {
                        share.rest += weight * kWeight[index] * response
                        share.restPower += weight * response
                        restWeight += weight
                    }
                }
                share.bass /= bassWeight
                share.bassPower /= bassWeight
                share.rest /= restWeight
                share.restPower /= restWeight
                table.append(share)
            }
        }
        return table
    }()

    private static let rate = 44_100.0

    /// 30 Hz to 8 kHz (the analysis's range), 24 points an octave.
    private static let frequencies: [Double] = (0...Int(24 * log2(8_000.0 / 30))).map { 30 * pow(2, Double($0) / 24) }

    /// Music's typical power per octave around a frequency, relative.
    private static func spread(_ frequency: Double) -> Double {
        if frequency < bassFrequency { return frequency < 40 ? pow(frequency / 40, 2) : 1 }
        return pow(frequency / bassFrequency, -log2(pow(10, 0.2)))
    }

    /// K-weighting's power gain at a frequency (BS.1770: a high shelf, then a low cut): how much
    /// the ear makes of a frequency's power, for loudness.
    static func heardWeight(at frequency: Double) -> Double {
        Biquad.highShelf(1_681.974450955533, gain: 3.999843853973347, q: 0.7071752369554196, rate: rate).power(at: frequency, rate: rate)
            * Biquad.highPass(38.13547087602444, q: 0.5003270373238773, rate: rate).power(at: frequency, rate: rate)
    }

    /// The bass cut's shelf, as `AVAudioUnitEQ`'s low shelf at 150 Hz (see Tools/AutoMixLevels for
    /// its measured response).
    private static func lowShelf(gain: Double) -> Biquad {
        Biquad.lowShelf(bassFrequency, gain: gain, q: 0.5.squareRoot(), rate: rate)
    }

    /// A second-order section (RBJ's cookbook), for its response.
    struct Biquad {
        var b0, b1, b2, a1, a2: Double

        private static func normalized(_ b: (Double, Double, Double), _ a: (Double, Double, Double)) -> Biquad {
            Biquad(b0: b.0 / a.0, b1: b.1 / a.0, b2: b.2 / a.0, a1: a.1 / a.0, a2: a.2 / a.0)
        }

        static func highPass(_ frequency: Double, q: Double, rate: Double) -> Biquad {
            let w = 2 * Double.pi * frequency / rate, alpha = sin(w) / (2 * q), c = cos(w)
            return normalized(((1 + c) / 2, -(1 + c), (1 + c) / 2), (1 + alpha, -2 * c, 1 - alpha))
        }

        static func lowShelf(_ frequency: Double, gain: Double, q: Double, rate: Double) -> Biquad {
            let a = pow(10, gain / 40), w = 2 * Double.pi * frequency / rate, alpha = sin(w) / (2 * q), c = cos(w)
            let root = 2 * a.squareRoot() * alpha
            return normalized((a * ((a + 1) - (a - 1) * c + root), 2 * a * ((a - 1) - (a + 1) * c), a * ((a + 1) - (a - 1) * c - root)),
                              ((a + 1) + (a - 1) * c + root, -2 * ((a - 1) + (a + 1) * c), (a + 1) + (a - 1) * c - root))
        }

        static func highShelf(_ frequency: Double, gain: Double, q: Double, rate: Double) -> Biquad {
            let a = pow(10, gain / 40), w = 2 * Double.pi * frequency / rate, alpha = sin(w) / (2 * q), c = cos(w)
            let root = 2 * a.squareRoot() * alpha
            return normalized((a * ((a + 1) + (a - 1) * c + root), -2 * a * ((a - 1) + (a + 1) * c), a * ((a + 1) + (a - 1) * c - root)),
                              ((a + 1) - (a - 1) * c + root, 2 * ((a - 1) - (a + 1) * c), (a + 1) - (a - 1) * c - root))
        }

        /// The power gain at a frequency.
        func power(at frequency: Double, rate: Double) -> Double {
            let w = 2 * Double.pi * frequency / rate
            func squared(_ c0: Double, _ c1: Double, _ c2: Double) -> Double {
                let real = c0 + c1 * cos(w) + c2 * cos(2 * w), imaginary = -(c1 * sin(w) + c2 * sin(2 * w))
                return real * real + imaginary * imaginary
            }
            return squared(b0, b1, b2) / squared(1, a1, a2)
        }
    }
}
