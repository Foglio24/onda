// Renders AutoMix mixes between songs made here and measures them: the mix starts exactly where the
// playing song is at the handover and ends exactly where the next song carries on (no jump on
// either side), it never goes silent, and the two songs' beats stay together through the overlap,
// also while their tempos glide (124 → 126 and 124 → 100 BPM).
// Run from the repository root: bash Tools/AutoMixRenderCheck/run.sh
import AVFoundation
import Foundation

var failures = 0
func expect(_ condition: Bool, _ message: String) {
    print(condition ? "ok   \(message)" : "FAIL \(message)")
    if !condition { failures += 1 }
}

func format(_ value: Double, _ digits: Int = 2) -> String { String(format: "%.\(digits)f", value) }

let rate = TrackAnalyzer.sampleRate

struct Random {
    var state: UInt64
    mutating func next() -> Float {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Float(Double(z >> 11) / Double(1 << 53)) * 2 - 1
    }
}

func note(_ midi: Int) -> Double { 440 * pow(2, Double(midi - 69) / 12) }

/// A song made to a click: a kick on every beat (stronger on the first of the bar), a hi-hat
/// between beats and a chord on every bar.
func song(bpm: Double, seconds: Double = 60, lead: Double = 1.5, seed: UInt64) -> [Float] {
    var random = Random(state: seed)
    let beat = 60 / bpm
    let count = Int((seconds - lead - 2) / beat)
    var x = [Float](repeating: 0, count: Int(seconds * rate))
    let chords = [(60, false), (65, false), (67, false), (60, false)]
    for k in 0..<count {
        let t = lead + Double(k) * beat
        let start = Int(t * rate)
        for i in 0..<Int(0.25 * rate) where start + i < x.count {
            let time = Double(i) / rate
            let accent: Double = k % 4 == 0 ? 1.4 : 1
            let envelope: Double = exp(-time * 18) * accent
            let sweep: Double = 55 + 90 * exp(-time * 40)
            x[start + i] += Float(0.8 * sin(2 * Double.pi * sweep * time) * envelope)
        }
        let hat = Int((t + beat / 2) * rate)
        for i in 0..<Int(0.05 * rate) where hat + i < x.count {
            x[hat + i] += 0.15 * random.next() * Float(exp(-Double(i) / rate * 60))
        }
        if k % 4 == 0 {
            let (root, minor) = chords[(k / 4) % chords.count]
            let pitches = [root, root + (minor ? 3 : 4), root + 7, root + 12].map(note)
            for i in 0..<Int(4 * beat * rate) where start + i < x.count {
                let time = Double(i) / rate
                var value = 0.0
                for pitch in pitches { value += sin(2 * Double.pi * pitch * time) }
                x[start + i] += Float(value * min(1, time / 0.02) * 0.08)
            }
        }
    }
    let peak = x.map { abs($0) }.max() ?? 1
    return x.map { $0 / peak * 0.8 }
}

func write(_ samples: [Float], to url: URL) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    try file.write(from: buffer)
}

/// The lag (seconds, positive when `b` is later) at which two stretches line up best, within
/// ±`range`, and how well (correlation 0…1).
func alignment(_ a: ArraySlice<Float>, _ b: ArraySlice<Float>, range: Double) -> (lag: Double, correlation: Double) {
    let a = Array(a), b = Array(b)
    let maxLag = Int(range * rate)
    var best = (lag: 0, value: -Double.infinity)
    let length = min(a.count, b.count) - 2 * maxLag
    guard length > 0 else { return (0, 0) }
    for lag in -maxLag...maxLag {
        var sum = 0.0, energyA = 0.0, energyB = 0.0
        for index in maxLag..<(maxLag + length) {
            let x = Double(a[index]), y = Double(b[index + lag])
            sum += x * y
            energyA += x * x
            energyB += y * y
        }
        let value = sum / ((energyA * energyB).squareRoot() + 1e-12)
        if value > best.value { best = (lag, value) }
    }
    return (Double(best.lag) / rate, best.value)
}

/// Kick onsets: where the 2 ms energy jumps to a local peak well above the second before.
func onsets(_ x: [Float]) -> [Double] {
    let window = Int(0.002 * rate)
    let frames = x.count / window
    var energy = [Double](repeating: 0, count: frames)
    for frame in 0..<frames {
        var sum = 0.0
        for index in (frame * window)..<((frame + 1) * window) { sum += Double(x[index] * x[index]) }
        energy[frame] = sum
    }
    var found: [Double] = []
    var last = -1.0
    for frame in 10..<max(10, frames - 25) {
        let before = energy[(frame - 10)..<(frame - 3)].reduce(0, +) / 7
        let around = energy[max(0, frame - 500)..<min(frames, frame + 500)].max() ?? 0
        guard energy[frame] > 8 * before, energy[frame] > 0.2 * around,
              energy[frame] >= energy[frame - 1], energy[frame] >= energy[frame + 1] else { continue }
        let time = Double(frame * window) / rate
        if time - last > 0.15 {
            found.append(time)
            last = time
        }
    }
    return found
}

