import Foundation

// The choices of a playlist's Mix (as Spotify's: a preset, then Volume, EQ, Filtra, Effetti and
// Looping), and how each one moves the two songs through the overlap.

/// How the two songs' volumes move.
enum MixVolume: String, Codable, CaseIterable, Sendable {
    case smooth, overlap, fadeInFadeOut, cutInFadeOut, fadeInCutOut, centerCut, crossfade, quick,
         barFadeInCutOut, barOverlapCutOut

    var title: String {
        switch self {
        case .smooth: return String(localized: "Dissolvenza incrociata uniforme")
        case .overlap: return String(localized: "Sovrapposizione")
        case .fadeInFadeOut: return String(localized: "Dissolvenza in entrata dissolvenza in uscita")
        case .cutInFadeOut: return String(localized: "Taglio in entrata dissolvenza in uscita")
        case .fadeInCutOut: return String(localized: "Dissolvenza in entrata taglio in uscita")
        case .centerCut: return String(localized: "Taglio centrale")
        case .crossfade: return String(localized: "Dissolvenza incrociata")
        case .quick: return String(localized: "Dissolvenza in entrata veloce in uscita")
        case .barFadeInCutOut: return String(localized: "Dissolvenza in entrata di 1 battuta, taglio in uscita")
        case .barOverlapCutOut: return String(localized: "Sovrapposizione di 1 battuta, taglio in uscita")
        }
    }
}

/// How the bass (and the other bands) pass from one song to the other.
enum MixEQ: String, Codable, CaseIterable, Sendable {
    case bassSwapCenter, bassSwapEnd, bassSwapStart, threeBand, quickBassCut, longBassCut, bassFadeOut, none

    var title: String {
        switch self {
        case .bassSwapCenter: return String(localized: "Scambio di bassi centrale")
        case .bassSwapEnd: return String(localized: "Scambio di bassi finale")
        case .bassSwapStart: return String(localized: "Scambio di bassi iniziale")
        case .threeBand: return String(localized: "Dissolvenza a 3 bande")
        case .quickBassCut: return String(localized: "Taglio di bassi rapido")
        case .longBassCut: return String(localized: "Taglio di bassi lungo")
        case .bassFadeOut: return String(localized: "Dissolvenza in uscita bassi")
        case .none: return String(localized: "Nessuno")
        }
    }
}

/// Filter sweeps on the song leaving ("in uscita") and the one coming in ("in entrata").
enum MixFilter: String, Codable, CaseIterable, Sendable {
    case none, lowPassOut, lowPassIn, lowPassInOut, lowPassInHighPassOut, highPassOut, highPassIn,
         highPassInOut, highPassInLowPassOut, highPassHalfOut, noiseOut

    var title: String {
        switch self {
        case .none: return String(localized: "Nessuno")
        case .lowPassOut: return String(localized: "Filtro passa basso in uscita")
        case .lowPassIn: return String(localized: "Filtro passa basso in entrata")
        case .lowPassInOut: return String(localized: "Filtro passa basso in entrata filtro passa basso in uscita")
        case .lowPassInHighPassOut: return String(localized: "Filtro passa basso in entrata filtro passa alto in uscita")
        case .highPassOut: return String(localized: "Filtro passa alto in uscita")
        case .highPassIn: return String(localized: "Filtro passa alto in entrata")
        case .highPassInOut: return String(localized: "Filtro passa alto in entrata filtro passa alto in uscita")
        case .highPassInLowPassOut: return String(localized: "Filtro passa alto in entrata filtro passa basso in uscita")
        case .highPassHalfOut: return String(localized: "Filtro passa alto metà in uscita")
        case .noiseOut: return String(localized: "Rumore in uscita alla fine")
        }
    }
}

/// Effects on the song leaving: reverb, echo and delay, with its dry sound cut or faded.
enum MixEffect: String, Codable, CaseIterable, Sendable {
    case none, reverbCenter, reverbCutEnd, reverbOutEnd, echoCutHalf, echoOutHalf, echoCutThreeQuarters,
         echoOutThreeQuarters, echoCutEnd, echoOutEnd, delayCutHalf, delayCutThreeQuarters

