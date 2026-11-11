import Foundation
import os
#if canImport(CoreAudio)
import CoreAudio // UnsafeMutableAudioBufferListPointer: AVFoundation brings it on iOS, not on a Mac
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

/// One song's side of a transition, played inside its player's audio processing (`EqualizerTap`):
/// each block of samples gets the level, the three bands and the filters its lanes give at that
/// block's place in the song. The place comes from the samples' own time, so what is heard follows
/// the music, whatever the output's latency. Unarmed, it leaves the samples untouched.
///
/// Real time: the program (the lanes, flattened) and the filters' state live in memory allocated
/// once; a new plan comes in under a lock the audio thread only tries (`withLockIfAvailable`), and
/// nothing on that thread allocates, waits, logs or reads a file.
final class SegueStage: @unchecked Sendable {
    // MARK: Program layout

    static let maxKnots = 40
    static let maxChannels = 8
    /// Automation is read every this many frames, the gain interpolated in between.
    static let blockFrames = 64
    /// The lanes' order in the program (level, low shelf, middle, high shelf, low-pass, high-pass, echo).
    private static let targetOrder: [SegueLane.Target] = [.level, .lowShelf, .mid, .highShelf, .lowPass, .highPass, .echo]
    private static let laneStride = 1 + 4 * maxKnots
    private static let headerCount = 8
    private static let programCount = headerCount + 7 * laneStride
    /// The echo's repeats: how much of each comes back, and the send's low cut (Hz) that keeps their
    /// bass from building up.
    static let echoFeedback = 0.5
    static let echoLowCut = 250.0

    // Header slots.
    private enum Header {
        static let version = 0
        /// 0: off; 1: playing its lanes; 2: going back to plain from where it is.
        static let mode = 1
        /// The song's own time where the window starts.
        static let anchor = 2
        /// The window's length in the song's own time.
        static let span = 3
        /// Seconds of the song's own time the return to plain takes.
        static let release = 4
        /// The echo's delay, seconds (0: the plan has none).
        static let echoDelay = 5
    }

    private let lock = OSAllocatedUnfairLock()
    /// Written on the main thread under `lock`, copied by the audio thread when its version changes.
    private let pending: UnsafeMutablePointer<Double>
    /// The audio thread's own copy.
    private let active: UnsafeMutablePointer<Double>
    private var nextVersion = 1.0

    // Audio thread state.
    private var sampleRate = 44_100.0
    private var channels = 2
    private var isFloat = false
    /// Five filters (low shelf, middle bell, high shelf, low-pass, high-pass) × 2 state values, per channel.
    private let memory: UnsafeMutablePointer<Double>
    private let filterCount = 5
    private let coefficients: UnsafeMutablePointer<FilterCoefficients>
    private var lastValues = (lowShelf: 0.0, mid: 0.0, highShelf: 0.0, lowPass: 20_000.0, highPass: 20.0)
    private var gain = 1.0
    /// While going back to plain: the values it leaves from and where (song time) it started.
    private var releaseFrom: (level: Double, lowShelf: Double, mid: Double, highShelf: Double, lowPass: Double, highPass: Double,
                              echo: Double)?
    private var releaseStart = 0.0
    private var lastProcessed = -Double.infinity
    /// The echo's delay line, a ring of `echoCapacity` frames per channel (allocated in `prepare`, off
    /// the audio thread), its write position, and per channel the send's low-cut state (input, output).
    private var echoLine: UnsafeMutablePointer<Float>?
    private var echoCapacity = 0
    private var echoPosition = 0
    private let echoCut: UnsafeMutablePointer<Double>
    private var echoCutCoefficient = 0.0
    private var echoSend = 0.0
    /// The song time at the end of the last block processed (read by the main thread, unsynchronised:
    /// a Double written whole by one thread).
    private(set) var processedTime = -Double.infinity
    /// How many times the samples didn't follow on from the last ones (a seek, or the player
    /// rendering again after a change), for CI's log; written by the audio thread alone, as above.
    private(set) var jumps = 0

    init() {
        pending = .allocate(capacity: Self.programCount)
        pending.initialize(repeating: 0, count: Self.programCount)
        active = .allocate(capacity: Self.programCount)
        active.initialize(repeating: 0, count: Self.programCount)
        memory = .allocate(capacity: Self.maxChannels * filterCount * 2)
        memory.initialize(repeating: 0, count: Self.maxChannels * filterCount * 2)
        coefficients = .allocate(capacity: 5)
        coefficients.initialize(repeating: .identity, count: 5)
        echoCut = .allocate(capacity: Self.maxChannels * 2)
        echoCut.initialize(repeating: 0, count: Self.maxChannels * 2)
    }

