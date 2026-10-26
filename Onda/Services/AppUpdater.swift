import Combine
import Foundation

/// What happens when a newer version of Onda is published on GitHub (Settings → Aggiornamenti).
enum UpdateMode: String, CaseIterable, Identifiable {
    /// Shows the new version and its changelog.
    case notify
    /// Saves the new IPA in Files (Sul mio iPhone › Onda › Aggiornamenti), then shows it.
    case download

    var id: Self { self }

    var title: String {
        switch self {
        case .notify: return String(localized: "Avvisami")
        case .download: return String(localized: "Scarica in automatico")
        }
    }
}

enum UpdateError: LocalizedError {
    case server(Int)
    case noIPA

    var errorDescription: String? {
        switch self {
        case .server(let status): return String(localized: "GitHub non ha risposto correttamente (\(status)).")
        case .noIPA: return String(localized: "Questa versione non ha un file IPA da scaricare.")
        }
    }
}

/// Checks GitHub for a newer stable release of Onda at launch or on request, and either shows it
/// or downloads its IPA, as chosen in Settings. Installing stays manual (Sideloadly, AltStore…):
/// iOS doesn't let a sideloaded app replace itself.
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
        let ipa: URL?
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

    private init() {}

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// At launch the sheet shows up at most once a day for the same version; a manual check always shows it.
    func check(userInitiated: Bool) async {
        guard status != .checking else { return }
        status = .checking
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
            if Preferences.updateModeSetting == .download, downloadedFile == nil {
                await download()
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

    private func shouldNotify(_ release: Release) -> Bool {
        guard let last = UserDefaults.standard.dictionary(forKey: Self.noticeKey),
              last["version"] as? String == release.version,
              let date = last["date"] as? Double else { return true }
        return Date.now.timeIntervalSince1970 - date > 24 * 3600
    }

    /// Once a version is installed, its IPA (and older ones) are only taking space.
    private func removeInstalledUpdates() {
        for file in Self.savedIPAs() {
            let version = file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "Onda-", with: "")
            if !AppVersion.isNewer(version, than: Self.currentVersion) {
                try? FileManager.default.removeItem(at: file)
                if downloadedFile == file { downloadedFile = nil }
            }
        }
    }

    private static func file(for release: Release) -> URL? {
        release.ipa == nil ? nil : Storage.updates.appending(path: "Onda-\(release.version).ipa")
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
        let ipa = release.assets.first { $0.name.lowercased().hasSuffix(".ipa") }?.browserDownloadUrl
        let version = AppVersion.components(release.tagName).map(String.init).joined(separator: ".")
        return Release(version: version, notes: release.body ?? "", page: release.htmlUrl, ipa: ipa)
    }
}
