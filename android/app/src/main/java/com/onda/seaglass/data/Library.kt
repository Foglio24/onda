package com.onda.seaglass.data

import android.content.Context
import com.onda.seaglass.model.Playlist
import com.onda.seaglass.model.Track
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import org.json.JSONArray
import java.io.File

/** Favourites, the user's playlists and the listening history, saved as JSON in the app's files. */
object Library {
    private lateinit var directory: File
    private val io = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val _liked = MutableStateFlow<List<Track>>(emptyList())
    val liked: StateFlow<List<Track>> = _liked

    private val _playlists = MutableStateFlow<List<Playlist>>(emptyList())
    val playlists: StateFlow<List<Playlist>> = _playlists

    private val _history = MutableStateFlow<List<Track>>(emptyList())
    val history: StateFlow<List<Track>> = _history

    private const val HISTORY_LIMIT = 300

    fun init(context: Context) {
        directory = File(context.filesDir, "library").apply { mkdirs() }
        _liked.value = Track.listFromJson(read("liked.json"))
        _history.value = Track.listFromJson(read("history.json"))
        _playlists.value = read("playlists.json")?.let { array ->
            (0 until array.length()).mapNotNull { Playlist.fromJson(array.optJSONObject(it)) }
        } ?: emptyList()
    }

    private fun read(name: String): JSONArray? =
        runCatching { JSONArray(File(directory, name).readText()) }.getOrNull()

    private fun write(name: String, array: JSONArray) {
        val text = array.toString()
        io.launch {
            synchronized(this@Library) {
                val file = File(directory, name)
                val temporary = File(directory, "$name.tmp")
                temporary.writeText(text)
                temporary.renameTo(file)
            }
        }
    }

    // Favourites

    fun isLiked(track: Track) = _liked.value.any { it.videoId == track.videoId }

    fun toggleLike(track: Track) {
        val current = _liked.value
        _liked.value = if (isLiked(track)) current.filterNot { it.videoId == track.videoId } else listOf(track) + current
        write("liked.json", Track.listToJson(_liked.value))
    }

    // Playlists

    fun playlist(id: String) = _playlists.value.firstOrNull { it.id == id }

    fun createPlaylist(name: String, tracks: List<Track> = emptyList()): Playlist {
        val playlist = Playlist(name = name.trim().ifEmpty { "Playlist" }, tracks = tracks)
        _playlists.value = _playlists.value + playlist
        savePlaylists()
        return playlist
    }

    fun renamePlaylist(id: String, name: String) = update(id) { it.copy(name = name.trim().ifEmpty { it.name }) }

    fun deletePlaylist(id: String) {
        _playlists.value = _playlists.value.filterNot { it.id == id }
        savePlaylists()
    }

    fun contains(track: Track, playlistId: String) = playlist(playlistId)?.tracks?.any { it.videoId == track.videoId } == true

    fun toggle(track: Track, playlistId: String) = update(playlistId) { playlist ->
        if (playlist.tracks.any { it.videoId == track.videoId }) {
            playlist.copy(tracks = playlist.tracks.filterNot { it.videoId == track.videoId })
        } else {
            playlist.copy(tracks = playlist.tracks + track)
        }
    }

    fun removeTrack(index: Int, playlistId: String) = update(playlistId) { playlist ->
        playlist.copy(tracks = playlist.tracks.filterIndexed { i, _ -> i != index })
    }

    fun moveTrack(from: Int, to: Int, playlistId: String) = update(playlistId) { playlist ->
        val tracks = playlist.tracks.toMutableList()
        if (from !in tracks.indices || to !in tracks.indices) return@update playlist
        tracks.add(to, tracks.removeAt(from))
        playlist.copy(tracks = tracks)
    }

    private fun update(id: String, change: (Playlist) -> Playlist) {
        _playlists.value = _playlists.value.map { if (it.id == id) change(it) else it }
        savePlaylists()
    }

    private fun savePlaylists() = write("playlists.json", JSONArray().apply { _playlists.value.forEach { put(it.toJson()) } })

    // History

    fun recordPlay(track: Track) {
        _history.value = (listOf(track) + _history.value.filterNot { it.videoId == track.videoId }).take(HISTORY_LIMIT)
        write("history.json", Track.listToJson(_history.value))
    }

    fun removeFromHistory(track: Track) {
        _history.value = _history.value.filterNot { it.videoId == track.videoId }
        write("history.json", Track.listToJson(_history.value))
    }

    fun clearHistory() {
        _history.value = emptyList()
        write("history.json", JSONArray())
    }
}
