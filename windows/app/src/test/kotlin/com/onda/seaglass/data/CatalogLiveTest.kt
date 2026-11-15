package com.onda.seaglass.data

import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertTrue

/**
 * YouTube Music itself: search, an artist, an album and a radio. Runs with -Plive=true (CI's
 * non-blocking live check) and skips itself when YouTube refuses the machine.
 */
class CatalogLiveTest {
    private val live = System.getProperty("seaglass.live") == "true"

    @Test
    fun searchesAndOpensPages() = runBlocking {
        if (!live) return@runBlocking
        val songs = runCatching { InnerTube.searchSongs("daft punk one more time") }.getOrElse {
            println("skip: YouTube refused this machine ($it)")
            return@runBlocking
        }
        println("songs: ${songs.take(5).map { "${it.title} – ${it.artist}" }}")
        assertTrue(songs.isNotEmpty(), "songs found")
        assertTrue(songs.any { "One More Time" in it.title }, "the song is among them")
        val catalog = InnerTube.searchCatalog("daft punk")
        println("top: ${catalog.top}, artists: ${catalog.artists.map { it.title }}")
        val artist = InnerTube.artist(InnerTube.artistId("Daft Punk") ?: error("no artist"))
        println("artist: ${artist.name}, top songs ${artist.topSongs.size}, shelves ${artist.shelves.map { it.title }}")
        assertTrue(artist.topSongs.isNotEmpty(), "artist's top songs")
        val radio = InnerTube.radio(songs.first().videoId)
        println("radio: ${radio.size}")
        assertTrue(radio.size > 5, "a radio")
    }
}
