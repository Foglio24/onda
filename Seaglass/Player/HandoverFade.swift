import AVFoundation
import os

/// Fades a song out at an exact moment of its own time, inside the player's audio processing (a
/// tap, see `EqualizerTap`), for AutoMix's handover: the song goes down sample by sample while the
/// mix comes up over the same stretch of the music (its audio mix ramps it in), so the two always
/// add up to the song. It doesn't depend on the output's latency or on the main thread. The
/// player's own `volume` can't do this: it applies to the sound as it is made, which AirPods play
/// a fifth of a second later (AirPlay two seconds later), while the mix's ramp follows the music
/// as it is heard.
final class HandoverFader: @unchecked Sendable {
    /// How long the song and the mix cross at the handover when the song fades out here: short. The
    /// two players are never on the very same sample, and the same music a few milliseconds apart,
    /// half and half, partly cancels out: over a quarter of a second that was heard as the volume
    /// dipping by 2–4 dB (with the players 1–5 ms apart); over 40 ms it is under 1 dB, and brief.
    static let exactLength = 0.04
    /// With the player's volume instead (no fader: Dolby, or a song started before AutoMix was on),
    /// whose timing is only as good as the output's latency is known: longer.
    static let volumeLength = 0.25

    /// Where to cross within `from`…`to` seconds of `samples` (mono, at `rate`): the start of the
    /// quietest stretch `length` long. What partly cancels out there (the players a few milliseconds
    /// apart) is the least heard: between the beats rather than on a kick.
    static func quietMoment(in samples: [Float], rate: Double, from: Double, to: Double, length: Double) -> Double {
        let first = max(0, Int((from * rate).rounded(.up))), last = min(samples.count, Int(to * rate))
        let span = max(1, Int(length * rate))
        guard last - first > span else { return from }
        var energy = 0.0
        for index in first..<(first + span) { energy += Double(samples[index] * samples[index]) }
        var best = (start: first, energy: energy)
        for start in (first + 1)...(last - span) {
            let entering = samples[start + span - 1], leaving = samples[start - 1]
            energy += Double(entering * entering) - Double(leaving * leaving)
            if energy < best.energy { best = (start, energy) }
        }
        return Double(best.start) / rate
    }

    /// Where the fade starts in the song's time (infinity: never) and how long it lasts.
    struct Fade: Equatable, Sendable {
        var start = Double.infinity
        var length = 0.25
    }

    private struct State {
        var fade = Fade()
        /// The song's time at the end of the audio processed last (none yet: -infinity).
        var processed = -Double.infinity
        /// When the first audio went through (host ticks; 0 before).
        var firstTicks: UInt64 = 0
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    /// Fades the song out from `start` over `length` seconds of its own time. False, changing
    /// nothing, unless its audio processing is running now (the song being at `now`) and hasn't
    /// reached `start` yet (it runs a little ahead of what is heard).
    func fadeOut(at start: Double, over length: Double, now: Double) -> Bool {
        lock.withLock { state -> Bool in
            guard state.processed >= now - 0.25, state.processed < start - 0.1 else { return false }
            state.fade = Fade(start: start, length: max(0.001, length))
            return true
        }
    }

    /// How far ahead of `now` (the song's time being heard) its audio processing has gone: more with
    /// AirPods, and when iOS works in bigger steps with the screen locked. Nil unless it is running.
    func ahead(of now: Double) -> Double? {
        lock.withLock { state -> Double? in
            state.processed >= now - 0.25 ? max(0, state.processed - now) : nil
        }
    }

    /// When its audio first went through (system uptime), for the startup timings in Settings →
    /// Diagnostica: the sound is heard the output's latency later.
    var firstProcessed: TimeInterval? {
        let ticks = lock.withLock { state -> UInt64 in state.firstTicks }
        guard ticks > 0 else { return nil }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }

    /// On the audio thread: fades `frames` frames of 32-bit float audio that start at the song's
    /// `time`. `fade` holds the values read last, used when the lock is busy (it is never waited for).
    func process(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int, time: Double,
                 sampleRate: Double, fade: inout Fade) {
        guard frames > 0, sampleRate > 0, time.isFinite else { return }
        let end = time + Double(frames) / sampleRate
        if let current = lock.withLockIfAvailable({ state -> Fade in
            state.processed = end
            if state.firstTicks == 0 { state.firstTicks = mach_absolute_time() }
            return state.fade
        }) {
            fade = current
        }
        guard end > fade.start else { return }
        let stop = fade.start + fade.length
        for buffer in buffers {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let channels = max(1, Int(buffer.mNumberChannels))
            let count = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels))
            if time >= stop {
                data.update(repeating: 0, count: count * channels)
                continue
            }
            // Straight down, as the mix comes straight up: the same music, so the two add up to it.
            for frame in 0..<count {
                let gain = Float(max(0, min(1, (stop - (time + Double(frame) / sampleRate)) / fade.length)))
                guard gain < 1 else { continue }
                for channel in 0..<channels { data[frame * channels + channel] *= gain }
            }
        }
    }
}
