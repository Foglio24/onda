package com.onda.seaglass.data

import com.onda.seaglass.model.Playlist
import com.onda.seaglass.model.Track
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject

/** Favourites, playlists and history — backed by LocalLibrary JSON (account sync). */
object Library {
    private val _liked = MutableStateFlow<List<Track>>(emptyList())
    val liked: StateFlow<List<Track>> = _liked.asStateFlow()

    private val _playlists = MutableStateFlow<List<Playlist>>(emptyList())
    val playlists: StateFlow<List<Playlist>> = _playlists.asStateFlow()

    private val _history = MutableStateFlow<List<Track>>(emptyList())
    val history: StateFlow<List<Track>> = _history.asStateFlow()

    private const val HISTORY_LIMIT = 300

    fun reload() {
        val body = LocalLibrary.snapshot()
        _liked.value = Track.listFromJson(body.optJSONArray("liked"))
        _history.value = Track.listFromJson(body.optJSONArray("history"))
        _playlists.value = body.optJSONArray("playlists")?.let { array ->
            (0 until array.length()).mapNotNull { Playlist.fromJson(array.optJSONObject(it)) }
        } ?: emptyList()
    }

    fun isLiked(track: Track) = _liked.value.any { it.videoId == track.videoId }

    fun toggleLike(track: Track) {
        val current = _liked.value
        _liked.value = if (isLiked(track)) current.filterNot { it.videoId == track.videoId } else listOf(track) + current
        persist()
    }

    fun createPlaylist(name: String, tracks: List<Track> = emptyList()): Playlist {
        val playlist = Playlist(name = name.trim().ifEmpty { "Playlist" }, tracks = tracks)
        _playlists.value = _playlists.value + playlist
        persist()
        return playlist
    }

    fun deletePlaylist(id: String) {
        _playlists.value = _playlists.value.filterNot { it.id == id }
        persist()
    }

    fun toggleInPlaylist(track: Track, playlistId: String) {
        _playlists.value = _playlists.value.map { playlist ->
            if (playlist.id != playlistId) return@map playlist
            if (playlist.tracks.any { it.videoId == track.videoId }) {
                playlist.copy(tracks = playlist.tracks.filterNot { it.videoId == track.videoId })
            } else {
                playlist.copy(tracks = playlist.tracks + track)
            }
        }
        persist()
    }

    fun recordPlay(track: Track) {
        _history.value = (listOf(track) + _history.value.filterNot { it.videoId == track.videoId }).take(HISTORY_LIMIT)
        persist()
    }

    fun clearHistory() {
        _history.value = emptyList()
        persist()
    }

    fun applyServerBody(body: JSONObject) {
        LocalLibrary.mergeFromServer(body)
        reload()
    }

    private fun persist() {
        val body = LocalLibrary.snapshot()
        body.put("liked", Track.listToJson(_liked.value))
        body.put("history", Track.listToJson(_history.value))
        body.put("playlists", JSONArray().apply { _playlists.value.forEach { put(it.toJson()) } })
        if (!body.has("preferences")) body.put("preferences", JSONObject())
        LocalLibrary.save(body)
    }
}
