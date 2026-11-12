import Foundation
import os
#if canImport(CoreAudio)
import CoreAudio // UnsafeMutableAudioBufferListPointer: AVFoundation brings it on iOS, not on a Mac
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

// The mix engine's core (Seaglass's own, no AVPlayer): two songs on two decks inside ONE render
// callback, so what one deck does is exact against the other, sample for sample. A deck reads a
// stretch of its song from memory at its own speed (resampled, so a glide in speed is continuous and
// moves no sample that was already played), plays the plan's lanes through the same `SegueStage`
// the AVPlayer path uses, and the two are summed. Nothing here talks to the output: the live engine
// (and the checks) call `render`, which works for any number of frames per call.
//
// Real time: `render` allocates nothing, waits for nothing (the control lock is only tried), logs
// nothing and reads no file. A song's samples are decoded before it is loaded (`DeckPCM`).

/// A stretch of one song decoded to memory: stereo, at the engine's rate. Immutable once made, so
/// the render thread reads it without a lock.
final class DeckPCM: @unchecked Sendable {
    let sampleRate: Double
    /// The song's own time, seconds, of the first frame.
    let origin: Double
    let frames: Int
    fileprivate let left: UnsafeMutablePointer<Float>
    fileprivate let right: UnsafeMutablePointer<Float>

    init(sampleRate: Double, origin: Double, left leftSamples: [Float], right rightSamples: [Float]) {
        let count = min(leftSamples.count, rightSamples.count)
        self.sampleRate = sampleRate
        self.origin = origin
        self.frames = count
        let capacity = max(1, count)
        left = .allocate(capacity: capacity)
        right = .allocate(capacity: capacity)
        left.initialize(repeating: 0, count: capacity)
        right.initialize(repeating: 0, count: capacity)
        leftSamples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress, count > 0 { left.update(from: base, count: count) }
        }
        rightSamples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress, count > 0 { right.update(from: base, count: count) }
        }
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    /// The song's own time, seconds, after the last frame.
    var end: Double { origin + Double(frames) / sampleRate }
}

/// A deck's speed over its song's own time: knots joined by straight lines, held before the first
/// and after the last. 1 is the song's own speed.
struct DeckRateProgram: Equatable, Sendable {
    static let maxKnots = 16
    var times: [Double]
    var rates: [Double]

    static let plain = DeckRateProgram(times: [], rates: [])

    /// From the song's own speed to `target` between `start` and `end` (song seconds), eased at both
    /// ends so the speed has no corner, then held at `target`.
    static func glide(to target: Double, from start: Double, until end: Double) -> DeckRateProgram {
        let steps = 12
        var times: [Double] = []
        var rates: [Double] = []
        for step in 0...steps {
            let u = Double(step) / Double(steps)
            let eased = u * u * (3 - 2 * u)
            times.append(start + (end - start) * u)
            rates.append(1 + (target - 1) * eased)
        }
        return DeckRateProgram(times: times, rates: rates)
    }

    /// The speed at `time`.
    func value(at time: Double) -> Double {
        times.withUnsafeBufferPointer { t in
            rates.withUnsafeBufferPointer { r in
                guard let tBase = t.baseAddress, let rBase = r.baseAddress else { return 1 }
                return DeckMixer.speed(at: time, times: tBase, rates: rBase, count: min(t.count, r.count))
            }
        }
    }
}

final class DeckMixer: @unchecked Sendable {
    /// The frames the decks are worked on at a time. The lanes are read once per chunk, and chunks
    /// start where the mixer's own count says (multiples of this), so what is heard doesn't depend on
    /// how many frames the output asks for at once.
    static let chunk = 64
    static let decks = 2

    let sampleRate: Double

    // MARK: Control (any thread, under `lock`)

    /// A deck's next load, taken by the render thread at the first chunk after it is posted.
    private struct Load {
        var version = 0
        var pcm: DeckPCM?
        var songTime = 0.0
        var startFrame: Int64 = 0
        var trim: Float = 1
        var times = [Double](repeating: 0, count: DeckRateProgram.maxKnots)
        var rates = [Double](repeating: 1, count: DeckRateProgram.maxKnots)
        var count = 0
        var stop = false
    }

    private let lock = OSAllocatedUnfairLock()
    private var loads = [Load](repeating: Load(), count: DeckMixer.decks)
    private var nextVersion = 1
    /// Songs the render thread let go of, for the main thread to free (a free on the render thread
    /// could wait): `collect()` empties it.
    private var retired = [DeckPCM?](repeating: nil, count: 8)

