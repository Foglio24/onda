import Foundation

/// What "Ordina per il mix" knows of a song: what AutoMix's analysis of its file measured reliably,
/// and nothing else. A tempo the beat didn't hold steady, or a key that didn't come out clearly, is
/// left out (nil), never guessed.
struct MixFeatures: Equatable, Sendable {
    /// BPM, when the beat grid was steady enough to mix on (`TrackAnalysis.isGridLocked`).
    var tempo: Double?
    /// The key on the Camelot wheel (1…12, `minor` for the A ring), when it was heard clearly.
    var camelot: Int?
    var minor: Bool
    /// The energy: how loud the song's main parts are (dB), the level AutoMix keeps even across a mix.
    var energy: Double?

    init(tempo: Double?, camelot: Int?, minor: Bool, energy: Double?) {
        self.tempo = tempo
        self.camelot = camelot
        self.minor = minor
        self.energy = energy
    }

    init(_ analysis: TrackAnalysis) {
        tempo = analysis.isGridLocked && analysis.tempo.isFinite && analysis.tempo > 0 ? analysis.tempo : nil
        if analysis.hasClearKey {
            let code = Camelot.code(key: analysis.key, minor: analysis.minor)
            camelot = Int(code.dropLast())
        } else {
            camelot = nil
        }
        minor = analysis.minor
        let body = Double(analysis.bodyLoudness)
        energy = body.isFinite && body > -70 ? body : nil
    }

    var camelotCode: String? { camelot.map { "\($0)\(minor ? "A" : "B")" } }
}

enum MixOrderMode: String, CaseIterable, Identifiable, Sendable {
    /// Each song next to the ones closest in tempo, key and energy.
    case smooth
    /// From the calmest song to the most energetic (by `MixFeatures.energy`).
    case rising

    var id: String { rawValue }
}

/// The order "Ordina per il mix" suggests for a playlist. Songs are given by their place in it (so a
/// song that appears twice is two songs), with their features when they have been analysed: those
/// without (not downloaded, or not analysable) can't be placed by what they sound like and keep
/// their playlist order after the others, so no song is lost and none is placed on invented values.
enum MixOrder {
    struct Item: Equatable, Sendable {
        /// The song's place in the playlist.
        let position: Int
        let features: MixFeatures?
    }

    struct Result: Equatable, Sendable {
        /// Places in the playlist, in the suggested order: first the songs ordered by their analysis,
        /// then the others in the playlist's order.
        var placed: [Int]
        var unplaced: [Int]
        var order: [Int] { placed + unplaced }
    }

    /// How close two tempos are, as a ratio (0 the same): half and double tempo count as the same
    /// beat (a song at 70 BPM mixes with one at 140).
    static func tempoDistance(_ a: Double, _ b: Double) -> Double {
        guard a > 0, b > 0 else { return .infinity }
        return [0.5, 1, 2].map { abs(log(b * $0 / a)) }.min() ?? .infinity
    }

    /// Steps apart on the Camelot wheel: 0 the same key, 1 a neighbour (one number on, or the
    /// relative major or minor), more the further round.
    static func camelotDistance(_ a: (number: Int, minor: Bool), _ b: (number: Int, minor: Bool)) -> Int {
        let around = abs(a.number - b.number) % 12
        let steps = min(around, 12 - around)
        return steps + (a.minor == b.minor ? 0 : 1)
    }

    /// Two songs whose tempos are within 6 % of each other (or of half or double).
    static func tempoClose(_ a: MixFeatures, _ b: MixFeatures) -> Bool? {
        guard let ta = a.tempo, let tb = b.tempo else { return nil }
        return tempoDistance(ta, tb) <= log(1.06)
    }

    /// Two songs whose keys sit together on the wheel (the same or neighbours).
    static func keysMatch(_ a: MixFeatures, _ b: MixFeatures) -> Bool? {
        guard let ka = a.camelot, let kb = b.camelot else { return nil }
        return camelotDistance((ka, a.minor), (kb, b.minor)) <= 1
    }

    /// The cost of going from one song to the other (0 a perfect fit, 1 nothing in common): tempo
    /// first, then key, then energy. Where a song's tempo or key isn't known, that part costs a
    /// middle value whichever the song is beside, so the unknown never decides where it goes.
    static func cost(_ a: MixFeatures, _ b: MixFeatures) -> Double {
        let unknown = 0.5
        var tempo = unknown, key = unknown, energy = unknown
        if let ta = a.tempo, let tb = b.tempo { tempo = min(1, tempoDistance(ta, tb) / log(1.08)) }
        if let ka = a.camelot, let kb = b.camelot {
            switch camelotDistance((ka, a.minor), (kb, b.minor)) {
            case 0: key = 0
            case 1: key = 0.25
            case 2: key = 0.6
            default: key = 1
            }
        }
        if let ea = a.energy, let eb = b.energy { energy = min(1, abs(ea - eb) / 6) }
        return 0.45 * tempo + 0.35 * key + 0.2 * energy
    }

