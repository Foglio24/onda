import Foundation

/// A folder the user chose for their own songs, kept as a bookmark (see `LocalMusic`).
struct LocalFolder: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var bookmark: Data
}

/// What is known of one audio file in a chosen folder, kept between launches so that only new or
/// changed files are read again.
struct LocalFile: Codable, Hashable, Sendable {
    /// The song's ID (`Track.isLocalID`): from its folder and its place in it.
    var id: String
    var folder: String
    /// Where it is in its folder, with `/` between the names.
    var path: String
    var size: Int64
    /// Its modification date, seconds since 1970.
    var modified: TimeInterval
    var title: String
    var artist: String
    var album: String?
    var duration: TimeInterval?
    /// The embedded cover's key (`LocalMusicIndex.coverKey`), the name of its file.
    var cover: String?
}

/// What `LocalMusic` keeps on disk.
struct LocalMusicStore: Codable, Sendable {
    var folders: [LocalFolder]
    var files: [LocalFile]
}

/// The pure part of the user's own songs: which files count, their IDs, what a new scan has to read
/// again, their titles when their tags have none, their order and the search. Foundation only, so a
/// check can run it on its own (Tools/LocalMusicCheck).
enum LocalMusicIndex {
    /// The formats AVPlayer plays from a file.
    static let audioExtensions: Set<String> = ["mp3", "m4a", "m4b", "aac", "wav", "wave", "aif", "aiff", "aifc", "caf", "flac"]

    static func isAudio(_ fileName: String) -> Bool {
        audioExtensions.contains((fileName as NSString).pathExtension.lowercased())
    }

    /// FNV-1a over `bytes`, 64 bits: stable between launches and devices, unlike `hashValue`.
    private static func fnv<S: Sequence>(_ bytes: S) -> UInt64 where S.Element == UInt8 {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01b3
        }
        return value
    }

    private static func hex(_ value: UInt64) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: max(0, 16 - digits.count)) + digits
    }

    /// A song's ID: the same file in the same folder has the same one every time, so favourites,
    /// playlists and the history keep finding it.
    static func trackID(folder: String, path: String) -> String {
        Track.localPrefix + hex(fnv("\(folder)|\(path)".utf8))
    }

    /// A folder's ID, from where it is: choosing the same folder again brings its songs back.
    static func folderID(path: String) -> String {
        hex(fnv(path.utf8))
    }

    /// An embedded cover's key: songs of an album share one file.
    static func coverKey(_ data: Data) -> String {
        hex(fnv(data)) + String(data.count, radix: 16)
    }

    /// A file found in a folder.
    struct Found: Hashable, Sendable {
        var path: String
        var size: Int64
        var modified: TimeInterval
    }

    /// What a scan has to do with what it found, against what was known of the folder.
    struct Plan {
        /// Known and unchanged: not read again.
        var kept: [LocalFile]
        /// New or changed: to read.
        var toRead: [Found]
        /// Known, no longer there.
        var removed: [LocalFile]
    }

    static func plan(previous: [LocalFile], found: [Found]) -> Plan {
        var known: [String: LocalFile] = [:]
        for file in previous { known[file.path] = file }
        var kept: [LocalFile] = []
        var toRead: [Found] = []
        var seen = Set<String>()
        for item in found {
            seen.insert(item.path)
            if let old = known[item.path], old.size == item.size, abs(old.modified - item.modified) < 1 {
                kept.append(old)
            } else {
                toRead.append(item)
            }
        }
        let removed = previous.filter { !seen.contains($0.path) }
        return Plan(kept: kept, toRead: toRead, removed: removed)
    }

    /// A title from a file's name, for a file whose tags have none: without its extension and a leading
    /// track number ("01 - ", "1. ", "03_", a zero-padded "07 "). A number that is part of the title
    /// ("21 Guns", "99 Luftballons") stays.
    static func fallbackTitle(_ fileName: String) -> String {
        var name = (fileName as NSString).deletingPathExtension
        let patterns = [#"^\d{1,3}\s*[-._]\s*"#, #"^0\d\s+"#]
        for pattern in patterns {
            if let range = name.range(of: pattern, options: .regularExpression), range.upperBound < name.endIndex {
                name = String(name[range.upperBound...])
                break
            }
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? fileName : trimmed
    }

    /// The song as the app's lists have it.
    static func track(_ file: LocalFile) -> Track {
        let artists: [String] = file.artist.isEmpty ? [] : [file.artist]
        return Track(videoId: file.id, title: file.title, artists: artists, album: file.album, duration: file.duration)
    }

    /// Text without case or accents, for ordering and searching.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// By artist, then album, then place in the folder (whose names usually start with the track
    /// number), numbers in names counted as numbers.
    static func sorted(_ files: [LocalFile]) -> [LocalFile] {
        struct Keyed {
            let artist: String
            let album: String
            let file: LocalFile
        }
        let keyed = files.map { Keyed(artist: fold($0.artist), album: fold($0.album ?? ""), file: $0) }
        let ordered = keyed.sorted { a, b in
            if a.artist != b.artist { return a.artist < b.artist }
            if a.album != b.album { return a.album < b.album }
            return a.file.path.localizedStandardCompare(b.file.path) == .orderedAscending
        }
        return ordered.map { $0.file }
    }

    /// What a song is searched by: its title, artist and album, folded.
    static func haystack(_ file: LocalFile) -> String {
        fold("\(file.title) \(file.artist) \(file.album ?? "")")
    }

    /// Whether every word of `query` is somewhere in `haystack` (a `haystack(_:)`).
    static func matches(_ haystack: String, query: String) -> Bool {
        let words = fold(query).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return false }
        for word in words where !haystack.contains(word) { return false }
        return true
    }
}
