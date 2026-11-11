import Accelerate
import CoreML
import Foundation

/// Beat This! (F. Foscarin, J. Schlüter, G. Widmer, CPJKU, Johannes Kepler University Linz, ISMIR 2024;
/// code and weights under the MIT licence, see THIRD_PARTY_NOTICES.md): a neural beat tracker. Its
/// small0 model, converted to Core ML by CI (Tools/convert_beat_model.py), gives every log-mel frame
/// of a song (50 a second) how likely a beat and a downbeat are there. AutoMix takes its bars and the
/// stretches it beat-matches on from it (see `SegueSong`): Seaglass's own analysis finds a song's
/// tempo, but on real songs it can't often tell which beats hold steady enough to mix on, nor where
/// the bars start. Foundation, Accelerate and Core ML only, so CI's check compiles it on its own.
final class BeatThis: @unchecked Sendable {
    /// The beats and downbeats of a song, seconds; each downbeat's logit (how sure the model is).
    struct Result: Sendable, Equatable {
        var beats: [Double]
        var downbeats: [Double]
        var downbeatLogits: [Float]
    }

    enum Failure: Error { case input, output }

    /// The model's fixed input (as upstream's inference splits a song) and the frames at each chunk's
    /// edges that are left out (it wasn't trained on them).
    static let chunk = 1_500
    static let border = 6
    static let mels = 128
    static let framesPerSecond = 50.0

    private let model: MLModel
    private let input: MLMultiArray
    private let lock = NSLock()

    /// The model is in the app (CI converts it; a local build without that step has none).
    static var isBundled: Bool { Bundle.main.url(forResource: "BeatThis", withExtension: "mlmodelc", subdirectory: "BeatThis") != nil }

    /// The app's model, loaded the first time it is asked for; nil without it (a build without CI's
    /// conversion) or when it can't load.
    static let shared: BeatThis? = {
        guard let url = Bundle.main.url(forResource: "BeatThis", withExtension: "mlmodelc", subdirectory: "BeatThis") else { return nil }
        return try? BeatThis(modelURL: url)
    }()

