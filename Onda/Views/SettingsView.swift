import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var lastfm: LastFM
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var updater: AppUpdater
    @ObservedObject private var diagnostics = Diagnostics.shared
    @ObservedObject private var equalizer = Equalizer.shared
    @ObservedObject private var startupMetrics = PlaybackStartupMetrics.shared

    @AppStorage(Preferences.wifiQuality) private var wifiQuality = Preferences.defaultWifiQuality
    @AppStorage(Preferences.cellularQuality) private var cellularQuality = Preferences.defaultCellularQuality
    @AppStorage(Preferences.downloadQuality) private var downloadQuality = Preferences.defaultDownloadQuality
    @AppStorage(Preferences.spatialAudio) private var spatialAudio = true
    @AppStorage(Preferences.normalizeVolume) private var normalizeVolume = true
    @AppStorage(Preferences.preferDolby) private var preferDolby = true
    @AppStorage(Preferences.crossfade) private var crossfade = Preferences.defaultCrossfade
    @AppStorage(Preferences.songTransition) private var transition: SongTransition = Preferences.songTransitionSetting
    @AppStorage(Preferences.opusLastError) private var opusLastError = ""
    @AppStorage(Preferences.accent) private var accent: AccentChoice = .pink
    @AppStorage(Preferences.nowPlayingAccepted) private var nowPlayingAccepted = -1
    @AppStorage(Preferences.nowPlayingBackend) private var nowPlayingBackend = ""
    @AppStorage(Preferences.lyricsTranslate) private var translateLyrics = false
    @AppStorage(Preferences.interactiveArtwork) private var interactiveArtwork = true
    @AppStorage(Preferences.lyricsTranslationTarget) private var translationTarget = Preferences.defaultTranslationTarget
    @AppStorage(Preferences.skipLongMixes) private var skipLongMixes = true
    @AppStorage(Preferences.dynamicColors) private var dynamicColors = true
    @AppStorage(Preferences.lyricsStyle) private var lyricsStyle: LyricsStyle = .focus
    @AppStorage(Preferences.lyricsSize) private var lyricsSize: LyricsSize = .medium
    @AppStorage(Preferences.recentSearches) private var recentSearches = ""
    @AppStorage(Preferences.updateMode) private var updateMode: UpdateMode = .notify

    @State private var keyDraft = ""
    @State private var secretDraft = ""
    @State private var editingKeys = false
    @State private var authURL: IdentifiedURL?
    @State private var working = false
    @State private var alertText: String?
    @State private var confirmDeleteDownloads = false
    @State private var cacheCleared = false
    @State private var showEqualizer = false
    /// Bumped after deleting files, so sizes and statuses read from disk refresh.
    @State private var storageRevision = 0

    var body: some View {
        NavigationStack {
            Form {
                audioSection
                playbackSection
                karaokeSection
                lyricsSection
                appearanceSection
                languageSection
                lastfmSection
                storageSection
                updatesSection
                diagnosticsSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background { AmbientBackground() }
            .navigationTitle("Impostazioni")
            // Opened directly only by the CI screenshots (see `LaunchScene`).
            .navigationDestination(isPresented: $showEqualizer) { EqualizerView() }
            .task { if LaunchScene.opensEqualizer { showEqualizer = true } }
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
            .onChange(of: normalizeVolume) { _, _ in player.applyAudioEffectsPreference() }
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
            Toggle(isOn: $normalizeVolume) {
                Label("Volume uniforme", systemImage: "speaker.wave.2")
            }
            NavigationLink { EqualizerView() } label: {
                LabeledContent {
                    Text(equalizer.isOn ? equalizer.preset.title : String(localized: "Disattivato"))
                } label: {
                    Label("Equalizzatore", systemImage: "slider.vertical.3")
                }
            }
        } header: {
            Text("Audio")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Volume uniforme abbassa i brani più forti al livello di riferimento di YouTube (-14 LUFS), come la normalizzazione di Spotify, così passando da un brano all'altro il volume resta simile.")
                Text("Massima usa Opus 160 kbps, il formato migliore che YouTube dà senza Premium: Onda lo decodifica sull'iPhone e lo riproduce senza perdite. Il brano parte subito in AAC e lo tiene fino alla fine, senza salti: Opus viene preparato intanto e suona dal riascolto successivo (o da quando sposti la barra). Se un video ha l'audio Dolby Digital Plus o AAC 256 kbps, viene usato quello. L'Audio spaziale funziona con AirPods e cuffie Beats compatibili.")
                if !opusLastError.isEmpty {
                    Text("Ultimo errore Opus: \(opusLastError)")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var playbackSection: some View {
        Section {
            Picker(selection: $transition) {
                ForEach(SongTransition.allCases) { option in
                    Text(option.title).tag(option)
                }
            } label: {
                Label("Transizioni tra brani", systemImage: "waveform.path")
            }
            .onChange(of: transition) { _, value in
                if value == .crossfade, crossfade < 1 { crossfade = Preferences.defaultCrossfade }
                player.applyTransitionPreference()
            }
            if transition == .crossfade {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Durata della dissolvenza", systemImage: "timer")
                        Spacer()
                        Text("\(Int(crossfade)) s")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $crossfade, in: 1...12, step: 1)
                }
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
            Text("AutoMix mixa ogni brano nel successivo come un DJ, come su Apple Music: Onda prepara il mix in anticipo, con i due brani che cambiano velocità per incontrarsi a metà (fino al 30 per cento di differenza), il successivo che entra sul primo battito di una battuta saltando un'intro lunga, fino a 16 battute insieme con i bassi che passano dall'uno all'altro e un filtro che svuota il brano che esce. Con tempi troppo diversi o senza un ritmo regolare il mix è una lunga dissolvenza sul finale. Nella coda vedi cosa farà; mentre il mix suona, il player mostra \"AutoMix\". Il brano successivo viene analizzato e mixato dalla copia che Onda scarica comunque, senza dati in più. La radio automatica continua con brani simili quando la coda finisce. Le compilation da più di 15 minuti vengono escluse da radio, mood e \"Scelti per te\". Il timer di spegnimento è nel menu ··· del player.")
        }
    }

    private var karaokeSection: some View {
        Section {
            LabeledContent {
                Text(StemSeparator.isAvailable ? "Incluso nell'app" : "Non disponibile").foregroundStyle(.secondary)
            } label: {
                Label("Modello AI (UVR MDX-Net)", systemImage: "music.mic")
            }
            if let lastRun = StemSeparator.lastRun {
                LabeledContent("Ultima preparazione", value: lastRun)
                    .id(storageRevision)
            }
            LabeledContent("Tracce karaoke salvate",
                           value: ByteCountFormatter.string(fromByteCount: StemSeparator.cacheSize, countStyle: .file))
            Button("Elimina le tracce karaoke") {
                StemSeparator.clearCache()
                storageRevision += 1
            }
            if let note = StemSeparator.interruptedRun {
                VStack(alignment: .leading, spacing: 4) {
                    Label("L'ultima preparazione si è interrotta", systemImage: "exclamationmark.triangle")
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                .id(storageRevision)
            }
        } header: {
            Text("Karaoke")
        } footer: {
            Text("Il karaoke usa un modello di intelligenza artificiale che separa voce e musica sull'iPhone, con il Neural Engine e la GPU. Attivalo dal tasto 🎤 nel player: il brano continua a suonare mentre viene preparato, poi passa alla versione senza voce (o solo voce). Le tracce separate restano salvate per riascoltarle subito.")
                .id(storageRevision)
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
            Toggle(isOn: $translateLyrics) {
                Label("Traduci i testi", systemImage: "translate")
            }
            if translateLyrics {
                Picker(selection: $translationTarget) {
                    ForEach(Preferences.translationLanguages, id: \.self) { identifier in
                        Text(Preferences.languageName(identifier)).tag(identifier)
                    }
                } label: {
                    Label("Traduci in", systemImage: "globe")
                }
                TranslationDownloadRow(targetIdentifier: translationTarget)
            }
        } header: {
            Text("Testi")
        } footer: {
            Text("La traduzione avviene sull'iPhone con la traduzione di Apple: scarica la lingua qui una volta sola e i testi si traducono offline, senza rallentare il brano. Nel player il tasto 文A mostra o nasconde la traduzione.")
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
            Toggle(isOn: $interactiveArtwork) {
                Label("Copertina interattiva", systemImage: "rotate.3d")
            }
            Toggle(isOn: $dynamicColors) {
                Label("Colori dalla copertina", systemImage: "paintpalette")
            }
        } header: {
            Text("Aspetto")
        } footer: {
            Text("Il colore del tema si usa per pulsanti, interruttori e brano in riproduzione. La copertina interattiva si inclina con l'iPhone e con il dito; un doppio tocco mette Mi piace. Con \"Colori dalla copertina\" sfondi e player prendono il colore dell'album in riproduzione.")
        }
    }

    /// The app follows the iPhone's language; iOS lets each app have its own in the app's settings page.
    private var languageSection: some View {
        Section {
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            } label: {
                LabeledContent {
                    Text(appLanguage)
                } label: {
                    Label("Lingua", systemImage: "globe").foregroundStyle(.primary)
                }
            }
        } footer: {
            Text("Onda è in italiano e in inglese e segue la lingua dell'iPhone. Per cambiarla solo in Onda, tocca Lingua: si aprono le impostazioni dell'app, dove la scelta compare se sull'iPhone c'è più di una lingua preferita.")
        }
    }

    private var appLanguage: String {
        let code = Bundle.main.preferredLocalizations.first ?? "it"
        return Locale.current.localizedString(forLanguageCode: code)?.capitalized(with: Locale.current) ?? code
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
            NavigationLink { DownloadStorageView() } label: {
                LabeledContent("Brani scaricati",
                               value: ByteCountFormatter.string(fromByteCount: downloads.totalSize, countStyle: .file))
            }
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

    private var updatesSection: some View {
        Section {
            Picker(selection: $updateMode) {
                ForEach(UpdateMode.allCases) { Text($0.title).tag($0) }
            } label: {
                Label("Nuove versioni", systemImage: "arrow.down.app")
            }
            Button {
                Task { await updater.check(userInitiated: true) }
            } label: {
                LabeledContent {
                    updateStatus
                } label: {
                    Label("Cerca aggiornamenti", systemImage: "arrow.clockwise")
                        .foregroundStyle(.primary)
                }
            }
            .disabled(updater.status == .checking)
            if updater.status == .available, let latest = updater.latest {
                Button {
                    updater.showsNotice = true
                } label: {
                    Label("Novità della \(latest.version)", systemImage: "sparkles")
                }
            }
            if case .failed(let message) = updater.status {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Aggiornamenti")
        } footer: {
            Text("Onda controlla le nuove versioni su GitHub a ogni avvio, oppure quando tocchi Cerca aggiornamenti. Con «Scarica in automatico» il file IPA viene salvato nell'app File, in Sul mio iPhone › Onda › \(Storage.updatesFolderName): da lì lo installi con Sideloadly, AltStore o SideStore, perché iOS non permette a un'app installata così di aggiornarsi da sola.")
        }
    }

    private var diagnosticsSection: some View {
        Section {
            startupTimes
            if diagnostics.reports.isEmpty {
                Text("Nessun rapporto")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(diagnostics.reports) { report in
                    ShareLink(item: report.file) {
                        LabeledContent {
                            Image(systemName: "square.and.arrow.up")
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(report.summary)
                                    .foregroundStyle(.primary)
                                Text(report.date, format: .dateTime.day().month().year().hour().minute())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Button("Elimina i rapporti", role: .destructive) { diagnostics.removeAll() }
            }
        } header: {
            Text("Diagnostica")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("I tempi di avvio vanno dal tocco su un brano alla prima nota, sugli ultimi 20 avvii, e restano sull'iPhone.")
                Text("Se Onda si chiude da sola o si blocca, iOS prepara un rapporto tecnico e lo consegna all'app a un avvio successivo, di solito entro un giorno. Toccalo per condividerlo: contiene solo dati tecnici dell'app, non la tua musica né i tuoi account.")
            }
        }
    }

    /// How long songs take to start (see `PlaybackStartupMetrics`), once there is something to show.
    @ViewBuilder private var startupTimes: some View {
        if let median = startupMetrics.manualMedian {
            LabeledContent("Avvio dei brani scelti",
                           value: String(localized: "\(Self.seconds(median)) · mediana di \(startupMetrics.manualCount)"))
        }
        if let median = startupMetrics.automaticMedian {
            LabeledContent("Passaggio automatico",
                           value: String(localized: "\(Self.seconds(median)) · mediana di \(startupMetrics.automaticCount)"))
        }
        if let last = startupMetrics.last {
            LabeledContent("Ultimo avvio", value: [Self.seconds(last.playingAfter), Self.sourceName(last.source)]
                .compactMap { $0 }.joined(separator: " · "))
            Button("Azzera i tempi di avvio") { startupMetrics.removeAll() }
        }
    }

    private static func seconds(_ value: TimeInterval) -> String {
        value.formatted(.number.precision(.fractionLength(1))) + " s"
    }

    private static func sourceName(_ source: StartupSource?) -> String? {
        switch source {
        case .prepared?, .preparing?: return String(localized: "già preparato")
        case .resolvedURL?: return String(localized: "link già pronto")
        case .network?: return String(localized: "da internet")
        case .localFile?: return String(localized: "file sull'iPhone")
        case nil: return nil
        }
    }

    @ViewBuilder private var updateStatus: some View {
        switch updater.status {
        case .checking:
            ProgressView()
        case .upToDate:
            Text("Aggiornata").foregroundStyle(.secondary)
        case .available:
            Text("Nuova versione").foregroundStyle(.tint)
        case .failed:
            Text("Non riuscito").foregroundStyle(.secondary)
        case .idle:
            EmptyView()
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Versione", value: Bundle.main.appVersion)
            LabeledContent("Bundle ID", value: Bundle.main.bundleIdentifier ?? "—")
                .textSelection(.enabled)
            LabeledContent("Player di sistema", value: nowPlayingStatus)
            LabeledContent("Sistema usato", value: nowPlayingBackend.isEmpty ? "—" : nowPlayingBackend)
            Text("Catalogo: YouTube Music · Testi: LRCLIB · Scrobbling: Last.fm")
            Text("Progetto personale, non affiliato a Google, YouTube o Last.fm.")
            LabeledContent("Copyright", value: "© 2026 Foglio24")
            Link("Licenza e crediti", destination: AppUpdater.licenseURL)
            Link("Codice sorgente su GitHub", destination: AppUpdater.repositoryURL)
        } header: {
            Text("Informazioni")
        }
        .font(.footnote)
    }

    private var nowPlayingStatus: String {
        switch nowPlayingAccepted {
        case 1: return String(localized: "Onda (accettato da iOS)")
        case 0: return String(localized: "Rifiutato da iOS")
        default: return "—"
        }
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
