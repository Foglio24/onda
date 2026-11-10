import Combine
import UIKit

/// The Mac app's AppKit plug-in (Mac/Bridge, embedded in the Mac build only): Seaglass's icon in the
/// menu bar, and installing an update over the app. A Mac Catalyst app can't use AppKit itself.
/// On iPhone and iPad there is no plug-in, and this does nothing.
@MainActor
final class MacBridge {
    static let shared = MacBridge()

    private let plugIn: NSObject?
    private var observers: Set<AnyCancellable> = []

    private init() {
        guard ProcessInfo.processInfo.isMacCatalystApp else {
            plugIn = nil
            return
        }
        do {
            guard let url = Bundle.main.builtInPlugInsURL?.appending(path: "SeaglassMac.bundle"),
                  let bundle = Bundle(url: url) else { throw UpdateError.invalid }
            try bundle.loadAndReturnError()
            guard let type = bundle.principalClass as? NSObject.Type else { throw UpdateError.invalid }
            plugIn = type.init()
        } catch {
            // Said where it can be read (Console, CI's log): without it there's no menu bar icon nor updates.
            print("MacBridge: the AppKit plug-in didn't load: \(error)")
            plugIn = nil
        }
    }

    var isAvailable: Bool { plugIn != nil }

    // MARK: Menu bar

