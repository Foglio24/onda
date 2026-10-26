import SwiftUI

/// Opens a given screen at launch, for the screenshots CI takes on a simulator
/// (Tools/Screenshots/run.sh): `-OndaScene home | library | settings | search:<query> |
/// artist:<browseId> | album:<browseId> | player:<videoId> | downloads:<videoId> | storage`.
/// `downloads` downloads the first songs of a song's radio and shows them downloading;
/// `storage` shows the space they take.
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
        case "settings":
            select(.settings)
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
                router.showPlayer = true
            }
        default:
            select(.home)
        }
    }
}
