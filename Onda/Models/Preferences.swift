import Foundation
import Network

enum AudioQuality: String, CaseIterable, Identifiable, Sendable {
    case high, low

    var id: Self { self }

    var title: String {
        switch self {
        case .high: return "Alta · AAC 128 kbps"
        case .low: return "Risparmio dati · AAC 48 kbps"
        }
    }
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
    static let skipLongMixes = "radio.skipLongMixes"
    static let dynamicColors = "theme.dynamicColors"
    static let lyricsStyle = "lyrics.style"
    static let lyricsSize = "lyrics.size"
    static let recentSearches = "search.recent"

    /// Radios and quick picks skip "songs" longer than this (hour-long compilations).
    static let longMixThreshold: TimeInterval = 15 * 60

    static func quality(for key: String) -> AudioQuality {
        AudioQuality(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .high
    }

    /// The quality to stream at right now, depending on Wi-Fi or cellular.
    static var streamingQuality: AudioQuality {
        quality(for: NetworkMonitor.shared.isExpensive ? cellularQuality : wifiQuality)
    }

    static var spatialAudioEnabled: Bool { flag(spatialAudio, default: true) }
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
