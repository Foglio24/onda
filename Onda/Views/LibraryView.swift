import SwiftUI

struct LibraryView: View {
    private enum Shelf: String, CaseIterable, Identifiable {
        case liked = "Preferiti"
        case downloads = "Download"
        case history = "Cronologia"

        var id: Self { self }
    }

    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var downloads: DownloadManager
    @State private var shelf: Shelf = .liked

    private var tracks: [Track] {
        switch shelf {
        case .liked: return library.liked
        case .downloads: return library.downloads
        case .history: return library.history
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Picker("Sezione", selection: $shelf) {
                    ForEach(Shelf.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)

                if !tracks.isEmpty {
                    HStack(spacing: 12) {
                        Button { player.play(tracks, source: shelf.rawValue) } label: {
                            Label("Riproduci", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        Button { player.play(tracks.shuffled(), source: shelf.rawValue) } label: {
                            Label("Casuale", systemImage: "shuffle").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .controlSize(.large)
                    .listRowSeparator(.hidden)
                }

                ForEach(Array(tracks.enumerated()), id: \.element.id) { position, track in
                    Button { player.play(tracks, startAt: position, source: shelf.rawValue) } label: {
                        TrackRow(track: track)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete(perform: delete)
            }
            .listStyle(.plain)
            .overlay {
                if tracks.isEmpty { emptyState }
            }
            .navigationTitle("Libreria")
            .toolbar {
                if shelf == .history && !library.history.isEmpty {
                    Button("Svuota") { library.clearHistory() }
                }
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        switch shelf {
        case .liked:
            ContentUnavailableView("Nessun preferito", systemImage: "heart",
                                   description: Text("Tocca il cuore mentre ascolti per salvare un brano."))
        case .downloads:
            ContentUnavailableView("Nessun download", systemImage: "arrow.down.circle",
                                   description: Text("Tieni premuto un brano e scegli Scarica per ascoltarlo offline."))
        case .history:
            ContentUnavailableView("Cronologia vuota", systemImage: "clock",
                                   description: Text("I brani che ascolti appariranno qui."))
        }
    }

    private func delete(_ offsets: IndexSet) {
        let selected = offsets.map { tracks[$0] }
        switch shelf {
        case .liked:
            for track in selected { library.toggleLike(track) }
        case .downloads:
            for track in selected { downloads.remove(track) }
        case .history:
            library.removeFromHistory(selected)
        }
    }
}
