// AutoMix's volume, measured on songs made here (see Levels.swift): bass-rich songs mixed on the
// beat (the bass passing from one to the other), a bass-rich song into an acoustic one, two songs
// 12 dB apart, with "Volume uniforme" off and on, and a playlist's Mix with its presets. Each mix
// is rendered with and without the limiter and compared with normal playback of the same songs.
// Run from the repository root: bash Tools/AutoMixLevels/run.sh
import AVFoundation
import Foundation

var failures = 0
func expect(_ condition: Bool, _ message: String) {
    print(condition ? "ok   \(message)" : "FAIL \(message)")
    if !condition { failures += 1 }
}

let rate = TrackAnalyzer.sampleRate

func note(_ midi: Int) -> Double { 440 * pow(2, Double(midi - 69) / 12) }

/// A song made to a click: kick drum, bass line, hi-hat and a chord on every bar, as asked for.
func song(bpm: Double, root: Int, kick: Bool, bass: Bool, seconds: Double = 90, level: Float = 1) -> [Float] {
    var x = [Float](repeating: 0, count: Int(seconds * rate))
    let beat = 60 / bpm
    let count = Int((seconds - 3.5) / beat)
    var noise: UInt64 = UInt64(root * 7919 + Int(bpm))
    func random() -> Float {
        noise = noise &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int64(bitPattern: noise >> 11) % 10_000) / 10_000
    }
    let progression = [0, 5, 7, 3]
    for k in 0..<count {
        let t = 1.5 + Double(k) * beat
        let start = Int(t * rate)
        let chord = progression[(k / 4) % progression.count]
        if kick {
            for i in 0..<Int(0.25 * rate) where start + i < x.count {
                let time = Double(i) / rate
                let sweep = 50 + 90 * exp(-time * 40)
                x[start + i] += Float(0.7 * sin(2 * Double.pi * sweep * time) * exp(-time * 16) * (k % 4 == 0 ? 1.3 : 1))
            }
        }
        if bass {
            // Eighth notes on the chord's root, two octaves down.
            let pitch = note(root + chord - 24)
            for half in 0..<2 {
                let from = Int((t + Double(half) * beat / 2) * rate)
                for i in 0..<Int(beat / 2 * rate) where from + i < x.count {
                    let time = Double(i) / rate
                    let envelope = min(1, time / 0.01) * exp(-time * 3)
                    x[from + i] += Float(0.45 * envelope * (sin(2 * Double.pi * pitch * time) + 0.3 * sin(4 * Double.pi * pitch * time)))
                }
            }
        }
        let hat = Int((t + beat / 2) * rate)
        for i in 0..<Int(0.04 * rate) where hat + i < x.count {
            x[hat + i] += 0.12 * (random() * 2 - 1) * Float(exp(-Double(i) / rate * 70))
        }
        if k % 4 == 0 {
            let pitches = [0, 4, 7, 12].map { note(root + chord + 12 + $0) }
            for i in 0..<Int(4 * beat * rate) where start + i < x.count {
                let time = Double(i) / rate
                let envelope = min(1, time / 0.02) * (kick ? 1 : exp(-time * 0.8))
                var value = 0.0
                for pitch in pitches { value += sin(2 * Double.pi * pitch * time) + 0.2 * sin(4 * Double.pi * pitch * time) }
                x[start + i] += Float(value * envelope * 0.07)
            }
        }
    }
    let peak = x.map { abs($0) }.max() ?? 1
    return x.map { $0 / peak * 0.9 * level }
}

func write(_ samples: [Float], to url: URL) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    try file.write(from: buffer)
}

/// The gain "Volume uniforme" gives a song: louder songs down to a reference (here -16 dB of
/// K-weighted power), never up.
func uniformGain(_ samples: [Float]) -> Float {
    let stereo = Stereo(left: samples, right: samples, rate: rate).filtered(LevelFilter.kWeighting(rate: rate))
    let loudness = stereo.level(from: 0, to: Double(samples.count) / rate)
    return Float(min(1, pow(10, (-16 - loudness) / 20)))
}

