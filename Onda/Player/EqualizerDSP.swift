import Foundation

/// The equalizer's six bands, as in Spotify: a low shelf, four peaks and a high shelf.
enum EqualizerBands {
    static let frequencies: [Double] = [60, 150, 400, 1_000, 2_400, 15_000]
    static let labels = ["60", "150", "400", "1K", "2.4K", "15K"]
    static let count = 6
    /// Decibels a band can be raised or lowered.
    static let limit: Float = 12
    /// Width of the four peaks: neighbouring bands overlap a little, so curves stay smooth.
    static let q = 1.0
}

/// Spotify's equalizer presets (the same names as the iPhone's Music equalizer) on the six bands,
/// in decibels, plus the user's own curve.
enum EqualizerPreset: String, CaseIterable, Identifiable, Sendable {
    case flat, acoustic, bassBooster, bassReducer, classical, dance, deep, electronic, hipHop, jazz,
         latin, loudness, lounge, piano, pop, rnb, rock, smallSpeakers, spokenWord, trebleBooster,
         trebleReducer, vocalBooster, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flat: return String(localized: "Piatto")
        case .acoustic: return String(localized: "Acustica")
        case .bassBooster: return String(localized: "Più bassi")
        case .bassReducer: return String(localized: "Meno bassi")
        case .classical: return String(localized: "Classica")
        case .dance: return String(localized: "Dance")
        case .deep: return String(localized: "Profondo")
        case .electronic: return String(localized: "Elettronica")
        case .hipHop: return String(localized: "Hip-Hop")
        case .jazz: return String(localized: "Jazz")
        case .latin: return String(localized: "Latino")
        case .loudness: return String(localized: "Loudness")
        case .lounge: return String(localized: "Lounge")
        case .piano: return String(localized: "Pianoforte")
        case .pop: return String(localized: "Pop")
        case .rnb: return String(localized: "R&B")
        case .rock: return String(localized: "Rock")
        case .smallSpeakers: return String(localized: "Altoparlanti piccoli")
        case .spokenWord: return String(localized: "Parlato")
        case .trebleBooster: return String(localized: "Più alti")
        case .trebleReducer: return String(localized: "Meno alti")
        case .vocalBooster: return String(localized: "Più voce")
        case .custom: return String(localized: "Personalizzato")
        }
    }

    /// Gains for 60 Hz, 150 Hz, 400 Hz, 1 kHz, 2.4 kHz and 15 kHz; nil for `custom`.
    var gains: [Float]? {
        switch self {
        case .flat: return [0, 0, 0, 0, 0, 0]
        case .acoustic: return [4, 3, 1, 1, 2.5, 2.5]
        case .bassBooster: return [5.5, 4, 1.5, 0, 0, 0]
        case .bassReducer: return [-5.5, -4, -1.5, 0, 0, 0]
        case .classical: return [4, 3, 0, -1, 1.5, 3.5]
        case .dance: return [3.5, 5, 1, -0.5, 2.5, 3]
        case .deep: return [4.5, 2, 1.5, 0, -2, -4.5]
        case .electronic: return [4, 3.5, -0.5, 0.5, 1.5, 4.5]
        case .hipHop: return [5, 4, 0.5, -1, 1, 2.5]
        case .jazz: return [3.5, 2.5, 1, -1.5, 1, 3.5]
        case .latin: return [3.5, 1.5, -1.5, -1.5, 1.5, 4]
        case .loudness: return [6, 3, 0, -1, 1, 4]
        case .lounge: return [-2.5, -1, 0, 1.5, 0.5, 1.5]
        case .piano: return [2, 1, 2, 2.5, 3, 2.5]
        case .pop: return [-1, 0.5, 2.5, 3, 1, -1]
        case .rnb: return [3, 6, 2, -1, 1.5, 3]
        case .rock: return [4.5, 3, -0.5, -1, 1.5, 4]
        case .smallSpeakers: return [5, 3.5, 2, 0.5, -1, -3.5]
        case .spokenWord: return [-3, -1, 2, 3.5, 3.5, 0]
        case .trebleBooster: return [0, 0, 0, 1.5, 4, 5.5]
        case .trebleReducer: return [0, 0, 0, -1.5, -4, -5.5]
        case .vocalBooster: return [-1.5, -2, 1.5, 3.5, 3, 0]
        case .custom: return nil
        }
    }
}

/// One second-order filter section, from Robert Bristow-Johnson's "Audio EQ Cookbook",
/// normalized so that a0 = 1.
struct Biquad: Equatable, Sendable {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0

    static let identity = Biquad()

