import SwiftUI
import UIKit

/// Settings as the iPhone's own: a short list of topics, each opening its page.
struct SettingsView: View {
    @EnvironmentObject private var lastfm: LastFM
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var updater: AppUpdater
    @EnvironmentObject private var account: AccountService

    @AppStorage(Preferences.wifiQuality) private var wifiQuality = Preferences.defaultWifiQuality
    @AppStorage(Preferences.songTransition) private var transition: SongTransition = Preferences.songTransitionSetting
    @AppStorage(Preferences.accent) private var accent: AccentChoice = .pink
    @AppStorage(Preferences.lyricsTranslate) private var translateLyrics = false

    @State private var showEqualizer = false
    @State private var showAccount = false

    var body: some View {
        NavigationStack {
            List {
                // Only in builds that know the account service (see build.yml).
                if account.isAvailable {
                    Section {
                        NavigationLink { AccountSettingsView() } label: { AccountSettingsRow() }
                    }
                }
                Section {
                    NavigationLink { AudioSettingsView() } label: {
                        SettingsRow("Audio", symbol: "waveform", tint: .pink, value: wifiQuality.title)
                    }
                    NavigationLink { PlaybackSettingsView() } label: {
                        SettingsRow("Riproduzione", symbol: "play.fill", tint: .orange,
                                    value: (transition == .autoMix && !account.unlocks(.autoMix) ? .crossfade : transition).title)
                    }
                    NavigationLink { LyricsSettingsView() } label: {
                        SettingsRow("Testi", symbol: "quote.bubble.fill", tint: .purple,
                                    value: translateLyrics && account.unlocks(.lyricsTranslation)
                                        ? String(localized: "Tradotti") : nil)
                    }
                }
                Section {
                    NavigationLink { AppearanceSettingsView() } label: {
                        SettingsRow("Aspetto", symbol: "paintbrush.fill", tint: .blue, value: accent.title)
                    }
                    Button {
                        // On a Mac an app's language is in System Settings › General › Language & Region.
                        let settings = ProcessInfo.processInfo.isMacCatalystApp
                            ? "x-apple.systempreferences:com.apple.Localization-Settings.extension"
                            : UIApplication.openSettingsURLString
                        if let url = URL(string: settings) { UIApplication.shared.open(url) }
                    } label: {
                        SettingsRow("Lingua", symbol: "globe", tint: .teal, value: Self.appLanguage)
                    }
                    .foregroundStyle(.primary)
                }
                Section {
                    NavigationLink { LastFMSettingsView() } label: {
                        SettingsRow("Last.fm", symbol: "dot.radiowaves.left.and.right", tint: .red,
                                    value: lastfm.isConnected ? lastfm.username : String(localized: "Non connesso"))
                    }
                    NavigationLink { StorageSettingsView() } label: {
                        SettingsRow("Spazio", symbol: "internaldrive.fill", tint: .gray,
                                    value: ByteCountFormatter.string(fromByteCount: downloads.totalSize, countStyle: .file))
                    }
                    NavigationLink { UpdatesSettingsView() } label: {
                        SettingsRow("Aggiornamenti", symbol: "arrow.down.app.fill", tint: .green,
                                    value: updater.status == .available ? String(localized: "Nuova versione") : nil)
                    }
                }
                Section {
                    NavigationLink { AboutSettingsView() } label: {
                        SettingsRow("Informazioni", symbol: "info.circle.fill", tint: .indigo, value: Bundle.main.appVersion)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background { AmbientBackground() }
            .navigationTitle("Impostazioni")
            // Opened directly only by the CI screenshots (see `LaunchScene`).
            .navigationDestination(isPresented: $showEqualizer) { EqualizerView() }
            .navigationDestination(isPresented: $showAccount) { AccountSettingsView() }
            .task {
                if LaunchScene.opensEqualizer { showEqualizer = true }
                if LaunchScene.opensAccount { showAccount = true }
            }
        }
    }

    /// The app's language (the iPhone's, or the one chosen for Seaglass in iOS's settings).
    private static var appLanguage: String {
        let code = Bundle.main.preferredLocalizations.first ?? "en"
        return Locale.current.localizedString(forIdentifier: code)?.capitalized(with: Locale.current) ?? code
    }
}

/// A row of the settings' list: a coloured icon, the topic and, on the right, its current value.
struct SettingsRow: View {
    let title: LocalizedStringKey
    let symbol: String
    let tint: Color
    var value: String?

    init(_ title: LocalizedStringKey, symbol: String, tint: Color, value: String? = nil) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.value = value
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(tint.gradient, in: .rect(cornerRadius: 7))
            Text(title)
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// The settings' pages share the app's background.
private extension View {
    func settingsPage(_ title: LocalizedStringKey) -> some View {
        scrollContentBackground(.hidden)
            .background { AmbientBackground() }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: Audio

private struct AudioSettingsView: View {
    @EnvironmentObject private var player: PlayerController
    @ObservedObject private var equalizer = Equalizer.shared
    @AppStorage(Preferences.wifiQuality) private var wifiQuality = Preferences.defaultWifiQuality
    @AppStorage(Preferences.cellularQuality) private var cellularQuality = Preferences.defaultCellularQuality
    @AppStorage(Preferences.downloadQuality) private var downloadQuality = Preferences.defaultDownloadQuality
    @AppStorage(Preferences.preferDolby) private var preferDolby = true
    @AppStorage(Preferences.opusFromStart) private var opusFromStart = true
    @AppStorage(Preferences.spatialAudio) private var spatialAudio = true
    @AppStorage(Preferences.normalizeVolume) private var normalizeVolume = true
    @AppStorage(Preferences.playerVolumeBar) private var playerVolumeBar = true

    var body: some View {
        Form {
            Section {
                Picker(selection: $wifiQuality) {
                    ForEach(AudioQuality.allCases) { Text($0.title).tag($0) }
                } label: {
                    Label("Wi-Fi", systemImage: "wifi")
                }
                Picker(selection: $cellularQuality) {
                    ForEach(AudioQuality.allCases) { Text($0.title).tag($0) }
                } label: {
                    Label("Rete cellulare", systemImage: "antenna.radiowaves.left.and.right")
                }
                Picker(selection: $downloadQuality) {
                    ForEach(AudioQuality.downloadCases) { Text($0.downloadTitle).tag($0) }
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
            } header: {
                Text("Qualità")
            } footer: {
                Text("«Massima» usa Opus a 160 kbps, la qualità più alta di YouTube senza Premium.")
            }

            Section {
                Toggle(isOn: $spatialAudio) {
                    Label("Audio spaziale", systemImage: "headphones")
                }
                Toggle(isOn: $normalizeVolume) {
                    Label("Volume uniforme", systemImage: "speaker.wave.2")
                }
                // A Mac's player always has its volume, in its corner and in the player bar.
                if !ProcessInfo.processInfo.isMacCatalystApp {
                    Toggle(isOn: $playerVolumeBar) {
                        Label("Volume nel player", systemImage: "speaker.wave.3")
                    }
                }
                NavigationLink { EqualizerView() } label: {
                    LabeledContent {
                        Text(equalizer.isOn ? equalizer.preset.title : String(localized: "Disattivato"))
                    } label: {
                        Label("Equalizzatore", systemImage: "slider.vertical.3")
                    }
                }
            } footer: {
                Text("Volume uniforme porta tutti i brani allo stesso livello.")
            }

            Section {
                Toggle(isOn: $preferDolby) {
                    Label("Dolby quando disponibile", systemImage: "hifispeaker.2")
                }
                Toggle(isOn: $opusFromStart) {
                    Label("Opus dal primo suono", systemImage: "waveform")
                }
            } header: {
                Text("Formato")
            } footer: {
                Text("Con Opus dal primo suono i brani partono subito in Opus invece che in AAC.")
            }
        }
        .settingsPage("Audio")
        .onChange(of: spatialAudio) { _, _ in player.applySpatialAudioPreference() }
        .onChange(of: normalizeVolume) { _, _ in player.applyAudioEffectsPreference() }
    }
}

// MARK: Playback

private struct PlaybackSettingsView: View {
    @EnvironmentObject private var player: PlayerController
    @AppStorage(Preferences.songTransition) private var transition: SongTransition = Preferences.songTransitionSetting
    @AppStorage(Preferences.crossfade) private var crossfade = Preferences.defaultCrossfade
    @AppStorage(Preferences.skipLongMixes) private var skipLongMixes = true
    @AppStorage(Preferences.liveMix) private var liveMix = true
    @AppStorage(Preferences.mixLengthKey) private var mixLength = SegueLength.normal.rawValue
    @AppStorage(Preferences.autoMixEqualiserKey) private var autoMixEqualiser = true
    @AppStorage(Preferences.transitionMark) private var transitionMark = true
    @ObservedObject private var account = AccountService.shared
    @State private var paywall: PremiumFeature?

    /// The transitions that play: without Premium (where AutoMix needs it) AutoMix is a crossfade,
    /// and choosing it explains Premium.
    private var shownTransition: Binding<SongTransition> {
        Binding(get: { transition == .autoMix && !account.unlocks(.autoMix) ? .crossfade : transition },
                set: { value in
                    if value == .autoMix, !account.unlocks(.autoMix) { paywall = .autoMix } else { transition = value }
                })
    }

    /// A choice's name in the picker: AutoMix is a beta feature, and a Premium one.
    private func pickerTitle(_ option: SongTransition) -> String {
        guard option == .autoMix else { return option.title }
        let beta = "\(option.title) · \(String(localized: "Beta"))"
        return account.unlocks(.autoMix) ? beta : "\(beta) · Premium"
    }

    var body: some View {
        Form {
            Section {
                Picker(selection: shownTransition) {
                    ForEach(SongTransition.allCases) { option in
                        Text(verbatim: pickerTitle(option)).tag(option)
                    }
                } label: {
                    Label("Transizioni", systemImage: "waveform.path")
                }
                .onChange(of: transition) { _, value in
                    if value == .crossfade, crossfade < 1 { crossfade = Preferences.defaultCrossfade }
                    player.applyTransitionPreference()
                }
                if shownTransition.wrappedValue == .crossfade {
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
            } footer: {
                if shownTransition.wrappedValue == .autoMix {
                    Text("AutoMix sceglie come passare da un brano all'altro, a tempo come un DJ quando il ritmo lo permette.")
                } else if !account.unlocks(.autoMix) {
                    Text(String(localized: "\(PremiumFeature.autoMix.title) fa parte di Premium."))
                }
            }

            if shownTransition.wrappedValue == .autoMix {
                Section {
                    Toggle(isOn: $liveMix) {
                        Label("Mix dal vivo", systemImage: "dial.medium")
                    }
                    if liveMix {
                        Picker(selection: $mixLength) {
                            Text("Breve").tag(SegueLength.short.rawValue)
                            Text("Normale").tag(SegueLength.normal.rawValue)
                            Text("Lunga").tag(SegueLength.long.rawValue)
                        } label: {
                            Label("Durata del mix", systemImage: "ruler")
                        }
                        Toggle(isOn: $autoMixEqualiser) {
                            Label("Equalizzazione automatica", systemImage: "slider.vertical.3")
                        }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text("AutoMix")
                        BetaBadge()
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("AutoMix suona il brano successivo su un secondo lettore, a tempo con quello in corso, con livelli, bassi e filtri automatici. Spento, usa i mix preparati in un file.")
                        if liveMix {
                            Text("Breve: fino a 8 battute. Normale: fino a 16. Lunga: fino a 32, quando i due brani tengono il tempo così a lungo. Con l'equalizzazione automatica bassi, medi, alti, filtri ed eco passano da un brano all'altro; spenta, cambiano solo i volumi.")
                        }
                    }
                }
                .onChange(of: mixLength) { _, _ in player.applyTransitionPreference() }
                .onChange(of: autoMixEqualiser) { _, _ in player.applyTransitionPreference() }
            }

            if shownTransition.wrappedValue != .off {
                Section {
                    Toggle(isOn: $transitionMark) {
                        Label("Segna il mix sulla barra", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    }
                } footer: {
                    Text("Quando si avvicina, la barra di avanzamento del player mostra dove avverrà il mix.")
                }
            }

            Section {
                Toggle(isOn: $player.autoRadio) {
                    Label("Radio automatica", systemImage: "infinity")
                }
            } footer: {
                Text("Quando la coda finisce, continua con brani simili.")
            }

            Section {
                Toggle(isOn: $skipLongMixes) {
                    Label("Salta le compilation lunghe", systemImage: "forward.end")
                }
            } footer: {
                Text("Tiene fuori da radio e consigli i video di oltre 15 minuti.")
            }
        }
        .settingsPage("Riproduzione")
        .premiumPaywall($paywall)
    }
}

// MARK: Lyrics

private struct LyricsSettingsView: View {
    @AppStorage(Preferences.lyricsSize) private var lyricsSize: LyricsSize = .medium
    @AppStorage(Preferences.lyricsStyle) private var lyricsStyle: LyricsStyle = .focus
    @AppStorage(Preferences.lyricsTranslate) private var translateLyrics = false
    @AppStorage(Preferences.lyricsTranslationTarget) private var translationTarget = Preferences.defaultTranslationTarget
    @ObservedObject private var account = AccountService.shared
    @State private var paywall: PremiumFeature?

    /// Translation is a Premium feature where Premium can be bought: the switch explains it then.
    private var translation: Binding<Bool> {
        Binding(get: { translateLyrics && account.unlocks(.lyricsTranslation) },
                set: { on in
                    if on, !account.unlocks(.lyricsTranslation) { paywall = .lyricsTranslation } else { translateLyrics = on }
                })
    }

    var body: some View {
        Form {
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
            }

            Section {
                Toggle(isOn: translation) {
                    HStack {
                        Label("Traduci i testi", systemImage: "translate")
                        if !account.unlocks(.lyricsTranslation) { PremiumBadge() }
                    }
                }
                if translation.wrappedValue {
                    Picker(selection: $translationTarget) {
                        ForEach(Preferences.translationLanguages, id: \.self) { identifier in
                            Text(Preferences.languageName(identifier)).tag(identifier)
                        }
                    } label: {
                        Label("Traduci in", systemImage: "globe")
                    }
                    TranslationDownloadRow(targetIdentifier: translationTarget)
                }
            } footer: {
                Text("La traduzione avviene sul dispositivo, anche offline.")
            }
        }
        .settingsPage("Testi")
        .premiumPaywall($paywall)
    }
}

// MARK: Appearance

private struct AppearanceSettingsView: View {
    @EnvironmentObject private var player: PlayerController
    @AppStorage(Preferences.accent) private var accent: AccentChoice = .pink
    @AppStorage(Preferences.interactiveArtwork) private var interactiveArtwork = true
    @AppStorage(Preferences.dynamicColors) private var dynamicColors = true
    @AppStorage(Preferences.macZoom) private var zoom = 100

    var body: some View {
        Form {
            if ProcessInfo.processInfo.isMacCatalystApp {
                Section {
                    Picker(selection: $zoom) {
                        ForEach(MacZoom.levels, id: \.self) { level in
                            Text(verbatim: "\(level) %").tag(level)
                        }
                    } label: {
                        Label("Zoom", systemImage: "plus.magnifyingglass")
                    }
                } footer: {
                    Text("Ingrandisce o riduce testi e pulsanti, come su Spotify. Anche con ⌘+, ⌘− e ⌘0.")
                }
            }
            Section {
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
                                .overlay {
                                    Circle().strokeBorder(Color.primary.opacity(choice == accent ? 0.6 : 0), lineWidth: 2)
                                        .padding(-4)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(choice.title)
                    }
                }
                .padding(.vertical, 6)
            } header: {
                Text("Colore del tema")
            }

            Section {
                Toggle(isOn: $dynamicColors) {
                    Label("Colori dalla copertina", systemImage: "paintpalette")
                }
                Toggle(isOn: $interactiveArtwork) {
                    Label("Copertina interattiva", systemImage: "rotate.3d")
                }
            } footer: {
                Text("La copertina interattiva si inclina con il dispositivo; con un doppio tocco metti Mi piace.")
            }
        }
        .settingsPage("Aspetto")
        .onChange(of: dynamicColors) { _, _ in player.applyThemePreference() }
    }
}

// MARK: Last.fm

private struct LastFMSettingsView: View {
    @EnvironmentObject private var lastfm: LastFM
    @State private var keyDraft = ""
    @State private var secretDraft = ""
    @State private var editingKeys = false
    @State private var authURL: IdentifiedURL?
    /// On a Mac: the Last.fm page is open in the browser, waiting for the user to come back.
    @State private var authInBrowser = false
    @State private var working = false
    @State private var alertText: String?
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
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
            } footer: {
                Text("Serve una API key gratuita di Last.fm. Un brano viene registrato dopo metà ascolto o 4 minuti.")
            }
        }
        .settingsPage("Last.fm")
        .sheet(item: $authURL, onDismiss: finishAuth) { item in
            SafariView(url: item.url).ignoresSafeArea()
        }
        .alert("Last.fm", isPresented: $authInBrowser) {
            Button("Annulla", role: .cancel) {}
            Button("OK") { finishAuth() }
        } message: {
            Text("Consenti l'accesso a Seaglass nella pagina di Last.fm aperta nel browser, poi torna qui e fai clic su OK.")
        }
        .alert("Last.fm", isPresented: Binding(get: { alertText != nil }, set: { if !$0 { alertText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertText ?? "")
        }
    }

    private func connect() {
        working = true
        Task {
            do {
                let url = try await lastfm.beginAuth()
                if ProcessInfo.processInfo.isMacCatalystApp {
                    // On a Mac, Safari's sheet would hand the page to the browser anyway (and stay empty).
                    openURL(url)
                    authInBrowser = true
                } else {
                    authURL = IdentifiedURL(url: url)
                }
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

// MARK: Storage

private struct StorageSettingsView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var library: Library
    @AppStorage(Preferences.recentSearches) private var recentSearches = ""
    @AppStorage(Preferences.recentSearchItems) private var recentSearchItems = Data()
    @State private var confirmDeleteDownloads = false
    @State private var cacheCleared = false
    /// Bumped after deleting files, so sizes read from disk refresh.
    @State private var storageRevision = 0

    var body: some View {
        Form {
            Section {
                NavigationLink { DownloadStorageView() } label: {
                    LabeledContent("Brani scaricati",
                                   value: ByteCountFormatter.string(fromByteCount: downloads.totalSize, countStyle: .file))
                }
                Button("Elimina tutti i download", role: .destructive) { confirmDeleteDownloads = true }
                    .disabled(downloads.totalSize == 0)
            }

            Section {
                LabeledContent("Tracce karaoke salvate",
                               value: ByteCountFormatter.string(fromByteCount: StemSeparator.cacheSize, countStyle: .file))
                    .id(storageRevision)
                Button("Elimina le tracce karaoke") {
                    StemSeparator.clearCache()
                    storageRevision += 1
                }
                Button(cacheCleared ? "Cache svuotata" : "Svuota cache (copertine e brani Opus)") {
                    URLCache.shared.removeAllCachedResponses()
                    OpusPipeline.clearCache()
                    cacheCleared = true
                }
                .disabled(cacheCleared)
            }

            Section {
                Button("Cancella ricerche recenti") {
                    recentSearches = ""
                    recentSearchItems = Data()
                }
                .disabled(recentSearches.isEmpty && RecentSearch.decode(recentSearchItems).isEmpty)
                Button("Cancella cronologia ascolti", role: .destructive) { library.clearHistory() }
                    .disabled(library.history.isEmpty)
            }
        }
        .settingsPage("Spazio")
        .confirmationDialog("Eliminare tutti i brani scaricati?", isPresented: $confirmDeleteDownloads,
                            titleVisibility: .visible) {
            Button("Elimina", role: .destructive) { downloads.removeAll() }
        }
    }
}

// MARK: Updates

private struct UpdatesSettingsView: View {
    @EnvironmentObject private var updater: AppUpdater
    @AppStorage(Preferences.updateMode) private var updateMode: UpdateMode = .standard

    var body: some View {
        Form {
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
                        status
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
                MacInstallStatus()
            } footer: {
                if ProcessInfo.processInfo.isMacCatalystApp {
                    Text("Con «Installa in automatico» gli aggiornamenti si scaricano e si preparano da soli. Seaglass ti chiede prima di riavviarsi, oppure li installa quando esci dall'app.")
                } else {
                    Text("Gli aggiornamenti si installano con Sideloadly, AltStore o SideStore. Quelli scaricati sono nell'app File, in Seaglass › \(Storage.updatesFolderName).")
                }
            }
        }
        .settingsPage("Aggiornamenti")
    }

    @ViewBuilder private var status: some View {
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
}

// MARK: About

private struct AboutSettingsView: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Versione", value: Bundle.main.appVersion)
                Link("Licenza e crediti", destination: AppUpdater.licenseURL)
                Link("Codice sorgente su GitHub", destination: AppUpdater.repositoryURL)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Catalogo: YouTube Music · Testi: LRCLIB · Scrobbling: Last.fm")
                    Text("Progetto personale, non affiliato a Google, YouTube o Last.fm.")
                    Text(verbatim: "© 2026 Foglio24")
                }
            }

            Section {
                NavigationLink { DiagnosticsSettingsView() } label: {
                    Label("Diagnostica", systemImage: "stethoscope")
                }
            }
        }
        .settingsPage("Informazioni")
    }
}

// MARK: Diagnostics

/// What only helps when something goes wrong: crash reports, start times and the last decisions
/// of the player, AutoMix and the karaoke.
private struct DiagnosticsSettingsView: View {
    @ObservedObject private var diagnostics = Diagnostics.shared
    @ObservedObject private var startupMetrics = PlaybackStartupMetrics.shared
    @AppStorage(Preferences.lastOpusFallback) private var lastOpusFallback = ""
    @AppStorage(Preferences.opusLastError) private var opusLastError = ""
    @AppStorage(Preferences.nowPlayingAccepted) private var nowPlayingAccepted = -1
    @AppStorage(Preferences.nowPlayingBackend) private var nowPlayingBackend = ""
    @AppStorage(Preferences.lastRouteChange) private var lastRouteChange = ""
    @AppStorage(Preferences.lastHandover) private var lastHandover = ""
    @AppStorage(Preferences.lastAutoMixChoice) private var lastAutoMixChoice = ""

    var body: some View {
        Form {
            Section {
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
                Text("Rapporti")
            } footer: {
                Text("Se Seaglass si chiude da sola, iOS prepara un rapporto tecnico: toccalo per condividerlo.")
            }

            Section {
                startupTimes
            } header: {
                Text("Avvio dei brani")
            }

            Section {
                if !opusLastError.isEmpty {
                    LabeledContent("Ultimo errore Opus", value: opusLastError)
                        .textSelection(.enabled)
                }
                if !lastOpusFallback.isEmpty {
                    LabeledContent("Ultimo ripiego su AAC", value: lastOpusFallback)
                        .textSelection(.enabled)
                }
                LabeledContent {
                    Text(StemSeparator.isAvailable ? "Incluso nell'app" : "Non disponibile")
                } label: {
                    Text("Modello AI (UVR MDX-Net)")
                }
                if let lastRun = StemSeparator.lastRun {
                    LabeledContent("Ultima preparazione", value: lastRun)
                }
                if let note = StemSeparator.interruptedRun {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("L'ultima preparazione si è interrotta", systemImage: "exclamationmark.triangle")
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Audio e karaoke")
            }

            Section {
                LabeledContent("Player di sistema", value: nowPlayingStatus)
                LabeledContent("Sistema usato", value: nowPlayingBackend.isEmpty ? "—" : nowPlayingBackend)
                LabeledContent("Ultimo cambio di uscita audio", value: lastRouteChange.isEmpty ? "—" : lastRouteChange)
                    .textSelection(.enabled)
                LabeledContent("Ultimo passaggio AutoMix", value: lastHandover.isEmpty ? "—" : lastHandover)
                    .textSelection(.enabled)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ultima scelta AutoMix")
                    Text(lastAutoMixChoice.isEmpty ? "—" : lastAutoMixChoice)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                LabeledContent("Bundle ID", value: Bundle.main.bundleIdentifier ?? "—")
                    .textSelection(.enabled)
            } header: {
                Text("Sistema")
            }
            .font(.footnote)
        }
        .settingsPage("Diagnostica")
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
        // Each way a song can start, on its own: prepared or not, Opus or not.
        ForEach(Self.sources, id: \.self) { source in
            if let median = startupMetrics.manualMedian(for: source), let name = Self.sourceName(source) {
                LabeledContent(name, value: String(localized: "\(Self.seconds(median.median)) · mediana di \(median.count)"))
            }
        }
        if let last = startupMetrics.last {
            LabeledContent("Ultimo avvio", value: Self.describe(last))
            Button("Azzera i tempi di avvio") { startupMetrics.removeAll() }
        } else {
            Text("Nessun dato")
                .foregroundStyle(.secondary)
        }
    }

    private static let sources: [StartupSource] = [.opusPrepared, .opusResolvedURL, .opusNetwork, .prepared,
                                                   .resolvedURL, .network, .localFile]

    /// The last start, and for Opus its steps: first byte, first decoded audio, first audio played.
    private static func describe(_ sample: PlaybackStartupMetrics.Sample) -> String {
        var parts = [seconds(sample.playingAfter), sourceName(sample.source)].compactMap { $0 }
        if let value = sample.firstByteAfter { parts.append(String(localized: "primo byte \(seconds(value))")) }
        if let value = sample.firstDecodedAfter { parts.append(String(localized: "primo audio decodificato \(seconds(value))")) }
        if let value = sample.firstAudioAfter { parts.append(String(localized: "primo audio \(seconds(value))")) }
        if sample.fellBack { parts.append(String(localized: "Opus non riuscito: AAC")) }
        return parts.joined(separator: " · ")
    }

    private static func seconds(_ value: TimeInterval) -> String {
        value.formatted(.number.precision(.fractionLength(2))) + " s"
    }

    private static func sourceName(_ source: StartupSource?) -> String? {
        switch source {
        case .prepared?, .preparing?: return String(localized: "già preparato")
        case .resolvedURL?: return String(localized: "link già pronto")
        case .network?: return String(localized: "da internet")
        case .localFile?: return String(localized: "file sull'iPhone")
        case .opusPrepared?: return String(localized: "Opus, già preparato")
        case .opusResolvedURL?: return String(localized: "Opus, link già pronto")
        case .opusNetwork?: return String(localized: "Opus, da internet")
        case nil: return nil
        }
    }

    private var nowPlayingStatus: String {
        switch nowPlayingAccepted {
        case 1: return String(localized: "Seaglass (accettato da iOS)")
        case 0: return String(localized: "Rifiutato da iOS")
        default: return "—"
        }
    }
}