    deinit {
        pending.deallocate()
        active.deallocate()
        memory.deallocate()
        coefficients.deallocate()
        echoCut.deallocate()
        echoLine?.deallocate()
    }

    // MARK: Main thread

    /// Plays `side` of `plan` from now on (its lanes hold their first values until the window).
    /// `offset`: what the player's item time is ahead of the song's (a song carried on from a rendered
    /// mix plays inside the mix's file: see `PlayerController.itemOffset`).
    func arm(_ plan: SeguePlan, side: SegueLane.Side, offset: Double = 0) {
        let anchor = (side == .outgoing ? plan.outgoingStart : plan.incomingStart) + offset
        let span = side == .outgoing ? plan.length : plan.length * plan.rate
        lock.withLock {
            pending.update(repeating: 0, count: Self.programCount)
            pending[Header.mode] = 1
            pending[Header.anchor] = anchor
            pending[Header.span] = max(0.001, span)
            // Only the outgoing song is thrown into an echo.
            pending[Header.echoDelay] = side == .outgoing ? min(SeguePlan.maxEchoDelay, max(0, plan.echoDelay ?? 0)) : 0
            for (index, target) in Self.targetOrder.enumerated() {
                let base = Self.headerCount + index * Self.laneStride
                guard let lane = plan.lanes.first(where: { $0.side == side && $0.target == target }) else { continue }
                let knots = lane.knots.prefix(Self.maxKnots)
                pending[base] = Double(knots.count)
                for (k, knot) in knots.enumerated() {
                    let slot = base + 1 + k * 4
                    pending[slot] = knot.at
                    pending[slot + 1] = knot.value ?? .nan
                    switch knot.curve {
                    case .step: pending[slot + 2] = 0
                    case .linear: pending[slot + 2] = 1
                    case .exponential: pending[slot + 2] = 2
                    case .power(let k): pending[slot + 2] = 3; pending[slot + 3] = k
                    }
                }
            }
            pending[Header.version] = nextVersion
            nextVersion += 1
        }
    }

    /// Goes back to the song's plain sound over `seconds` of its time, from wherever it is.
    func release(over seconds: Double) {
        lock.withLock {
            guard pending[Header.mode] == 1 else { return }
            pending[Header.mode] = 2
            pending[Header.release] = max(0.01, seconds)
            pending[Header.version] = nextVersion
            nextVersion += 1
        }
    }

    /// Off at once (nothing to play any more).
    func disarm() {
        lock.withLock {
            pending.update(repeating: 0, count: Self.programCount)
            pending[Header.version] = nextVersion
            nextVersion += 1
        }
    }

    // MARK: Audio thread

    /// The processing format: float samples only (the others pass untouched).
    /// Called by the audio processing before it starts (never while it runs), so the echo's line is
    /// allocated here.
    func prepare(sampleRate: Double, channels: Int, isFloat: Bool) {
        self.sampleRate = sampleRate > 0 ? sampleRate : 44_100
        self.channels = max(1, min(Self.maxChannels, channels))
        self.isFloat = isFloat
        memory.update(repeating: 0, count: Self.maxChannels * filterCount * 2)
        let capacity = Int(SeguePlan.maxEchoDelay * self.sampleRate) + 2
        if capacity != echoCapacity {
            echoLine?.deallocate()
            echoLine = .allocate(capacity: capacity * Self.maxChannels)
            echoCapacity = capacity
        }
        echoLine?.initialize(repeating: 0, count: capacity * Self.maxChannels)
        echoCut.update(repeating: 0, count: Self.maxChannels * 2)
        echoPosition = 0
        echoSend = 0
        // One pole: y = c (y' + x - x'), c = RC / (RC + dt).
        let rc = 1 / (2 * Double.pi * Self.echoLowCut)
        echoCutCoefficient = rc / (rc + 1 / self.sampleRate)
    }