func instrumental(_ analysis: TrackAnalysis) -> VocalActivity {
    VocalActivity(regions: [VocalActivity.Region(start: 0, values: [UInt8](repeating: 0, count: Int(analysis.duration / 0.25) + 1))])
}

/// How much an `AVAudioUnitEQ` band set up as the mix sets it lets through at `frequency` (dB):
/// a sine through it, rendered offline, against the sine.
func response(at frequency: Double, _ configure: (AVAudioUnitEQFilterParameters) -> Void) throws -> Double {
    let sampleRate = 44_100.0
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    let frames = Int(2 * sampleRate)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    for channel in 0..<2 {
        for index in 0..<frames {
            buffer.floatChannelData![channel][index] = Float(0.5 * sin(2 * Double.pi * frequency * Double(index) / sampleRate))
        }
    }
    let engine = AVAudioEngine()
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
    let player = AVAudioPlayerNode(), eq = AVAudioUnitEQ(numberOfBands: 1)
    eq.bands[0].bypass = false
    configure(eq.bands[0])
    engine.attach(player)
    engine.attach(eq)
    engine.connect(player, to: eq, format: format)
    engine.connect(eq, to: engine.mainMixerNode, format: format)
    try engine.start()
    player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
    player.play()
    let output = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4_096)!
    var power = 0.0, counted = 0, rendered = 0
    while rendered < Int(1.5 * sampleRate) {
        guard try engine.renderOffline(4_096, to: output) == .success else { break }
        if rendered >= Int(0.5 * sampleRate) {
            for index in 0..<Int(output.frameLength) {
                power += Double(output.floatChannelData![0][index] * output.floatChannelData![0][index])
                counted += 1
            }
        }
        rendered += Int(output.frameLength)
    }
    engine.stop()
    return 10 * log10(power / Double(max(1, counted)) / 0.125 + 1e-12)
}

struct Made {
    let name: String
    let url: URL
    let samples: [Float]
    let analysis: TrackAnalysis
}

