import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: Library
    @State private var showNewPlaylist = false
    @State private var showImport = false
    @State private var newName = ""
    @State private var importLink = ""
    @State private var importing = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { TrackCollectionView(collection: .liked) } label: {
                        shortcut("Preferiti", symbol: "heart.fill", tint: .pink, count: library.liked.count)
                    }
                    NavigationLink { TrackCollectionView(collection: .downloads) } label: {
                        shortcut("Download", symbol: "arrow.down.circle.fill", tint: .blue,
                                 count: library.downloads.count)
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
                        HStack {
                            Label("Importa da YouTube Music", systemImage: "square.and.arrow.down.fill")
                            if importing {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(importing)

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
                Text("Incolla il link di una playlist pubblica di YouTube o YouTube Music.")
            }
            .alert("Ops", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorText ?? "")
            }
        }
    }

    private func shortcut(_ title: String, symbol: String, tint: Color, count: Int) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(tint.gradient, in: .rect(cornerRadius: 10))
            Text(title).font(.body.weight(.medium))
            Spacer()
            Text("\(count)").foregroundStyle(.secondary)
        }
    }

    private func importPlaylist() {
        guard let id = InnerTube.playlistID(from: importLink) else {
            errorText = "Il link non sembra quello di una playlist: deve contenere \"list=\"."
            return
        }
        importing = true
        Task {
            do {
                let result = try await InnerTube.shared.playlist(id: id)
                library.createPlaylist(named: result.title ?? "Playlist importata", tracks: result.tracks)
            } catch {
                errorText = "Importazione non riuscita. La playlist deve essere pubblica. (\(error.localizedDescription))"
            }
            importing = false
        }
    }
}

enum TrackCollection {
    case liked, downloads, history

    var title: String {
        switch self {
        case .liked: return "Preferiti"
        case .downloads: return "Download"
        case .history: return "Cronologia"
        }
    }
}

/// Preferiti, Download and Cronologia.
struct TrackCollectionView: View {
    let collection: TrackCollection

    @EnvironmentObject private var library: Library
    @EnvironmentObject private var player: PlayerController
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
                TrackRow(track: track) {
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
