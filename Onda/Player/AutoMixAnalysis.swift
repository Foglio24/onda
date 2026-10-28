import Accelerate
import Foundation

/// What AutoMix knows about a song, worked out once from its audio (see `TrackAnalyzer`) and kept
/// on disk: where the sound starts and ends, its beat grid, how loud, how rhythmic, how steady and
/// how bass-heavy each beat is, the harmony of each bar, and its key.
struct TrackAnalysis: Codable, Equatable, Sendable {
    /// Raised whenever the analysis changes, so older results are made again.
    static let currentVersion = 2
    /// Seconds between the values of `loudness`.
    static let loudnessStep = 0.25

    var version = TrackAnalysis.currentVersion
    var duration: Double
    /// Where the sound starts and ends: the silence before and after is left out of transitions.
    var soundStart: Double
    var soundEnd: Double
    /// The beat grid: beat n falls at `gridStart + n × beatLength` seconds. Beat 0 is the first one
    /// at the start of the sound.
    var gridStart: Double
    var beatLength: Double
    /// Share of the song's strong onsets within 15 ms of the grid: near 1 for music made to a click
    /// (most pop, dance and hip-hop), low for songs played freely.
    var gridFit: Double
    /// Beats n with (n - downbeat) divisible by 4 start a bar.
    var downbeat: Int
    /// For each beat of the grid inside the sound: its loudness (dB) and how strongly it is marked
    /// (1 is a typical strong beat, near 0 no beat at all).
    var beatLoudness: [Float]
    var beatPulse: [Float]
    /// Loudness (dB) every `loudnessStep` seconds, and the loudness of the song's main parts.
    var loudness: [Float]
    var bodyLoudness: Float
    /// Key: pitch class (0 = C … 11 = B) and mode, with how clearly it showed (correlation, 0…1).
    var key: Int
    var minor: Bool
    var keyClarity: Double
    /// For each beat: the share of its sound below 150 Hz (kick drum and bass), 0…255 for 0…1.
    var beatBass: [UInt8]
    /// For each beat: how far (ms, ±100) the strongest onset near it falls from the grid. A stretch
    /// whose marked beats sit on the grid can be beat-matched there; live and freely played songs
    /// drift away from a constant grid in places.
    var beatOffset: [Int8]
    /// Each bar's pitch classes (12 values, 0…255, the strongest 255), bar k starting on beat
    /// `firstBarBeat + 4k`: the harmony of a stretch, for what two songs sound like together.
    var barChroma: [UInt8]

    var tempo: Double { 60 / beatLength }
    var beatCount: Int { beatLoudness.count }
    /// Made to a steady grid that beats can be matched to.
    var isGridLocked: Bool { gridFit >= 0.65 }

    func beatTime(_ beat: Int) -> Double { gridStart + Double(beat) * beatLength }

    func isDownbeat(_ beat: Int) -> Bool { ((beat - downbeat) % 4 + 4) % 4 == 0 }

    /// The first beat at or after a time.
    func beat(atOrAfter time: Double) -> Int { Int(((time - gridStart) / beatLength).rounded(.up)) }

    /// Average pulse of the beats in a range (clamped to the song's beats); 0 when there are none.
    func pulse(_ beats: Range<Int>) -> Float {
        let range = beats.clamped(to: 0..<beatPulse.count)
        guard !range.isEmpty else { return 0 }
        return beatPulse[range].reduce(0, +) / Float(range.count)
    }

    /// Loudness (dB) around a time.
    func level(at time: Double) -> Float {
        guard !loudness.isEmpty else { return -100 }
        let index = Int(time / Self.loudnessStep)
        return loudness[max(0, min(loudness.count - 1, index))]
    }

    /// Mean power (linear) between two times, from `loudness`; 0 outside the sound.
    func power(from start: Double, to end: Double) -> Double {
        guard !loudness.isEmpty else { return 0 }
        let first = max(0, min(loudness.count - 1, Int(start / Self.loudnessStep)))
        let last = max(first + 1, min(loudness.count, Int((end / Self.loudnessStep).rounded(.up))))
        let total = loudness[first..<last].reduce(0.0) { $0 + pow(10, Double($1) / 10) }
        return total / Double(last - first)
    }

    /// The first beat of the first whole bar (bars start every four beats from it).
    var firstBarBeat: Int { ((downbeat % 4) + 4) % 4 }

    /// The share (0…1) of the sound below 150 Hz over a range of beats, weighted by their power.
    func bassShare(_ beats: Range<Int>) -> Double {
        let range = beats.clamped(to: 0..<min(beatBass.count, beatLoudness.count))
        guard !range.isEmpty else { return 0 }
        var weighted = 0.0, total = 0.0
        for beat in range {
            let power = pow(10, Double(beatLoudness[beat]) / 10)
            weighted += power * Double(beatBass[beat]) / 255
            total += power
        }
        return total > 0 ? weighted / total : 0
    }

