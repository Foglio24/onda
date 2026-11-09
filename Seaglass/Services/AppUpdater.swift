import Combine
import CryptoKit
import UIKit
import Foundation

/// What happens when a newer version of Seaglass is published on GitHub (Settings → Aggiornamenti).
enum UpdateMode: String, CaseIterable, Identifiable {
    /// Shows the new version and its changelog.
    case notify
    /// Saves the new IPA in Files (Sul mio iPhone › Seaglass › Aggiornamenti), then shows it.
    /// On a Mac: downloads and installs it (see `AppUpdater.updateMac`).
    case download

    var id: Self { self }

    var title: String {
        switch self {
        case .notify: return String(localized: "Avvisami")
        case .download:
            return ProcessInfo.processInfo.isMacCatalystApp
                ? String(localized: "Installa in automatico") : String(localized: "Scarica in automatico")
        }
    }

    /// A Mac installs updates by itself unless told otherwise; an iPhone only says there is one.
    static var standard: UpdateMode { ProcessInfo.processInfo.isMacCatalystApp ? .download : .notify }
}

enum UpdateError: LocalizedError {
    case server(Int)
    case noIPA
    /// A download that isn't the release's own file, or not Seaglass once unzipped.
    case invalid
    /// The Mac app runs from where it can't replace itself (Downloads, a read-only folder).
    case notInPlace

    var errorDescription: String? {
        switch self {
        case .server(let status): return String(localized: "GitHub non ha risposto correttamente (\(status)).")
        case .noIPA: return String(localized: "Questa versione non ha un file IPA da scaricare.")
        case .invalid: return String(localized: "Questo aggiornamento non è valido: non è stato installato.")
        case .notInPlace: return String(localized: "Sposta Seaglass nella cartella Applicazioni perché si aggiorni da sola.")
        }
    }
}

