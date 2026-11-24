// Checks "Ordina per il mix" (Seaglass/Player/MixOrder.swift):
// - the features come from AutoMix's analysis and only where it measured them reliably: a song made
//   to a click gets its tempo, key and energy; a song without a beat gets no tempo (none invented);
// - tempos at half or double count as the same beat, keys are neighbours on the Camelot wheel;
// - a part that isn't known costs the same whichever song it is beside (it never decides the order);
// - Fluido starts from the playlist's first analysed song, is at least as smooth as the playlist's
//   own order, and is the same every time; Energia crescente never steps down in energy;
// - songs without an analysis stay, at the end, in the playlist's order; every song is kept once,
//   twice-listed songs too, and a long playlist is ordered quickly;
// - a passage's gains bring the louder song down to the other, never up.
// Run from the repository root: bash Tools/MixOrderCheck/run.sh
import Foundation

var failures = 0
func expect(_ condition: Bool, _ message: String) {
    print(condition ? "ok   \(message)" : "FAIL \(message)")
    if !condition { failures += 1 }
}
func format(_ value: Double, _ digits: Int = 2) -> String { String(format: "%.\(digits)f", value) }

// MARK: Features from the analysis

let rate = TrackAnalyzer.sampleRate
func analysed(bpm: Double, root: Int, level: Double, drums: Bool) -> TrackAnalysis? {
    let samples = DemoSongs.samples(bpm: bpm, root: root, introBars: 0, seconds: 75, sampleRate: rate, level: level, drums: drums)
    return TrackAnalyzer.analyze(samples, sampleRate: rate)
}
if let beat = analysed(bpm: 124, root: 57, level: 0.8, drums: true) {
    let features = MixFeatures(beat)
    print("a song to a click: tempo \(features.tempo.map { format($0, 1) } ?? "-"), key \(features.camelotCode ?? "-"), energy \(features.energy.map { format($0, 1) } ?? "-") dB")
    expect(features.tempo.map { abs($0 - 124) < 1 } == true, "a song made to a click has its tempo")
    expect(features.camelot != nil, "and its key (\(features.camelotCode ?? "none"))")
    expect(features.energy != nil, "and its energy")
    if let quiet = analysed(bpm: 124, root: 57, level: 0.3, drums: true).map { MixFeatures($0) },
       let quietEnergy = quiet.energy, let loudEnergy = features.energy {
        expect(loudEnergy - quietEnergy > 6, "a quieter version has less energy (\(format(loudEnergy - quietEnergy, 1)) dB)")
    } else {
        expect(false, "a quieter version is analysed")
    }
} else {
    expect(false, "a song made to a click is analysed")
}
if let drone = analysed(bpm: 90, root: 65, level: 0.3, drums: false) {
    let features = MixFeatures(drone)
    expect(features.tempo == nil, "a song without a beat has no tempo, not an invented one (grid fit \(format(drone.gridFit)))")
    expect(features.energy != nil, "but has its energy")
} else {
    print("note: a song without a beat isn't analysed at all (it is left out of the order then)")
}

// MARK: Distances

expect(MixOrder.tempoDistance(70, 140) < 1e-12 && MixOrder.tempoDistance(140, 70) < 1e-12, "half and double tempo are the same beat")
expect(abs(MixOrder.tempoDistance(124, 128) - log(128.0 / 124)) < 1e-12, "124 and 128 BPM are 3 % apart")
expect(MixOrder.camelotDistance((8, true), (8, false)) == 1, "8A and 8B are neighbours")
expect(MixOrder.camelotDistance((12, false), (1, false)) == 1, "12B and 1B are neighbours (round the wheel)")
expect(MixOrder.camelotDistance((8, false), (3, false)) == 5, "8B and 3B are five apart")
let a1 = MixFeatures(tempo: 124, camelot: 8, minor: false, energy: -10)
let a2 = MixFeatures(tempo: 90, camelot: 3, minor: true, energy: -10)
let unknownTempo = MixFeatures(tempo: nil, camelot: 8, minor: false, energy: -10)
let blank = MixFeatures(tempo: nil, camelot: nil, minor: false, energy: -10)
expect(abs(MixOrder.cost(a1, blank) - MixOrder.cost(a2, blank)) < 1e-12, "an unknown tempo and key cost the same beside any song")
expect(MixOrder.cost(a1, a1) < MixOrder.cost(a1, a2), "a song fits itself better than a song far in tempo and key")
expect(MixOrder.tempoClose(a1, unknownTempo) == nil && MixOrder.keysMatch(a1, blank) == nil, "an unknown part is never counted as a match or a clash")

// MARK: Orders

