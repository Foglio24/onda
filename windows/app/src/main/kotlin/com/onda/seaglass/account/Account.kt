package com.onda.seaglass.account

import com.onda.seaglass.BuildConfig
import com.onda.seaglass.core.Http
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.awt.Desktop
import java.net.URI
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit

/**
 * Seaglass account via the website (same PKCE flow as iPhone/Mac): open the page, receive a code on
 * `com.onda.player.auth:/callback`, exchange it, keep the session, sync the library.
 */
object Account {
    data class Details(
        val id: String,
        val email: String,
        val displayName: String?,
        val premium: Boolean,
    )

    sealed class SyncState {
        data object Idle : SyncState()
        data object Syncing : SyncState()
        data class Failed(val message: String) : SyncState()
    }

    private val origin = BuildConfig.ACCOUNT_ORIGIN.trimEnd('/')
    private val _signedIn = MutableStateFlow(SecureStore.readToken() != null)
    private val _details = MutableStateFlow<Details?>(null)
    private val _sync = MutableStateFlow<SyncState>(SyncState.Idle)
    private val _signInError = MutableStateFlow<String?>(null)
    private val _premiumEnabled = MutableStateFlow(false)

    val isSignedIn: StateFlow<Boolean> = _signedIn.asStateFlow()
    val details: StateFlow<Details?> = _details.asStateFlow()
    val syncState: StateFlow<SyncState> = _sync.asStateFlow()
    val signInError: StateFlow<String?> = _signInError.asStateFlow()
    val premiumEnabled: StateFlow<Boolean> = _premiumEnabled.asStateFlow()

    private var pendingState: String? = null
    private var pendingFuture: CompletableFuture<String>? = null

    val manageUrl: String get() = "$origin/account"

    fun setSyncState(state: SyncState) {
        _sync.value = state
    }

    suspend fun refresh() = withContext(Dispatchers.IO) {
        val token = SecureStore.readToken() ?: run {
            _signedIn.value = false
            _details.value = null
            return@withContext
        }
        try {
            val status = JSONObject(Http.text(Http.jsonRequest("$origin/v1/status", bearer = token)))
            _premiumEnabled.value = status.optBoolean("premiumEnabled", false)
            val account = JSONObject(Http.text(Http.jsonRequest("$origin/v1/account", bearer = token)))
            val profile = account.optJSONObject("profile")
            val membership = account.optJSONObject("membership")
            _details.value = Details(
                id = account.getString("id"),
                email = account.getString("email"),
                displayName = profile?.optString("displayName")?.takeIf { it.isNotBlank() },
                premium = membership?.optBoolean("premium", false) == true,
            )
            _signedIn.value = true
        } catch (e: Exception) {
            if (e.message?.contains("401") == true || e.message?.contains("403") == true) {
                signOut()
            }
        }
    }

    /**
     * Opens the account page in the browser. Completes when [handleCallback] receives the code
     * (protocol handler or pasted deep link).
     */
    suspend fun signIn() = withContext(Dispatchers.IO) {
        _signInError.value = null
        val verifier = randomToken()
        val state = randomToken()
        val challenge = base64url(sha256(verifier.toByteArray()))
        pendingState = state
        val future = CompletableFuture<String>()
        pendingFuture = future
        val url = "$origin/v1/auth/start?challenge=$challenge&state=$state"
        try {
            Desktop.getDesktop().browse(URI(url))
            val code = future.get(5, TimeUnit.MINUTES)
            val body = JSONObject().put("code", code).put("verifier", verifier).toString()
            val response = JSONObject(
                Http.text(Http.jsonRequest("$origin/v1/auth/exchange", method = "POST", json = body))
            )
            val token = response.getString("token")
            SecureStore.writeToken(token)
            _signedIn.value = true
            refresh()
            LibrarySync.pushAndPull()
        } catch (e: Exception) {
            _signInError.value = e.message ?: e.toString()
        } finally {
            pendingState = null
            pendingFuture = null
        }
    }

    /** Called when Windows delivers `com.onda.player.auth:/callback?code=&state=`. */
    fun handleCallback(uri: String): Boolean {
        val parsed = runCatching { URI(uri) }.getOrNull() ?: return false
        if (parsed.scheme != "com.onda.player.auth") return false
        val query = parsed.rawQuery.orEmpty().split("&").associate {
            val parts = it.split("=", limit = 2)
            parts[0] to (parts.getOrNull(1)?.let { v ->
                java.net.URLDecoder.decode(v, Charsets.UTF_8)
            } ?: "")
        }
        val code = query["code"] ?: return false
        val state = query["state"]
        if (state != null && pendingState != null && state != pendingState) return false
        pendingFuture?.complete(code)
        return true
    }

    fun signOut() {
        val token = SecureStore.readToken()
        SecureStore.clear()
        _signedIn.value = false
        _details.value = null
        if (token != null) {
            runCatching {
                Http.text(Http.jsonRequest("$origin/v1/session", method = "DELETE", bearer = token))
            }
        }
    }

    suspend fun signedInManageUrl(): String = withContext(Dispatchers.IO) {
        val token = SecureStore.readToken() ?: return@withContext manageUrl
        runCatching {
            val body = JSONObject().put("view", "account").toString()
            val response = JSONObject(
                Http.text(Http.jsonRequest("$origin/v1/auth/web-link", method = "POST", json = body, bearer = token))
            )
            response.getString("url")
        }.getOrDefault(manageUrl)
    }

    private fun randomToken(): String {
        val bytes = ByteArray(32)
        SecureRandom().nextBytes(bytes)
        return base64url(bytes)
    }

    private fun sha256(data: ByteArray): ByteArray =
        MessageDigest.getInstance("SHA-256").digest(data)

    private fun base64url(data: ByteArray): String =
        Base64.getUrlEncoder().withoutPadding().encodeToString(data)
}
