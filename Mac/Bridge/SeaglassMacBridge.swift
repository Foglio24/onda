import AppKit
import Security
import AudioToolbox
import CoreAudio

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
    private var volumeHandler: ((NSNumber?) -> Void)?
    private var listenedOutput = AudioObjectID(kAudioObjectUnknown)
    private var outputVolumeListener: AudioObjectPropertyListenerBlock?

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

    // MARK: Volume

    /// The volume of the Mac's sound output (0…1), the one in the menu bar; nil when the output has
    /// none to set (some HDMI and USB outputs).
    @objc func systemVolume() -> NSNumber? {
        guard let output = Self.output(), let address = Self.volumeAddresses(of: output).first else { return nil }
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var where_ = address
        guard AudioObjectGetPropertyData(output, &where_, 0, nil, &size, &volume) == noErr else { return nil }
        return NSNumber(value: volume)
    }

    /// Sets the output's volume: its overall one, or else each of its channels'.
    @objc func setSystemVolume(_ value: NSNumber) {
        guard let output = Self.output() else { return }
        var volume = Float32(max(0, min(1, value.floatValue)))
        let size = UInt32(MemoryLayout<Float32>.size)
        let addresses = Self.volumeAddresses(of: output)
        for address in addresses {
            var where_ = address
            let status = AudioObjectSetPropertyData(output, &where_, 0, nil, size, &volume)
            // The overall volume done, the channels follow it by themselves.
            if status == noErr, address.mSelector == kAudioHardwareServiceDeviceProperty_VirtualMainVolume { return }
        }
    }

    /// Where an output's volume can be set: its overall (virtual) volume as the menu bar uses it, or
    /// its main volume, or its first two channels'; empty when it has none (some HDMI and USB outputs).
    nonisolated private static func volumeAddresses(of output: AudioObjectID) -> [AudioObjectPropertyAddress] {
        var candidates = [volumeAddress]
        for element in [kAudioObjectPropertyElementMain, 1, 2] as [UInt32] {
            candidates.append(AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                         mScope: kAudioDevicePropertyScopeOutput, mElement: element))
        }
        let settable = candidates.filter { candidate in
            var address = candidate
            var isSettable: DarwinBoolean = false
            return AudioObjectHasProperty(output, &address)
                && AudioObjectIsPropertySettable(output, &address, &isSettable) == noErr && isSettable.boolValue
        }
        // The overall volume alone when there is one; otherwise the main one, or the channels.
        if let overall = settable.first(where: { $0.mSelector == kAudioHardwareServiceDeviceProperty_VirtualMainVolume }) {
            return [overall]
        }
        if let main = settable.first(where: { $0.mElement == kAudioObjectPropertyElementMain }) { return [main] }
        return settable
    }

    /// Calls `block` (taking the volume, or nil) now and whenever the volume changes (from Seaglass,
    /// the keyboard or the menu bar) or the sound goes to another output.
    @objc func observeVolume(_ block: Any) {
        let handler = unsafeBitCast(block as AnyObject, to: (@convention(block) (NSNumber?) -> Void).self)
        let first = volumeHandler == nil
        volumeHandler = { handler($0) }
        if first {
            var address = Self.outputAddress
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.listenToOutput() }
            }
        }
        listenToOutput()
    }

    private func listenToOutput() {
        var address = Self.volumeAddress
        if let listener = outputVolumeListener {
            AudioObjectRemovePropertyListenerBlock(listenedOutput, &address, .main, listener)
            outputVolumeListener = nil
        }
        if let output = Self.output() {
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.reportVolume() }
            }
            if AudioObjectAddPropertyListenerBlock(output, &address, .main, listener) == noErr {
                listenedOutput = output
                outputVolumeListener = listener
            }
        }
        reportVolume()
    }

    private func reportVolume() {
        volumeHandler?(systemVolume())
    }

    nonisolated private static var outputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                   mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    /// The output's overall volume, as the menu bar sets it, whatever its channels.
    nonisolated private static var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                   mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    nonisolated private static func output() -> AudioObjectID? {
        var address = outputAddress
        var output = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &output) == noErr,
              output != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return output
    }

    // MARK: Keyboard

    private var spaceMonitor: Any?

    /// The windows move only by their title bar, as Apple Music's: a click on a page (the volume, a
    /// slider) never drags the whole window. Returns whether one could be moved by its background.
    private var windowObserver: NSObjectProtocol?

    @objc func keepWindowsInPlace() -> NSNumber {
        var movable = false
        for window in NSApp.windows where window.isMovableByWindowBackground {
            movable = true
            window.isMovableByWindowBackground = false
        }
        if windowObserver == nil {
            windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeMainNotification,
                                                                    object: nil, queue: .main) { note in
                let window = note.object as? NSWindow
                MainActor.assumeIsolated { window?.isMovableByWindowBackground = false }
            }
        }
        return NSNumber(value: movable)
    }

    // MARK: Zoom

    /// The scale macOS draws the app at (an iPad app on a Mac: 77 %) times the zoom. Read by the
    /// scene views' scale methods, replaced by `scaleScenes`, on the main thread.
    nonisolated(unsafe) private static var sceneScale: CGFloat = 0.77
    private static var baseScale: CGFloat?
    private static var zoom: CGFloat = 1

    /// `value`: the zoom, 0.5…2 (1, the app's own size). Everything in the windows grows or shrinks
    /// together, as with Spotify's zoom: macOS has no setting for an iPad app's 77 % scale, so the
    /// methods UIKit's Mac windows read it from (`UINSSceneView`'s) return it times the zoom, and
    /// the windows are laid out again. Returns what was done, for CI's log.
    @objc func setZoom(_ value: NSNumber) -> NSString {
        let zoom = min(2, max(0.5, CGFloat(value.doubleValue)))
        var report: [String] = []
        if Self.baseScale == nil {
            let base = Self.currentSceneScale() ?? 0.77
            Self.baseScale = base
            Self.sceneScale = base
            report.append("base \(base), scaled " + Self.scaleScenes().joined(separator: ", "))
        }
        guard zoom != Self.zoom, let base = Self.baseScale else { return report.joined(separator: "; ") as NSString }
        Self.zoom = zoom
        Self.sceneScale = base * zoom
        // A resize makes each window's scene take the new scale (its size in the app's points).
        for window in NSApp.windows where window.isVisible && window.contentView.map(Self.hasSceneView) == true {
            let frame = window.frame
            window.setFrame(NSRect(x: frame.minX, y: frame.minY, width: frame.width + 1, height: frame.height), display: false)
            window.setFrame(frame, display: true)
        }
        report.append("zoom \(zoom), scene scale \(Self.sceneScale)")
        return report.joined(separator: "; ") as NSString
    }

    private static let sceneScaleMethods = [
        ("UINSSceneView", "sceneToSceneViewScaleFactor"),
        ("UINSSceneView", "fixedSceneToSceneViewScaleFactor"),
        ("UINSSceneContainerView", "sceneToSceneViewScaleForLayout"),
    ]

    /// The scale the app is drawn at now, read from a window's scene view before any change.
    private static func currentSceneScale() -> CGFloat? {
        for window in NSApp.windows {
            guard let view = window.contentView.flatMap({ sceneView(in: $0) }) else { continue }
            let selector = NSSelectorFromString("sceneToSceneViewScaleFactor")
            guard view.responds(to: selector), let method = class_getInstanceMethod(type(of: view), selector) else { continue }
            typealias Getter = @convention(c) (AnyObject, Selector) -> CGFloat
            let scale = unsafeBitCast(method_getImplementation(method), to: Getter.self)(view, selector)
            if scale > 0.3, scale < 3 { return scale }
        }
        return nil
    }

    private static func sceneView(in view: NSView) -> NSView? {
        if NSStringFromClass(type(of: view)).contains("UINSSceneView") { return view }
        for subview in view.subviews {
            if let found = sceneView(in: subview) { return found }
        }
        return nil
    }

    private static func hasSceneView(_ view: NSView) -> Bool { sceneView(in: view) != nil }

    /// Each scene scale method (those that exist and return a CGFloat) returns `sceneScale` instead:
    /// the same value from each, so none multiplies what another already did.
    private static func scaleScenes() -> [String] {
        var replaced: [String] = []
        for (className, name) in sceneScaleMethods {
            guard let type = NSClassFromString(className) else { continue }
            let selector = NSSelectorFromString(name)
            guard let method = class_getInstanceMethod(type, selector), let encoding = method_getTypeEncoding(method),
                  String(cString: encoding).hasPrefix("d") else { continue }
            let replacement: @convention(block) (AnyObject) -> CGFloat = { _ in SeaglassMacBridge.sceneScale }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
            replaced.append("\(className).\(name)")
        }
        return replaced
    }

    // MARK: AirPlay

    /// The AirPlay button about to open its list of devices: its frame and its window's size, in
    /// the app's (UIKit) points, and when. Read by the next popover shown (see `NSPopover` below).
    fileprivate static var routeAnchor: (button: CGRect, window: CGSize, time: Date)?
    private static var correctsPopovers = false

    /// `request`: "x", "y", "width", "height" (the AirPlay button in its window) and "windowWidth",
    /// "windowHeight", in the app's points. macOS 26 places the list AirPlay opens from its button
    /// with the app's 77 % scale (the iPad's, on a Mac) applied twice, so it opens far from the
    /// button, towards the window's top left corner; the popover is put at the button instead.
    @objc func anchorRoutePicker(_ request: NSDictionary) {
        func value(_ key: String) -> CGFloat { CGFloat((request[key] as? NSNumber)?.doubleValue ?? 0) }
        Self.routeAnchor = (CGRect(x: value("x"), y: value("y"), width: value("width"), height: value("height")),
                            CGSize(width: value("windowWidth"), height: value("windowHeight")), Date())
        guard !Self.correctsPopovers else { return }
        Self.correctsPopovers = true
        let pairs = [
            ("showRelativeToRect:ofView:preferredEdge:", #selector(NSPopover.seaglassShow(relativeTo:of:preferredEdge:))),
            ("showRelativeToRect:ofView:preferredEdge:hasFullSizeContent:",
             #selector(NSPopover.seaglassShow(relativeTo:of:preferredEdge:hasFullSizeContent:))),
        ]
        for (name, replacement) in pairs {
            guard let original = class_getInstanceMethod(NSPopover.self, NSSelectorFromString(name)),
                  let ours = class_getInstanceMethod(NSPopover.self, replacement) else { continue }
            method_exchangeImplementations(original, ours)
        }
    }

    /// Where a popover shown now should point, in `view`'s coordinates: at the AirPlay button just
    /// clicked, if it was (within 3 seconds), worked out from its place in the window rather than
    /// from the rect macOS passes, so it stays right if macOS's own scaling is ever fixed.
    fileprivate static func routeRect(in view: NSView, instead rect: NSRect) -> NSRect {
        guard let anchor = routeAnchor, Date().timeIntervalSince(anchor.time) < 3,
              let content = view.window?.contentView, anchor.window.width > 0, anchor.window.height > 0 else { return rect }
        routeAnchor = nil
        let bounds = content.bounds
        let scaleX = bounds.width / anchor.window.width, scaleY = bounds.height / anchor.window.height
        var button = NSRect(x: anchor.button.minX * scaleX, y: 0,
                            width: anchor.button.width * scaleX, height: anchor.button.height * scaleY)
        button.origin.y = content.isFlipped ? anchor.button.minY * scaleY : bounds.height - anchor.button.maxY * scaleY
        let corrected = view.convert(button, from: content)
        print("airplay: popover at \(rect) of \(type(of: view)) moved to \(corrected) (window content \(bounds.size))")
        return corrected
    }

    /// The app's windows, for CI's log: their kind, frame and level.
    @objc func describeWindows() -> NSString {
        NSApp.windows.filter(\.isVisible).map { window in
            "\(type(of: window)) \(window.frame) level \(window.level.rawValue)"
        }.joined(separator: "; ") as NSString
    }

    /// The space bar plays or pauses wherever Seaglass is, as in Apple Music: `block` (returning
    /// whether it took the key, which it doesn't while text is being typed) is called for each press.
    @objc func handleSpaceBar(_ block: Any) {
        guard spaceMonitor == nil else { return }
        let handler = unsafeBitCast(block as AnyObject, to: (@convention(block) () -> Bool).self)
        spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
            guard event.keyCode == 49, modifiers.isEmpty, !event.isARepeat else { return event }
            return handler() ? nil : event
        }
    }

    // MARK: Updates

    /// Whether the app can replace itself where it is: not run from a read-only place (macOS runs
    /// an app opened from Downloads from a copy elsewhere until it's moved) and in a folder it can write.
    // MARK: Keychain

    /// A password in the login keychain, with macOS's file-based keychain API: an ad hoc signed Mac
    /// Catalyst app's own keychain calls can fail where this works. Nil value removes it.
    @objc func keychainSet(_ request: NSDictionary) -> NSNumber {
        guard let service = request["service"] as? String, let account = request["account"] as? String else {
            return NSNumber(value: errSecParam)
        }
        var item: SecKeychainItem?
        if SecKeychainFindGenericPassword(nil, UInt32(service.utf8.count), service, UInt32(account.utf8.count), account,
                                          nil, nil, &item) == errSecSuccess, let item {
            SecKeychainItemDelete(item)
        }
        guard let value = request["value"] as? String else { return NSNumber(value: errSecSuccess) }
        let bytes = Array(value.utf8)
        let status = SecKeychainAddGenericPassword(nil, UInt32(service.utf8.count), service,
                                                   UInt32(account.utf8.count), account,
                                                   UInt32(bytes.count), bytes, nil)
        return NSNumber(value: status)
    }

    @objc func keychainGet(_ request: NSDictionary) -> NSString? {
        guard let service = request["service"] as? String, let account = request["account"] as? String else { return nil }
        var length: UInt32 = 0
        var data: UnsafeMutableRawPointer?
        guard SecKeychainFindGenericPassword(nil, UInt32(service.utf8.count), service, UInt32(account.utf8.count), account,
                                             &length, &data, nil) == errSecSuccess, let data else { return nil }
        defer { SecKeychainItemFreeContent(nil, data) }
        return String(data: Data(bytes: data, count: Int(length)), encoding: .utf8) as NSString?
    }

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
        var verified = false
        defer { if !verified { try? FileManager.default.removeItem(at: folder) } }
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
        verified = true
        return .success(app)
    }

    /// Mount a verified release DMG read-only, copy its app out, then apply the same identity,
    /// version and code-signature checks used for ZIP updates. Never run the mounted app.
    @objc func stageDMGUpdate(_ request: NSDictionary) {
        guard let path = request["dmg"] as? String, let version = request["version"] as? String,
              let completionObject = request["completion"] else { return }
        let completion = unsafeBitCast(completionObject as AnyObject,
                                       to: (@convention(block) (NSString?, NSString?) -> Void).self)
        let identifier = Bundle.main.bundleIdentifier
        DispatchQueue.global(qos: .utility).async {
            let result = Self.stageDMG(URL(fileURLWithPath: path), version: version, identifier: identifier)
            DispatchQueue.main.async {
                switch result {
                case .success(let app): completion(app.path as NSString, nil)
                case .failure(let error): completion(nil, error.message as NSString)
                }
            }
        }
    }

    nonisolated private static func stageDMG(_ dmg: URL, version: String, identifier: String?) -> Result<URL, StageError> {
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = dmg.deletingPathExtension()
        do {
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        } catch {
            return .failure(StageError(message: "DMG mount directory failed"))
        }
        defer { try? FileManager.default.removeItem(at: mount) }

        guard run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, dmg.path]) else {
            return .failure(StageError(message: "DMG mount failed"))
        }
        defer { _ = run("/usr/bin/hdiutil", ["detach", mount.path]) }

        let source = mount.appendingPathComponent("Seaglass.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: source.path) else {
            return .failure(StageError(message: "Seaglass.app missing from DMG"))
        }
        try? FileManager.default.removeItem(at: folder)
        var verified = false
        defer { if !verified { try? FileManager.default.removeItem(at: folder) } }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent("Seaglass.app"))
        } catch {
            return .failure(StageError(message: "DMG app copy failed"))
        }
        let app = folder.appendingPathComponent("Seaglass.app")
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
        verified = true
        return .success(app)
    }

    /// Puts a staged update in place of the running app (the running copy carries on from memory) and,
    /// with "relaunch", quits and opens the new one as soon as this one has gone.
    /// `request`: "app" (the staged app's path), "relaunch" (a Bool), "prepareToQuit" (a block that
    /// stops playback and saves its state after installation succeeds). Returns nil, or an error.
    @objc func installUpdate(_ request: NSDictionary) -> NSString? {
        guard let staged = request["app"] as? String else { return "no update" }
        let relaunch = (request["relaunch"] as? NSNumber)?.boolValue ?? false
        let current = Bundle.main.bundleURL
        guard canUpdateInPlace().boolValue else { return "can't update in place" }
        do {
            // The new app's own metadata only: the old copy's would carry its quarantine over, and
            // macOS would ask again whether to open it.
            _ = try FileManager.default.replaceItemAt(current, withItemAt: URL(fileURLWithPath: staged),
                                                      options: .usingNewMetadataOnly)
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
        if let preparation = request["prepareToQuit"] {
            let block = unsafeBitCast(preparation as AnyObject, to: (@convention(block) () -> Void).self)
            block()
        }
        // This terminates the application, including the menu bar and its closed-window playback.
        // The short-lived helper above is the only process left, and exits after opening the app.
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

/// Exchanged with NSPopover's own showing methods once the app has an AirPlay button (see
/// `anchorRoutePicker`): they call the originals, with the rect moved to the button just clicked.
fileprivate extension NSPopover {
    @objc dynamic func seaglassShow(relativeTo rect: NSRect, of view: NSView, preferredEdge edge: NSRectEdge) {
        seaglassShow(relativeTo: SeaglassMacBridge.routeRect(in: view, instead: rect), of: view, preferredEdge: edge)
    }

    @objc dynamic func seaglassShow(relativeTo rect: NSRect, of view: NSView, preferredEdge edge: NSRectEdge,
                                    hasFullSizeContent: Bool) {
        seaglassShow(relativeTo: SeaglassMacBridge.routeRect(in: view, instead: rect), of: view, preferredEdge: edge,
                     hasFullSizeContent: hasFullSizeContent)
    }
}
