import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var lastfm: LastFM
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var downloads: DownloadManager

    @State private var keyDraft = ""
    @State private var secretDraft = ""
    @State private var editingKeys = false
    @State private var authURL: IdentifiedURL?
    @State private var working = false
    @State private var alertText: String?
    @State private var confirmDeleteDownloads = false

    var body: some View {
        NavigationStack {
            Form {
                lastfmSection

                Section {
                    Toggle("Radio automatica", isOn: $player.autoRadio)
                } header: {
                    Text("Riproduzione")
                } footer: {
                    Text("Quando la coda finisce, continua con brani simili a quello che stavi ascoltando.")
                }

                Section {
                    LabeledContent("Spazio usato",
                                   value: ByteCountFormatter.string(fromByteCount: downloads.totalSize, countStyle: .file))
                    Button("Elimina tutti i download", role: .destructive) { confirmDeleteDownloads = true }
                        .disabled(downloads.totalSize == 0)
                } header: {
                    Text("Download")
                }

                Section {
                    LabeledContent("Versione", value: Bundle.main.appVersion)
                    Text("Catalogo: YouTube Music · Testi: LRCLIB · Scrobbling: Last.fm")
                    Text("Progetto personale, non affiliato a Google, YouTube o Last.fm.")
                } header: {
                    Text("Informazioni")
                }
                .font(.footnote)
            }
            .navigationTitle("Impostazioni")
            .sheet(item: $authURL, onDismiss: finishAuth) { item in
                SafariView(url: item.url).ignoresSafeArea()
            }
            .alert("Last.fm", isPresented: Binding(get: { alertText != nil }, set: { if !$0 { alertText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(alertText ?? "")
            }
            .confirmationDialog("Eliminare tutti i brani scaricati?", isPresented: $confirmDeleteDownloads,
                                titleVisibility: .visible) {
                Button("Elimina", role: .destructive) { downloads.removeAll() }
            }
        }
    }

    @ViewBuilder private var lastfmSection: some View {
        Section {
            if !lastfm.hasCredentials || editingKeys {
                TextField("API key", text: $keyDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                SecureField("Shared secret", text: $secretDraft)
                    .font(.body.monospaced())
                Button("Salva chiavi") {
                    lastfm.saveCredentials(key: keyDraft, secret: secretDraft)
                    secretDraft = ""
                    editingKeys = false
                }
                .disabled(keyDraft.trimmed.isEmpty || secretDraft.trimmed.isEmpty)
                Link("Crea una API key su last.fm",
                     destination: URL(string: "https://www.last.fm/api/account/create")!)
            } else if let username = lastfm.username, lastfm.isConnected {
                LabeledContent("Account", value: username)
                Toggle("Scrobbling", isOn: $lastfm.scrobblingEnabled)
                if lastfm.pendingCount > 0 {
                    LabeledContent("Scrobble in attesa", value: "\(lastfm.pendingCount)")
                }
                Button("Disconnetti", role: .destructive) { lastfm.signOut() }
            } else {
                Button(action: connect) {
                    HStack {
                        Text("Connetti account Last.fm")
                        if working {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(working)
                Button("Modifica chiavi API") {
                    keyDraft = lastfm.apiKey
                    editingKeys = true
                }
            }
        } header: {
            Text("Last.fm")
        } footer: {
            Text("Crea gratis un'applicazione API su last.fm (nome e descrizione a piacere), incolla API key e shared secret, poi connetti l'account. Un brano viene registrato dopo metà ascolto o 4 minuti.")
        }
    }

    private func connect() {
        working = true
        Task {
            do {
                let url = try await lastfm.beginAuth()
                authURL = IdentifiedURL(url: url)
            } catch {
                alertText = error.localizedDescription
            }
            working = false
        }
    }

    /// Called when the Last.fm page is closed: the user has (hopefully) allowed access.
    private func finishAuth() {
        Task {
            do {
                try await lastfm.completeAuth()
            } catch {
                alertText = error.localizedDescription
            }
        }
    }
}
