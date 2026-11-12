import SwiftUI

/// The user's own songs (see `LocalMusic`): the folders they chose, and the songs in them, which play,
/// queue and mix like any other.
struct LocalMusicView: View {
    @ObservedObject private var local = LocalMusic.shared
    /// The folder just chosen couldn't be opened.
    @State private var failed = false
    private var player: PlayerController { .shared }

    var body: some View {
        List {
            if !local.tracks.isEmpty {
                PlayShuffleButtons(tracks: local.tracks, source: String(localized: "File locali"))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            foldersSection
            if local.tracks.isEmpty && !local.scanning {
                emptyState
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(Array(local.tracks.enumerated()), id: \.element.id) { position, track in
                TrackRow(track: track) {
                    player.play(local.tracks, startAt: position, source: String(localized: "File locali"))
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background { AmbientBackground() }
        .navigationTitle("File locali")
        .task { local.refreshOnce() }
        .alert("Cartella non raggiungibile", isPresented: $failed) {
            Button("OK", role: .cancel) {}
        }
    }

    /// Files' own picker (see `FolderPicker`: SwiftUI's stops answering beside the Library's).
    private func chooseFolder() {
        FolderPicker.shared.present { url in
            if !local.add(folder: url) { failed = true }
        }
    }

    /// Songs picked one by one: the system copies them into the app's own folder.
    private func chooseFiles() {
        FolderPicker.shared.presentFiles { urls in
            _ = local.importCopies(urls)
        }
    }

    private var foldersSection: some View {
        Section {
            ForEach(local.folders) { folder in
                if folder.id == LocalMusic.appFolderID {
                    folderRow(folder)
                        .listRowBackground(Color.clear)
                } else {
                    folderRow(folder)
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) { local.remove(folder) } label: {
                                Label("Rimuovi cartella", systemImage: "trash")
                            }
                        }
                }
            }
            Button { chooseFolder() } label: {
                Label("Aggiungi cartella…", systemImage: "folder.badge.plus")
            }
            .listRowBackground(Color.clear)
            Button { chooseFiles() } label: {
                Label("Aggiungi file…", systemImage: "music.note.list")
            }
            .listRowBackground(Color.clear)
            Button { local.rescan() } label: {
                if local.scanning {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Lettura dei file: \(local.scanned)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                } else {
                    Label("Aggiorna", systemImage: "arrow.clockwise")
                }
            }
            .disabled(local.scanning)
            .listRowBackground(Color.clear)
        } header: {
            Text("Cartelle")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Rimuovere una cartella non elimina i file: Seaglass non li copia né li modifica.")
                Text("Puoi anche mettere la musica in File › Sul mio iPhone › Seaglass › Musica: Seaglass la legge da lì, senza permessi.")
            }
        }
    }

    private func folderRow(_ folder: LocalFolder) -> some View {
        let closed = local.unreachable.contains(folder.id)
        let own = folder.id == LocalMusic.appFolderID
        let empty = !closed && !local.scanning && local.songCount(in: folder) == 0
        return HStack(spacing: 12) {
            Image(systemName: closed ? "exclamationmark.triangle.fill" : (own ? "iphone" : "folder.fill"))
                .foregroundStyle(closed ? Color.orange : Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                if own {
                    Text("Musica di Seaglass")
                        .lineLimit(1)
                } else {
                    Text(folder.name)
                        .lineLimit(1)
                }
                if closed {
                    Text("Cartella non raggiungibile")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if empty {
                    Text("Nessun brano trovato")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nessun file locale", systemImage: "folder")
        } description: {
            Text("Scegli una cartella con la tua musica sul dispositivo: i brani restano dove sono e Seaglass li riproduce da lì, senza copiarli.")
        }
    }
}
