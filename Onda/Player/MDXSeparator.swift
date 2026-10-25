import Accelerate
import CoreML
import Foundation

enum MDXError: Error {
    case setup
    case badPiece
    case badOutput
}

/// The UVR MDX-Net "Voc_FT" vocal model, run by Core ML on the Neural Engine / GPU.
/// The model works on spectrograms: they are computed here exactly as UVR and sherpa-onnx do
/// (a centred STFT with a periodic Hann window), which CI checks against onnxruntime with
/// Tools/KaraokeCheck. Not thread-safe: use one instance from one thread at a time.
final class MDXSeparator {
    static let sampleRate = 44_100
    private static let fftLength = 6144
    private static let hop = 1024
    /// Frequency bins and time frames the model takes.
    private static let bins = 3072
    private static let frames = 256
    /// Song frames that make up the model's input.
    private static let segmentLength = hop * (frames - 1)
    /// Frames dropped at both ends of the segment, where the STFT has too little context.
    private static let trim = fftLength / 2
    /// The longest piece separated in one go.
    static let maxPieceLength = segmentLength - 2 * trim

    private let model: MLModel
    private let input: MLMultiArray
    private let forward: vDSP_DFT_Setup
    private let inverse: vDSP_DFT_Setup
    private let window: [Float]
    /// window / fftLength: the inverse DFT is unscaled.
    private let synthesisWindow: [Float]
    /// 1 / (sum of the squared windows overlapping each output frame), as torch.istft divides by.
    private let inverseEnvelope: [Float]

    // Work buffers.
    private var segment: [Float]
    private var padded: [Float]
    private var realIn: [Float]
    private var imagIn: [Float]
    private var realOut: [Float]
    private var imagOut: [Float]
    private var overlapAdd: [Float]

    init(modelURL: URL, computeUnits: MLComputeUnits) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        model = try MLModel(contentsOf: modelURL, configuration: configuration)
        input = try MLMultiArray(shape: [1, 4, NSNumber(value: Self.bins), NSNumber(value: Self.frames)],
                                 dataType: .float32)
        let length = vDSP_Length(Self.fftLength)
        guard let forward = vDSP_DFT_zop_CreateSetup(nil, length, .FORWARD),
              let inverse = vDSP_DFT_zop_CreateSetup(nil, length, .INVERSE) else {
            throw MDXError.setup
        }
        self.forward = forward
        self.inverse = inverse

        let n = Self.fftLength
        window = (0..<n).map { 0.5 - 0.5 * Float(cos(2 * Double.pi * Double($0) / Double(n))) }
        synthesisWindow = window.map { $0 / Float(n) }
        let outputLength = n + Self.hop * (Self.frames - 1)
        var envelope = [Float](repeating: 0, count: outputLength)
        for frame in 0..<Self.frames {
            for index in 0..<n { envelope[frame * Self.hop + index] += window[index] * window[index] }
        }
        inverseEnvelope = envelope.map { $0 > 1e-11 ? 1 / $0 : 1 }

