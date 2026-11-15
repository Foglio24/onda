package com.onda.seaglass.spotify

import com.onda.seaglass.core.Http
import com.onda.seaglass.core.Paths
import com.onda.seaglass.core.tr
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Request
import kotlinx.coroutines.NonCancellable
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

class SpotifyLoginCancelled : IOException(tr("Accesso a Spotify annullato."))

/**
 * Signs in to Spotify through Microsoft Edge, which every Windows 11 computer has, and learns
 * how the web player asks for playlists.
 *
 * Edge runs with a profile of its own (in %LOCALAPPDATA%\Seaglass\Spotify, so the user's own Edge
 * is never touched) and with its DevTools port open on 127.0.0.1 only while Seaglass uses it.
 * The first time, a small Edge window shows Spotify's own sign-in page; the profile then keeps
 * the session, and later imports run Edge without a window. From the web player's traffic this
 * keeps the request headers (its token) and the two GraphQL queries it needs; Seaglass itself
 * never sees the password.
 */
object SpotifyBrowser {
    private const val HOME = "https://open.spotify.com/"
    private const val LIBRARY = "https://open.spotify.com/collection/playlists"
    private val LOGIN = "https://accounts.spotify.com/login?continue=" + java.net.URLEncoder.encode(HOME, Charsets.UTF_8)

    val profile: File get() = File(Paths.local, "Spotify")

    /** Whether someone signed in to Spotify on this computer before (the session may still have expired). */
    val hasProfile: Boolean get() = File(profile, "Default").isDirectory

    fun edge(): File? {
        System.getProperty("seaglass.edge")?.let { return File(it).takeIf(File::canExecute) }
        val windowsPaths = listOfNotNull(System.getenv("ProgramFiles(x86)"), System.getenv("ProgramFiles"), System.getenv("LOCALAPPDATA"))
            .map { File(it, "Microsoft\\Edge\\Application\\msedge.exe") }
        val others = listOf(File("/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"), File("/usr/bin/microsoft-edge"))
        return (windowsPaths + others).firstOrNull { it.isFile }
    }

    /** Forgets the Spotify session (the whole Edge profile). */
    suspend fun signOut() = withContext(Dispatchers.IO) { profile.deleteRecursively() }

    /**
     * Returns a reader for the user's playlists, asking them to sign in first when needed.
     * [status] gets short texts for the dialog.
     */
    suspend fun connect(status: (String) -> Unit): SpotifyWeb {
        val edge = edge() ?: throw IOException(tr("Microsoft Edge non è installato: serve per accedere a Spotify."))
        if (hasProfile) {
            status(tr("Lettura delle playlist da Spotify…"))
            Edge.session(edge, profile, visible = false) { browser -> if (browser.signedIn()) capture(browser) else null }
                ?.let { return it }
        }
        status(tr("Completa l'accesso nella finestra di Microsoft Edge…"))
        Edge.session(edge, profile, visible = true, url = LOGIN) { browser -> browser.waitForSignIn() }
        status(tr("Lettura delle playlist da Spotify…"))
        // The window closes once signed in; the rest happens out of sight.
        return Edge.session(edge, profile, visible = false) { browser ->
            if (!browser.signedIn()) throw SpotifyLoginCancelled()
            capture(browser)
        }
    }

