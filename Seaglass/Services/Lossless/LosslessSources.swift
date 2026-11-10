import Foundation

/// Finds a lossless copy of a song before it plays: an imported file of the same recording (at once),
/// or the user's OpenSubsonic server (within a short budget, so a song never waits long for it). What
/// is found plays instead of YouTube's stream; when nothing is found, the search runs late, or the
/// copy fails while playing, the song plays as before (see `PlayerController`). It only adds a
/// quality: never what stops a song from playing.
@MainActor
final class LosslessSources {
    static let shared = LosslessSources()

    /// How long a song's start waits for a server's answer; the search carries on afterwards, for the
    /// next time and for AutoMix.
    static let startupBudget: TimeInterval = 2.5
    /// How long one search may take at all.
    static let searchTimeout: TimeInterval = 6
    /// The cache of servers' files, kept for AutoMix's analyses and offline listening, pruned past this.
    nonisolated static let cacheLimit: Int64 = 3 << 30

    private var decisions = LosslessDecisions()
    private var running: [String: Task<LosslessDecisions.Decision?, Never>] = [:]
    private var fetching: [String: Task<URL?, Never>] = [:]

    private init() {}

    var isEnabled: Bool { UserDefaults.standard.object(forKey: Preferences.losslessSearch) as? Bool ?? true }

    /// A lossless copy to play: where it is, what it is, and the label to show.
    struct Choice: Sendable {
        let candidate: LosslessCandidate
        let url: URL
        /// A file on the device (imported, or a server's file kept): it plays offline too.
        let isLocal: Bool
        var label: String { Self.label(candidate.format, source: candidate.source) }

        static func label(_ format: AudioFormatInfo?, source: LosslessSourceKind) -> String {
            [format?.label ?? "Lossless", source.title].joined(separator: " · ")
        }
    }

    static func query(for track: Track) -> LosslessQuery {
        LosslessQuery(title: track.title, artists: track.artist.components(separatedBy: ", "), album: track.album,
                      duration: track.duration, isrc: nil)
    }

    // MARK: Choosing

    /// The copy to play for a song now, or nil to play it as before. A server's answer is waited for
    /// `budget` seconds at most.
    func choice(for track: Track, budget: TimeInterval) async -> Choice? {
        // A song that is one of the user's files plays it, whatever the setting: it has nothing else.
        if let entry = LocalLosslessLibrary.shared.entry(forTrackID: track.id) {
            let library = LocalLosslessLibrary.shared
            let candidate = library.candidates.first { $0.id == entry.id }
            return candidate.map { Choice(candidate: $0, url: library.fileURL(for: entry), isLocal: true) }
        }
        guard isEnabled, !track.isPodcastEpisode else { return nil }
        if let local = localChoice(for: track) { return local }
        guard let decision = await decision(for: track, budget: budget), case .found(let candidate) = decision else { return nil }
        guard !decisions.hasFailed(track.id, candidate) else { return nil }
        if let file = cachedFile(for: track, candidate) { return Choice(candidate: candidate, url: file, isLocal: true) }
        guard remoteAllowed, let url = OpenSubsonicSettings.client?.streamURL(id: candidate.id) else { return nil }
        return Choice(candidate: candidate, url: url, isLocal: false)
    }

    /// Starts looking for a song's copy without waiting (the next songs of the queue).
    func prefetch(_ track: Track) {
        guard isEnabled, !track.isPodcastEpisode, localChoice(for: track) == nil,
              decisions.decision(for: track.id) == nil, running[track.id] == nil,
              let client = OpenSubsonicSettings.client, NetworkMonitor.shared.isOnline else { return }
        _ = startSearch(track, client: client)
    }

    /// The copy failed while playing: not tried again for this song until the app starts again.
    func failed(_ track: Track, _ candidate: LosslessCandidate) {
        decisions.recordFailure(track.id, candidate)
    }

    /// An imported file of the song, the best one if several fit.
    private func localChoice(for track: Track) -> Choice? {
        let library = LocalLosslessLibrary.shared
        guard !library.entries.isEmpty,
              let candidate = LosslessMatcher.best(for: Self.query(for: track), among: library.candidates),
              !decisions.hasFailed(track.id, candidate),
              let entry = library.entry(id: candidate.id) else { return nil }
        return Choice(candidate: candidate, url: library.fileURL(for: entry), isLocal: true)
    }

    /// Lossless streams on Wi-Fi, and on mobile data only when asked for.
    private var remoteAllowed: Bool {
        let network = NetworkMonitor.shared
        return network.isOnline
            && (!network.isExpensive || UserDefaults.standard.bool(forKey: Preferences.losslessCellular))
    }

    // MARK: Searching

