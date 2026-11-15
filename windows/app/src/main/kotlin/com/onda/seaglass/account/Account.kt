package com.onda.seaglass.account

import com.onda.seaglass.core.Http
import com.onda.seaglass.core.HttpException
import com.onda.seaglass.core.Paths
import com.onda.seaglass.core.tr
import com.onda.seaglass.data.Library
import com.sun.jna.platform.win32.Crypt32Util
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.awt.Desktop
import java.io.File
import java.net.URI
import java.net.URLEncoder
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import java.util.UUID

/**
 * The session token, kept with Windows's own protection for the user's secrets (DPAPI, as the
 * Keychain on the iPhone): the file is readable only by this Windows user on this computer. Off
 * Windows (development, tests) it is kept in memory only, never written in the clear.
 */
object SecureStore {
    private val windows = System.getProperty("os.name").orEmpty().lowercase().contains("win")
    private val memory = HashMap<String, String>()

    private fun file(name: String) = File(Paths.data, "$name.dpapi")

    fun get(name: String): String? {
        if (!windows) return synchronized(memory) { memory[name] }
        return runCatching { String(Crypt32Util.cryptUnprotectData(file(name).readBytes()), Charsets.UTF_8) }.getOrNull()
    }

    fun set(name: String, value: String?) {
        if (!windows) {
            synchronized(memory) { if (value == null) memory.remove(name) else memory[name] = value }
            return
        }
        if (value == null) {
            file(name).delete()
        } else {
            file(name).writeBytes(Crypt32Util.cryptProtectData(value.toByteArray(Charsets.UTF_8)))
        }
    }
}

/**
 * The Seaglass account, as on the iPhone (Account.swift): the app signs in through the account
 * page in the browser, which hands back a one-time code on `com.onda.player.auth:/callback` that
 * only the verifier this app made can exchange (PKCE). The token is kept with [SecureStore]. The
 * library syncs with the account, merged by [LibraryMerge]. Everything else is managed on the page.
 */
object Account {
    const val ORIGIN = "https://account.mystudioappweb.com"
    const val CALLBACK = "com.onda.player.auth:/callback"

    data class Details(val email: String, val name: String?, val plan: String?, val premium: Boolean)

    sealed interface Sync {
        data object Idle : Sync
        data object Syncing : Sync
        data class Failed(val message: String) : Sync
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val stateFile by lazy { File(Paths.data, "account-sync.json") }

    private val _signedIn = MutableStateFlow(false)
    val signedIn: StateFlow<Boolean> = _signedIn
    private val _details = MutableStateFlow<Details?>(null)
    val details: StateFlow<Details?> = _details
    private val _sync = MutableStateFlow<Sync>(Sync.Idle)
    val sync: StateFlow<Sync> = _sync
    private val _lastSync = MutableStateFlow<Long?>(null)
    val lastSync: StateFlow<Long?> = _lastSync
    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error
    private val _premiumEnabled = MutableStateFlow(false)
    /** Premium can be bought (the service says so): only then are Premium features locked, as on the iPhone. */
    val premiumEnabled: StateFlow<Boolean> = _premiumEnabled
    private val _waiting = MutableStateFlow(false)
    /** The browser is open on the sign-in page. */
    val waiting: StateFlow<Boolean> = _waiting

    private var pendingVerifier: String? = null
    private var pendingState: String? = null
    private val syncLock = Mutex()
    private var applying = false
    private var watcher: Job? = null

    private val token: String? get() = SecureStore.get("account.token")

    fun init() {
        _signedIn.value = token != null
        val stored = readState()
        _lastSync.value = stored.optLong("lastSync").takeIf { it > 0 }
        // The last answers, so an offline launch locks and unlocks as before.
        _premiumEnabled.value = stored.optBoolean("premiumEnabled", false)
        if (stored.optBoolean("premium", false) && _signedIn.value) _details.value = Details("", null, null, premium = true)
        scope.launch { refreshStatus() }
        if (_signedIn.value) {
            scope.launch {
                refresh()
                syncNow()
            }
        }
        watchLibrary()
    }

    // MARK: Signing in

    fun signIn() {
        val verifier = random()
        val state = random()
        pendingVerifier = verifier
        pendingState = state
        val challenge = base64url(MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray()))
        val url = "$ORIGIN/v1/auth/start?challenge=${encode(challenge)}&state=${encode(state)}"
        _error.value = null
        _waiting.value = true
        runCatching { Desktop.getDesktop().browse(URI(url)) }.onFailure {
            _waiting.value = false
            _error.value = tr("Impossibile aprire il browser.")
        }
    }

