import Foundation

enum PlaylistImportMatch {
    case matched(Track)
    case issue(PlaylistImportEntry.Issue)
}

/// One row in the source, kept even if YouTube Music couldn't resolve it.
struct PlaylistImportEntry: Codable, Hashable, Identifiable {
    enum Issue: String, Codable {
        case notFound
        case searchFailed
        case duplicate
        case unavailable
        case unsupported
    }

    let id: UUID
    let original: Track
    var matchedVideoID: String?
    var issue: Issue?
    var isIgnored: Bool? = nil

    init(original: Track, matchedVideoID: String? = nil, issue: Issue? = nil) {
        id = UUID()
        self.original = original
        self.matchedVideoID = matchedVideoID
        self.issue = issue
    }
}

struct PlaylistImportReport: Codable, Hashable {
    let service: String
    var entries: [PlaylistImportEntry]
    /// The public Spotify embed can stop at 100 without saying how many remain.
    let mayBeTruncated: Bool

    var pending: [PlaylistImportEntry] { entries.filter { $0.issue != nil && $0.isIgnored != true } }
    var ignored: [PlaylistImportEntry] { entries.filter { $0.issue != nil && $0.isIgnored == true } }

    enum Resolution: Equatable {
        case added
        case alreadyPresent
        case missing
    }

    /// Report every source row, including duplicate recordings and failed searches.
    static func assemble(service: String, rows: [PlaylistImportSource.Row], matches: [PlaylistImportMatch],
                         mayBeTruncated: Bool) -> (tracks: [Track], report: PlaylistImportReport) {
        var found: [Track] = [], entries: [PlaylistImportEntry] = [], seen = Set<String>()
        for (index, row) in rows.enumerated() {
            let result: PlaylistImportMatch = matches.indices.contains(index) ? matches[index] : .issue(.searchFailed)
            switch result {
            case .matched(let track):
                guard let videoID = track.videoId else {
                    entries.append(PlaylistImportEntry(original: row.track, issue: .notFound))
                    continue
                }
                if seen.insert(videoID).inserted {
                    found.append(track.retainingIdentity(of: row.track))
                    entries.append(PlaylistImportEntry(original: row.track, matchedVideoID: videoID))
                } else {
                    entries.append(PlaylistImportEntry(original: row.track, issue: .duplicate))
                }
            case .issue(let issue):
                entries.append(PlaylistImportEntry(original: row.track, issue: issue))
            }
        }
        return (found, PlaylistImportReport(service: service, entries: entries, mayBeTruncated: mayBeTruncated))
    }

    /// Add a manually chosen recording near its original neighbors, without reordering edits.
    mutating func resolve(_ entryID: UUID, with selected: Track, in tracks: inout [Track]) -> Resolution {
        guard let position = entries.firstIndex(where: { $0.id == entryID && $0.issue != nil && $0.isIgnored != true }),
              let videoID = selected.videoId else { return .missing }
        guard !tracks.contains(where: { $0.videoId == videoID }) else { return .alreadyPresent }
        let following = entries.dropFirst(position + 1).compactMap(\.matchedVideoID)
        let preceding = entries.prefix(position).reversed().compactMap(\.matchedVideoID)
        var insertAt: Int?
        for id in following {
            if let index = tracks.firstIndex(where: { $0.videoId == id }) { insertAt = index; break }
        }
        if insertAt == nil {
            for id in preceding {
                if let index = tracks.firstIndex(where: { $0.videoId == id }) { insertAt = index + 1; break }
            }
        }
        tracks.insert(selected.retainingIdentity(of: entries[position].original), at: insertAt ?? tracks.count)
        entries[position].matchedVideoID = videoID
        entries[position].issue = nil
        return .added
    }

    mutating func ignore(_ entryID: UUID) {
        guard let position = entries.firstIndex(where: { $0.id == entryID && $0.issue != nil }) else { return }
        entries[position].isIgnored = true
    }

    mutating func restore(_ entryID: UUID) {
        guard let position = entries.firstIndex(where: { $0.id == entryID && $0.issue != nil }) else { return }
        entries[position].isIgnored = false
    }
}
