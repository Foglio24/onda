import Foundation
import Network

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
        case .max: return "Massima · Opus 160 kbps"
        case .high: return "Alta · AAC 128 kbps"
        case .medium: return "Media · Opus 70 kbps"
        case .low: return "Risparmio · AAC 48 kbps"
        }
    }

    var downloadTitle: String {
        switch self {
        case .max: return "Massima · lossless da Opus (~5 MB/min)"
        case .high: return "Alta · AAC 128 kbps (~1 MB/min)"
        case .medium, .low: return "Risparmio · AAC 48 kbps (~0,4 MB/min)"
        }
    }

    /// Opus has to be decoded on the iPhone, because AVPlayer can't play WebM.
    var usesOpus: Bool { self == .max || self == .medium }
}

enum LyricsStyle: String, CaseIterable, Identifiable {
    case focus, fade, glow

    var id: Self { self }

    var title: String {
        switch self {
        case .focus: return "Messa a fuoco"
        case .fade: return "Dissolvenza"
        case .glow: return "Bagliore"
        }
    }
}

enum LyricsSize: String, CaseIterable, Identifiable {
    case small, medium, large

    var id: Self { self }

    var title: String {
        switch self {
        case .small: return "Piccolo"
        case .medium: return "Medio"
        case .large: return "Grande"
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
    static let preferDolby = "audio.preferDolby"
    static let downloadFormats = "download.formats"
    static let skipLongMixes = "radio.skipLongMixes"
    static let crossfade = "playback.crossfade"
    static let opusLastError = "audio.opusLastError"
    static let dynamicColors = "theme.dynamicColors"
    static let lyricsStyle = "lyrics.style"
    static let lyricsSize = "lyrics.size"
    static let recentSearches = "search.recent"

    /// Radios and quick picks skip "songs" longer than this (hour-long compilations).
    static let longMixThreshold: TimeInterval = 15 * 60

    /// Songs longer than this always stream as AAC: decoding an hour of Opus would take too long.
    static let opusLengthLimit: TimeInterval = 20 * 60

    /// Defaults used both here and by `@AppStorage` in the settings screen.
    static let defaultWifiQuality = AudioQuality.max
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

    static var downloadQualitySetting: AudioQuality {
        let quality = quality(for: downloadQuality)
        return quality == .medium ? .low : quality
    }

    static let defaultCrossfade: Double = 6

    /// Seconds of overlap between songs; 0 turns the crossfade off.
    static var crossfadeSeconds: Double {
        UserDefaults.standard.object(forKey: crossfade) as? Double ?? defaultCrossfade
    }

    static var spatialAudioEnabled: Bool { flag(spatialAudio, default: true) }
    static var prefersDolby: Bool { flag(preferDolby, default: true) }
    static var skipsLongMixes: Bool { flag(skipLongMixes, default: true) }
    static var dynamicColorsEnabled: Bool { flag(dynamicColors, default: true) }

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