    /** The page's callback, handed to the app by Windows (the installer registers the address). */
    fun handleCallback(link: String) {
        if (!link.startsWith(CALLBACK)) return
        val query = link.substringAfter('?', "").split('&').mapNotNull { part ->
            val (key, value) = part.split('=', limit = 2).takeIf { it.size == 2 } ?: return@mapNotNull null
            key to java.net.URLDecoder.decode(value, Charsets.UTF_8)
        }.toMap()
        val verifier = pendingVerifier
        // Only the sign-in this app started: its state, once.
        if (verifier == null || query["state"] != pendingState) return
        val code = query["code"] ?: return
        pendingVerifier = null
        pendingState = null
        scope.launch {
            try {
                val body = JSONObject().put("code", code).put("verifier", verifier).toString()
                val response = JSONObject(send("v1/auth/exchange", "POST", body, null))
                val received = response.optString("token").takeIf { it.isNotEmpty() } ?: throw IllegalStateException()
                SecureStore.set("account.token", received)
                writeState(JSONObject().put("accountId", response.optString("accountId")))
                _signedIn.value = true
                _waiting.value = false
                refresh()
                syncNow()
            } catch (e: Exception) {
                _waiting.value = false
                _error.value = tr("Accesso non riuscito. Riprova.")
            }
        }
    }

    /** Whether a Premium feature can be used: Premium isn't on sale yet, or this account has it. */
    fun unlocks(): Boolean = !_premiumEnabled.value || (_signedIn.value && _details.value?.premium == true)

    private suspend fun refreshStatus() {
        runCatching {
            val enabled = JSONObject(send("v1/status", "GET", null, null)).optBoolean("premiumEnabled", false)
            _premiumEnabled.value = enabled
            writeState(readState().put("premiumEnabled", enabled))
        }
    }

    suspend fun refresh() {
        val token = token ?: return
        try {
            val account = JSONObject(send("v1/account", "GET", null, token))
            val profile = account.optJSONObject("profile")
            val membership = account.optJSONObject("membership")
            val name = profile?.optString("displayName")?.takeIf { it.isNotBlank() }
                ?: listOfNotNull(profile?.optString("firstName"), profile?.optString("lastName")).filter { it.isNotBlank() }.joinToString(" ").ifBlank { null }
            _details.value = Details(
                email = account.optString("email"),
                name = name,
                plan = membership?.optString("status")?.takeIf { it.isNotBlank() },
                premium = membership?.optBoolean("premium") == true,
            )
            writeState(readState().put("premium", _details.value?.premium == true))
        } catch (e: HttpException) {
            if (e.status == 401) endSession()
        } catch (_: Exception) {
        }
    }

    /** The account page in the browser, signed in (a link that works once, within a minute); [premium] opens its Premium part. */
    fun openAccountPage(premium: Boolean = false) {
        scope.launch {
            val token = token
            val body = JSONObject().apply { if (premium) put("view", "premium") }.toString()
            val url = token?.let {
                runCatching { JSONObject(send("v1/auth/web-link", "POST", body, it)).optString("url") }.getOrNull()
            }?.takeIf { it.startsWith("$ORIGIN/") } ?: "$ORIGIN/account"
            runCatching { Desktop.getDesktop().browse(URI(url)) }
        }
    }

    fun signOut() {
        val token = token
        scope.launch {
            if (token != null) runCatching { send("v1/session", "DELETE", null, token) }
            endSession()
        }
    }

    private fun endSession() {
        SecureStore.set("account.token", null)
        _signedIn.value = false
        _details.value = null
        // The library stays on this computer; only the record of what was last agreed goes.
        writeState(JSONObject().put("premiumEnabled", _premiumEnabled.value))
    }

    // MARK: Sync

    /** Liked songs and playlists go up a few seconds after they change; the history with them. */
    @OptIn(FlowPreview::class)
    private fun watchLibrary() {
        watcher?.cancel()
        watcher = scope.launch {
            combine(Library.liked, Library.playlists, Library.history) { _, _, _ -> }
                .drop(1)
                .debounce(4_000)
                .collect { if (!applying && _signedIn.value) syncNow() }
        }
    }

    fun syncNow() {
        scope.launch { sync() }
    }

