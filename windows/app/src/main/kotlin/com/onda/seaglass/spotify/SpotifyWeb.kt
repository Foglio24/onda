package com.onda.seaglass.spotify

import com.onda.seaglass.core.Http
import com.onda.seaglass.core.HttpException
import com.onda.seaglass.core.J
import com.onda.seaglass.core.tr
import kotlinx.coroutines.delay
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException

data class SpotifyPlaylist(val uri: String, val name: String, val owner: String?, val imageUrl: String?)

/** A song as Spotify describes it: only what's needed to find it on YouTube Music. */
data class SpotifySong(val title: String, val artists: List<String>, val album: String?, val durationSeconds: Double?) {
    val primaryArtist: String get() = artists.firstOrNull { it.isNotBlank() }.orEmpty()
}

/** A playlist's songs; null entries are rows Spotify can't play here (removed, local files, episodes). */
data class SpotifyPlaylistContent(val name: String?, val songs: List<SpotifySong?>)

/** The web player's token stopped working (it lasts about an hour): sign in again silently. */
class SpotifySessionExpired : IOException(tr("Spotify non ha risposto correttamente. Riprova più tardi."))

/**
 * One GraphQL query of Spotify's web player ("pathfinder"), as seen in the player's own traffic.
 * The hash identifies the query on Spotify's side and changes when the web player is updated,
 * which is why it is read from the live page every time instead of being written here.
 */
data class PathfinderOperation(val name: String, val hash: String, val url: String, val variables: JSONObject)

/**
 * Reads the signed-in user's playlists with the same queries and headers the web player sends.
 * The public Web API (api.spotify.com/v1) refuses the web player's token with 429, so this
 * talks to the player's own endpoint instead.
 */
class SpotifyWeb(
    private val headers: Map<String, String>,
    private val library: PathfinderOperation,
    private val playlist: PathfinderOperation?,
) {
    suspend fun playlists(): List<SpotifyPlaylist> {
        val found = LinkedHashMap<String, SpotifyPlaylist>()
        var offset = 0
        while (true) {
            val variables = JSONObject(library.variables.toString()).put("offset", offset).put("limit", PAGE)
            // Playlists inside folders only show up in a flattened list.
            if (variables.has("flatten")) variables.put("flatten", true)
            val json = query(library, variables)
            val page = SpotifyParse.libraryPlaylists(json)
            page.forEach { found.putIfAbsent(it.uri, it) }
            val total = SpotifyParse.libraryTotal(json)
            val items = SpotifyParse.libraryItemCount(json)
            offset += PAGE
            if (items == 0 || total == null || offset >= total || offset >= MAX_ITEMS) break
        }
        return found.values.toList()
    }

    suspend fun content(uri: String): SpotifyPlaylistContent {
        val operation = playlist ?: throw IOException(tr("Spotify non ha risposto correttamente. Riprova più tardi."))
        val songs = mutableListOf<SpotifySong?>()
        var name: String? = null
        var offset = 0
        while (true) {
            val variables = JSONObject(operation.variables.toString()).put("uri", uri).put("offset", offset).put("limit", PAGE)
            val json = query(operation, variables)
            val page = SpotifyParse.playlistPage(json)
            name = name ?: page.name
            songs += page.songs
            offset += PAGE
            if (page.songs.isEmpty() || offset >= page.total || offset >= MAX_ITEMS) break
        }
        return SpotifyPlaylistContent(name, songs)
    }

    private suspend fun query(operation: PathfinderOperation, variables: JSONObject): JSONObject {
        val extensions = JSONObject().put("persistedQuery", JSONObject().put("version", 1).put("sha256Hash", operation.hash))
        val builder = Request.Builder()
        headers.forEach { (name, value) -> builder.header(name, value) }
        if (operation.url.contains("/v1/")) {
            // The older endpoint takes the query in the URL.
            val url = operation.url.toHttpUrl().newBuilder()
                .addQueryParameter("operationName", operation.name)
                .addQueryParameter("variables", variables.toString())
                .addQueryParameter("extensions", extensions.toString())
                .build()
            builder.url(url).get()
        } else {
            val body = JSONObject().put("variables", variables).put("operationName", operation.name).put("extensions", extensions)
            builder.url(operation.url).post(body.toString().toRequestBody("application/json;charset=UTF-8".toMediaType()))
        }
        val request = builder.build()
        repeat(4) { attempt ->
            val (status, retryAfter, text) = Http.send(request) { response ->
                Triple(response.code, response.header("retry-after")?.toLongOrNull(), response.body.string())
            }
            when {
                status == 401 -> throw SpotifySessionExpired()
                status == 429 && attempt < 3 -> delay(((retryAfter ?: 2L).coerceIn(1, 15)) * 1000)
                status !in 200..299 -> throw HttpException(status)
                else -> {
                    val json = JSONObject(text)
                    val errors = json.optJSONArray("errors")
                    if (errors != null && errors.length() > 0 && json.optJSONObject("data") == null) {
                        throw IOException("Spotify: " + errors.optJSONObject(0)?.optString("message"))
                    }
                    return json
                }
            }
        }
        throw HttpException(429)
    }

    private companion object {
        const val PAGE = 100
        /** Spotify playlists stop at 10,000 songs; a guard against a loop if a total is wrong. */
        const val MAX_ITEMS = 10_000
    }
}

