import CryptoKit
import Foundation
import NaturalLanguage
import Translation

/// Translates synced lyrics with Apple's on-device Translation as soon as they load (and the next
/// song's ahead of time), so the translation is already there when the lyrics panel opens.
/// Translations are kept on disk per song and language. Only languages already on the iPhone are
/// used here: the lyrics panel asks before downloading one.
@MainActor
final class LyricsTranslator: ObservableObject {
    static let shared = LyricsTranslator()

    enum Phase: Equatable {
        case off
        case translating
        case done
        /// The lyrics' language can be translated once downloaded (the lyrics panel offers it).
        case needsDownload(Locale.Language)
        case note(String)
    }

    /// The lyrics that `translations` and `phase` are about.
    @Published private(set) var lines: [LyricLine] = []
    /// Translated text by line id, filled in as the lines arrive.
    @Published private(set) var translations: [Int: String] = [:]
    @Published private(set) var phase: Phase = .off

    /// Identifies `lines` and the target language; nil while translation is off.
    private var shownKey: String?
    private var task: Task<Void, Never>?
    private var prefetchKey: String?
    private var prefetchTask: Task<Void, Never>?
    /// Recent complete translations: original line → translated line, by lyrics and language.
    private var memory: [String: [String: String]] = [:]
    /// Kept between songs, so the language model stays loaded.
    private var sessions: [String: TranslationSession] = [:]

