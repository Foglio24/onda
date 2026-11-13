import Foundation

// AutoMix's transitions as data (Seaglass's own engine, after the behaviour of Myspoti's "Segue",
// GPL-3.0, whose code is not used: see docs/automix-segue.md). The policy (`SeguePolicy`) writes a
// plan from the two songs' analyses; the decks (`SegueStage`, in each player's audio processing)
// play it and decide nothing. Foundation only, so the checks compile it on their own.

/// How a pair was mixed, from the most to the least ambitious. Each level is tried in this order and
/// the first whose best candidate clears its guards and its threshold plays; plain playback is not a
/// failure (no effect beats a bad one).
enum SegueLevel: String, CaseIterable, Codable, Sendable {
    /// Beat-matched over a long phrase (16 bars), phrases on both sides.
    case lockedLong
    /// Beat-matched over 8 or 4 bars, phrases on both sides.
    case lockedShort
    /// Beat-matched over 4 or 2 bars from any shared downbeat, the bass handed over.
    case lockedBeat
    /// No beat alignment: a filtered fade, the bass handed over, no two voices at once.
    case filtered
    /// A cut on a downbeat, with an anti-click ramp, between two clear boundaries.
    case hard
    /// A short equal-power fade from a safe point.
    case simpleFade
    /// Plain playback: one song after the other.
    case normal

    var isLocked: Bool { self == .lockedLong || self == .lockedShort || self == .lockedBeat }

    /// The class whose guards and scores apply.
    var family: SegueFamily? {
        switch self {
        case .lockedLong, .lockedShort, .lockedBeat: return .locked
        case .filtered: return .filtered
        case .hard: return .hard
        case .simpleFade: return .fade
        case .normal: return nil
        }
    }
}

/// Treatments whose candidates compare with one another (scores never compare across them).
enum SegueFamily: String, Codable, Sendable {
    case locked, filtered, hard, fade
}

/// What the transition sounds like, as lanes in the plan.
enum SegueShape: String, Codable, Sendable {
    /// Locked: the bass changes hands on one downbeat, over level ramps.
    case bassSwap
    /// Locked: the bass, then the middle, then the top change hands.
    case threeBand
    /// Locked: one song, then the other, on a shared downbeat.
    case cutOnBeat
    /// Locked: the incoming song opens from a closed low-pass up to the bass hand-over.
    case filterOpen
    /// Locked: after the swap the outgoing song thins from below until only its top is left.
    case riseOut
    /// Filtered: the outgoing song filtered away while the incoming one rises.
    case sweepOut
    /// Filtered: equal-power levels, the bass handed over at the middle.
    case evenFade
    /// Filtered: the outgoing song leaves early, for a voice of its own in the way.
    case quickOut
    /// Filtered: the incoming song is up early, for a voice it starts with.
    case lateOut
    /// Hard: a cut.
    case cut
    /// Simple fade.
    case fade
    /// Locked: the bass swap, the outgoing song's fader closing early into an echo of its last beats.
    case echoTail
    /// Filtered: the outgoing song thrown into an echo of its beat late in the fade.
    case echoOut
}

/// Why a level was left behind.
enum SegueCause: String, Codable, Sendable {
    case noGrid, tempoOutOfReach, lengthNotAllowed, noCandidate, guards, belowThreshold, invalidPlan, albumContinuity, disabled
}

struct SegueAttempt: Equatable, Codable, Sendable, CustomStringConvertible {
    var level: SegueLevel
    var cause: SegueCause
    var detail: String = ""
    var description: String { detail.isEmpty ? "\(level.rawValue): \(cause.rawValue)" : "\(level.rawValue): \(cause.rawValue) (\(detail))" }
}

/// One modulation of one song over the window: a level, a band of the three-band equalizer, or a
/// filter's cutoff, as knots joined by curves. Positions run from 0 to 1 over the window; before the
/// first knot and after the last, the lane holds their values, so a lane is defined at any time.
struct SegueLane: Equatable, Codable, Sendable {
    enum Side: String, Codable, Sendable { case outgoing, incoming }

    enum Target: String, Codable, CaseIterable, Sendable {
        /// dB; nil is silence.
        case level
        /// The low shelf (bass, under 180 Hz), dB; nil is neutral.
        case lowShelf
        /// The middle bell between the shelves, dB; nil is neutral.
        case mid
        /// The high shelf (over 2.5 kHz), dB; nil is neutral.
        case highShelf
        /// A low-pass's cutoff, Hz; nil is open (20 kHz).
        case lowPass
        /// A high-pass's cutoff, Hz; nil is open (20 Hz).
        case highPass
        /// How much of the song goes into an echo of its beat (0…1; nil is none), ahead of its fader:
        /// the repeats ring on after the fader has closed.
        case echo

        var isFrequency: Bool { self == .lowPass || self == .highPass }

        /// The number a nil knot stands for while a curve runs to or from it.
        var neutral: Double {
            switch self {
            case .level: return SegueLane.silenceDB
            case .lowShelf, .mid, .highShelf: return 0
            case .lowPass: return 20_000
            case .highPass: return 20
            case .echo: return 0
            }
        }
    }

