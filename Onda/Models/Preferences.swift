import Foundation
import Network
import SwiftUI

/// The app's tint colour, picked in Settings.
enum AccentChoice: String, CaseIterable, Identifiable {
    case pink, red, orange, yellow, lightGreen, darkGreen, mint, lightBlue, blue, indigo, purple

    var id: Self { self }

    var title: String {
        switch self {
        case .pink: return String(localized: "Rosa")
        case .red: return String(localized: "Rosso")
        case .orange: return String(localized: "Arancione")
        case .yellow: return String(localized: "Giallo")
        case .lightGreen: return String(localized: "Verde chiaro")
        case .darkGreen: return String(localized: "Verde scuro")
        case .mint: return String(localized: "Menta")
        case .lightBlue: return String(localized: "Azzurro")
        case .blue: return String(localized: "Blu")
        case .indigo: return String(localized: "Indaco")
        case .purple: return String(localized: "Viola")
        }
    }

    var color: Color {
        switch self {
        case .pink: return Color(red: 1.0, green: 0.31, blue: 0.6)
        case .red: return Color(red: 0.96, green: 0.23, blue: 0.25)
        case .orange: return .orange
        case .yellow: return Color(red: 1.0, green: 0.8, blue: 0.1)
        case .lightGreen: return Color(red: 0.45, green: 0.86, blue: 0.36)
        case .darkGreen: return Color(red: 0.12, green: 0.55, blue: 0.28)
        case .mint: return .mint
        case .lightBlue: return Color(red: 0.35, green: 0.76, blue: 1.0)
        case .blue: return Color(red: 0.16, green: 0.42, blue: 1.0)
        case .indigo: return .indigo
        case .purple: return .purple
        }
    }
}

enum AudioQuality: String, CaseIterable, Identifiable, Sendable {
    /// Best available: Dolby or 256 kbps AAC when YouTube offers them, otherwise Opus ~160 kbps.
    case max
    /// AAC 128 kbps, played directly.
    case high
    /// Opus ~70 kbps.
    case medium
    /// HE-AAC 48 kbps.
    case low

    var id: Self { self }

    /// Downloads skip the medium level: a lossless copy of a 70 kbps stream makes no sense.
    static let downloadCases: [AudioQuality] = [.max, .high, .low]

    var title: String {
        switch self {
        case .max: return String(localized: "Massima · Opus 160 kbps")
        case .high: return String(localized: "Alta · AAC 128 kbps")
        case .medium: return String(localized: "Media · Opus 70 kbps")
        case .low: return String(localized: "Risparmio · AAC 48 kbps")
        }
    }

    var downloadTitle: String {
        switch self {
        case .max: return String(localized: "Massima · lossless da Opus (~5 MB/min)")
        case .high: return String(localized: "Alta · AAC 128 kbps (~1 MB/min)")
        case .medium, .low: return String(localized: "Risparmio · AAC 48 kbps (~0,4 MB/min)")
        }
    }

    /// Opus has to be decoded on the iPhone, because AVPlayer can't play WebM.
    var usesOpus: Bool { self == .max || self == .medium }
}

/// What happens between songs (Impostazioni → Riproduzione → Transizioni tra brani).
enum SongTransition: String, CaseIterable, Identifiable {
    /// Like Apple Music's AutoMix: matched beats or a crossfade suited to the two songs.
    case autoMix
    /// The same overlap every time, of `Preferences.crossfadeSeconds`.
    case crossfade
    case off

    var id: Self { self }

    var title: String {
        switch self {
        case .autoMix: return String(localized: "AutoMix")
        case .crossfade: return String(localized: "Dissolvenza incrociata")
        case .off: return String(localized: "Nessuna")
        }
    }
}

enum LyricsStyle: String, CaseIterable, Identifiable {
    case focus, fade, glow

    var id: Self { self }

    var title: String {
        switch self {
        case .focus: return String(localized: "Messa a fuoco")
        case .fade: return String(localized: "Dissolvenza")
        case .glow: return String(localized: "Bagliore")
        }
    }
}

enum LyricsSize: String, CaseIterable, Identifiable {
    case small, medium, large

    var id: Self { self }

    var title: String {
        switch self {
        case .small: return String(localized: "Piccolo")
        case .medium: return String(localized: "Medio")
        case .large: return String(localized: "Grande")
        }
    }

    var points: CGFloat {
        switch self {
        case .small: return 24
        case .medium: return 30
        case .large: return 36
        }
    }
}

/// UserDefaults keys shared by `@AppStorage` in the views and by the services.
enum Preferences {
    static let wifiQuality = "audio.quality.wifi"
    static let cellularQuality = "audio.quality.cellular"
    static let downloadQuality = "audio.quality.download"
    static let spatialAudio = "audio.spatial"
    static let equalizerOn = "audio.equalizer.on"
    static let equalizerPreset = "audio.equalizer.preset"
    static let equalizerCustom = "audio.equalizer.custom"
    static let preferDolby = "audio.preferDolby"
    static let downloadFormats = "download.formats"
    static let skipLongMixes = "radio.skipLongMixes"
    static let crossfade = "playback.crossfade"
    static let songTransition = "playback.transition"
    static let opusLastError = "audio.opusLastError"
    static let opusFromStart = "audio.opusFromStart"
    /// The last time Opus couldn't play from the start and AAC played instead, and why.
    static let lastOpusFallback = "diagnostics.lastOpusFallback"
    static let accent = "theme.accent"
    /// -1 unknown, 0 refused by iOS, 1 accepted.
    static let nowPlayingAccepted = "diagnostics.nowPlayingAccepted"
    static let nowPlayingBackend = "diagnostics.nowPlayingBackend"
    /// The last change of audio output (headphones in or out) and what the player did.
    static let lastRouteChange = "diagnostics.lastRouteChange"
    /// The last AutoMix handover and how it went.
    static let lastHandover = "diagnostics.lastHandover"
    /// The last transition AutoMix chose, and why (see `TransitionChoice.summary`).
    static let lastAutoMixChoice = "diagnostics.lastAutoMixChoice"
    static let interactiveArtwork = "player.interactiveArtwork"
    static let lyricsTranslate = "lyrics.translate"
    static let updateMode = "updates.mode"

