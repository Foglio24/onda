import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var lastfm: LastFM
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var library: Library

    @AppStorage(Preferences.wifiQuality) private var wifiQuality: AudioQuality = .high
    @AppStorage(Preferences.cellularQuality) private var cellularQuality: AudioQuality = .high
    @AppStorage(Preferences.downloadQuality) private var downloadQuality: AudioQuality = .high
    @AppStorage(Preferences.spatialAudio) private var spatialAudio = true
    @AppStorage(Preferences.skipLongMixes) private var skipLongMixes = true
    @AppStorage(Preferences.dynamicColors) private var dynamicColors = true
    @AppStorage(Preferences.lyricsStyle) private var lyricsStyle: LyricsStyle = .focus
    @AppStorage(Preferences.lyricsSize) private var lyricsSize: LyricsSize = .medium
    @AppStorage(Preferences.recentSearches) private var recentSearches = ""

    @State private var keyDraft = ""
    @State private var secretDraft = ""
    @State private var editingKeys = false
    @State private var authURL: IdentifiedURL?
    @State private var working = false
    @State private var alertText: String?
    @State private var confirmDeleteDownloads = false
    @State private var cacheCleared = false

    var body: some View {
        NavigationStack {
            Form {
                audioSection
                playbackSection
                lyricsSection
                appearanceSection
                lastfmSection
                storageSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background { AmbientBackground() }
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
            .onChange(of: spatialAudio) { _, _ in player.applySpatialAudioPreference() }
            .onChange(of: dynamicColors) { _, _ in player.applyThemePreference() }
        }
    }

    // MARK: Sections

    private var audioSection: some View {
        Section {
            Picker(selection: $wifiQuality) {
                ForEach(AudioQuality.allCases) { Text($0.title).tag($0) }
            } label: {
                Label("Streaming su Wi-Fi", systemImage: "wifi")
            }
            Picker(selection: $cellularQuality) {
                ForEach(AudioQuality.allCases) { Text($0.title).tag($0) }
            } label: {
                Label("Streaming su rete cellulare", systemImage: "antenna.radiowaves.left.and.right")
            }
            Picker(selection: $downloadQuality) {
                ForEach(AudioQuality.allCases) { Text($0.title).tag($0) }
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            LabeledContent {
                Text("AAC (m4a)")
            } label: {
                Label("Codec", systemImage: "waveform")
            }
            Toggle(isOn: $spatialAudio) {
                Label("Audio spaziale", systemImage: "headphones")
            }
        } header: {
            Text("Audio")
        } footer: {
            Text("YouTube offre l'audio in AAC e in Opus, ma il lettore di iOS non decodifica Opus: Onda usa AAC. L'Audio spaziale è il sistema con cui l'iPhone riproduce il Dolby Atmos e funziona con AirPods e cuffie Beats compatibili; YouTube non distribuisce brani in Dolby Atmos, quindi l'iPhone spazializza l'audio stereo. La nuova qualità vale dal brano successivo.")
        }
    }

    private var playbackSection: some View {
        Section {
            Toggle(isOn: $player.autoRadio) {
                Label("Radio automatica", systemImage: "infinity")
            }
            Toggle(isOn: $skipLongMixes) {
                Label("Salta le compilation lunghe", systemImage: "forward.end")
            }
        } header: {
            Text("Riproduzione")
        } footer: {
            Text("La radio automatica continua con brani simili quando la coda finisce. Le compilation da più di 15 minuti vengono escluse da radio, mood e \"Scelti per te\". Il timer di spegnimento è nel menu ··· del player.")
        }
    }

    private var lyricsSection: some View {
        Section {
            Picker(selection: $lyricsSize) {
                ForEach(LyricsSize.allCases) { Text($0.title).tag($0) }
            } label: {
                Label("Dimensione", systemImage: "textformat.size")
            }
            Picker(selection: $lyricsStyle) {
                ForEach(LyricsStyle.allCases) { Text($0.title).tag($0) }
            } label: {
                Label("Animazione", systemImage: "sparkles")
            }
        } header: {
            Text("Testi")
        }
    }

    private var appearanceSection: some View {
        Section {
            Toggle(isOn: $dynamicColors) {
                Label("Colori dalla copertina", systemImage: "paintpalette")
            }
        } header: {
            Text("Aspetto")
        } footer: {
            Text("Sfondi e player prendono il colore dell'album in riproduzione.")
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

    private var storageSection: some View {
        Section {
            LabeledContent("Brani scaricati",
                           value: ByteCountFormatter.string(fromByteCount: downloads.totalSize, countStyle: .file))
            Button("Elimina tutti i download", role: .destructive) { confirmDeleteDownloads = true }
                .disabled(downloads.totalSize == 0)
            Button(cacheCleared ? "Cache delle copertine svuotata" : "Svuota cache delle copertine") {
                URLCache.shared.removeAllCachedResponses()
                cacheCleared = true
            }
            .disabled(cacheCleared)
            Button("Cancella ricerche recenti") { recentSearches = "" }
                .disabled(recentSearches.isEmpty)
            Button("Cancella cronologia ascolti", role: .destructive) { library.clearHistory() }
                .disabled(library.history.isEmpty)
        } header: {
            Text("Spazio e dati")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Versione", value: Bundle.main.appVersion)
            Text("Catalogo: YouTube Music · Testi: LRCLIB · Scrobbling: Last.fm")
            Text("Progetto personale, non affiliato a Google, YouTube o Last.fm.")
        } header: {
            Text("Informazioni")
        }
        .font(.footnote)
    }

    // MARK: Last.fm

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