    /// How the lane arrives on a knot from the previous one.
    enum Curve: Codable, Equatable, Sendable {
        /// Holds the previous value, then jumps.
        case step
        /// Straight, in the lane's unit.
        case linear
        /// Geometric: for frequencies, so a sweep sounds even.
        case exponential
        /// position^k: k under 1 rises fast then slows, over 1 the reverse.
        case power(Double)
    }

    struct Knot: Equatable, Codable, Sendable {
        var at: Double
        var value: Double?
        var curve: Curve = .linear
    }

    static let silenceDB = -60.0

    var side: Side
    var target: Target
    var knots: [Knot]

    /// The lane's number at `x` (0…1 of the window), a nil knot standing for its target's neutral.
    func value(at x: Double) -> Double {
        guard let first = knots.first, let last = knots.last else { return target.neutral }
        if x <= first.at { return number(first) }
        if x >= last.at { return number(last) }
        var low = 0, high = knots.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if knots[middle].at <= x { low = middle } else { high = middle }
        }
        let a = number(knots[low]), b = number(knots[high])
        let span = knots[high].at - knots[low].at
        let u = span > 0 ? (x - knots[low].at) / span : 1
        switch knots[high].curve {
        case .step: return a
        case .linear: return a + (b - a) * u
        case .exponential: return a > 0 && b > 0 ? a * pow(b / a, u) : a + (b - a) * u
        case .power(let k): return a + (b - a) * pow(u, max(0.05, k))
        }
    }

    /// Whether the lane sits on silence (a level lane between nil knots): not merely very quiet.
    func isSilent(at x: Double) -> Bool {
        guard target == .level, let first = knots.first, let last = knots.last else { return false }
        if x <= first.at { return first.value == nil }
        if x >= last.at { return last.value == nil }
        guard let index = knots.lastIndex(where: { $0.at <= x }), index + 1 < knots.count else { return last.value == nil }
        return knots[index].value == nil && (knots[index + 1].value == nil || knots[index + 1].curve == .step)
    }

    private func number(_ knot: Knot) -> Double { knot.value ?? target.neutral }
}

/// A transition from one song to the next.
struct SeguePlan: Equatable, Codable, Sendable {
    var level: SegueLevel
    var shape: SegueShape
    /// Where the window starts in each song's own time, seconds.
    var outgoingStart: Double
    var incomingStart: Double
    /// How fast the incoming song's time passes against the outgoing song's during the window, so
    /// that its bars meet the outgoing song's: its speed, with the outgoing song at its own (1 = the
    /// same). Played ahead (`SegueRender`) the two meet halfway, keeping this ratio; played live the
    /// outgoing song keeps its speed and, when it plays at another (a live mix brought it in so), the
    /// incoming one plays at this times that.
    var rate: Double
    /// The window's length in the outgoing song's time (as heard).
    var length: Double
    /// Bars, for a locked window.
    var bars: Int?
    /// The common tempo of a locked window, BPM.
    var tempo: Double?
    /// The expected beat misalignment of a locked window: median and 95th percentile, seconds.
    var phaseMedian: Double?
    var phaseP95: Double?
    var lanes: [SegueLane]
    /// Where the bass changes hands, 0…1 of the window.
    var swap: Double
    /// The echo's delay (seconds, on the outgoing song's beat), for the shapes that throw it into one.
    var echoDelay: Double? = nil
    var score: Double?
    /// Why each level above this one wasn't used.
    var attempts: [SegueAttempt] = []

    var outgoingEnd: Double { outgoingStart + length }

    /// The longest echo delay a deck holds (seconds), and how long the outgoing song plays on past the
    /// window for its echo to ring out.
    static let maxEchoDelay = 0.7
    static let echoTail = 3.0
    var hasEcho: Bool { lanes.contains { $0.target == .echo } }
    var incomingEnd: Double { incomingStart + length * rate }

    func lanes(_ side: SegueLane.Side) -> [SegueLane] { lanes.filter { $0.side == side } }

    /// Where in the window a song's own time falls (0 at its start, 1 at its end): what each deck reads
    /// its lanes at, from the position of the very samples it processes.
    func position(_ side: SegueLane.Side, sourceTime: Double) -> Double {
        guard length > 0 else { return sourceTime >= outgoingStart ? 1 : 0 }
        switch side {
        case .outgoing: return (sourceTime - outgoingStart) / length
        case .incoming: return (sourceTime - incomingStart) / (rate * length)
        }
    }

    /// The incoming song's own time that goes with a time of the outgoing one in the window.
    func incomingTime(atOutgoing time: Double) -> Double { incomingStart + (time - outgoingStart) * rate }

