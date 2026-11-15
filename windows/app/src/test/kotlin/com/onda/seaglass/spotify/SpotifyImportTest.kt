package com.onda.seaglass.spotify

import com.onda.seaglass.data.PlaylistImport
import com.onda.seaglass.model.Track
import org.json.JSONObject
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Reading the web player's answers and choosing the YouTube Music recording. The JSON follows the
 * shape the web player's "libraryV3" and "fetchPlaylist" queries answer with, trimmed to what the
 * importer reads.
 */
class SpotifyImportTest {
    private val library = JSONObject(
        """
        {"data":{"me":{"libraryV3":{"__typename":"LibraryPage","totalCount":3,"items":[
          {"item":{"data":{"__typename":"Playlist","uri":"spotify:playlist:AAA","name":"Estate",
            "ownerV2":{"data":{"name":"Luca"}},
            "images":{"items":[{"sources":[{"url":"https://i.scdn.co/image/a"}]}]}}}},
          {"item":{"data":{"__typename":"Album","uri":"spotify:album:BBB","name":"Un album"}}},
          {"item":{"data":{"__typename":"Folder","uri":"spotify:user:x:folder:1","name":"Cartella",
            "playlists":[{"data":{"__typename":"Playlist","uri":"spotify:playlist:CCC","name":"Dentro la cartella"}}]}}}
        ]}}}}
        """,
    )

    private val playlistPage = JSONObject(
        """
        {"data":{"playlistV2":{"__typename":"Playlist","name":"Estate","content":{"totalCount":250,"items":[
          {"itemV2":{"data":{"__typename":"Track","name":"Bohemian Rhapsody - Remastered 2011",
            "artists":{"items":[{"profile":{"name":"Queen"}}]},
            "albumOfTrack":{"name":"A Night at the Opera"},
            "trackDuration":{"totalMilliseconds":354320}}}},
          {"itemV2":{"data":{"__typename":"NotFound"}}},
          {"itemV2":{"data":{"__typename":"Episode","name":"Un podcast"}}}
        ]}}}}
        """,
    )

    @Test
    fun readsPlaylistsFromTheLibraryIncludingFolders() {
        val playlists = SpotifyParse.libraryPlaylists(library)
        assertEquals(listOf("spotify:playlist:AAA", "spotify:playlist:CCC"), playlists.map { it.uri })
        assertEquals("Luca", playlists[0].owner)
        assertEquals("https://i.scdn.co/image/a", playlists[0].imageUrl)
        assertEquals(3, SpotifyParse.libraryTotal(library))
        assertEquals(3, SpotifyParse.libraryItemCount(library))
    }

    @Test
    fun readsSongsAndKeepsUnavailableRowsAsGaps() {
        val page = SpotifyParse.playlistPage(playlistPage)
        assertEquals("Estate", page.name)
        assertEquals(250, page.total)
        assertEquals(3, page.songs.size)
        val song = page.songs[0]!!
        assertEquals("Bohemian Rhapsody - Remastered 2011", song.title)
        assertEquals(listOf("Queen"), song.artists)
        assertEquals("A Night at the Opera", song.album)
        assertEquals(354.32, song.durationSeconds!!, 0.001)
        assertNull(page.songs[1])
        assertNull(page.songs[2])
    }

    @Test
    fun aPlaylistBecomesRowsWithUnavailableSongsReported() {
        val content = SpotifyPlaylistContent("Estate", listOf(SpotifySong("Song", listOf("A", "B"), "Album", 200.0), null))
        val source = SpotifyImport.source("", content)
        assertEquals("Estate", source.name)
        assertEquals("Spotify", source.service)
        assertEquals(PlaylistImport.Row("Song", listOf("A", "B"), "Album", 200.0), source.rows[0])
        assertEquals(PlaylistImport.Issue.UNAVAILABLE, source.rows[1].issue)
        assertTrue(source.rows[1].artists.isEmpty())
        assertEquals("Mia", SpotifyImport.source("Mia", content).name)
    }

    // Spotify's titles ("- Remastered 2011", "(feat. …)") through the importer's own rules.

    private fun track(id: String, title: String, artist: String, seconds: Double?) =
        Track(videoId = id, title = title, artists = listOf(artist), duration = seconds)

    private fun row(song: SpotifySong) = SpotifyImport.source("x", SpotifyPlaylistContent(null, listOf(song))).rows.single()

    private val wanted = row(SpotifySong("Bohemian Rhapsody - Remastered 2011", listOf("Queen"), null, 354.0))

    @Test
    fun prefersTheSameRecordingOverVariants() {
        val results = listOf(
            track("live0000000", "Bohemian Rhapsody (Live Aid)", "Queen", 360.0),
            track("cover000000", "Bohemian Rhapsody", "Some Choir", 354.0),
            track("orig0000000", "Bohemian Rhapsody", "Queen", 355.0),
        )
        assertEquals("orig0000000", PlaylistImport.Matching.best(results, wanted)?.videoId)
    }

    @Test
    fun refusesALengthTooFarOff() {
        val results = listOf(track("long0000000", "Bohemian Rhapsody", "Queen", 600.0))
        assertNull(PlaylistImport.Matching.best(results, wanted))
    }

    @Test
    fun matchesAccentsAndFeaturing() {
        val song = row(SpotifySong("Despacito (feat. Daddy Yankee)", listOf("Luis Fonsi", "Daddy Yankee"), null, 229.0))
        val results = listOf(track("desp0000000", "Despacito", "Luis Fonsí", 228.0))
        assertEquals("desp0000000", PlaylistImport.Matching.best(results, song)?.videoId)
    }
}