    init(modelURL: URL, computeUnits: MLComputeUnits = .all) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        model = try MLModel(contentsOf: modelURL, configuration: configuration)
        input = try MLMultiArray(shape: [1, NSNumber(value: Self.chunk), NSNumber(value: Self.mels)], dataType: .float32)
    }

    /// The beats and downbeats of a song: mono samples at 22,050 Hz.
    func analyze(_ mono: [Float]) throws -> Result {
        let (spect, frames) = BeatThisFrontEnd.spectrogram(mono)
        let (beat, downbeat) = try logits(spect, frames: frames)
        return Self.result(beat: beat, downbeat: downbeat)
    }

    /// The beat and downbeat logits of every frame of a spectrogram (`frames` × 128, a frame per row),
    /// run in chunks as upstream's inference does: chunks of 1,500 frames from 6 frames before the
    /// start, overlapping by 12, the last one ending 6 frames after the end; each frame taken from the
    /// first chunk that keeps it (6 frames are left out at each edge of a chunk), zeros outside the song.
    func logits(_ spect: [Float], frames: Int) throws -> (beat: [Float], downbeat: [Float]) {
        guard frames > 0, spect.count == frames * Self.mels else { throw Failure.input }
        var beat = [Float](repeating: -1_000, count: frames)
        var downbeat = [Float](repeating: -1_000, count: frames)
        let starts = Self.chunkStarts(frames: frames)
        lock.lock()
        defer { lock.unlock() }
        let pointer = input.dataPointer.assumingMemoryBound(to: Float.self)
        // Later chunks first: an earlier one overwrites what they share.
        for start in starts.reversed() {
            pointer.update(repeating: 0, count: Self.chunk * Self.mels)
            for row in 0..<Self.chunk {
                let frame = start + row
                guard frame >= 0, frame < frames else { continue }
                spect.withUnsafeBufferPointer { values in
                    (pointer + row * Self.mels).update(from: values.baseAddress! + frame * Self.mels, count: Self.mels)
                }
            }
            let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["spect": MLFeatureValue(multiArray: input)]))
            guard let beats = output.featureValue(for: "beat")?.multiArrayValue,
                  let downbeats = output.featureValue(for: "downbeat")?.multiArrayValue,
                  beats.count >= Self.chunk, downbeats.count >= Self.chunk else { throw Failure.output }
            for row in Self.border..<(Self.chunk - Self.border) {
                let frame = start + row
                guard frame >= 0, frame < frames else { continue }
                beat[frame] = Self.value(beats, row)
                downbeat[frame] = Self.value(downbeats, row)
            }
        }
        return (beat, downbeat)
    }

    /// Where each chunk starts, in frames (negative: before the song).
    static func chunkStarts(frames: Int) -> [Int] {
        var starts = Array(stride(from: -border, to: frames - border, by: chunk - 2 * border))
        if frames > chunk - 2 * border, !starts.isEmpty { starts[starts.count - 1] = frames - (chunk - border) }
        return starts
    }

    /// The `index`th value of a (1, chunk) output, whatever its element type.
    private static func value(_ array: MLMultiArray, _ index: Int) -> Float {
        let stride = array.strides.last?.intValue ?? 1
        switch array.dataType {
        case .float32: return array.dataPointer.assumingMemoryBound(to: Float.self)[index * stride]
        case .double: return Float(array.dataPointer.assumingMemoryBound(to: Double.self)[index * stride])
        default: return array[index * stride].floatValue
        }
    }

    // MARK: Peaks

    /// The frames whose logit is over 0 and the largest within 70 ms (±3 frames; on a tie the first),
    /// neighbouring frames merged into their mean, then moved by a parabola through the logits around
    /// them (a frame is 20 ms: the beat lies between frames). Frame positions, with their logits.
    static func peaks(_ logits: [Float]) -> [(frame: Double, logit: Float)] {
        var found: [(frame: Double, logit: Float, count: Int)] = []
        for index in logits.indices where logits[index] > 0 {
            let value = logits[index]
            var top = true
            for other in max(0, index - 3)...min(logits.count - 1, index + 3) where other != index {
                if logits[other] > value || (logits[other] == value && other < index) { top = false; break }
            }
            guard top else { continue }
            if let last = found.last, Double(index) - last.frame <= 1 {
                let count = last.count + 1
                found[found.count - 1] = (last.frame + (Double(index) - last.frame) / Double(count), max(last.logit, value), count)
            } else {
                found.append((Double(index), value, 1))
            }
        }
        return found.map { peak in
            let index = Int(peak.frame.rounded())
            guard peak.count == 1, index > 0, index + 1 < logits.count else { return (peak.frame, peak.logit) }
            let before = logits[index - 1], at = logits[index], after = logits[index + 1]
            let curvature = before - 2 * at + after
            let shift = curvature < 0 ? max(-0.5, min(0.5, Double(0.5 * (before - after) / curvature))) : 0
            return (Double(index) + shift, peak.logit)
        }
    }

    /// The beats and downbeats from the logits: each downbeat moved onto its nearest beat, as upstream
    /// does, keeping its logit; two downbeats on one beat keep the surer one.
    static func result(beat: [Float], downbeat: [Float]) -> Result {
        let beats = peaks(beat).map { $0.frame / framesPerSecond }
        var downbeats: [Double] = [], logits: [Float] = []
        for peak in peaks(downbeat) {
            var time = peak.frame / framesPerSecond
            if !beats.isEmpty {
                var low = 0, high = beats.count - 1
                while high - low > 1 {
                    let middle = (low + high) / 2
                    if beats[middle] <= time { low = middle } else { high = middle }
                }
                time = abs(beats[low] - time) <= abs(beats[high] - time) ? beats[low] : beats[high]
            }
            if let last = downbeats.last, last == time {
                logits[logits.count - 1] = max(logits[logits.count - 1], peak.logit)
            } else {
                downbeats.append(time)
                logits.append(peak.logit)
            }
        }
        return Result(beats: beats, downbeats: downbeats, downbeatLogits: logits)
    }
}

