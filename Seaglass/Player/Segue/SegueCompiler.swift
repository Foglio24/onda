import Foundation

/// Writes each shape as lanes, so every curve a deck plays is data in the plan. Levels are written
/// from gains: equal power where the songs don't add up, and the two faders' sum bounded
/// (`overlapMaxSum`) where their peaks may meet on a beat. A louder incoming song is brought to the
/// outgoing one's level and back to its own after the bass changes hands; a louder outgoing one is
/// eased down over the first half.
struct SegueCompiler {
    let tuning: SegueTuning
    private var t: SegueTuning { tuning }

    init(tuning: SegueTuning) { self.tuning = tuning }

    // MARK: Building blocks

    private func knot(_ x: Double, _ value: Double?, _ curve: SegueLane.Curve = .linear) -> SegueLane.Knot {
        SegueLane.Knot(at: max(0, min(1, x)), value: value, curve: curve)
    }

    /// Sorted, one knot per position (the last written wins), first at 0 and last at 1.
    private func lane(_ side: SegueLane.Side, _ target: SegueLane.Target, _ knots: [SegueLane.Knot]) -> SegueLane {
        var byPosition: [Double: SegueLane.Knot] = [:]
        for knot in knots { byPosition[(knot.at * 1_000_000).rounded() / 1_000_000] = knot }
        var sorted = byPosition.keys.sorted().compactMap { byPosition[$0] }
        if let first = sorted.first, first.at > 0 { sorted.insert(knot(0, first.value, .step), at: 0) }
        if let last = sorted.last, last.at < 1 { sorted.append(knot(1, last.value)) }
        if !sorted.isEmpty { sorted[0].curve = .step }
        return SegueLane(side: side, target: target, knots: sorted)
    }

    private func decibels(_ gain: Double) -> Double? { gain <= 1e-4 ? nil : 20 * log10(gain) }

    private func smooth(_ x: Double) -> Double {
        let u = max(0, min(1, x))
        return u * u * (3 - 2 * u)
    }

    /// Both level lanes from the gains at evenly spread positions (and `extra` ones), the power and
    /// the sum of the two bounded; `reserve`: what an echo adds to the sum there (no fader takes back
    /// what is already in its repeats, so the faders make room for it).
    private func levels(extra: [Double] = [], reserve: (Double) -> Double = { _ in 0 },
                        _ gains: (Double) -> (Double, Double)) -> [SegueLane] {
        var positions = (0...t.curveKnots).map { Double($0) / Double(t.curveKnots) } + extra
        positions = Array(Set(positions.map { max(0, min(1, $0)) })).sorted()
        var outgoing: [SegueLane.Knot] = [], incoming: [SegueLane.Knot] = []
        for x in positions {
            let (ga, gb) = gains(x)
            let power = ga * ga + gb * gb
            // The echo's share of the bound is taken first: the faders get what is left of it.
            let room = max(0.01, t.overlapMaxSum - reserve(x))
            let scale = min(power > 1 ? 1 / power.squareRoot() : 1, ga + gb > room ? room / (ga + gb) : 1)
            outgoing.append(knot(x, decibels(ga * scale)))
            incoming.append(knot(x, decibels(gb * scale)))
        }
        return [lane(.outgoing, .level, outgoing), lane(.incoming, .level, incoming)]
    }

    /// The gains with the loudness matched (see the type's comment).
    private func matched(_ x: Double, swap: Double, matchA: Double, matchB: Double, _ ga: Double, _ gb: Double) -> (Double, Double) {
        let down = 1 - (1 - matchA) * smooth(x / 0.5)
        let up = x <= swap || swap >= 1 ? matchB : matchB + (1 - matchB) * smooth((x - swap) / (1 - swap))
        return (ga * down, gb * up)
    }

    /// The bass handed over from `from` to `to` (0…1): the outgoing song's low shelf down to the
    /// kill level, the incoming one's up from it.
    private func bassHandOver(from: Double, to: Double) -> [SegueLane] {
        let end = max(min(1, to), from + 0.001)
        return [
            lane(.outgoing, .lowShelf, [knot(0, 0), knot(from, 0), knot(end, t.bassKillDB), knot(1, t.bassKillDB)]),
            lane(.incoming, .lowShelf, [knot(0, t.bassKillDB), knot(from, t.bassKillDB), knot(end, 0), knot(1, 0)]),
        ]
    }

    // MARK: Locked

