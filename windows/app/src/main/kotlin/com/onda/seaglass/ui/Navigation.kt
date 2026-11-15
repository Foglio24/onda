package com.onda.seaglass.ui

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.onda.seaglass.model.MusicItem
import com.onda.seaglass.model.Track

/** A page of the window's main area. */
sealed interface Route {
    data object Home : Route
    data class Search(val query: String = "") : Route
    data object Liked : Route
    data object Playlists : Route
    data class Playlist(val id: String) : Route
    data object Downloads : Route
    data object History : Route
    data object LocalSongs : Route
    data class Artist(val id: String?, val name: String) : Route
    data class Album(val id: String) : Route
    data class RemotePlaylist(val id: String, val title: String) : Route
    data class SongInfo(val track: Track) : Route
    data object Settings : Route
    data object Equalizer : Route
    data object Account : Route
}

/** What the window shows: the page with its history (back and forward, as a browser), and its panels. */
object Nav {
    private val back = mutableStateListOf<Route>(Route.Home)
    private val forward = mutableStateListOf<Route>()

    val current: Route get() = back.last()
    val canGoBack: Boolean get() = back.size > 1
    val canGoForward: Boolean get() = forward.isNotEmpty()

    fun open(route: Route) {
        if (route == current) return
        back += route
        forward.clear()
        fullPlayer = false
    }

    /** A sidebar section: a fresh start rather than one more page on the stack. */
    fun section(route: Route) {
        if (route == current && back.size == 1) return
        back.clear()
        back += route
        forward.clear()
        fullPlayer = false
    }

    /** Replaces the page in place (the search's query as it's typed). */
    fun replace(route: Route) {
        back[back.lastIndex] = route
    }

    fun goBack() {
        if (back.size > 1) forward += back.removeAt(back.lastIndex)
    }

    fun goForward() {
        if (forward.isNotEmpty()) back += forward.removeAt(forward.lastIndex)
    }

    fun open(item: MusicItem) {
        when (item.kind) {
            MusicItem.Kind.ARTIST -> open(Route.Artist(item.id, item.title))
            MusicItem.Kind.ALBUM -> open(Route.Album(item.id))
            MusicItem.Kind.PLAYLIST -> open(Route.RemotePlaylist(item.id, item.title))
            else -> Unit
        }
    }

    /** The right panel: the queue or the lyrics, or nothing. */
    enum class Panel { NONE, QUEUE, LYRICS }
    var panel by mutableStateOf(Panel.NONE)

    /** The player over the whole window (the cover large, the lyrics beside it). */
    var fullPlayer by mutableStateOf(false)

    /** "Aggiungi a una playlist" for this song (the dialog shows while it's set). */
    var addToPlaylist by mutableStateOf<List<Track>?>(null)

    /** A short message at the bottom of the window. */
    var toast by mutableStateOf<String?>(null)
    private var toastId = 0
    fun toast(message: String) {
        toast = message
        val id = ++toastId
        Thread {
            Thread.sleep(2_500)
            if (toastId == id) toast = null
        }.apply { isDaemon = true }.start()
    }
}