    /// How steady a range of beats is: the share of its beats clearly marked (pulse at least half
    /// a typical strong beat's), and the share of those within 20 ms of the grid.
    func timing(_ beats: Range<Int>) -> (marked: Double, onGrid: Double) {
        let range = beats.clamped(to: 0..<min(beatPulse.count, beatOffset.count))
        guard !range.isEmpty else { return (0, 0) }
        let marked = range.filter { beatPulse[$0] >= 0.5 }
        guard !marked.isEmpty else { return (0, 0) }
        let onGrid = marked.filter { abs(Int(beatOffset[$0])) <= 20 }.count
        return (Double(marked.count) / Double(range.count), Double(onGrid) / Double(marked.count))
    }

    /// The average pitch classes (each 0…1) of the bars between two times.
    func chroma(from start: Double, to end: Double) -> [Double] {
        var sum = [Double](repeating: 0, count: 12)
        let bars = barChroma.count / 12
        guard bars > 0 else { return sum }
        let barLength = 4 * beatLength
        let origin = beatTime(firstBarBeat)
        let first = max(0, min(bars - 1, Int(((start - origin) / barLength).rounded(.down))))
        let last = max(first + 1, min(bars, Int(((end - origin) / barLength).rounded(.up))))
        for bar in first..<last {
            for pitch in 0..<12 { sum[pitch] += Double(barChroma[bar * 12 + pitch]) / 255 }
        }
        return sum.map { $0 / Double(last - first) }
    }
}

/// Works out a `TrackAnalysis` from a song's samples (mono, ideally 22 050 Hz): beats are found as
/// DJ software does, from where the sound changes (with the kick drum counting extra), a tempo
/// estimate, beat tracking by dynamic programming (Ellis, 2007) and a constant-tempo grid fitted
/// through the strongest beats. The key comes from the song's average chroma (Krumhansl–Kessler).
enum TrackAnalyzer {
    /// The rate the app decodes songs to for analysis.
    static let sampleRate = 22_050.0

    private static let frameLength = 1024
    private static let hop = 256
    private static let bandCount = 36
    private static let lowWeight: Float = 0.5