    func locked(_ shape: SegueShape, swap: Double, beatShare: Double, matchA: Double, matchB: Double) -> [SegueLane] {
        switch shape {
        case .threeBand: return threeBand(swap: swap, beatShare: beatShare, matchA: matchA, matchB: matchB)
        case .cutOnBeat: return cut(at: swap, ramp: max(0.002, beatShare * 0.25))
        case .filterOpen:
            return bassSwap(swap: swap, beatShare: beatShare, matchA: matchA, matchB: matchB)
                + [lane(.incoming, .lowPass, [knot(0, t.sweepClosedHz), knot(swap, nil, .exponential), knot(1, nil)])]
        case .riseOut:
            return bassSwap(swap: swap, beatShare: beatShare, matchA: matchA, matchB: matchB)
                .filter { !($0.side == .outgoing && $0.target == .highShelf) }
                + [lane(.outgoing, .highPass, [knot(0, nil), knot(swap, nil), knot(1, t.riseClosedHz, .exponential)])]
        case .echoTail:
            return echoTail(swap: swap, beatShare: beatShare, matchA: matchA, matchB: matchB)
        default:
            return bassSwap(swap: swap, beatShare: beatShare, matchA: matchA, matchB: matchB)
        }
    }

    /// The bass swapped on one downbeat, the levels ramping: the incoming song under the outgoing
    /// one up to the swap, then the outgoing one leaving; its top end goes down over the last part,
    /// the incoming one's is held back until the swap.
    private func bassSwap(swap: Double, beatShare: Double, matchA: Double, matchB: Double) -> [SegueLane] {
        var lanes = levels(extra: [swap]) { x in
            let after = max(0, min(1, (x - swap) / max(0.001, 1 - swap)))
            let ga = x < swap ? 1 : cos(Double.pi / 2 * after)
            let gb = x < swap ? t.incomingBed * sin(Double.pi / 2 * (x / max(0.001, swap)))
                : t.incomingBed + (1 - t.incomingBed) * after
            return matched(x, swap: swap, matchA: matchA, matchB: matchB, ga, gb)
        }
        lanes += bassHandOver(from: swap, to: swap + beatShare)
        lanes.append(lane(.outgoing, .highShelf, [knot(0, 0), knot(t.outgoingTopFrom, 0), knot(1, t.outgoingTopDB)]))
        lanes.append(lane(.incoming, .highShelf, [knot(0, t.incomingTopDB), knot(swap, 0), knot(1, 0)]))
        return lanes
    }

    /// The bass swap, the outgoing song's fader shutting a beat before the end under a send that
    /// throws its last beats into the echo; the repeats ring on over the incoming song.
    private func echoTail(swap: Double, beatShare: Double, matchA: Double, matchB: Double) -> [SegueLane] {
        let closed = max(1 - beatShare, swap + 0.01)
        let opens = max(swap, closed - 2 * beatShare), closes = min(1, closed + beatShare)
        func send(_ x: Double) -> Double {
            guard x >= opens, x <= closes else { return 0 }
            return t.echoSend * (x < closed ? (x - opens) / max(0.001, closed - opens) : (closes - x) / max(0.001, closes - closed))
        }
        var lanes = levels(extra: [swap, opens, closed, closes], reserve: send) { x in
            let after = max(0, min(1, (x - swap) / max(0.001, closed - swap)))
            let ga = x < swap ? 1 : cos(Double.pi / 2 * after)
            let gb = x < swap ? t.incomingBed * sin(Double.pi / 2 * (x / max(0.001, swap)))
                : t.incomingBed + (1 - t.incomingBed) * max(0, min(1, (x - swap) / max(0.001, 1 - swap)))
            return matched(x, swap: swap, matchA: matchA, matchB: matchB, ga, gb)
        }
        lanes += bassHandOver(from: swap, to: swap + beatShare)
        lanes.append(lane(.incoming, .highShelf, [knot(0, t.incomingTopDB), knot(swap, 0), knot(1, 0)]))
        lanes.append(lane(.outgoing, .echo, [knot(0, 0), knot(opens, 0), knot(closed, t.echoSend), knot(closes, 0), knot(1, 0)]))
        return lanes
    }

    /// The bass at the swap, then the middle, then the top change hands.
    private func threeBand(swap: Double, beatShare: Double, matchA: Double, matchB: Double) -> [SegueLane] {
        let middle = (swap + 1) / 2, top = (middle + 1) / 2
        var lanes = levels(extra: [swap, middle, top]) { x in
            let ga = x < top ? 1 : cos(Double.pi / 2 * (x - top) / max(0.001, 1 - top))
            let gb = x < swap ? t.incomingBed * sin(Double.pi / 2 * (x / max(0.001, swap))) : t.incomingBed + (1 - t.incomingBed) * smooth((x - swap) / max(0.001, 1 - swap))
            return matched(x, swap: swap, matchA: matchA, matchB: matchB, ga, gb)
        }
        lanes += bassHandOver(from: swap, to: swap + beatShare)
        lanes.append(lane(.outgoing, .mid, [knot(0, 0), knot(middle, 0), knot(min(1, middle + beatShare * 2), t.coreOutDB), knot(1, t.coreOutDB)]))
        lanes.append(lane(.incoming, .mid, [knot(0, t.coreInDB), knot(middle, t.coreInDB), knot(min(1, middle + beatShare * 2), 0), knot(1, 0)]))
        lanes.append(lane(.outgoing, .highShelf, [knot(0, 0), knot(top, 0), knot(1, t.outgoingTopDB)]))
        lanes.append(lane(.incoming, .highShelf, [knot(0, t.topInDB), knot(top, t.topInDB), knot(min(1, top + beatShare * 2), 0), knot(1, 0)]))
        return lanes
    }