    /** Opens the library and one playlist in the web player, noting its token and queries. */
    private suspend fun capture(browser: Edge): SpotifyWeb = coroutineScope {
        val page = browser.page
        val headers = ConcurrentHashMap<String, String>()
        val operations = ConcurrentHashMap<String, PathfinderOperation>()
        val requests = Channel<JSONObject>(Channel.UNLIMITED)
        page.onEvent = { method, params ->
            if (method == "Network.requestWillBeSent" && params.optJSONObject("request")?.optString("url").orEmpty().contains("/pathfinder/")) {
                requests.trySend(params)
            }
        }
        val reader = launch {
            for (params in requests) {
                val request = params.getJSONObject("request")
                val sent = request.optJSONObject("headers") ?: JSONObject()
                if (sent.keys().asSequence().any { it.equals("authorization", ignoreCase = true) }) {
                    sent.keys().forEach { name -> if (keep(name)) headers[name.lowercase()] = sent.optString(name) }
                }
                var body = request.optString("postData").ifEmpty { null }
                if (body == null && request.optBoolean("hasPostData")) {
                    body = runCatching {
                        page.send("Network.getRequestPostData", JSONObject().put("requestId", params.optString("requestId"))).optString("postData")
                    }.getOrNull()
                }
                parseOperation(request.optString("url"), body)?.let { operations.putIfAbsent(it.name, it) }
            }
        }
        page.send("Network.enable")
        page.send("Page.navigate", JSONObject().put("url", LIBRARY))
        val library = withTimeoutOrNull(30_000) {
            while (headers["authorization"] == null || operations.keys.none(::isLibrary)) delay(250)
            operations.entries.first { isLibrary(it.key) }.value
        } ?: run {
            reader.cancel()
            throw IOException(tr("Spotify non ha risposto correttamente. Riprova più tardi."))
        }
        // The query for a playlist's songs only runs when a playlist opens: open the first one.
        val first = SpotifyWeb(HashMap(headers).withAgent(browser.userAgent), library, null).playlists().firstOrNull()
        var playlist: PathfinderOperation? = null
        if (first != null) {
            page.send("Page.navigate", JSONObject().put("url", HOME + "playlist/" + first.uri.substringAfterLast(':')))
            playlist = withTimeoutOrNull(30_000) {
                while (operations.keys.none(::isPlaylist)) delay(250)
                operations.entries.filter { isPlaylist(it.key) }.minBy { it.key.length }.value
            }
        }
        reader.cancel()
        requests.close()
        SpotifyWeb(HashMap(headers).withAgent(browser.userAgent), library, playlist)
    }

    private fun isLibrary(name: String) = Regex("^libraryV\\d+$").matches(name)
    // "fetchPlaylist" and variants of it ("fetchPlaylistContents"), but not its metadata alone.
    private fun isPlaylist(name: String) = name.startsWith("fetchPlaylist") && !name.contains("Metadata")

    /** Headers worth replaying: not the ones the connection itself sets. */
    private fun keep(name: String): Boolean {
        val lower = name.lowercase()
        return !lower.startsWith(":") && lower !in setOf("host", "content-length", "accept-encoding", "cookie", "connection", "content-type")
    }

    private fun Map<String, String>.withAgent(agent: String?): Map<String, String> =
        if (agent == null) this else this + ("user-agent" to agent)

    private fun parseOperation(url: String, body: String?): PathfinderOperation? = runCatching {
        val (name, variables, extensions) = if (body != null) {
            val json = JSONObject(body)
            Triple(json.optString("operationName"), json.optJSONObject("variables"), json.optJSONObject("extensions"))
        } else {
            val parsed = url.toHttpUrlOrNull() ?: return null
            Triple(
                parsed.queryParameter("operationName").orEmpty(),
                parsed.queryParameter("variables")?.let(::JSONObject),
                parsed.queryParameter("extensions")?.let(::JSONObject),
            )
        }
        val hash = extensions?.optJSONObject("persistedQuery")?.optString("sha256Hash").orEmpty()
        if (name.isEmpty() || hash.isEmpty()) null
        else PathfinderOperation(name, hash, url.substringBefore('?'), variables ?: JSONObject())
    }.getOrNull()
}

/** One run of Edge with its DevTools port, closed cleanly so the profile keeps its cookies. */
private class Edge(private val process: Process, private val port: Int, private val browserSocket: String, val page: Cdp) {
    var userAgent: String? = null
        private set

    /** Spotify's session cookie: present once someone is signed in. */
    suspend fun signedIn(): Boolean {
        val cookies = page.send("Network.getCookies", JSONObject().put("urls", JSONArray().put("https://open.spotify.com/")))
            .optJSONArray("cookies") ?: return false
        return (0 until cookies.length()).any { cookies.optJSONObject(it)?.optString("name") == "sp_dc" }
    }