@main
struct AutoMixLevelsCheck {
    static func main() async {
        let folder = FileManager.default.temporaryDirectory.appending(path: "automix-levels-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // The filters as the mix uses them (see AutoMixRenderer's Deck): the bass cut is a low shelf at
        // 150 Hz down by 30 dB times the cut, the high-pass sweeps from 20 Hz to 1.2 kHz.
        let probes: [Double] = [30, 40, 50, 63, 80, 100, 125, 150, 200, 250, 315, 400, 500, 800, 1_250, 2_500]
        print("     filter response (dB) at " + probes.map { String(Int($0)) }.joined(separator: ", ") + " Hz:")
        do {
            for gain: Float in [-3, -6, -10, -15, -20, -30] {
                let values = try probes.map { frequency in
                    try response(at: frequency) { band in
                        band.filterType = .lowShelf
                        band.frequency = 150
                        band.gain = gain
                    }
                }
                print("       low shelf 150 Hz \(Int(gain)) dB: " + values.map { String(format: "%.1f", $0) }.joined(separator: " "))
            }
            for sweep in [0.25, 0.5, 0.75, 1.0] {
                let frequency = Float(20 * pow(60, sweep))
                let values = try probes.map { probe in
                    try response(at: probe) { band in
                        band.filterType = .highPass
                        band.frequency = frequency
                    }
                }
                print("       high-pass \(Int(frequency)) Hz: " + values.map { String(format: "%.1f", $0) }.joined(separator: " "))
            }
        } catch {
            expect(false, "filter response measured (\(error))")
        }

        var songs: [String: Made] = [:]
        for (name, samples) in [("bass 124", song(bpm: 124, root: 45, kick: true, bass: true)),
                                ("bass 126", song(bpm: 126, root: 50, kick: true, bass: true)),
                                ("acoustic 100", song(bpm: 100, root: 52, kick: false, bass: false)),
                                ("bass 126, 12 dB down", song(bpm: 126, root: 50, kick: true, bass: true, level: 0.25))] {
            let url = folder.appending(path: "\(songs.count).wav")
            guard (try? write(samples, to: url)) != nil, let analysis = TrackAnalyzer.analyze(samples, sampleRate: rate) else {
                expect(false, "\(name): made and analysed")
                continue
            }
            songs[name] = Made(name: name, url: url, samples: samples, analysis: analysis)
            print("     \(name): \(String(format: "%.1f", analysis.tempo)) BPM, bass \(String(format: "%.2f", analysis.bassShare(0..<analysis.beatCount))), "
                  + "\"Volume uniforme\" \(String(format: "%.1f", 20 * log10(Double(uniformGain(samples))))) dB")
        }

        /// Renders `plan` with and without the limiter and measures it.
        func measure(_ label: String, _ plan: TransitionPlan, _ a: Made, _ b: Made, gains: (Float, Float),
                     context: TransitionContext) async -> MixLevels? {
            let schedule = MixSchedule(plan: plan)
            let url = folder.appending(path: "\(UUID().uuidString).caf"), open = folder.appending(path: "\(UUID().uuidString).caf")
            do {
                let mix = try await AutoMixRenderer.render(schedule, outgoing: a.url, incoming: b.url, outgoingGain: gains.0,
                                                           incomingGain: gains.1, to: url)
                _ = try await AutoMixRenderer.render(schedule, outgoing: a.url, incoming: b.url, outgoingGain: gains.0,
                                                     incomingGain: gains.1, to: open, limiter: false)
                let judge = TransitionJudge(a.analysis, b.analysis, context)
                let levels = try await MixLevels.measure(try Stereo.read(url), unlimited: try Stereo.read(open), schedule: schedule,
                                                         join: mix.join, outgoing: a.url, incoming: b.url, gains: gains, judge: judge)
                let swap = plan.swapStart.map { String(format: ", bass swap %.2f–%.2f", $0, plan.swapEnd ?? $0) } ?? ""
                print("     \(label): \(plan.style.rawValue), \(String(format: "%.1f", plan.overlap)) s\(swap)")
                print("       " + levels.summary)
                return levels
            } catch {
                expect(false, "\(label): rendered and measured (\(error))")
                return nil
            }
        }

        guard let bassA = songs["bass 124"], let bassB = songs["bass 126"], let acoustic = songs["acoustic 100"],
              let quiet = songs["bass 126, 12 dB down"] else { exit(1) }

        // The planner uses this K-weighted/unweighted ratio to predict the level of each
        // song. Check it against filtering the actual samples, including bass below 30 Hz
        // and an acoustic signal, rather than testing it against the planner's own formula.
        for made in [bassA, bassB, acoustic, quiet] {
            let a = made.analysis
            let start = max(0, a.beatTime(0)), end = min(a.duration, a.beatTime(a.beatCount))
            let stereo = Stereo(left: made.samples, right: made.samples, rate: rate)
            let raw = stereo.level(from: start, to: end)
            let actual = stereo.filtered(LevelFilter.kWeighting(rate: rate)).level(from: start, to: end) - raw
            if let heard = a.heard(0..<a.beatCount) {
                let predicted = 10 * log10(max(heard.factor, 1e-12))
                expect(abs(predicted - actual) <= 1,
                       String(format: "%@: K-weighted source estimate %.2f dB, measured %.2f dB", made.name, predicted, actual))
            } else {
                expect(false, "\(made.name): K-weighted source estimate available")
            }
        }

        // AutoMix's own choice, with "Volume uniforme" off and on.
        for (a, b) in [(bassA, bassB), (bassA, acoustic), (bassA, quiet), (quiet, bassA)] {
            for uniform in [false, true] {
                let gains: (Float, Float) = uniform ? (uniformGain(a.samples), uniformGain(b.samples)) : (1, 1)
                let context = TransitionContext(outgoingGain: gains.0, incomingGain: gains.1,
                                                outgoingVocals: instrumental(a.analysis), incomingVocals: instrumental(b.analysis))
                let plan = TransitionPlanner.plan(from: a.analysis, to: b.analysis, context: context)
                let label = "\(a.name) → \(b.name), \"Volume uniforme\" \(uniform ? "on" : "off")"
                guard let levels = await measure(label, plan, a, b, gains: gains, context: context) else { continue }
                expect(abs(levels.takeOver) <= 0.1 && abs(levels.handBack) <= 0.1,
                       "\(label): takes over and hands back at the songs' level")
                expect(levels.limiterAtEnds <= 0.1, "\(label): the limiter leaves the ends alone")
                expect(levels.rise <= 1.5, "\(label): never more than 1.5 dB over the louder song alone")
                // The bass passing over: never far under the bass just before and just after it,
                // nor far over. (In a crossfade each song is at -3 dB half way: so is its bass.)
                if let hole = levels.swapHole, let pile = levels.swapPileUp {
                    let floor = plan.style == .beatMatched ? -2.0 : -3.5
                    expect(hole >= floor && pile <= 3.5, "\(label): the bass passes over without a hole or a pile-up")
                }
                // Beat-matched, the next song comes in without its bass until the swap (a DJ's
                // way): the curves alone overstate it there. Otherwise the filters take little off.
                if plan.style != .beatMatched {
                    expect(levels.dipUnderCurves >= -3.5, "\(label): the filters and trims take at most 3.5 dB off the curves")
                }
                if plan.overlap >= 1.5 {
                    expect(levels.predictionSamples >= 3 && levels.predictionError <= 1 && levels.predictionWorst <= 3,
                           "\(label): the planner knows the one-second loudness (\(levels.predictionSamples) windows)")
                }
            }
        }

        // With the app's equalizer on ("Più bassi", the strongest on the bass), which playback runs
        // on the songs and on the mix alike: the mix still takes over and hands back at their level.
        do {
            let context = TransitionContext(outgoingVocals: instrumental(bassA.analysis), incomingVocals: instrumental(bassB.analysis))
            let plan = TransitionPlanner.plan(from: bassA.analysis, to: bassB.analysis, context: context)
            let schedule = MixSchedule(plan: plan)
            let url = folder.appending(path: "equalized.caf")
            let mix = try await AutoMixRenderer.render(schedule, outgoing: bassA.url, incoming: bassB.url, outgoingGain: 1,
                                                       incomingGain: 1, to: url)
            let gains = EqualizerPreset.bassBooster.gains ?? []
            let levels = try await MixLevels.measure(try Stereo.read(url), unlimited: nil, schedule: schedule, join: mix.join,
                                                     outgoing: bassA.url, incoming: bassB.url, gains: (1, 1),
                                                     judge: TransitionJudge(bassA.analysis, bassB.analysis, context), equalizer: gains)
            print("     equalizer \"Più bassi\": " + levels.summary)
            expect(abs(levels.takeOver) <= 0.1 && abs(levels.handBack) <= 0.1,
                   "equalizer on: the mix takes over and hands back at the songs' level")
        } catch {
            expect(false, "equalizer on: rendered and measured (\(error))")
        }

        // A playlist's Mix: its presets on the bass-rich pair.
        for preset in [MixPreset.auto, .blend, .warm, .rise] {
            let design = MixDesign.preset(preset)
            let plan = MixDesigner.plan(from: bassA.analysis, to: bassB.analysis, design: design)
            let label = "Mix \(preset.rawValue) (\(design.eq.rawValue))"
            guard let levels = await measure(label, plan, bassA, bassB, gains: (1, 1), context: TransitionContext()) else { continue }
            expect(abs(levels.takeOver) <= 0.1 && abs(levels.handBack) <= 0.1, "\(label): takes over and hands back at the songs' level")
            // (A filter on either song takes its bass by design: "rise" sweeps the song leaving up
            // to the swap, a riser.)
            if [.bassSwapCenter, .bassSwapEnd, .bassSwapStart].contains(design.eq), design.filter == .none,
               let hole = levels.swapHole {
                expect(hole >= -3.5, "\(label): the bass passes over without a hole")
            }
        }

        print(failures == 0 ? "AutoMixLevels: all checks passed" : "AutoMixLevels: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
