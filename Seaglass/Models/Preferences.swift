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
        // The classic style is in green, whatever the theme's colour (read here, so every view that tints
        // with the theme's colour follows it).
        if UserDefaults.standard.string(forKey: Preferences.interfaceStyle) == InterfaceStyle.classic.rawValue {
            return ClassicPalette.accent
        }
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

    /// Downloads skip the medium level: a decoded copy of a 70 kbps stream makes no sense.
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
        // Opus decoded once and kept as it came out of the decoder (in ALAC, which AVPlayer plays):
        // the quality is YouTube's Opus, nothing more and nothing less.
        case .max: return String(localized: "Massima · Opus 160 kbps (~5 MB/min)")
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
    /// The volume bar under the player's controls (iPhone and iPad; a Mac always has its own).
    static let playerVolumeBar = "player.volumeBar"
    static let equalizerOn = "audio.equalizer.on"
    static let equalizerPreset = "audio.equalizer.preset"
    static let equalizerCustom = "audio.equalizer.custom"
    static let preferDolby = "audio.preferDolby"
    static let downloadFormats = "download.formats"
    /// AutoMix's live transitions (two players in step, see `SegueSession`); off, the rendered mixes.
    static let liveMix = "automix.liveMix"
    /// The player's progress bar shows where the transition into the next song will happen.
    static let transitionMark = "player.transitionMark"
    static var showsTransitionMark: Bool { UserDefaults.standard.object(forKey: transitionMark) as? Bool ?? true }
    static var liveMixEnabled: Bool { UserDefaults.standard.object(forKey: liveMix) as? Bool ?? true }
    /// How long AutoMix's live mixes may be (`SegueLength`: 0 short, 1 normal, 2 long).
    static let mixLengthKey = "automix.length"
    static var mixLength: SegueLength {
        SegueLength(rawValue: UserDefaults.standard.object(forKey: mixLengthKey) as? Int ?? 1) ?? .normal
    }
    /// AutoMix's automatic equaliser (bass, bands, filters and echo in the live mix); off, only levels.
    static let autoMixEqualiserKey = "automix.equaliser"
    static var autoMixEqualiser: Bool { UserDefaults.standard.object(forKey: autoMixEqualiserKey) as? Bool ?? true }
    static let skipLongMixes = "radio.skipLongMixes"
    static let crossfade = "playback.crossfade"
    static let songTransition = "playback.transition"
    static let opusLastError = "audio.opusLastError"
    static let opusFromStart = "audio.opusFromStart"
    /// The last time Opus couldn't play from the start and AAC played instead, and why.
    static let lastOpusFallback = "diagnostics.lastOpusFallback"
    static let accent = "theme.accent"
    /// The interface style (see `InterfaceStyle`): "seaglass" or "classic".
    static let interfaceStyle = "theme.style"
    /// Light, dark, or as the device (see `AppearanceMode`).
    static let appearanceMode = "theme.mode"
    /// The Mac's zoom in percent (see `MacZoom`).
    static let macZoom = "mac.zoom"
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
    /// The speed podcast episodes play at (1 = normal).
    static let episodeSpeed = "podcasts.speed"
    /// The songs' tempo, -0.15…+0.15 (see `PlaybackTempo`), and whether the voice keeps its pitch.
    static let songTempo = "playback.tempo"
    /// How far the tempo fader goes either way: 0.08, 0.15 (the default), 0.25 or 0.5.
    static let tempoRange = "playback.tempoRange"
    static let keyLock = "playback.keyLock"
    static let lyricsTranslate = "lyrics.translate"
    /// The line being sung (and the next) under the player's cover, besides the preview under the page.
    static let lyricsInPlayer = "lyrics.inPlayer"
    static let updateMode = "updates.mode"

    static var updateModeSetting: UpdateMode {
        UserDefaults.standard.string(forKey: updateMode).flatMap(UpdateMode.init(rawValue:)) ?? .standard
    }
    static let lyricsTranslationTarget = "lyrics.translationTarget"

    /// The phone's language, used as the default translation target (as `translationLanguages`
    /// names it: Portuguese is Brazil's, Chinese simplified or traditional).
    static var defaultTranslationTarget: String {
        let language = Locale.current.language
        switch language.languageCode?.identifier {
        case "pt": return "pt-BR"
        case "zh": return language.script?.identifier == "Hant" ? "zh-Hant" : "zh-Hans"
        case let code?: return code
        case nil: return "it"
        }
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
    /// Searches typed and sent, one per line (what versions before 1.32 kept; still written for them).
    static let recentSearches = "search.recent"
    /// The search's history with what was picked from the results (songs, artists, albums...: with
    /// their covers), as JSON (`RecentSearch`); read from `recentSearches` while it isn't there.
    static let recentSearchItems = "search.recentItems"

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
    /// The transitions as chosen in Settings (see `PlayerController.transitionSetting` for the ones
    /// that play: AutoMix needs Premium where Premium can be bought).
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
        monitor.start(queue: DispatchQueue(label: "seaglass.network-monitor"))
    }

    private func update(_ metered: Bool) {
        lock.lock()
        expensive = metered
        lock.unlock()
    }
}