    static func suggest(_ items: [Item], mode: MixOrderMode) -> Result {
        switch mode {
        case .smooth:
            let usable = items.filter { $0.features != nil }
            return Result(placed: smooth(usable), unplaced: items.filter { $0.features == nil }.map(\.position))
        case .rising:
            let usable = items.filter { $0.features?.energy != nil }
            // Strictly by energy (between equals, the playlist's order): never a step down.
            let placed = usable.sorted { x, y in
                let ex = x.features?.energy ?? 0, ey = y.features?.energy ?? 0
                return ex != ey ? ex < ey : x.position < y.position
            }.map(\.position)
            return Result(placed: placed, unplaced: items.filter { $0.features?.energy == nil }.map(\.position))
        }
    }

    /// A chain from the playlist's first analysed song (the opening it chose), always on to the
    /// closest song left, then improved by turning stretches of it around where that makes the whole
    /// smoother (2-opt); the playlist's own order improved the same way, and the smoother of the two.
    /// The same songs always give the same order.
    private static func smooth(_ items: [Item]) -> [Int] {
        let n = items.count
        guard n > 2 else { return items.map(\.position) }
        let features = items.map { $0.features ?? MixFeatures(tempo: nil, camelot: nil, minor: false, energy: nil) }
        var matrix = [Double](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in (i + 1)..<n {
                let c = cost(features[i], features[j])
                matrix[i * n + j] = c
                matrix[j * n + i] = c
            }
        }
        func d(_ i: Int, _ j: Int) -> Double { matrix[i * n + j] }
        var path = [0]
        var left = Set(1..<n)
        while let last = path.last,
              // The closest; between equals, the one earlier in the playlist.
              let next = left.min(by: { a, b in
                  let da = d(last, a), db = d(last, b)
                  return da != db ? da < db : a < b
              }) {
            path.append(next)
            left.remove(next)
        }
        // 2-opt on an open path whose first song stays first: from the chain, and from the playlist's
        // own order, so the result is never rougher than what the playlist already had.
        let passes = n <= 200 ? 40 : n <= 600 ? 6 : 0
        func improve(_ start: [Int]) -> [Int] {
            var path = start
            var improved = true
            var pass = 0
            while improved, pass < passes {
                improved = false
                pass += 1
                for i in 1..<(n - 1) {
                    for j in (i + 1)..<n {
                        let before = d(path[i - 1], path[i]) + (j + 1 < n ? d(path[j], path[j + 1]) : 0)
                        let after = d(path[i - 1], path[j]) + (j + 1 < n ? d(path[i], path[j + 1]) : 0)
                        if after < before - 1e-9 {
                            path[i...j].reverse()
                            improved = true
                        }
                    }
                }
            }
            return path
        }
        func total(_ path: [Int]) -> Double { zip(path, path.dropFirst()).reduce(0) { $0 + d($1.0, $1.1) } }
        let fromChain = improve(path), fromPlaylist = improve(Array(0..<n))
        let best = total(fromChain) < total(fromPlaylist) - 1e-9 ? fromChain : fromPlaylist
        return best.map { items[$0].position }
    }

    /// Gains that play two songs as loud as each other in a passage, from their analysed loudness:
    /// the louder one comes down to the other (never up, so nothing clips), without any network.
    static func passageGains(_ a: TrackAnalysis, _ b: TrackAnalysis) -> (outgoing: Float, incoming: Float) {
        let la = Double(a.bodyLoudness), lb = Double(b.bodyLoudness)
        guard la.isFinite, lb.isFinite, la > -70, lb > -70 else { return (1, 1) }
        let common = min(la, lb)
        return (Float(pow(10, (common - la) / 20)), Float(pow(10, (common - lb) / 20)))
    }

    /// How an order's neighbours go together, counting only the pairs where both songs are known.
    struct Summary: Equatable, Sendable {
        var tempoPairs = 0, tempoClose = 0
        var keyPairs = 0, keysMatch = 0
        var energySteps: [Double] = []

        /// The largest change of energy from one song to the next (dB).
        var largestEnergyStep: Double { energySteps.map(abs).max() ?? 0 }
    }

    static func summary(of order: [Int], features: [Int: MixFeatures]) -> Summary {
        var summary = Summary()
        for (a, b) in zip(order, order.dropFirst()) {
            guard let fa = features[a], let fb = features[b] else { continue }
            if let close = tempoClose(fa, fb) {
                summary.tempoPairs += 1
                if close { summary.tempoClose += 1 }
            }
            if let match = keysMatch(fa, fb) {
                summary.keyPairs += 1
                if match { summary.keysMatch += 1 }
            }
            if let ea = fa.energy, let eb = fb.energy { summary.energySteps.append(eb - ea) }
        }
        return summary
    }

    /// The order's total cost (lower: smoother), over the pairs where both songs are analysed.
    static func totalCost(_ order: [Int], features: [Int: MixFeatures]) -> Double {
        zip(order, order.dropFirst()).reduce(0) { total, pair in
            guard let fa = features[pair.0], let fb = features[pair.1] else { return total }
            return total + cost(fa, fb)
        }
    }
}
