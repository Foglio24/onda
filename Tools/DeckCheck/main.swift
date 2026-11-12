// Checks the mix engine's core (Seaglass/Player/Deck/DeckMixer.swift) on samples made here:
//  - a deck starts on the exact output frame it is given;
//  - a song glided from one tempo to another and a second song started on the shared beat stay on
//    each other's beats to a fraction of a frame, and the glide's tempo moves smoothly;
//  - the lanes' levels come out where the plan puts them, by the song's own time;
//  - a glide in speed makes no click;
//  - the sound is the same whatever the number of frames the output asks for at once.
// Run from the repository root: bash Tools/DeckCheck/run.sh
import CoreAudio
import Foundation

var failures = 0
func expect(_ condition: Bool, _ message: String) {
    print(condition ? "ok   \(message)" : "FAIL \(message)")
    if !condition { failures += 1 }
}
func format(_ value: Double, _ digits: Int = 3) -> String { String(format: "%.\(digits)f", value) }

let sr = 44_100.0

// MARK: Material

/// A burst of `width` frames shaped as a Hann window, amplitude 0.5, at each of `times` (seconds): the
/// beats of a song. The burst's centre can be found to a fraction of a frame.
func clicks(at times: [Double], seconds: Double, width: Int = 24) -> [Float] {
    var x = [Float](repeating: 0, count: Int(seconds * sr))
    for time in times {
        // The burst's centre sits at `time`, fractions of a frame included.
        let centre = time * sr
        let first = Int((centre - Double(width) / 2).rounded(.up))
        for index in first..<(first + width) where index >= 0 && index < x.count {
            let u = (Double(index) - (centre - Double(width) / 2)) / Double(width)
            x[index] += Float(0.5 * (0.5 - 0.5 * cos(2 * Double.pi * u)))
        }
    }
    return x
}

func beats(bpm: Double, lead: Double, seconds: Double) -> [Double] {
    var times: [Double] = []
    var t = lead
    while t < seconds - 1 {
        times.append(t)
        t += 60 / bpm
    }
    return times
}

/// Where each burst of `x` is, in frames, to a fraction (the centroid of its energy).
func burstCentres(_ x: [Float], from: Int = 0, to: Int? = nil) -> [Double] {
    var centres: [Double] = []
    var index = from
    let end = min(to ?? x.count, x.count) - 80
    while index < end {
        if abs(x[index]) > 0.05 {
            var sum = 0.0, weight = 0.0
            for j in (index - 6)..<(index + 40) where j >= 0 && j < x.count {
                let energy = Double(x[j]) * Double(x[j])
                sum += Double(j) * energy
                weight += energy
            }
            if weight > 0 { centres.append(sum / weight) }
            index += 200
        } else {
            index += 1
        }
    }
    return centres
}

func pcm(_ samples: [Float]) -> DeckPCM { DeckPCM(sampleRate: sr, origin: 0, left: samples, right: samples) }

func render(_ mixer: DeckMixer, frames: Int, block: Int = 512) -> [Float] {
    var left = [Float](repeating: 0, count: frames)
    var right = [Float](repeating: 0, count: frames)
    left.withUnsafeMutableBufferPointer { l in
        right.withUnsafeMutableBufferPointer { r in
            var offset = 0
            while offset < frames {
                let count = min(block, frames - offset)
                mixer.render(frames: count, left: l.baseAddress! + offset, right: r.baseAddress! + offset)
                offset += count
            }
        }
    }
    return left
}

func rmsDB(_ x: [Float], from: Double, to: Double) -> Double {
    let range = Int(from * sr)..<min(x.count, Int(to * sr))
    guard !range.isEmpty else { return -200 }
    let power = range.reduce(0.0) { $0 + Double(x[$1]) * Double(x[$1]) } / Double(range.count)
    return 10 * log10(max(power, 1e-20))
}

// MARK: A deck starts on the frame it is given

for start in [1, 63, 64, 1000, 1024, 5000] {
    let mixer = DeckMixer(sampleRate: sr)
    var impulse = [Float](repeating: 0, count: 2000)
    impulse[0] = 1
    mixer.load(deck: 0, pcm: pcm(impulse), songTime: 0, startFrame: Int64(start))
    let heard = render(mixer, frames: start + 600, block: 97)
    let first = heard.firstIndex { abs($0) > 1e-6 } ?? -1
    expect(first == start && abs(heard[start] - 1) < 1e-6, "a deck given frame \(start) starts on frame \(first)")
}

