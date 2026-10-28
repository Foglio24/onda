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

/// A line of the mix drawn by hand (Personalizza): it takes the place of what its part's option
/// does to one song. Volumes and the bass go from 0 (silent, no bass) to 1 (full); a filter line
/// works like a DJ's filter knob, open in the middle (0.5), a low-pass below and a high-pass above;
/// the effect line is how much of the song leaving goes through its effect.
enum MixLine: String, Codable, CodingKeyRepresentable, CaseIterable, Sendable {
    case outgoingVolume, incomingVolume, outgoingBass, incomingBass, outgoingFilter, incomingFilter, effect

    /// On the song leaving (drawn over the upper waveform) rather than the next one.
    var isOutgoing: Bool {
        switch self {
        case .outgoingVolume, .outgoingBass, .outgoingFilter, .effect: return true
        case .incomingVolume, .incomingBass, .incomingFilter: return false
        }
    }

    /// The value at the start and at the end where a song plays on its own there (the song leaving
    /// at the start, the next one at the end), so the mix starts and ends as the songs sound. Nil
    /// where the line is free.
    var fixedStart: Double? {
        switch self {
        case .outgoingVolume, .outgoingBass: return 1
        case .incomingVolume, .effect: return 0
        case .outgoingFilter: return 0.5
        case .incomingBass, .incomingFilter: return nil
        }
    }

    var fixedEnd: Double? {
        switch self {
        case .outgoingVolume: return 0
        case .incomingVolume, .incomingBass: return 1
        case .incomingFilter: return 0.5
        case .outgoingBass, .outgoingFilter, .effect: return nil
        }
    }

    /// The line's value in a mix's levels.
    func value(in levels: TransitionLevels) -> Double {
        switch self {
        case .outgoingVolume: return Double(levels.outgoing)
        case .incomingVolume: return Double(levels.incoming)
        case .outgoingBass: return 1 - Double(levels.outgoingBassCut)
        case .incomingBass: return 1 - Double(levels.incomingBassCut)
        case .outgoingFilter: return 0.5 + 0.5 * Double(levels.outgoingHighPass - levels.outgoingLowPass)
        case .incomingFilter: return 0.5 + 0.5 * Double(levels.incomingHighPass - levels.incomingLowPass)
        case .effect: return Double(max(levels.reverb, levels.echo))
        }
    }

    /// Puts the line's value into a mix's levels; the effect line drives the reverb or the echo.
    func apply(_ value: Double, to levels: inout TransitionLevels, reverb: Bool) {
        let v = Float(max(0, min(1, value)))
        switch self {
        case .outgoingVolume: levels.outgoing = v
        case .incomingVolume: levels.incoming = v
        case .outgoingBass: levels.outgoingBassCut = 1 - v
        case .incomingBass: levels.incomingBassCut = 1 - v
        case .outgoingFilter:
            levels.outgoingLowPass = max(0, (0.5 - v) * 2)
            levels.outgoingHighPass = max(0, (v - 0.5) * 2)
        case .incomingFilter:
            levels.incomingLowPass = max(0, (0.5 - v) * 2)
            levels.incomingHighPass = max(0, (v - 0.5) * 2)
        case .effect:
            levels.reverb = reverb ? v : 0
            levels.echo = reverb ? 0 : v
        }
    }

    /// The curve with its ends at 0 and 1, in order, in range, and fixed where they must be.
    func fixing(_ curve: MixCurve) -> MixCurve {
        var points = curve.points
            .map { MixPoint(x: max(0, min(1, $0.x)), y: max(0, min(1, $0.y))) }
            .sorted { $0.x < $1.x }
        if points.first?.x != 0 { points.insert(MixPoint(x: 0, y: points.first?.y ?? fixedStart ?? 0), at: 0) }
        if points.last?.x != 1 { points.append(MixPoint(x: 1, y: points.last?.y ?? fixedEnd ?? 0)) }
        if let fixedStart { points[0].y = fixedStart }
        if let fixedEnd { points[points.count - 1].y = fixedEnd }
        return MixCurve(points: points)
    }
}

/// A point of a line drawn by hand: where in the overlap (0…1) and its value (0…1).
struct MixPoint: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
}

/// A line drawn by hand: points across the overlap, in order, from 0 to 1, joined straight.
struct MixCurve: Codable, Hashable, Sendable {
    var points: [MixPoint]

    func value(at x: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if x <= first.x { return first.y }
        if x >= last.x { return last.y }
        for index in 1..<points.count where points[index].x >= x {
            let a = points[index - 1], b = points[index]
            return b.x > a.x ? a.y + (b.y - a.y) * (x - a.x) / (b.x - a.x) : b.y
        }
        return last.y
    }

