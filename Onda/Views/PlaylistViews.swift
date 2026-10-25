import PhotosUI
import SwiftUI

struct PlaylistRow: View {
    let playlist: Playlist

    var body: some View {
        HStack(spacing: 14) {
            PlaylistArtwork(playlist: playlist, size: 56, cornerRadius: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(playlist.countLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct PlaylistDetailView: View {
    let playlistID: UUID

    @EnvironmentObject private var library: Library
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss
    @State private var showRename = false
    @State private var newName = ""
    @State private var confirmDelete = false
    @State private var confirmRemoveDownloads = false
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?

    var body: some View {
        Group {
            if let playlist = library.playlist(playlistID) {
                List {
                    header(playlist)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)

                    if playlist.tracks.isEmpty {
                        Text("La playlist è vuota. Aggiungi brani con il tasto ··· accanto a ogni canzone, oppure scorrendo un brano verso destra.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }

                    ForEach(Array(playlist.tracks.enumerated()), id: \.element.id) { position, track in
                        TrackRow(track: track) {
                            player.play(playlist.tracks, startAt: position, source: playlist.name)
                        }
                        .listRowBackground(Color.clear)
                    }
                    .onDelete { library.removeTracks(atOffsets: $0, from: playlistID) }
                    .onMove { library.moveTracks(fromOffsets: $0, toOffset: $1, in: playlistID) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .toolbar { toolbarMenu(playlist) }
            } else {
                ContentUnavailableView("Playlist eliminata", systemImage: "music.note.list")
            }
        }
        .background { AmbientBackground() }
        .navigationBarTitleDisplayMode(.inline)
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    library.setCover(data, for: playlistID)
                }
                photoItem = nil
            }
        }
        .alert("Rinomina playlist", isPresented: $showRename) {
            TextField("Nome", text: $newName)
            Button("Salva") { library.renamePlaylist(playlistID, to: newName) }
            Button("Annulla", role: .cancel) {}
        }
        .confirmationDialog("Eliminare questa playlist?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Elimina", role: .destructive) {
                library.deletePlaylist(playlistID)
                dismiss()
            }
        }
        .confirmationDialog("Rimuovere i brani scaricati di questa playlist?", isPresented: $confirmRemoveDownloads,
                            titleVisibility: .visible) {
            Button("Rimuovi download", role: .destructive) {
                if let playlist = library.playlist(playlistID) { downloads.removeAll(playlist.tracks) }
            }
        }
    }

    private func toolbarMenu(_ playlist: Playlist) -> some View {
        Menu {
            Button { showPhotoPicker = true } label: {
                Label("Cambia copertina", systemImage: "photo")
            }
            if playlist.coverFile != nil {
                Button { library.removeCover(for: playlistID) } label: {
                    Label("Usa le copertine dei brani", systemImage: "square.grid.2x2")
                }
            }
            Button {
                newName = playlist.name
                showRename = true
            } label: {
                Label("Rinomina", systemImage: "pencil")
            }
            if playlist.tracks.contains(where: { downloads.isDownloaded($0) }) {
                Button(role: .destructive) { confirmRemoveDownloads = true } label: {
                    Label("Rimuovi download", systemImage: "arrow.down.circle.dotted")
                }
            }
            Button(role: .destructive) { confirmDelete = true } label: {
                Label("Elimina playlist", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
        }
    }

    private func header(_ playlist: Playlist) -> some View {
        VStack(spacing: 14) {
            Button { showPhotoPicker = true } label: {
                PlaylistArtwork(playlist: playlist, size: 220, cornerRadius: 22)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "camera.fill")
                            .font(.footnote.weight(.semibold))
                            .padding(9)
                            .glassEffect(.regular, in: .circle)
                            .padding(10)
                    }
                    .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
            }
            .buttonStyle(.plain)

            VStack(spacing: 4) {
                Text(playlist.name)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(summary(playlist))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !playlist.tracks.isEmpty {
                PlayShuffleButtons(tracks: playlist.tracks, source: playlist.name)
                downloadButton(playlist)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    /// One tap saves the whole playlist; shows progress while it runs.
    @ViewBuilder private func downloadButton(_ playlist: Playlist) -> some View {
        let downloadable = playlist.tracks.filter { $0.videoId != nil }
        let saved = downloadable.filter { downloads.isDownloaded($0) }.count
        let inProgress = downloadable.filter { downloads.isQueued($0) }.count
        Button {
            if inProgress > 0 {
                downloads.cancelWaiting(in: downloadable)
            } else {
                downloads.downloadAll(downloadable)
            }
        } label: {
            HStack(spacing: 8) {
                if inProgress > 0 {
                    ProgressView().controlSize(.small)
                    Text("Download \(saved)/\(downloadable.count) · tocca per fermare")
                } else if saved == downloadable.count {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Playlist scaricata")
                } else {
                    Image(systemName: "arrow.down.circle.fill")
                    Text(saved > 0 ? "Scarica i restanti \(downloadable.count - saved)" : "Scarica tutta la playlist")
                }
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .disabled(downloadable.isEmpty || (saved == downloadable.count && inProgress == 0))
    }

    private func summary(_ playlist: Playlist) -> String {
        let total = playlist.tracks.compactMap(\.duration).reduce(0, +)
        guard total > 0 else { return playlist.countLabel }
        let minutes = Int(total / 60)
        let length = minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
        return "\(playlist.countLabel) · \(length)"
    }
}

/// Sheet opened by "Aggiungi a playlist…": tick the playlists the song belongs to, or create a new one.
struct AddToPlaylistSheet: View {
    let track: Track

    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var showNew = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        ArtworkView(track: track, size: 48, cornerRadius: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title).font(.headline).lineLimit(1)
                            Text(track.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }

                Section {
                    Button { library.toggleLike(track) } label: {
                        HStack {
                            Label("Preferiti", systemImage: "heart.fill")
                                .foregroundStyle(.pink)
                            Spacer()
                            if library.isLiked(track) { checkmark }
                        }
                    }
                    Button {
                        newName = ""
                        showNew = true
                    } label: {
                        Label("Nuova playlist", systemImage: "plus")
                    }
                }

                if !library.playlists.isEmpty {
                    Section("Le tue playlist") {
                        ForEach(library.playlists) { playlist in
                            Button { library.toggle(track, in: playlist.id) } label: {
                                HStack {
                                    PlaylistRow(playlist: playlist)
                                    Spacer()
                                    if library.contains(track, in: playlist.id) { checkmark }
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }
            }
            .navigationTitle("Aggiungi a playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }
                }
            }
            .alert("Nuova playlist", isPresented: $showNew) {
                TextField("Nome", text: $newName)
                Button("Crea") { library.createPlaylist(named: newName, tracks: [track]) }
                Button("Annulla", role: .cancel) {}
            } message: {
                Text("\"\(track.title)\" verrà aggiunto alla nuova playlist.")
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var checkmark: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.title3)
            .foregroundStyle(.tint)
    }
}
