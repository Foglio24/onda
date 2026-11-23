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
/// Seaglass is installed by sideloading, and the tools that sign it rename the group after the
/// signer's team (AltStore and SideStore make "group.com.onda.player.<team>", others their own). The
/// name that counts is the one in the signature, so it is looked for where the signers write it: the
/// provisioning profile each signed bundle carries (`embedded.mobileprovision`, which lists the
/// groups it grants), then the `ALTAppGroups` list AltStore adds to the Info.plist, then the name the
/// app declares. App and widgets build the same list from both bundles (the app's and the widgets'),
/// groups granted to both first, and each takes the first one it can open. 1.36.21 looked only at the
/// last two, and on an iPhone signed otherwise the widget found no folder and showed nothing.
/// Without any group the widgets show "Niente in riproduzione", and their buttons still work (see
/// `WidgetCommands`).
enum SharedStore {
    static let declaredGroup = "group.com.onda.player"
    static let widgetsBundleName = "SeaglassWidgets.appex"

    /// The app's bundle and the widgets', from whichever of the two is running.
    private static var bundleURLs: (app: URL, widgets: URL) {
        let main = Bundle.main.bundleURL
        if main.pathExtension == "appex" {
            // App.app/PlugIns/X.appex on an iPhone, App.app/Contents/PlugIns/X.appex on a Mac.
            var app = main.deletingLastPathComponent().deletingLastPathComponent()
            if app.lastPathComponent == "Contents" { app = app.deletingLastPathComponent() }
            return (app, main)
        }
        let plugIns = Bundle.main.builtInPlugInsURL ?? main.appending(path: "PlugIns")
        return (main, plugIns.appending(path: widgetsBundleName))
    }

    /// The groups a bundle's provisioning profile grants (none: no profile, or none granted).
    static func provisionedGroups(in bundle: URL) -> [String] {
        guard let data = try? Data(contentsOf: bundle.appending(path: "embedded.mobileprovision")),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil)
                as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String] else { return [] }
        return groups.filter { !$0.contains("*") }
    }

    private static func listedGroups(in bundle: URL) -> [String] {
        Bundle(url: bundle)?.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] ?? []
    }

    static var groupIdentifiers: [String] {
        let (app, widgets) = bundleURLs
        let appGroups = provisionedGroups(in: app), widgetGroups = provisionedGroups(in: widgets)
        var identifiers: [String] = []
        func add(_ list: [String]) {
            for identifier in list where !identifiers.contains(identifier) { identifiers.append(identifier) }
        }
        add(appGroups.filter(widgetGroups.contains))
        add(appGroups)
        add(widgetGroups)
        add(listedGroups(in: app))
        add(listedGroups(in: widgets))
        add([declaredGroup])
        return identifiers
    }

    /// The group in use (nil: none can be opened), found once per process.
    static let activeGroup: String? = groupIdentifiers.first {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil
    }

    static var folder: URL? {
        guard let activeGroup,
              let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: activeGroup) else { return nil }
        return url.appending(path: "Widgets", directoryHint: .isDirectory)
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

/// What the widgets' buttons do, set by the app as it starts (see `SeaglassApp`). An intent the
/// system runs in the app (one that opens it, `openAppWhenRun`) calls it directly. One it runs in the
/// widget extension, where there is no handler, as the widget's play button was on an iPhone, tells
/// the app with a system-wide notification (`WidgetSignal`), which needs no shared folder: the app,
/// playing in the background, does it at once.
@MainActor
enum WidgetCommands {
    static var handler: (@MainActor (WidgetCommand) -> Void)?

    static func run(_ command: WidgetCommand) {
        if let handler {
            handler(command)
        } else {
            WidgetSignal.post(command)
        }
    }
}

/// The widgets' commands as Darwin notifications, from the widget extension to the app.
enum WidgetSignal {
    static func name(_ command: WidgetCommand) -> String { "com.onda.player.widget.\(command.rawValue)" }

    static func post(_ command: WidgetCommand) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(name(command) as CFString), nil, nil, true)
    }

    /// In the app: runs `WidgetCommands`' handler when the extension sends a command.
    static func listen() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for command in [WidgetCommand.togglePlayback, .next, .recognize] {
            CFNotificationCenterAddObserver(center, nil, { _, _, name, _, _ in
                guard let cfName = name?.rawValue else { return }
                let raw = cfName as String
                guard let command = [WidgetCommand.togglePlayback, .next, .recognize].first(where: { WidgetSignal.name($0) == raw })
                else { return }
                Task { @MainActor in WidgetCommands.handler?(command) }
            }, name(command) as CFString, nil, .deliverImmediately)
        }
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
