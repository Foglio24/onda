import AVFoundation
import Foundation
import ImageIO

/// The user's own songs: audio files in folders chosen on the device (Files, iCloud Drive, a USB
/// drive), played from where they are. A folder is kept as a bookmark that keeps the access the picker
/// gave, its files are listed and their tags and covers read once (again only when a file is new or
/// changed), and the songs play, queue, mix and sing along as any song does: `Storage.localAudio` gives
/// the player their file. Seaglass only reads these files: it never writes to them, copies them or
/// deletes them, and nothing of them is sent anywhere or synced to the account.
@MainActor
final class LocalMusic: ObservableObject {
    static let shared = LocalMusic()

    @Published private(set) var folders: [LocalFolder] = []
    /// The songs of the folders that can be opened, in order.
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var scanning = false
    /// Files read so far in the scan that is running.
    @Published private(set) var scanned = 0
    /// Folders that can't be opened now (moved, deleted, a drive that isn't there).
    @Published private(set) var unreachable: Set<String> = []

    private var files: [LocalFile] = []
    /// The folders being read, each with the URL its access was opened on.
    private var access: [String: URL] = [:]
    private var scopedURLs: [URL] = []
    private var scan: Task<Void, Never>?
    private var scannedOnce = false
    /// `LocalMusicIndex.haystack` of each of `tracks`, same order, for the search.
    private var haystacks: [String] = []

    private static let storeURL = Storage.support.appending(path: "LocalMusic.json")

    private init() {
        // The user's songs have their own cache names for AutoMix (their file names repeat).
        AutoMixLibrary.customKey = { LocalFiles.analysisKey(for: $0) }
        load()
    }

    // MARK: Folders

    /// A folder the user picked in the Files picker: kept, opened and read. False when it can't be kept
    /// (no bookmark could be made of it, or it can't be opened).
    @discardableResult
    func add(folder url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { return false }
        // The same folder again keeps its songs (the ID comes from where it is).
        let id = LocalMusicIndex.folderID(path: url.standardizedFileURL.path)
        folders.removeAll { $0.id == id }
        folders.append(LocalFolder(id: id, name: url.lastPathComponent, bookmark: bookmark))
        openFolders()
        // A folder that can't be opened is not kept: it would only sit in the list, unreachable.
        guard access[id] != nil else {
            folders.removeAll { $0.id == id }
            publish()
            return false
        }
        publish()
        save()
        rescan()
        return true
    }

    /// Takes a folder out of the app: its files stay where they are, untouched.
    func remove(_ folder: LocalFolder) {
        // A scan under way would bring its files back.
        scan?.cancel()
        scanning = false
        folders.removeAll { $0.id == folder.id }
        files.removeAll { $0.folder == folder.id }
        openFolders()
        publish()
        save()
        removeUnusedCovers()
    }

    /// Reads the folders again when the page is opened for the first time since the app started.
    func refreshOnce() {
        guard !scannedOnce else { return }
        rescan()
    }

    // MARK: Search

    /// The songs whose title, artist or album has every word of `query`.
    func search(_ query: String, limit: Int = 50) -> [Track] {
        var found: [Track] = []
        for (index, haystack) in haystacks.enumerated() where LocalMusicIndex.matches(haystack, query: query) {
            found.append(tracks[index])
            if found.count >= limit { break }
        }
        return found
    }

