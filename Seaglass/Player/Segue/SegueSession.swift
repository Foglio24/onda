import AVFoundation

/// A live AutoMix transition (see `SeguePolicy`): the next song on a second player, prepared ahead,
/// started a little before the window in step with the playing song (silent: its lanes hold it so
/// until the window), at the speed that puts its bars on the playing song's, and corrected only while
/// it is still quiet in the mix. It keeps that speed to its end, as a DJ leaves the pitch fader: the
/// mix into the song after it is matched to it (`outgoingRate`). The lanes themselves play inside
/// each player's audio processing (`SegueStage`), by each song's own time.
///
/// Why a heard song's speed never changes: a playing player renders its sound again whenever its rate
/// changes, and its time jumps by 20–40 ms (CI's Mac: the deck's samples jumped, and the measured
/// distance with them). On an iPhone that was heard as sound coming and going (steps back to the
/// song's own speed every 250 ms), then as a cut where one change brought it back after the window;
/// giving the change to the playing song as the window opened put the two 100 ms apart.
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
    /// The next song's speed now: `playRate`, corrected while it is quiet in the mix, then kept.
    private(set) var rate: Float
    /// The speed the playing song plays at (1 unless a live mix brought it in at another).
    let outgoingRate: Double
    /// Its distance from its place (seconds of its own time; positive: ahead): the last, and the
    /// largest while it was heard.
    private(set) var lastError = 0.0
    private(set) var worstError = 0.0
    private var task: Task<Void, Never>?
    /// When it starts on the system clock (seconds): before then (and just after) its time says
    /// where it will start, not where it is, so it isn't measured.
    private var startsAt = 0.0
    /// Called once the window is over and the playing song gone (not when the session is dropped or
    /// stopped).
    var finished: (() -> Void)?
    /// For CI's log: the next song's speed changes while it was heard.
    private(set) var heardRateChanges = 0
    /// The decks' jumps (see `SegueStage.jumps`) when the window opened and when it closed.
    private var jumpsAtWindow = (incoming: 0, outgoing: 0), jumpsAtEnd = (incoming: 0, outgoing: 0)

    init(plan: SeguePlan, outgoingTrackID: String, next: Track, file: URL, label: String, incomingGain: Float,
         outgoingStage: SegueStage, outgoingOffset: Double = 0, outgoingRate: Double = 1) {
        self.outgoingOffset = outgoingOffset
        self.outgoingRate = outgoingRate > 0 ? outgoingRate : 1
        // A window that doesn't match the beats plays the next song at its own speed, whatever the
        // playing song's: its time then passes 1 / outgoingRate as fast as the playing song's.
        var plan = plan
        if !plan.level.isLocked { plan.rate = 1 / self.outgoingRate }
        self.plan = plan
        self.outgoingTrackID = outgoingTrackID
        self.next = next
        self.file = file
        self.label = label
        self.incomingGain = incomingGain
        self.outgoingStage = outgoingStage
        rate = Float(plan.rate * self.outgoingRate)
        PlaybackVolume.shared.register(player)
        // It starts at an exact moment (`setRate(_:time:atHostTime:)`) only without its own waiting.
        player.automaticallyWaitsToMinimizeStalling = false
    }

    /// The speed the next song plays at: its time against the playing song's, times that song's speed.
    var playRate: Double { plan.rate * outgoingRate }

    /// Where the next song starts: its run-up before the window (never before its start).
    private var incomingStartTime: Double { max(0, plan.incomingStart - Self.runUp * playRate) }

    /// Loads the next song where its run-up starts, its lanes and effects on, prerolled at its speed.
    /// `pitch`: how the app changes songs' speed (Tempo's key lock: the pitch kept, or moving as on a
    /// turntable), so nothing changes it once the song plays on its own. False when it can't be (no
    /// audio processing for the lanes, not ready in time).
    func prepare(spatial: AVAudioSpatializationFormats, pitch: AVAudioTimePitchAlgorithm) async -> Bool {
        let item = AVPlayerItem(url: file)
        item.allowedAudioSpatializationFormats = spatial
        // Not the time-domain algorithm: it is made for speech, and on music it stutters.
        item.audioTimePitchAlgorithm = pitch == .timeDomain ? .spectral : pitch
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
    /// over 0.3 s, a seek when far off. Heard, seldom and gentle, so its tempo never sways and its
    /// player rarely renders again: nothing until it is 20 ms off, then up to 0.8 % over 2 s (1.5 %
    /// over 0.8 s while it is still low in the mix) until it is within 5 ms; the mix left (`lost`)
    /// when far off. `window` when the window starts, `ended` when it ends.
    func follow(outgoingTime: @escaping () -> Double?, window: @escaping () -> Void, ended: @escaping () -> Void,
                lost: @escaping (String) -> Void) {
        task?.cancel()
        let incomingLevel = plan.lanes.first { $0.side == .incoming && $0.target == .level }
        task = Task {
            var readings: [Double] = []
            var loggedAt = 0.0
            var outgoingGone = 0
            var correcting = false
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
                    correcting = false
                    jumpsAtWindow = (incomingStage.jumps, outgoingStage.jumps)
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
                    _ = await player.seek(to: CMTime(seconds: plan.incomingTime(atOutgoing: outgoingTime) + 0.12 * playRate,
                                                     preferredTimescale: 48_000), toleranceBefore: .zero, toleranceAfter: .zero)
                    readings.removeAll()
                    continue
                }
                if heard { worstError = max(worstError, abs(error)) }
                let x = plan.position(.outgoing, sourceTime: outgoingTime)
                let gain = incomingLevel.map { $0.isSilent(at: x) ? 0 : pow(10, $0.value(at: x) / 20) } ?? 1
                let quiet = gain < 0.35
                if heard, !quiet {
                    // Loud in the mix: never corrected again (a change of its rate would be heard).
                    // A correction still under way ends here, under the playing song.
                    correcting = false
                } else if heard {
                    if !correcting, abs(error) > 0.020 { correcting = true }
                    if correcting, abs(error) < 0.005 { correcting = false }
                } else {
                    correcting = abs(error) > 0.002
                }
                let horizon = heard ? 0.8 : 0.3
                let limit = heard ? 0.015 : 0.08
                let nudge = correcting ? max(-limit, min(limit, -error / horizon)) : 0
                let target = Float(playRate * (1 + nudge))
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
            jumpsAtEnd = (incomingStage.jumps, outgoingStage.jumps)
            // The window is over: the next song's deck goes back to plain sound (from its lanes' last
            // values, plain already or nearly). Left on its lanes, a seek back to before the window,
            // where they hold it silent, would play nothing while the song went on.
            incomingStage.release(over: 0.5)
            ended()
            await restore()
        }
    }

    /// Once a second in CI's log: how far the next song is from its place.
    static var logs = false

    /// After the window (from `restoring`): the next song plays on at its speed, and once the playing
    /// song is gone (its echo rung out), the session is done.
    private func restore() async {
        guard phase == .restoring else { return }
        try? await Task.sleep(for: .seconds(0.5 + (plan.hasEcho ? SeguePlan.echoTail : 0)))
        guard phase == .restoring else { return }
        phase = .finished
        if Self.logs {
            print(String(format: "segue: after the window: plays on at rate %.4f (the playing song's %.4f); heard with %d speed "
                         + "changes; deck jumps in the window: incoming %d, outgoing %d; incoming after it: %d",
                         rate, outgoingRate, heardRateChanges, jumpsAtEnd.incoming - jumpsAtWindow.incoming,
                         jumpsAtEnd.outgoing - jumpsAtWindow.outgoing, incomingStage.jumps - jumpsAtEnd.incoming))
        }
        finished?()
    }

    /// Done with at once (the song it brought in is no longer playing, or the next mix needs its
    /// place): nothing more is changed on the player.
    func stop() {
        task?.cancel()
        if phase != .abandoned { phase = .finished }
    }

    /// Done at once (the next mix, or a tempo set, starts from here).
    func settle() {
        guard phase == .restoring else { return }
        task?.cancel()
        phase = .finished
    }

    /// The next song goes back to its plain sound (the mix was left while it is heard): its lanes
    /// ramp out; it plays on at its speed.
    func releaseIncoming() {
        incomingStage.release(over: 0.4)
        // Past its window already, it carries on as it is.
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
