import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var lastfm: LastFM
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var library: Library

    @AppStorage(Preferences.wifiQuality) private var wifiQuality = Preferences.defaultWifiQuality
    @AppStorage(Preferences.cellularQuality) private var cellularQuality = Preferences.defaultCellularQuality
    @AppStorage(Preferences.downloadQuality) private var downloadQuality = Preferences.defaultDownloadQuality
    @AppStorage(Preferences.spatialAudio) private var spatialAudio = true
    @AppStorage(Preferences.preferDolby) private var preferDolby = true
    @AppStorage(Preferences.crossfade) private var crossfade = Preferences.defaultCrossfade
    @AppStorage(Preferences.opusLastError) private var opusLastError = ""
    @AppStorage(Preferences.accent) private var accent: AccentChoice = .pink
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
                ForEach(AudioQuality.downloadCases) { Text($0.downloadTitle).tag($0) }
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            Toggle(isOn: $preferDolby) {
                Label("Dolby quando disponibile", systemImage: "hifispeaker.2")
            }
            Toggle(isOn: $spatialAudio) {
                Label("Audio spaziale", systemImage: "headphones")
            }
        } header: {
            Text("Audio")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Massima usa Opus 160 kbps, il formato migliore che YouTube dà senza Premium: Onda lo decodifica sull'iPhone e lo riproduce senza perdite. Il brano parte subito in AAC e passa a Opus appena è pronto; i due brani successivi vengono preparati in anticipo. Se un video ha l'audio Dolby Digital Plus o AAC 256 kbps, viene usato quello. L'Audio spaziale funziona con AirPods e cuffie Beats compatibili.")
                if !opusLastError.isEmpty {
                    Text("Ultimo errore Opus: \(opusLastError)")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var playbackSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Dissolvenza tra brani", systemImage: "waveform.path")
                    Spacer()
                    Text(crossfade == 0 ? "No" : "\(Int(crossfade)) s")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $crossfade, in: 0...12, step: 1)
            }
            Toggle(isOn: $player.autoRadio) {
                Label("Radio automatica", systemImage: "infinity")
            }
            Toggle(isOn: $skipLongMixes) {
                Label("Salta le compilation lunghe", systemImage: "forward.end")
            }
        } header: {
            Text("Riproduzione")
        } footer: {
            Text("La dissolvenza sovrappone la fine di un brano all'inizio del successivo, come su Spotify. La radio automatica continua con brani simili quando la coda finisce. Le compilation da più di 15 minuti vengono escluse da radio, mood e \"Scelti per te\". Il timer di spegnimento è nel menu ··· del player.")
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
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Colore del tema", systemImage: "paintbrush.fill")
                    Spacer()
                    Text(accent.title).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 12) {
                    ForEach(AccentChoice.allCases) { choice in
                        Button { accent = choice } label: {
                            Circle()
                                .fill(choice.color.gradient)
                                .frame(width: 34, height: 34)
                                .overlay {
                                    if choice == accent {
                                        Image(systemName: "checkmark")
                                            .font(.footnote.weight(.bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                                .overlay { Circle().strokeBorder(Color.primary.opacity(choice == accent ? 0.6 : 0), lineWidth: 2).padding(-4) }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(choice.title)
                    }
                }
                .padding(.vertical, 4)
            }
            Toggle(isOn: $dynamicColors) {
                Label("Colori dalla copertina", systemImage: "paintpalette")
            }
        } header: {
            Text("Aspetto")
        } footer: {
            Text("Il colore del tema si usa per pulsanti, interruttori e brano in riproduzione. Con \"Colori dalla copertina\" sfondi e player prendono il colore dell'album in riproduzione.")
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
            Button(cacheCleared ? "Cache svuotata" : "Svuota cache (copertine e brani Opus)") {
                URLCache.shared.removeAllCachedResponses()
                OpusPipeline.clearCache()
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
