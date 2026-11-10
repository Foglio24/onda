import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import SwiftUI
import UIKit

/// Seaglass's account (the service in server/account). As with Spotify, the account is managed on
/// its web page (name, password, the Premium subscription, deleting it): the app signs in through
/// that page, shows the account, keeps the library in sync with it, unlocks Premium's features
/// and signs out.
@MainActor
final class AccountService: ObservableObject {
    static let shared = AccountService()

    /// The account as the service describes it (GET /v1/account).
    struct Details: Codable, Equatable {
        struct Names: Codable, Equatable {
            var firstName: String?
            var lastName: String?
            var displayName: String?
        }
        /// Seaglass Premium: a paid Patreon membership linked on the account page.
        struct Membership: Codable, Equatable {
            var available: Bool
            var linked: Bool
            var premium: Bool?
        }
        struct Records: Codable, Equatable {
            var playlist: Int?
            var favorites: Int?
            var history: Int?
        }

        var id: String
        var email: String
        var emailVerified: Bool
        var createdAt: TimeInterval
        var profile: Names?
        var membership: Membership?
        var records: Records?

        var fullName: String? {
            let parts = [profile?.firstName, profile?.lastName].compactMap { $0 }.filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
        var name: String {
            if let display = profile?.displayName, !display.isEmpty { return display }
            return fullName ?? String(email.prefix { $0 != "@" })
        }
        var isPremium: Bool { membership?.premium == true }
        var memberSince: Date { Date(timeIntervalSince1970: createdAt) }
    }

    enum SyncState: Equatable {
        case idle
        case syncing
        case failed(String)
    }

    @Published private(set) var details: Details?
    @Published private(set) var isSignedIn: Bool
    @Published private(set) var isSigningIn = false
    @Published private(set) var syncState: SyncState = .idle
    @Published private(set) var lastSync: Date?
    /// Shown under the sign-in button when signing in didn't work.
    @Published var signInError: String?
    /// Whether Premium can be bought (the service says so): only then are its features locked.
    @Published private(set) var premiumEnabled: Bool

    /// The service's address, set by CI in the Info.plist (build.yml): nil, no accounts.
    let origin: URL?
    var isAvailable: Bool { origin != nil }
    /// The account page, where everything about the account is changed.
    var manageURL: URL? { origin?.appending(path: "account") }
    /// The account page's Premium section (after signing in there).
    var premiumURL: URL? {
        guard let manageURL else { return nil }
        var components = URLComponents(url: manageURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "view", value: "premium")]
        return components?.url
    }

    /// Premium, as last confirmed by the service within the last 30 days (it works offline).
    var hasPremium: Bool {
        guard isSignedIn, details?.isPremium == true, let refreshedAt = state.refreshedAt else { return false }
        return Date.now.timeIntervalSince(refreshedAt) < 30 * 86_400
    }

    /// Whether a Premium feature can be used: always in builds or setups where Premium can't be
    /// bought (no account service, or no Patreon there), and in CI's screenshots.
    func unlocks(_ feature: PremiumFeature) -> Bool {
        LaunchScene.isActive || !premiumEnabled || hasPremium
    }

    private static let callbackScheme = "com.onda.player.auth"
    private enum Keys {
        static let token = "account.token"
    }

    private var token: String? { Keychain.get(Keys.token) }
    private var state: StoredState
    private var syncing = false
    private var syncAgain = false
    private var applyingSync = false
    private var observers: Set<AnyCancellable> = []
    private var scheduledSync: Task<Void, Never>?
    private var lastPreferences: [String: SyncValue] = [:]
    private var lastRefresh: Date?
    private var lastStatus: Date?
    /// Whether AutoMix was there when the transitions were last set up.
    private var autoMixUnlocked = true

    private init() {
        let origin = Self.configuredOrigin()
        let stored = StoredState.load()
        self.origin = origin
        state = stored
        isSignedIn = origin != nil && Keychain.get(Keys.token) != nil
        premiumEnabled = origin != nil && stored.premiumEnabled == true
        details = stored.details
        lastSync = stored.lastSync
        lastPreferences = SyncedPreferences.read()
        observeChanges()
    }

