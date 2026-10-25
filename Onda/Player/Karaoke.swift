import AVFoundation
import MediaToolbox

enum KaraokeMode: Int32, CaseIterable, Identifiable {
    case off = 0
    case noVocals = 1
    case vocalsOnly = 2

    var id: Self { self }

    var title: String {
        switch self {
        case .off: return "Normale"
        case .noVocals: return "Senza voce"
        case .vocalsOnly: return "Solo voce"
        }
    }

    var symbol: String {
        switch self {
        case .off: return "music.note"
        case .noVocals: return "mic.slash"
        case .vocalsOnly: return "music.mic"
        }
    }
}

/// Settings read by the audio render thread on every buffer: plain scalars, no locking needed.
final class KaraokeControl: @unchecked Sendable {
    static let shared = KaraokeControl()
    var mode: Int32 = 0
    /// 0 = original, 1 = fully processed.
    var amount: Float = 1
}

/// Vocal removal / isolation done on the stereo signal, the classic karaoke trick:
/// lead vocals are usually mixed in the centre, so they cancel in the side signal (left − right)
/// and dominate the mid signal (left + right) between roughly 200 Hz and 6 kHz.
/// Apple Music Sing separates stems with machine learning; this is lighter and works best on songs
/// with centred vocals.
enum KaraokeEngine {
    /// Adds the karaoke processing to an item's audio (nothing happens while the mode is `.off`).
    @MainActor
    static func attach(to item: AVPlayerItem) async {
        guard item.audioMix == nil,
              let track = try? await item.asset.loadTracks(withMediaType: .audio).first,
              item.audioMix == nil else { return }

        let state = KaraokeTapState()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(state).toOpaque()),
            init: karaokeTapInit,
            finalize: karaokeTapFinalize,
            prepare: karaokeTapPrepare,
            unprepare: karaokeTapUnprepare,
            process: karaokeTapProcess)
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                         kMTAudioProcessingTapCreationFlag_PreEffects, &tap) == noErr,
              let tap else {
            // The tap never took ownership of the state.
            Unmanaged.passUnretained(state).release()
            return
        }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        item.audioMix = mix
    }

    @MainActor
    static func detach(from item: AVPlayerItem?) {
        item?.audioMix = nil
    }
}

/// Per-item filter state, owned by the tap.
private final class KaraokeTapState {
    private var isFloat = false
    private var nonInterleaved = false
    private var channels = 0

    private var bassCoefficient: Float = 0
    private var lowCutCoefficient: Float = 0
    private var highCutCoefficient: Float = 0
    private var bass: Float = 0
    private var lowCut: Float = 0
    private var highCut: Float = 0

    func prepare(_ format: AudioStreamBasicDescription) {
        isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        channels = Int(format.mChannelsPerFrame)
        let rate = Float(format.mSampleRate > 0 ? format.mSampleRate : 44_100)
        bassCoefficient = Self.coefficient(cutoff: 160, rate: rate)
        lowCutCoefficient = Self.coefficient(cutoff: 220, rate: rate)
        highCutCoefficient = Self.coefficient(cutoff: 6_000, rate: rate)
        bass = 0
        lowCut = 0
        highCut = 0
    }

    /// One-pole low-pass coefficient.
    private static func coefficient(cutoff: Float, rate: Float) -> Float {
        1 - exp(-2 * Float.pi * cutoff / rate)
    }

    func process(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        let mode = KaraokeControl.shared.mode
        guard mode != 0, isFloat, channels == 2, frames > 0 else { return }
        let amount = KaraokeControl.shared.amount
        let buffers = UnsafeMutableAudioBufferListPointer(list)

        if nonInterleaved {
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return }
            let count = min(frames, Int(buffers[0].mDataByteSize) / 4, Int(buffers[1].mDataByteSize) / 4)
            for i in 0..<count {
                let output = processFrame(left[i], right[i], mode: mode, amount: amount)
                left[i] = output.0
                right[i] = output.1
            }
        } else {
            guard buffers.count >= 1, let samples = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return }
            let count = min(frames, Int(buffers[0].mDataByteSize) / 8)
            for i in 0..<count {
                let output = processFrame(samples[2 * i], samples[2 * i + 1], mode: mode, amount: amount)
                samples[2 * i] = output.0
                samples[2 * i + 1] = output.1
            }
        }
    }

    @inline(__always)
    private func processFrame(_ left: Float, _ right: Float, mode: Int32, amount: Float) -> (Float, Float) {
        let mid = 0.5 * (left + right)
        let side = 0.5 * (left - right)
        let outLeft: Float
        let outRight: Float
        if mode == 1 {
            // No vocals: keep the side signal, plus the bass from the centre so the song keeps its low end.
            bass += bassCoefficient * (mid - bass)
            outLeft = side * 1.4 + bass
            outRight = -side * 1.4 + bass
        } else {
            // Vocals only: the centre, band-limited to the voice range.
            lowCut += lowCutCoefficient * (mid - lowCut)
            let highPassed = mid - lowCut
            highCut += highCutCoefficient * (highPassed - highCut)
            outLeft = highCut * 1.3
            outRight = outLeft
        }
        return (left + amount * (outLeft - left), right + amount * (outRight - right))
    }
}

// MARK: Tap callbacks (C function pointers: no captures)

private let karaokeTapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, storageOut in
    storageOut.pointee = clientInfo
}

private let karaokeTapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    Unmanaged<KaraokeTapState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private let karaokeTapPrepare: MTAudioProcessingTapPrepareCallback = { tap, _, format in
    Unmanaged<KaraokeTapState>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
        .takeUnretainedValue()
        .prepare(format.pointee)
}

private let karaokeTapUnprepare: MTAudioProcessingTapUnprepareCallback = { _ in }

private let karaokeTapProcess: MTAudioProcessingTapProcessCallback = { tap, frameCount, _, bufferList, frameCountOut, flagsOut in
    guard MTAudioProcessingTapGetSourceAudio(tap, frameCount, bufferList, flagsOut, nil, frameCountOut) == noErr else {
        return
    }
    Unmanaged<KaraokeTapState>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
        .takeUnretainedValue()
        .process(bufferList, frames: Int(frameCountOut.pointee))
}
