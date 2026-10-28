import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var downloads: DownloadManager
    @ObservedObject private var importer = PlaylistImporter.shared
    @State private var showDownloads = false
    @State private var showNewPlaylist = false
    @State private var showImport = false
    @State private var newName = ""
    @State private var importLink = ""
    @State private var errorText: String?
    @State private var importResult: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { TrackCollectionView(collection: .liked) } label: {
                        shortcut("Preferiti", symbol: "heart.fill", tint: .pink, count: library.liked.count)
                    }
                    NavigationLink { DownloadsView() } label: {
                        if downloads.batchTotal > 0 {
                            // Like the Music app's "Downloading" row: overall ring and songs left.
                            shortcut("Download", symbol: "arrow.down.circle.fill", tint: .blue) {
                                HStack(spacing: 8) {
                                    Text("\(downloads.batchTotal - downloads.batchDone) in corso")
                                        .monospacedDigit()
                                    ProgressRing(value: downloads.batchFraction, size: 18, showsStop: false)
                                }
                            }
                        } else {
                            shortcut("Download", symbol: "arrow.down.circle.fill", tint: .blue,
                                     count: library.downloads.count)
                        }
                    }
                    NavigationLink { TrackCollectionView(collection: .history) } label: {
                        shortcut("Cronologia", symbol: "clock.fill", tint: .orange, count: library.history.count)
                    }
                }

                Section {
                    Button {
                        newName = ""
                        showNewPlaylist = true
                    } label: {
                        Label("Nuova playlist", systemImage: "plus.circle.fill")
                    }
                    Button {
                        importLink = ""
                        showImport = true
                    } label: {
                        if let status = importer.status {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text(status).foregroundStyle(.secondary)
                            }
                        } else {
                            Label("Importa da Spotify, Apple Music o YouTube", systemImage: "square.and.arrow.down.fill")
                        }
                    }
                    .disabled(importer.status != nil)

                    ForEach(library.playlists) { playlist in
                        NavigationLink { PlaylistDetailView(playlistID: playlist.id) } label: {
                            PlaylistRow(playlist: playlist)
                        }
                    }
                    .onDelete { library.deletePlaylists(atOffsets: $0) }
                } header: {
                    Text("Playlist")
                } footer: {
                    if library.playlists.isEmpty {
                        Text("Crea una playlist qui, oppure dal tasto ··· accanto a qualsiasi brano.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background { AmbientBackground() }
            .navigationTitle("Libreria")
            // Opened directly only by the CI screenshots (see `LaunchScene`).
            .navigationDestination(isPresented: $showDownloads) { DownloadsView() }
            .task { if LaunchScene.opensDownloads { showDownloads = true } }
            .alert("Nuova playlist", isPresented: $showNewPlaylist) {
                TextField("Nome", text: $newName)
                Button("Crea") { library.createPlaylist(named: newName) }
                Button("Annulla", role: .cancel) {}
            }
            .alert("Importa playlist", isPresented: $showImport) {
                TextField("Link della playlist", text: $importLink)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Importa") { importPlaylist() }
                Button("Annulla", role: .cancel) {}
            } message: {
                Text("Incolla il link di una playlist o di un album pubblico di Spotify, Apple Music, YouTube o YouTube Music. Da Spotify arrivano al massimo 100 brani.")
            }
            .alert("Ops", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorText ?? "")
            }
            .alert("Playlist importata", isPresented: Binding(get: { importResult != nil },
                                                              set: { if !$0 { importResult = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importResult ?? "")
            }
        }
    }

    private func shortcut(_ title: LocalizedStringKey, symbol: String, tint: Color, count: Int) -> some View {
        shortcut(title, symbol: symbol, tint: tint) {
            Text("\(count)")
        }
    }

    private func shortcut<Detail: View>(_ title: LocalizedStringKey, symbol: String, tint: Color,
                                        @ViewBuilder detail: () -> Detail) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(tint.gradient, in: .rect(cornerRadius: 10))
            Text(title).font(.body.weight(.medium))
            Spacer()
            detail().foregroundStyle(.secondary)
        }
    }

    private func importPlaylist() {
        let link = importLink
        Task {
            do {
                let outcome = try await importer.importPlaylist(from: link)
                var message = "\"\(outcome.playlist.name)\": \(outcome.playlist.countLabel)."
                if outcome.unmatched > 0 {
                    message += " " + String(localized: "\(outcome.unmatched) non trovati su YouTube Music.")
                }
                importResult = message
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}

enum TrackCollection {
    case liked, downloads, history

    var title: String {
        switch self {
        case .liked: return String(localized: "Preferiti")
        case .downloads: return String(localized: "Download")
        case .history: return String(localized: "Cronologia")
        }
    }
}

/// Preferiti, Download and Cronologia.
struct TrackCollectionView: View {
    let collection: TrackCollection

    @EnvironmentObject private var library: Library
    private var player: PlayerController { .shared }
    @EnvironmentObject private var downloads: DownloadManager

    private var tracks: [Track] {
        switch collection {
        case .liked: return library.liked
        case .downloads: return library.downloads
        case .history: return library.history
        }
    }

    var body: some View {
        List {
            if !tracks.isEmpty {
                PlayShuffleButtons(tracks: tracks, source: collection.title)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(Array(tracks.enumerated()), id: \.element.id) { position, track in
                TrackRow(track: track, remove: { delete(IndexSet(integer: position)) }) {
                    player.play(tracks, startAt: position, source: collection.title)
                }
                .listRowBackground(Color.clear)
            }
            .onDelete(perform: delete)
            .onMove(perform: moveAction)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background { AmbientBackground() }
        .overlay {
            if tracks.isEmpty { emptyState }
        }
        .navigationTitle(collection.title)
        .toolbar {
            if collection == .history && !tracks.isEmpty {
                Button("Svuota") { library.clearHistory() }
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        switch collection {
        case .liked:
            ContentUnavailableView("Nessun preferito", systemImage: "heart",
                                   description: Text("Tocca il cuore nel player, o scorri un brano verso destra."))
        case .downloads:
            ContentUnavailableView("Nessun download", systemImage: "arrow.down.circle",
                                   description: Text("Tocca ··· accanto a un brano e scegli Scarica."))
        case .history:
            ContentUnavailableView("Cronologia vuota", systemImage: "clock",
                                   description: Text("I brani che ascolti appariranno qui."))
        }
    }

    /// Only favourites keep a custom order; downloads and history are sorted by date.
    private var moveAction: ((IndexSet, Int) -> Void)? {
        guard collection == .liked else { return nil }
        return { source, destination in library.moveLiked(fromOffsets: source, toOffset: destination) }
    }

    private func delete(_ offsets: IndexSet) {
        let selected = offsets.map { tracks[$0] }
        switch collection {
        case .liked:
            for track in selected { library.toggleLike(track) }
        case .downloads:
            for track in selected { downloads.remove(track) }
        case .history:
            library.removeFromHistory(selected)
        }
    }
}
