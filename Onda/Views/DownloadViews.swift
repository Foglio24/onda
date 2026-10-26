import SwiftUI

// MARK: Marks

/// A ring that fills up clockwise, like the Music app's download progress.
/// With `showsStop`, a small square in the middle says a tap stops it.
struct ProgressRing: View {
    let value: Double
    var size: CGFloat = 17
    var lineWidth: CGFloat = 2
    var showsStop = true

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.3), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.03, min(value, 1)))
                .stroke(.tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.35), value: value)
            if showsStop {
                RoundedRectangle(cornerRadius: size * 0.08)
                    .fill(.tint)
                    .frame(width: size * 0.3, height: size * 0.3)
            }
        }
        .frame(width: size, height: size)
    }
}

/// The Music app's download marks: a dotted circle while waiting, a ring filling up while
/// downloading, a small arrow once the song is on the iPhone. Nothing for other songs.
struct DownloadIndicator: View {
    let state: DownloadState
    var size: CGFloat = 17

    var body: some View {
        switch state {
        case .none:
            EmptyView()
        case .waiting:
            Circle()
                .strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [2, 2.6]))
                .frame(width: size, height: size)
                .accessibilityLabel("In attesa di download")
        case .downloading(let value):
            ProgressRing(value: value, size: size)
                .accessibilityLabel("Download in corso")
                .accessibilityValue(Text(value, format: .percent.precision(.fractionLength(0))))
        case .downloaded:
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: size * 0.85))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .accessibilityLabel("Scaricato")
        }
    }
}

// MARK: Albums and playlists

/// Saves a whole album or playlist, like the Music app's download button: an arrow, then a ring
/// that fills up as the songs arrive (tap to stop), then a tick once everything is on the iPhone.
/// The caller picks the button style.
struct CollectionDownloadButton: View {
    let tracks: [Track]
    var downloadTitle = String(localized: "Scarica")
    var doneTitle = String(localized: "Scaricato")
    /// For a button that shares its row: "3/12" instead of the full sentence while downloading.
    var compact = false
    var verticalPadding: CGFloat = 4

    @EnvironmentObject private var downloads: DownloadManager

    var body: some View {
        let status = downloads.status(of: tracks)
        let isComplete = status.total > 0 && status.saved == status.total
        Button {
            if status.inProgress > 0 {
                downloads.cancel(tracks)
            } else {
                downloads.downloadAll(tracks)
            }
        } label: {
            HStack(spacing: 8) {
                if status.inProgress > 0 {
                    ProgressRing(value: status.fraction, size: 18)
                    if compact {
                        Text(verbatim: "\(status.saved)/\(status.total)")
                            .monospacedDigit()
                    } else {
                        Text("Download \(status.saved)/\(status.total) · tocca per fermare")
                            .monospacedDigit()
                    }
                } else if isComplete {
                    Image(systemName: "checkmark.circle.fill")
                    Text(doneTitle)
                } else {
                    Image(systemName: "arrow.down.circle.fill")
                    if status.saved > 0 {
                        Text("Scarica i restanti \(status.total - status.saved)")
                    } else {
                        Text(downloadTitle)
                    }
                }
            }
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(maxWidth: .infinity)
            .padding(.vertical, verticalPadding)
            .contentShape(.capsule)
            .animation(.smooth(duration: 0.3), value: status.inProgress > 0)
        }
        .disabled(tracks.isEmpty || (isComplete && status.inProgress == 0))
    }
}

// MARK: Library → Download

enum DownloadSort: String, CaseIterable, Identifiable {
    case recent, title, artist

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recent: return String(localized: "Scaricati di recente")
        case .title: return String(localized: "Titolo")
        case .artist: return String(localized: "Artista")
        }
    }
}

