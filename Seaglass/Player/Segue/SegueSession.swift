import AVFoundation

/// A live AutoMix transition (see `SeguePolicy`): the next song on a second player, prepared ahead,
/// started a little before the window in step with the playing song (silent: its lanes hold it so
/// until the window), at the speed that puts its bars on the playing song's, and corrected only while
/// it is still quiet in the mix. After the window it goes back to its own speed on a fresh player
/// (see `returnToOwnSpeed`). The lanes themselves play inside each player's audio processing
/// (`SegueStage`), by each song's own time.
///
/// Why a heard player's speed never changes: a playing player renders its sound again whenever its
/// rate changes, and its time jumps by 20–40 ms (CI's Mac: the deck's samples jumped, and the
/// measured distance with them). On an iPhone that was heard as sound coming and going (steps back to
/// the song's own speed every 250 ms), then as a cut where one change brought it back; giving the
/// change to the playing song as the window opened put the two 100 ms apart; keeping the speed to the
/// song's end left it slowed (or sped up) and time-stretched to the end.
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
    /// The song started again at its own speed after the window, handed to the player controller,
    /// which plays it from then on (false: it couldn't take it, the fresh player is let go).
    struct OwnSpeed {
        let player: AVPlayer
        let item: AVPlayerItem
        let stage: SegueStage
        let fader: HandoverFader?
    }

    var ownSpeed: ((OwnSpeed) -> Bool)?
    /// What the controller plays the songs with (see `prepare`), for the fresh player too.
    private var spatial: AVAudioSpatializationFormats = []
    private var pitch: AVAudioTimePitchAlgorithm = .spectral
    /// For CI's log: where the song went back to its own speed (its time) and how far the fresh
    /// player started from the stretched one's place (s).
    private var returnedAt: Double?, returnedOff = 0.0
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
        self.spatial = spatial
        // Not the time-domain algorithm: it is made for speech, and on music it stutters.
        self.pitch = pitch == .timeDomain ? .spectral : pitch
        let item = AVPlayerItem(url: file)
        item.allowedAudioSpatializationFormats = spatial
        item.audioTimePitchAlgorithm = self.pitch
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

    /// After the window (from `restoring`): the next song back to its own speed (`returnToOwnSpeed`),
    /// and once the playing song is gone (its echo rung out), the session is done.
    private func restore() async {
        guard phase == .restoring else { return }
        let jumpsBefore = incomingStage.jumps
        if abs(Double(rate) - 1) > 0.0005, await returnToOwnSpeed() {
            rate = 1
        }
        try? await Task.sleep(for: .seconds(0.5 + (plan.hasEcho ? SeguePlan.echoTail : 0)))
        guard phase == .restoring else { return }
        phase = .finished
        if Self.logs {
            let returned = returnedAt.map { String(format: "back to its own speed on a fresh player at %.2f s, %+.0f ms off", $0, returnedOff * 1000) }
                ?? "no fresh player"
            print(String(format: "segue: after the window: plays on at rate %.4f (the playing song's %.4f), %@; heard with %d speed "
                         + "changes; deck jumps in the window: incoming %d, outgoing %d; incoming after it: %d",
                         rate, outgoingRate, returned, heardRateChanges, jumpsAtEnd.incoming - jumpsAtWindow.incoming,
                         jumpsAtEnd.outgoing - jumpsAtWindow.outgoing, incomingStage.jumps - jumpsBefore))
        }
        finished?()
    }

    /// How long ahead the fresh player is prepared (seconds of playing), the crossover's length, and
    /// how long the fresh player runs, silent through its deck, before the crossover: its start (and
    /// whatever a player does as it starts) is never heard.
    static let returnLead = 2.0
    static let crossover = 0.08
    static let silentStart = 0.35

    /// The song, heard on its own now, back to its own speed without a playing player's rate changing:
    /// started again on a fresh player at its own speed, a third of a second before a downbeat a
    /// couple of seconds on (its bars counted from the window's start) and silent until it, on the
    /// system clock so it meets the stretched one there; the two cross over in 80 ms through their
    /// decks, by the song's time (equal gain: the same music, in phase), and the stretched player,
    /// silent from then on, is let go once all it played has come out of the speakers (with
    /// Bluetooth, a fifth of a second later; let go sooner, the end of its sound was cut off before
    /// the fresh one's came, a short gap). Only the tempo steps back, on that downbeat. False when it
    /// couldn't (the song paused, moved or near its end, the fresh player not ready in time, the
    /// controller no longer playing it): it plays on at its speed, and a pause or a seek brings it
    /// back (see `dropSpeed`).
    private func returnToOwnSpeed() async -> Bool {
        guard let item, let tempo = plan.tempo, tempo > 0, plan.level.isLocked, let ownSpeed else { return false }
        let bar = 4 * 60 / tempo * plan.rate
        let length = item.duration.seconds
        for _ in 0..<3 {
            guard phase == .restoring, player.timeControlStatus == .playing, player.currentItem === item else { return false }
            let now = player.currentTime().seconds
            let bars = max(0, ((now + Self.returnLead * Double(rate) - plan.incomingStart) / bar).rounded(.up))
            let at = plan.incomingStart + bars * bar
            guard length.isFinite, at + 10 < length else { return false }
            let cross = SeguePlan(level: .simpleFade, shape: .fade, outgoingStart: at, incomingStart: at, rate: 1,
                                  length: Self.crossover, bars: nil, tempo: nil, phaseMedian: nil, phaseP95: nil,
                                  lanes: SegueCompiler(tuning: SegueTuning()).crossover(), swap: 0.5)
            let fresh = AVPlayer()
            fresh.automaticallyWaitsToMinimizeStalling = false
            // At the app's volume, as the stretched one, from its first sound.
            PlaybackVolume.shared.register(fresh)
            let freshItem = AVPlayerItem(url: file)
            freshItem.allowedAudioSpatializationFormats = spatial
            freshItem.audioTimePitchAlgorithm = pitch
            let stage = SegueStage()
            let effects = await AudioEffects.mix(for: freshItem, gain: incomingGain, segue: stage)
            guard effects.segue != nil else { return false }
            freshItem.audioMix = effects.mix
            stage.arm(cross, side: .incoming)
            fresh.replaceCurrentItem(with: freshItem)
            func letGo() {
                fresh.pause()
                fresh.replaceCurrentItem(with: nil)
            }
            let startsAt = max(0, at - Self.silentStart)
            _ = await fresh.seek(to: CMTime(seconds: startsAt, preferredTimescale: 48_000), toleranceBefore: .zero, toleranceAfter: .zero)
            var waited = 0
            while freshItem.status == .unknown, waited < 30, phase == .restoring {
                try? await Task.sleep(for: .milliseconds(50))
                waited += 1
            }
            guard freshItem.status == .readyToPlay, phase == .restoring, await fresh.preroll(atRate: 1) else {
                letGo()
                return false
            }
            // When the stretched song reaches `at`, on the system clock; too late, the next bar.
            guard player.timeControlStatus == .playing, player.currentItem === item, let timebase = item.timebase else {
                letGo()
                return false
            }
            let speed = CMTimebaseGetRate(timebase)
            let from = CMTimebaseGetTime(timebase).seconds
            let delay = (at - from) / max(0.01, speed)
            guard speed > 0, delay > (at - startsAt) + 0.15 else {
                letGo()
                continue
            }
            let clock = CMClockGetTime(CMClockGetHostTimeClock())
            // `host`: when the stretched song reaches `at`; the fresh one starts earlier by as much of
            // its own time as lies between where it starts and `at`.
            let host = CMTimeAdd(clock, CMTime(seconds: delay, preferredTimescale: 1_000_000_000))
            let freshStart = CMTimeSubtract(host, CMTime(seconds: at - startsAt, preferredTimescale: 1_000_000_000))
            incomingStage.arm(cross, side: .outgoing)
            fresh.setRate(1, time: CMTime(seconds: startsAt, preferredTimescale: 48_000), atHostTime: freshStart)
            // Followed through the crossover: a pause, a seek or a skip calls it off (the fresh player
            // is silent until `at`, and the stretched one goes back to plain).
            var steady = true
            while CMClockGetTime(CMClockGetHostTimeClock()).seconds < host.seconds + Self.crossover + 0.05 {
                try? await Task.sleep(for: .milliseconds(20))
                let elapsed = CMClockGetTime(CMClockGetHostTimeClock()).seconds - clock.seconds
                if phase != .restoring || player.timeControlStatus != .playing || player.currentItem !== item
                    || abs(player.currentTime().seconds - (from + elapsed * speed)) > 0.25 {
                    steady = false
                    break
                }
            }
            guard steady else {
                letGo()
                incomingStage.release(over: 0.05)
                return false
            }
            // How far the fresh player is from the stretched one's place, both counted from `at`.
            let since = CMClockGetTime(CMClockGetHostTimeClock()).seconds - host.seconds
            returnedOff = (fresh.currentTime().seconds - at) - since
            returnedAt = at
            guard ownSpeed(OwnSpeed(player: fresh, item: freshItem, stage: stage, fader: effects.fader)) else {
                letGo()
                incomingStage.release(over: 0.05)
                return false
            }
            // The fresh player's deck back to plain (a seek back before `at` must play), and the
            // stretched player, silent now, let go once its last sound is out of the speakers.
            stage.release(over: 0.05)
            let session = AVAudioSession.sharedInstance()
            let latency = max(0, session.outputLatency) + max(0, session.ioBufferDuration)
            try? await Task.sleep(for: .seconds(latency + 0.25))
            player.pause()
            player.replaceCurrentItem(with: nil)
            return true
        }
        return false
    }

    /// A pause or a seek hides a change of speed: the song brought in goes back to its own there
    /// (paused, from its next start), and no fresh player is needed.
    func dropSpeed() {
        guard abs(Double(rate) - 1) > 0.0005 else { return }
        rate = 1
        player.defaultRate = 1
        if player.timeControlStatus != .paused { player.rate = 1 }
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
