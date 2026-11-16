import Foundation
import WebKit

/// Signs in to Spotify in a web view (its own page: Seaglass never sees the password) and learns how
/// the web player asks for playlists. The web view keeps its own cookies in a data store of its own,
/// so the sign-in lasts and "Esci da Spotify" forgets it without touching anything else.
///
/// The first time, Spotify's sign-in page is shown; later imports run on the already signed-in page
/// behind a "Lettura…" cover. From the player's traffic (SpotifyHook) it keeps the request headers
/// (its token) and the two queries it needs, then sends them from inside the page.
@MainActor
final class SpotifySession: NSObject, ObservableObject {
    static let shared = SpotifySession()

    private static let home = "https://open.spotify.com/"
    private static let library = "https://open.spotify.com/collection/playlists"
    private static let login = "https://accounts.spotify.com/login?continue=" +
        (home.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? home)
    /// A desktop browser's name: with a phone's, Spotify's page asks to open the app instead of playing.
    private static let desktopAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    /// Fixed, so the web view finds the same sign-in again.
    private static let storeID = UUID(uuidString: "5EA61A55-0B0E-4F5B-8E0C-5E0C1D5A1D01")!

    /// Whether the page is Spotify's own sign-in (shown) or the player being read (covered).
    @Published private(set) var showsLogin = false

    private(set) lazy var webView: WKWebView = makeWebView()
    private var headers: [String: String] = [:]
    private var operations: [String: PathfinderOperation] = [:]

    private static let dataStore = WKWebsiteDataStore(forIdentifier: storeID)