    /// One song, then the other, at `at` (0…1), each over a ramp of `ramp` against clicks.
    func cut(at x: Double, ramp: Double) -> [SegueLane] {
        let half = max(0.0005, ramp / 2)
        return [
            lane(.outgoing, .level, [knot(0, 0), knot(x - half, 0), knot(x + half, nil), knot(1, nil)]),
            lane(.incoming, .level, [knot(0, nil), knot(x - half, nil), knot(x + half, 0), knot(1, 0)]),
        ]
    }

    // MARK: Fades

    func filtered(_ shape: SegueShape, matchA: Double, matchB: Double) -> [SegueLane] {
        let swap = t.filteredSwap
        switch shape {
        case .quickOut:
            // The outgoing song leaves by 60 %, the incoming one rises over the whole window.
            var lanes = levels { x in
                let ga = x < 0.6 ? cos(Double.pi / 2 * x / 0.6) : 0
                return matched(x, swap: 0.6, matchA: matchA, matchB: matchB, ga, sin(Double.pi / 2 * x))
            }
            lanes += bassHandOver(from: 0.3, to: 0.45)
            return lanes
        case .lateOut:
            // The incoming song is up by 40 %, the outgoing one stays until late.
            var lanes = levels { x in
                let gb = x < 0.4 ? sin(Double.pi / 2 * x / 0.4) : 1
                let ga = x < 0.6 ? 1 : cos(Double.pi / 2 * (x - 0.6) / 0.4)
                return matched(x, swap: 0.4, matchA: matchA, matchB: matchB, ga, gb)
            }
            lanes += bassHandOver(from: 0.5, to: 0.6)
            return lanes
        case .evenFade:
            var lanes = levels { x in
                matched(x, swap: 0.5, matchA: matchA, matchB: matchB, cos(Double.pi / 2 * x), sin(Double.pi / 2 * x))
            }
            lanes += bassHandOver(from: 0.45, to: 0.55)
            return lanes
        case .echoOut:
            // The outgoing song thrown into the echo late in the fade, its fader shut just after.
            let throwAt = t.echoThrowShare, shut = min(1, t.echoThrowShare + 0.08), closes = min(1, t.echoThrowShare + 0.16)
            func send(_ x: Double) -> Double {
                guard x >= throwAt - 0.06, x <= closes else { return 0 }
                return t.echoSend * (x < throwAt ? (x - (throwAt - 0.06)) / 0.06 : (closes - x) / max(0.001, closes - throwAt))
            }
            var lanes = levels(extra: [throwAt - 0.06, throwAt, shut, closes], reserve: send) { x in
                let ga = x < throwAt ? cos(Double.pi / 4 * x / throwAt) : (x < shut ? cos(Double.pi / 4) * (shut - x) / (shut - throwAt) : 0)
                return matched(x, swap: swap, matchA: matchA, matchB: matchB, ga, sin(Double.pi / 2 * x))
            }
            lanes += bassHandOver(from: swap - 0.1, to: swap)
            lanes.append(lane(.outgoing, .echo, [knot(0, 0), knot(throwAt - 0.06, 0), knot(throwAt, t.echoSend), knot(closes, 0), knot(1, 0)]))
            lanes.append(lane(.incoming, .highShelf, [knot(0, t.incomingTopDB), knot(swap, 0), knot(1, 0)]))
            return lanes
        default:
            // The outgoing song filtered away while the incoming one rises.
            var lanes = levels { x in
                let ga = cos(Double.pi / 2 * x)
                let gb = x < swap ? t.filteredBed * sin(Double.pi / 2 * x / swap) : t.filteredBed + (1 - t.filteredBed) * smooth((x - swap) / (1 - swap))
                return matched(x, swap: swap, matchA: matchA, matchB: matchB, ga, gb)
            }
            lanes += bassHandOver(from: swap, to: min(1, swap + 0.1))
            lanes.append(lane(.outgoing, .lowPass, [knot(0, nil), knot(0.2, nil), knot(1, t.sweepClosedHz, .exponential)]))
            lanes.append(lane(.incoming, .highShelf, [knot(0, t.incomingTopDB), knot(swap, 0), knot(1, 0)]))
            return lanes
        }
    }

    /// The plain short fade: equal power, the outgoing song's bass out halfway.
    func fade() -> [SegueLane] {
        var lanes = levels { x in (cos(Double.pi / 2 * x), sin(Double.pi / 2 * x)) }
        lanes.append(lane(.outgoing, .lowShelf, [knot(0, 0), knot(0.4, 0), knot(0.6, t.bassKillDB), knot(1, t.bassKillDB)]))
        return lanes
    }

    /// One song crossing over to itself, the same music on two players (see `SegueSession`'s return
    /// to its own speed): equal gain, the two adding up to one all the way, as they are in phase.
    func crossover() -> [SegueLane] {
        levels { x in (1 - x, x) }
    }
}