    private static let directory: URL = {
        let url = URL.cachesDirectory.appending(path: "LyricTranslations", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static var isEnabled: Bool { UserDefaults.standard.bool(forKey: Preferences.lyricsTranslate) }

    private static var target: Locale.Language {
        Locale.Language(identifier: UserDefaults.standard.string(forKey: Preferences.lyricsTranslationTarget)
                        ?? Preferences.defaultTranslationTarget)
    }

    /// Shows the translation of these lyrics (nothing for empty lyrics or with translation off):
    /// from the cache, or translated now when the language is on the iPhone.
    func show(_ newLines: [LyricLine]) {
        let target = Self.target
        let newKey = Self.isEnabled && !newLines.isEmpty ? Self.key(for: newLines, target: target) : nil
        guard newKey != shownKey || newLines != lines else { return }
        task?.cancel()
        lines = newLines
        translations = [:]
        shownKey = newKey
        guard let key = newKey else {
            phase = .off
            return
        }
        if let cached = cached(key) {
            translations = Self.byLine(cached, lines: newLines)
            phase = .done
            return
        }
        phase = .translating
        // The next song's lyrics may be translating already: wait for that instead of starting over.
        let pending = prefetchKey == key ? prefetchTask : nil
        task = Task {
            await pending?.value
            guard !Task.isCancelled, self.shownKey == key else { return }
            if let cached = self.cached(key) {
                self.translations = Self.byLine(cached, lines: newLines)
                self.phase = .done
                return
            }
            await self.run(newLines, key: key, target: target, shown: true)
        }
    }

    /// Translates the next song's lyrics in the background, so they show at once when it starts.
    func prefetch(_ newLines: [LyricLine]) {
        guard Self.isEnabled, !newLines.isEmpty else { return }
        let target = Self.target
        let key = Self.key(for: newLines, target: target)
        guard key != shownKey, key != prefetchKey, cached(key) == nil else { return }
        prefetchTask?.cancel()
        prefetchKey = key
        prefetchTask = Task {
            await self.run(newLines, key: key, target: target, shown: false)
            if self.prefetchKey == key { self.prefetchKey = nil }
        }
    }

    /// After the user downloaded the language from the lyrics panel: translates with that session.
    func translate(_ newLines: [LyricLine], with session: TranslationSession) async {
        guard let key = shownKey, newLines == lines else { return }
        phase = .translating
        do {
            try await translate(newLines, key: key, session: session, shown: true)
        } catch {
            report(.note(String(localized: "Traduzione non riuscita: \(error.localizedDescription)")), key: key)
        }
    }

    // MARK: Translating

    private func run(_ lines: [LyricLine], key: String, target: Locale.Language, shown: Bool) async {
        guard let source = Self.detectLanguage(of: lines) else {
            if shown { report(.note(String(localized: "Lingua del testo non riconosciuta")), key: key) }
            return
        }
        guard source.languageCode != target.languageCode else {
            if shown {
                report(.note(String(localized: "Il testo è già in \(Self.inlineName(of: target))")), key: key)
            }
            return
        }
        let status = await LanguageAvailability().status(from: source, to: target)
        guard !Task.isCancelled else { return }
        switch status {
        case .installed:
            await translateInstalled(lines, key: key, source: source, target: target, shown: shown)
        case .supported:
            if shown { report(.needsDownload(source), key: key) }
        default:
            if shown {
                report(.note(String(localized: "Traduzione da \(Self.inlineName(of: source)) non disponibile")), key: key)
            }
        }
    }

    /// Uses a session of its own (no system sheet), kept for the next songs; on an error it
    /// tries once more with a fresh one.
    private func translateInstalled(_ lines: [LyricLine], key: String, source: Locale.Language,
                                    target: Locale.Language, shown: Bool) async {
        let pair = "\(source.minimalIdentifier)>\(target.minimalIdentifier)"
        for attempt in 0..<2 {
            let session: TranslationSession
            if shown, attempt == 0, let kept = sessions[pair] {
                session = kept
            } else if let created = try? TranslationSession(installedSource: source, target: target) {
                session = created
                // The background one is not shared: two translations at once on one session may clash.
                if shown { sessions[pair] = created }
            } else {
                if shown { report(.note(String(localized: "Traduzione non disponibile")), key: key) }
                return
            }
            do {
                try await translate(lines, key: key, session: session, shown: shown)
                return
            } catch {
                if shown { sessions[pair] = nil }
                if attempt == 1 || Task.isCancelled {
                    if shown {
                        report(.note(String(localized: "Traduzione non riuscita: \(error.localizedDescription)")), key: key)
                    }
                    return
                }
            }
        }
    }

    /// Translates each distinct line once (choruses repeat), publishing them as they arrive.
    private func translate(_ lines: [LyricLine], key: String, session: TranslationSession, shown: Bool) async throws {
        var translated: [String: String] = [:]
        var seen = Set<String>()
        let texts = lines.map(\.text).filter { !$0.isEmpty && seen.insert($0).inserted }
        let requests = texts.enumerated().map {
            TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
        }
        if !requests.isEmpty {
            for try await response in session.translate(batch: requests) {
                translated[response.sourceText] = response.targetText
                if shown, shownKey == key { translations = Self.byLine(translated, lines: lines) }
            }
        }
        guard !Task.isCancelled else { return }
        store(translated, key: key)
        if shown, shownKey == key {
            translations = Self.byLine(translated, lines: lines)
            phase = translated.isEmpty ? .note(String(localized: "Nessuna traduzione ricevuta")) : .done
        }
    }

    /// A language's name as written inside a sentence ("inglese" in Italian, "English" in English).
    private static func inlineName(of language: Locale.Language) -> String {
        Locale.current.localizedString(forIdentifier: language.minimalIdentifier) ?? language.minimalIdentifier
    }

    private func report(_ newPhase: Phase, key: String) {
        guard shownKey == key else { return }
        phase = newPhase
    }

    // MARK: Cache

    private func cached(_ key: String) -> [String: String]? {
        if let kept = memory[key] { return kept }
        guard let data = try? Data(contentsOf: Self.file(for: key)),
              let stored = try? JSONDecoder().decode([String: String].self, from: data) else { return nil }
        memory[key] = stored
        return stored
    }

    private func store(_ translated: [String: String], key: String) {
        guard !translated.isEmpty else { return }
        if memory.count >= 30 { memory.removeAll() }
        memory[key] = translated
        if let data = try? JSONEncoder().encode(translated) {
            try? data.write(to: Self.file(for: key), options: .atomic)
        }
    }

    private static func file(for key: String) -> URL {
        directory.appending(path: "\(key).json")
    }

    private static func key(for lines: [LyricLine], target: Locale.Language) -> String {
        let text = lines.map(\.text).joined(separator: "\n") + "\n→" + target.minimalIdentifier
        return SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func byLine(_ translated: [String: String], lines: [LyricLine]) -> [Int: String] {
        var result: [Int: String] = [:]
        for line in lines {
            if let text = translated[line.text] { result[line.id] = text }
        }
        return result
    }

    private static func detectLanguage(of lines: [LyricLine]) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(lines.map(\.text).joined(separator: "\n"))
        guard let language = recognizer.dominantLanguage else { return nil }
        return Locale.Language(identifier: language.rawValue)
    }
}