// MARK: A glide to another tempo, and a song started on the shared beat

let beatsA = beats(bpm: 124, lead: 1.0, seconds: 50)
let beatsB = beats(bpm: 128, lead: 0.5, seconds: 50)
let songA = clicks(at: beatsA, seconds: 50)
let songB = clicks(at: beatsB, seconds: 50)
let target = 128.0 / 124.0
let glide = DeckRateProgram.glide(to: target, from: 12, until: 30)

let alone = DeckMixer(sampleRate: sr)
alone.load(deck: 0, pcm: pcm(songA), songTime: 0, startFrame: 0, rate: glide)
let heardA = render(alone, frames: Int(38 * sr))
let centresA = burstCentres(heardA)
print("the outgoing song's beats heard: \(centresA.count)")

// The tempo through the glide: the gap between beats, in frames.
let gaps = zip(centresA.dropFirst(), centresA).map { $0 - $1 }
let before = 60.0 / 124 * sr, after = 60.0 / 128 * sr
expect(abs(gaps[2] - before) < 1, "before the glide the beats are \(format(gaps[2], 1)) frames apart (\(format(before, 1)))")
expect(abs(gaps[gaps.count - 2] - after) < 1, "after it \(format(gaps[gaps.count - 2], 1)) (\(format(after, 1)))")
let inGlide = zip(centresA.dropFirst(), centresA).enumerated().filter { _, pair in pair.1 > 12.5 * sr && pair.0 < 29.5 * sr }.map { $0.element.0 - $0.element.1 }
expect(zip(inGlide.dropFirst(), inGlide).allSatisfy { $0 <= $1 + 0.5 }, "through the glide the gap between beats only shortens (\(inGlide.count) beats)")
let steps = zip(inGlide.dropFirst(), inGlide).map { abs($0 - $1) }
expect((steps.max() ?? 0) < 40, "and by small steps (the largest \(format(steps.max() ?? 0, 1)) frames)")

// A beat of the glided song after the glide, and the other song's beat that is to land on it.
let reference = centresA.first { $0 > 33 * sr } ?? 0
let referenceIndex = centresA.firstIndex(of: reference) ?? 0
let beatB = beatsB[10]
let songBStart = beatB - 8 * 60 / 128
let startFrame = Int64((reference - (beatB - songBStart) * sr).rounded())
let incoming = DeckMixer(sampleRate: sr)
incoming.load(deck: 1, pcm: pcm(songB), songTime: songBStart, startFrame: startFrame)
let heardB = render(incoming, frames: Int(38 * sr))
let centresB = burstCentres(heardB, from: Int(startFrame))
// The two songs' beats, from the reference on: each of A's against the same one of B's.
let fromReference = Array(centresA[referenceIndex...])
let paired = Array(centresB.drop { $0 < reference - 1000 }.prefix(fromReference.count))
let offsets = zip(paired, fromReference).map { $0 - $1 }
print("beats paired from the shared one: \(offsets.count)")
expect(offsets.count >= 8, "enough beats to measure (\(offsets.count))")
let first = offsets.first ?? 99
expect(abs(first) <= 0.75, "the second song's beat lands within \(format(abs(first), 2)) frame of the first's (it starts on a whole frame)")
let drift = (offsets.map { abs($0 - first) }.max() ?? 99)
expect(drift < 0.05, "over \(offsets.count) beats they drift apart by \(format(drift, 3)) frame (\(format(drift / sr * 1e6, 3)) µs)")

// MARK: The lanes' levels, by the song's own time

let tone = (0..<Int(20 * sr)).map { Float(0.5 * sin(2 * Double.pi * 440 * Double($0) / sr)) }
let fadePlan = SeguePlan(level: .simpleFade, shape: .fade, outgoingStart: 5, incomingStart: 5, rate: 1, length: 8, bars: nil,
                         tempo: nil, phaseMedian: nil, phaseP95: nil,
                         lanes: [SegueLane(side: .outgoing, target: .level,
                                           knots: [SegueLane.Knot(at: 0, value: 0), SegueLane.Knot(at: 1, value: -40)]),
                                 SegueLane(side: .incoming, target: .level,
                                           knots: [SegueLane.Knot(at: 0, value: -40), SegueLane.Knot(at: 1, value: 0)])],
                         swap: 0.5)