    /// Plays the lanes on `frames` frames whose first is at `time` (song seconds) and which cover
    /// `duration` seconds of the song.
    func process(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int, time: Double, duration: Double) {
        guard isFloat, frames > 0, time.isFinite else { return }
        lock.withLockIfAvailable {
            if pending[Header.version] != active[Header.version] {
                let wasMode = active[Header.mode]
                active.update(from: pending, count: Self.programCount)
                if active[Header.mode] == 2, wasMode == 1 { releaseFrom = nil } else if active[Header.mode] == 1, wasMode != 1 {
                    memory.update(repeating: 0, count: Self.maxChannels * filterCount * 2)
                    releaseFrom = nil
                    gain = currentLevel(at: time)
                    // A new plan's echo starts from silence (a bounded clear, once per plan).
                    echoLine?.update(repeating: 0, count: echoCapacity * Self.maxChannels)
                    echoCut.update(repeating: 0, count: Self.maxChannels * 2)
                    echoSend = 0
                }
            }
        }
        let mode = active[Header.mode]
        guard mode != 0 else { return }
        let step = duration > 0 ? duration / Double(frames) : 1 / sampleRate
        var start = 0
        while start < frames {
            let count = min(Self.blockFrames, frames - start)
            let blockTime = time + Double(start) * step
            let values = mode == 2 ? releasing(at: blockTime) : read(at: blockTime)
            let target = values.level <= -59.99 ? 0 : pow(10, min(6, values.level) / 20)
            updateFilters(values)
            let send = max(0, min(1, values.echo))
            run(buffers, from: start, count: count, gainFrom: gain, gainTo: target, sendFrom: echoSend, sendTo: send)
            gain = target
            echoSend = send
            start += count
        }
        if processedTime.isFinite, abs(time - processedTime) > 0.002 { jumps &+= 1 }
        processedTime = time + Double(frames) * step
        lastProcessed = processedTime
    }

    private typealias Values = (level: Double, lowShelf: Double, mid: Double, highShelf: Double, lowPass: Double, highPass: Double,
                                echo: Double)

    private func read(at time: Double) -> Values {
        let x = (time - active[Header.anchor]) / active[Header.span]
        return (lane(0, x, silenceAsFloor: true), lane(1, x), lane(2, x), lane(3, x), lane(4, x), lane(5, x), lane(6, x))
    }

    private func currentLevel(at time: Double) -> Double {
        let level = read(at: time).level
        return level <= -59.99 ? 0 : pow(10, min(6, level) / 20)
    }

    /// From the values where the release began to plain sound, over the release's length.
    private func releasing(at time: Double) -> Values {
        if releaseFrom == nil {
            releaseFrom = read(at: time)
            releaseStart = time
        }
        guard let from = releaseFrom else { return (0, 0, 0, 0, 20_000, 20, 0) }
        let u = max(0, min(1, (time - releaseStart) / active[Header.release]))
        let level = from.level + (0 - from.level) * u
        return (level, from.lowShelf * (1 - u), from.mid * (1 - u), from.highShelf * (1 - u),
                from.lowPass * pow(20_000 / max(20, from.lowPass), u), from.highPass * pow(20 / max(20, from.highPass), u),
                from.echo * (1 - u))
    }

