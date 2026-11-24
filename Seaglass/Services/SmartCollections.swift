import Foundation

/// The library's smart collections: lists that update on the device by themselves, each from a rule
/// that can be checked against data the app already keeps. They are never stored or synced; they
/// are worked out again from the library, the downloads and the listening log each time they show.
enum SmartCollectionKind: String, CaseIterable, Identifiable, Sendable {
    /// The last songs started, from the history.
    case recent
    /// The downloaded songs whose file is on this device.
    case downloaded
    /// Favourites hardly listened to.
    case forgottenFavourites

    var id: String { rawValue }
}

enum SmartCollections {
    /// How many of the history's songs "Ascoltati di recente" shows.
    static let recentLimit = 50
    /// A favourite listened to at most this many times counts as listened to little.
    static let fewListens = 1

    /// A listen that counts: at least 30 seconds, or half of a song shorter than a minute. A song
    /// started and left at once isn't listened to.
    static func counts(_ event: ListenEvent) -> Bool {
        event.listened >= min(30, max(1, (event.length ?? 60) / 2))
    }

    /// The history keeps the songs in the order they last started (the most recent first, each
    /// once, up to 200), with no dates: the recent ones are its first `recentLimit`.
    static func recent(history: [Track]) -> [Track] {
        Array(history.prefix(recentLimit))
    }

    /// The downloads (the most recent first) whose file is on the device.
    static func downloaded(_ downloads: [Track], isOnDevice: (Track) -> Bool) -> [Track] {
        downloads.filter(isOnDevice)
    }

    struct Forgotten: Equatable {
        var tracks: [Track]
        /// Since when the listening log covers this device (its oldest play): nil when it holds none,
        /// and the rule falls back on the history.
        var since: Date?
        /// Counted listens of each song shown (by video ID), with the log.
        var listens: [String: Int]
    }

    /// Favourites listened to at most `fewListens` times since the listening log began (its
    /// oldest play still kept), the least listened first and otherwise in the favourites' order.
    /// With nothing in the log (a new device, or the log cleared), the favourites that aren't among
    /// the history's songs: the only record of plays there is then.
    static func forgottenFavourites(liked: [Track], events: [ListenEvent], history: [Track],
                                    videoId: (Track) -> String?) -> Forgotten {
        guard let since = events.map(\.date).min() else {
            let tracks = liked.filter { favourite in !history.contains { $0.isSameRecording(as: favourite) } }
            return Forgotten(tracks: tracks, since: nil, listens: [:])
        }
        var listens: [String: Int] = [:]
        for event in events where counts(event) { listens[event.videoId, default: 0] += 1 }
        let counted = liked.enumerated().map { position, track -> (position: Int, track: Track, count: Int) in
            (position, track, videoId(track).map { listens[$0] ?? 0 } ?? 0)
        }
        let few = counted.filter { $0.count <= fewListens }
            .sorted { $0.count != $1.count ? $0.count < $1.count : $0.position < $1.position }
        var shown: [String: Int] = [:]
        for entry in few { if let id = videoId(entry.track) { shown[id] = entry.count } }
        return Forgotten(tracks: few.map(\.track), since: since, listens: shown)
    }

    /// The songs of a collection that play without a connection: downloaded, or the user's own.
    static func availableOffline(_ tracks: [Track], isOnDevice: (Track) -> Bool) -> [Track] {
        tracks.filter(isOnDevice)
    }
}
