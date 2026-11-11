import AVFoundation

/// A live AutoMix transition (see `SeguePolicy`): the next song on a second player, prepared ahead,
/// started a little before the window in step with the playing song (silent: its lanes hold it so
/// until the window), and kept there by small changes of its speed while the two are heard together.
/// After the window it goes back to its own speed in steps too small to hear. The lanes themselves
/// play inside each player's audio processing (`SegueStage`), by each song's own time.
@MainActor
final class SegueSession {
    enum Phase: String { case preparing, ready, running, mixing, restoring, finished, abandoned }

    /// How long before the window the next song starts (silent), so it is in step when it is heard.
    static let runUp: TimeInterval = 2.5
    /// How long before the window it is loaded.
    static let prepareLead: TimeInterval = 15
    /// A distance from its place past which it is put back by a seek (silent) or the mix is left (heard).
    static let lostDistance: TimeInterval = 0.4

    let plan: SeguePlan
    let outgoingTrackID: String
    let next: Track
    let file: URL
    let label: String
    let incomingGain: Float
    /// The playing song's stage (in its item's audio processing), and the next song's.
    let outgoingStage: SegueStage
    /// What the playing song's item time is ahead of the song's (a song carried on from a rendered mix).
    let outgoingOffset: Double
    let incomingStage = SegueStage()
    let player = AVPlayer()
    private(set) var item: AVPlayerItem?
    private(set) var phase: Phase = .preparing
    /// The next song's speed now: the plan's, corrected, then back to its own.
    private(set) var rate: Float
    /// Its distance from its place (seconds of its own time; positive: ahead): the last, and the
    /// largest while it was heard.
    private(set) var lastError = 0.0
    private(set) var worstError = 0.0
    private var task: Task<Void, Never>?
    /// When it starts on the system clock (seconds): before then (and just after) its time says
    /// where it will start, not where it is, so it isn't measured.
    private var startsAt = 0.0
    /// Called once the next song is back at its own speed (not when the session is dropped or stopped).
    var finished: (() -> Void)?
    /// For CI's log: speed changes while it was heard, and the steps back to its own.
    private(set) var heardRateChanges = 0
    private(set) var restoreSteps = 0
    /// The incoming deck's jumps (see `SegueStage.jumps`) when the window opened and when it closed.
    private var jumpsAtWindow = 0, jumpsAtEnd = 0

    init(plan: SeguePlan, outgoingTrackID: String, next: Track, file: URL, label: String, incomingGain: Float,
         outgoingStage: SegueStage, outgoingOffset: Double = 0) {
        self.outgoingOffset = outgoingOffset
        self.plan = plan
        self.outgoingTrackID = outgoingTrackID
        self.next = next
        self.file = file
        self.label = label
        self.incomingGain = incomingGain
        self.outgoingStage = outgoingStage
        rate = Float(plan.rate)
        PlaybackVolume.shared.register(player)
        // It starts at an exact moment (`setRate(_:time:atHostTime:)`) only without its own waiting.
        player.automaticallyWaitsToMinimizeStalling = false
    }

    /// Where the next song starts: its run-up before the window (never before its start).
    private var incomingStartTime: Double { max(0, plan.incomingStart - Self.runUp * plan.rate) }

