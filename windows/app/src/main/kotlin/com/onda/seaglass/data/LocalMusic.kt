package com.onda.seaglass.data

import com.onda.seaglass.audio.Decoder
import com.onda.seaglass.audio.FileSource
import com.onda.seaglass.core.Paths
import com.onda.seaglass.core.Prefs
import com.onda.seaglass.model.Track
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest

/**
 * The user's own songs, from folders they pick (Musica di Windows by default is not read until
 * they choose it): MP3, M4A, FLAC, WAV, OGG, Opus… with their tags. The files are only read,
 * never written, moved or deleted; their names and tags aren't sent anywhere.
 */
object LocalMusic {
    private val extensions = setOf("mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "oga", "wma", "aiff", "aif", "alac", "webm")

    data class Song(val track: Track, val path: String)

    private val _songs = MutableStateFlow<List<Song>>(emptyList())
    val songs: StateFlow<List<Song>> = _songs
    private val _scanning = MutableStateFlow(false)
    val scanning: StateFlow<Boolean> = _scanning

    private val byId = HashMap<String, String>()
    private val indexFile by lazy { File(Paths.data, "local-music.json") }

    val folders: List<String>
        get() = (Prefs.store.json("local.folders") as? JSONArray)?.let { array -> (0 until array.length()).map { array.optString(it) } }
            ?: emptyList()

    fun init() {
        val array = runCatching { JSONArray(indexFile.readText()) }.getOrNull() ?: JSONArray()
        val list = (0 until array.length()).mapNotNull { i ->
            val entry = array.optJSONObject(i) ?: return@mapNotNull null
            val track = Track.fromJson(entry.optJSONObject("track")) ?: return@mapNotNull null
            Song(track, entry.optString("path"))
        }
        publish(list)
        // The folders may have changed while the app was closed: read them again, in the background.
        if (folders.isNotEmpty()) scope.launch { rescan() }
    }

    private val scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.SupervisorJob() + Dispatchers.IO)

    fun file(track: Track): File? {
        if (!track.videoId.startsWith("local:")) return null
        return synchronized(byId) { byId[track.videoId] }?.let(::File)?.takeIf { it.isFile }
    }

    suspend fun addFolder(folder: File) {
        val list = (folders + folder.absolutePath).distinct()
        Prefs.store.set("local.folders", JSONArray(list))
        rescan()
    }

    suspend fun removeFolder(path: String) {
        Prefs.store.set("local.folders", JSONArray(folders - path))
        rescan()
    }

    /** Reads every folder again: new songs come in, removed ones go (the files themselves are untouched). */
    suspend fun rescan() = withContext(Dispatchers.IO) {
        _scanning.value = true
        try {
            val known = _songs.value.associateBy { it.path }
            val found = ArrayList<Song>()
            for (folder in folders) {
                File(folder).walkTopDown().maxDepth(12).filter { it.isFile && it.extension.lowercase() in extensions }.forEach { file ->
                    val previous = known[file.absolutePath]
                    found += previous ?: read(file) ?: return@forEach
                }
            }
            found.sortWith(compareBy({ it.track.primaryArtist.lowercase() }, { it.track.album.orEmpty().lowercase() }, { it.track.title.lowercase() }))
            publish(found)
            save(found)
        } finally {
            _scanning.value = false
        }
    }

    private fun read(file: File): Song? = runCatching {
        Decoder(FileSource(file)).use { decoder ->
            val tags = decoder.tags
            val title = tags["title"]?.takeIf { it.isNotBlank() } ?: file.nameWithoutExtension
            val artists = (tags["artist"] ?: tags["album_artist"]).orEmpty()
                .split(";", " / ", " & ", ", ").map { it.trim() }.filter { it.isNotEmpty() }
            val id = "local:" + MessageDigest.getInstance("SHA-1").digest(file.absolutePath.toByteArray())
                .joinToString("") { "%02x".format(it) }.take(20)
            Song(Track(id, title, artists, tags["album"]?.takeIf { it.isNotBlank() }, decoder.duration.takeIf { it > 0 }), file.absolutePath)
        }
    }.getOrNull()

    private fun publish(list: List<Song>) {
        synchronized(byId) {
            byId.clear()
            list.forEach { byId[it.track.videoId] = it.path }
        }
        _songs.value = list
    }

    private fun save(list: List<Song>) {
        val array = JSONArray()
        list.forEach { array.put(JSONObject().put("track", it.track.toJson()).put("path", it.path)) }
        indexFile.writeText(array.toString())
    }
}