@main
struct AutoMixRenderCheck {
    static func main() async {
        let folder = FileManager.default.temporaryDirectory.appending(path: "automix-render-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var songs: [Double: (url: URL, samples: [Float], analysis: TrackAnalysis)] = [:]
        for (index, bpm) in [124.0, 126, 100].enumerated() {
            let samples = song(bpm: bpm, seed: UInt64(index + 3))
            let url = folder.appending(path: "\(Int(bpm)).wav")
            do { try write(samples, to: url) } catch { expect(false, "write \(Int(bpm)) BPM: \(error)") }
            guard let analysis = TrackAnalyzer.analyze(samples, sampleRate: rate) else {
                expect(false, "\(Int(bpm)) BPM analysed")
                continue
            }
            songs[bpm] = (url, samples, analysis)
        }

        for (from, to) in [(124.0, 126.0), (124.0, 100.0)] {
            guard let a = songs[from], let b = songs[to] else { continue }
            let name = "\(Int(from)) → \(Int(to)) BPM"
            let plan = TransitionPlanner.plan(from: a.analysis, to: b.analysis)
            let schedule = MixSchedule(plan: plan)
            var joins: [String: Double] = [:]
            func render(_ outgoingGain: Float, _ incomingGain: Float, effects: Bool, _ label: String) async -> [Float]? {
                let url = folder.appending(path: "\(Int(from))-\(Int(to))-\(label).caf")
                let started = Date()
                do {
                    let mix = try await AutoMixRenderer.render(schedule, outgoing: a.url, incoming: b.url,
                                                               outgoingGain: outgoingGain, incomingGain: incomingGain,
                                                               to: url, effects: effects)
                    let seconds = Date().timeIntervalSince(started)
                    expect(abs(mix.length - schedule.length) < 0.05,
                           "\(name) (\(label)): \(format(mix.length, 1)) s of mix rendered in \(format(seconds)) s")
                    joins[label] = mix.join
                    return try await AutoMixDecoder.samples(of: url)
                } catch {
                    expect(false, "\(name) (\(label)): rendered (\(error))")
                    return nil
                }
            }
            guard let full = await render(1, 1, effects: true, "full"),
                  let outgoingOnly = await render(1, 0, effects: false, "outgoing"),
                  let incomingOnly = await render(0, 1, effects: false, "incoming") else { continue }

            // Starts exactly where the playing song is at the handover.
            let handover = Int(plan.handover * rate)
            let head = alignment(full[0..<Int(0.6 * rate)], a.samples[handover..<(handover + Int(0.6 * rate))], range: 0.02)
            expect(abs(head.lag) <= 0.0012 && head.correlation > 0.9,
                   "\(name): the mix starts where the song is (lag \(format(head.lag * 1000)) ms, match \(format(head.correlation)))")
            // Ends exactly where the next song carries on.
            let tailLength = Int(1.0 * rate)
            let joinIndex = Int((joins["full"] ?? schedule.join) * rate)
            let tail = alignment(full[(full.count - tailLength)..<full.count],
                                 b.samples[(joinIndex - tailLength)..<joinIndex], range: 0.02)
            expect(abs(tail.lag) <= 0.0012 && tail.correlation > 0.9,
                   "\(name): the mix ends where the next song carries on (lag \(format(tail.lag * 1000)) ms, match \(format(tail.correlation)))")
            // Never silent.
            let window = Int(0.05 * rate)
            let levels = stride(from: 0, to: full.count - window, by: window).map { start -> Double in
                let slice = full[start..<(start + window)]
                return (slice.reduce(0) { $0 + Double($1 * $1) } / Double(window)).squareRoot()
            }
            let typical = levels.sorted()[levels.count / 2]
            let quietest = levels.min() ?? 0
            expect(quietest > typical * 0.1,
                   "\(name): no gap (quietest 50 ms at \(format(20 * log10(quietest / typical), 1)) dB from the typical level)")
            // The two songs' kicks land together through the overlap.
            let entry = schedule.entry
            var overlapEnd = entry
            while let incoming = schedule.positions(at: overlapEnd).incoming, schedule.positions(at: overlapEnd).outgoing < plan.outEnd - 1,
                  incoming > 0, overlapEnd < schedule.length {
                overlapEnd += 0.25
            }
            let kicksOut = onsets(outgoingOnly).filter { $0 > entry + 1 && $0 < overlapEnd }
            let kicksIn = onsets(incomingOnly).filter { $0 > entry + 1 && $0 < overlapEnd }
            let distances = kicksIn.map { kick in kicksOut.map { abs($0 - kick) }.min() ?? 1 }.sorted()
            // (The last kicks of the song leaving can be too faint to find: the worst tenth is left out.)
            let median = distances.isEmpty ? 1 : distances[distances.count / 2]
            let most = distances.isEmpty ? 1 : distances[distances.count * 9 / 10]
            expect(distances.count >= 8 && median < 0.004 && most < 0.010,
                   "\(name): \(distances.count) kicks together (median \(format(median * 1000, 1)) ms, 90 % within \(format(most * 1000, 1)) ms)")
        }

        print(failures == 0 ? "AutoMixRenderCheck: all checks passed" : "AutoMixRenderCheck: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