    /** Waits (up to ten minutes) for the sign-in to finish, or for the window to be closed. */
    suspend fun waitForSignIn() {
        val deadline = System.currentTimeMillis() + 10 * 60_000
        while (System.currentTimeMillis() < deadline) {
            if (!process.isAlive) throw SpotifyLoginCancelled()
            // The page's connection breaks when its window is closed, even if Edge stays in the background.
            if (runCatching { signedIn() }.getOrElse { throw SpotifyLoginCancelled() }) return
            delay(1000)
        }
        throw SpotifyLoginCancelled()
    }

    suspend fun shutdown() = withContext(Dispatchers.IO + NonCancellable) {
        // Browser.close lets Edge write its cookies to disk; killing it could lose the session.
        withTimeoutOrNull(5_000) {
            runCatching {
                val browser = Cdp.connect("ws://127.0.0.1:$port$browserSocket")
                runCatching { browser.send("Browser.close", timeoutMs = 3_000) }
                browser.close()
            }
        }
        page.close()
        if (!process.waitFor(5, TimeUnit.SECONDS)) process.destroyForcibly()
    }

    companion object {
        /** Runs [block] with Edge open, then always closes it. */
        suspend fun <T> session(edge: File, profile: File, visible: Boolean, url: String = "about:blank", block: suspend (Edge) -> T): T {
            val browser = launch(edge, profile, visible, url)
            try {
                return block(browser)
            } finally {
                browser.shutdown()
            }
        }

        private suspend fun launch(edge: File, profile: File, visible: Boolean, url: String = "about:blank"): Edge = withContext(Dispatchers.IO) {
            profile.mkdirs()
            val portFile = File(profile, "DevToolsActivePort").apply { delete() }
            val arguments = mutableListOf(
                edge.path,
                "--user-data-dir=${profile.path}",
                // Port 0: Edge picks a free one and writes it to DevToolsActivePort.
                "--remote-debugging-port=0",
                "--remote-debugging-address=127.0.0.1",
                "--no-first-run",
                "--no-default-browser-check",
                "--disable-sync",
            )
            if (visible) arguments += listOf("--app=$url", "--window-size=520,760") else arguments += listOf("--headless=new", url)
            val process = ProcessBuilder(arguments)
                .redirectOutput(ProcessBuilder.Redirect.DISCARD)
                .redirectError(ProcessBuilder.Redirect.DISCARD)
                .start()
            try {
                val lines = withTimeoutOrNull(20_000) {
                    while (!portFile.isFile || portFile.readLines().size < 2) {
                        // Edge exits at once when another Edge already uses this profile (a previous run left open).
                        if (!process.isAlive) throw IOException(tr("Importazione non riuscita"))
                        delay(200)
                    }
                    portFile.readLines()
                } ?: throw IOException("Edge: DevTools did not start")
                val port = lines[0].trim().toInt()
                val targets = JSONArray(Http.text(Request.Builder().url("http://127.0.0.1:$port/json/list").build()))
                val target = (0 until targets.length()).map { targets.getJSONObject(it) }.first { it.optString("type") == "page" }
                val page = Cdp.connect(target.getString("webSocketDebuggerUrl"))
                val edgeInstance = Edge(process, port, lines[1].trim(), page)
                if (!visible) {
                    // Headless Edge says so in its user agent; Spotify should see an ordinary Edge.
                    val agent = page.send("Browser.getVersion").optString("userAgent")
                        .replace("HeadlessChrome", "Chrome").replace("HeadlessEdg", "Edg")
                    if (agent.isNotEmpty()) {
                        page.send("Network.setUserAgentOverride", JSONObject().put("userAgent", agent))
                        edgeInstance.userAgent = agent
                    }
                }
                edgeInstance
            } catch (error: Throwable) {
                process.destroyForcibly()
                throw error
            }
        }
    }
}