    /// Lane `index` at position `x`: its knots read straight from the program.
    private func lane(_ index: Int, _ x: Double, silenceAsFloor: Bool = false) -> Double {
        let neutral = Self.neutral(index)
        let base = Self.headerCount + index * Self.laneStride
        let count = Int(active[base])
        guard count > 0 else { return neutral }
        func at(_ k: Int) -> Double { active[base + 1 + k * 4] }
        func value(_ k: Int) -> Double { let v = active[base + 2 + k * 4]; return v.isNaN ? neutral : v }
        if x <= at(0) { return value(0) }
        if x >= at(count - 1) { return value(count - 1) }
        var low = 0, high = count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if at(middle) <= x { low = middle } else { high = middle }
        }
        let a = value(low), b = value(high)
        let span = at(high) - at(low)
        let u = span > 0 ? (x - at(low)) / span : 1
        switch active[base + 3 + high * 4] {
        case 0: return a
        case 2: return a > 0 && b > 0 ? a * pow(b / a, u) : a + (b - a) * u
        case 3: return a + (b - a) * pow(u, max(0.05, active[base + 4 + high * 4]))
        default: return a + (b - a) * u
        }
    }

    /// What a lane without knots, or a nil knot, stands for, by its place in the program (no static
    /// table is read on the audio thread: its first reading would take a lock).
    private static func neutral(_ index: Int) -> Double {
        switch index {
        case 0: return -60
        case 4: return 20_000
        case 5: return 20
        default: return 0
        }
    }

    // MARK: Filters

    /// A state-variable filter's coefficients (A. Simper, "Linear trapezoidal integrated SVF", 2013):
    /// stable while they move, and exactly the identity at 0 dB.
    struct FilterCoefficients: Equatable {
        var a1 = 1.0, a2 = 0.0, a3 = 0.0
        /// Output mix: m0 × input + m1 × band + m2 × low.
        var m0 = 1.0, m1 = 0.0, m2 = 0.0
        var isIdentity: Bool { m0 == 1 && m1 == 0 && m2 == 0 }
        /// Computed, not stored: a stored static's first reading could happen on the audio thread.
        static var identity: FilterCoefficients { FilterCoefficients() }

        static func make(g: Double, k: Double, m0: Double, m1: Double, m2: Double) -> FilterCoefficients {
            let a1 = 1 / (1 + g * (g + k))
            let a2 = g * a1
            return FilterCoefficients(a1: a1, a2: a2, a3: g * a2, m0: m0, m1: m1, m2: m2)
        }

        static func lowShelf(_ db: Double, frequency: Double, q: Double, rate: Double) -> FilterCoefficients {
            guard abs(db) > 0.01 else { return .identity }
            let a = pow(10, db / 40)
            let g = tan(Double.pi * min(frequency, rate * 0.45) / rate) / a.squareRoot()
            let k = 1 / q
            return make(g: g, k: k, m0: 1, m1: k * (a - 1), m2: a * a - 1)
        }

        static func highShelf(_ db: Double, frequency: Double, q: Double, rate: Double) -> FilterCoefficients {
            guard abs(db) > 0.01 else { return .identity }
            let a = pow(10, db / 40)
            let g = tan(Double.pi * min(frequency, rate * 0.45) / rate) * a.squareRoot()
            let k = 1 / q
            return make(g: g, k: k, m0: a * a, m1: k * (1 - a) * a, m2: 1 - a * a)
        }

        static func bell(_ db: Double, frequency: Double, q: Double, rate: Double) -> FilterCoefficients {
            guard abs(db) > 0.01 else { return .identity }
            let a = pow(10, db / 40)
            let g = tan(Double.pi * min(frequency, rate * 0.45) / rate)
            let k = 1 / (q * a)
            return make(g: g, k: k, m0: 1, m1: k * (a * a - 1), m2: 0)
        }

        static func lowPass(_ frequency: Double, q: Double, rate: Double) -> FilterCoefficients {
            guard frequency < min(19_000, rate * 0.45) else { return .identity }
            let g = tan(Double.pi * max(20, frequency) / rate)
            return make(g: g, k: 1 / q, m0: 0, m1: 0, m2: 1)
        }

        static func highPass(_ frequency: Double, q: Double, rate: Double) -> FilterCoefficients {
            guard frequency > 21 else { return .identity }
            let g = tan(Double.pi * min(frequency, rate * 0.45) / rate)
            let k = 1 / q
            // high = input - k × band - low
            return make(g: g, k: k, m0: 1, m1: -k, m2: -1)
        }
    }

    static let lowShelfHz = 180.0
    static let highShelfHz = 2_500.0
    /// √(180 × 2,500), halfway between the shelves on a log scale (a literal: nothing to work out on
    /// the audio thread's first reading).
    static let midHz = 670.820_393_249_937
    static let shelfQ = 0.7071
    static let midQ = 0.5

    private func updateFilters(_ values: Values) {
        if abs(values.lowShelf - lastValues.lowShelf) > 0.005 || coefficients[0] == .identity && abs(values.lowShelf) > 0.01 {
            coefficients[0] = .lowShelf(values.lowShelf, frequency: Self.lowShelfHz, q: Self.shelfQ, rate: sampleRate)
        }
        if abs(values.mid - lastValues.mid) > 0.005 || coefficients[1] == .identity && abs(values.mid) > 0.01 {
            coefficients[1] = .bell(values.mid, frequency: Self.midHz, q: Self.midQ, rate: sampleRate)
        }
        if abs(values.highShelf - lastValues.highShelf) > 0.005 || coefficients[2] == .identity && abs(values.highShelf) > 0.01 {
            coefficients[2] = .highShelf(values.highShelf, frequency: Self.highShelfHz, q: Self.shelfQ, rate: sampleRate)
        }
        if abs(values.lowPass - lastValues.lowPass) > 0.5 || coefficients[3] == .identity && values.lowPass < 19_000 {
            coefficients[3] = .lowPass(values.lowPass, q: Self.shelfQ, rate: sampleRate)
        }
        if abs(values.highPass - lastValues.highPass) > 0.05 || coefficients[4] == .identity && values.highPass > 21 {
            coefficients[4] = .highPass(values.highPass, q: Self.shelfQ, rate: sampleRate)
        }
        lastValues = (values.lowShelf, values.mid, values.highShelf, values.lowPass, values.highPass)
    }

    /// The filters, then the fader, on `count` frames from `start`; the echo's send taken after the
    /// filters and ahead of the fader, its repeats added after it (they ring on once the fader is shut).
    private func run(_ buffers: UnsafeMutableAudioBufferListPointer, from start: Int, count: Int, gainFrom: Double, gainTo: Double,
                     sendFrom: Double, sendTo: Double) {
        let delayFrames = Int(active[Header.echoDelay] * sampleRate)
        let echoes = delayFrames > 0 && delayFrames < echoCapacity ? echoLine : nil
        let blockStart = echoPosition
        var channel = 0
        var advanced = 0
        for buffer in buffers {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let interleaved = max(1, Int(buffer.mNumberChannels))
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * interleaved)
            guard start < frames else { continue }
            let length = min(count, frames - start)
            advanced = max(advanced, length)
            for offset in 0..<interleaved where channel < Self.maxChannels {
                let samples = data + start * interleaved + offset
                let state = memory + channel * filterCount * 2
                for f in 0..<filterCount where !coefficients[f].isIdentity {
                    filter(samples, count: length, stride: interleaved, coefficients[f], state: state + f * 2)
                }
                let delta = (gainTo - gainFrom) / Double(max(1, length))
                if let echoes {
                    let line = echoes + channel * echoCapacity
                    let cut = echoCut + channel * 2
                    var lastIn = cut[0], lastOut = cut[1]
                    let sendDelta = (sendTo - sendFrom) / Double(max(1, length))
                    var index = 0
                    var write = blockStart
                    while index < length {
                        let y = Double(samples[index * interleaved])
                        let high = echoCutCoefficient * (lastOut + y - lastIn)
                        lastIn = y
                        lastOut = high
                        var read = write - delayFrames
                        if read < 0 { read += echoCapacity }
                        let repeat_ = Double(line[read])
                        let fed = high * (sendFrom + sendDelta * Double(index + 1)) + repeat_ * Self.echoFeedback
                        line[write] = Float(fed.isFinite ? fed : 0)
                        samples[index * interleaved] = Float(y * (gainFrom + delta * Double(index + 1)) + repeat_)
                        write += 1
                        if write == echoCapacity { write = 0 }
                        index += 1
                    }
                    // Denormals never stay in the state.
                    cut[0] = abs(lastIn) > 1e-20 ? lastIn : 0
                    cut[1] = abs(lastOut) > 1e-20 && lastOut.isFinite ? lastOut : 0
                } else {
                    var index = 0
                    while index < length {
                        samples[index * interleaved] *= Float(gainFrom + delta * Double(index + 1))
                        index += 1
                    }
                }
                channel += 1
            }
        }
        if echoes != nil { echoPosition = (blockStart + advanced) % max(1, echoCapacity) }
    }

    private func filter(_ samples: UnsafeMutablePointer<Float>, count: Int, stride: Int, _ c: FilterCoefficients,
                        state: UnsafeMutablePointer<Double>) {
        var ic1 = state[0], ic2 = state[1]
        var index = 0
        while index < count {
            let v0 = Double(samples[index * stride])
            let v3 = v0 - ic2
            let v1 = c.a1 * ic1 + c.a2 * v3
            let v2 = ic2 + c.a2 * ic1 + c.a3 * v3
            ic1 = 2 * v1 - ic1
            ic2 = 2 * v2 - ic2
            samples[index * stride] = Float(c.m0 * v0 + c.m1 * v1 + c.m2 * v2)
            index += 1
        }
        // Denormals and blow-ups never stay in the state.
        state[0] = ic1.isFinite && abs(ic1) > 1e-20 ? ic1 : 0
        state[1] = ic2.isFinite && abs(ic2) > 1e-20 ? ic2 : 0
    }
}
