import SwiftUI
import UniformTypeIdentifiers

/// The user's own songs (see `LocalMusic`): the folders they chose, and the songs in them, which play,
/// queue and mix like any other.
struct LocalMusicView: View {
    @ObservedObject private var local = LocalMusic.shared
    @State private var choosing = false
    private var player: PlayerController { .shared }

    var body: some View {
        List {
            if !local.tracks.isEmpty {
                PlayShuffleButtons(tracks: local.tracks, source: String(localized: "File locali"))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            if !local.folders.isEmpty {
                foldersSection
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
        .overlay {
            if local.folders.isEmpty { emptyState }
        }
        .navigationTitle("File locali")
        .task { local.refreshOnce() }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                local.add(folder: url)
            }
        }
    }

    private var foldersSection: some View {
        Section {
            ForEach(local.folders) { folder in
                folderRow(folder)
                    .listRowBackground(Color.clear)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) { local.remove(folder) } label: {
                            Label("Rimuovi cartella", systemImage: "trash")
                        }
                    }
            }
            Button { choosing = true } label: {
                Label("Aggiungi cartella…", systemImage: "folder.badge.plus")
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
            Text("Rimuovere una cartella non elimina i file: Seaglass non li copia né li modifica.")
        }
    }

    private func folderRow(_ folder: LocalFolder) -> some View {
        let closed = local.unreachable.contains(folder.id)
        return HStack(spacing: 12) {
            Image(systemName: closed ? "exclamationmark.triangle.fill" : "folder.fill")
                .foregroundStyle(closed ? Color.orange : Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                    .lineLimit(1)
                if closed {
                    Text("Cartella non raggiungibile")
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
        } actions: {
            Button("Aggiungi cartella…") { choosing = true }
                .buttonStyle(.borderedProminent)
        }
    }
}
