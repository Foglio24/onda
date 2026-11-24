import Foundation

/// The listening log's plays as listens: what counts, and what is one listen.
enum ListenHistory {
    /// A listen that counts: at least 30 seconds, or half of a song shorter than a minute. A song
    /// started and left at once isn't listened to.
    static func counts(_ event: ListenEvent) -> Bool {
        event.listened >= min(30, max(1, (event.length ?? 60) / 2))
    }

    /// The log's plays with a song taken up again where it was left joined into one listen. Since
    /// 1.37.0 the player does it as it records (`ListeningLog.start(_:resuming:)`), and its plays
    /// (the ones with a title) are taken as they are: two are two listens. The plays recorded before
    /// (no title) were two when a session restored after the app was closed carried on: two of them,
    /// of the same song in a row, the second within 12 hours of the first, that together are no
    /// longer than the song (and 15 seconds) are one listen. A song played whole twice stays two.
    static func merged(_ events: [ListenEvent]) -> [ListenEvent] {
        var result: [ListenEvent] = []
        result.reserveCapacity(events.count)
        for event in events {
            if var last = result.last, last.title == nil, event.title == nil, last.videoId == event.videoId,
               event.date >= last.date, event.date.timeIntervalSince(last.date) < 12 * 3600,
               last.listened + event.listened <= (last.length ?? event.length ?? .infinity) + 15 {
                last.listened += event.listened
                last.skipped = last.skipped && event.skipped
                result[result.count - 1] = last
            } else {
                result.append(event)
            }
        }
        return result
    }
}

/// A month of listening as the listening log recorded it on this device: only what it holds (plays
/// with their artist, length listened and, since this version, title), nothing estimated.
struct MonthlyRecap: Equatable, Sendable {
    struct Artist: Equatable, Sendable {
        let name: String
        let listens: Int
        let minutes: Int
    }

    struct Song: Equatable, Sendable {
        let videoId: String
        let title: String
        let artist: String
        let listens: Int
    }

    /// The month (its first moment) and the part of it the log covers: from its start, or from the
    /// log's first play when that falls inside it.
    let month: Date
    let coveredFrom: Date?
    /// The log's first play on this device (nil: it holds none).
    let logStart: Date?
    let listens: Int
    let minutes: Int
    let artistCount: Int
    let topArtists: [Artist]
    /// The most listened songs whose title is known (plays recorded before this version have none,
    /// unless the library knows the song).
    let topSongs: [Song]
    /// Artists listened to this month and never before in the log; nil when the log doesn't reach
    /// back before the month, so a first time can't be told.
    let discoveries: [String]?

    /// Fewer listens than this make a month with few listens: no ranking is shown for it.
    static let fewListens = 10
    var hasFewListens: Bool { listens < Self.fewListens }

    /// The recap of the month holding `date`. `title` finds a song's title for a play recorded
    /// without one (from the library).
    static func make(events: [ListenEvent], month date: Date, calendar: Calendar = .current,
                     title: (String) -> String? = { _ in nil }) -> MonthlyRecap {
        let interval = calendar.dateInterval(of: .month, for: date) ?? DateInterval(start: date, duration: 0)
        let plays = ListenHistory.merged(events.sorted { $0.date < $1.date })
        let logStart = plays.first?.date
        let inMonth = plays.filter { interval.contains($0.date) }
        let counted = inMonth.filter(ListenHistory.counts)
        let seconds = inMonth.reduce(0) { $0 + max(0, $1.listened) }

        var byArtist: [String: (name: String, listens: Int, seconds: Double)] = [:]
        for play in counted {
            let key = Self.key(play.artist)
            guard !key.isEmpty else { continue }
            var entry = byArtist[key] ?? (play.artist.trimmingCharacters(in: .whitespacesAndNewlines), 0, 0)
            entry.listens += 1
            entry.seconds += play.listened
            byArtist[key] = entry
        }
        let artists = byArtist.values
            .sorted { $0.listens != $1.listens ? $0.listens > $1.listens
                : $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.name < $1.name }
            .map { Artist(name: $0.name, listens: $0.listens, minutes: Int(($0.seconds / 60).rounded())) }

        var bySong: [String: (title: String?, artist: String, listens: Int, first: Date)] = [:]
        for play in counted {
            var entry = bySong[play.videoId] ?? (play.title, play.artist, 0, play.date)
            entry.listens += 1
            if entry.title == nil { entry.title = play.title }
            bySong[play.videoId] = entry
        }
        let songs = bySong.compactMap { id, entry -> (Song, Date)? in
            guard let name = entry.title ?? title(id), !name.isEmpty else { return nil }
            return (Song(videoId: id, title: name, artist: entry.artist, listens: entry.listens), entry.first)
        }
        .sorted { $0.0.listens != $1.0.listens ? $0.0.listens > $1.0.listens : $0.1 < $1.1 }
        .map(\.0)

        var discoveries: [String]?
        if let logStart, logStart < interval.start {
            let before = Set(plays.filter { $0.date < interval.start }.map { Self.key($0.artist) })
            discoveries = artists.filter { !before.contains(Self.key($0.name)) }.map(\.name)
        }
        let coveredFrom = logStart.map { max($0, interval.start) }.flatMap { $0 < interval.end ? $0 : nil }
        return MonthlyRecap(month: interval.start, coveredFrom: coveredFrom, logStart: logStart, listens: counted.count,
                            minutes: Int((seconds / 60).rounded()), artistCount: byArtist.count,
                            topArtists: Array(artists.prefix(5)), topSongs: Array(songs.prefix(3)), discoveries: discoveries)
    }

    /// The months with plays in the log, the most recent first (the current one always first).
    static func months(events: [ListenEvent], now: Date = .now, calendar: Calendar = .current) -> [Date] {
        var months = Set<Date>()
        if let current = calendar.dateInterval(of: .month, for: now)?.start { months.insert(current) }
        for event in events {
            if let start = calendar.dateInterval(of: .month, for: event.date)?.start { months.insert(start) }
        }
        return months.sorted(by: >)
    }

    /// Artists as one whatever their case and spacing.
    private static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
