// Renders AutoMix mixes between songs made here and measures them: the mix starts exactly where the
// playing song is at the handover and ends exactly where the next song carries on (no jump on
// either side), it never goes silent, and the two songs' beats stay together through the overlap,
// also while their tempos glide (124 → 126 and 124 → 130 BPM; 124 → 100 is crossfaded). The
// handover itself is played as the player makes it: the mix silent at first, then the song fading
// out in its own audio processing (`HandoverFader`) as the mix fades in, which together sound as
// the song.
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

/// How much louder `a` is than `b` (dB).
func decibels(_ a: ArraySlice<Float>, _ b: ArraySlice<Float>) -> Double {
    let power = { (x: ArraySlice<Float>) -> Double in x.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(1, x.count)) }
    return 10 * log10((power(a) + 1e-12) / (power(b) + 1e-12))
}

/// A song as its player passes it through its audio processing: in buffers of uneven sizes, each
/// with its time, through `fader`. `program` runs once the audio has gone through up to `index`
/// (AutoMix sets the fade while the song plays, ahead of the music).
func throughFader(_ samples: [Float], fader: HandoverFader, programAt index: Int, program: () -> Void) -> [Float] {
    var out = samples
    let sizes = [4096, 1024, 333, 2048, 77, 512, 1500]
    var fade = HandoverFader.Fade()
    let list = AudioBufferList.allocate(maximumBuffers: 1)
    defer { free(list.unsafeMutablePointer) }
    var position = 0
    var step = 0
    var programmed = false
    out.withUnsafeMutableBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return }
        while position < buffer.count {
            if !programmed, position >= index {
                program()
                programmed = true
            }
            let count = min(sizes[step % sizes.count], buffer.count - position)
            list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(count * MemoryLayout<Float>.size),
                                  mData: UnsafeMutableRawPointer(base + position))
            fader.process(list, frames: count, time: Double(position) / rate, sampleRate: rate, fade: &fade)
            position += count
            step += 1
        }
    }
    return out
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
        for (index, bpm) in [124.0, 126, 130, 100].enumerated() {
            let samples = song(bpm: bpm, seed: UInt64(index + 3))
            let url = folder.appending(path: "\(Int(bpm)).wav")
            do { try write(samples, to: url) } catch { expect(false, "write \(Int(bpm)) BPM: \(error)") }
            guard let analysis = TrackAnalyzer.analyze(samples, sampleRate: rate) else {
                expect(false, "\(Int(bpm)) BPM analysed")
                continue
            }
            songs[bpm] = (url, samples, analysis)
        }

        // Without voices (beats matched, the second pair with the tempo moving by up to 5 %), and
        // 124 → 100 BPM (too far apart: a crossfade at their own tempos).
        func instrumental(_ analysis: TrackAnalysis) -> VocalActivity {
            VocalActivity(regions: [VocalActivity.Region(start: 0, values: [UInt8](repeating: 0, count: Int(analysis.duration / 0.25) + 1))])
        }
        for (from, to) in [(124.0, 126.0), (124.0, 130.0), (124.0, 100.0)] {
            guard let a = songs[from], let b = songs[to] else { continue }
            let name = "\(Int(from)) → \(Int(to)) BPM"
            let context = to == 100 ? TransitionContext()
                : TransitionContext(outgoingVocals: instrumental(a.analysis), incomingVocals: instrumental(b.analysis))
            let plan = TransitionPlanner.plan(from: a.analysis, to: b.analysis, context: context)
            expect((plan.style == .beatMatched) == (to != 100),
                   "\(name): \(plan.style.rawValue), \(format(plan.overlap, 1)) s, rates \(format(plan.outgoingRate, 4)) and \(format(plan.incomingRate, 4))")
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
                    let shift = mix.shift.map { "next song moved \(format($0 * 1000, 1)) ms to land on the beat" } ?? "beats not lined up"
                    expect(abs(mix.length - schedule.length) < 0.05,
                           "\(name) (\(label)): \(format(mix.length, 1)) s of mix rendered in \(format(seconds)) s (\(shift))")
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
            // Handed over as the player does it: the mix starts silent at the handover and, once it
            // is seen playing, the two cross half a second in (the mix still the song alone, at its
            // tempo), the song fading out in its audio processing as the mix fades in. As loud as the
            // song before, during and after the fade, and never a gap.
            let crossing = 0.5, fade = HandoverFader.exactLength
            /// What is heard through the handover with the mix `lag` frames ahead of the song (the
            /// two players are never on the very same sample), crossing over `length` seconds.
            func handedOver(lag: Int, over length: Double) -> (heard: [Float], accepted: Bool) {
                let fader = HandoverFader()
                var accepted = false
                let faded = throughFader(a.samples, fader: fader, programAt: handover + Int(0.1 * rate)) {
                    accepted = fader.fadeOut(at: plan.handover + crossing, over: length, now: plan.handover)
                }
                let heard = (handover..<(handover + Int(1.0 * rate))).map { index -> Float in
                    let ramp = max(0, min(1, (Double(index - handover) / rate - crossing) / length))
                    return faded[index] + full[min(full.count - 1, index - handover + lag)] * Float(ramp)
                }
                return (heard, accepted)
            }
            let (heard, accepted) = handedOver(lag: 0, over: fade)
            func level(_ range: Range<Int>, of heard: [Float]) -> Double {
                let own = range.reduce(0.0) { $0 + Double(a.samples[handover + $1] * a.samples[handover + $1]) }
                let mixed = range.reduce(0.0) { $0 + Double(heard[$1] * heard[$1]) }
                return 10 * log10((mixed + 1e-12) / (own + 1e-12))
            }
            let crossAt = Int(crossing * rate), span = Int(fade * rate), short = Int(0.01 * rate)
            let before = level(0..<crossAt, of: heard), during = level(crossAt..<(crossAt + span), of: heard)
            let after = level((crossAt + span)..<heard.count, of: heard)
            let gap = stride(from: 0, to: heard.count - short, by: short).map { level($0..<($0 + short), of: heard) }.min() ?? -99
            expect(accepted && abs(before) < 0.01 && abs(during) < 1.5 && abs(after) < 1.5 && gap > -10,
                   "\(name): handed over as loud as the song (\(format(during, 1)) dB in the fade, \(format(after, 1)) dB after, quietest 10 ms \(format(gap, 1)) dB)")
            // With the players a few milliseconds apart the same music, half and half, partly cancels
            // out: the quietest tenth of a second (about what the ear goes by) against the song's.
            let tenth = Int(0.1 * rate)
            func dip(lag milliseconds: Double, over length: Double) -> Double {
                let heard = handedOver(lag: Int(milliseconds / 1000 * rate), over: length).heard
                return stride(from: 0, to: heard.count - tenth, by: short).map { level($0..<($0 + tenth), of: heard) }.min() ?? -99
            }
            let dips = [1.0, 2, 5].map { (lag: $0, short: dip(lag: $0, over: fade), long: dip(lag: $0, over: HandoverFader.volumeLength)) }
            expect(dips.allSatisfy { $0.short > -1.5 },
                   "\(name): players 1, 2 and 5 ms apart, at most "
                   + dips.map { format(-$0.short, 1) }.joined(separator: ", ") + " dB down over a tenth of a second (crossing over "
                   + dips.map { format(-$0.long, 1) }.joined(separator: ", ") + " dB down)")
            // Ends exactly where the next song carries on.
            let tailLength = Int(1.0 * rate)
            let joinIndex = Int((joins["full"] ?? schedule.join) * rate)
            let tail = alignment(full[(full.count - tailLength)..<full.count],
                                 b.samples[(joinIndex - tailLength)..<joinIndex], range: 0.02)
            expect(abs(tail.lag) <= 0.0012 && tail.correlation > 0.9,
                   "\(name): the mix ends where the next song carries on (lag \(format(tail.lag * 1000)) ms, match \(format(tail.correlation)))")
            // And as loud as it: the next song alone there.
            let handBack = decibels(full[(full.count - tailLength)..<full.count], b.samples[(joinIndex - tailLength)..<joinIndex])
            expect(abs(handBack) < 0.05, "\(name): hands back as loud as the next song (\(format(handBack)) dB over the last second)")
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
            guard plan.style == .beatMatched else { continue }
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

        // The handover's fade on its own: exact whatever the buffers, set only ahead of the music.
        if let a = songs[124.0] {
            let handover = 20.0, fade = HandoverFader.exactLength
            let fader = HandoverFader()
            expect(!fader.fadeOut(at: handover, over: fade, now: handover - 1),
                   "handover: no fade set before the song's audio goes through")
            var accepted = false
            var ahead: Double?
            let faded = throughFader(a.samples, fader: fader, programAt: Int((handover - 0.6) * rate)) {
                // The audio processing runs ahead of what is heard, here by 0.4 s and a buffer.
                ahead = fader.ahead(of: handover - 1)
                accepted = fader.fadeOut(at: handover, over: fade, now: handover - 1)
            }
            expect((ahead ?? 0) >= 0.39 && (ahead ?? 1) < 0.6,
                   "handover: how far the audio processing is ahead of the music is known (\(format(ahead ?? -1)) s)")
            let start = Int(handover * rate), end = Int((handover + fade) * rate)
            let before = (0..<start).allSatisfy { faded[$0] == a.samples[$0] }
            let after = ((end + 1)..<faded.count).allSatisfy { faded[$0] == 0 }
            // The mix starts as a copy of the song and ramps in: the two add up to the song.
            var worst: Float = 0
            for index in start...end {
                let ramp = Float(Double(index - start) / (fade * rate))
                worst = max(worst, abs(faded[index] + a.samples[index] * ramp - a.samples[index]))
            }
            expect(accepted && before && after && worst < 1e-4,
                   "handover: the song is untouched before, silent after, and with the mix the song itself (error \(worst))")
            expect(!fader.fadeOut(at: 40, over: fade, now: 59.9),
                   "handover: a fade the music has already gone past is refused (the player's volume does it then)")
        }

        // A song muted in the mix isn't heard: the end of the mix, where only the next song
        // plays, is silent when it is muted.
        if let a = songs[124.0], let b = songs[126.0] {
            let schedule = MixSchedule(plan: TransitionPlanner.plan(from: a.analysis, to: b.analysis))
            let url = folder.appending(path: "muted.caf")
            if let _ = try? await AutoMixRenderer.render(schedule, outgoing: a.url, incoming: b.url, outgoingGain: 1,
                                                       incomingGain: 0, to: url),
               let samples = try? await AutoMixDecoder.samples(of: url) {
                let end = samples.suffix(Int(rate))
                let level = (end.reduce(0) { $0 + Double($1 * $1) } / Double(max(1, end.count))).squareRoot()
                expect(level < 0.001, "a muted song isn't heard (\(format(20 * log10(max(level, 1e-9)), 0)) dB)")
            } else {
                expect(false, "muted mix rendered")
            }

            // Loud songs, mastered up to full scale and over it (as decoded AAC often is), at full
            // gain: where one plays alone the mix is that song, as loud and with its peaks; where
            // both play the limiter keeps them under full scale.
            let loud = { (samples: [Float]) -> [Float] in samples.map { Float(tanh(Double($0) * 4) * 1.1) } }
            let loudA = loud(a.samples), loudB = loud(b.samples)
            let loudURLs = (folder.appending(path: "loud-a.wav"), folder.appending(path: "loud-b.wav"))
            do {
                try write(loudA, to: loudURLs.0)
                try write(loudB, to: loudURLs.1)
                let instrumental = { (analysis: TrackAnalysis) in
                    VocalActivity(regions: [VocalActivity.Region(start: 0, values: [UInt8](repeating: 0, count: Int(analysis.duration / 0.25) + 1))])
                }
                let plan = TransitionPlanner.plan(from: a.analysis, to: b.analysis,
                                                  context: TransitionContext(outgoingVocals: instrumental(a.analysis),
                                                                             incomingVocals: instrumental(b.analysis)))
                let loudSchedule = MixSchedule(plan: plan)
                let url = folder.appending(path: "loud.caf")
                let mix = try await AutoMixRenderer.render(loudSchedule, outgoing: loudURLs.0, incoming: loudURLs.1,
                                                           outgoingGain: 1, incomingGain: 1, to: url)
                let samples = try await AutoMixDecoder.samples(of: url)
                let handover = Int(plan.handover * rate), second = Int(rate)
                let takeOver = decibels(samples[0..<second], loudA[handover..<(handover + second)])
                let joinIndex = Int(mix.join * rate)
                let handBack = decibels(samples[(samples.count - second)..<samples.count], loudB[(joinIndex - second)..<joinIndex])
                // Where both are clearly heard, at the mix's own rate (resampled, as `samples` are,
                // a limited peak comes out a little over).
                let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
                let native = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
                try file.read(into: native)
                let mixRate = file.processingFormat.sampleRate
                var peakTogether: Float = 0
                for time in stride(from: loudSchedule.entry, to: loudSchedule.length - 0.05, by: 0.05) {
                    let levels = loudSchedule.step(at: time).levels
                    guard levels.outgoing >= 0.3, levels.incoming >= 0.3 else { continue }
                    for frame in Int(time * mixRate)..<min(Int(native.frameLength), Int((time + 0.05) * mixRate)) {
                        for channel in 0..<Int(native.format.channelCount) {
                            peakTogether = max(peakTogether, abs(native.floatChannelData![channel][frame]))
                        }
                    }
                }
                let peakAlone = samples[0..<second].map { abs($0) }.max() ?? 0
                expect(abs(takeOver) < 0.1 && abs(handBack) < 0.05 && peakTogether <= 1.0001 && peakAlone > 1,
                       "loud songs: the mix takes over \(format(takeOver)) dB and hands back \(format(handBack)) dB from the songs, "
                       + "peaks \(format(Double(peakAlone))) alone (kept) and \(format(Double(peakTogether), 4)) together")
            } catch {
                expect(false, "loud songs: rendered (\(error))")
            }

            // Designed mixes with effects: they render, start where the song is, stay in range and join.
            for (name, preset) in [("blur: reverb, low-pass, 3 bands", MixPreset.blur), ("peak: loop, high-pass", .peak),
                                   ("wave: echo, filters", .wave), ("lines drawn by hand: filters, volume, echo", .echo)] {
                var design = MixDesign.preset(preset)
                if preset == .peak { design.filter = .noiseOut }
                if preset == .echo {
                    // A high-pass rising on the song leaving, a low-pass opening on the next one,
                    // a volume dip and an echo swelling.
                    design.setLine(.outgoingFilter, MixCurve(points: [MixPoint(x: 0, y: 0.5), MixPoint(x: 0.4, y: 0.5),
                                                                      MixPoint(x: 1, y: 0.95)]))
                    design.setLine(.incomingFilter, MixCurve(points: [MixPoint(x: 0, y: 0.1), MixPoint(x: 0.7, y: 0.5),
                                                                      MixPoint(x: 1, y: 0.5)]))
                    design.setLine(.outgoingVolume, MixCurve(points: [MixPoint(x: 0, y: 1), MixPoint(x: 0.5, y: 0.6),
                                                                      MixPoint(x: 0.8, y: 0.7), MixPoint(x: 1, y: 0)]))
                    design.setLine(.effect, MixCurve(points: [MixPoint(x: 0, y: 0), MixPoint(x: 0.6, y: 0.2),
                                                              MixPoint(x: 1, y: 0.9)]))
                }
                let plan = MixDesigner.plan(from: a.analysis, to: b.analysis, design: design)
                let schedule = MixSchedule(plan: plan)
                let url = folder.appending(path: "\(preset.rawValue).caf")
                do {
                    let mix = try await AutoMixRenderer.render(schedule, outgoing: a.url, incoming: b.url,
                                                               outgoingGain: 1, incomingGain: 1, to: url)
                    let samples = try await AutoMixDecoder.samples(of: url)
                    let peak = samples.map { abs($0) }.max() ?? 0
                    let handover = Int(plan.handover * rate)
                    let head = alignment(samples[0..<Int(0.6 * rate)], a.samples[handover..<(handover + Int(0.6 * rate))],
                                         range: 0.02)
                    let joinIndex = Int(mix.join * rate)
                    let tail = alignment(samples[(samples.count - Int(rate))..<samples.count],
                                         b.samples[(joinIndex - Int(rate))..<joinIndex], range: 0.02)
                    expect(samples.allSatisfy { $0.isFinite } && peak <= 1.0 && abs(head.lag) <= 0.0012 && head.correlation > 0.9
                           && abs(tail.lag) <= 0.0012 && tail.correlation > 0.9,
                           "\(name): \(format(mix.length, 1)) s, peak \(format(Double(peak))), joins on both sides")
                } catch {
                    expect(false, "\(name): rendered (\(error))")
                }
            }
        }

        // Voices (`VocalDetector`), with a stand-in for the model: the vocals' share of each piece,
        // and phrases made of it (short pauses filled, blips left out).
        do {
            let frames = Int(12 * 44_100.0)
            let sound = (0..<frames).map { Float(sin(Double($0) * 0.05)) * 0.5 }
            // "Vocals": half the sound (-6 dB) from 2 to 8 s, nothing elsewhere.
            let separate: VocalDetector.Separate = { left, _ in
                let vocals = left.indices.map { index -> Float in
                    let time = Double(index) / 44_100
                    return time >= 2 && time < 8 ? left[index] * 0.5 : 0
                }
                return (vocals, vocals)
            }
            let shares = try await VocalDetector.shares(left: sound, right: sound, separate: separate)
            let region = VocalDetector.region(start: 10, shares: shares)
            let activity = VocalActivity(regions: [region])
            let sung = (activity.presence(at: 15) ?? 0) > 0.9, quiet = (activity.presence(at: 11) ?? 1) < 0.1
            expect(shares.count == 48 && sung && quiet && abs((activity.firstVoice(after: 10) ?? 0) - 12) < 0.3
                   && abs((activity.lastVoice(before: 22) ?? 0) - 18) < 0.3,
                   "voices: found from 12 to 18 s of the song (\(shares.count) quarter seconds)")
            // A pause of half a second inside a phrase is filled; a quarter second of voice alone isn't one.
            var phrase = [Float](repeating: -40, count: 40)
            for index in 4..<14 { phrase[index] = 0 }
            for index in 16..<26 { phrase[index] = 0 }
            phrase[34] = 0
            let filled = VocalDetector.region(start: 0, shares: phrase)
            expect(filled.values[14] >= 128 && filled.values[15] >= 128 && filled.values[34] < 128,
                   "voices: a pause within a phrase filled, a blip left out")
        } catch {
            expect(false, "voices: measured (\(error))")
        }

        print(failures == 0 ? "AutoMixRenderCheck: all checks passed" : "AutoMixRenderCheck: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
