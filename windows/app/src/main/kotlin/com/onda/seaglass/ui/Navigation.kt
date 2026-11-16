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

    /**
     * The panel on the right, as Spotify's: what's playing (the cover, the song, what comes next),
     * the queue or the lyrics, or none; it stays as it was left from one launch to the next.
     */
    enum class Panel(val key: String) { NONE("none"), NOW_PLAYING("now"), QUEUE("queue"), LYRICS("lyrics") }
    private var panelState by mutableStateOf(Panel.entries.firstOrNull { it.key == com.onda.seaglass.core.Prefs.rightPanel.value } ?: Panel.NOW_PLAYING)
    var panel: Panel
        get() = panelState
        set(value) {
            panelState = value
            com.onda.seaglass.core.Prefs.rightPanel.value = value.key
        }

    /** The panel's button: shows that panel, or hides it if it's the one showing. */
    fun togglePanel(target: Panel) {
        panel = if (panel == target) Panel.NONE else target
    }

    /** The library on the left shrunk to its covers (dragged narrow, or its title clicked). */
    var libraryCollapsed by mutableStateOf(com.onda.seaglass.core.Prefs.leftPanelWidth.value < 120)

    /** The player over the whole window (the cover large, the lyrics or the queue beside it). */
    var fullPlayer by mutableStateOf(false)

    /** What the full player shows beside the cover. */
    enum class FullSide { NONE, LYRICS, QUEUE }
    var fullPlayerSide by mutableStateOf(FullSide.LYRICS)

    /** "Aggiungi a una playlist" for this song (the dialog shows while it's set). */
    var addToPlaylist by mutableStateOf<List<Track>?>(null)

    /** The Premium feature asked for without Premium (its name): the Premium dialog shows while it's set. */
    var premium by mutableStateOf<String?>(null)

    /** A short message at the bottom of the window, with a button when it has an [action] ("Cambia"). */
    data class Toast(val message: String, val action: String? = null, val onAction: (() -> Unit)? = null)
    var toast by mutableStateOf<Toast?>(null)
    private var toastId = 0
    fun toast(message: String, action: String? = null, onAction: (() -> Unit)? = null) {
        toast = Toast(message, action, onAction)
        val id = ++toastId
        Thread {
            // Longer with a button, to have time to press it.
            Thread.sleep(if (action != null) 5_000 else 2_500)
            if (toastId == id) toast = null
        }.apply { isDaemon = true }.start()
    }

    /** "Salva in" for this song: Brani preferiti and the playlists, ticked where it is (the dialog shows while it's set). */
    var saveTo by mutableStateOf<Track?>(null)
}