    static var updateModeSetting: UpdateMode {
        UserDefaults.standard.string(forKey: updateMode).flatMap(UpdateMode.init(rawValue:)) ?? .notify
    }
    static let lyricsTranslationTarget = "lyrics.translationTarget"

    /// The phone's language, used as the default translation target.
    static var defaultTranslationTarget: String {
        Locale.current.language.languageCode?.identifier ?? "it"
    }

    /// Languages Apple's on-device translation offers, as BCP-47 identifiers.
    static let translationLanguages = [
        "it", "en", "es", "fr", "de", "pt-BR", "nl", "pl", "ru", "uk", "tr",
        "ar", "hi", "id", "th", "vi", "ja", "ko", "zh-Hans", "zh-Hant",
    ]

    static func languageName(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier)?.capitalized ?? identifier
    }
    static let dynamicColors = "theme.dynamicColors"
    static let lyricsStyle = "lyrics.style"
    static let lyricsSize = "lyrics.size"
    static let recentSearches = "search.recent"

    /// Radios and quick picks skip "songs" longer than this (hour-long compilations).
    static let longMixThreshold: TimeInterval = 15 * 60

    /// Songs longer than this always stream as AAC: decoding an hour of Opus would take too long.
    static let opusLengthLimit: TimeInterval = 20 * 60

    /// Defaults used both here and by `@AppStorage` in the settings screen.
    // Native AAC avoids decoding and re-encoding every streamed song on the phone.
    // Explicit Maximum quality selections remain available and are preserved.
    static let defaultWifiQuality = AudioQuality.high
    static let defaultCellularQuality = AudioQuality.high
    static let defaultDownloadQuality = AudioQuality.max

    static func quality(for key: String) -> AudioQuality {
        if let stored = UserDefaults.standard.string(forKey: key), let quality = AudioQuality(rawValue: stored) {
            return quality
        }
        switch key {
        case wifiQuality: return defaultWifiQuality
        case cellularQuality: return defaultCellularQuality
        default: return defaultDownloadQuality
        }
    }

    /// The quality to stream at right now, depending on Wi-Fi or cellular.
    static var streamingQuality: AudioQuality {
        quality(for: NetworkMonitor.shared.isExpensive ? cellularQuality : wifiQuality)
    }

    /// What a song starts streaming with: at the Opus qualities, Opus itself from its first
    /// seconds (`playsOpusFromStart`, see `OpusStream`); otherwise AAC, playable right away,
    /// until its local copy takes over.
    static var initialStreamQuality: AudioQuality {
        let quality = streamingQuality
        if quality.usesOpus, playsOpusFromStart { return quality }
        return quality == .low || quality == .medium ? .low : .high
    }

    static var downloadQualitySetting: AudioQuality {
        let quality = quality(for: downloadQuality)
        return quality == .medium ? .low : quality
    }

    static let defaultCrossfade: Double = 6

    /// Seconds of overlap between songs with "Dissolvenza incrociata".
    static var crossfadeSeconds: Double {
        UserDefaults.standard.object(forKey: crossfade) as? Double ?? defaultCrossfade
    }

    /// AutoMix unless chosen otherwise; up to 1.11 a crossfade of 0 seconds meant no transitions.
    static var songTransitionSetting: SongTransition {
        if let stored = UserDefaults.standard.string(forKey: songTransition),
           let transition = SongTransition(rawValue: stored) {
            return transition
        }
        return (UserDefaults.standard.object(forKey: crossfade) as? Double) == 0 ? .off : .autoMix
    }

    static let normalizeVolume = "audio.normalizeVolume"
    static var normalizesVolume: Bool { flag(normalizeVolume, default: true) }
    static var spatialAudioEnabled: Bool { flag(spatialAudio, default: true) }
    static var prefersDolby: Bool { flag(preferDolby, default: true) }
    static var skipsLongMixes: Bool { flag(skipLongMixes, default: true) }
    static var dynamicColorsEnabled: Bool { flag(dynamicColors, default: true) }
    /// "Opus dal primo suono": Opus plays while it downloads, instead of AAC until the decoded
    /// file is ready (for the next seek or listen).
    static var playsOpusFromStart: Bool { flag(opusFromStart, default: true) }

    private static func flag(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }
}

/// Tells whether the current connection is cellular (or otherwise metered).
final class NetworkMonitor: @unchecked Sendable {
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var expensive = false

    var isExpensive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return expensive
    }

    private init() {
        monitor.pathUpdateHandler = { [unowned self] path in
            self.update(path.isExpensive || path.usesInterfaceType(.cellular))
        }
        monitor.start(queue: DispatchQueue(label: "onda.network-monitor"))
    }

    private func update(_ metered: Bool) {
        lock.lock()
        expensive = metered
        lock.unlock()
    }
}