/// The Mac's zoom, as Spotify's (Settings › Appearance, and ⌘+, ⌘− and ⌘0 in the View menu): the
/// app's text, and the buttons and rows that follow it, bigger or smaller.
enum MacZoom {
    static let levels = [75, 85, 100, 115, 130, 150]

    /// The zoom in percent (also as a launch argument, which comes as text).
    static var current: Int {
        let value = UserDefaults.standard.integer(forKey: Preferences.macZoom)
        return value == 0 ? 100 : min(200, max(50, value))
    }

    /// One level up or down, or back to 100 % with zero.
    static func step(_ direction: Int) {
        let index = levels.firstIndex(of: current) ?? levels.firstIndex(of: 100) ?? 0
        let next = direction == 0 ? 100 : levels[min(levels.count - 1, max(0, index + direction))]
        UserDefaults.standard.set(next, forKey: Preferences.macZoom)
    }
}

/// Applies the Mac's zoom to its windows (the AppKit plug-in scales them whole: Dynamic Type, the
/// text size, does nothing in an iPad app on a Mac); on iPhone and iPad the system's text size
/// applies instead. Given to the root and to sheets; the plug-in acts only when the zoom changes.
struct MacZoomModifier: ViewModifier {
    @AppStorage(Preferences.macZoom) private var zoom = 100

    func body(content: Content) -> some View {
        content.onChange(of: zoom, initial: true) {
            guard ProcessInfo.processInfo.isMacCatalystApp else { return }
            let report = MacBridge.shared.setZoom(percent: MacZoom.current)
            if LaunchScene.isActive, let report, !report.isEmpty { print("zoom: \(report)") }
        }
    }
}

// MARK: AutoMix's settings (see AutoMixSettings.swift)

extension Preferences {
    static let autoMixStyleKey = "automix.style"
    static var autoMixStyle: AutoMixStyle {
        UserDefaults.standard.string(forKey: autoMixStyleKey).flatMap(AutoMixStyle.init(rawValue:)) ?? .automatic
    }
    static let autoMixTempoBendKey = "automix.tempoBend"
    static var autoMixTempoBend: AutoMixTempoBend {
        UserDefaults.standard.string(forKey: autoMixTempoBendKey).flatMap(AutoMixTempoBend.init(rawValue:)) ?? .normal
    }
    /// Keys taken into account (a clash costs a pair its score).
    static let autoMixHarmonicKey = "automix.harmonic"
    static var autoMixHarmonic: Bool { UserDefaults.standard.object(forKey: autoMixHarmonicKey) as? Bool ?? true }
    /// An album's songs played in order stay as the album has them, not mixed.
    static let autoMixKeepAlbumKey = "automix.keepAlbum"
    static var autoMixKeepAlbum: Bool { UserDefaults.standard.object(forKey: autoMixKeepAlbumKey) as? Bool ?? true }
    static let skipMixKey = "automix.skip"
    static var skipMix: SkipMix {
        UserDefaults.standard.string(forKey: skipMixKey).flatMap(SkipMix.init(rawValue:)) ?? .cut
    }

    // Mix Lab.
    static let mixLabBassKey = "automix.lab.bass"
    static var mixLabBass: Bool { UserDefaults.standard.object(forKey: mixLabBassKey) as? Bool ?? true }
    static let mixLabVocalsKey = "automix.lab.vocals"
    static var mixLabVocals: Bool { UserDefaults.standard.object(forKey: mixLabVocalsKey) as? Bool ?? false }
    static let mixLabEchoKey = "automix.lab.echo"
    static var mixLabEcho: Bool { UserDefaults.standard.object(forKey: mixLabEchoKey) as? Bool ?? true }
    static let mixLabBeatFadeKey = "automix.lab.beatFade"
    static var mixLabBeatFade: Bool { UserDefaults.standard.object(forKey: mixLabBeatFadeKey) as? Bool ?? false }
    static let mixLabEnergyKey = "automix.lab.energy"
    static var mixLabEnergy: Bool { UserDefaults.standard.object(forKey: mixLabEnergyKey) as? Bool ?? false }
}
