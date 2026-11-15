package com.onda.seaglass.data

import com.onda.seaglass.account.SecureStore
import com.onda.seaglass.core.Http
import com.onda.seaglass.core.Paths
import com.onda.seaglass.core.Prefs
import com.onda.seaglass.core.tr
import com.onda.seaglass.model.Track
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import okhttp3.FormBody
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.net.URLEncoder
import java.security.MessageDigest

/**
 * Last.fm, as on the iPhone (LastFM.swift): the user's own API key and shared secret, a session
 * authorised in the browser, "now playing" and scrobbles after half the song or 4 minutes. The
 * secret and the session key are kept with DPAPI (never in settings or logs); scrobbles that
 * can't go now wait in a file and go in batches of 50.
 */
object LastFM {
    private const val ENDPOINT = "https://ws.audioscrobbler.com/2.0/"
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val outbox = Mutex()
    private val pendingFile by lazy { File(Paths.data, "lastfm-pending.json") }

    private val _username = MutableStateFlow<String?>(null)
    val username: StateFlow<String?> = _username
    private val _pending = MutableStateFlow(0)
    val pending: StateFlow<Int> = _pending
    val scrobbling = Prefs.Setting("lastfm.scrobbling", true) { s, k, d -> s.boolean(k, d) }

    val apiKey: String get() = Prefs.store.string("lastfm.apiKey").orEmpty()
    private val secret: String get() = SecureStore.get("lastfm.secret").orEmpty()
    private val session: String? get() = SecureStore.get("lastfm.session")
    private var pendingToken: String? = null

    val hasCredentials: Boolean get() = apiKey.isNotEmpty() && secret.isNotEmpty()

    fun init() {
        _username.value = Prefs.store.string("lastfm.username")?.takeIf { session != null }
        _pending.value = readPending().length()
        scope.launch { flush() }
    }

    fun saveCredentials(key: String, sharedSecret: String) {
        val changed = key.trim() != apiKey || sharedSecret.trim() != secret
        if (changed) signOut()
        Prefs.store.set("lastfm.apiKey", key.trim())
        SecureStore.set("lastfm.secret", sharedSecret.trim().ifEmpty { null })
    }

    /** Step 1: a token, and the page where the user allows Seaglass. */
    suspend fun beginAuth(): String {
        val json = call("auth.getToken", signed = true)
        val token = json.optString("token").takeIf { it.isNotEmpty() } ?: throw IOException(tr("Risposta non valida da Last.fm."))
        pendingToken = token
        return "https://www.last.fm/api/auth/?api_key=${encode(apiKey)}&token=${encode(token)}"
    }

    /** Step 2: once allowed, the token traded for a session. */
    suspend fun completeAuth() {
        val token = pendingToken ?: return
        val json = try {
            call("auth.getSession", mapOf("token" to token), signed = true)
        } catch (e: LastFMException) {
            if (e.code == 14) throw IOException(tr("Autorizzazione non completata: nella pagina di Last.fm tocca \"Yes, allow access\" e riprova."))
            throw e
        }
        val key = json.optJSONObject("session")?.optString("key")?.takeIf { it.isNotEmpty() } ?: throw IOException(tr("Risposta non valida da Last.fm."))
        val name = json.optJSONObject("session")?.optString("name").orEmpty()
        pendingToken = null
        SecureStore.set("lastfm.session", key)
        Prefs.store.set("lastfm.username", name)
        _username.value = name
        flush()
    }

    fun signOut() {
        SecureStore.set("lastfm.session", null)
        Prefs.store.set("lastfm.username", null)
        _username.value = null
        pendingToken = null
    }

    private val canScrobble: Boolean get() = scrobbling.value && session != null && hasCredentials

    fun nowPlaying(track: Track) {
        if (!canScrobble || track.videoId.startsWith("local:") && track.artists.isEmpty()) return
        scope.launch {
            val params = mutableMapOf("artist" to artistOf(track), "track" to track.title, "sk" to (session ?: return@launch))
            track.album?.let { params["album"] = it }
            track.duration?.let { params["duration"] = it.toInt().toString() }
            runCatching { call("track.updateNowPlaying", params, signed = true, post = true) }
        }
    }

