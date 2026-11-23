import SwiftUI
import UIKit
import WidgetKit

/// Keeps the widgets (see `SharedStore`, Widgets/SeaglassWidgets.swift) on the song playing: called
/// by the player whenever its system Now Playing changes, it writes only when what the widgets show
/// changes (the song, playing or paused, the cover, the theme's colour) and then asks them to reload,
/// never for the position's ticks.
@MainActor
final class WidgetFeed {
    static let shared = WidgetFeed()

    private var last: WidgetSnapshot?
    private var lastArtworkID: String?
    private var pendingArtwork: (id: String, image: UIImage)?
    /// Whether there is a shared folder at all (none: the signer made no App Group), found once. Never
    /// on a Mac, which has no widgets (see project.yml): its unsandboxed app would only make a group
    /// folder no one reads, and macOS may ask about it.
    private lazy var available = !ProcessInfo.processInfo.isMacCatalystApp && SharedStore.folder != nil

    private init() {}

    /// The cover of the song `id`, once loaded (it often comes after the song itself).
    func artwork(_ image: UIImage, for id: String) {
        pendingArtwork = (id, image)
    }

    func update(track: Track?, isPlaying: Bool) {
        guard available else { return }
        var snapshot = WidgetSnapshot(title: track?.title ?? "", artist: track?.artist ?? "", isPlaying: isPlaying,
                                      artworkFile: last?.artworkFile, tint: Self.tint, updated: .now)
        // A new song without its cover yet shows none rather than the previous song's.
        if track?.id != lastArtworkID { snapshot.artworkFile = nil }
        var artwork: Data?
        if let track, let pending = pendingArtwork, pending.id == track.id, lastArtworkID != track.id || last?.artworkFile == nil {
            artwork = Self.thumbnail(pending.image)
            lastArtworkID = track.id
        }
        if artwork == nil, let last, Self.same(last, snapshot) { return }
        if SharedStore.write(snapshot, artwork: artwork) {
            last = SharedStore.read() ?? snapshot
            if track == nil { lastArtworkID = nil }
            WidgetCenter.shared.reloadTimelines(ofKind: SeaglassWidgetKind.nowPlaying)
        }
    }

    /// The same as far as the widgets go (not counting when it was written).
    private static func same(_ a: WidgetSnapshot, _ b: WidgetSnapshot) -> Bool {
        a.title == b.title && a.artist == b.artist && a.isPlaying == b.isPlaying && a.artworkFile == b.artworkFile
            && a.tint == b.tint
    }

    private static var tint: [Double] {
        let raw = UserDefaults.standard.string(forKey: Preferences.accent) ?? AccentChoice.pink.rawValue
        let color = UIColor((AccentChoice(rawValue: raw) ?? .pink).color)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return [0.93, 0.25, 0.55] }
        return [Double(red), Double(green), Double(blue)].map { min(1, max(0, $0)) }
    }

    /// A square 300-pixel JPEG: what a widget can afford to decode.
    private static func thumbnail(_ image: UIImage) -> Data? {
        let side: CGFloat = 300
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let scaled = renderer.image { _ in
            let size = image.size
            guard size.width > 0, size.height > 0 else { return }
            let scale = max(side / size.width, side / size.height)
            let drawn = CGSize(width: size.width * scale, height: size.height * scale)
            image.draw(in: CGRect(x: (side - drawn.width) / 2, y: (side - drawn.height) / 2,
                                  width: drawn.width, height: drawn.height))
        }
        return scaled.jpegData(compressionQuality: 0.8)
    }
}
