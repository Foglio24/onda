import Foundation
import UIKit

/// What was played, for how long and what was skipped: what the recommendations learn from
/// (see `TasteProfile`). Kept only on the iPhone, the last 3000 plays (a few months of listening).
@MainActor
final class ListeningLog {
    static let shared = ListeningLog()

    private(set) var events: [ListenEvent] = []
    /// Bumped on every change, so recommendations know when to look again.
    private(set) var revision = 0
    /// The song playing now is the last event; set while it is.
    private var isOpen = false
    private var skipRequested = false
    private var saveTask: Task<Void, Never>?
    private static let limit = 3000
    private static var file: URL { Storage.support.appending(path: "listening.json") }

    private init() {
        if let data = try? Data(contentsOf: Self.file),
           let saved = try? JSONDecoder().decode([ListenEvent].self, from: data) {
            events = saved
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ListeningLog.shared.save() }
        }
    }

    /// A song starts: the previous one is closed.
    func start(_ track: Track) {
        close()
        guard let videoId = track.videoId else { return }
        events.append(ListenEvent(videoId: videoId, artist: track.primaryArtist, date: .now, listened: 0,
                                  length: track.duration, skipped: false))
        if events.count > Self.limit { events.removeFirst(events.count - Self.limit) }
        isOpen = true
        changed()
    }

    /// Called four times a second while playing: only counts, the file is written when the song
    /// changes or the app goes to the background.
    func addListened(_ seconds: TimeInterval) {
        guard isOpen, !events.isEmpty else { return }
        events[events.count - 1].listened += seconds
    }

    /// "Next" was pressed: the song counts as skipped if it played less than 30 seconds.
    func noteSkip() {
        skipRequested = true
    }

    /// Closes the song that was playing, deciding whether it was skipped.
    func close() {
        defer { skipRequested = false }
        guard isOpen, !events.isEmpty else { return }
        isOpen = false
        let last = events[events.count - 1]
        if skipRequested, last.listened < 30, (last.length ?? 0) > 60 {
            events[events.count - 1].skipped = true
            changed()
        }
    }

    /// Forgets songs removed from the history (all of them when nil).
    func remove(_ videoIds: Set<String>? = nil) {
        if let videoIds { events.removeAll { videoIds.contains($0.videoId) } } else { events.removeAll() }
        isOpen = false
        changed()
    }

    private func changed() {
        revision += 1
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self.save()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(events) else { return }
        try? data.write(to: Self.file, options: .atomic)
    }
}