    // MARK: Render thread state

    private final class Deck {
        var pcm: DeckPCM?
        var version = 0
        /// The song's own time of the next frame to be read.
        var songTime = 0.0
        /// The output frame the deck starts at (not before).
        var startFrame = Int64.max
        var playing = false
        var trim: Float = 1
        let rateTimes: UnsafeMutablePointer<Double>
        let rateValues: UnsafeMutablePointer<Double>
        var rateCount = 0
        let left: UnsafeMutablePointer<Float>
        let right: UnsafeMutablePointer<Float>
        let list: UnsafeMutableAudioBufferListPointer
        let stage = SegueStage()

        init() {
            rateTimes = .allocate(capacity: DeckRateProgram.maxKnots)
            rateTimes.initialize(repeating: 0, count: DeckRateProgram.maxKnots)
            rateValues = .allocate(capacity: DeckRateProgram.maxKnots)
            rateValues.initialize(repeating: 1, count: DeckRateProgram.maxKnots)
            left = .allocate(capacity: DeckMixer.chunk)
            left.initialize(repeating: 0, count: DeckMixer.chunk)
            right = .allocate(capacity: DeckMixer.chunk)
            right.initialize(repeating: 0, count: DeckMixer.chunk)
            list = AudioBufferList.allocate(maximumBuffers: 2)
            let bytes = UInt32(DeckMixer.chunk * MemoryLayout<Float>.size)
            list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: UnsafeMutableRawPointer(left))
            list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: UnsafeMutableRawPointer(right))
        }

        deinit {
            rateTimes.deallocate()
            rateValues.deallocate()
            left.deallocate()
            right.deallocate()
            free(list.unsafeMutablePointer)
        }
    }

    private let state: [Deck]
    /// The mixed chunk waiting to be handed out, and how much of it is.
    private let mixLeft: UnsafeMutablePointer<Float>
    private let mixRight: UnsafeMutablePointer<Float>
    private var pendingFrom = DeckMixer.chunk
    /// The output frame at the start of the next chunk (a multiple of `chunk`), written by the render
    /// thread alone and read, unsynchronised, by the main thread: an Int64 written whole.
    private(set) var chunkFrame: Int64 = 0

    /// Per deck, the song time of the next frame to be read (read by the main thread, unsynchronised).
    private let songTimes: UnsafeMutablePointer<Double>

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        state = (0..<Self.decks).map { _ in Deck() }
        mixLeft = .allocate(capacity: Self.chunk)
        mixLeft.initialize(repeating: 0, count: Self.chunk)
        mixRight = .allocate(capacity: Self.chunk)
        mixRight.initialize(repeating: 0, count: Self.chunk)
        songTimes = .allocate(capacity: Self.decks)
        songTimes.initialize(repeating: -1, count: Self.decks)
        for deck in state { deck.stage.prepare(sampleRate: sampleRate, channels: 2, isFloat: true) }
    }

    deinit {
        mixLeft.deallocate()
        mixRight.deallocate()
        songTimes.deallocate()
    }

    // MARK: Main thread

    /// Loads `pcm` on `deck`, to start playing at `songTime` (the song's own time) when the output
    /// reaches frame `startFrame`, at the speed `rate` gives over the song's time and `trim` (linear
    /// gain: the song's loudness against the other's).
    func load(deck: Int, pcm: DeckPCM, songTime: Double, startFrame: Int64, rate: DeckRateProgram = .plain, trim: Float = 1) {
        guard (0..<Self.decks).contains(deck) else { return }
        var load = Load()
        load.pcm = pcm
        load.songTime = songTime
        load.startFrame = startFrame
        load.trim = trim
        let count = min(rate.times.count, rate.rates.count, DeckRateProgram.maxKnots)
        for index in 0..<count {
            load.times[index] = rate.times[index]
            load.rates[index] = rate.rates[index]
        }
        load.count = count
        post(load, to: deck)
    }

    /// Stops `deck` (its song is let go of).
    func stop(deck: Int) {
        guard (0..<Self.decks).contains(deck) else { return }
        var load = Load()
        load.stop = true
        post(load, to: deck)
    }

    private func post(_ load: Load, to deck: Int) {
        lock.withLock {
            var posted = load
            posted.version = nextVersion
            nextVersion += 1
            loads[deck] = posted
        }
    }

    /// Plays `plan`'s lanes: deck 0 as the outgoing song, deck 1 as the incoming one.
    func arm(_ plan: SeguePlan) {
        state[0].stage.arm(plan, side: .outgoing)
        state[1].stage.arm(plan, side: .incoming)
    }

    /// Back to the songs' plain sound, over `seconds` of their time.
    func release(over seconds: Double) {
        for deck in state { deck.stage.release(over: seconds) }
    }

    /// Plain sound at once.
    func disarm() {
        for deck in state { deck.stage.disarm() }
    }

    /// The song time `deck` will read next, or a negative number while it plays nothing.
    func songTime(of deck: Int) -> Double {
        (0..<Self.decks).contains(deck) ? songTimes[deck] : -1
    }

    /// The songs the render thread has let go of are freed here, on the calling thread.
    func collect() {
        lock.withLock {
            for index in retired.indices { retired[index] = nil }
        }
    }

    // MARK: Render thread

    /// Writes `frames` frames of the mix to `outLeft` and `outRight`.
    func render(frames: Int, left outLeft: UnsafeMutablePointer<Float>, right outRight: UnsafeMutablePointer<Float>) {
        var written = 0
        while written < frames {
            if pendingFrom >= Self.chunk {
                renderChunk()
                pendingFrom = 0
            }
            let count = min(frames - written, Self.chunk - pendingFrom)
            for index in 0..<count {
                outLeft[written + index] = mixLeft[pendingFrom + index]
                outRight[written + index] = mixRight[pendingFrom + index]
            }
            written += count
            pendingFrom += count
        }
    }

    /// Works one chunk: takes any load posted, plays each deck's frames of it and sums them.
    private func renderChunk() {
        takeLoads()
        let first = chunkFrame
        for index in 0..<Self.chunk {
            mixLeft[index] = 0
            mixRight[index] = 0
        }
        for (number, deck) in state.enumerated() {
            let produced = play(deck, from: first)
            songTimes[number] = deck.playing || produced ? deck.songTime : -1
            if produced {
                for index in 0..<Self.chunk {
                    mixLeft[index] += deck.left[index]
                    mixRight[index] += deck.right[index]
                }
            }
        }
        for index in 0..<Self.chunk {
            mixLeft[index] = Self.soften(mixLeft[index])
            mixRight[index] = Self.soften(mixRight[index])
        }
        chunkFrame = first + Int64(Self.chunk)
    }

    /// Untouched up to 0.95, then a smooth knee that never passes 1: two songs at full level can't
    /// clip, and one song's own peaks (a loud master reaches 0.95 and a little over) are left as they are.
    @inline(__always)
    private static func soften(_ x: Float) -> Float {
        let magnitude = abs(x)
        if magnitude <= 0.95 { return x }
        let over = (magnitude - 0.95) / 0.05
        let shaped = 0.95 + 0.05 * Float(tanh(Double(over)))
        return x < 0 ? -shaped : shaped
    }

    private func takeLoads() {
        lock.withLockIfAvailable {
            for number in 0..<Self.decks where loads[number].version != state[number].version {
                let load = loads[number]
                let deck = state[number]
                deck.version = load.version
                // The song it leaves goes to the retired slots, to be freed off this thread.
                if let old = deck.pcm, let slot = retired.firstIndex(where: { $0 == nil }) { retired[slot] = old }
                if load.stop || load.pcm == nil {
                    deck.pcm = nil
                    deck.playing = false
                    deck.startFrame = .max
                    continue
                }
                deck.pcm = load.pcm
                // The post no longer holds the song: the deck (and, later, the retired slot) does.
                loads[number].pcm = nil
                deck.songTime = load.songTime
                deck.startFrame = load.startFrame
                deck.trim = load.trim
                deck.playing = false
                deck.rateCount = load.count
                for index in 0..<load.count {
                    deck.rateTimes[index] = load.times[index]
                    deck.rateValues[index] = load.rates[index]
                }
            }
        }
    }

    /// The speed at `time`: `count` knots of `times` and `rates`, joined by straight lines, held
    /// beyond the ends.
    @inline(__always)
    static func speed(at time: Double, times: UnsafePointer<Double>, rates: UnsafePointer<Double>, count: Int) -> Double {
        if count <= 0 { return 1 }
        if time <= times[0] { return rates[0] }
        if time >= times[count - 1] { return rates[count - 1] }
        var low = 0
        var high = count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if times[middle] <= time { low = middle } else { high = middle }
        }
        let span = times[high] - times[low]
        let u = span > 0 ? (time - times[low]) / span : 1
        return rates[low] + (rates[high] - rates[low]) * u
    }

    /// Plays `deck`'s share of the chunk starting at output frame `first` into its scratch; false when
    /// it plays nothing in it (the scratch is then silent).
    private func play(_ deck: Deck, from first: Int64) -> Bool {
        for index in 0..<Self.chunk {
            deck.left[index] = 0
            deck.right[index] = 0
        }
        guard let pcm = deck.pcm else { return false }
        let last = first + Int64(Self.chunk)
        if !deck.playing {
            guard deck.startFrame < last else { return false }
            deck.playing = true
        }
        // The frame inside the chunk the deck starts at (0 when it already plays).
        let begin = deck.startFrame > first ? Int(deck.startFrame - first) : 0
        let outputRate = sampleRate
        let sourceRate = pcm.sampleRate

        // The speed at the chunk's start and at its end (the song time it will have reached by then),
        // the speed between them straight: no step in the speed, whatever the knots do.
        let start = deck.songTime
        let rateStart = Self.speed(at: start, times: deck.rateTimes, rates: deck.rateValues, count: deck.rateCount)
        let remaining = Double(Self.chunk - begin)
        let expectedEnd = start + remaining * rateStart / outputRate
        let rateEnd = Self.speed(at: expectedEnd, times: deck.rateTimes, rates: deck.rateValues, count: deck.rateCount)

        var time = start
        var produced = false
        for index in begin..<Self.chunk {
            let u = remaining > 1 ? Double(index - begin) / (remaining - 1) : 0
            let speed = rateStart + (rateEnd - rateStart) * u
            let position = (time - pcm.origin) * sourceRate
            deck.left[index] = Self.read(pcm.left, frames: pcm.frames, at: position)
            deck.right[index] = Self.read(pcm.right, frames: pcm.frames, at: position)
            time += speed / outputRate
            produced = true
        }
        deck.songTime = time

        // The lanes, read at the song time of the chunk's middle (the stage reads them once per chunk and
        // ramps the level towards what it read), over the song time the whole chunk covers.
        let chunkDuration = Double(Self.chunk) * (rateStart + rateEnd) / 2 / outputRate
        let chunkStart = start - Double(begin) * rateStart / outputRate
        deck.stage.process(deck.list, frames: Self.chunk, time: chunkStart + chunkDuration / 2, duration: chunkDuration)
        if deck.trim != 1 {
            for index in 0..<Self.chunk {
                deck.left[index] *= deck.trim
                deck.right[index] *= deck.trim
            }
        }
        // Past the end of its samples a deck plays nothing and lets go of them (when the lock and a slot
        // are free; otherwise at a later chunk).
        if time >= pcm.end + 0.5 {
            let handed = lock.withLockIfAvailable { () -> Bool in
                guard let slot = retired.firstIndex(where: { $0 == nil }) else { return false }
                retired[slot] = pcm
                return true
            } ?? false
            if handed {
                deck.pcm = nil
                deck.playing = false
                deck.startFrame = .max
            }
        }
        return produced
    }

    /// The sample at frame position `x` (fractional) of `samples`: exact on a whole frame, cubic
    /// (Hermite) between, and silence outside the samples.
    @inline(__always)
    private static func read(_ samples: UnsafeMutablePointer<Float>, frames: Int, at x: Double) -> Float {
        guard x.isFinite, x > -4, x < Double(frames) + 4 else { return 0 }
        @inline(__always) func at(_ i: Int) -> Float { i >= 0 && i < frames ? samples[i] : 0 }
        // A position within a millionth of a frame of a whole one reads that frame: at the song's own
        // speed the time adds up with a rounding error, and the song must still come out as it is.
        let nearest = x.rounded()
        if abs(x - nearest) < 1e-6 { return at(Int(nearest)) }
        let base = Int(x.rounded(.down))
        let fraction = Float(x - Double(base))
        let y0 = at(base - 1), y1 = at(base), y2 = at(base + 1), y3 = at(base + 2)
        let c1 = 0.5 * (y2 - y0)
        let c2 = y0 - 2.5 * y1 + 2 * y2 - 0.5 * y3
        let c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2)
        return ((c3 * fraction + c2) * fraction + c1) * fraction + y1
    }
}
