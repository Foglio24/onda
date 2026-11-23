import AppIntents
import Foundation
import SwiftUI
import UIKit

// What the app and its widgets (the SeaglassWidgets extension) share: built into both.

enum SeaglassWidgetKind {
    static let nowPlaying = "SeaglassNowPlaying"
    static let recognizeControl = "SeaglassRecognizeControl"
    static let playbackControl = "SeaglassPlaybackControl"
}

/// The song playing, as the widgets show it: written by the app when it changes, read by the widgets.
struct WidgetSnapshot: Codable, Equatable {
    var title: String
    var artist: String
    var isPlaying: Bool
    /// The cover's file in the shared folder (nil: none yet), its name changing with the song.
    var artworkFile: String?
    /// The theme's colour (sRGB), so the widgets match the app.
    var tint: [Double]
    var updated: Date

    var tintColor: Color {
        tint.count == 3 ? Color(.sRGB, red: tint[0], green: tint[1], blue: tint[2]) : .pink
    }

    static let sample = WidgetSnapshot(title: "Neon Coast", artist: "Seaglass Demo", isPlaying: true, artworkFile: nil,
                                       tint: [0.93, 0.25, 0.55], updated: .now)
}

/// The folder the app and its widgets share (an App Group).
///
/// Seaglass is installed by sideloading, and the tools that sign it (AltStore, SideStore) rename the
/// group after the signer's team, then list the names they gave in the app's Info.plist under
/// `ALTAppGroups`: those come first, the name the app declares last. The widget extension reads the
/// app's own Info.plist too (its bundle is inside the app's). Without a group the signer could make,
/// there is no shared folder: the widgets then show "Niente in riproduzione", and their buttons still
/// work, since they run in the app (see `WidgetCommands`).
enum SharedStore {
    static let declaredGroup = "group.com.onda.player"

    static var groupIdentifiers: [String] {
        var bundles = [Bundle.main]
        // An extension's bundle is App.app/PlugIns/X.appex on an iPhone, App.app/Contents/PlugIns/X.appex
        // on a Mac: the app's is two levels up, or three.
        if Bundle.main.bundleURL.pathExtension == "appex" {
            var url = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            if url.lastPathComponent == "Contents" { url = url.deletingLastPathComponent() }
            if let app = Bundle(url: url) { bundles.append(app) }
        }
        var identifiers: [String] = []
        for bundle in bundles {
            for identifier in (bundle.object(forInfoDictionaryKey: "ALTAppGroups") as? [String]) ?? []
            where !identifiers.contains(identifier) {
                identifiers.append(identifier)
            }
        }
        if !identifiers.contains(declaredGroup) { identifiers.append(declaredGroup) }
        return identifiers
    }

    static var folder: URL? {
        for identifier in groupIdentifiers {
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) {
                return url.appending(path: "Widgets", directoryHint: .isDirectory)
            }
        }
        return nil
    }

    private static var snapshotURL: URL? { folder?.appending(path: "now-playing.json") }

    static func read() -> WidgetSnapshot? {
        guard let url = snapshotURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    /// Small and already square: a widget has little memory to decode it in.
    static func artwork(_ snapshot: WidgetSnapshot) -> UIImage? {
        guard let name = snapshot.artworkFile, let url = folder?.appending(path: name) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    /// Writes the snapshot (and the cover, under a new name, removing the older ones). False when
    /// there is no shared folder.
    @discardableResult
    static func write(_ snapshot: WidgetSnapshot, artwork: Data?) -> Bool {
        guard let folder else { return false }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var snapshot = snapshot
            if let artwork {
                let name = "cover-\(UUID().uuidString).jpg"
                try artwork.write(to: folder.appending(path: name), options: .atomic)
                snapshot.artworkFile = name
            }
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: folder.appending(path: "now-playing.json"), options: .atomic)
            // Only the current cover is kept.
            let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for file in files where file.hasPrefix("cover-") && file != snapshot.artworkFile {
                try? FileManager.default.removeItem(at: folder.appending(path: file))
            }
            return true
        } catch {
            return false
        }
    }
}

// MARK: Commands

enum WidgetCommand: String {
    case togglePlayback, next, recognize
}

/// What the widgets' buttons do, set by the app as it starts (see `SeaglassApp`). The intents below
/// run in the app's process: an audio intent (`AudioPlaybackIntent`) wakes it in the background, one
/// that opens it (`openAppWhenRun`) brings it forward. In the widget extension there is no handler.
@MainActor
enum WidgetCommands {
    static var handler: (@MainActor (WidgetCommand) -> Void)?

    static func run(_ command: WidgetCommand) {
        handler?(command)
    }
}

struct TogglePlaybackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Riproduci o metti in pausa"
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        WidgetCommands.run(.togglePlayback)
        return .result()
    }
}

struct NextTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Brano successivo"
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        WidgetCommands.run(.next)
        return .result()
    }
}

struct RecognizeSongIntent: AppIntent {
    static let title: LocalizedStringResource = "Riconosci un brano"
    static let openAppWhenRun = true
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        WidgetCommands.run(.recognize)
        return .result()
    }
}

/// Where a tap on the widget takes the app: the player (see `SeaglassApp`'s `onOpenURL`).
enum WidgetLink {
    static let player = URL(string: "seaglass://player")!
}