    /// Puts Seaglass in the menu bar, where it shows the song playing and controls it, and opens the
    /// window again once it's closed (the app keeps playing without one).
    func startMenuBar() {
        guard let plugIn, observers.isEmpty else { return }
        let player = PlayerController.shared
        let labels = [
            "play": String(localized: "Riproduci"),
            "pause": String(localized: "Pausa"),
            "next": String(localized: "Brano successivo"),
            "previous": String(localized: "Brano precedente"),
            "open": String(localized: "Apri Seaglass"),
            "quit": String(localized: "Esci da Seaglass"),
            "idle": String(localized: "Niente in riproduzione"),
        ]
        let actions: [String: AnyObject] = [
            "playPause": Self.block { player.togglePlayPause() },
            "next": Self.block { player.next() },
            "previous": Self.block { player.previous() },
            "open": Self.block { Self.openWindow() },
        ]
        _ = plugIn.perform(NSSelectorFromString("startMenuBar:"), with: ["labels": labels, "actions": actions] as NSDictionary)
        // After the change is in (the publishers announce it just before).
        player.nowPlaying.$currentID.combineLatest(player.nowPlaying.$isPlaying)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, playing in
                guard let self else { return }
                var info: [String: Any] = ["playing": NSNumber(value: playing)]
                if let track = player.current {
                    info["title"] = track.title
                    info["artist"] = track.artist
                }
                _ = self.plugIn?.perform(NSSelectorFromString("updateNowPlaying:"), with: info as NSDictionary)
            }
            .store(in: &observers)
    }

    /// The window, brought forward, or a new one if it was closed.
    private static func openWindow() {
        let session = UIApplication.shared.openSessions.first { $0.role == .windowApplication }
        let request = session.map { UISceneSessionActivationRequest(session: $0) }
            ?? UISceneSessionActivationRequest(role: .windowApplication)
        UIApplication.shared.activateSceneSession(for: request) { _ in }
    }

    /// A block the plug-in can call, running `action` on the main actor (the menu's actions come on it).
    private static func block(_ action: @escaping @MainActor () -> Void) -> AnyObject {
        let block: @convention(block) () -> Void = { MainActor.assumeIsolated { action() } }
        return unsafeBitCast(block, to: AnyObject.self)
    }

    // MARK: Keyboard

    /// Text fields and views being typed in: the space bar is theirs then.
    private var editing = 0
    private var keyboardObservers: Set<AnyCancellable> = []

    /// The space bar plays or pauses the music anywhere in the app, unless text is being typed.
    func handleSpaceBar() {
        guard let plugIn, keyboardObservers.isEmpty else { return }
        let center = NotificationCenter.default
        for begin in [UITextField.textDidBeginEditingNotification, UITextView.textDidBeginEditingNotification] {
            center.publisher(for: begin).sink { [weak self] _ in self?.editing += 1 }.store(in: &keyboardObservers)
        }
        for end in [UITextField.textDidEndEditingNotification, UITextView.textDidEndEditingNotification] {
            center.publisher(for: end).sink { [weak self] _ in
                guard let self else { return }
                editing = max(0, editing - 1)
            }.store(in: &keyboardObservers)
        }
        let block: @convention(block) () -> Bool = {
            MainActor.assumeIsolated {
                let player = PlayerController.shared
                guard MacBridge.shared.editing == 0, player.current != nil else { return false }
                player.togglePlayPause()
                return true
            }
        }
        _ = plugIn.perform(NSSelectorFromString("handleSpaceBar:"), with: unsafeBitCast(block, to: AnyObject.self))
    }

    // MARK: Volume

    /// The Mac's sound output volume (0…1), or nil when it has none to set.
    var systemVolume: Float? {
        (plugIn?.perform(NSSelectorFromString("systemVolume"))?.takeUnretainedValue() as? NSNumber)?.floatValue
    }

    func setSystemVolume(_ volume: Float) {
        _ = plugIn?.perform(NSSelectorFromString("setSystemVolume:"), with: NSNumber(value: volume))
    }

    /// Calls `handler` now and whenever the volume changes, wherever from (nil: none to set).
    func observeVolume(_ handler: @escaping @MainActor (Float?) -> Void) {
        let block: @convention(block) (NSNumber?) -> Void = { volume in
            MainActor.assumeIsolated { handler(volume?.floatValue) }
        }
        _ = plugIn?.perform(NSSelectorFromString("observeVolume:"), with: unsafeBitCast(block, to: AnyObject.self))
    }

    // MARK: Keychain

    /// Writes (or with nil removes) a password in the Mac's login keychain through macOS's
    /// file-based keychain API, which the app's own keychain calls can't always reach (see
    /// Keychain). The OSStatus, or nil without the plug-in.
    func keychainSet(_ value: String?, service: String, account: String) -> OSStatus? {
        guard let plugIn else { return nil }
        var request: [String: Any] = ["service": service, "account": account]
        if let value { request["value"] = value }
        let result = plugIn.perform(NSSelectorFromString("keychainSet:"), with: request as NSDictionary)
        return (result?.takeUnretainedValue() as? NSNumber).map { OSStatus($0.int32Value) }
    }

    func keychainGet(service: String, account: String) -> String? {
        let request: [String: Any] = ["service": service, "account": account]
        return plugIn?.perform(NSSelectorFromString("keychainGet:"), with: request as NSDictionary)?
            .takeUnretainedValue() as? String
    }

    // MARK: Updates

    /// Whether the app can replace itself where it is (not run from Downloads before being moved,
    /// and in a folder it can write).
    var canUpdateInPlace: Bool {
        (plugIn?.perform(NSSelectorFromString("canUpdateInPlace"))?.takeUnretainedValue() as? NSNumber)?.boolValue ?? false
    }

    /// Unzips a downloaded update and checks it (Seaglass's identifier, the version announced, a valid
    /// signature): the new app, ready to put in place.
    func stage(zip: URL, version: String) async throws -> URL {
        guard let plugIn else { throw UpdateError.invalid }
        return try await withCheckedThrowingContinuation { continuation in
            let completion: @convention(block) (NSString?, NSString?) -> Void = { path, _ in
                if let path {
                    continuation.resume(returning: URL(fileURLWithPath: path as String))
                } else {
                    continuation.resume(throwing: UpdateError.invalid)
                }
            }
            let request: [String: Any] = ["zip": zip.path, "version": version,
                                          "completion": unsafeBitCast(completion, to: AnyObject.self)]
            _ = plugIn.perform(NSSelectorFromString("stageUpdate:"), with: request as NSDictionary)
        }
    }

    /// Puts a staged update in place of the app and, with `relaunch`, quits and opens the new one.
    /// Returns an error's description when it couldn't.
    func install(app: URL, relaunch: Bool) -> String? {
        guard let plugIn else { return UpdateError.invalid.localizedDescription }
        let request: [String: Any] = [
            "app": app.path, "relaunch": NSNumber(value: relaunch),
            "prepareToQuit": Self.block { PlayerController.shared.prepareForAppTermination() },
        ]
        let result = plugIn.perform(NSSelectorFromString("installUpdate:"), with: request as NSDictionary)
        return result?.takeUnretainedValue() as? String
    }
}
