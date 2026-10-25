import SwiftUI

struct PlaylistRow: View {
    let playlist: Playlist

    var body: some View {
        HStack(spacing: 14) {
            PlaylistArtwork(tracks: playlist.tracks, size: 56, cornerRadius: 10)
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
    @Environment(\.dismiss) private var dismiss
    @State private var showRename = false
    @State private var newName = ""
    @State private var confirmDelete = false

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
                .toolbar {
                    Menu {
                        Button {
                            newName = playlist.name
                            showRename = true
                        } label: {
                            Label("Rinomina", systemImage: "pencil")
                        }
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Label("Elimina playlist", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            } else {
                ContentUnavailableView("Playlist eliminata", systemImage: "music.note.list")
            }
        }
        .background { AmbientBackground() }
        .navigationBarTitleDisplayMode(.inline)
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
    }

    private func header(_ playlist: Playlist) -> some View {
        VStack(spacing: 14) {
            PlaylistArtwork(tracks: playlist.tracks, size: 220, cornerRadius: 22)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
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
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
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
            .foregroundStyle(Color.accentColor)
    }
}
