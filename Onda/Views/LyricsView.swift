import NaturalLanguage
import SwiftUI
import Translation

struct LyricsView: View {
    @EnvironmentObject private var player: PlayerController

    var body: some View {
        Group {
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
            case .unavailable:
                ContentUnavailableView("Testo non disponibile", systemImage: "quote.bubble",
                                       description: Text("LRCLIB non ha il testo di questo brano."))
            }
        }
        // Fade lines in and out at the edges.
        .mask {
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.08),
                .init(color: .black, location: 0.92),
                .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
    }
}

/// Karaoke-style lyrics: the current line lights up and stays centred; tap a line to jump there.
/// With translation on, each line shows its translation underneath, made on the iPhone by Apple's
/// Translation framework with a language downloaded beforehand (Settings → Testi).
private struct SyncedLyrics: View {
    let lines: [LyricLine]
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var progress: PlaybackProgress
    @AppStorage(Preferences.lyricsStyle) private var style: LyricsStyle = .focus
    @AppStorage(Preferences.lyricsSize) private var size: LyricsSize = .medium
    @AppStorage(Preferences.lyricsTranslate) private var translateEnabled = false
    @AppStorage(Preferences.lyricsTranslationTarget) private var targetIdentifier = Preferences.defaultTranslationTarget

    /// Translated text by line id.
    @State private var translations: [Int: String] = [:]
    @State private var configuration: TranslationSession.Configuration?
    /// A source language that can be translated once its model is downloaded.
    @State private var downloadableSource: Locale.Language?

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
        .overlay(alignment: .topTrailing) { translationControls }
        .task(id: translationKey) { await prepareTranslation() }
        .translationTask(configuration) { session in
            await translate(with: session)
        }
    }

    // MARK: Translation

    private var translationControls: some View {
        HStack(spacing: 8) {
            if translateEnabled, let source = downloadableSource {
                Button {
                    // The system asks to download the language, then translates.
                    configuration = TranslationSession.Configuration(
                        source: source, target: Locale.Language(identifier: targetIdentifier))
                } label: {
                    Label("Scarica \(Preferences.languageName(source.minimalIdentifier))", systemImage: "arrow.down.circle")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .glassEffect(.regular, in: .capsule)
                }
                .buttonStyle(.plain)
            }
            Button {
                translateEnabled.toggle()
            } label: {
                Image(systemName: "translate")
                    .font(.footnote.weight(.semibold))
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(translateEnabled ? 0.25 : 0.08), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(translateEnabled ? "Nascondi traduzione" : "Mostra traduzione")
        }
        .foregroundStyle(.white)
        .padding(.top, 4)
    }

    /// Decides whether to translate: only when the language model is already on the iPhone,
    /// so nothing is downloaded while a song loads.
    private func prepareTranslation() async {
        translations = [:]
        configuration = nil
        downloadableSource = nil
        guard translateEnabled, let source = Self.detectLanguage(of: lines) else { return }
        let target = Locale.Language(identifier: targetIdentifier)
        guard source.languageCode != target.languageCode else { return }
        let status = await LanguageAvailability().status(from: source, to: target)
        guard !Task.isCancelled else { return }
        switch status {
        case .installed:
            configuration = TranslationSession.Configuration(source: source, target: target)
        case .supported:
            downloadableSource = source
        default:
            break
        }
    }

    private func translate(with session: TranslationSession) async {
        let requests = lines
            .filter { !$0.text.isEmpty }
            .map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: String($0.id)) }
        guard !requests.isEmpty, let responses = try? await session.translations(from: requests) else { return }
        var result: [Int: String] = [:]
        for response in responses {
            if let id = response.clientIdentifier.flatMap({ Int($0) }) {
                result[id] = response.targetText
            }
        }
        withAnimation(.easeOut(duration: 0.3)) {
            translations = result
            downloadableSource = nil
        }
    }

    private static func detectLanguage(of lines: [LyricLine]) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(lines.map(\.text).joined(separator: "\n"))
        guard let language = recognizer.dominantLanguage else { return nil }
        return Locale.Language(identifier: language.rawValue)
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