    var title: String {
        switch self {
        case .none: return String(localized: "Nessuno")
        case .reverbCenter: return String(localized: "Riverbero in uscita al centro")
        case .reverbCutEnd: return String(localized: "Riverbero con taglio alla fine")
        case .reverbOutEnd: return String(localized: "Riverbero in uscita alla fine")
        case .echoCutHalf: return String(localized: "Eco con taglio a metà alla fine")
        case .echoOutHalf: return String(localized: "Eco in uscita a metà alla fine")
        case .echoCutThreeQuarters: return String(localized: "Eco con taglio a tre quarti alla fine")
        case .echoOutThreeQuarters: return String(localized: "Eco in uscita a tre quarti alla fine")
        case .echoCutEnd: return String(localized: "Eco con un taglio alla fine")
        case .echoOutEnd: return String(localized: "Eco in uscita alla fine")
        case .delayCutHalf: return String(localized: "Ritardo con taglio a metà alla fine")
        case .delayCutThreeQuarters: return String(localized: "Ritardo con taglio a tre quarti alla fine")
        }
    }

    var isReverb: Bool { self == .reverbCenter || self == .reverbCutEnd || self == .reverbOutEnd }
    var isEcho: Bool { !isReverb && self != .none }

    /// The echo's repeat, in beats: a half, three quarters or a whole beat.
    var echoBeats: Double {
        switch self {
        case .echoCutHalf, .echoOutHalf, .delayCutHalf: return 0.5
        case .echoCutThreeQuarters, .echoOutThreeQuarters, .delayCutThreeQuarters: return 0.75
        default: return 1
        }
    }

    /// How much each repeat feeds the next (a delay repeats less than an echo).
    var echoFeedback: Double {
        self == .delayCutHalf || self == .delayCutThreeQuarters ? 0.2 : 0.5
    }

    /// The dry sound stops at once (the effect's tail goes on) rather than fading.
    var cutsDry: Bool {
        switch self {
        case .reverbCenter, .reverbCutEnd, .echoCutHalf, .echoCutThreeQuarters, .echoCutEnd, .delayCutHalf,
             .delayCutThreeQuarters: return true
        default: return false
        }
    }
}

/// The song leaving repeats its last beats.
enum MixLoop: Int, Codable, CaseIterable, Sendable {
    case none = 0, one = 1, two = 2, four = 4, eight = 8, sixteen = 16

    var title: String {
        self == .none ? String(localized: "Nessuno") : String(localized: "Loop di \(rawValue) beat")
    }
}

/// Ready-made combinations, as Spotify's presets.
enum MixPreset: String, Codable, CaseIterable, Sendable {
    case auto, fade, rise, blur, wave, blend, hardCut, echo, peak, warm, custom

    var title: String {
        switch self {
        case .auto: return String(localized: "Auto")
        case .fade: return String(localized: "Dissolvenza")
        case .rise: return String(localized: "Ascendente")
        case .blur: return String(localized: "Sfumatura")
        case .wave: return String(localized: "Onda")
        case .blend: return String(localized: "Fusione")
        case .hardCut: return String(localized: "Passaggio brusco")
        case .echo: return String(localized: "Eco")
        case .peak: return String(localized: "Picco")
        case .warm: return String(localized: "Fusione calda")
        case .custom: return String(localized: "Personalizzato")
        }
    }

    /// Presets offered as chips (Personalizzato is what editing a part makes).
    static var choices: [MixPreset] { allCases.filter { $0 != .custom } }
}

/// One transition of a playlist's Mix.
struct MixDesign: Codable, Hashable, Sendable {
    var preset: MixPreset
    var volume: MixVolume
    var eq: MixEQ
    var filter: MixFilter
    var effect: MixEffect
    var loop: MixLoop
    var beatmatch: Bool
    /// Seconds the two play together (of the song leaving); nil for automatic.
    var overlap: Double?
    /// How far the song leaving ends earlier (negative) or later than automatic, in seconds.
    var shift: Double = 0