    private func decision(for track: Track, budget: TimeInterval?) async -> LosslessDecisions.Decision? {
        if let known = decisions.decision(for: track.id) { return known }
        guard let client = OpenSubsonicSettings.client, NetworkMonitor.shared.isOnline else { return nil }
        let task = running[track.id] ?? startSearch(track, client: client)
        guard let budget else { return await task.value }
        return await Self.within(budget) { await task.value } ?? nil
    }

    private func startSearch(_ track: Track, client: OpenSubsonicClient) -> Task<LosslessDecisions.Decision?, Never> {
        let query = Self.query(for: track)
        let songID = track.id
        let task = Task { () -> LosslessDecisions.Decision? in
            defer { self.running[songID] = nil }
            do {
                let found = try await client.search(query, timeout: Self.searchTimeout)
                let decision: LosslessDecisions.Decision = LosslessMatcher.best(for: query, among: found).map { .found($0) } ?? .missing
                self.decisions.record(decision, for: songID)
                return decision
            } catch {
                // A server that doesn't answer isn't a song it lacks: asked again next time.
                return nil
            }
        }
        running[songID] = task
        return task
    }

    /// A task's value if it comes within `seconds`, else nil at once: the task itself goes on (its
    /// answer is kept for the next time), and nothing here waits for it.
    private nonisolated static func within<T: Sendable>(_ seconds: TimeInterval,
                                                        _ work: @escaping @Sendable () async -> T) async -> T? {
        let once = Once()
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            Task {
                let value = await work()
                if once.claim() { continuation.resume(returning: value) }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    /// True for the first caller only.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }

    // MARK: Files

    nonisolated static let cacheFolder: URL = {
        let caches = ProcessInfo.processInfo.isMacCatalystApp
            ? URL.cachesDirectory.appending(path: "com.onda.player", directoryHint: .isDirectory) : URL.cachesDirectory
        let url = caches.appending(path: "Lossless", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Where a server's file of the song is kept: named by the song, the source, its id and format.
    func cacheURL(for track: Track, _ candidate: LosslessCandidate) -> URL {
        let suffix = candidate.suffix ?? candidate.format?.codec.rawValue ?? "audio"
        return Self.cacheFolder.appending(path: LosslessCacheKey.name(videoId: track.videoId ?? track.id, candidate: candidate) + ".\(suffix)")
    }

    func cachedFile(for track: Track, _ candidate: LosslessCandidate) -> URL? {
        let url = cacheURL(for: track, candidate)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The song's lossless file on the device, for AutoMix: an imported file, a server's file already
    /// kept, or (`fetch`) one fetched now when a server has the song and the network allows it.
    func file(for track: Track, fetch: Bool) async -> URL? {
        guard isEnabled, !track.isPodcastEpisode else { return nil }
        if let entry = LocalLosslessLibrary.shared.entry(forTrackID: track.id) {
            return LocalLosslessLibrary.shared.fileURL(for: entry)
        }
        if let local = localChoice(for: track) { return local.url }
        let decision = fetch ? await decision(for: track, budget: nil) : decisions.decision(for: track.id)
        guard let decision, case .found(let candidate) = decision, !decisions.hasFailed(track.id, candidate) else { return nil }
        if let file = cachedFile(for: track, candidate) { return file }
        guard fetch, remoteAllowed, let client = OpenSubsonicSettings.client, let source = client.downloadURL(id: candidate.id)
        else { return nil }
        let destination = cacheURL(for: track, candidate)
        let key = destination.lastPathComponent
        if let task = fetching[key] { return await task.value }
        let task = Task { () -> URL? in
            defer { self.fetching[key] = nil }
            return await Self.download(source, to: destination)
        }
        fetching[key] = task
        return await task.value
    }

    /// The whole file, kept only if its audio is lossless (a server could send something else).
    private nonisolated static func download(_ source: URL, to destination: URL) async -> URL? {
        do {
            var request = URLRequest(url: source, timeoutInterval: 30)
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            let (temporary, response) = try await OpenSubsonicClient.session.download(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                try? FileManager.default.removeItem(at: temporary)
                return nil
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            guard let format = await AudioFormatProbe.probe(destination), format.isLossless else {
                try? FileManager.default.removeItem(at: destination)
                return nil
            }
            prune()
            return destination
        } catch {
            return nil
        }
    }

    /// The oldest files go first once the cache is over its limit.
    private nonisolated static func prune() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentAccessDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: cacheFolder, includingPropertiesForKeys: keys) else { return }
        var entries = files.compactMap { url -> (URL, Int64, Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentAccessDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        entries.sort { $0.2 < $1.2 }
        for entry in entries where total > cacheLimit {
            try? FileManager.default.removeItem(at: entry.0)
            total -= entry.1
        }
    }
}
