package com.onda.seaglass.spotify

import com.onda.seaglass.core.tr
import com.onda.seaglass.data.PlaylistImport
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * Copies Spotify playlists into the library: the songs are read from the user's Spotify account
 * (private playlists too, and past the 100 songs of a public link) and each one is looked up on
 * YouTube Music by [PlaylistImport], as a link or a file is: the same rules and the same summary.
 */
object SpotifyImport {
    /** One [PlaylistImport.Outcome] per playlist; [missing] counts the songs left out (a duplicate isn't missing). */
    data class Outcome(val imports: List<PlaylistImport.Outcome>) {
        val missing: Int get() = imports.sumOf { done -> done.toCheck.count { it.issue != PlaylistImport.Issue.DUPLICATE } }
    }

    private val _status = MutableStateFlow<String?>(null)
    /** What the import is doing right now, for the dialog. */
    val status: StateFlow<String?> = _status

    private var web: SpotifyWeb? = null

    /** The user's playlists, signing in to Spotify first if needed. */
    suspend fun playlists(): List<SpotifyPlaylist> = try {
        val reader = SpotifyBrowser.connect { _status.value = it }
        web = reader
        reader.playlists()
    } finally {
        _status.value = null
    }

    suspend fun import(selected: List<SpotifyPlaylist>): Outcome = try {
        val imports = mutableListOf<PlaylistImport.Outcome>()
        for ((index, playlist) in selected.withIndex()) {
            val line = tr("Playlist %lld di %lld: %@", index + 1, selected.size, playlist.name)
            _status.value = line
            val content = withSession { it.content(playlist.uri) }
            // Signing in again may have changed the text meanwhile.
            _status.value = line
            imports += PlaylistImport.importSource(source(playlist.name, content)) { _status.value = line + "\n" + it }
        }
        Outcome(imports)
    } finally {
        _status.value = null
    }

    /** A playlist's songs as [PlaylistImport] reads them; a song Spotify can't play here is reported, not looked up. */
    fun source(name: String, content: SpotifyPlaylistContent): PlaylistImport.Source = PlaylistImport.Source(
        name = name.ifBlank { content.name?.takeIf { it.isNotBlank() } ?: tr("Playlist importata") },
        rows = content.songs.mapIndexed { index, song ->
            song?.let { PlaylistImport.Row(it.title, it.artists, it.album, it.durationSeconds) }
                ?: PlaylistImport.Row(tr("Brano non disponibile %lld", index + 1), emptyList(), issue = PlaylistImport.Issue.UNAVAILABLE)
        },
        service = "Spotify",
    )

    suspend fun signOut() {
        web = null
        SpotifyBrowser.signOut()
    }

    /** The token lasts about an hour: when it has expired, sign in again (without a window). */
    private suspend fun <T> withSession(block: suspend (SpotifyWeb) -> T): T {
        val current = web ?: SpotifyBrowser.connect { _status.value = it }.also { web = it }
        return try {
            block(current)
        } catch (expired: SpotifySessionExpired) {
            val fresh = SpotifyBrowser.connect { _status.value = it }
            web = fresh
            block(fresh)
        }
    }
}