    private override init() { super.init() }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = Self.dataStore
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        configuration.userContentController.addUserScript(
            WKUserScript(source: SpotifyHook.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.add(MessageRelay(self), name: SpotifyHook.handlerName)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.customUserAgent = Self.desktopAgent
        view.navigationDelegate = self
        view.uiDelegate = self
        return view
    }

    // MARK: Signing in

    /// Spotify's session cookie: present once someone is signed in.
    func isSignedIn() async -> Bool {
        let cookies = await Self.dataStore.httpCookieStore.allCookies()
        return cookies.contains { $0.name == "sp_dc" && $0.domain.hasSuffix("spotify.com") }
    }

    /// Stops the player (it would keep running, and show up as a Spotify device, while Seaglass is open).
    /// The sign-in stays in the cookies; the next import loads the page again.
    func close() {
        showsLogin = false
        headers = [:]
        operations = [:]
        webView.stopLoading()
        load("about:blank")
    }

    /// Forgets the Spotify session (cookies and everything else the page kept).
    func signOut() async {
        close()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await Self.dataStore.removeData(ofTypes: types, modifiedSince: .distantPast)
    }

    /// Returns a reader for the user's playlists, asking them to sign in first when needed.
    /// [status] gets short texts for the sheet.
    func connect(status: (String) -> Void) async throws -> SpotifyWeb {
        headers = [:]
        operations = [:]
        showsLogin = false
        if await !isSignedIn() {
            showsLogin = true
            defer { showsLogin = false }
            status(String(localized: "Completa l'accesso a Spotify qui sotto."))
            load(Self.login)
            try await waitForSignIn()
        }
        status(String(localized: "Lettura delle playlist da Spotify…"))
        return try await capture()
    }

    /// Waits (up to ten minutes) for the sign-in to finish, or for the sheet to be closed.
    private func waitForSignIn() async throws {
        let deadline = Date().addingTimeInterval(10 * 60)
        while Date() < deadline {
            try Task.checkCancellation()
            if await isSignedIn() { return }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw SpotifyImportError.cancelled
    }

    // MARK: Learning the player's queries

    private func load(_ address: String) {
        guard let url = URL(string: address) else { return }
        webView.load(URLRequest(url: url))
    }

    /// Opens the library and one playlist in the web player, noting its token and queries.
    private func capture() async throws -> SpotifyWeb {
        load(Self.library)
        let libraryOperation: PathfinderOperation = try await waitFor(seconds: 30) { [self] () -> PathfinderOperation? in
            guard headers["authorization"] != nil else { return nil }
            return operations.values.first { Self.isLibrary($0.name) }
        }
        let reader = SpotifyWeb(transport: self, headers: headers, library: libraryOperation, playlist: nil)
        // The query for a playlist's songs only runs when a playlist opens: open the first one.
        var playlistOperation: PathfinderOperation?
        if let first = try await reader.playlists().first, let id = first.uri.components(separatedBy: ":").last {
            load(Self.home + "playlist/" + id)
            playlistOperation = try? await waitFor(seconds: 30) { [self] () -> PathfinderOperation? in
                operations.values.filter { Self.isPlaylist($0.name) }.min { $0.name.count < $1.name.count }
            }
        }
        return SpotifyWeb(transport: self, headers: headers, library: libraryOperation, playlist: playlistOperation)
    }

    private static func isLibrary(_ name: String) -> Bool {
        name.range(of: #"^libraryV\d+$"#, options: .regularExpression) != nil
    }

    /// "fetchPlaylist" and variants of it ("fetchPlaylistContents"), but not its metadata alone.
    private static func isPlaylist(_ name: String) -> Bool {
        name.hasPrefix("fetchPlaylist") && !name.contains("Metadata")
    }

    private func waitFor<T>(seconds: Double, _ found: () -> T?) async throws -> T {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try Task.checkCancellation()
            if let value = found() { return value }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw SpotifyImportError.unavailable
    }

    /// Headers worth replaying: not the ones the connection itself sets.
    private static func keeps(_ name: String) -> Bool {
        let lower = name.lowercased()
        return !lower.hasPrefix(":") &&
            !["host", "content-length", "accept-encoding", "cookie", "connection", "content-type"].contains(lower)
    }

    fileprivate func note(_ message: [String: Any]) {
        guard let url = message["url"] as? String, url.contains("/pathfinder/") else { return }
        let sent = (message["headers"] as? [String: Any]) ?? [:]
        if sent.keys.contains(where: { $0.lowercased() == "authorization" }) {
            for (name, value) in sent where Self.keeps(name) { headers[name.lowercased()] = "\(value)" }
        }
        if let operation = PathfinderOperation.parse(url: url, body: message["body"] as? String) {
            operations[operation.name] = operation
        }
    }
}

extension SpotifySession: SpotifyTransport {
    /// Sent from the signed-in page itself, so it is exactly what the player would send.
    func send(_ request: SpotifyHTTPRequest) async throws -> SpotifyHTTPResponse {
        var payload: [String: Any] = ["method": request.method, "url": request.url.absoluteString, "headers": request.headers]
        payload["body"] = request.body ?? NSNull()
        let result = try await webView.callAsyncJavaScript(SpotifyHook.sendScript, arguments: ["request": payload],
                                                           in: nil, contentWorld: .page)
        guard let reply = result as? [String: Any], let status = (reply["status"] as? NSNumber)?.intValue else {
            throw SpotifyImportError.unavailable
        }
        return SpotifyHTTPResponse(status: status, retryAfter: (reply["retryAfter"] as? NSNumber)?.doubleValue,
                                   body: reply["body"] as? String ?? "")
    }
}

/// The web view keeps its message handler strongly: this keeps the session from being kept with it.
private final class MessageRelay: NSObject, WKScriptMessageHandler {
    private weak var session: SpotifySession?
    init(_ session: SpotifySession) { self.session = session }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        Task { @MainActor in self.session?.note(body) }
    }
}

extension SpotifySession: WKNavigationDelegate, WKUIDelegate {
    /// Only web pages: Spotify's own pages try to open its app (spotify:…), which would leave Seaglass.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let scheme = navigationAction.request.url?.scheme?.lowercased() else { return .allow }
        return ["http", "https", "about", "blob", "data"].contains(scheme) ? .allow : .cancel
    }

    /// A link that wants a window of its own (a sign-in's "continue") opens in this one.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url,
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            webView.load(navigationAction.request)
        }
        return nil
    }
}
