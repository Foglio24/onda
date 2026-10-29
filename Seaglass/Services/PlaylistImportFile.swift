import Foundation

/// A file can contain several playlists; keep each source row, including unsupported entries.
struct PlaylistImportSource: Identifiable {
    struct Row {
        let track: Track
        var issue: PlaylistImportEntry.Issue? = nil
    }
    let id = UUID()
    let name: String
    let rows: [Row]
}

enum PlaylistImportFileError: LocalizedError {
    case unsupported
    case malformedCSV

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return String(localized: "File non riconosciuto. Scegli un file Playlist di Spotify in JSON oppure un CSV con titolo e artista.")
        case .malformedCSV:
            return String(localized: "Il file CSV non è leggibile. Controlla che sia esportato correttamente.")
        }
    }
}

enum PlaylistImportFile {
    /// Spotify's account data export (Playlist1.json) or a CSV such as a playlist export.
    static func read(_ data: Data, fileName: String) throws -> [PlaylistImportSource] {
        if let json = try? JSONSerialization.jsonObject(with: data),
           let root = json as? [String: Any], let lists = root["playlists"] as? [[String: Any]] {
            return lists.map { list in
                let name = clean(list["name"] as? String) ?? String(localized: "Playlist importata")
                let items = list["items"] as? [Any] ?? []
                let rows = items.enumerated().map { index, value -> PlaylistImportSource.Row in
                    let item = value as? [String: Any] ?? [:]
                    let song = item["track"] as? [String: Any] ?? item["localTrack"] as? [String: Any]
                    if let song, let title = clean(song["trackName"] as? String) {
                        let artist = clean(song["artistName"] as? String) ?? ""
                        return .init(track: Track(videoId: nil, title: title, artists: [artist],
                                                  album: clean(song["albumName"] as? String)))
                    }
                    if let episode = item["episode"] as? [String: Any],
                       let title = clean(episode["episodeName"] as? String) {
                        return .init(track: Track(videoId: nil, title: title,
                                                  artists: [clean(episode["showName"] as? String) ?? ""]), issue: .unsupported)
                    }
                    return .init(track: unavailable(index + 1), issue: .unavailable)
                }
                return PlaylistImportSource(name: name, rows: rows)
            }
        }
        guard var text = String(data: data, encoding: .utf8) else { throw PlaylistImportFileError.unsupported }
        if text.first == "\u{FEFF}" { text.removeFirst() }
        let records = try csv(text).filter { $0.contains { clean($0) != nil } }
        guard let header = records.first else { throw PlaylistImportFileError.unsupported }
        let names = header.map(key)
        func index(_ keys: [String]) -> Int? { names.firstIndex { keys.contains($0) } }
        guard let title = index(["trackname", "tracktitle", "songname", "songtitle", "title"]),
              let artist = index(["artistnames", "artistname", "artist", "artists"]) else {
            throw PlaylistImportFileError.unsupported
        }
        let album = index(["albumname", "album"]), milliseconds = index(["trackdurationms", "durationms"])
        func field(_ row: [String], _ index: Int?) -> String? {
            guard let index, row.indices.contains(index) else { return nil }
            return clean(row[index])
        }
        let rows = records.dropFirst().enumerated().map { index, row -> PlaylistImportSource.Row in
            guard let name = field(row, title) else { return .init(track: unavailable(index + 1), issue: .unavailable) }
            let artists = (field(row, artist) ?? "").components(separatedBy: ", ")
            let duration = field(row, milliseconds).flatMap(Double.init).flatMap { $0 > 0 ? $0 / 1000 : nil }
            return .init(track: Track(videoId: nil, title: name, artists: artists,
                                      album: field(row, album), duration: duration))
        }
        let name = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        return [PlaylistImportSource(name: name.isEmpty ? String(localized: "Playlist importata") : name, rows: rows)]
    }

    private static func clean(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func key(_ text: String) -> String {
        String(String.UnicodeScalarView(text.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains)))
    }

    private static func unavailable(_ number: Int) -> Track {
        Track(videoId: nil, title: String(localized: "Brano non disponibile \(number)"), artists: [])
    }

    /// CSV with commas, CRLF, quoted commas/newlines and doubled quotes (RFC 4180).
    static func csv(_ text: String) throws -> [[String]] {
        var records: [[String]] = [], row: [String] = [], field = ""
        var quoted = false, atFieldStart = true
        var i = text.startIndex
        while i < text.endIndex {
            let char = text[i]
            let next = text.index(after: i)
            if quoted {
                if char == "\"" {
                    if next < text.endIndex, text[next] == "\"" { field.append("\""); i = next }
                    else { quoted = false }
                } else { field.append(char) }
            } else if char == "\"" && atFieldStart {
                quoted = true
                atFieldStart = false
            } else if char == "," {
                row.append(field); field = ""; atFieldStart = true
            } else if char == "\n" || char == "\r" || char == "\r\n" {
                row.append(field); records.append(row); row = []; field = ""; atFieldStart = true
            } else {
                field.append(char); atFieldStart = false
            }
            i = text.index(after: i)
        }
        guard !quoted else { throw PlaylistImportFileError.malformedCSV }
        if !row.isEmpty || !field.isEmpty { row.append(field); records.append(row) }
        return records
    }
}
