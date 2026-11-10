import AVFoundation
import SwiftUI

/// The same entry point on the Home and Search pages, on iPhone, iPad and Mac.
struct RecognitionButton: View {
    @ObservedObject private var account = AccountService.shared
    @State private var showsRecognition = false
    @State private var openedPreview = false
    @State private var paywall: PremiumFeature?

    var body: some View {
        Button {
            // A Premium feature where Premium can be bought.
            if account.unlocks(.recognition) { showsRecognition = true } else { paywall = .recognition }
        } label: {
            Label("Riconosci un brano", systemImage: "waveform.badge.magnifyingglass")
        }
        .sheet(isPresented: $showsRecognition) {
            RecognitionView(previewPhase: LaunchScene.recognitionPreview).appEnvironment()
        }
        .premiumPaywall($paywall)
        .onAppear {
            guard LaunchScene.opensRecognition, !openedPreview else { return }
            openedPreview = true
            showsRecognition = true
        }
    }
}

/// Keeps listening, its result and the result's actions in one sheet. Recording starts only after
/// the user has read the disclosure and pressed the listening button.
struct RecognitionView: View {
    /// Only `LaunchScene` supplies this for deterministic screenshots, without opening the mic.
    var previewPhase: MusicRecognizer.Phase? = nil
    @ObservedObject private var recognizer = MusicRecognizer.shared
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(Preferences.accent) private var accent: AccentChoice = .pink