    init(preset: MixPreset = .auto, volume: MixVolume = .smooth, eq: MixEQ = .bassSwapCenter, filter: MixFilter = .none,
         effect: MixEffect = .none, loop: MixLoop = .none, beatmatch: Bool = true, overlap: Double? = nil, shift: Double = 0) {
        self.preset = preset
        self.volume = volume
        self.eq = eq
        self.filter = filter
        self.effect = effect
        self.loop = loop
        self.beatmatch = beatmatch
        self.overlap = overlap
        self.shift = shift
    }

    /// A preset's choices (timing kept as automatic).
    static func preset(_ preset: MixPreset) -> MixDesign {
        switch preset {
        case .auto, .custom: return MixDesign(preset: .auto)
        case .fade: return MixDesign(preset: preset, volume: .crossfade, eq: .none)
        case .rise: return MixDesign(preset: preset, volume: .fadeInCutOut, eq: .bassSwapEnd, filter: .highPassOut)
        case .blur: return MixDesign(preset: preset, volume: .smooth, eq: .threeBand, filter: .lowPassOut, effect: .reverbOutEnd)
        case .wave: return MixDesign(preset: preset, volume: .smooth, eq: .bassSwapCenter, filter: .lowPassInHighPassOut,
                                     effect: .echoOutHalf)
        case .blend: return MixDesign(preset: preset, volume: .overlap, eq: .bassSwapCenter)
        case .hardCut: return MixDesign(preset: preset, volume: .centerCut, eq: .none)
        case .echo: return MixDesign(preset: preset, volume: .cutInFadeOut, eq: .bassSwapStart, effect: .echoOutEnd)
        case .peak: return MixDesign(preset: preset, volume: .barOverlapCutOut, eq: .quickBassCut, filter: .highPassOut,
                                     loop: .four)
        case .warm: return MixDesign(preset: preset, volume: .smooth, eq: .longBassCut, filter: .lowPassOut)
        }
    }