    static func peaking(frequency: Double, gain: Double, q: Double, sampleRate: Double) -> Biquad {
        guard gain != 0 else { return .identity }
        let a = pow(10, gain / 40)
        let w = 2 * Double.pi * min(frequency, sampleRate * 0.45) / sampleRate
        let cosw = cos(w)
        let alpha = sin(w) / (2 * q)
        let a0 = 1 + alpha / a
        return Biquad(b0: (1 + alpha * a) / a0, b1: -2 * cosw / a0, b2: (1 - alpha * a) / a0,
                      a1: -2 * cosw / a0, a2: (1 - alpha / a) / a0)
    }

    /// A shelf with slope 1: half the gain at `frequency`, all of it well below (low) or above (high).
    static func shelf(high: Bool, frequency: Double, gain: Double, sampleRate: Double) -> Biquad {
        guard gain != 0 else { return .identity }
        let a = pow(10, gain / 40)
        let w = 2 * Double.pi * min(frequency, sampleRate * 0.45) / sampleRate
        let cosw = cos(w)
        let root = 2 * sqrt(a) * sin(w) / 2 * sqrt(2)
        if high {
            let a0 = (a + 1) - (a - 1) * cosw + root
            return Biquad(b0: a * ((a + 1) + (a - 1) * cosw + root) / a0,
                          b1: -2 * a * ((a - 1) + (a + 1) * cosw) / a0,
                          b2: a * ((a + 1) + (a - 1) * cosw - root) / a0,
                          a1: 2 * ((a - 1) - (a + 1) * cosw) / a0,
                          a2: ((a + 1) - (a - 1) * cosw - root) / a0)
        }
        let a0 = (a + 1) + (a - 1) * cosw + root
        return Biquad(b0: a * ((a + 1) - (a - 1) * cosw + root) / a0,
                      b1: 2 * a * ((a - 1) - (a + 1) * cosw) / a0,
                      b2: a * ((a + 1) - (a - 1) * cosw - root) / a0,
                      a1: -2 * ((a - 1) + (a + 1) * cosw) / a0,
                      a2: ((a + 1) + (a - 1) * cosw - root) / a0)
    }

    /// The section's gain in decibels at a frequency.
    func response(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let (c1, s1, c2, s2) = (cos(w), sin(w), cos(2 * w), sin(2 * w))
        let numeratorRe = b0 + b1 * c1 + b2 * c2, numeratorIm = -(b1 * s1 + b2 * s2)
        let denominatorRe = 1 + a1 * c1 + a2 * c2, denominatorIm = -(a1 * s1 + a2 * s2)
        let power = (numeratorRe * numeratorRe + numeratorIm * numeratorIm)
            / (denominatorRe * denominatorRe + denominatorIm * denominatorIm)
        return 10 * log10(power)
    }
}

/// Turns six band gains into filters.
enum EqualizerDesign {
    /// The filter for one band: shelves for the first and last, peaks in between.
    static func section(band: Int, gain: Float, sampleRate: Double) -> Biquad {
        let frequency = EqualizerBands.frequencies[band]
        let decibels = Double(max(-EqualizerBands.limit, min(EqualizerBands.limit, gain)))
        switch band {
        case 0: return .shelf(high: false, frequency: frequency, gain: decibels, sampleRate: sampleRate)
        case EqualizerBands.count - 1:
            return .shelf(high: true, frequency: frequency, gain: decibels, sampleRate: sampleRate)
        default:
            return .peaking(frequency: frequency, gain: decibels, q: EqualizerBands.q, sampleRate: sampleRate)
        }
    }

    /// Writes the six sections without allocating, for the audio thread.
    static func fill(_ sections: UnsafeMutablePointer<Biquad>, gains: SIMD8<Float>, sampleRate: Double) {
        for band in 0..<EqualizerBands.count {
            sections[band] = section(band: band, gain: gains[band], sampleRate: sampleRate)
        }
    }

    /// The overall volume that keeps raised bands from clipping: lowered by the largest boost.
    static func preamp(_ gains: SIMD8<Float>) -> Float {
        let boost = max(0, min(EqualizerBands.limit, gains.max()))
        return Float(pow(10, -Double(boost) / 20))
    }

    /// The whole equalizer's gain in decibels at a frequency, preamp included.
    static func response(gains: [Float], at frequency: Double, sampleRate: Double = 44_100) -> Double {
        var vector = SIMD8<Float>()
        for (band, gain) in gains.prefix(EqualizerBands.count).enumerated() { vector[band] = gain }
        let sections = (0..<EqualizerBands.count).map { section(band: $0, gain: vector[$0], sampleRate: sampleRate) }
        return sections.reduce(20 * log10(Double(preamp(vector)))) { $0 + $1.response(at: frequency, sampleRate: sampleRate) }
    }
}
