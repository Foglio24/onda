import SwiftUI

/// The report is stored with the playlist, so closing the sheet never loses the missing songs.
struct PlaylistImportReviewView: View {
    let playlistID: UUID
    @EnvironmentObject private var library: Library

    var body: some View {
        Group {
            if let playlist = library.playlist(playlistID), let report = playlist.importReport {
                List {
                    Section {
                        LabeledContent { Text(verbatim: String(playlist.tracks.count)) } label: { Text("Brani nella playlist") }
                        LabeledContent { Text(verbatim: String(report.entries.count)) } label: { Text("Elementi letti") }
                        LabeledContent { Text(verbatim: String(report.pending.count)) } label: { Text("Da controllare") }
                        if report.mayBeTruncated {
                            Label("Spotify potrebbe aver mostrato solo i primi 100 brani. Controlla la playlist originale; per importare una lista più lunga usa un file Spotify JSON o CSV.", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                    if report.pending.isEmpty {
                        Section { Label("Nessun brano da controllare", systemImage: "checkmark.circle") }
                    } else {
                        Section("Da controllare") {
                            ForEach(report.pending) { entry in
                                if entry.issue == .unavailable || entry.issue == .unsupported {
                                    entryLabel(entry)
                                } else {
                                    NavigationLink { PlaylistImportAlternativesView(playlistID: playlistID, entry: entry) } label: {
                                        entryLabel(entry)
                                    }
                                }
                            }
                            .onDelete { offsets in
                                for index in offsets { library.ignoreImportedTrack(report.pending[index].id, in: playlistID) }
                            }
                        }
                    }
                    if !report.ignored.isEmpty {
                        Section("Ignorati") {
                            ForEach(report.ignored) { entry in
                                HStack {
                                    entryLabel(entry)
                                    Spacer()
                                    Button("Recupera") { library.restoreImportedTrack(entry.id, in: playlistID) }
                                        .buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                }
                .navigationTitle("Importazione")
                .navigationBarTitleDisplayMode(.inline)
            } else {
                ContentUnavailableView("Riepilogo non disponibile", systemImage: "music.note.list")
            }
        }
    }

    private func entryLabel(_ entry: PlaylistImportEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.original.title).font(.body.weight(.medium))
            Text(entry.original.artist).font(.subheadline).foregroundStyle(.secondary)
            Text(issueText(entry.issue)).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    private func issueText(_ issue: PlaylistImportEntry.Issue?) -> String {
        switch issue {
        case .some(.notFound): return String(localized: "Non trovato: scegli un'alternativa")
        case .some(.searchFailed): return String(localized: "Ricerca non riuscita: riprova")
        case .some(.duplicate): return String(localized: "Già presente nella playlist")
        case .some(.unavailable): return String(localized: "Dati del brano non disponibili")
        case .some(.unsupported): return String(localized: "Elemento non musicale non importato")
        case nil: return ""
        }
    }
}

private struct PlaylistImportAlternativesView: View {
    let playlistID: UUID
    let entry: PlaylistImportEntry
    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [Track] = []
    @State private var searching = false
    @State private var searched = false
    @State private var error: String?
    @State private var duplicate = false

    var body: some View {
        List {
            Section("Brano originale") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.original.title).font(.headline)
                    Text(entry.original.artist).foregroundStyle(.secondary)
                }
            }
            Section {
                HStack {
                    TextField("Titolo e artista", text: $query)
                        .submitLabel(.search)
                        .onSubmit { Task { await search() } }
                    Button("Cerca") { Task { await search() } }.disabled(searching)
                }
            } footer: {
                Text("Scegli il brano che corrisponde, oppure modifica la ricerca.")
            }
            Section("Risultati su YouTube Music") {
                if searching {
                    ProgressView()
                } else if let error {
                    Text(error).foregroundStyle(.secondary)
                    Button("Riprova") { Task { await search() } }
                } else if searched && results.isEmpty {
                    Text("Nessun risultato. Prova a modificare la ricerca.").foregroundStyle(.secondary)
                } else {
                    ForEach(results) { track in
                        Button {
                            switch library.resolveImportedTrack(entry.id, in: playlistID, with: track) {
                            case .added: dismiss()
                            case .alreadyPresent: duplicate = true
                            case .missing: dismiss()
                            }
                        } label: {
                            HStack(spacing: 12) {
                                ArtworkView(track: track, size: 48)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(track.title).font(.body.weight(.medium)).lineLimit(2)
                                    Text(track.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer()
                                if let duration = track.duration, duration.isFinite, duration > 0 {
                                    Text(verbatim: String(format: "%d:%02d", Int(duration) / 60, Int(duration) % 60))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Scegli un'alternativa")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            query = "\(entry.original.primaryArtist) \(entry.original.title)".trimmingCharacters(in: .whitespaces)
            await search()
        }
        .alert("Brano già presente", isPresented: $duplicate) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Questo brano è già nella playlist. Puoi scegliere un'altra versione oppure ignorare la voce nel riepilogo.")
        }
    }

    @MainActor
    private func search() async {
        guard !searching else { return }
        searching = true
        defer { searching = false; searched = true }
        error = nil
        do { results = try await InnerTube.shared.importSuggestions(for: entry.original, query: query) }
        catch { results = []; self.error = error.localizedDescription }
    }
}
