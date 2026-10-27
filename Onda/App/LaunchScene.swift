import SwiftUI

/// Opens a given screen at launch, for the screenshots CI takes on a simulator
/// (Tools/Screenshots/run.sh): `-OndaScene home | library | settings | search:<query> |
/// artist:<browseId> | album:<browseId> | player:<videoId> | downloads:<videoId> | storage |
/// equalizer | info:<album browseId>`.
/// `downloads` downloads the first songs of a song's radio and shows them downloading;
/// `storage` shows the space they take; `info` plays an album and opens its first song's details.
/// Launch arguments are never passed in normal use, so this does nothing then.
@MainActor
enum LaunchScene {
    private static var scene: String? { UserDefaults.standard.string(forKey: "OndaScene") }

    /// Library → Download is opened at launch.
    static var opensDownloads: Bool {
        scene?.hasPrefix("downloads") == true || opensStorage
    }

    /// Library → Download → Spazio occupato is opened at launch.
    static var opensStorage: Bool { scene == "storage" }

    /// Settings → Equalizzatore is opened at launch.
    static var opensEqualizer: Bool { scene == "equalizer" }

    /// `-OndaCardProgress 0.55`: the player card stops part of the way, to see it over the app.
    static var playerCardProgress: CGFloat? {
        guard scene != nil, let value = UserDefaults.standard.object(forKey: "OndaCardProgress") as? Double
                ?? UserDefaults.standard.string(forKey: "OndaCardProgress").flatMap({ Double($0) }) else { return nil }
        return CGFloat(max(0, min(1, value)))
    }

    static func apply(select: (AppTab) -> Void) {
        guard let scene = Self.scene else { return }
        let parts = scene.split(separator: ":", maxSplits: 1).map(String.init)
        let value = parts.count > 1 ? parts[1] : ""
        let router = AppRouter.shared
        switch parts.first ?? "" {
        case "library", "storage":
            select(.library)
        case "downloads":
            select(.library)
            Task {
                guard let tracks = try? await InnerTube.shared.radio(for: value), !tracks.isEmpty else { return }
                DownloadManager.shared.downloadAll(Array(tracks.prefix(6)))
            }
        case "settings", "equalizer":
            select(.settings)
        case "info":
            Task {
                guard let album = try? await InnerTube.shared.album(value), let first = album.tracks.first else { return }
                PlayerController.shared.play(album.tracks, source: album.title)
                router.openPlayer()
                try? await Task.sleep(for: .seconds(1.5))
                router.page = .song(first)
            }
        case "search":
            select(.search)
            router.pendingSearch = value
        case "artist":
            router.page = .artist(id: value, name: "")
        case "album":
            router.page = .album(id: value)
        case "player":
            Task {
                guard let tracks = try? await InnerTube.shared.radio(for: value), !tracks.isEmpty else { return }
                PlayerController.shared.play(tracks, source: "Radio")
                router.openPlayer()
            }
        default:
            select(.home)
        }
    }
}