        segment = [Float](repeating: 0, count: Self.segmentLength)
        padded = [Float](repeating: 0, count: Self.segmentLength + n)
        realIn = [Float](repeating: 0, count: n)
        imagIn = [Float](repeating: 0, count: n)
        realOut = [Float](repeating: 0, count: n)
        imagOut = [Float](repeating: 0, count: n)
        overlapAdd = [Float](repeating: 0, count: outputLength)
    }

    deinit {
        vDSP_DFT_DestroySetup(forward)
        vDSP_DFT_DestroySetup(inverse)
    }

    /// The vocals of a stereo piece of at most `maxPieceLength` frames, as long as the piece.
    func vocals(left: ArraySlice<Float>, right: ArraySlice<Float>) throws -> (left: [Float], right: [Float]) {
        let count = left.count
        guard count > 0, count <= Self.maxPieceLength, right.count == count else { throw MDXError.badPiece }
        input.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, strides in
            guard let base = buffer.baseAddress else { return }
            analyze(left, channel: 0, into: base, strides: strides)
            analyze(right, channel: 1, into: base, strides: strides)
        }

        let features = try MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(multiArray: input)])
        let result = try model.prediction(from: features)
        guard let output = result.featureValue(for: "output")?.multiArrayValue,
              output.dataType == .float32, output.shape.count == 4 else {
            throw MDXError.badOutput
        }
        let strides = output.strides.map(\.intValue)
        return try output.withUnsafeBufferPointer(ofType: Float.self) { spectrogram in
            guard let base = spectrogram.baseAddress else { throw MDXError.badOutput }
            let leftVocals = synthesize(base, channel: 0, strides: strides, count: count)
            let rightVocals = synthesize(base, channel: 1, strides: strides, count: count)
            return (leftVocals, rightVocals)
        }
    }

    /// Puts the piece in the middle of a silent segment and writes its spectrogram
    /// (real and imaginary parts, the first `bins` bins) into model channels 2c and 2c+1.
    private func analyze(_ samples: ArraySlice<Float>, channel: Int, into input: UnsafeMutablePointer<Float>,
                         strides: [Int]) {
        let n = Self.fftLength
        let half = n / 2
        let length = Self.segmentLength
        segment.withUnsafeMutableBufferPointer { segment in
            segment.update(repeating: 0)
            _ = samples.withUnsafeBufferPointer { source in
                UnsafeMutableBufferPointer(rebasing: segment[Self.trim..<(Self.trim + source.count)])
                    .update(fromContentsOf: source)
            }
            // Reflect padding (as torch.stft with center=True): the edge sample is not repeated.
            padded.withUnsafeMutableBufferPointer { padded in
                for index in 0..<half {
                    padded[index] = segment[half - index]
                    padded[half + length + index] = segment[length - 2 - index]
                }
                _ = UnsafeMutableBufferPointer(rebasing: padded[half..<(half + length)])
                    .update(fromContentsOf: UnsafeBufferPointer(segment))
            }
        }
        let realPlane = (2 * channel) * strides[1]
        let imagPlane = (2 * channel + 1) * strides[1]
        let binStride = strides[2]
        let frameStride = strides[3]
        padded.withUnsafeBufferPointer { padded in
            window.withUnsafeBufferPointer { window in
                realIn.withUnsafeMutableBufferPointer { realIn in
                    imagIn.withUnsafeMutableBufferPointer { imagIn in
                        realOut.withUnsafeMutableBufferPointer { realOut in
                            imagOut.withUnsafeMutableBufferPointer { imagOut in
                                vDSP_vclr(imagIn.baseAddress!, 1, vDSP_Length(n))
                                for frame in 0..<Self.frames {
                                    vDSP_vmul(padded.baseAddress! + frame * Self.hop, 1, window.baseAddress!, 1,
                                              realIn.baseAddress!, 1, vDSP_Length(n))
                                    vDSP_DFT_Execute(forward, realIn.baseAddress!, imagIn.baseAddress!,
                                                     realOut.baseAddress!, imagOut.baseAddress!)
                                    let column = frame * frameStride
                                    for bin in 0..<Self.bins {
                                        input[realPlane + bin * binStride + column] = realOut[bin]
                                        input[imagPlane + bin * binStride + column] = imagOut[bin]
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Inverse STFT of the model's channels 2c and 2c+1 (the missing top bins are zero),
    /// cut back to the piece.
    private func synthesize(_ spectrogram: UnsafePointer<Float>, channel: Int, strides: [Int], count: Int) -> [Float] {
        let n = Self.fftLength
        let realPlane = (2 * channel) * strides[1]
        let imagPlane = (2 * channel + 1) * strides[1]
        overlapAdd.withUnsafeMutableBufferPointer { overlapAdd in
            overlapAdd.update(repeating: 0)
            synthesisWindow.withUnsafeBufferPointer { window in
                realIn.withUnsafeMutableBufferPointer { realIn in
                    imagIn.withUnsafeMutableBufferPointer { imagIn in
                        realOut.withUnsafeMutableBufferPointer { realOut in
                            imagOut.withUnsafeMutableBufferPointer { imagOut in
                                for frame in 0..<Self.frames {
                                    let column = frame * strides[3]
                                    // Bins 0..<bins from the model, n/2 and up mirrored (conjugate),
                                    // so the inverse is real.
                                    for bin in 0..<Self.bins {
                                        realIn[bin] = spectrogram[realPlane + bin * strides[2] + column]
                                        imagIn[bin] = spectrogram[imagPlane + bin * strides[2] + column]
                                    }
                                    realIn[n / 2] = 0
                                    imagIn[n / 2] = 0
                                    imagIn[0] = 0
                                    for bin in 1..<(n / 2) {
                                        realIn[n - bin] = realIn[bin]
                                        imagIn[n - bin] = -imagIn[bin]
                                    }
                                    vDSP_DFT_Execute(inverse, realIn.baseAddress!, imagIn.baseAddress!,
                                                     realOut.baseAddress!, imagOut.baseAddress!)
                                    let target = overlapAdd.baseAddress! + frame * Self.hop
                                    vDSP_vma(realOut.baseAddress!, 1, window.baseAddress!, 1, target, 1,
                                             target, 1, vDSP_Length(n))
                                }
                            }
                        }
                    }
                }
            }
        }
        // Centre trim (n/2) plus the segment's own trim.
        let start = n / 2 + Self.trim
        var vocals = [Float](repeating: 0, count: count)
        overlapAdd.withUnsafeBufferPointer { overlapAdd in
            inverseEnvelope.withUnsafeBufferPointer { envelope in
                vocals.withUnsafeMutableBufferPointer { vocals in
                    vDSP_vmul(overlapAdd.baseAddress! + start, 1, envelope.baseAddress! + start, 1,
                              vocals.baseAddress!, 1, vDSP_Length(count))
                }
            }
        }
        return vocals
    }
}
