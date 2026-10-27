import AVFoundation
import Combine
import MediaToolbox
import os

/// The equalizer's settings (Settings → Audio → Equalizzatore, or the player's ··· menu), saved
/// between launches. Songs that are playing follow changes to the curve right away.
@MainActor
final class Equalizer: ObservableObject {
    static let shared = Equalizer()

    @Published var isOn: Bool {
        didSet {
            save()
            // Adds or removes the equalizer on the song that is playing.
            PlayerController.shared.applyAudioEffectsPreference()
        }
    }
    @Published private(set) var preset: EqualizerPreset
    /// The six band gains in decibels: the preset's, or the user's own with `custom`.
    @Published private(set) var gains: [Float]
    /// The user's own curve, kept when another preset is picked.
    @Published private(set) var customGains: [Float]

    private init() {
        let saved = Self.saved
        isOn = saved.isOn
        preset = saved.preset
        customGains = saved.custom
        gains = saved.gains
    }

    func select(_ preset: EqualizerPreset) {
        self.preset = preset
        gains = preset.gains ?? customGains
        if !isOn { isOn = true }
        save()
    }

    /// Dragging a point of the curve makes it the user's own.
    func setGain(_ value: Float, band: Int) {
        guard gains.indices.contains(band) else { return }
        let rounded = (max(-EqualizerBands.limit, min(EqualizerBands.limit, value)) * 2).rounded() / 2
        guard rounded != gains[band] || preset != .custom else { return }
        if preset != .custom { customGains = gains }
        customGains[band] = rounded
        preset = .custom
        gains = customGains
        if !isOn { isOn = true }
        save()
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(isOn, forKey: Preferences.equalizerOn)
        defaults.set(preset.rawValue, forKey: Preferences.equalizerPreset)
        defaults.set(customGains, forKey: Preferences.equalizerCustom)
        EqualizerParameters.shared.set(isOn: isOn, gains: gains)
    }

    /// The settings as saved, read before the equalizer screen is ever opened.
    nonisolated static var saved: (isOn: Bool, preset: EqualizerPreset, custom: [Float], gains: [Float]) {
        let defaults = UserDefaults.standard
        let preset = defaults.string(forKey: Preferences.equalizerPreset).flatMap(EqualizerPreset.init) ?? .flat
        var custom = (defaults.array(forKey: Preferences.equalizerCustom) as? [NSNumber])?.map(\.floatValue) ?? []
        if custom.count != EqualizerBands.count { custom = Array(repeating: 0, count: EqualizerBands.count) }
        return (defaults.bool(forKey: Preferences.equalizerOn), preset, custom, preset.gains ?? custom)
    }
}

/// What the audio taps read: whether the equalizer is on and its band gains. Written on the main
/// thread, read on the audio thread without ever waiting (see `EqualizerProcessor`).
final class EqualizerParameters: @unchecked Sendable {
    struct Snapshot: Sendable {
        var version = 0
        var isOn = false
        var gains = SIMD8<Float>()
    }

    static let shared = EqualizerParameters()

    private let lock: OSAllocatedUnfairLock<Snapshot>

    private init() {
        let saved = Equalizer.saved
        lock = OSAllocatedUnfairLock(initialState: Snapshot(version: 1, isOn: saved.isOn,
                                                            gains: Self.vector(saved.gains)))
    }

    var isOn: Bool { lock.withLock { $0.isOn } }

    func set(isOn: Bool, gains: [Float]) {
        let vector = Self.vector(gains)
        lock.withLock { state in
            state.version += 1
            state.isOn = isOn
            state.gains = vector
        }
    }

    /// The current values, or nil while they are being changed: the audio thread then keeps the
    /// previous ones for one more buffer instead of waiting.
    func snapshotIfAvailable() -> Snapshot? {
        lock.withLockIfAvailable { $0 }
    }

    private static func vector(_ gains: [Float]) -> SIMD8<Float> {
        var vector = SIMD8<Float>()
        for (band, gain) in gains.prefix(EqualizerBands.count).enumerated() { vector[band] = gain }
        return vector
    }
}

/// Runs the equalizer on one track's audio, inside the player's audio processing: nothing here
/// waits or allocates while audio flows.
final class EqualizerProcessor {
    private static let maxChannels = 8
    private let parameters: EqualizerParameters
    private let sections = UnsafeMutablePointer<Biquad>.allocate(capacity: EqualizerBands.count)
    /// Two values of filter memory per section and channel.
    private let memory = UnsafeMutablePointer<Double>.allocate(capacity: maxChannels * EqualizerBands.count * 2)
    private var memoryCount: Int { Self.maxChannels * EqualizerBands.count * 2 }
    private var sampleRate = 44_100.0
    private var isFloat = false
    private var version = -1
    private var isActive = false
    private var preamp: Float = 1

