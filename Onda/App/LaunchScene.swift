import SwiftUI

/// Opens a given screen at launch, for the screenshots CI takes on a simulator
/// (Tools/Screenshots/run.sh): `-OndaScene home | library | settings | search:<query> |
/// artist:<browseId> | album:<browseId> | player:<videoId>`.
/// Launch arguments are never passed in normal use, so this does nothing then.
@MainActor
enum LaunchScene {
    static func apply(select: (AppTab) -> Void) {
        guard let scene = UserDefaults.standard.string(forKey: "OndaScene") else { return }
        let parts = scene.split(separator: ":", maxSplits: 1).map(String.init)
        let value = parts.count > 1 ? parts[1] : ""
        let router = AppRouter.shared
        switch parts.first ?? "" {
        case "library":
            select(.library)
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
