import Foundation

/// A podcast on YouTube Music, opened from its "MPSP…" page.
struct PodcastShow: Codable, Hashable, Identifiable {
    /// The page's browse ID ("MPSP" and the show's playlist ID).
    let id: String
    var title: String
    var author: String
    var artworkURL: URL?
}

/// An episode, as the podcast's page or a search lists it.
struct PodcastEpisode: Codable, Hashable, Identifiable {
    let videoId: String
    var title: String
    var showTitle: String
    var showID: String?
    /// As YouTube Music writes it: "3 gg fa", "22 ott", "16 giu 2025".
    var date: String?
    /// Rounded to the minute ("34 min"): for the lists only, the player asks for the exact length.
    var listedLength: TimeInterval?
    /// The episode's description, where the chapters are.
    var notes: String?
    /// The episode's own picture (wide, a frame of the video) and the show's square cover, when known.
    var artworkURL: URL?
    var showArtworkURL: URL?

    var id: String { videoId }

    /// An episode known only as the player's track (a queue saved before, a download).
    init?(_ track: Track) {
        guard let videoId = track.videoId, track.isPodcastEpisode else { return nil }
        self.init(videoId: videoId, title: track.title, showTitle: track.album ?? track.artist,
                  showID: track.podcastID.flatMap { $0.isEmpty ? nil : $0 }, artworkURL: track.artworkURL)
    }

    init(videoId: String, title: String, showTitle: String, showID: String?, date: String? = nil,
         listedLength: TimeInterval? = nil, notes: String? = nil, artworkURL: URL? = nil, showArtworkURL: URL? = nil) {
        self.videoId = videoId
        self.title = title
        self.showTitle = showTitle
        self.showID = showID
        self.date = date
        self.listedLength = listedLength
        self.notes = notes
        self.artworkURL = artworkURL
        self.showArtworkURL = showArtworkURL
    }

    /// What the player plays: the show as the album, its square cover rather than the episode's frame.
    var track: Track {
        var track = Track(videoId: videoId, title: title, artists: [showTitle], album: showTitle,
                          artworkURL: showArtworkURL ?? artworkURL)
        track.podcastID = showID ?? ""
        return track
    }

    var chapters: [PodcastChapter] { PodcastChapter.chapters(in: notes ?? "") }
}

/// A chapter of an episode, from the timestamps in its description ("00:00 Intro", "1:02:03 – Q&A").
struct PodcastChapter: Hashable, Identifiable {
    let time: TimeInterval
    let title: String

    var id: TimeInterval { time }

    /// The description's chapters, when it lists at least three in order from the start; nothing
    /// otherwise (a single timestamp in the text is a reference, not a chapter list).
    static func chapters(in notes: String) -> [PodcastChapter] {
        var found: [PodcastChapter] = []
        for line in notes.split(whereSeparator: \.isNewline) {
            guard let chapter = chapter(in: String(line)) else { continue }
            // Timestamps that go back start another list (sponsors, a second part): the first one counts.
            if let last = found.last, chapter.time <= last.time { break }
            found.append(chapter)
        }
        guard found.count >= 3, let first = found.first, first.time <= 60 else { return [] }
        return found
    }

    private static let leadingStamp = #/^[\[(]?((?:\d{1,2}:)?\d{1,2}:\d{2})[\])]?/#
    private static let trailingStamp = #/[\[(]?((?:\d{1,2}:)?\d{1,2}:\d{2})[\])]?$/#
    private static let separators = CharacterSet(charactersIn: "-–—:|•·").union(.whitespaces)

    /// "00:00 Intro", "[1:02:03] Intro", "(12:30) - Intro", "Intro - 12:30".
    private static func chapter(in line: String) -> PodcastChapter? {
        let text = line.trimmingCharacters(in: .whitespaces)
        if let match = text.firstMatch(of: leadingStamp), let time = seconds(String(match.output.1)) {
            let title = String(text[match.range.upperBound...]).trimmingCharacters(in: separators)
            return title.isEmpty ? nil : PodcastChapter(time: time, title: title)
        }
        if let match = text.firstMatch(of: trailingStamp), let time = seconds(String(match.output.1)) {
            let title = String(text[..<match.range.lowerBound]).trimmingCharacters(in: separators)
            return title.isEmpty ? nil : PodcastChapter(time: time, title: title)
        }
        return nil
    }

    /// "1:02:03" or "02:03".
    static func seconds(_ stamp: String) -> TimeInterval? {
        let parts = stamp.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2, parts.count <= 3, parts.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
        return TimeInterval(parts.reduce(0) { $0 * 60 + $1 })
    }
}

/// A podcast's page: what it is about and its episodes, newest first, a page at a time.
struct PodcastShowPage {
    var show: PodcastShow
    var about: String?
    var episodes: [PodcastEpisode]
    /// Asks for the next (older) episodes; nil after the last.
    var continuation: String?
}

/// A row of podcasts YouTube Music suggests ("Podcast per iniziare").
struct PodcastShelf: Identifiable {
    let title: String
    let shows: [PodcastShow]
    var id: String { title }
}
