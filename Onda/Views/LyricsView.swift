import NaturalLanguage
import SwiftUI
import Translation

struct LyricsView: View {
    @EnvironmentObject private var player: PlayerController

    var body: some View {
        switch player.lyrics {
        case .idle, .loading:
            ProgressView()
                .tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .synced(let lines):
            SyncedLyrics(lines: lines)
        case .plain(let text):
            ScrollView {
                Text(text)
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 32)
            }
            .scrollIndicators(.hidden)
            .mask { LyricsView.edgeFade }
        case .unavailable:
            ContentUnavailableView("Testo non disponibile", systemImage: "quote.bubble",
                                   description: Text("LRCLIB non ha il testo di questo brano."))
        }
    }

    /// Fades the lines in and out at the top and bottom edges.
    static var edgeFade: some View {
        LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: 0.08),
            .init(color: .black, location: 0.92),
            .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }
}

/// Karaoke-style lyrics: the current line lights up and stays centred; tap a line to jump there.
/// With translation on, each line shows its translation underneath, made on the iPhone by Apple's
/// Translation framework (see `LyricsTranslator`, which starts as soon as the song does).
private struct SyncedLyrics: View {
    let lines: [LyricLine]
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var progress: PlaybackProgress
    @EnvironmentObject private var translator: LyricsTranslator
    @AppStorage(Preferences.lyricsStyle) private var style: LyricsStyle = .focus
    @AppStorage(Preferences.lyricsSize) private var size: LyricsSize = .medium
    @AppStorage(Preferences.lyricsTranslate) private var translateEnabled = false
    @AppStorage(Preferences.lyricsTranslationTarget) private var targetIdentifier = Preferences.defaultTranslationTarget

    /// Used only to download a missing language, which shows the system sheet.
    @State private var configuration: TranslationSession.Configuration?
    @State private var downloading = false
    /// Set when the user turns translation on, so a missing language is downloaded right away.
    @State private var userAskedToTranslate = false

    /// Translated text by line id, once these lyrics have it.
    private var translations: [Int: String] {
        translator.lines == lines ? translator.translations : [:]
    }

    /// A language that can translate these lyrics once downloaded.
    private var downloadableSource: Locale.Language? {
        guard !downloading, translator.lines == lines, case .needsDownload(let source) = translator.phase else {
            return nil
        }
        return source
    }

    /// Short status under the 文A button ("Il testo è già in italiano", "Traduzione…"…).
    private var translationNote: String? {
        if downloading { return "Download della lingua…" }
        guard translator.lines == lines else { return nil }
        switch translator.phase {
        case .translating: return translations.isEmpty ? "Traduzione…" : nil
        case .note(let text): return text
        default: return nil
        }
    }

    private var inactiveOpacity: Double { style == .fade ? 0.22 : 0.32 }

    /// Lines are sorted by time and their ids are their positions.
    private var activeID: Int? {
        lines.last(where: { $0.time <= progress.currentTime + 0.25 })?.id
    }

    /// Changes whenever the song or the translation settings change.
    private var translationKey: String {
        "\(translateEnabled)|\(targetIdentifier)|\(lines.count)|\(lines.first?.text ?? "")"
    }