    static func analyze(_ samples: [Float], sampleRate: Double) -> TrackAnalysis? {
        let duration = Double(samples.count) / sampleRate
        guard duration >= 20 else { return nil }
        let level = loudness(samples, sampleRate: sampleRate)
        let frameRate = sampleRate / Double(hop)
        let curves = onsets(samples, sampleRate: sampleRate)
        guard curves.full.count > Int(frameRate * 10) else { return nil }
        let first = max(0, min(curves.full.count - 1, Int(level.soundStart * frameRate)))
        let last = max(first + 1, min(curves.full.count, Int(level.soundEnd * frameRate)))
        let sound = first..<last
        let onset = combined(curves, sound: sound)

        // Without a beat to follow, a grid at 120 BPM that nothing fits: crossfades still use the
        // song's silences and loudness.
        let period = tempoPeriod(onset, sound: sound, frameRate: frameRate) ?? frameRate / 2
        var grid = trackBeats(onset, period: period, sound: sound, frameRate: frameRate).flatMap {
            fitGrid(beats: $0, onset: onset, period: period, sound: sound, frameRate: frameRate)
        } ?? Grid(start: Double(first), period: period, fit: 0)
        // A grid outside 40–260 BPM (or not a number) can only be a failed fit.
        let shortest = 60 * frameRate / 260, longest = 60 * frameRate / 40
        if !grid.period.isFinite || !grid.start.isFinite || grid.period < shortest || grid.period > longest {
            grid = Grid(start: Double(first), period: frameRate / 2, fit: 0)
        }

        // Seconds from onset frames: an onset frame stands for the middle of its window.
        let toSeconds = { (frame: Double) -> Double in (frame * Double(hop) + Double(frameLength / 2)) / sampleRate }
        let beatLength = grid.period * Double(hop) / sampleRate
        let anchor = toSeconds(grid.start)
        let shift = ((level.soundStart - 0.25 * beatLength - anchor) / beatLength).rounded(.up)
        let gridStart = anchor + shift * beatLength
        let beatCount = max(0, Int(((level.soundEnd - gridStart) / beatLength).rounded(.up)))
        guard beatCount >= 16 else { return nil }

        let frameOf = { (time: Double) -> Int in
            Int(((time * sampleRate - Double(frameLength / 2)) / Double(hop)).rounded())
        }
        // The first beat can fall a little before the file starts: only frames inside it count.
        func peak(_ curve: [Float], near time: Double) -> Float {
            let centre = frameOf(time)
            let lower = max(0, centre - 2), upper = min(curve.count, centre + 3)
            guard lower < upper else { return 0 }
            return curve[lower..<upper].max() ?? 0
        }
        let rawPulse = (0..<beatCount).map { peak(onset, near: gridStart + Double($0) * beatLength) }
        let reference = max(percentile(rawPulse, 0.75), 1e-6)
        let beatPulse = rawPulse.map { $0 / reference }
        let beatLoudness = (0..<beatCount).map { beat -> Float in
            let start = gridStart + Double(beat) * beatLength
            return level.decibels(from: start, to: start + beatLength)
        }

        let chroma = Chroma(samples, sampleRate: sampleRate)
        let key = chroma.key(from: level.soundStart, to: level.soundEnd)
        let lowPulse = (0..<beatCount).map { peak(curves.low, near: gridStart + Double($0) * beatLength) }
        let downbeat = downbeatPhase(lowPulse: lowPulse, loudness: beatLoudness, chroma: chroma,
                                     gridStart: gridStart, beatLength: beatLength)

        // Each beat's share of bass, from the frames inside it.
        let beatBass = (0..<beatCount).map { beat -> UInt8 in
            let start = max(0, frameOf(gridStart + Double(beat) * beatLength))
            let end = min(curves.totalPower.count, max(start + 1, frameOf(gridStart + Double(beat + 1) * beatLength)))
            guard start < end else { return 0 }
            let low = curves.lowPower[start..<end].reduce(0, +), total = curves.totalPower[start..<end].reduce(0, +)
            return UInt8(max(0, min(255, (total > 0 ? low / total : 0) * 255)).rounded())
        }
        // Where the strongest onset near each beat falls: within a tenth of a second (a quarter
        // of a beat at fast tempos).
        let reach = max(1, min(Int(0.1 * frameRate), Int(0.25 * grid.period)))
        let beatOffset = (0..<beatCount).map { beat -> Int8 in
            let exact = ((gridStart + Double(beat) * beatLength) * sampleRate - Double(frameLength / 2)) / Double(hop)
            let centre = Int(exact.rounded())
            let lower = max(1, centre - reach), upper = min(onset.count - 1, centre + reach + 1)
            guard lower < upper else { return 100 }
            var best = lower
            for index in lower..<upper where onset[index] > onset[best] { best = index }
            let shift = parabolicShift(onset[(best - 1)...(best + 1)].map(Double.init), at: 1)
            let milliseconds = (Double(best) + shift - exact) / frameRate * 1000
            return Int8(max(-100, min(100, milliseconds.rounded())))
        }
        // Each bar's harmony.
        let firstBar = ((downbeat % 4) + 4) % 4
        var barChroma: [UInt8] = []
        var bar = firstBar
        while bar + 4 <= beatCount {
            let values = chroma.average(from: gridStart + Double(bar) * beatLength, to: gridStart + Double(bar + 4) * beatLength)
            let peak = max(values.max() ?? 0, 1e-6)
            barChroma += values.map { UInt8(max(0, min(255, $0 / peak * 255)).rounded()) }
            bar += 4
        }

        return TrackAnalysis(duration: duration, soundStart: level.soundStart, soundEnd: level.soundEnd,
                             gridStart: gridStart, beatLength: beatLength, gridFit: grid.fit, downbeat: downbeat,
                             beatLoudness: beatLoudness, beatPulse: beatPulse, loudness: level.envelope,
                             bodyLoudness: level.body, key: key.tonic, minor: key.minor, keyClarity: key.clarity,
                             beatBass: beatBass, beatOffset: beatOffset, barChroma: barChroma)
    }

    // MARK: Loudness and silence

    private struct Level {
        /// Mean power every `fineStep` seconds.
        let fine: [Double]
        let fineStep: Double
        let envelope: [Float]
        let body: Float
        let soundStart: Double
        let soundEnd: Double

        func decibels(from start: Double, to end: Double) -> Float {
            let first = max(0, Int(start / fineStep))
            let last = min(fine.count, max(first + 1, Int(end / fineStep)))
            guard first < last else { return -100 }
            let power = fine[first..<last].reduce(0, +) / Double(last - first)
            return Float(10 * log10(power + 1e-12))
        }
    }