/// Checks GitHub for a newer stable release of Seaglass at launch or on request, and either shows it
/// or downloads its IPA, as chosen in Settings. Installing stays manual (Sideloadly, AltStore…):
/// iOS doesn't let a sideloaded app replace itself. A Mac does: there the update is downloaded,
/// checked and installed by the app itself (`updateMac`), right away when nothing plays, else when
/// Seaglass quits.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    static let repositoryURL = URL(string: "https://github.com/Foglio24/onda")!
    static let licenseURL = URL(string: "https://github.com/Foglio24/onda/blob/main/LICENSE")!
    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/Foglio24/onda/releases/latest")!
    private static let noticeKey = "updates.lastNotice"

    struct Release: Equatable {
        let version: String
        let notes: String
        let page: URL
        /// The IPA, or on a Mac the Mac app's zip.
        let ipa: URL?
        /// Its size and SHA-256 as GitHub gives them, to check the download against.
        var size: Int?
        var digest: String?
    }

    /// The Mac's update, once it's being downloaded or ready to put in place.
    enum MacInstall: Equatable {
        case none, downloading, ready(URL), failed(String)
    }

    enum Status: Equatable {
        case idle, checking, upToDate, available, failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var latest: Release?
    @Published private(set) var downloadedFile: URL?
    @Published private(set) var isDownloading = false
    @Published private(set) var downloadError: String?
    /// Presents the update sheet (see RootView).
    @Published var showsNotice = false
    @Published private(set) var macInstall: MacInstall = .none
    private var lastCheck: Date?
    private var observers: [NSObjectProtocol] = []

    private init() {
        guard ProcessInfo.processInfo.isMacCatalystApp else { return }
        // A Mac app stays open for days: it looks again when it comes forward, twice a day at most,
        // and an update that's ready goes in as it quits.
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                                object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let updater = AppUpdater.shared
                guard let last = updater.lastCheck, Date.now.timeIntervalSince(last) > 12 * 3600 else { return }
                Task { await updater.check(userInitiated: false) }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification,
                                                                object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppUpdater.shared.installAtQuit() }
        })
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// At launch the sheet shows up at most once a day for the same version; a manual check always shows it.
    func check(userInitiated: Bool) async {
        guard status != .checking else { return }
        status = .checking
        lastCheck = .now
        do {
            let release = try await Self.fetchLatest()
            latest = release
            removeInstalledUpdates()
            guard AppVersion.isNewer(release.version, than: Self.currentVersion) else {
                status = .upToDate
                return
            }
            status = .available
            downloadedFile = Self.file(for: release).flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            if Preferences.updateModeSetting == .download {
                if ProcessInfo.processInfo.isMacCatalystApp {
                    // Downloaded and installed by itself: nothing to tell unless asked.
                    await updateMac(now: false)
                    if !userInitiated, case .ready = macInstall { return }
                } else if downloadedFile == nil {
                    await download()
                }
            }
            if userInitiated || shouldNotify(release) {
                let notice: [String: Any] = ["version": release.version, "date": Date.now.timeIntervalSince1970]
                UserDefaults.standard.set(notice, forKey: Self.noticeKey)
                showsNotice = true
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Saves the new version's IPA in the updates folder, replacing older ones.
    func download() async {
        guard let release = latest, !isDownloading else { return }
        if ProcessInfo.processInfo.isMacCatalystApp {
            await updateMac(now: true)
            return
        }
        guard let source = release.ipa, let destination = Self.file(for: release) else {
            downloadError = UpdateError.noIPA.localizedDescription
            return
        }
        isDownloading = true
        downloadError = nil
        defer { isDownloading = false }
        do {
            let (temporary, response) = try await URLSession.shared.download(from: source)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw UpdateError.server(status) }
            for old in Self.savedIPAs() { try? FileManager.default.removeItem(at: old) }
            try FileManager.default.moveItem(at: temporary, to: destination)
            downloadedFile = destination
        } catch {
            downloadError = error.localizedDescription
        }
    }

    // MARK: Mac

    /// Downloads the Mac app of the latest release, checks it and gets it ready; then installs it and
    /// opens it again, now (`now`, or nothing loaded in the player) or when Seaglass quits.
    /// It only takes the repository's own release file, whose size and SHA-256 must be GitHub's, and
    /// the app inside must be Seaglass, at that version, with a valid signature (see `MacBridge`).
    func updateMac(now: Bool) async {
        guard let release = latest, AppVersion.isNewer(release.version, than: Self.currentVersion) else { return }
        switch macInstall {
        case .downloading:
            return
        case .ready(let app):
            if now { failIfNeeded(MacBridge.shared.install(app: app, relaunch: true)) }
            return
        case .none, .failed:
            break
        }
        guard MacBridge.shared.isAvailable, MacBridge.shared.canUpdateInPlace else {
            macInstall = .failed(UpdateError.notInPlace.localizedDescription)
            downloadError = UpdateError.notInPlace.localizedDescription
            return
        }
        macInstall = .downloading
        downloadError = nil
        do {
            guard let source = release.ipa, Self.isReleaseAsset(source), let size = release.size,
                  let digest = release.digest?.lowercased(), digest.hasPrefix("sha256:") else { throw UpdateError.invalid }
            let (temporary, response) = try await URLSession.shared.download(from: source)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw UpdateError.server(status) }
            let zip = Storage.updates.appending(path: "Seaglass-\(release.version)-mac.zip")
            try? FileManager.default.removeItem(at: zip)
            try FileManager.default.moveItem(at: temporary, to: zip)
            defer { try? FileManager.default.removeItem(at: zip) }
            let actualSize = (try? FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int) ?? -1
            let actualDigest = await Self.sha256(of: zip)
            guard actualSize == size, actualDigest == String(digest.dropFirst("sha256:".count)) else {
                throw UpdateError.invalid
            }
            let app = try await MacBridge.shared.stage(zip: zip, version: release.version)
            macInstall = .ready(app)
            if now || PlayerController.shared.nowPlaying.isIdle {
                failIfNeeded(MacBridge.shared.install(app: app, relaunch: true))
            }
        } catch {
            macInstall = .failed(error.localizedDescription)
            downloadError = error.localizedDescription
        }
    }

    /// An update that's ready goes in as Seaglass quits, and is there the next time it opens.
    private func installAtQuit() {
        guard case .ready(let app) = macInstall else { return }
        macInstall = .none
        _ = MacBridge.shared.install(app: app, relaunch: false)
    }

    private func failIfNeeded(_ error: String?) {
        guard let error else { return }
        macInstall = .failed(error)
        downloadError = error
    }

    /// A file of one of this repository's releases on GitHub, and nothing else.
    private static func isReleaseAsset(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.path.hasPrefix("/Foglio24/onda/releases/download/")
    }

    nonisolated private static func sha256(of file: URL) async -> String? {
        await Task.detached(priority: .utility) {
            guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    private func shouldNotify(_ release: Release) -> Bool {
        guard let last = UserDefaults.standard.dictionary(forKey: Self.noticeKey),
              last["version"] as? String == release.version,
              let date = last["date"] as? Double else { return true }
        return Date.now.timeIntervalSince1970 - date > 24 * 3600
    }

    /// Once a version is installed, its IPA (and older ones) are only taking space; on a Mac, so are
    /// the folders its updates were unzipped in.
    private func removeInstalledUpdates() {
        if ProcessInfo.processInfo.isMacCatalystApp, macInstall == .none {
            let items = (try? FileManager.default.contentsOfDirectory(at: Storage.updates, includingPropertiesForKeys: nil)) ?? []
            for item in items where item.lastPathComponent.hasSuffix("-mac") || item.pathExtension == "zip" {
                try? FileManager.default.removeItem(at: item)
            }
        }
        for file in Self.savedIPAs() {
            let version = file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "Onda-", with: "")
                .replacingOccurrences(of: "Seaglass-", with: "")
            if !AppVersion.isNewer(version, than: Self.currentVersion) {
                try? FileManager.default.removeItem(at: file)
                if downloadedFile == file { downloadedFile = nil }
            }
        }
    }

    private static func file(for release: Release) -> URL? {
        release.ipa == nil ? nil : Storage.updates.appending(path: "Seaglass-\(release.version).ipa")
    }

    private static func savedIPAs() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: Storage.updates,
                                                                  includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "ipa" }
    }

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: URL
            let size: Int?
            /// "sha256:…", for files uploaded since GitHub started giving it.
            let digest: String?
        }

        let tagName: String
        let body: String?
        let htmlUrl: URL
        let assets: [Asset]
    }

    private static func fetchLatest() async throws -> Release {
        var request = URLRequest(url: latestReleaseURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.server(status) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let release = try decoder.decode(GitHubRelease.self, from: data)
        // On a Mac, the Mac app's zip.
        let suffix = ProcessInfo.processInfo.isMacCatalystApp ? "-mac.zip" : ".ipa"
        let asset = release.assets.first { $0.name.lowercased().hasSuffix(suffix) }
        let version = AppVersion.components(release.tagName).map(String.init).joined(separator: ".")
        return Release(version: version, notes: release.body ?? "", page: release.htmlUrl, ipa: asset?.browserDownloadUrl,
                       size: asset?.size, digest: asset?.digest)
    }
}
