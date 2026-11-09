import AppKit

/// What the Mac app needs from AppKit, which a Mac Catalyst app can't use itself: its icon in the
/// menu bar, and installing an update over itself. The app loads this bundle from its PlugIns and
/// talks to it through the Objective-C methods below (see `MacBridge` in the app), passing the
/// menu's text in the user's language and blocks for its actions.
@MainActor
@objc(SeaglassMacBridge)
final class SeaglassMacBridge: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var labels: [String: String] = [:]
    private var actions: [String: () -> Void] = [:]
    private var song: String?
    private var artist: String?
    private var playing = false

    // MARK: Menu bar

    /// `configuration`: "labels" ([String: String]: play, pause, next, previous, open, quit, idle)
    /// and "actions" ([String: block]: playPause, next, previous, open).
    @objc func startMenuBar(_ configuration: NSDictionary) {
        labels = configuration["labels"] as? [String: String] ?? [:]
        if let blocks = configuration["actions"] as? [String: Any] {
            for (key, value) in blocks {
                let block = unsafeBitCast(value as AnyObject, to: (@convention(block) () -> Void).self)
                actions[key] = { block() }
            }
        }
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = icon(playing: false)
        item.button?.toolTip = "Seaglass"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// `info`: "title" and "artist" (absent when nothing is loaded) and "playing" (a Bool).
    @objc func updateNowPlaying(_ info: NSDictionary) {
        song = info["title"] as? String
        artist = info["artist"] as? String
        playing = (info["playing"] as? NSNumber)?.boolValue ?? false
        statusItem?.button?.image = icon(playing: playing)
        statusItem?.button?.toolTip = [song, artist].compactMap { $0 }.joined(separator: " — ").nonEmpty ?? "Seaglass"
    }

    /// The note, with sound waves while the music plays.
    private func icon(playing: Bool) -> NSImage? {
        let image = NSImage(systemSymbolName: playing ? "music.note.list" : "music.note",
                            accessibilityDescription: "Seaglass")
        image?.isTemplate = true
        return image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let song {
            let title = NSMenuItem(title: song, action: nil, keyEquivalent: "")
            title.attributedTitle = NSAttributedString(string: song, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
            title.isEnabled = false
            menu.addItem(title)
            if let artist, !artist.isEmpty {
                let line = NSMenuItem(title: artist, action: nil, keyEquivalent: "")
                line.isEnabled = false
                menu.addItem(line)
            }
        } else {
            let idle = NSMenuItem(title: labels["idle"] ?? "Seaglass", action: nil, keyEquivalent: "")
            idle.isEnabled = false
            menu.addItem(idle)
        }
        menu.addItem(.separator())
        if song != nil {
            menu.addItem(item(labels[playing ? "pause" : "play"] ?? "", action: "playPause"))
            menu.addItem(item(labels["next"] ?? "", action: "next"))
            menu.addItem(item(labels["previous"] ?? "", action: "previous"))
            menu.addItem(.separator())
        }
        menu.addItem(item(labels["open"] ?? "Seaglass", action: "open"))
        let quit = NSMenuItem(title: labels["quit"] ?? "Quit", action: #selector(quit(_:)), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
    }

    private func item(_ title: String, action: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = action
        return item
    }

    @objc private func run(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        if key == "open" { NSApp.activate() }
        actions[key]?()
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    // MARK: Updates

    /// Whether the app can replace itself where it is: not run from a read-only place (macOS runs
    /// an app opened from Downloads from a copy elsewhere until it's moved) and in a folder it can write.
    @objc func canUpdateInPlace() -> NSNumber {
        let app = Bundle.main.bundleURL
        let translocated = app.path.contains("/AppTranslocation/")
        let writable = FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path)
            && FileManager.default.isWritableFile(atPath: app.path)
        return NSNumber(value: !translocated && writable)
    }

    /// Unzips a downloaded update beside the zip and checks it before it's ever opened: the same
    /// app (its identifier), the version announced, and a whole, valid signature.
    /// `request`: "zip" (path), "version", "completion" (block taking the new app's path, or nil and
    /// an error). The work happens off the main thread; the completion is called on it.
    @objc func stageUpdate(_ request: NSDictionary) {
        guard let zip = request["zip"] as? String, let version = request["version"] as? String,
              let completionObject = request["completion"] else { return }
        let completion = unsafeBitCast(completionObject as AnyObject,
                                       to: (@convention(block) (NSString?, NSString?) -> Void).self)
        let identifier = Bundle.main.bundleIdentifier
        DispatchQueue.global(qos: .utility).async {
            let result = Self.stage(zip: URL(fileURLWithPath: zip), version: version, identifier: identifier)
            DispatchQueue.main.async {
                switch result {
                case .success(let app): completion(app.path as NSString, nil)
                case .failure(let error): completion(nil, error.message as NSString)
                }
            }
        }
    }

    private struct StageError: Error {
        let message: String
    }

    nonisolated private static func stage(zip: URL, version: String, identifier: String?) -> Result<URL, StageError> {
        let folder = zip.deletingPathExtension()
        try? FileManager.default.removeItem(at: folder)
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path]) else {
            return .failure(StageError(message: "unzip failed"))
        }
        let app = folder.appending(path: "Seaglass.app")
        guard let info = Bundle(url: app)?.infoDictionary,
              let found = info["CFBundleIdentifier"] as? String, found == identifier else {
            return .failure(StageError(message: "not Seaglass"))
        }
        guard info["CFBundleShortVersionString"] as? String == version else {
            return .failure(StageError(message: "not version \(version)"))
        }
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) else {
            return .failure(StageError(message: "signature not valid"))
        }
        return .success(app)
    }

    /// Puts a staged update in place of the running app (the running copy carries on from memory) and,
    /// with "relaunch", quits and opens the new one as soon as this one has gone.
    /// `request`: "app" (the staged app's path), "relaunch" (a Bool). Returns nil, or an error.
    @objc func installUpdate(_ request: NSDictionary) -> NSString? {
        guard let staged = request["app"] as? String else { return "no update" }
        let relaunch = (request["relaunch"] as? NSNumber)?.boolValue ?? false
        let current = Bundle.main.bundleURL
        guard canUpdateInPlace().boolValue else { return "can't update in place" }
        do {
            _ = try FileManager.default.replaceItemAt(current, withItemAt: URL(fileURLWithPath: staged))
        } catch {
            return error.localizedDescription as NSString
        }
        guard relaunch else { return nil }
        // A small shell waits for this process to end, then opens the new app at the same place.
        let script = "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\""
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/bin/sh")
        opener.arguments = ["-c", script, current.path]
        do {
            try opener.run()
        } catch {
            return error.localizedDescription as NSString
        }
        NSApp.terminate(nil)
        return nil
    }

    nonisolated private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
