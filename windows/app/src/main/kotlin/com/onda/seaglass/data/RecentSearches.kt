package com.onda.seaglass.data

import com.onda.seaglass.audio.isLocal
import com.onda.seaglass.core.Paths
import com.onda.seaglass.model.MusicItem
import com.onda.seaglass.model.Track
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * The search's history, newest first, as on the iPhone ("Ricerche recenti"): the searches sent and
 * what was picked from the results (a song, an artist, an album, a playlist), at most 20. It stays
 * on this computer (%APPDATA%\Seaglass\recent-searches.json, not synced); the user removes an entry
 * or clears it all.
 */
object RecentSearches {
    enum class Kind(val key: String) { QUERY("query"), SONG("song"), ARTIST("artist"), ALBUM("album"), PLAYLIST("playlist") }

    data class Entry(val kind: Kind, val key: String, val title: String, val subtitle: String = "", val artworkUrl: String? = null, val track: Track? = null) {
        val id: String get() = "${kind.key}:$key"

        /** The page it opens (an artist, an album, a playlist). */
        val item: MusicItem?
            get() = when (kind) {
                Kind.ARTIST -> MusicItem(MusicItem.Kind.ARTIST, key, title, subtitle, artworkUrl)
                Kind.ALBUM -> MusicItem(MusicItem.Kind.ALBUM, key, title, subtitle, artworkUrl)
                Kind.PLAYLIST -> MusicItem(MusicItem.Kind.PLAYLIST, key, title, subtitle, artworkUrl)
                else -> null
            }

        fun toJson(): JSONObject = JSONObject().put("kind", kind.key).put("key", key).put("title", title).put("subtitle", subtitle)
            .put("artwork", artworkUrl ?: JSONObject.NULL).put("track", track?.toJson() ?: JSONObject.NULL)

        companion object {
            fun fromJson(json: JSONObject?): Entry? {
                json ?: return null
                val kind = Kind.entries.firstOrNull { it.key == json.optString("kind") } ?: return null
                val key = json.optString("key").takeIf { it.isNotBlank() } ?: return null
                val track = if (kind == Kind.SONG) Track.fromJson(json.optJSONObject("track")) ?: return null else null
                return Entry(kind, key, json.optString("title", key), json.optString("subtitle"), json.optString("artwork").takeIf { it.isNotBlank() && it != "null" }, track)
            }

            fun query(text: String) = Entry(Kind.QUERY, text, text)
            fun song(track: Track) = Entry(Kind.SONG, track.videoId, track.title, track.artist, track.resized(120), track)

            /** An artist, album or playlist from the results; a song item is its song; anything else isn't kept. */
            fun item(item: MusicItem): Entry? = when (item.kind) {
                MusicItem.Kind.SONG -> item.track?.let(::song)
                MusicItem.Kind.ARTIST -> Entry(Kind.ARTIST, item.id, item.title, item.subtitle, item.artworkUrl)
                MusicItem.Kind.ALBUM -> Entry(Kind.ALBUM, item.id, item.title, item.subtitle, item.artworkUrl)
                MusicItem.Kind.PLAYLIST -> Entry(Kind.PLAYLIST, item.id, item.title, item.subtitle, item.artworkUrl)
                MusicItem.Kind.PODCAST -> null
            }
        }
    }

    const val LIMIT = 20

    /** [entry] first, without its earlier place, at most [LIMIT]. */
    fun adding(entries: List<Entry>, entry: Entry): List<Entry> = (listOf(entry) + entries.filter { it.id != entry.id }).take(LIMIT)

    private val io = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val _entries = MutableStateFlow<List<Entry>>(emptyList())
    val entries: StateFlow<List<Entry>> = _entries
    private val file: File get() = File(Paths.data, "recent-searches.json")

    fun init() {
        _entries.value = runCatching {
            val array = JSONArray(file.readText())
            (0 until array.length()).mapNotNull { Entry.fromJson(array.optJSONObject(it)) }.take(LIMIT)
        }.getOrDefault(emptyList())
    }

    fun remember(query: String) {
        val text = query.trim()
        if (text.isNotEmpty()) remember(Entry.query(text))
    }

    fun remember(track: Track) {
        if (!track.isLocal) remember(Entry.song(track))
    }

    fun remember(item: MusicItem) {
        Entry.item(item)?.let(::remember)
    }

    private fun remember(entry: Entry) = change(adding(_entries.value, entry))

    fun remove(entry: Entry) = change(_entries.value.filter { it.id != entry.id })

    fun clear() = change(emptyList())

    private fun change(entries: List<Entry>) {
        _entries.value = entries
        val text = JSONArray().apply { entries.forEach { put(it.toJson()) } }.toString()
        io.launch {
            synchronized(this@RecentSearches) {
                runCatching {
                    val temporary = File(file.parentFile, file.name + ".tmp")
                    temporary.writeText(text)
                    java.nio.file.Files.move(
                        temporary.toPath(), file.toPath(),
                        java.nio.file.StandardCopyOption.REPLACE_EXISTING, java.nio.file.StandardCopyOption.ATOMIC_MOVE,
                    )
                }
            }
        }
    }
}