    /// The plan for the player that carries the outgoing song out of the mix (see
    /// `SegueSession.carried`): its level crossing in from silence over the window's first
    /// `crossover` seconds (equal gain against the player it takes over from, which plays
    /// `SeguePlan.crossover`), the other lanes as they are.
    func carried(crossover: Double) -> SeguePlan {
        var carried = self
        guard length > 0, let index = carried.lanes.firstIndex(where: { $0.side == .outgoing && $0.target == .level }) else {
            return carried
        }
        let lane = carried.lanes[index]
        let span = min(0.5, crossover / length)
        // Twelve steps: the lane interpolates in dB, so a straight gain needs knots close together.
        var knots = (0...12).map { step -> SegueLane.Knot in
            let x = span * Double(step) / 12
            let value: Double? = step == 0 || lane.isSilent(at: x) ? nil : lane.value(at: x) + 20 * log10(Double(step) / 12)
            return SegueLane.Knot(at: x, value: value)
        }
        knots += lane.knots.filter { $0.at > span }
        carried.lanes[index].knots = knots
        return carried
    }

    /// One step of the playing song's glide to the next song's tempo (see `SegueSession.carriers`):
    /// a player that crosses in from silence at `from` (the song's time) and out at `to`, each over
    /// `crossover` seconds (equal gain against the players before and after it), at full level in
    /// between.
    static func relay(from: Double, to: Double, crossover: Double) -> SeguePlan {
        let length = max(2 * crossover, to - from + crossover)
        let edge = crossover / length
        var knots: [SegueLane.Knot] = []
        for step in 0...12 {
            let gain = Double(step) / 12
            knots.append(SegueLane.Knot(at: edge * gain, value: step == 0 ? nil : 20 * log10(gain)))
        }
        for step in 0...12 {
            let gain = 1 - Double(step) / 12
            knots.append(SegueLane.Knot(at: 1 - edge + edge * Double(step) / 12, value: step == 12 ? nil : 20 * log10(gain)))
        }
        return SeguePlan(level: .simpleFade, shape: .fade, outgoingStart: from, incomingStart: from, rate: 1, length: length,
                         bars: nil, tempo: nil, phaseMedian: nil, phaseP95: nil,
                         lanes: [SegueLane(side: .outgoing, target: .level, knots: knots)], swap: 0.5)
    }

    /// One song crossing over to itself on another player, from `at` (its time on both) over
    /// `length` seconds: the outgoing side the player it leaves, the incoming side the one it goes to.
    static func crossover(at: Double, length: Double) -> SeguePlan {
        SeguePlan(level: .simpleFade, shape: .fade, outgoingStart: at, incomingStart: at, rate: 1, length: length,
                  bars: nil, tempo: nil, phaseMedian: nil, phaseP95: nil,
                  lanes: SegueCompiler(tuning: SegueTuning()).crossover(), swap: 0.5)
    }
}

/// What a plan must be to run: every problem found (none: it may play).
enum SegueValidator {
    static func problems(_ plan: SeguePlan, outgoingDuration: Double, incomingDuration: Double) -> [String] {
        var found: [String] = []
        if !(plan.length > 0 && plan.length.isFinite) { found.append("length") }
        if !(plan.rate > 0.5 && plan.rate < 2 && plan.rate.isFinite) { found.append("rate") }
        if plan.outgoingStart < 0 || plan.outgoingEnd > outgoingDuration + 0.05 { found.append("outgoing window") }
        if plan.incomingStart < 0 || plan.incomingEnd > incomingDuration + 0.05 { found.append("incoming window") }
        if plan.level.isLocked, plan.tempo == nil || plan.bars == nil { found.append("locked without tempo") }
        for lane in plan.lanes {
            guard let first = lane.knots.first, let last = lane.knots.last, first.at <= 0, last.at >= 1 else {
                found.append("\(lane.side.rawValue) \(lane.target.rawValue): not covering the window")
                continue
            }
            if zip(lane.knots, lane.knots.dropFirst()).contains(where: { $0.at >= $1.at }) {
                found.append("\(lane.side.rawValue) \(lane.target.rawValue): knots out of order")
            }
            if lane.knots.contains(where: { $0.curve == .exponential && !lane.target.isFrequency }) {
                found.append("\(lane.side.rawValue) \(lane.target.rawValue): exponential curve on a level")
            }
            if lane.target.isFrequency, lane.knots.contains(where: { ($0.value ?? 1) <= 0 }) {
                found.append("\(lane.side.rawValue) \(lane.target.rawValue): frequency not positive")
            }
            if lane.target == .echo, lane.knots.contains(where: { ($0.value ?? 0) < 0 || ($0.value ?? 0) > 1 }) {
                found.append("\(lane.side.rawValue) echo: send out of 0…1")
            }
        }
        if plan.lanes.contains(where: { $0.target == .echo }) {
            if !((plan.echoDelay ?? 0) >= 0.05 && (plan.echoDelay ?? 1) <= SeguePlan.maxEchoDelay) { found.append("echo delay") }
            if plan.outgoingEnd + SeguePlan.echoTail > outgoingDuration + 0.05 { found.append("no room for the echo's tail") }
        }
        let levels = Dictionary(grouping: plan.lanes.filter { $0.target == .level }, by: \.side)
        if levels[.outgoing]?.count != 1 || levels[.incoming]?.count != 1 { found.append("one level lane per side") }
        return found
    }
}
