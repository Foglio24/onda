import Foundation

/// The Home's AutoMix demo: two of the app's own songs (see `DemoSongs`) heard twice, one after the
/// other as with no transition and mixed by AutoMix, from the same seconds of the first song, at the
/// same gains. Everything is made on the device, so it works without an account, without Premium
/// and offline; it opens AutoMix for these two songs only, and never touches the queue (see
/// `PassagePlayer`).
///
/// The mix is AutoMix's own: the songs analysed as any song is (`AutoMixLibrary`, Beat This! where it
/// is bundled), the transition planned by `SeguePolicy` with the settings of Settings › AutoMix, and
/// rendered by `SegueRender`, the code that renders it in the player.
enum AutoMixDemo {
    typealias Song = DemoSongs.Spec

    static var songs: [Song] { DemoSongs.autoMixPair }
    static let artist = "Seaglass Demo"

    static var folder: URL { Storage.caches.appending(path: "AutoMixDemo", directoryHint: .isDirectory) }

    static func file(of song: Song) -> URL { folder.appending(path: "\(song.id).m4a") }

    private struct Manifest: Codable {
        var levels: [String: DemoSongs.Level]
    }

    private static var manifestURL: URL { folder.appending(path: "songs.json") }

    /// The songs' files, made now unless they were before, and the gains that make them as loud as
    /// each other.
    static func songFiles() throws -> (urls: [URL], gains: [Float]) {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var manifest = (try? Data(contentsOf: manifestURL)).flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
            ?? Manifest(levels: [:])
        var changed = false
        for song in songs where manifest.levels[song.id] == nil || !FileManager.default.fileExists(atPath: file(of: song).path) {
            manifest.levels[song.id] = try DemoSongs.write(to: file(of: song), bpm: song.bpm, root: song.root,
                                                           introBars: song.introBars, seconds: song.seconds)
            changed = true
        }
        if changed, let data = try? JSONEncoder().encode(manifest) { try? data.write(to: manifestURL, options: .atomic) }
        let levels = songs.map { manifest.levels[$0.id] ?? DemoSongs.Level(rms: 0, peak: 0) }
        return (songs.map(file(of:)), DemoSongs.matchedGains(levels))
    }

    /// The request the player would make for these two songs, with the listener's AutoMix settings.
    static func request(_ outgoing: TrackAnalysis, _ incoming: TrackAnalysis, settings: Bool) -> SegueRequest {
        var request = DemoSongs.autoMixRequest(outgoing, incoming)
        guard settings else { return request }
        var tuning = SegueTuning()
        tuning.maxRateChange = Preferences.autoMixTempoBend.maxRateChange
        if Preferences.mixLabVocals {
            tuning.voiceOverlapMax = 0.25
            tuning.penaltyVoice *= 2
        }
        request.harmonic = Preferences.autoMixHarmonic
        request.length = Preferences.mixLength
        request.eq = Preferences.autoMixEqualiser
        request.tuning = tuning
        request.families = Preferences.autoMixStyle.families
        request.bassHandover = Preferences.mixLabBass
        request.echoes = Preferences.mixLabEcho
        request.fadeOnBeat = Preferences.mixLabBeatFade
        request.byEnergy = Preferences.mixLabEnergy
        return request
    }

    struct Prepared: Sendable {
        var analyses: [TrackAnalysis]
        var plain: TransitionClip
        var autoMix: TransitionClip
        var plan: SeguePlan
        /// The listener's settings found no mix for this pair, and AutoMix's defaults made it.
        var usedDefaults: Bool
    }

    enum Failure: LocalizedError {
        case analysis
        case noMix

        var errorDescription: String? {
            switch self {
            case .analysis: return String(localized: "L'analisi dei brani demo non è riuscita.")
            case .noMix: return String(localized: "AutoMix non ha trovato un passaggio per i brani demo.")
            }
        }
    }

    /// Makes the songs (once), analyses them (once), plans the mix and renders both listens.
    /// `step` says what is being done, for the page.
    static func prepare(step: @escaping @Sendable (String) async -> Void) async throws -> Prepared {
        await step(String(localized: "Creazione dei brani demo…"))
        let (urls, gains) = try songFiles()
        await step(String(localized: "Analisi dei brani demo…"))
        async let first = AutoMixLibrary.shared.analysis(of: urls[0], priority: .userInitiated)
        async let second = AutoMixLibrary.shared.analysis(of: urls[1], priority: .userInitiated)
        guard let outgoing = await first, let incoming = await second else { throw Failure.analysis }
        try Task.checkCancellation()
        await step(String(localized: "Preparazione del mix…"))
        var usedDefaults = false
        var decision = SeguePolicy.decide(request(outgoing, incoming, settings: true))
        if decision.plan == nil || decision.level == .normal {
            decision = SeguePolicy.decide(request(outgoing, incoming, settings: false))
            usedDefaults = true
        }
        guard let plan = decision.plan, decision.level != .normal else { throw Failure.noMix }
        let pair = (outgoing: gains[0], incoming: gains[1])
        let plain = try await TransitionClipMaker.plain(outgoing: urls[0], incoming: urls[1], gains: pair,
                                                        to: folder.appending(path: "plain.caf"))
        let mixed = try await TransitionClipMaker.autoMix(plan, outgoing: urls[0], incoming: urls[1], gains: pair,
                                                          to: folder.appending(path: "automix.caf"))
        return Prepared(analyses: [outgoing, incoming], plain: plain, autoMix: mixed, plan: plan, usedDefaults: usedDefaults)
    }
}