    private static func configuredOrigin() -> URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "SeaglassAccountOrigin") as? String,
              let url = URL(string: value.trimmingCharacters(in: .whitespaces)),
              url.scheme == "https", url.host() != nil, url.path().isEmpty || url.path() == "/" else { return nil }
        return url
    }

    // MARK: Signing in and out

    /// Opens the account page in a sign-in sheet (never sharing the browser's cookies); the page
    /// sends back a one-time code that only this app, holding the verifier, can exchange.
    func signIn(using session: WebAuthenticationSession) async {
        guard let origin, !isSigningIn else { return }
        isSigningIn = true
        signInError = nil
        defer { isSigningIn = false }
        let verifier = Self.randomToken()
        let requestState = Self.randomToken()
        let challenge = Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        var components = URLComponents(url: origin.appending(path: "v1/auth/start"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "challenge", value: challenge), URLQueryItem(name: "state", value: requestState)]
        guard let url = components?.url else { return }
        do {
            let callback = try await session.authenticate(using: url, callbackURLScheme: Self.callbackScheme,
                                                          preferredBrowserSession: .ephemeral)
            let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard items.first(where: { $0.name == "state" })?.value == requestState,
                  let code = items.first(where: { $0.name == "code" })?.value else { throw AccountError.signInFailed }
            let body = try JSONSerialization.data(withJSONObject: ["code": code, "verifier": verifier])
            let data = try await send("v1/auth/exchange", method: "POST", body: body, token: nil)
            let exchange = try JSONDecoder().decode(Exchange.self, from: data)
            Keychain.set(exchange.token, for: Keys.token)
            if state.accountID != exchange.accountId {
                // Another account than the last one: its library is merged as on a first sync.
                state = StoredState(accountID: exchange.accountId)
                state.save()
                details = nil
                lastSync = nil
            }
            isSignedIn = true
            await refresh(force: true)
            await sync()
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // Closed by the user.
        } catch {
            signInError = (error as? AccountError)?.message ?? AccountError.signInFailed.message
        }
    }

    /// Signs this device out. The library stays on it, no longer synced.
    func signOut() async {
        if let token {
            _ = try? await send("v1/session", method: "DELETE", token: token)
        }
        endSession()
    }

    private func endSession() {
        Keychain.set(nil, for: Keys.token)
        isSignedIn = false
        details = nil
        syncState = .idle
        scheduledSync?.cancel()
        state.details = nil
        state.refreshedAt = nil
        state.save()
        enforcePremium()
    }

    // MARK: The account

    /// Reads the account from the service (at most every ten minutes unless forced).
    func refresh(force: Bool = false) async {
        guard isSignedIn, let token else { return }
        if !force, let lastRefresh, Date.now.timeIntervalSince(lastRefresh) < 600 { return }
        do {
            let data = try await send("v1/account", token: token)
            let fresh = try JSONDecoder().decode(Details.self, from: data)
            lastRefresh = .now
            state.details = fresh
            state.refreshedAt = .now
            state.save()
            details = fresh
            enforcePremium()
        } catch AccountError.signedOut {
            endSession()
        } catch {
            // Offline or the service is down: the last details stay on screen.
        }
    }

    /// Whether Premium can be bought, from the service (at most hourly). Without an answer the
    /// last one stays.
    func refreshStatus() async {
        guard origin != nil else { return }
        if let lastStatus, Date.now.timeIntervalSince(lastStatus) < 3600 { return }
        struct Status: Decodable { var premiumEnabled: Bool? }
        guard let data = try? await send("v1/status", token: nil),
              let status = try? JSONDecoder().decode(Status.self, from: data) else { return }
        lastStatus = .now
        state.premiumEnabled = status.premiumEnabled == true
        state.save()
        premiumEnabled = status.premiumEnabled == true
        enforcePremium()
    }

    /// The user went to the account page to get Premium: the next return to the app checks.
    func expectPremium() {
        lastRefresh = nil
    }

    /// Without Premium, its features that keep running (karaoke, a changed tempo) stop, and the
    /// transitions follow whether AutoMix is there.
    private func enforcePremium() {
        let player = PlayerController.shared
        if !unlocks(.karaoke), player.karaokeMode != .off { player.setKaraoke(.off) }
        if !unlocks(.tempo), player.songTempo != 0 { player.setSongTempo(0) }
        let autoMix = unlocks(.autoMix)
        if autoMix != autoMixUnlocked {
            autoMixUnlocked = autoMix
            player.applyTransitionPreference()
        }
    }

    /// The app came to the foreground: the account and what changed on the other devices.
    func appBecameActive() {
        guard isAvailable else { return }
        enforcePremium()
        Task {
            await refreshStatus()
            guard isSignedIn else { return }
            await refresh()
            await sync()
        }
    }

    /// The app went to the background: what changed here (the history too) is sent now.
    func appEnteredBackground() {
        guard isSignedIn else { return }
        let task = UIApplication.shared.beginBackgroundTask(withName: "Seaglass account sync")
        Task {
            await sync()
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
        }
    }

    // MARK: Sync

    /// Liked songs, playlists and preferences go up a few seconds after they change; the history,
    /// which changes with every song, goes with them or when the app goes to the background.
    private func observeChanges() {
        let library = Library.shared
        Publishers.Merge(library.$liked.map { _ in () }, library.$playlists.map { _ in () })
            .dropFirst(2)
            .sink { [weak self] in self?.libraryChanged() }
            .store(in: &observers)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let preferences = SyncedPreferences.read()
                guard preferences != lastPreferences else { return }
                lastPreferences = preferences
                libraryChanged()
            }
            .store(in: &observers)
    }

    private func libraryChanged() {
        guard isSignedIn, !applyingSync else { return }
        scheduledSync?.cancel()
        scheduledSync = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    /// Merges the library with the account's and sends the result (see `LibraryMerge`).
    func sync() async {
        guard isSignedIn, let token, let accountID = state.accountID else { return }
        guard !syncing else {
            syncAgain = true
            return
        }
        syncing = true
        syncState = .syncing
        do {
            // A write that crossed another device's is merged again with the newer library.
            for _ in 0..<3 {
                let remote = try await pullLibrary(token: token)
                let base = state.base?.accountID == accountID ? state.base : nil
                let local = Library.shared.syncSnapshot(preferences: SyncedPreferences.read())
                let merged = LibraryMerge.merge(local: local, base: base?.snapshot, remote: remote?.snapshot)
                if merged != local { apply(merged, over: local) }
                let upload = SyncLimits.uploadable(merged)
                if let remote, remote.snapshot == upload {
                    remember(remote, accountID: accountID)
                    break
                }
                if let saved = try await pushLibrary(upload, revision: remote?.revision ?? 0, token: token) {
                    remember(saved, accountID: accountID)
                    break
                }
            }
            lastSync = .now
            state.lastSync = lastSync
            state.save()
            syncState = .idle
        } catch AccountError.signedOut {
            endSession()
        } catch {
            syncState = .failed((error as? AccountError)?.message ?? AccountError.unreachable.message)
        }
        syncing = false
        // Asked for again while this one ran: once more, with what changed meanwhile.
        if syncAgain, isSignedIn {
            syncAgain = false
            await sync()
        }
    }

    private func apply(_ merged: LibrarySnapshot, over local: LibrarySnapshot) {
        applyingSync = true
        Library.shared.applySync(merged)
        SyncedPreferences.write(merged.preferences ?? [:], over: local.preferences ?? [:])
        lastPreferences = SyncedPreferences.read()
        applyingSync = false
    }

    private func remember(_ record: LibraryRecord, accountID: String) {
        state.base = StoredState.Base(accountID: accountID, revision: record.revision, snapshot: record.snapshot)
        state.save()
    }

    private struct LibraryRecord {
        var revision: Int
        var snapshot: LibrarySnapshot
    }

    private struct RecordResponse: Decodable {
        var revision: Int
        var data: LibrarySnapshot?
    }

    private func pullLibrary(token: String) async throws -> LibraryRecord? {
        struct Pull: Decodable { var record: RecordResponse? }
        let data = try await send("v1/sync/library", token: token)
        guard let record = try JSONDecoder().decode(Pull.self, from: data).record else { return nil }
        // A library deleted from the account (nil) is like none: the device's goes up again.
        return LibraryRecord(revision: record.revision, snapshot: record.data ?? .empty)
    }

    /// The saved library, or nil when another device wrote first (the sync merges again).
    private func pushLibrary(_ snapshot: LibrarySnapshot, revision: Int, token: String) async throws -> LibraryRecord? {
        struct Mutation: Encodable {
            var revision: Int
            var operationId: String
            var data: LibrarySnapshot
        }
        let body = try JSONEncoder().encode(Mutation(revision: revision, operationId: UUID().uuidString.lowercased(), data: snapshot))
        guard body.count < SyncLimits.bytes else { throw AccountError.tooLarge }
        do {
            let data = try await send("v1/sync/library/library", method: "PUT", body: body, token: token)
            let saved = try JSONDecoder().decode(RecordResponse.self, from: data)
            return LibraryRecord(revision: saved.revision, snapshot: saved.data ?? snapshot)
        } catch AccountError.conflict {
            return nil
        }
    }

    // MARK: Requests

    private struct Exchange: Decodable {
        var accountId: String
        var token: String
    }

    /// Its own session: nothing cached or kept in cookies, and bounded waits.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 90
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }()

    private func send(_ path: String, method: String = "GET", body: Data? = nil, token: String?) async throws -> Data {
        guard let origin else { throw AccountError.unreachable }
        var request = URLRequest(url: origin.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw AccountError.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw AccountError.unreachable }
        switch http.statusCode {
        case 200..<300: return data
        case 401 where token != nil: throw AccountError.signedOut
        case 409: throw AccountError.conflict
        case 413: throw AccountError.tooLarge
        default: throw AccountError.unreachable
        }
    }

    /// 32 random bytes, base64url: 43 characters, as the service expects.
    private static func randomToken() -> String {
        base64url(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

enum AccountError: Error {
    case signInFailed
    case signedOut
    case conflict
    case tooLarge
    case unreachable

    var message: String {
        switch self {
        case .signInFailed: return String(localized: "Accesso non riuscito. Riprova.")
        case .signedOut: return String(localized: "La sessione è scaduta: accedi di nuovo.")
        case .tooLarge: return String(localized: "La libreria è troppo grande per la sincronizzazione.")
        case .conflict, .unreachable: return String(localized: "Il servizio account non risponde. Riprova più tardi.")
        }
    }
}

/// What the app keeps about the account between launches, in Application Support (the token is in
/// the Keychain): the account's details for showing them offline, and the library as last agreed
/// with the account, which the next sync merges against.
private struct StoredState: Codable {
    struct Base: Codable {
        var accountID: String
        var revision: Int
        var snapshot: LibrarySnapshot
    }

    var accountID: String?
    var details: AccountService.Details?
    /// When the service last confirmed the details (and so Premium).
    var refreshedAt: Date?
    var lastSync: Date?
    var base: Base?
    /// Whether Premium can be bought, as the service last said.
    var premiumEnabled: Bool?

    private static var url: URL { Storage.support.appending(path: "account.json") }

    static func load() -> StoredState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(StoredState.self, from: data) else { return StoredState() }
        return state
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// The listening preferences the account keeps, the same on every device. Not the ones about a
/// device (the volume bar, diagnostics, the equalizer's live state) nor what's playing.
enum SyncedPreferences {
    private enum Kind { case bool, number, string }

    private static let keys: [String: Kind] = [
        Preferences.wifiQuality: .string,
        Preferences.cellularQuality: .string,
        Preferences.downloadQuality: .string,
        Preferences.spatialAudio: .bool,
        Preferences.preferDolby: .bool,
        Preferences.normalizeVolume: .bool,
        Preferences.skipLongMixes: .bool,
        Preferences.crossfade: .number,
        Preferences.songTransition: .string,
        Preferences.accent: .string,
        Preferences.dynamicColors: .bool,
        Preferences.interactiveArtwork: .bool,
        Preferences.lyricsStyle: .string,
        Preferences.lyricsSize: .string,
        Preferences.lyricsTranslate: .bool,
        Preferences.lyricsTranslationTarget: .string,
    ]

    /// The values set on this device (a preference never changed keeps its default, unsent).
    static func read(_ defaults: UserDefaults = .standard) -> [String: SyncValue] {
        var values: [String: SyncValue] = [:]
        for (key, kind) in keys {
            guard let value = defaults.object(forKey: key) else { continue }
            switch (kind, value) {
            case (.bool, let number as NSNumber) where CFGetTypeID(number) == CFBooleanGetTypeID():
                values[key] = .bool(number.boolValue)
            case (.number, let number as NSNumber) where CFGetTypeID(number) != CFBooleanGetTypeID():
                values[key] = .number(number.doubleValue)
            case (.string, let text as String):
                values[key] = .string(text)
            default:
                break
            }
        }
        return values
    }

    /// Sets the values that changed, each only with the type the app keeps it as.
    static func write(_ values: [String: SyncValue], over current: [String: SyncValue], _ defaults: UserDefaults = .standard) {
        for (key, value) in values where current[key] != value {
            switch (keys[key], value) {
            case (.bool?, .bool(let flag)): defaults.set(flag, forKey: key)
            case (.number?, .number(let number)): defaults.set(number, forKey: key)
            case (.string?, .string(let text)): defaults.set(text, forKey: key)
            default: break
            }
        }
    }
}

/// What Seaglass Premium unlocks, where Premium can be bought (see `AccountService.unlocks`).
enum PremiumFeature: String, Identifiable, CaseIterable {
    /// AutoMix, and the playlists' Mix it plays.
    case autoMix
    case playlistLinks
    case recognition
    case lyricsTranslation
    case karaoke
    case tempo

    var id: Self { self }

    var title: String {
        switch self {
        case .autoMix: return String(localized: "AutoMix")
        case .playlistLinks: return String(localized: "Importa playlist da link")
        case .recognition: return String(localized: "Riconosci un brano")
        case .lyricsTranslation: return String(localized: "Traduci i testi")
        case .karaoke: return String(localized: "Karaoke AI")
        case .tempo: return String(localized: "Tempo")
        }
    }

    var symbol: String {
        switch self {
        case .autoMix: return "waveform.path"
        case .playlistLinks: return "link"
        case .recognition: return "waveform.badge.magnifyingglass"
        case .lyricsTranslation: return "translate"
        case .karaoke: return "music.mic"
        case .tempo: return "metronome"
        }
    }
}