func features(_ tempo: Double?, _ camelot: Int?, _ minor: Bool, _ energy: Double?) -> MixFeatures {
    MixFeatures(tempo: tempo, camelot: camelot, minor: minor, energy: energy)
}
// The CI scene's playlist: six analysed songs (the last without a tempo), two not on the device, one unreadable.
let items: [MixOrder.Item] = [
    .init(position: 0, features: features(128, 8, false, -9)),
    .init(position: 1, features: features(100, 3, false, -15)),
    .init(position: 2, features: features(126, 9, false, -8)),
    .init(position: 3, features: nil),
    .init(position: 4, features: features(102, 10, false, -16)),
    .init(position: 5, features: nil),
    .init(position: 6, features: features(124, 9, true, -10)),
    .init(position: 7, features: nil),
    .init(position: 8, features: features(nil, 4, false, -19)),
]
let known = Dictionary(uniqueKeysWithValues: items.compactMap { item in item.features.map { (item.position, $0) } })
let smooth = MixOrder.suggest(items, mode: .smooth)
print("Fluido: \(smooth.order)")
expect(smooth.order.sorted() == Array(0..<items.count), "Fluido keeps every song once")
expect(smooth.unplaced == [3, 5, 7], "the songs without an analysis stay at the end in the playlist's order")
expect(smooth.placed.first == 0, "Fluido starts from the playlist's first song")
let playlistOrder = items.map(\.position).filter { known[$0] != nil }
let before = MixOrder.totalCost(playlistOrder, features: known), after = MixOrder.totalCost(smooth.placed, features: known)
expect(after <= before, "Fluido is at least as smooth as the playlist's order (\(format(after)) against \(format(before)))")
let summary = MixOrder.summary(of: smooth.order, features: known), summaryBefore = MixOrder.summary(of: items.map(\.position), features: known)
expect(summary.tempoClose >= summaryBefore.tempoClose, "with at least as many passages at tempo (\(summary.tempoClose) of \(summary.tempoPairs), before \(summaryBefore.tempoClose))")
expect(MixOrder.suggest(items, mode: .smooth) == smooth, "Fluido gives the same order every time")
// The three songs near 125 BPM go together, and so do the two near 100.
if let i128 = smooth.placed.firstIndex(of: 0), let i126 = smooth.placed.firstIndex(of: 2), let i124 = smooth.placed.firstIndex(of: 6),
   let i100 = smooth.placed.firstIndex(of: 1), let i102 = smooth.placed.firstIndex(of: 4) {
    let fast = [i128, i126, i124].sorted(), slow = [i100, i102].sorted()
    expect(fast.last! - fast.first! == 2 && slow.last! - slow.first! == 1, "songs close in tempo end up together (\(smooth.placed))")
}

let rising = MixOrder.suggest(items, mode: .rising)
let energies = rising.placed.compactMap { known[$0]?.energy }
print("Energia crescente: \(rising.order), energies \(energies)")
expect(rising.order.sorted() == Array(0..<items.count), "Energia crescente keeps every song once")
expect(zip(energies, energies.dropFirst()).allSatisfy { $0 <= $1 }, "Energia crescente never steps down")
expect(rising.unplaced == [3, 5, 7], "and leaves the songs without an analysis at the end")

// A song listed twice, and equal energies: both kept, in the playlist's order between equals.
let twice: [MixOrder.Item] = [.init(position: 0, features: features(120, 1, false, -10)),
                              .init(position: 1, features: features(120, 1, false, -10)),
                              .init(position: 2, features: features(118, 2, false, -12))]
expect(MixOrder.suggest(twice, mode: .smooth).order.sorted() == [0, 1, 2], "a song listed twice is kept twice")
expect(MixOrder.suggest(twice, mode: .rising).placed == [2, 0, 1], "equal energies keep the playlist's order")
// Nothing analysed: the playlist as it is.
let none = (0..<5).map { MixOrder.Item(position: $0, features: nil) }
expect(MixOrder.suggest(none, mode: .smooth).order == [0, 1, 2, 3, 4], "with nothing analysed the order is the playlist's")
expect(MixOrder.suggest([], mode: .rising).order.isEmpty, "an empty playlist gives an empty order")

// A long playlist, quickly.
var generator = SystemRandomNumberGenerator()
let long = (0..<400).map { position -> MixOrder.Item in
    let known = Int.random(in: 0..<10, using: &generator) > 0
    return MixOrder.Item(position: position, features: known
        ? features(Bool.random(using: &generator) ? Double.random(in: 80...175, using: &generator) : nil,
                   Bool.random(using: &generator) ? Int.random(in: 1...12, using: &generator) : nil,
                   Bool.random(using: &generator), Double.random(in: -20 ... -6, using: &generator))
        : nil)
}
let started = Date()
let longOrder = MixOrder.suggest(long, mode: .smooth)
let seconds = Date().timeIntervalSince(started)
expect(longOrder.order.sorted() == Array(0..<400), "400 songs are all kept")
expect(seconds < 5, "400 songs are ordered in \(format(seconds, 2)) s")
let longKnown = Dictionary(uniqueKeysWithValues: long.compactMap { item in item.features.map { (item.position, $0) } })
expect(MixOrder.totalCost(longOrder.placed, features: longKnown) <= MixOrder.totalCost(long.map(\.position).filter { longKnown[$0] != nil }, features: longKnown),
       "and the order is smoother than the playlist's")

// MARK: A passage's gains

if let loud = analysed(bpm: 124, root: 57, level: 0.8, drums: true), let quiet = analysed(bpm: 126, root: 60, level: 0.4, drums: true) {
    let gains = MixOrder.passageGains(loud, quiet)
    expect(gains.outgoing < 1 && gains.incoming == 1, "the louder song comes down to the other (\(format(Double(gains.outgoing), 3)), \(format(Double(gains.incoming), 3)))")
    let difference = Double(loud.bodyLoudness) + 20 * log10(Double(gains.outgoing)) - Double(quiet.bodyLoudness)
    expect(abs(difference) < 0.01, "and both play as loud as each other (\(format(difference, 3)) dB)")
}

print(failures == 0 ? "MixOrderCheck: all passed" : "MixOrderCheck: \(failures) failed")
exit(failures == 0 ? 0 : 1)