    /// The line's mean over `width` around `x` (narrower at the ends, which stay exact): a jump
    /// drawn steeper than `width` becomes a ramp that long.
    func value(at x: Double, smoothing width: Double) -> Double {
        let half = min(width / 2, x, 1 - x)
        guard half > 1e-9 else { return value(at: x) }
        let lower = x - half, upper = x + half
        // Exact for straight pieces: the trapezoids between the points inside the window.
        var edges = [lower]
        edges += points.lazy.map(\.x).filter { $0 > lower && $0 < upper }
        edges.append(upper)
        var area = 0.0
        for index in 1..<edges.count {
            area += (value(at: edges[index - 1]) + value(at: edges[index])) / 2 * (edges[index] - edges[index - 1])
        }
        return area / (upper - lower)
    }

    /// A line following `value` across the overlap with as few points as keep it within
    /// `tolerance` (Ramer–Douglas–Peucker over 400 samples).
    static func tracing(tolerance: Double = 0.015, _ value: (Double) -> Double) -> MixCurve {
        let count = 400
        let samples = (0...count).map { MixPoint(x: Double($0) / Double(count), y: value(Double($0) / Double(count))) }
        var keep = [Bool](repeating: false, count: samples.count)
        keep[0] = true
        keep[count] = true
        var spans = [(0, count)]
        while let (start, end) = spans.popLast() {
            guard end > start + 1 else { continue }
            let a = samples[start], b = samples[end]
            var worst = 0.0, worstIndex = start
            for index in (start + 1)..<end {
                let line = a.y + (b.y - a.y) * (samples[index].x - a.x) / (b.x - a.x)
                let distance = abs(samples[index].y - line)
                if distance > worst {
                    worst = distance
                    worstIndex = index
                }
            }
            if worst > tolerance {
                keep[worstIndex] = true
                spans.append((start, worstIndex))
                spans.append((worstIndex, end))
            }
        }
        return MixCurve(points: samples.indices.filter { keep[$0] }.map { samples[$0] })
    }
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
    /// How far the song leaving ends earlier (negative) or later than automatic, in seconds (whole
    /// bars with beatmatching).
    var shift: Double = 0
    /// How much later (positive) or earlier than automatic the next song starts, in its own
    /// seconds (whole bars with beatmatching). Optional: designs saved before it lack it.
    var incomingShift: Double?
    /// Lines drawn by hand ("Personalizza"), each in place of what its part's option does.
    var lines: [MixLine: MixCurve]?

    init(preset: MixPreset = .auto, volume: MixVolume = .smooth, eq: MixEQ = .bassSwapCenter, filter: MixFilter = .none,
         effect: MixEffect = .none, loop: MixLoop = .none, beatmatch: Bool = true, overlap: Double? = nil, shift: Double = 0,
         incomingShift: Double? = nil, lines: [MixLine: MixCurve]? = nil) {
        self.preset = preset
        self.volume = volume
        self.eq = eq
        self.filter = filter
        self.effect = effect
        self.loop = loop
        self.beatmatch = beatmatch
        self.overlap = overlap
        self.shift = shift
        self.incomingShift = incomingShift
        self.lines = lines
    }