    // MARK: Opening

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let stored = try? JSONDecoder().decode(LocalMusicStore.self, from: data) else { return }
        folders = stored.folders
        files = stored.files
        openFolders()
        publish()
    }

    private func save() {
        let store = LocalMusicStore(folders: folders, files: files)
        let url = Self.storeURL
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(store) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Opens the access of every folder from its bookmark (kept open while the app runs).
    private func openFolders() {
        for url in scopedURLs { url.stopAccessingSecurityScopedResource() }
        scopedURLs = []
        access = [:]
        var closed = Set<String>()
        var refreshed = false
        for index in folders.indices {
            var stale = false
            let resolved = try? URL(resolvingBookmarkData: folders[index].bookmark, options: [], relativeTo: nil,
                                    bookmarkDataIsStale: &stale)
            guard let url = resolved else {
                closed.insert(folders[index].id)
                continue
            }
            let scoped = url.startAccessingSecurityScopedResource()
            // On a Mac the app isn't sandboxed: a folder opens without a scope.
            guard scoped || FileManager.default.isReadableFile(atPath: url.path) else {
                closed.insert(folders[index].id)
                continue
            }
            if scoped { scopedURLs.append(url) }
            if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                folders[index].bookmark = fresh
                refreshed = true
            }
            access[folders[index].id] = url
        }
        unreachable = closed
        if refreshed { save() }
    }

    /// Hands the player the songs' files, and the lists their tracks.
    private func publish() {
        var entries: [String: LocalFiles.Entry] = [:]
        var reachable: [LocalFile] = []
        for file in files {
            guard let base = access[file.folder] else { continue }
            reachable.append(file)
            let url = base.appending(path: file.path)
            let ext = (file.path as NSString).pathExtension.uppercased()
            var cover: URL?
            if let key = file.cover { cover = Storage.localCovers.appending(path: "\(key).jpg") }
            entries[file.id] = LocalFiles.Entry(url: url, label: ext.isEmpty ? "Audio" : ext, cover: cover,
                                                analysisKey: "\(file.id)-\(String(file.size, radix: 16))")
        }
        LocalFiles.replace(with: entries)
        let ordered = LocalMusicIndex.sorted(reachable)
        tracks = ordered.map { LocalMusicIndex.track($0) }
        haystacks = ordered.map { LocalMusicIndex.haystack($0) }
    }

    // MARK: Scanning

    /// Lists the folders again and reads the tags of the files that are new or changed, a few at a time,
    /// showing the songs as they come.
    func rescan() {
        scan?.cancel()
        var targets: [(id: String, base: URL)] = []
        for folder in folders {
            if let base = access[folder.id] { targets.append((folder.id, base)) }
        }
        guard !targets.isEmpty else {
            scanning = false
            return
        }
        scannedOnce = true
        scanning = true
        scanned = 0
        let previous = files
        scan = Task {
            let scanIDs = Set(targets.map { $0.id })
            // What belongs to folders not read now (one that can't be opened) stays as it was.
            var result = previous.filter { !scanIDs.contains($0.folder) }
            var lastShown = 0
            for target in targets {
                let base = target.base
                let found = await Task.detached(priority: .utility) { Self.list(base) }.value
                if Task.isCancelled { return }
                let folderID = target.id
                let known = previous.filter { $0.folder == folderID }
                let plan = LocalMusicIndex.plan(previous: known, found: found)
                result += plan.kept
                var start = 0
                while start < plan.toRead.count {
                    if Task.isCancelled { return }
                    let slice = Array(plan.toRead[start..<min(start + 8, plan.toRead.count)])
                    start += slice.count
                    let batch = await Self.readBatch(base: base, folder: folderID, slice: slice)
                    result += batch
                    self.scanned += batch.count
                    // The list grows every few hundred files (ordering a long one takes a moment).
                    if result.count - lastShown >= 400 {
                        lastShown = result.count
                        self.files = result
                        self.publish()
                    }
                }
            }
            self.files = result
            self.publish()
            self.save()
            self.scanning = false
            self.removeUnusedCovers()
        }
    }

    /// The audio files of a folder and its subfolders.
    nonisolated private static func list(_ base: URL) -> [LocalMusicIndex.Found] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        // The names between the root and the file ("/" is only the root, or a trailing slash).
        let baseCount = base.pathComponents.filter { $0 != "/" }.count
        var found: [LocalMusicIndex.Found] = []
        for case let url as URL in walker {
            guard LocalMusicIndex.isAudio(url.lastPathComponent),
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let parts = url.pathComponents.filter { $0 != "/" }
            guard parts.count > baseCount else { continue }
            let path = parts[baseCount...].joined(separator: "/")
            let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            found.append(LocalMusicIndex.Found(path: path, size: Int64(values.fileSize ?? 0), modified: modified))
        }
        return found
    }

    nonisolated private static func readBatch(base: URL, folder: String, slice: [LocalMusicIndex.Found]) async -> [LocalFile] {
        await withTaskGroup(of: LocalFile.self) { group in
            for item in slice {
                group.addTask { await Self.read(base: base, folder: folder, item: item) }
            }
            var out: [LocalFile] = []
            for await file in group { out.append(file) }
            return out
        }
    }

    /// A file's tags (title, artist, album, length, cover); its name stands in for a missing title.
    nonisolated private static func read(base: URL, folder: String, item: LocalMusicIndex.Found) async -> LocalFile {
        let url = base.appending(path: item.path)
        let asset = AVURLAsset(url: url)
        var title: String?
        var artist: String?
        var album: String?
        var artwork: Data?
        if let metadata = try? await asset.load(.commonMetadata) {
            title = await text(metadata, .commonIdentifierTitle)
            artist = await text(metadata, .commonIdentifierArtist)
            album = await text(metadata, .commonIdentifierAlbumName)
            artwork = await data(metadata, .commonIdentifierArtwork)
        }
        var length: TimeInterval?
        if let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds > 0 {
            length = duration.seconds
        }
        let name = (item.path as NSString).lastPathComponent
        var cover: String?
        if let artwork { cover = saveCover(artwork) }
        return LocalFile(id: LocalMusicIndex.trackID(folder: folder, path: item.path), folder: folder, path: item.path,
                         size: item.size, modified: item.modified,
                         title: title ?? LocalMusicIndex.fallbackTitle(name), artist: artist ?? "", album: album,
                         duration: length, cover: cover)
    }

    nonisolated private static func text(_ items: [AVMetadataItem], _ identifier: AVMetadataIdentifier) async -> String? {
        guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier).first,
              let value = try? await item.load(.stringValue) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated private static func data(_ items: [AVMetadataItem], _ identifier: AVMetadataIdentifier) async -> Data? {
        guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier).first else { return nil }
        return try? await item.load(.dataValue)
    }

    // MARK: Covers

    /// An embedded cover as a small JPEG in the app's own folder, named by its content (the songs of an
    /// album share one); its key, or nil when it can't be read.
    nonisolated private static func saveCover(_ data: Data) -> String? {
        let key = LocalMusicIndex.coverKey(data)
        let file = Storage.localCovers.appending(path: "\(key).jpg")
        if FileManager.default.fileExists(atPath: file.path) { return key }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 600,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, "public.jpeg" as CFString, 1, nil) else { return nil }
        let quality: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.8]
        CGImageDestinationAddImage(destination, image, quality as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        do {
            try (output as Data).write(to: file, options: .atomic)
        } catch {
            return nil
        }
        return key
    }

    /// Covers no song uses any more (a folder taken out, a file gone), removed from the app's own folder.
    private func removeUnusedCovers() {
        let used = Set(files.compactMap { $0.cover }.map { "\($0).jpg" })
        let folder = Storage.localCovers
        Task.detached(priority: .utility) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names where name.hasSuffix(".jpg") && !used.contains(name) {
                try? FileManager.default.removeItem(at: folder.appending(path: name))
            }
        }
    }
}