/// Library → Download, like the Music app's Downloaded section: what is on the iPhone and the
/// space it takes, the songs still downloading with their progress, and a choice of order.
struct DownloadsView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var downloads: DownloadManager
    @AppStorage("downloads.sort") private var sort: DownloadSort = .recent
    @State private var totalSize: Int64 = 0
    @State private var showStorage = false
    @State private var confirmCancel = false

    private var songs: [Track] {
        let songs = library.downloads
        switch sort {
        case .recent:
            return songs
        case .title:
            return songs.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .artist:
            return songs.sorted {
                let order = $0.primaryArtist.localizedStandardCompare($1.primaryArtist)
                return order == .orderedSame
                    ? $0.title.localizedStandardCompare($1.title) == .orderedAscending
                    : order == .orderedAscending
            }
        }
    }

    private var pending: [Track] { downloads.active + downloads.waiting }

    var body: some View {
        let songs = self.songs
        List {
            if !songs.isEmpty {
                summary(songs)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                PlayShuffleButtons(tracks: songs, source: String(localized: "Download"))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if !pending.isEmpty {
                Section {
                    ForEach(pending) { track in
                        PendingDownloadRow(track: track)
                            .listRowBackground(Color.clear)
                    }
                } header: {
                    pendingHeader
                }
            }

            Section {
                ForEach(Array(songs.enumerated()), id: \.element.id) { position, track in
                    TrackRow(track: track) {
                        player.play(songs, startAt: position, source: String(localized: "Download"))
                    }
                    .listRowBackground(Color.clear)
                }
                .onDelete { offsets in
                    for track in offsets.map({ songs[$0] }) { downloads.remove(track) }
                }
            } header: {
                if !pending.isEmpty, !songs.isEmpty {
                    Text("Sull'iPhone")
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background { AmbientBackground() }
        .overlay {
            if songs.isEmpty, pending.isEmpty {
                ContentUnavailableView("Nessun download", systemImage: "arrow.down.circle",
                                       description: Text("Tocca ··· accanto a un brano e scegli Scarica."))
            }
        }
        .navigationTitle("Download")
        .toolbar {
            Menu {
                Picker("Ordina per", selection: $sort) {
                    ForEach(DownloadSort.allCases) { Text($0.title).tag($0) }
                }
                Button { showStorage = true } label: {
                    Label("Spazio occupato", systemImage: "internaldrive")
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
            }
            .accessibilityLabel("Opzioni")
        }
        .navigationDestination(isPresented: $showStorage) { DownloadStorageView() }
        .confirmationDialog("Fermare tutti i download in corso?", isPresented: $confirmCancel,
                            titleVisibility: .visible) {
            Button("Ferma i download", role: .destructive) { downloads.cancel() }
        }
        .task(id: downloads.revision) { totalSize = downloads.totalSize }
        .task { if LaunchScene.opensStorage { showStorage = true } }
    }

    /// "42 brani · 2 h 10 min · 1,4 GB", under a big download tile.
    private func summary(_ songs: [Track]) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(Color.blue.gradient, in: .rect(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 3) {
                Text(songs.count == 1 ? String(localized: "1 brano") : String(localized: "\(songs.count) brani"))
                    .font(.title3.bold())
                Text(details(songs))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    private func details(_ songs: [Track]) -> String {
        let seconds = songs.compactMap(\.duration).reduce(0, +)
        let minutes = Int(seconds / 60)
        let length = minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
        let size = ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
        return "\(length) · \(size)"
    }

    private var pendingHeader: some View {
        HStack(spacing: 10) {
            ProgressRing(value: downloads.batchFraction, size: 15, showsStop: false)
            let total = max(downloads.batchTotal, 1)
            Text("Download in corso: \(min(downloads.batchDone + 1, total)) di \(total)")
                .monospacedDigit()
            Spacer()
            Button("Ferma tutti") { confirmCancel = true }
                .font(.subheadline.weight(.semibold))
        }
    }
}

/// A song downloading or waiting its turn; the ring stops it.
private struct PendingDownloadRow: View {
    let track: Track
    @EnvironmentObject private var downloads: DownloadManager

    var body: some View {
        let state = downloads.state(of: track)
        HStack(spacing: 12) {
            ArtworkView(track: track, size: 44, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Group {
                    if case .downloading(let value) = state {
                        Text(verbatim: "\(track.artist) · \(value.formatted(.percent.precision(.fractionLength(0))))")
                    } else {
                        Text("In attesa")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button { downloads.cancel([track]) } label: {
                DownloadIndicator(state: state == .none ? .waiting : state, size: 26)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Annulla download")
        }
    }
}

// MARK: Storage

/// How much space the downloads take, by artist, like iPhone Settings → Music → Downloaded Music.
/// Swipe an artist or a song to remove it from the iPhone.
struct DownloadStorageView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var downloads: DownloadManager
    /// Bytes on disk by video ID (audio plus cover).
    @State private var sizes: [String: Int64] = [:]
    @State private var totalSize: Int64 = 0
    @State private var device: DeviceSpace?
    @State private var confirmDeleteAll = false

    fileprivate struct ArtistGroup: Identifiable {
        let name: String
        let tracks: [Track]
        let size: Int64
        var id: String { name }
    }

    private var groups: [ArtistGroup] {
        Dictionary(grouping: library.downloads, by: Self.artistName)
            .map { name, tracks in
                ArtistGroup(name: name, tracks: tracks,
                            size: tracks.reduce(0) { $0 + (sizes[$1.videoId ?? ""] ?? 0) })
            }
            .sorted { $0.size == $1.size ? $0.name < $1.name : $0.size > $1.size }
    }

    fileprivate static func artistName(_ track: Track) -> String {
        track.primaryArtist.isEmpty ? track.artist : track.primaryArtist
    }

    var body: some View {
        let groups = self.groups
        List {
            Section {
                StorageBar(downloads: totalSize, device: device)
                    .listRowBackground(Color.clear)
            }

            Section {
                LabeledContent("Tutti i brani", value: Self.bytes(totalSize))
                ForEach(groups) { group in
                    NavigationLink {
                        ArtistDownloadsView(name: group.name, sizes: sizes)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.name)
                                    .lineLimit(1)
                                Text(group.tracks.count == 1
                                     ? String(localized: "1 brano") : String(localized: "\(group.tracks.count) brani"))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(Self.bytes(group.size))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
                .onDelete { offsets in
                    for position in offsets { downloads.removeAll(groups[position].tracks) }
                }
            } header: {
                Text("Musica scaricata")
            } footer: {
                Text("Scorri a sinistra su un artista o su un brano per toglierlo dall'iPhone: resta nei preferiti e nelle playlist, e si può riscaricare.")
            }

            if totalSize > 0 {
                Section {
                    Button("Elimina tutti i download", role: .destructive) { confirmDeleteAll = true }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background { AmbientBackground() }
        .navigationTitle("Spazio occupato")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Eliminare tutti i brani scaricati?", isPresented: $confirmDeleteAll,
                            titleVisibility: .visible) {
            Button("Elimina", role: .destructive) { downloads.removeAll() }
        }
        .task(id: downloads.revision) {
            totalSize = downloads.totalSize
            sizes = await Self.measure(library.downloads.compactMap(\.videoId))
            device = DeviceSpace.current
        }
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// Reads the file sizes away from the main thread.
    nonisolated private static func measure(_ videoIds: [String]) async -> [String: Int64] {
        await Task.detached(priority: .utility) {
            var result: [String: Int64] = [:]
            for videoId in videoIds {
                result[videoId] = fileSize(Storage.audioFile(for: videoId)) + fileSize(Storage.artworkFile(for: videoId))
            }
            return result
        }.value
    }

    nonisolated private static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
}

/// The iPhone's storage, for the bar at the top of `DownloadStorageView`.
struct DeviceSpace {
    let total: Int64
    let available: Int64

    static var current: DeviceSpace? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL.documentsDirectory.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, total > 0,
              let available = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return DeviceSpace(total: Int64(total), available: available)
    }
}

/// Like the bar in Settings → General → iPhone Storage: Onda's downloads, everything else, free space.
private struct StorageBar: View {
    let downloads: Int64
    let device: DeviceSpace?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let device {
                let total = Double(max(device.total, 1))
                let ours = Double(downloads) / total
                let other = max(0, Double(device.total - device.available - downloads) / total)
                GeometryReader { geometry in
                    let width = geometry.size.width
                    HStack(spacing: 2) {
                        Rectangle().fill(.tint)
                            .frame(width: max(3, width * ours))
                        Rectangle().fill(Color.secondary.opacity(0.55))
                            .frame(width: width * other)
                        Rectangle().fill(Color.secondary.opacity(0.18))
                    }
                    .clipShape(.capsule)
                }
                .frame(height: 14)
                HStack(spacing: 14) {
                    legend("Download di Onda", value: downloads, style: AnyShapeStyle(.tint))
                    legend("Altro", value: max(0, device.total - device.available - downloads),
                           style: AnyShapeStyle(Color.secondary.opacity(0.55)))
                    legend("Disponibile", value: device.available,
                           style: AnyShapeStyle(Color.secondary.opacity(0.18)))
                }
                .font(.caption)
            } else {
                LabeledContent("Download di Onda", value: DownloadStorageView.bytes(downloads))
            }
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    private func legend(_ title: LocalizedStringKey, value: Int64, style: AnyShapeStyle) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Circle().fill(style).frame(width: 8, height: 8)
                Text(title).foregroundStyle(.secondary)
            }
            Text(DownloadStorageView.bytes(value))
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

/// One artist's downloaded songs, with their format and size.
private struct ArtistDownloadsView: View {
    let name: String
    let sizes: [String: Int64]
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var downloads: DownloadManager

    private var tracks: [Track] {
        library.downloads.filter { DownloadStorageView.artistName($0) == name }
    }

    var body: some View {
        let tracks = self.tracks
        List {
            ForEach(tracks) { track in
                HStack(spacing: 12) {
                    ArtworkView(track: track, size: 44, cornerRadius: 6)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .lineLimit(1)
                        Text(DownloadManager.formatLabel(for: track) ?? "AAC")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(DownloadStorageView.bytes(sizes[track.videoId ?? ""] ?? 0))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .onDelete { offsets in
                for track in offsets.map({ tracks[$0] }) { downloads.remove(track) }
            }
        }
        .scrollContentBackground(.hidden)
        .background { AmbientBackground() }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if tracks.isEmpty {
                ContentUnavailableView("Nessun download", systemImage: "arrow.down.circle")
            }
        }
    }
}