/// Beat This!'s input, as upstream computes it (torchaudio's MelSpectrogram): mono audio at 22,050 Hz,
/// a 1,024-point STFT with a periodic Hann window every 441 samples (50 frames a second), centred
/// frames with the signal reflected at its edges, magnitudes divided by √1024, 128 triangular mel
/// bands (Slaney's scale, unnormalised) from 30 Hz to 11 kHz, then log(1 + 1000 x).
enum BeatThisFrontEnd {
    static let sampleRate = 22_050.0
    static let fftLength = 1_024
    static let hop = 441
    static let mels = 128

    /// The spectrogram, a frame per row of 128 values, and its number of frames.
    static func spectrogram(_ mono: [Float]) -> (values: [Float], frames: Int) {
        let count = mono.count
        guard count > fftLength / 2 else { return ([], 0) }
        let frames = 1 + count / hop
        let half = fftLength / 2
        let bins = half + 1
        var values = [Float](repeating: 0, count: frames * mels)
        guard let setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(fftLength), .FORWARD) else { return ([], 0) }
        defer { vDSP_DFT_DestroySetup(setup) }
        let window = (0..<fftLength).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(fftLength))) }
        let bank = filterBank
        var inReal = [Float](repeating: 0, count: fftLength), inImag = [Float](repeating: 0, count: fftLength)
        var outReal = [Float](repeating: 0, count: fftLength), outImag = [Float](repeating: 0, count: fftLength)
        var magnitude = [Float](repeating: 0, count: bins)
        let scale = 1 / Float(fftLength).squareRoot()
        for frame in 0..<frames {
            for i in 0..<fftLength {
                var at = frame * hop + i - half
                // Reflected at the edges, the edge sample itself not repeated (torch's "reflect").
                while at < 0 || at >= count { at = at < 0 ? -at : 2 * (count - 1) - at }
                inReal[i] = mono[at] * window[i]
            }
            vDSP_DFT_Execute(setup, inReal, inImag, &outReal, &outImag)
            for k in 0..<bins { magnitude[k] = (outReal[k] * outReal[k] + outImag[k] * outImag[k]).squareRoot() * scale }
            for band in 0..<mels {
                let (first, weights) = bank[band]
                var sum: Float = 0
                for (offset, weight) in weights.enumerated() { sum += magnitude[first + offset] * weight }
                values[frame * mels + band] = log1p(1_000 * sum)
            }
        }
        return (values, frames)
    }

    /// Each band's first frequency bin and its weights from there (torchaudio's melscale_fbanks).
    static let filterBank: [(first: Int, weights: [Float])] = {
        let bins = fftLength / 2 + 1
        func mel(_ hz: Double) -> Double { hz < 1_000 ? hz / (200.0 / 3) : 15 + log(hz / 1_000) / (log(6.4) / 27) }
        func hz(_ mel: Double) -> Double { mel < 15 ? mel * (200.0 / 3) : 1_000 * exp((mel - 15) * (log(6.4) / 27)) }
        let low = mel(30), high = mel(11_000)
        let points = (0..<(mels + 2)).map { hz(low + (high - low) * Double($0) / Double(mels + 1)) }
        let frequencies = (0..<bins).map { Double($0) * sampleRate / 2 / Double(bins - 1) }
        return (0..<mels).map { band in
            var first = -1
            var weights: [Float] = []
            for (bin, frequency) in frequencies.enumerated() {
                let rising = (frequency - points[band]) / (points[band + 1] - points[band])
                let falling = (points[band + 2] - frequency) / (points[band + 2] - points[band + 1])
                let weight = max(0, min(rising, falling))
                if weight > 0 {
                    if first < 0 { first = bin }
                    weights.append(Float(weight))
                } else if first >= 0 {
                    break
                }
            }
            return (max(0, first), weights)
        }
    }()
}