    init(parameters: EqualizerParameters) {
        self.parameters = parameters
        sections.initialize(repeating: .identity, count: EqualizerBands.count)
        memory.initialize(repeating: 0, count: Self.maxChannels * EqualizerBands.count * 2)
    }

    deinit {
        sections.deallocate()
        memory.deallocate()
    }

    func prepare(format: AudioStreamBasicDescription) {
        isFloat = format.mFormatID == kAudioFormatLinearPCM
            && format.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.mBitsPerChannel == 32
        sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 44_100
        version = -1
        memory.update(repeating: 0, count: memoryCount)
    }

    func process(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
        guard isFloat else { return }
        if let snapshot = parameters.snapshotIfAvailable(), snapshot.version != version {
            version = snapshot.version
            let wasActive = isActive
            isActive = snapshot.isOn && snapshot.gains != SIMD8<Float>()
            EqualizerDesign.fill(sections, gains: snapshot.gains, sampleRate: sampleRate)
            preamp = EqualizerDesign.preamp(snapshot.gains)
            if !wasActive { memory.update(repeating: 0, count: memoryCount) }
        }
        guard isActive else { return }
        var channel = 0
        for buffer in buffers {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let interleaved = max(1, Int(buffer.mNumberChannels))
            let count = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * interleaved))
            for offset in 0..<interleaved where channel < Self.maxChannels {
                run(data + offset, count: count, stride: interleaved,
                    memory: memory + channel * EqualizerBands.count * 2)
                channel += 1
            }
        }
    }

    /// Transposed direct form II, one section after the other, in place.
    private func run(_ samples: UnsafeMutablePointer<Float>, count: Int, stride: Int,
                     memory: UnsafeMutablePointer<Double>) {
        if preamp != 1 {
            var index = 0
            while index < count {
                samples[index * stride] *= preamp
                index += 1
            }
        }
        for band in 0..<EqualizerBands.count {
            let filter = sections[band]
            if filter == .identity { continue }
            var z1 = memory[band * 2], z2 = memory[band * 2 + 1]
            var index = 0
            while index < count {
                let x = Double(samples[index * stride])
                let y = filter.b0 * x + z1
                z1 = filter.b1 * x - filter.a1 * y + z2
                z2 = filter.b2 * x - filter.a2 * y
                samples[index * stride] = Float(y)
                index += 1
            }
            memory[band * 2] = z1
            memory[band * 2 + 1] = z2
        }
    }
}

/// An audio processing tap that runs an `EqualizerProcessor` on a track of an AVPlayerItem.
enum EqualizerTap {
    static func make() -> MTAudioProcessingTap? {
        let processor = EqualizerProcessor(parameters: .shared)
        let context = Unmanaged.passRetained(processor).toOpaque()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: context,
            init: { _, clientInfo, storage in storage.pointee = clientInfo },
            finalize: { tap in
                Unmanaged<EqualizerProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                Unmanaged<EqualizerProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue().prepare(format: format.pointee)
            },
            unprepare: { _ in },
            process: { tap, frames, _, buffers, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, nil, framesOut) == noErr
                else { return }
                Unmanaged<EqualizerProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue()
                    .process(UnsafeMutableAudioBufferListPointer(buffers), frames: Int(framesOut.pointee))
            })
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                                kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr, let tap else {
            Unmanaged<EqualizerProcessor>.fromOpaque(context).release()
            return nil
        }
        return tap
    }
}

/// A song's audio mix: the "Volume uniforme" gain and the equalizer.
enum AudioEffects {
    /// Nil when neither changes anything.
    static func mix(for item: AVPlayerItem, gain: Float) async -> AVAudioMix? {
        let equalizer = EqualizerParameters.shared.isOn
        guard gain < 0.999 || equalizer,
              let tracks = try? await item.asset.loadTracks(withMediaType: .audio), !tracks.isEmpty else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = tracks.map { track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            if gain < 0.999 { parameters.setVolume(gain, at: .zero) }
            if equalizer { parameters.audioTapProcessor = EqualizerTap.make() }
            return parameters
        }
        return mix
    }
}