    /// The design with a line drawn by hand (its fixed ends kept), or without it.
    mutating func setLine(_ line: MixLine, _ curve: MixCurve?) {
        var all = lines ?? [:]
        all[line] = curve.map { line.fixing($0) }
        lines = all.isEmpty ? nil : all
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
    /// the song leaving, and `ramp` the shortest change (50 ms), both in the same units. Lines
    /// drawn by hand replace what their options do (smoothed over `ramp`, so no change clicks).
    func levels(at progress: Double, bar: Double, ramp: Double) -> TransitionLevels {
        var levels = optionLevels(at: progress, bar: bar, ramp: ramp)
        guard let lines else { return levels }
        let p = max(0, min(1, progress))
        for (line, curve) in lines where line != .effect || effect != .none {
            line.apply(curve.value(at: p, smoothing: ramp), to: &levels, reverb: effect.isReverb)
        }
        return levels
    }

    /// What the options alone do at a point of the overlap.
    private func optionLevels(at progress: Double, bar: Double, ramp: Double) -> TransitionLevels {
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
        let automatic = TransitionPlanner.reference(from: a, to: b)
        var plan: TransitionPlan
        if design.beatmatch, canBeatmatch(a, b),
           let matched = beatMatched(a, b, design: design, automatic: automatic) {
            plan = matched.plan
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

    /// The design with the songs moved only as far as the mix can be made: what the editor keeps
    /// after a drag, so dragging back moves them at once.
    static func normalized(_ design: MixDesign, from a: TrackAnalysis, to b: TrackAnalysis) -> MixDesign {
        var design = design
        let automatic = TransitionPlanner.reference(from: a, to: b)
        if design.beatmatch, canBeatmatch(a, b),
           let matched = beatMatched(a, b, design: design, automatic: automatic) {
            design.shift = Double(matched.outgoingBars) * 4 * a.beatLength
            design.incomingShift = matched.incomingBars == 0 ? nil : Double(matched.incomingBars) * 4 * b.beatLength
        } else {
            let plan = free(a, b, design: design, automatic: automatic)
            design.shift = plan.outEnd - automatic.outEnd
            let moved = plan.inStart - freeStart(b, automatic: automatic)
            design.incomingShift = abs(moved) < 0.01 ? nil : moved
        }
        return design
    }

    /// The overlaps the editor offers, in bars of the song leaving.
    static let barOptions = [2, 4, 8, 16]

    /// Each overlap the editor offers, and whether these two songs can be mixed over it.
    static func barChoices(from a: TrackAnalysis, to b: TrackAnalysis, design: MixDesign) -> [(bars: Int, available: Bool)] {
        barOptions.map { bars in
            var choice = design
            let seconds = Double(bars) * 4 * a.beatLength
            choice.overlap = seconds
            let planned = Self.plan(from: a, to: b, design: choice)
            let available = planned.style == .beatMatched ? planned.bars == bars : abs(planned.overlap - seconds) < 0.05
            return (bars, available)
        }
    }

    /// The overlap of a plan in bars of the song leaving.
    static func bars(of plan: TransitionPlan) -> Int {
        plan.bars ?? max(1, Int((plan.overlap / plan.barLength).rounded()))
    }

    /// The moves asked for, brought back toward none, nearest first.
    private static func towardZero(_ moves: Int) -> [Int] {
        moves >= 0 ? Array((0...moves).reversed()) : Array(moves...0)
    }

    /// Beats matched over the bars asked for (half or a quarter when the song is too short),
    /// both songs moved from the automatic cue points by whole bars, as far as they can be: the next
    /// song from its first downbeat to where enough of it is left, the song leaving to where the
    /// whole overlap still fits before its end.
    private static func beatMatched(_ a: TrackAnalysis, _ b: TrackAnalysis, design: MixDesign, automatic: TransitionPlan)
        -> (plan: TransitionPlan, outgoingBars: Int, incomingBars: Int)? {
        guard let octave = TransitionPlanner.tempoMatch(a, b)?.octave else { return nil }
        let bar = 4 * a.beatLength
        let wanted = bars(design, automatic: automatic, bar: bar)
        let outgoingMove = Int((design.shift / bar).rounded())
        let incomingMove = Int(((design.incomingShift ?? 0) / (4 * b.beatLength)).rounded())
        for count in [wanted, wanted / 2, wanted / 4] where count >= 1 {
            guard let cues = TransitionPlanner.cues(a, b, bars: count, endingBy: a.audibleEnd) else { continue }
            let length = Double(count * 4) * a.beatLength
            // The overlap in the next song's own time.
            let incomingLength = length * a.tempo / (b.tempo * octave)
            let incomingBars = towardZero(incomingMove).first { move in
                let downbeat = cues.incoming + 4 * move
                return downbeat >= b.firstDownbeat && b.beatTime(downbeat) + incomingLength + 10 <= b.soundEnd
            } ?? 0
            for move in towardZero(outgoingMove) {
                let downbeat = cues.outgoing + 4 * move
                guard let plan = TransitionPlanner.beatMatched(a, b, bars: count, from: downbeat,
                                                               to: cues.incoming + 4 * incomingBars, minimumHandover: 15)
                else { continue }
                // Moved, the whole overlap fits before the song's end.
                if move == 0 || plan.outEnd >= a.beatTime(downbeat) + length - 0.01 {
                    return (plan, move, incomingBars)
                }
            }
        }
        return nil
    }

    /// Where the next song starts without beatmatching, before the design moves it.
    private static func freeStart(_ b: TrackAnalysis, automatic: TransitionPlan) -> Double {
        automatic.style == .beatMatched ? max(0, b.soundStart - 0.01) : automatic.inStart
    }

    private static func free(_ a: TrackAnalysis, _ b: TrackAnalysis, design: MixDesign,
                             automatic: TransitionPlan) -> TransitionPlan {
        let end = max(a.soundStart + 12, min(a.duration - 0.05, automatic.outEnd + design.shift))
        let overlap = max(1, min(design.overlap ?? max(6, automatic.overlap), end - a.soundStart - 10))
        let outStart = end - overlap
        let start = freeStart(b, automatic: automatic)
        let latest = max(start, b.soundEnd - overlap - 10)
        let inStart = max(0, min(latest, start + (design.incomingShift ?? 0)))
        let tempo = a.tempo
        return TransitionPlan(style: .blend, handover: max(0, outStart - 0.5), outStart: outStart, outEnd: end,
                              inStart: inStart, tempoOut: tempo, tempoMeet: tempo, tempoIn: tempo, alignment: nil,
                              swapStart: nil, swapEnd: nil, fadeIn: 0.5, filterOut: nil, bars: nil)
    }
}