    /// Volumes, bands, filters and effects at a point of the overlap (0…1). `bar` is one bar of
    /// the song leaving, and `ramp` the shortest change (about 30 ms), both in the same units.
    func levels(at progress: Double, bar: Double, ramp: Double) -> TransitionLevels {
        let p = max(0, min(1, progress))
        let edge = max(0.001, ramp)
        func rise(_ start: Double, _ end: Double) -> Double {
            guard end > start else { return p >= end ? 1 : 0 }
            let x = max(0, min(1, (p - start) / (end - start)))
            return x * x * (3 - 2 * x)
        }
        var outgoing = 1.0, incoming = 0.0
        switch volume {
        case .smooth:
            let s = rise(0, 1)
            outgoing = cos(s * .pi / 2)
            incoming = sin(s * .pi / 2)
        case .crossfade:
            outgoing = 1 - p
            incoming = p
        case .overlap:
            incoming = rise(0, edge)
            outgoing = 1 - rise(1 - edge, 1)
        case .fadeInFadeOut:
            incoming = rise(0, 0.5)
            outgoing = 1 - rise(0.5, 1)
        case .cutInFadeOut:
            incoming = rise(0, edge)
            outgoing = 1 - rise(0, 1)
        case .fadeInCutOut:
            incoming = rise(0, 1 - edge)
            outgoing = 1 - rise(1 - edge, 1)
        case .centerCut:
            incoming = rise(0.5 - edge / 2, 0.5 + edge / 2)
            outgoing = 1 - incoming
        case .quick:
            let s = rise(0.35, 0.65)
            outgoing = cos(s * .pi / 2)
            incoming = sin(s * .pi / 2)
        case .barFadeInCutOut:
            incoming = rise(0, min(1 - edge, bar))
            outgoing = 1 - rise(1 - edge, 1)
        case .barOverlapCutOut:
            incoming = rise(0, edge)
            outgoing = 1 - rise(min(1 - edge, bar), min(1, bar + edge))
        }

        var levels = TransitionLevels(outgoing: 0, incoming: 0, outgoingBassCut: 0, incomingBassCut: 0, outgoingHighPass: 0)
        let swapWidth = max(edge, bar / 4)
        func swap(at centre: Double) {
            let x = rise(centre - swapWidth / 2, centre + swapWidth / 2)
            levels.outgoingBassCut = Float(x)
            levels.incomingBassCut = Float(1 - x)
        }
        switch eq {
        case .bassSwapCenter: swap(at: 0.5)
        case .bassSwapEnd: swap(at: 0.8)
        case .bassSwapStart: swap(at: 0.2)
        case .threeBand:
            levels.outgoingBassCut = Float(rise(0.2, 0.4))
            levels.outgoingMidCut = Float(rise(0.4, 0.6))
            levels.outgoingHighCut = Float(rise(0.6, 0.8))
            levels.incomingHighCut = Float(1 - rise(0.2, 0.4))
            levels.incomingMidCut = Float(1 - rise(0.4, 0.6))
            levels.incomingBassCut = Float(1 - rise(0.6, 0.8))
        case .quickBassCut: levels.outgoingBassCut = Float(rise(0, 0.1))
        case .longBassCut: levels.outgoingBassCut = Float(rise(0, 1))
        case .bassFadeOut: levels.outgoingBassCut = Float(rise(0.5, 1))
        case .none: break
        }

        let sweepOut = rise(0.3, 1), sweepIn = 1 - rise(0, 0.7)
        switch filter {
        case .none: break
        case .lowPassOut: levels.outgoingLowPass = Float(sweepOut)
        case .lowPassIn: levels.incomingLowPass = Float(sweepIn)
        case .lowPassInOut:
            levels.outgoingLowPass = Float(sweepOut)
            levels.incomingLowPass = Float(sweepIn)
        case .lowPassInHighPassOut:
            levels.outgoingHighPass = Float(sweepOut)
            levels.incomingLowPass = Float(sweepIn)
        case .highPassOut: levels.outgoingHighPass = Float(sweepOut)
        case .highPassIn: levels.incomingHighPass = Float(sweepIn)
        case .highPassInOut:
            levels.outgoingHighPass = Float(sweepOut)
            levels.incomingHighPass = Float(sweepIn)
        case .highPassInLowPassOut:
            levels.outgoingLowPass = Float(sweepOut)
            levels.incomingHighPass = Float(sweepIn)
        case .highPassHalfOut: levels.outgoingHighPass = Float(0.5 * sweepOut)
        case .noiseOut:
            levels.outgoingHighPass = Float(0.6 * sweepOut)
            levels.noise = Float(rise(0.5, 1 - edge) * (1 - rise(1 - edge, 1)))
        }

        // Effects: the wet sound rises, then the dry sound stops (cut) or fades (out); the tail
        // of the effect carries on.
        switch effect {
        case .none: break
        case .reverbCenter:
            levels.reverb = Float(rise(0.3, 0.5))
            outgoing *= 1 - rise(0.5, 0.5 + edge)
        case .reverbCutEnd:
            levels.reverb = Float(rise(0.6, 0.9))
            outgoing *= 1 - rise(0.9, 0.9 + edge)
        case .reverbOutEnd:
            levels.reverb = Float(rise(0.5, 0.9))
            outgoing *= 1 - rise(0.7, 1)
        default:
            levels.echo = Float(rise(0.7, 0.75))
            if effect.cutsDry {
                outgoing *= 1 - rise(0.8, 0.8 + edge)
            } else {
                outgoing *= 1 - rise(0.75, 1)
            }
        }
        levels.outgoing = Float(max(0, min(1, outgoing)))
        levels.incoming = Float(max(0, min(1, incoming)))
        return levels
    }
}

/// A playlist's Mix: whether it plays, and its transitions by pair of songs ("from>to").
struct PlaylistMix: Codable, Hashable, Sendable {
    var enabled = true
    var transitions: [String: MixDesign] = [:]