    private static func loudness(_ samples: [Float], sampleRate: Double) -> Level {
        let length = max(1, Int(sampleRate * 0.01))
        let step = Double(length) / sampleRate
        let count = samples.count / length
        var fine = [Double](repeating: 0, count: count)
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for index in 0..<count {
                var sum: Float = 0
                vDSP_svesq(base + index * length, 1, &sum, vDSP_Length(length))
                fine[index] = Double(sum) / Double(length)
            }
        }
        let per = max(1, Int((TrackAnalysis.loudnessStep / step).rounded()))
        var envelope: [Float] = []
        var start = 0
        while start + per <= count {
            let power = fine[start..<start + per].reduce(0, +) / Double(per)
            envelope.append(Float(10 * log10(power + 1e-12)))
            start += per
        }
        let body = percentile(envelope, 0.7)
        let threshold = max(Double(body) - 38, -70)
        let duration = Double(samples.count) / sampleRate
        let first = fine.firstIndex { 10 * log10($0 + 1e-12) >= threshold }
        let last = fine.lastIndex { 10 * log10($0 + 1e-12) >= threshold }
        let soundStart = first.map { max(0, Double($0) * step - 0.01) } ?? 0
        let soundEnd = last.map { min(duration, Double($0 + 1) * step) } ?? duration
        return Level(fine: fine, fineStep: step, envelope: envelope, body: body,
                     soundStart: soundStart, soundEnd: max(soundStart + 1, soundEnd))
    }

    // MARK: Onsets

    /// How much the sound grows at each frame: over all bands, and over the bands below 150 Hz
    /// (the kick drum and the bass).
    private struct Curves {
        var full: [Float]
        var low: [Float]
        /// Each frame's power below 150 Hz, and in all bands.
        var lowPower: [Float] = []
        var totalPower: [Float] = []
    }

    private static func onsets(_ samples: [Float], sampleRate: Double) -> Curves {
        let length = frameLength
        let half = length / 2
        guard samples.count >= length else { return Curves(full: [], low: []) }
        let frames = 1 + (samples.count - length) / hop
        let log2n = vDSP_Length(10)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return Curves(full: [], low: []) }
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: length)
        vDSP_hann_window(&window, vDSP_Length(length), Int32(vDSP_HANN_NORM))

        // 36 bands spaced evenly in pitch from 30 Hz to 8 kHz; bands too narrow for any bin are left out.
        let edges = (0...bandCount).map { 30 * pow(8_000.0 / 30, Double($0) / Double(bandCount)) }
        let binWidth = sampleRate / Double(length)
        var bandOfBin = [Int](repeating: -1, count: half)
        for bin in 1..<half {
            let frequency = Double(bin) * binWidth
            if let band = (0..<bandCount).first(where: { frequency >= edges[$0] && frequency < edges[$0 + 1] }) {
                bandOfBin[bin] = band
            }
        }
        let used = Array(Set(bandOfBin.filter { $0 >= 0 })).sorted()
        guard !used.isEmpty else { return Curves(full: [], low: []) }
        var position = [Int](repeating: -1, count: bandCount)
        for (index, band) in used.enumerated() { position[band] = index }
        bandOfBin = bandOfBin.map { $0 >= 0 ? position[$0] : -1 }
        let bands = used.count
        let isLow = used.map { sqrt(edges[$0] * edges[$0 + 1]) < 150 }
        let lowCount = max(1, isLow.filter { $0 }.count)

        var levels = [Float](repeating: 0, count: frames * bands)
        var lowPower = [Float](repeating: 0, count: frames)
        var totalPower = [Float](repeating: 0, count: frames)
        var frame = [Float](repeating: 0, count: length)
        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)
        var bandPower = [Float](repeating: 0, count: bands)
        samples.withUnsafeBufferPointer { input in
            guard let base = input.baseAddress else { return }
            for index in 0..<frames {
                vDSP_vmul(base + index * hop, 1, window, 1, &frame, 1, vDSP_Length(length))
                real.withUnsafeMutableBufferPointer { realPointer in
                    imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                        var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                        frame.withUnsafeBufferPointer { framePointer in
                            framePointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                                vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                            }
                        }
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
                    }
                }
                for band in 0..<bands { bandPower[band] = 0 }
                for bin in 1..<half where bandOfBin[bin] >= 0 { bandPower[bandOfBin[bin]] += power[bin] }
                for band in 0..<bands {
                    levels[index * bands + band] = 10 * log10(bandPower[band] + 1e-10)
                    totalPower[index] += bandPower[band]
                    if isLow[band] { lowPower[index] += bandPower[band] }
                }
            }
        }
        // Nothing counts below 80 dB under the loudest band.
        let floor = (levels.max() ?? 0) - 80
        for index in levels.indices where levels[index] < floor { levels[index] = floor }

        var full = [Float](repeating: 0, count: frames)
        var low = [Float](repeating: 0, count: frames)
        if frames > 1 {
            for index in 1..<frames {
                var sum: Float = 0
                var lowSum: Float = 0
                let row = index * bands, previous = (index - 1) * bands
                for band in 0..<bands {
                    let rise = levels[row + band] - levels[previous + band]
                    if rise > 0 {
                        sum += rise
                        if isLow[band] { lowSum += rise }
                    }
                }
                full[index] = sum / Float(bands)
                low[index] = lowSum / Float(lowCount)
            }
        }
        // Only what stands out from the last second counts.
        let width = max(1, Int(sampleRate / Double(hop)))
        return Curves(full: detrended(full, width: width), low: detrended(low, width: width),
                      lowPower: lowPower, totalPower: totalPower)
    }

    private static func detrended(_ values: [Float], width: Int) -> [Float] {
        var sums = [Double](repeating: 0, count: values.count + 1)
        for (index, value) in values.enumerated() { sums[index + 1] = sums[index] + Double(value) }
        return values.indices.map { index in
            let lower = max(0, index - width / 2)
            let upper = min(values.count, index - width / 2 + width)
            let mean = Float((sums[upper] - sums[lower]) / Double(width))
            return max(0, values[index] - mean)
        }
    }

    /// The onset curve beats are found on: all bands, plus the low bands at half weight, each
    /// scaled by how much it varies inside the sound.
    private static func combined(_ curves: Curves, sound: Range<Int>) -> [Float] {
        let fullScale = max(standardDeviation(curves.full, in: sound), 1e-9)
        let lowScale = max(standardDeviation(curves.low, in: sound), 1e-9)
        return zip(curves.full, curves.low).map { $0 / fullScale + lowWeight * $1 / lowScale }
    }

    // MARK: Tempo and beats

    /// The beat length in onset frames: the strongest repetition of the onsets between 55 and 210
    /// BPM, preferring tempos near 120.
    private static func tempoPeriod(_ onset: [Float], sound: Range<Int>, frameRate: Double) -> Double? {
        let slice = Array(onset[sound])
        let mean = slice.reduce(0, +) / Float(max(1, slice.count))
        let centred = slice.map { $0 - mean }
        let minLag = Int(60 * frameRate / 210)
        let maxLag = Int(60 * frameRate / 55) + 2
        guard centred.count > maxLag * 4 else { return nil }
        var scores: [Double] = []
        centred.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for lag in minLag...maxLag {
                var dot: Float = 0
                vDSP_dotpr(base, 1, base + lag, 1, &dot, vDSP_Length(centred.count - lag))
                let correlation = Double(dot) / Double(centred.count - lag)
                let bpm = 60 * frameRate / Double(lag)
                let prior = exp(-0.5 * pow(log2(bpm / 120) / 0.9, 2))
                scores.append(max(correlation, 0) * prior)
            }
        }
        guard let best = scores.indices.max(by: { scores[$0] < scores[$1] }), scores[best] > 0 else { return nil }
        return Double(minLag + best) + parabolicShift(scores, at: best)
    }

    /// Beat frames (fractional) through the song by dynamic programming: each beat as strong as
    /// possible, the gaps as close as possible to `period`.
    private static func trackBeats(_ onset: [Float], period: Double, sound: Range<Int>,
                                   frameRate: Double) -> [Double]? {
        let count = onset.count
        let scale = max(standardDeviation(onset, in: sound), 1e-9)
        let radius = Int(period)
        let kernel = (-radius...radius).map { Float(exp(-0.5 * pow(Double($0) * 32 / period, 2))) }
        var local = [Float](repeating: 0, count: count)
        for index in 0..<count {
            var sum: Float = 0
            for (offset, weight) in kernel.enumerated() {
                let source = index + offset - radius
                if source >= 0, source < count { sum += onset[source] / scale * weight }
            }
            local[index] = sum
        }

        let shortest = Int((period / 2).rounded()) + 1
        let longest = Int((2 * period).rounded())
        guard longest > shortest else { return nil }
        let penalty = (0...longest).map { $0 == 0 ? 0 : 100 * pow(log(Double($0) / period), 2) }
        var score = [Double](repeating: 0, count: count)
        var previous = [Int](repeating: -1, count: count)
        for index in 0..<count {
            var best = -Double.infinity
            var from = -1
            if index >= shortest {
                for gap in shortest...min(longest, index) {
                    let value = score[index - gap] - penalty[gap]
                    if value > best {
                        best = value
                        from = index - gap
                    }
                }
            }
            score[index] = Double(local[index]) + (from >= 0 ? best : 0)
            previous[index] = from
        }

        var peaks: [Int] = []
        if count > 2 {
            for index in 1..<(count - 1) where score[index] > score[index - 1] && score[index] >= score[index + 1] {
                peaks.append(index)
            }
        }
        guard !peaks.isEmpty else { return nil }
        let middle = median(peaks.map { score[$0] })
        guard let last = peaks.last(where: { score[$0] >= 0.5 * middle }) else { return nil }
        var beats = [last]
        while let head = beats.last, previous[head] >= 0 { beats.append(previous[head]) }
        beats.reverse()

        // Weak beats at either end are guesses through silence or an intro without rhythm.
        let rms = sqrt(local.reduce(0) { $0 + $1 * $1 } / Float(max(1, count)))
        guard let firstStrong = beats.firstIndex(where: { local[$0] >= 0.5 * rms }),
              let lastStrong = beats.lastIndex(where: { local[$0] >= 0.5 * rms }) else { return nil }
        let lower = Double(sound.lowerBound) - 0.05 * frameRate
        let upper = Double(sound.upperBound) + 0.05 * frameRate
        let refined = beats[firstStrong...lastStrong].map { frame -> Double in
            guard frame > 0, frame < count - 1 else { return Double(frame) }
            let around = [Double(local[frame - 1]), Double(local[frame]), Double(local[frame + 1])]
            return Double(frame) + max(-0.5, min(0.5, parabolicShift(around, at: 1)))
        }.filter { $0 >= lower && $0 <= upper }
        return refined.count >= 16 ? refined : nil
    }

    private struct Grid {
        var start: Double
        var period: Double
        var fit: Double
    }

    /// A constant-tempo grid through the strong beats. Three starting points (the beats' own
    /// spacing, and the onsets' repetition with two ways of placing it) are each refined by least
    /// squares, and the one whose grid the strong onsets follow most closely wins.
    private static func fitGrid(beats: [Double], onset: [Float], period: Double, sound: Range<Int>,
                                frameRate: Double) -> Grid? {
        let strength = beats.map { frame -> Float in
            let index = Int(frame.rounded(.down))
            let lower = max(0, index - 1), upper = min(onset.count, index + 2)
            guard lower < upper else { return 0 }
            return onset[lower..<upper].max() ?? 0
        }
        let middle = median(strength.map(Double.init))
        let strong = strength.map { Double($0) >= middle }
        let gaps = zip(beats.dropFirst(), beats).map { $0 - $1 }
        let spacing = median(gaps)
        guard spacing > 0 else { return nil }

        func circularStart(_ period: Double) -> Double {
            var re = 0.0, im = 0.0
            for index in beats.indices where strong[index] {
                let angle = 2 * Double.pi * beats[index] / period
                re += Double(strength[index]) * cos(angle)
                im += Double(strength[index]) * sin(angle)
            }
            return positiveRemainder(atan2(im, re) / (2 * Double.pi) * period, period)
        }

        let comb = combFit(onset, around: period, sound: sound)
        var starts = [(spacing, circularStart(spacing))]
        if let comb { starts += [(comb.period, circularStart(comb.period)), (comb.period, comb.start)] }
        let grids = starts.map { candidate -> Grid in
            let refined = refine(beats, strong: strong, period: candidate.0, start: candidate.1)
            let fit = onsetFit(onset, sound: sound, period: refined.period, start: refined.start, frameRate: frameRate)
            return Grid(start: refined.start, period: refined.period, fit: fit)
        }
        return grids.max { $0.fit < $1.fit }
    }

    /// The beat length (within 3 % of `period`) at which the onsets repeat most strongly, and where
    /// that repetition lands.
    private static func combFit(_ onset: [Float], around period: Double, sound: Range<Int>) -> (period: Double, start: Double)? {
        let candidates = 601
        func sum(_ period: Double) -> (re: Double, im: Double) {
            let step = -2 * Double.pi / period
            let rotationRe = cos(step), rotationIm = sin(step)
            let first = Double(sound.lowerBound) * step
            var zRe = cos(first), zIm = sin(first)
            var re = 0.0, im = 0.0
            for index in sound {
                let value = Double(onset[index])
                re += value * zRe
                im += value * zIm
                let nextRe = zRe * rotationRe - zIm * rotationIm
                zIm = zRe * rotationIm + zIm * rotationRe
                zRe = nextRe
            }
            return (re, im)
        }
        /// The candidate at a (fractional) position: from 3 % shorter to 3 % longer than `period`.
        func candidate(_ position: Double) -> Double {
            let change: Double = -0.03 + 0.06 * position / Double(candidates - 1)
            return period * (1 + change)
        }
        let periods: [Double] = (0..<candidates).map { candidate(Double($0)) }
        let magnitudes = periods.map { candidate -> Double in
            let value = sum(candidate)
            return (value.re * value.re + value.im * value.im).squareRoot()
        }
        guard let best = magnitudes.indices.max(by: { magnitudes[$0] < magnitudes[$1] }) else { return nil }
        let refined = candidate(Double(best) + parabolicShift(magnitudes, at: best))
        let value = sum(refined)
        let start = positiveRemainder(-atan2(value.im, value.re) / (2 * Double.pi) * refined, refined)
        return (refined, start)
    }

    /// Least squares through the strong beats within a tenth of a beat of the grid, four times over.
    private static func refine(_ beats: [Double], strong: [Bool], period: Double, start: Double) -> (period: Double, start: Double) {
        var period = period, start = start
        for _ in 0..<4 {
            var count = 0.0, sumN = 0.0, sumT = 0.0, sumNN = 0.0, sumNT = 0.0
            for index in beats.indices where strong[index] {
                let n = ((beats[index] - start) / period).rounded()
                guard abs(beats[index] - (start + n * period)) < 0.1 * period else { continue }
                count += 1
                sumN += n
                sumT += beats[index]
                sumNN += n * n
                sumNT += n * beats[index]
            }
            let denominator = count * sumNN - sumN * sumN
            guard count >= 16, denominator != 0 else { break }
            period = (count * sumNT - sumN * sumT) / denominator
            start = (sumT - period * sumN) / count
        }
        return (period, start)
    }

    /// Share of the strong onsets near each grid beat that fall within 15 ms of it.
    private static func onsetFit(_ onset: [Float], sound: Range<Int>, period: Double, start: Double,
                                 frameRate: Double) -> Double {
        guard period > 1 else { return 0 }
        let first = Int(((Double(sound.lowerBound) - start) / period).rounded(.up))
        let last = Int(((Double(sound.upperBound) - start) / period).rounded(.down))
        guard last > first else { return 0 }
        var deviations: [Double] = []
        var strengths: [Double] = []
        for beat in first..<last {
            let centre = start + Double(beat) * period
            let lower = Int((centre - 0.25 * period).rounded(.down))
            let upper = Int((centre + 0.25 * period).rounded(.down)) + 1
            guard lower >= 1, upper < onset.count - 1 else { continue }
            var peak = lower
            for index in lower..<upper where onset[index] > onset[peak] { peak = index }
            let shift = parabolicShift(onset[(peak - 1)...(peak + 1)].map(Double.init), at: 1)
            deviations.append((Double(peak) + shift - centre) / frameRate)
            strengths.append(Double(onset[peak]))
        }
        guard !strengths.isEmpty else { return 0 }
        let middle = median(strengths)
        let strong = strengths.indices.filter { strengths[$0] >= middle }
        guard !strong.isEmpty else { return 0 }
        return Double(strong.filter { abs(deviations[$0]) < 0.015 }.count) / Double(strong.count)
    }

    // MARK: Bars

    /// Which beat of four starts a bar: the one where the low bands hit hardest, the harmony
    /// changes and the loudness changes, on average through the song.
    private static func downbeatPhase(lowPulse: [Float], loudness: [Float], chroma: Chroma,
                                      gridStart: Double, beatLength: Double) -> Int {
        let count = lowPulse.count
        guard count >= 8 else { return 0 }
        let beatChroma = (0..<count).map { chroma.average(from: gridStart + Double($0) * beatLength,
                                                          to: gridStart + Double($0 + 1) * beatLength) }
        var harmony = [Double](repeating: 0, count: count)
        var change = [Double](repeating: 0, count: count)
        for beat in 1..<count {
            harmony[beat] = 1 - cosine(beatChroma[beat], beatChroma[beat - 1])
            change[beat] = Double(abs(loudness[beat] - loudness[beat - 1]))
        }
        let low = standardized(lowPulse.map(Double.init))
        let harmonic = standardized(harmony)
        let loud = standardized(change)
        let combined = (0..<count).map { low[$0] + harmonic[$0] + 0.5 * loud[$0] }
        let scores = (0..<4).map { phase -> Double in
            let values = stride(from: phase, to: count, by: 4).map { combined[$0] }
            return values.reduce(0, +) / Double(max(1, values.count))
        }
        return scores.indices.max { scores[$0] < scores[$1] } ?? 0
    }

    // MARK: Helpers

    static func percentile(_ values: [Float], _ fraction: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let position = fraction * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(sorted.count - 1, lower + 1)
        let weight = Float(position - Double(lower))
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    private static func standardDeviation(_ values: [Float], in range: Range<Int>) -> Float {
        let range = range.clamped(to: 0..<values.count)
        guard range.count > 1 else { return 0 }
        let mean = values[range].reduce(0, +) / Float(range.count)
        let variance = values[range].reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(range.count - 1)
        return variance.squareRoot()
    }

    private static func standardized(_ values: [Double]) -> [Double] {
        guard values.count > 1 else { return values.map { _ in 0 } }
        let mean = values.reduce(0, +) / Double(values.count)
        let deviation = (values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)).squareRoot()
        return values.map { ($0 - mean) / (deviation + 1e-9) }
    }

    private static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for index in 0..<min(a.count, b.count) {
            dot += a[index] * b[index]
            normA += a[index] * a[index]
            normB += b[index] * b[index]
        }
        return Double(dot / ((normA * normB).squareRoot() + 1e-9))
    }

    /// Where the true peak lies between samples, from a parabola through the peak and its neighbours.
    private static func parabolicShift(_ values: [Double], at index: Int) -> Double {
        guard index > 0, index < values.count - 1 else { return 0 }
        let left = values[index - 1], centre = values[index], right = values[index + 1]
        let denominator = left - 2 * centre + right
        guard denominator < 0 else { return 0 }
        return 0.5 * (left - right) / denominator
    }

    private static func positiveRemainder(_ value: Double, _ divisor: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: divisor)
        return remainder < 0 ? remainder + divisor : remainder
    }
}