    fun scrobble(track: Track, startedAt: Long) {
        if (!canScrobble) return
        scope.launch {
            outbox.withLock {
                val items = readPending()
                items.put(JSONObject().put("artist", artistOf(track)).put("track", track.title).put("album", track.album)
                    .put("duration", track.duration?.toInt()).put("timestamp", startedAt / 1000))
                writePending(items)
            }
            flush()
        }
    }

    /** Sends what's waiting, 50 at a time (the API's limit); on a network or session problem it waits for next time. */
    suspend fun flush() = outbox.withLock {
        if (!canScrobble) return@withLock
        var items = readPending()
        while (items.length() > 0) {
            val batch = (0 until minOf(50, items.length())).map { items.getJSONObject(it) }
            val params = mutableMapOf("sk" to (session ?: return@withLock))
            batch.forEachIndexed { i, item ->
                params["artist[$i]"] = item.optString("artist")
                params["track[$i]"] = item.optString("track")
                params["timestamp[$i]"] = item.optLong("timestamp").toString()
                item.optString("album").takeIf { it.isNotEmpty() && it != "null" }?.let { params["album[$i]"] = it }
                item.optInt("duration").takeIf { it > 0 }?.let { params["duration[$i]"] = it.toString() }
            }
            val sent = try {
                call("track.scrobble", params, signed = true, post = true)
                true
            } catch (e: LastFMException) {
                // Rejected for good (bad data): dropped rather than retried forever.
                e.code !in setOf(9, 11, 16, 29)
            } catch (_: Exception) {
                false
            }
            if (!sent) break
            items = JSONArray().apply { for (i in batch.size until items.length()) put(items.get(i)) }
            writePending(items)
        }
    }

    class LastFMException(val code: Int, message: String) : IOException(message)

    private suspend fun call(method: String, params: Map<String, String> = emptyMap(), signed: Boolean = false, post: Boolean = false): JSONObject {
        if (apiKey.isEmpty() || (signed && secret.isEmpty())) throw IOException(tr("Inserisci API key e shared secret di Last.fm nelle impostazioni."))
        val all = params.toMutableMap()
        all["method"] = method
        all["api_key"] = apiKey
        if (signed) all["api_sig"] = signature(all)
        all["format"] = "json"
        val request = if (post) {
            val form = FormBody.Builder().apply { all.forEach { (k, v) -> add(k, v) } }.build()
            Request.Builder().url(ENDPOINT).post(form)
        } else {
            Request.Builder().url(ENDPOINT + "?" + all.entries.joinToString("&") { "${it.key}=${encode(it.value)}" })
        }.header("User-Agent", "Seaglass (Windows)").build()
        val text = Http.send(request) { it.body.string() }
        val json = runCatching { JSONObject(text) }.getOrElse { throw IOException(tr("Risposta non valida da Last.fm.")) }
        if (json.has("error")) {
            val code = json.optInt("error")
            if (code == 9 && params.containsKey("sk")) signOut()
            throw LastFMException(code, json.optString("message"))
        }
        return json
    }

    /** md5 of the parameters sorted by name, as name+value, followed by the secret. */
    private fun signature(params: Map<String, String>): String {
        val base = params.keys.sorted().joinToString("") { it + params[it] } + secret
        return MessageDigest.getInstance("MD5").digest(base.toByteArray()).joinToString("") { "%02x".format(it) }
    }

    private fun artistOf(track: Track) = track.primaryArtist.ifEmpty { track.artist }
    private fun encode(value: String) = URLEncoder.encode(value, Charsets.UTF_8)

    private fun readPending(): JSONArray = runCatching { JSONArray(pendingFile.readText()) }.getOrElse { JSONArray() }
    private fun writePending(items: JSONArray) {
        pendingFile.writeText(items.toString())
        _pending.value = items.length()
    }
}
