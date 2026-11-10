import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// The user's own lossless files (FLAC, ALAC, WAV, AIFF), imported in Libreria › File lossless: kept
/// in the app's own folder, as they were (never converted), and played instead of the catalogue's
/// stream of the same recording (see `LosslessSources`), or on their own. Deleted only by the user.
@MainActor
final class LocalLosslessLibrary: ObservableObject {
    static let shared = LocalLosslessLibrary()

    struct Entry: Codable, Identifiable, Hashable, Sendable {
        var id: String
        /// The file's name in `folder`.
        var fileName: String
        var title: String
        var artists: [String]
        var album: String?
        var duration: TimeInterval?
        var isrcs: [String]
        var format: AudioFormatInfo
        var addedAt: Date
    }

    /// Files that could not be imported, and why.
    struct Rejection: Identifiable, Sendable {
        let id = UUID()
        let name: String
        let reason: String
    }

    /// The file types that can hold lossless audio; each file's own audio decides (an .m4a may be AAC).
    static let types: [UTType] = [UTType(filenameExtension: "flac"), .mpeg4Audio, .wav, .aiff,
                                  UTType(filenameExtension: "caf")].compactMap { $0 }

    static let folder: URL = {
        let url = Storage.support.appending(path: "Lossless", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    private static var index: URL { folder.appending(path: "index.json") }

    @Published private(set) var entries: [Entry] = []

    private init() {
        if let data = try? Data(contentsOf: Self.index),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            // Files removed outside the app (Files, Finder) leave the list.
            entries = saved.filter { FileManager.default.fileExists(atPath: Self.folder.appending(path: $0.fileName).path) }
        }
    }

    func fileURL(for entry: Entry) -> URL { Self.folder.appending(path: entry.fileName) }

    func entry(id: String) -> Entry? { entries.first { $0.id == id } }

    /// The entry a library song made from an imported file stands for ("lossless:<id>").
    func entry(forTrackID trackID: String) -> Entry? {
        guard trackID.hasPrefix(Self.trackPrefix) else { return nil }
        return entry(id: String(trackID.dropFirst(Self.trackPrefix.count)))
    }

    static let trackPrefix = "lossless:"

    /// A song for the queue and the library, playing the file itself.
    func track(for entry: Entry) -> Track {
        var track = Track(videoId: nil, title: entry.title, artists: entry.artists, album: entry.album, duration: entry.duration)
        track.id = Self.trackPrefix + entry.id
        return track
    }

    var candidates: [LosslessCandidate] {
        entries.map { entry in
            LosslessCandidate(source: .localFile, id: entry.id, scope: "local", title: entry.title, artists: entry.artists,
                              album: entry.album, duration: entry.duration, isrcs: entry.isrcs, format: entry.format,
                              suffix: (entry.fileName as NSString).pathExtension.lowercased())
        }
    }

    /// Copies the files in (they stay where they were too), keeping those whose audio is lossless.
    func importFiles(_ urls: [URL]) async -> (imported: Int, rejected: [Rejection]) {
        var imported = 0
        var rejected: [Rejection] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let name = url.lastPathComponent
            let suffix = url.pathExtension.lowercased()
            let id = UUID().uuidString
            let destination = Self.folder.appending(path: "\(id).\(suffix.isEmpty ? "audio" : suffix)")
            do {
                // Off the main thread: a hi-res album's files run to hundreds of megabytes.
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.copyItem(at: url, to: destination)
                }.value
            } catch {
                rejected.append(Rejection(name: name, reason: error.localizedDescription))
                continue
            }
            let asset = AVURLAsset(url: destination)
            guard let format = await AudioFormatProbe.probe(asset), format.isLossless else {
                try? FileManager.default.removeItem(at: destination)
                rejected.append(Rejection(name: name, reason: String(localized: "Non è un file lossless (FLAC, ALAC, WAV o AIFF).")))
                continue
            }
            let tags = await Self.tags(of: asset, fallbackName: url.deletingPathExtension().lastPathComponent)
            let seconds = (try? await asset.load(.duration)).map(\.seconds)
            entries.append(Entry(id: id, fileName: destination.lastPathComponent, title: tags.title, artists: tags.artists,
                                 album: tags.album, duration: seconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
                                 isrcs: tags.isrcs, format: format, addedAt: .now))
            imported += 1
        }
        save()
        return (imported, rejected)
    }

    func remove(_ entry: Entry) {
        try? FileManager.default.removeItem(at: fileURL(for: entry))
        entries.removeAll { $0.id == entry.id }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: Self.index, options: .atomic)
    }

    /// Title, artists, album and ISRC from the file's tags (ID3, iTunes, Vorbis comments: whatever
    /// AVFoundation reads), else "Artist - Title" from the file's name.
    private static func tags(of asset: AVURLAsset, fallbackName: String) async -> (title: String, artists: [String], album: String?, isrcs: [String]) {
        let items = (try? await asset.load(.metadata)) ?? []
        var title: String?, artist: String?, album: String?, isrcs: [String] = []
        for item in items {
            let key = (item.commonKey?.rawValue ?? (item.key as? String) ?? item.identifier?.rawValue ?? "").lowercased()
            guard let value = try? await item.load(.stringValue), !value.isEmpty else { continue }
            if key == "title" || key.hasSuffix("/title") || key.hasSuffix("tit2") || key.hasSuffix("©nam") || key.hasSuffix("%a9nam") {
                title = title ?? value
            } else if key == "artist" || key.hasSuffix("/artist") || key.hasSuffix("tpe1") || key.hasSuffix("©art") || key.hasSuffix("%a9art") {
                artist = artist ?? value
            } else if key == "albumname" || key == "album" || key.hasSuffix("/album") || key.hasSuffix("talb") || key.hasSuffix("©alb")
                        || key.hasSuffix("%a9alb") {
                album = album ?? value
            } else if key.contains("isrc") || key.hasSuffix("tsrc") {
                isrcs.append(value)
            }
        }
        if title == nil || artist == nil {
            let parts = fallbackName.components(separatedBy: " - ")
            if parts.count >= 2 {
                artist = artist ?? parts[0].trimmingCharacters(in: .whitespaces)
                title = title ?? parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces)
            }
        }
        let artists = (artist ?? "").components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return (title ?? fallbackName, artists, album, isrcs)
    }
}