/// The song's pitch classes over time (4096-sample frames), for its key and its harmony changes.
private struct Chroma {
    private static let length = 4096
    /// 12 values per frame, each frame scaled so its strongest pitch class is 1.
    private var values: [Float] = []
    private var frameDuration = 0.0
    private(set) var frames = 0

    init(_ samples: [Float], sampleRate: Double) {
        let length = Self.length
        let half = length / 2
        frames = samples.count / length
        frameDuration = Double(length) / sampleRate
        guard frames > 0 else { return }
        let log2n = vDSP_Length(12)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            frames = 0
            return
        }
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: length)
        vDSP_hann_window(&window, vDSP_Length(length), Int32(vDSP_HANN_NORM))
        var pitchClass = [Int](repeating: -1, count: half)
        for bin in 1..<half {
            let frequency = Double(bin) * sampleRate / Double(length)
            guard frequency >= 80, frequency <= 2_000 else { continue }
            let note = Int((12 * log2(frequency / 440) + 69).rounded())
            pitchClass[bin] = ((note % 12) + 12) % 12
        }
        var table = [Float](repeating: 0, count: frames * 12)
        var frame = [Float](repeating: 0, count: length)
        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        var magnitude = [Float](repeating: 0, count: half)
        samples.withUnsafeBufferPointer { input in
            guard let base = input.baseAddress else { return }
            for index in 0..<frames {
                vDSP_vmul(base + index * length, 1, window, 1, &frame, 1, vDSP_Length(length))
                real.withUnsafeMutableBufferPointer { realPointer in
                    imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                        var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                        frame.withUnsafeBufferPointer { framePointer in
                            framePointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                                vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                            }
                        }
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvabs(&split, 1, &magnitude, 1, vDSP_Length(half))
                    }
                }
                var classes = [Float](repeating: 0, count: 12)
                for bin in 1..<half where pitchClass[bin] >= 0 { classes[pitchClass[bin]] += magnitude[bin] }
                let peak = (classes.max() ?? 0) + 1e-9
                for pitch in 0..<12 { table[index * 12 + pitch] = classes[pitch] / peak }
            }
        }
        values = table
    }

    /// The average chroma between two times (the frame at `start` when none ends inside).
    func average(from start: Double, to end: Double) -> [Float] {
        guard frames > 0 else { return [Float](repeating: 0, count: 12) }
        let first = max(0, min(frames - 1, Int(start / frameDuration)))
        let last = max(first + 1, min(frames, Int(end / frameDuration)))
        var sum = [Float](repeating: 0, count: 12)
        for index in first..<last {
            for pitch in 0..<12 { sum[pitch] += values[index * 12 + pitch] }
        }
        return sum.map { $0 / Float(last - first) }
    }

    /// The key whose profile best matches the song's average chroma.
    func key(from start: Double, to end: Double) -> (tonic: Int, minor: Bool, clarity: Double) {
        KeyProfile.key(of: average(from: start, to: end).map(Double.init))
    }
}