    @State private var playlistTrack: Track?
    @State private var hasAppeared = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    phaseContent
                }
                .frame(maxWidth: 520)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Riconosci un brano")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fine") {
                        recognizer.stop()
                        dismiss()
                    }
                }
            }
        }
        .tint(accent.color)
        .presentationDetents([.large])
        .sheet(item: $playlistTrack) { track in
            AddToPlaylistSheet(track: track).appEnvironment()
        }
        .downloadErrorAlert(isActive: playlistTrack == nil)
        .onAppear {
            guard !hasAppeared else { return }
            hasAppeared = true
            recognizer.stop()
        }
        .onDisappear {
            if isWorking { recognizer.stop() }
        }
        .onChange(of: scenePhase) { _, phase in
            // The microphone permission prompt itself briefly makes the scene inactive.
            if phase == .background || (phase == .inactive && isCapturingOrMatching) {
                if isWorking { recognizer.stop() }
            }
        }
    }

    private var displayedPhase: MusicRecognizer.Phase { previewPhase ?? recognizer.phase }

    private var isWorking: Bool {
        if case .requestingPermission = displayedPhase { return true }
        return isCapturingOrMatching
    }

    private var isCapturingOrMatching: Bool {
        switch displayedPhase {
        case .listening, .matching: return true
        default: return false
        }
    }

    @ViewBuilder private var phaseContent: some View {
        switch displayedPhase {
        case .idle:
            introduction
        case .requestingPermission:
            activity(title: String(localized: "Autorizzazione microfono…"), subtitle: nil, listening: false)
        case .listening:
            activity(title: String(localized: "In ascolto…"), subtitle: String(localized: "Tieni il dispositivo vicino alla musica."), listening: true)
        case .matching:
            activity(title: String(localized: "Riconoscimento in corso…"), subtitle: String(localized: "Stiamo cercando il brano."), listening: false)
        case .found(let song):
            result(song)
        case .noMatch:
            retryMessage(title: String(localized: "Nessun brano riconosciuto"), message: String(localized: "Prova ad avvicinarti alla musica e ripeti l'ascolto."))
        case .failed(let message):
            retryMessage(title: String(localized: "Riconoscimento non riuscito"), message: message)
        }
    }

    private var introduction: some View {
        VStack(spacing: 24) {
            Text("Avvicina il dispositivo alla musica, poi tocca il pulsante.")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Button { recognizer.start() } label: {
                VStack(spacing: 18) {
                    RecognitionOrb(listening: false, waiting: false)
                    Text("Ascolta e riconosci").font(.headline)
                }
                .frame(maxWidth: .infinity)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            disclosure
        }
        .padding(.vertical, 28)
    }

    private var disclosure: some View {
        VStack(spacing: 6) {
            Text("Il microfono si attiva solo durante il riconoscimento. A Shazam viene inviata un’impronta audio, non la registrazione.")
            Text("L’ascolto si interrompe automaticamente dopo pochi secondi.")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }

    private func activity(title: String, subtitle: String?, listening: Bool) -> some View {
        VStack(spacing: 24) {
            Button { recognizer.stop() } label: {
                RecognitionOrb(listening: listening, waiting: !listening)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Interrompi"))
            .padding(.top, 32)
            Text(title).font(.title2.bold())
            if let subtitle {
                Text(subtitle).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Button("Interrompi") { recognizer.stop() }
                .buttonStyle(.bordered)
            disclosure
        }
        .frame(maxWidth: .infinity)
    }

    private func retryMessage(title: String, message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
                .padding(.top, 32)
                .accessibilityHidden(true)
            Text(title).font(.title2.bold())
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if AVAudioApplication.shared.recordPermission == .denied {
                Button("Apri impostazioni microfono") {
                    let settings = ProcessInfo.processInfo.isMacCatalystApp
                        ? "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
                        : UIApplication.openSettingsURLString
                    if let url = URL(string: settings) { UIApplication.shared.open(url) }
                }
                .buttonStyle(.borderedProminent)
            }
            Button("Riprova") { recognizer.start() }
                .buttonStyle(.borderedProminent)
            disclosure
        }
        .frame(maxWidth: .infinity)
    }

    private func result(_ song: RecognizedSong) -> some View {
        VStack(spacing: 20) {
            Label("Brano riconosciuto", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.tint)
            ArtworkView(track: song.track, size: 200, cornerRadius: 20, highRes: true)
                .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text(song.track.title).font(.title.bold()).multilineTextAlignment(.center)
                Text(song.track.artist).font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if let album = song.track.album {
                    Text(album).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            resultActions(song.track)
            metadata(song)
            VStack(spacing: 12) {
                if let url = song.songURL { Link("Apri il brano", destination: url) }
                if let url = song.appleMusicURL { Link("Apri in Apple Music", destination: url) }
                Button("Riconosci un altro brano") { recognizer.stop() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func resultActions(_ track: Track) -> some View {
        VStack(spacing: 10) {
            Button {
                PlayerController.shared.playRadio(from: track)
                dismiss()
            } label: {
                Label("Riproduci", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Button { library.toggleLike(track) } label: {
                Label(library.isLiked(track) ? "Togli dai preferiti" : "Aggiungi ai preferiti",
                      systemImage: library.isLiked(track) ? "heart.fill" : "heart")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            downloadButton(track)
            Button { playlistTrack = track } label: {
                Label("Aggiungi a playlist…", systemImage: "text.badge.plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
    }

    private func downloadButton(_ track: Track) -> some View {
        let state = downloads.state(of: track)
        return Button {
            if downloads.isQueued(track) { downloads.cancel([track]) }
            else { downloads.download(track) }
        } label: {
            HStack(spacing: 8) {
                switch state {
                case .none: Label("Scarica", systemImage: "arrow.down.circle")
                case .downloaded: Label("Scaricato", systemImage: "checkmark.circle.fill")
                case .waiting:
                    ProgressView().controlSize(.small)
                    Text("Annulla download")
                case .downloading(let fraction):
                    ProgressRing(value: fraction, size: 18)
                    Text("Annulla download")
                    Text(fraction, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(state == .downloaded)
    }

    @ViewBuilder private func metadata(_ song: RecognizedSong) -> some View {
        if song.releaseDate != nil || song.label != nil || song.genre != nil || song.composer != nil || song.isrc != nil {
            VStack(spacing: 12) {
                if let value = song.releaseDate { LabeledContent("Uscita", value: value) }
                if let value = song.label { LabeledContent("Etichetta", value: value) }
                if let value = song.genre { LabeledContent("Genere", value: value) }
                if let value = song.composer { LabeledContent("Compositore", value: value) }
                if let value = song.isrc {
                    LabeledContent { Text(value) } label: { Text(verbatim: "ISRC") }
                }
            }
            .font(.subheadline)
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(.thinMaterial, in: .rect(cornerRadius: 16))
        }
    }
}

/// Only the listening state animates continuously. No audio buffers or timers feed the view.
private struct RecognitionOrb: View {
    let listening: Bool
    let waiting: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(Preferences.accent) private var accent: AccentChoice = .pink

    var body: some View {
        ZStack {
            if listening, !reduceMotion {
                Circle()
                    .stroke(accent.color.opacity(0.25), lineWidth: 10)
                    .frame(width: 172, height: 172)
                    .phaseAnimator([false, true]) { ring, expanded in
                        ring.scaleEffect(expanded ? 1.18 : 0.95).opacity(expanded ? 0.15 : 1)
                    } animation: { _ in .easeInOut(duration: 1.1) }
            } else {
                Circle().stroke(accent.color.opacity(0.2), lineWidth: 8).frame(width: 172, height: 172)
            }
            Circle()
                .fill(accent.color.gradient)
                .frame(width: 144, height: 144)
                .shadow(color: accent.color.opacity(0.25), radius: 16, y: 6)
            if waiting {
                ProgressView().controlSize(.large).tint(.white)
            } else {
                Image(systemName: listening ? "waveform" : "music.note")
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.variableColor.iterative, isActive: listening && !reduceMotion)
            }
        }
        .frame(width: 210, height: 210)
        .accessibilityHidden(true)
    }
}