    private suspend fun sync() = syncLock.withLock {
        val token = token ?: return@withLock
        _sync.value = Sync.Syncing
        try {
            val stored = readState()
            val accountId = stored.optString("accountId")
            // A write that crossed another device's is merged again with the newer library.
            for (attempt in 0 until 3) {
                val remoteRecord = JSONObject(send("v1/sync/library", "GET", null, token)).optJSONObject("record")
                // A library deleted from the account (no data) is like none: this computer's goes up again.
                val remote = remoteRecord?.let { LibrarySnapshot.fromJson(it.optJSONObject("data")) }
                val revision = remoteRecord?.optInt("revision") ?: 0
                val base = stored.optJSONObject("base")?.takeIf { stored.optString("baseAccount") == accountId }?.let { LibrarySnapshot.fromJson(it) }
                val local = Library.snapshot().copy(preferences = remote?.preferences)
                val merged = LibraryMerge.merge(local, base, remote)
                if (!merged.sameAs(local)) apply(merged)
                val upload = LibraryMerge.uploadable(merged)
                if (remote != null && remote.sameAs(upload)) {
                    remember(remote, accountId)
                    break
                }
                val body = JSONObject().put("revision", revision).put("operationId", UUID.randomUUID().toString()).put("data", upload.toJson()).toString()
                if (body.length >= 1_900_000) throw IllegalStateException(tr("La libreria è troppo grande per l'account."))
                val saved = try {
                    JSONObject(send("v1/sync/library/library", "PUT", body, token))
                } catch (e: HttpException) {
                    // Another device wrote first: merged again with its library.
                    if (e.status == 409) null else throw e
                }
                if (saved != null) {
                    remember(LibrarySnapshot.fromJson(saved.optJSONObject("data") ?: upload.toJson()), accountId)
                    break
                }
            }
            finish()
        } catch (e: HttpException) {
            if (e.status == 401) endSession()
            _sync.value = Sync.Failed(tr("Sincronizzazione non riuscita."))
        } catch (e: Exception) {
            _sync.value = Sync.Failed(e.message ?: tr("Sincronizzazione non riuscita."))
        }
    }

    private fun finish() {
        val now = System.currentTimeMillis()
        _lastSync.value = now
        writeState(readState().put("lastSync", now))
        _sync.value = Sync.Idle
    }

    private fun apply(merged: LibrarySnapshot) {
        applying = true
        try {
            Library.applySync(merged.liked, merged.playlists, merged.history)
        } finally {
            applying = false
        }
    }

    private fun remember(record: LibrarySnapshot, accountId: String) {
        writeState(readState().put("base", record.toJson()).put("baseAccount", accountId))
    }

    /**
     * Lyrics in [target] (the account service translates them, as the iPhone does on the device):
     * the HTTP status and the service's answer; 0 when not signed in.
     */
    fun translate(lines: List<String>, target: String): Pair<Int, JSONObject?> {
        val token = token ?: return 0 to null
        val body = JSONObject().put("lines", org.json.JSONArray(lines)).put("target", target).toString()
        val request = Request.Builder().url("$ORIGIN/v1/translate").header("Accept", "application/json")
            .header("Authorization", "Bearer $token").post(body.toRequestBody("application/json".toMediaType())).build()
        Http.client.newCall(request).execute().use { response ->
            return response.code to runCatching { JSONObject(response.body.string()) }.getOrNull()
        }
    }

    // MARK: Requests and storage

    private fun send(path: String, method: String, body: String?, token: String?): String {
        val builder = Request.Builder().url("$ORIGIN/$path").header("Accept", "application/json")
        if (token != null) builder.header("Authorization", "Bearer $token")
        val requestBody = body?.toRequestBody("application/json".toMediaType())
        builder.method(method, requestBody ?: if (method == "POST" || method == "PUT") "".toRequestBody() else null)
        Http.client.newCall(builder.build()).execute().use { response ->
            if (!response.isSuccessful) throw HttpException(response.code)
            return response.body.string()
        }
    }

    @Synchronized private fun readState(): JSONObject = runCatching { JSONObject(stateFile.readText()) }.getOrElse { JSONObject() }

    @Synchronized private fun writeState(state: JSONObject) {
        val temporary = File(stateFile.parentFile, stateFile.name + ".tmp")
        temporary.writeText(state.toString())
        java.nio.file.Files.move(temporary.toPath(), stateFile.toPath(), java.nio.file.StandardCopyOption.REPLACE_EXISTING)
    }

    private fun random(): String = base64url(ByteArray(32).also { SecureRandom().nextBytes(it) })
    private fun base64url(bytes: ByteArray) = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
    private fun encode(text: String) = URLEncoder.encode(text, Charsets.UTF_8)
}