/// Keys from pitch classes, by the Krumhansl–Kessler profiles.
enum KeyProfile {
    private static let major: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    private static let minor: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    /// The key whose profile best matches the pitch classes, with how well it does (0…1).
    static func key(of profile: [Double]) -> (tonic: Int, minor: Bool, clarity: Double) {
        var best = (tonic: 0, minor: false, clarity: -2.0)
        for tonic in 0..<12 {
            for (isMinor, shape) in [(false, major), (true, minor)] {
                let rotated = (0..<12).map { shape[(($0 - tonic) % 12 + 12) % 12] }
                let value = correlation(profile, rotated)
                if value > best.clarity { best = (tonic, isMinor, value) }
            }
        }
        return (best.tonic, best.minor, max(0, best.clarity))
    }

    static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let meanA = a.reduce(0, +) / Double(a.count), meanB = b.reduce(0, +) / Double(b.count)
        var covariance = 0.0, varianceA = 0.0, varianceB = 0.0
        for index in a.indices {
            covariance += (a[index] - meanA) * (b[index] - meanB)
            varianceA += (a[index] - meanA) * (a[index] - meanA)
            varianceB += (b[index] - meanB) * (b[index] - meanB)
        }
        return covariance / ((varianceA * varianceB).squareRoot() + 1e-12)
    }
}
