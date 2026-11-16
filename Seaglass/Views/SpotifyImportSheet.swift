import SwiftUI
import WebKit

/// "Importa dal tuo account Spotify": sign in on Spotify's own page (the first time), tick the
/// playlists, and each one becomes a Seaglass playlist of the songs found on YouTube Music.
struct SpotifyImportSheet: View {
    /// The playlists made, and why the import stopped early, if it did.
    let onFinished: (SpotifyAccountImport.Result) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var session = SpotifySession.shared
    @ObservedObject private var spotify = SpotifyAccountImport.shared
    @ObservedObject private var matcher = PlaylistImporter.shared
    @State private var playlists: [SpotifyPlaylist]?
    @State private var selected = Set<String>()
    @State private var importing = false
    @State private var error: String?
    @State private var work: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ZStack {
                // The web page stays under the sheet's content the whole time: Spotify's own
                // sign-in at first, and the player that answers the queries afterwards.
                SpotifyWebHost()
                if !session.showsLogin || error != nil {
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(.systemBackground))
                } else {
                    VStack {
                        Spacer()
                        Text("Seaglass non vede la tua password: l'accesso avviene nella pagina di Spotify. L'accesso con Google potrebbe non funzionare qui: usa email e password.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(10)
                            .frame(maxWidth: .infinity)
                            .background(.regularMaterial)
                    }
                }
            }
            .navigationTitle("Account Spotify")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { work?.cancel(); dismiss() }
                }
                if playlists != nil, !importing {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("Esci da Spotify", role: .destructive) { signOut() }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
            }
        }
        .task { if playlists == nil && error == nil { load() } }
        .onDisappear {
            work?.cancel()
            spotify.end()
        }
        #if targetEnvironment(macCatalyst)
        .frame(minWidth: 480, minHeight: 620)
        #endif
    }

    @ViewBuilder private var content: some View {
        if let error {
            VStack(spacing: 16) {
                Text(error).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("Riprova") { load() }.buttonStyle(.borderedProminent)
            }
            .padding(24)
        } else if let playlists, !importing {
            List {
                Section {
                    ForEach(playlists) { playlist in
                        Button {
                            if selected.contains(playlist.id) { selected.remove(playlist.id) } else { selected.insert(playlist.id) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selected.contains(playlist.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(playlist.id) ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(playlist.name).foregroundStyle(.primary).lineLimit(1)
                                    if let owner = playlist.owner {
                                        Text(owner).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                } footer: {
                    Text("Scegli le playlist da copiare in Seaglass. Ogni brano viene cercato su YouTube Music.")
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button { startImport(playlists.filter { selected.contains($0.id) }) } label: {
                    Text("Importa \(selected.count) playlist").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(selected.isEmpty)
                .padding()
                .background(.bar)
            }
        } else {
            VStack(spacing: 14) {
                ProgressView()
                Text(progressText).multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
            .padding(24)
        }
    }

    private var progressText: String {
        [spotify.status, importing ? matcher.status : nil].compactMap { $0 }.joined(separator: "\n")
    }

    private func load() {
        error = nil
        work?.cancel()
        work = Task {
            do {
                playlists = try await spotify.playlists()
            } catch is CancellationError {
                return
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func startImport(_ chosen: [SpotifyPlaylist]) {
        importing = true
        work?.cancel()
        work = Task {
            do {
                let result = try await spotify.importPlaylists(chosen)
                onFinished(result)
                dismiss()
            } catch is CancellationError {
                importing = false
            } catch {
                importing = false
                self.error = error.localizedDescription
            }
        }
    }

    private func signOut() {
        work?.cancel()
        work = Task {
            await spotify.signOut()
            playlists = nil
            selected = []
            load()
        }
    }
}

/// Hosts the session's web view (one for the whole app: it holds the Spotify sign-in).
private struct SpotifyWebHost: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { SpotifySession.shared.webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