/**
 * Reading the web player's answers. The shapes follow what the web player received when this was
 * written; they are read loosely (by `__typename` and `uri` wherever they sit) so a moved field
 * doesn't break the import.
 */
object SpotifyParse {
    data class Page(val name: String?, val total: Int, val songs: List<SpotifySong?>)

    fun libraryPlaylists(json: JSONObject): List<SpotifyPlaylist> {
        val found = LinkedHashMap<String, SpotifyPlaylist>()
        walk(J.value(json, "data")) { node ->
            val uri = node.optString("uri")
            val name = node.optString("name")
            if (uri.startsWith("spotify:playlist:") && name.isNotBlank() && uri !in found) {
                found[uri] = SpotifyPlaylist(
                    uri = uri,
                    name = name,
                    owner = J.string(node, "ownerV2", "data", "name"),
                    imageUrl = J.string(node, "images", "items", 0, "sources", 0, "url"),
                )
            }
        }
        return found.values.toList()
    }

    fun libraryTotal(json: JSONObject): Int? =
        (J.value(json, "data", "me", "libraryV3", "totalCount") as? Number)?.toInt()

    fun libraryItemCount(json: JSONObject): Int = J.array(json, "data", "me", "libraryV3", "items").size

    fun playlistPage(json: JSONObject): Page {
        val playlist = J.obj(json, "data", "playlistV2") ?: throw IOException(tr("Spotify non ha risposto correttamente. Riprova più tardi."))
        val content = J.obj(playlist, "content")
        val items = J.objects(content, "items")
        val songs = items.map { item -> song(J.obj(item, "itemV2", "data") ?: J.obj(item, "item", "data")) }
        val total = (content?.opt("totalCount") as? Number)?.toInt() ?: songs.size
        return Page(J.string(playlist, "name"), total, songs)
    }

    fun song(data: JSONObject?): SpotifySong? {
        if (data == null) return null
        val type = data.optString("__typename")
        if (type.isNotEmpty() && type != "Track") return null
        val title = data.optString("name").trim()
        if (title.isEmpty()) return null
        val artists = J.objects(data, "artists", "items").mapNotNull { J.string(it, "profile", "name")?.takeIf(String::isNotBlank) }
        val milliseconds = (J.value(data, "trackDuration", "totalMilliseconds") as? Number)?.toDouble()
        return SpotifySong(title, artists, J.string(data, "albumOfTrack", "name"), milliseconds?.let { it / 1000 })
    }

    private fun walk(node: Any?, visit: (JSONObject) -> Unit) {
        when (node) {
            is JSONObject -> {
                visit(node)
                for (key in node.keys()) walk(node.opt(key), visit)
            }
            is JSONArray -> for (i in 0 until node.length()) walk(node.opt(i), visit)
        }
    }
}