    /// Loads the next song where its run-up starts, its lanes and effects on, prerolled at its speed.
    /// False when it can't be (no audio processing for the lanes, not ready in time).
    func prepare(spatial: AVAudioSpatializationFormats) async -> Bool {
        let item = AVPlayerItem(url: file)
        item.allowedAudioSpatializationFormats = spatial
        // Within 1 % by resampling alone (the pitch moves by under 17 cents until it comes back);
        // more keeps the pitch with the spectral algorithm, as Tempo's key lock does. Not the
        // time-domain one: it is made for speech, and on music it stutters.
        item.audioTimePitchAlgorithm = abs(plan.rate - 1) <= 0.01 ? .varispeed : .spectral
        let effects = await AudioEffects.mix(for: item, gain: incomingGain, segue: incomingStage)
        guard effects.segue != nil, phase == .preparing else { return false }
        item.audioMix = effects.mix
        incomingStage.arm(plan, side: .incoming)
        outgoingStage.arm(plan, side: .outgoing, offset: outgoingOffset)
        self.item = item
        player.replaceCurrentItem(with: item)
        player.defaultRate = rate
        _ = await player.seek(to: CMTime(seconds: incomingStartTime, preferredTimescale: 48_000),
                              toleranceBefore: .zero, toleranceAfter: .zero)
        var waited = 0
        while item.status == .unknown, waited < 50, phase == .preparing {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        guard item.status == .readyToPlay, phase == .preparing else { return false }
        var ready = await player.preroll(atRate: rate)
        if !ready, phase == .preparing { ready = await player.preroll(atRate: rate) }
        guard ready, phase == .preparing else { return false }
        phase = .ready
        return true
    }

    /// Starts the next song on the system clock, so that its run-up meets the playing song's time.
    /// False when that moment has passed.
    func start(outgoing: AVPlayer, offset: Double) -> Bool {
        guard phase == .ready, let item = outgoing.currentItem, let timebase = item.timebase else { return false }
        let outgoingRate = CMTimebaseGetRate(timebase)
        let now = CMTimebaseGetTime(timebase).seconds - offset
        // The playing song's time at which the next one is at its run-up's start.
        let meet = plan.outgoingStart - (plan.incomingStart - incomingStartTime) / plan.rate
        let delay = (meet - now) / max(0.01, outgoingRate)
        guard outgoingRate > 0, now.isFinite, delay > 0.05 else { return false }
        let host = CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()), CMTime(seconds: delay, preferredTimescale: 1_000_000_000))
        startsAt = host.seconds
        player.setRate(rate, time: CMTime(seconds: incomingStartTime, preferredTimescale: 48_000), atHostTime: host)
        phase = .running
        return true
    }

    /// Keeps the next song on its place against the playing one (`outgoingTime`, nil while it isn't
    /// playing) every 50 ms, by nudging its speed: the median of the last five distances (a player's
    /// time moves in steps of 10–20 ms, which a single reading would chase), nothing inside a dead
    /// band, and the rest made good over a horizon. Silent (the run-up), fast and strong: up to 8 %
    /// over 0.3 s, a seek when far off. Heard, gentle, so its tempo never sways: up to 0.8 % over 2 s
    /// (1.5 % over 0.8 s while it is still low in the mix), the mix left (`lost`) when far off.
    /// `window` when the window starts, `ended` when it ends; then the speed goes back to its own.
    func follow(outgoingTime: @escaping () -> Double?, window: @escaping () -> Void, ended: @escaping () -> Void,
                lost: @escaping (String) -> Void) {
        task?.cancel()
        let incomingLevel = plan.lanes.first { $0.side == .incoming && $0.target == .level }
        task = Task {
            var readings: [Double] = []
            var loggedAt = 0.0
            var outgoingGone = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, phase == .running || phase == .mixing else { return }
                guard let outgoingTime = outgoingTime() else {
                    // The playing song stopped (its item ended or was let go) while the next one plays
                    // on: after 2 seconds the window is over, so the next song still comes back to
                    // its speed and nothing waits on it for ever.
                    if phase == .mixing, player.timeControlStatus == .playing {
                        outgoingGone += 1
                        if outgoingGone >= 40 { break }
                    }
                    continue
                }
                outgoingGone = 0
                if phase == .running, outgoingTime >= plan.outgoingStart {
                    phase = .mixing
                    jumpsAtWindow = incomingStage.jumps
                    window()
                }
                if outgoingTime >= plan.outgoingEnd { break }
                // Not playing yet (its start is ahead) is fine; stopped while it should play is a stall.
                if player.timeControlStatus != .playing {
                    if phase == .mixing { return lost("incoming stalled") }
                    readings.removeAll()
                    continue
                }
                if CMClockGetTime(CMClockGetHostTimeClock()).seconds < startsAt + 0.15 { continue }
                readings.append(player.currentTime().seconds - plan.incomingTime(atOutgoing: outgoingTime))
                if readings.count > 5 { readings.removeFirst() }
                let error = readings.sorted()[readings.count / 2]
                lastError = error
                let heard = phase == .mixing
                if abs(error) > Self.lostDistance, readings.count >= 3 {
                    if heard { return lost(String(format: "incoming %.0f ms off", error * 1000)) }
                    _ = await player.seek(to: CMTime(seconds: plan.incomingTime(atOutgoing: outgoingTime) + 0.12 * plan.rate,
                                                     preferredTimescale: 48_000), toleranceBefore: .zero, toleranceAfter: .zero)
                    readings.removeAll()
                    continue
                }
                if heard { worstError = max(worstError, abs(error)) }
                let x = plan.position(.outgoing, sourceTime: outgoingTime)
                let gain = incomingLevel.map { $0.isSilent(at: x) ? 0 : pow(10, $0.value(at: x) / 20) } ?? 1
                let quiet = gain < 0.35 || plan.level == .hard
                let dead = heard ? 0.012 : 0.002
                let horizon = heard ? (quiet ? 0.8 : 2) : 0.3
                let limit = heard ? (quiet ? 0.015 : 0.008) : 0.08
                let nudge = abs(error) <= dead ? 0 : max(-limit, min(limit, -error / horizon))
                let target = Float(plan.rate * (1 + nudge))
                if abs(target - rate) > 0.0005 {
                    player.rate = target
                    rate = target
                    if heard { heardRateChanges += 1 }
                }
                if Self.logs, outgoingTime - loggedAt >= 1 {
                    loggedAt = outgoingTime
                    print(String(format: "segue: %@ %+.0f ms, rate %.4f", heard ? "mix" : "run-up", error * 1000, rate))
                }
            }
            guard !Task.isCancelled else { return }
            phase = .restoring
            jumpsAtEnd = incomingStage.jumps
            ended()
            await restore()
        }
    }

    /// Once a second in CI's log: how far the next song is from its place.
    static var logs = false

    /// Back to its own speed (from `restoring`), never heard as a jump: in steps of at most 0.25 %
    /// while the pitch moves with it (4 cents), 0.5 % while it is kept, spread over the plan's time
    /// for it. Few steps rather than many: each is a change of the player's rate, which is all the
    /// player has, and the song is heard on its own by now.
    private func restore() async {
        guard phase == .restoring else { return }
        // The session's own speed, not the player's: paused, that one reads 0.
        let from = Double(rate)
        let change = 1 - from
        if abs(change) > 0.0005 {
            let largest = item?.audioTimePitchAlgorithm == .varispeed ? 0.0025 : 0.005
            let steps = max(1, Int((abs(change) / largest).rounded(.up)))
            let spacing = max(0.25, plan.restoreSeconds / Double(steps))
            for step in 1...steps {
                try? await Task.sleep(for: .seconds(spacing))
                guard !Task.isCancelled, phase == .restoring else { return }
                setRate(Float(from + change * Double(step) / Double(steps)))
                restoreSteps = step
            }
        } else {
            setRate(1)
        }
        guard phase == .restoring else { return }
        phase = .finished
        if Self.logs {
            print(String(format: "segue: back to its own speed in %d steps; heard with %d speed changes; incoming deck jumps: %d in the window, %d after it",
                         restoreSteps, heardRateChanges, jumpsAtEnd - jumpsAtWindow, incomingStage.jumps - jumpsAtEnd))
        }
        finished?()
    }

    /// Done with at once (the song it brought in is no longer playing, or the next mix needs its
    /// place): nothing more is changed on the player.
    func stop() {
        task?.cancel()
        if phase != .abandoned { phase = .finished }
    }

    /// Back to its own speed at once (the next mix must start from it): the last of the way in one step.
    func settle() {
        guard phase == .restoring else { return }
        task?.cancel()
        setRate(1)
        phase = .finished
    }

    private func setRate(_ value: Float) {
        rate = value
        player.defaultRate = value
        if player.timeControlStatus != .paused { player.rate = value }
    }

    /// The next song goes back to its plain sound (the mix was left while it is heard): its lanes
    /// ramp out and its speed returns to its own.
    func releaseIncoming() {
        incomingStage.release(over: 0.4)
        // Already on its way back (the window is over), it carries on.
        guard phase != .restoring, phase != .finished, phase != .abandoned else { return }
        task?.cancel()
        phase = .restoring
        Task { await restore() }
    }

    /// The playing song goes back to its plain sound (the next one stalled while heard).
    func releaseOutgoing() { outgoingStage.release(over: 0.4) }

    /// Dropped before it was heard: the next song's player stops, the playing song plays on plainly.
    func abandon() {
        task?.cancel()
        phase = .abandoned
        player.pause()
        player.replaceCurrentItem(with: nil)
        outgoingStage.disarm()
        incomingStage.disarm()
    }

    /// For Settings and CI's log.
    var summary: String {
        String(format: "%@ %@, %.1f s from %.1f s, rate %.4f, phase %.0f/%.0f ms, worst %.0f ms",
               plan.level.rawValue, plan.shape.rawValue, plan.length, plan.outgoingStart, plan.rate,
               (plan.phaseMedian ?? 0) * 1000, (plan.phaseP95 ?? 0) * 1000, worstError * 1000)
    }
}