let faded = DeckMixer(sampleRate: sr)
faded.load(deck: 0, pcm: pcm(tone), songTime: 0, startFrame: 0)
faded.arm(fadePlan)
let heardFade = render(faded, frames: Int(18 * sr), block: 333)
let plain = rmsDB(heardFade, from: 1, to: 3)
expect(abs(rmsDB(heardFade, from: 3, to: 4.9) - plain) < 0.2, "before its window a deck is at its plain level")
for (second, expected) in [(7.0, -10.0), (9.0, -20.0), (11.0, -30.0)] {
    let heard = rmsDB(heardFade, from: second - 0.1, to: second + 0.1) - plain
    expect(abs(heard - expected) < 0.7, "\(format(second, 0)) s: \(format(heard, 1)) dB (the lane says \(format(expected, 0)))")
}
expect(abs(rmsDB(heardFade, from: 14, to: 17) - plain + 40) < 1.0, "after its window it holds the lane's last level")

// MARK: No click through a glide

let sine = (0..<Int(12 * sr)).map { Float(0.5 * sin(2 * Double.pi * 440 * Double($0) / sr)) }
let smooth = DeckMixer(sampleRate: sr)
smooth.load(deck: 0, pcm: pcm(sine), songTime: 0, startFrame: 0, rate: DeckRateProgram.glide(to: 1.04, from: 2, until: 6))
let heardSine = render(smooth, frames: Int(9 * sr), block: 480)
var largest: Float = 0
for index in 1..<heardSine.count { largest = max(largest, abs(heardSine[index] - heardSine[index - 1])) }
let bound = Float(0.5 * 2 * Double.pi * 440 * 1.04 / sr * 1.02)
expect(largest <= bound, "through a 4 % glide the largest step between samples is \(format(Double(largest), 5)) (a sine's own: \(format(Double(bound), 5)))")
func frequency(_ x: [Float], from: Double, to: Double) -> Double {
    var crossings = 0
    for index in Int(from * sr)..<Int(to * sr) where x[index - 1] < 0 && x[index] >= 0 { crossings += 1 }
    return Double(crossings) / (to - from)
}
expect(abs(frequency(heardSine, from: 0.5, to: 1.9) - 440) < 1.5, "its pitch before the glide: \(format(frequency(heardSine, from: 0.5, to: 1.9), 1)) Hz")
expect(abs(frequency(heardSine, from: 6.5, to: 8.5) - 440 * 1.04) < 1.5, "and after it: \(format(frequency(heardSine, from: 6.5, to: 8.5), 1)) Hz (440 × 1.04)")

// MARK: The same sound whatever the block

func wholeMix(block: Int) -> [Float] {
    let mixer = DeckMixer(sampleRate: sr)
    mixer.load(deck: 0, pcm: pcm(songA), songTime: 0, startFrame: 0, rate: glide)
    mixer.load(deck: 1, pcm: pcm(songB), songTime: songBStart, startFrame: startFrame)
    let plan = SeguePlan(level: .simpleFade, shape: .fade, outgoingStart: 30, incomingStart: beatB, rate: 1, length: 8, bars: nil,
                         tempo: nil, phaseMedian: nil, phaseP95: nil,
                         lanes: [SegueLane(side: .outgoing, target: .level,
                                           knots: [SegueLane.Knot(at: 0, value: 0), SegueLane.Knot(at: 1, value: -60)]),
                                 SegueLane(side: .incoming, target: .level,
                                           knots: [SegueLane.Knot(at: 0, value: -60), SegueLane.Knot(at: 1, value: 0)])],
                         swap: 0.5)
    mixer.arm(plan)
    return render(mixer, frames: Int(36 * sr), block: block)
}
let reference512 = wholeMix(block: 512)
for block in [1, 64, 100, 333, 1000, 4096] {
    let other = wholeMix(block: block)
    var worst: Float = 0
    for index in 0..<other.count { worst = max(worst, abs(other[index] - reference512[index])) }
    expect(worst == 0, "\(block) frames at a time: the same sound (the largest difference \(worst))")
}
expect(reference512.allSatisfy { $0.isFinite && abs($0) <= 1.0 }, "the whole mix is finite and within range")

// How fast it renders.
let started = Date()
_ = wholeMix(block: 512)
let took = Date().timeIntervalSince(started)
print("a 36 s mix rendered in \(format(took * 1000, 0)) ms (\(format(36 / max(took, 0.001), 0))× real time, including making the songs' copies)")
expect(36 / max(took, 0.001) > 10, "it renders much faster than real time")

if failures > 0 {
    print("DeckCheck: \(failures) failed")
    exit(1)
}
print("DeckCheck passed")