    static func key(from: String, to: String) -> String { "\(from)>\(to)" }
}

/// The keys in Camelot notation, as DJs (and Spotify) show them: 8B is C major, 8A A minor.
enum Camelot {
    static func code(key: Int, minor: Bool) -> String {
        let major = minor ? (key + 3) % 12 : key
        let number = (major * 7 + 8) % 12
        return "\(number == 0 ? 12 : number)\(minor ? "A" : "B")"
    }
}

/// Builds the plan of a designed transition: the automatic plan's timing (moved and lengthened
/// as the design says), beats matched when asked and possible, and the design's curves.
enum MixDesigner {
    /// Both songs have a steady beat at tempos the mix can bring together.
    static func canBeatmatch(_ a: TrackAnalysis, _ b: TrackAnalysis) -> Bool {
        a.isGridLocked && b.isGridLocked && TransitionPlanner.tempoMatch(a, b) != nil
    }

    static func plan(from a: TrackAnalysis, to b: TrackAnalysis, design: MixDesign) -> TransitionPlan {
        let automatic = TransitionPlanner.plan(from: a, to: b)
        var plan: TransitionPlan
        if design.beatmatch, canBeatmatch(a, b),
           let matched = beatMatched(a, b, design: design, automatic: automatic) {
            plan = matched
        } else {
            plan = free(a, b, design: design, automatic: automatic)
        }
        plan.design = design
        plan.barLength = 4 * a.beatLength
        if design.effect.isEcho {
            plan.echoTime = min(2, design.effect.echoBeats * a.beatLength)
            plan.echoFeedback = design.effect.echoFeedback
        }
        if design.loop != .none {
            // The song leaving repeats the beats before the middle of the overlap until it has gone.
            let middle = plan.outStart + plan.overlap / 2
            let beat = a.beat(atOrAfter: middle)
            let end = a.beatTime(beat)
            let length = Double(design.loop.rawValue) * a.beatLength
            if end - length > plan.handover + 0.5 { plan.loop = MixLoopPlan(start: end, length: length) }
        }
        return plan
    }

    /// The overlap in whole bars (at least one), from the design or the automatic plan.
    private static func bars(_ design: MixDesign, automatic: TransitionPlan, bar: Double) -> Int {
        if let overlap = design.overlap { return max(1, Int((overlap / bar).rounded())) }
        return automatic.bars ?? max(1, Int((automatic.overlap / bar).rounded()))
    }

    private static func beatMatched(_ a: TrackAnalysis, _ b: TrackAnalysis, design: MixDesign,
                                    automatic: TransitionPlan) -> TransitionPlan? {
        let bar = 4 * a.beatLength
        let wanted = bars(design, automatic: automatic, bar: bar)
        let end = min(a.duration - 0.05, a.audibleEnd + (design.shift / bar).rounded() * bar)
        for bars in [wanted, wanted / 2, wanted / 4] where bars >= 1 {
            if let plan = TransitionPlanner.beatMatched(a, b, bars: bars, endingBy: end, minimumHandover: 15) {
                return plan
            }
        }
        return nil
    }

    private static func free(_ a: TrackAnalysis, _ b: TrackAnalysis, design: MixDesign,
                             automatic: TransitionPlan) -> TransitionPlan {
        let end = max(a.soundStart + 12, min(a.duration - 0.05, automatic.outEnd + design.shift))
        let overlap = max(1, min(design.overlap ?? max(6, automatic.overlap), end - a.soundStart - 10))
        let outStart = end - overlap
        let inStart = automatic.style == .beatMatched ? max(0, b.soundStart - 0.01) : automatic.inStart
        let tempo = a.tempo
        return TransitionPlan(style: .blend, handover: max(0, outStart - 0.5), outStart: outStart, outEnd: end,
                              inStart: inStart, tempoOut: tempo, tempoMeet: tempo, tempoIn: tempo, alignment: nil,
                              swapStart: nil, swapEnd: nil, fadeIn: 0.5, filterOut: nil, bars: nil)
    }
}