    var body: some View {
        let currentID = activeID
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    ForEach(lines) { line in
                        let active = line.id == currentID
                        VStack(alignment: .leading, spacing: 6) {
                            Text(line.text.isEmpty ? "♪" : line.text)
                                .font(.system(size: size.points, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.white.opacity(active ? 1 : inactiveOpacity))
                            if let translated = translations[line.id] {
                                Text(translated)
                                    .font(.system(size: size.points * 0.6, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Color.white.opacity(active ? 0.7 : inactiveOpacity * 0.8))
                            }
                        }
                        .blur(radius: style == .focus && !active ? 0.8 : 0)
                        .scaleEffect(style == .fade || active ? 1 : 0.94, anchor: .leading)
                        .shadow(color: Color.white.opacity(style == .glow && active ? 0.75 : 0),
                                radius: style == .glow && active ? 14 : 0)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                        .onTapGesture { player.seek(to: line.time) }
                        .animation(.spring(duration: 0.5, bounce: 0.2), value: active)
                        .id(line.id)
                    }
                }
                .padding(.vertical, 160)
            }
            .scrollIndicators(.hidden)
            .onChange(of: currentID) { _, id in
                guard let id else { return }
                withAnimation(.spring(duration: 0.6)) { proxy.scrollTo(id, anchor: .center) }
            }
            .onAppear {
                if let currentID { proxy.scrollTo(currentID, anchor: .center) }
            }
        }
        .mask { LyricsView.edgeFade }
        // Outside the fade, so the controls are always fully visible.
        .overlay(alignment: .topTrailing) { translationControls }
        // Usually already done by the player when the song started; this catches setting changes.
        .task(id: translationKey) { translator.show(lines) }
        .onChange(of: translator.phase) { _, phase in
            guard userAskedToTranslate, phase != .translating else { return }
            userAskedToTranslate = false
            // The user just turned translation on: ask for the missing language straight away.
            if case .needsDownload(let source) = phase { downloadAndTranslate(from: source) }
        }
        .translationTask(configuration) { session in
            await translator.translate(lines, with: session)
            downloading = false
        }
    }

    // MARK: Translation

    private var translationControls: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Button {
                translateEnabled.toggle()
                userAskedToTranslate = translateEnabled
            } label: {
                Image(systemName: "translate")
                    .font(.footnote.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(translateEnabled ? 0.3 : 0.12), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(translateEnabled ? "Nascondi traduzione" : "Mostra traduzione")

            if translateEnabled, let source = downloadableSource {
                Button {
                    downloadAndTranslate(from: source)
                } label: {
                    Label("Scarica \(Preferences.languageName(source.minimalIdentifier)) per tradurre",
                          systemImage: "arrow.down.circle.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.black.opacity(0.45), in: .capsule)
                }
                .buttonStyle(.plain)
            } else if translateEnabled, let note = translationNote {
                Text(note)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.black.opacity(0.45), in: .capsule)
            }
        }
        .foregroundStyle(.white)
        .padding(.top, 4)
    }

    /// The system shows its download sheet for the language, then the lines are translated.
    private func downloadAndTranslate(from source: Locale.Language) {
        downloading = true
        let target = Locale.Language(identifier: targetIdentifier)
        if configuration?.source == source, configuration?.target == target {
            // Same languages as a download the user cancelled: ask again.
            configuration?.invalidate()
        } else {
            configuration = TranslationSession.Configuration(source: source, target: target)
        }
    }
}

/// Settings row that downloads the translation language ahead of time, so lyrics translate offline.
struct TranslationDownloadRow: View {
    let targetIdentifier: String
    @State private var status: LanguageAvailability.Status?
    @State private var configuration: TranslationSession.Configuration?

    /// Most lyrics are in English: the download pairs it with the chosen language
    /// (Italian when the chosen language is English).
    private var source: Locale.Language {
        Locale.Language(identifier: targetIdentifier.hasPrefix("en") ? "it" : "en")
    }

    var body: some View {
        HStack {
            Label("Lingua offline", systemImage: "arrow.down.circle")
            Spacer()
            switch status {
            case .installed?:
                Text("Scaricata").foregroundStyle(.secondary)
            case .supported?:
                Button("Scarica") {
                    configuration = TranslationSession.Configuration(
                        source: source, target: Locale.Language(identifier: targetIdentifier))
                }
            case .unsupported?:
                Text("Non disponibile").foregroundStyle(.secondary)
            default:
                ProgressView()
            }
        }
        .task(id: targetIdentifier) { await refresh() }
        .translationTask(configuration) { session in
            try? await session.prepareTranslation()
            await refresh()
        }
    }

    private func refresh() async {
        status = await LanguageAvailability().status(from: source, to: Locale.Language(identifier: targetIdentifier))
    }
}
