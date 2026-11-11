package com.onda.seaglass

import com.onda.seaglass.core.Http
import com.onda.seaglass.core.L10n
import com.onda.seaglass.data.InnerTube
import com.onda.seaglass.data.Lyrics
import com.onda.seaglass.data.LyricsState
import com.onda.seaglass.data.NoStreamException
import com.onda.seaglass.data.Streams
import com.onda.seaglass.model.MusicItem
import kotlinx.coroutines.runBlocking
import okhttp3.Request
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

/**
 * The app's YouTube Music and LRCLIB code against the real services, like the iPhone app's
 * `CatalogCheck`: search, radio, artist, album and playlist pages, an audio link that answers with
 * audio in ranges, and synced lyrics. Run with `./gradlew testDebugUnitTest`.
 */
class CatalogCheck {
    /** The live service sometimes answers a runner slowly: a timeout is tried again, twice. */
    private suspend fun <T> retrying(block: suspend () -> T): T {
        var last: java.io.IOException? = null
        repeat(3) { attempt ->
            try {
                return block()
            } catch (e: java.net.SocketTimeoutException) {
                last = e
                println("Timeout, trying again (${attempt + 1})")
            }
        }
        throw last!!
    }

    @Test
    fun searchRadioAndPages() = runBlocking {
        val songs = retrying { InnerTube.searchSongs("Daft Punk Get Lucky") }
        assertTrue("no songs", songs.isNotEmpty())
        val song = songs.first()
        println("Song: ${song.title} – ${song.artist} (${song.videoId}, ${song.duration} s, album ${song.album})")
        assertTrue(song.title.isNotEmpty() && song.primaryArtist.isNotEmpty())

        val radio = retrying { InnerTube.radio(song.videoId) }
        println("Radio: ${radio.size} songs, first ${radio.firstOrNull()?.title}")
        assertTrue("short radio", radio.size >= 10)

        val catalog = retrying { InnerTube.searchCatalog("Daft Punk") }
        val artist = listOfNotNull(catalog.top, catalog.artists.firstOrNull()).first { it.kind == MusicItem.Kind.ARTIST }
        println("Artist: ${artist.title} ${artist.id}; albums ${catalog.albums.take(3).map { it.title }}")
        val page = retrying { InnerTube.artist(artist.id) }
        println("Artist page: ${page.name}, ${page.topSongs.size} top songs, shelves ${page.shelves.map { "${it.title} (${it.items.size})" }}")
        assertTrue(page.topSongs.isNotEmpty())
        assertTrue(page.shelves.isNotEmpty())

        val albumId = catalog.albums.firstOrNull()?.id ?: page.shelves.flatMap { it.items }.first { it.kind == MusicItem.Kind.ALBUM }.id
        val album = retrying { InnerTube.album(albumId) }
        println("Album: ${album.title} by ${album.artist}, ${album.tracks.size} songs, ${album.kindAndYear}, ${album.details}")
        assertTrue(album.tracks.isNotEmpty())

        val playlistId = page.songsPlaylistId ?: catalog.playlists.first().id
        val playlist = retrying { InnerTube.playlist(playlistId) }
        println("Playlist: ${playlist.title}, ${playlist.tracks.size} songs")
        assertTrue(playlist.tracks.size >= 10)
    }

    @Test
    fun audioStreams() = runBlocking {
        val song = InnerTube.searchSongs("Daft Punk Get Lucky").first()
        val resolved = try {
            Streams.resolve(song.videoId)
        } catch (e: NoStreamException) {
            // YouTube may refuse a data centre's network (CI) what it gives a phone: reported, not failed.
            println("Stream refused here: ${e.detail}")
            assumeTrue("YouTube refused the audio links on this network (${e.detail})", false)
            return@runBlocking
        }
        val url = resolved.rendition.url
        println("Stream: ${resolved.rendition.label}, ${resolved.rendition.mime}, clen=${url.substringAfter("clen=", "?").substringBefore('&')}")
        assertTrue(resolved.rendition.isOpus || resolved.rendition.isAac)
        assertTrue("no clen", "clen=" in url)
        // The first megabyte, as ChunkedDataSource asks for it.
        val request = Request.Builder().url(url).header("User-Agent", Streams.USER_AGENT).header("Range", "bytes=0-1048575").build()
        val (code, bytes) = Http.send(request) { it.code to it.body.bytes().size }
        println("Range: HTTP $code, $bytes bytes")
        // The same refusal, one step later: the link was given but the download isn't (reported, not failed).
        assumeTrue("YouTube refused the audio download on this network (HTTP $code)", code != 403)
        assertEquals(206, code)
        assertTrue(bytes > 100_000)
    }

    @Test
    fun syncedLyrics() = runBlocking {
        val song = InnerTube.searchSongs("Daft Punk Get Lucky").first()
        val lyrics = Lyrics.lyrics(song)
        println("Lyrics: ${(lyrics as? LyricsState.Synced)?.lines?.size} synced lines")
        assertTrue(lyrics is LyricsState.Synced)
    }

    /** Every text the Android app shows exists in every language (iPhone tables plus Android-only lines). */
    @Test
    fun translations() {
        val root = generateSequence(File("").absoluteFile) { it.parentFile }.first { File(it, "Seaglass/Resources").isDirectory }
        val sources = File(root, "android/app/src/main/java").walk().filter { it.extension == "kt" }.map { it.readText() }.joinToString("\n")
        val keys = Regex("""tr\(\s*"((?:[^"\\]|\\.)*)"""").findAll(sources).map { it.groupValues[1].replace("\\\"", "\"") }.toSet()
        assertTrue(keys.size > 100)
        val languages = File(root, "Seaglass/Resources").listFiles()!!.filter { it.name.endsWith(".lproj") && it.name != "it.lproj" }
        val missing = mutableListOf<String>()
        for (language in languages) {
            val code = language.name.removeSuffix(".lproj")
            val table = L10n.parse(File(language, "Localizable.strings").readText()) +
                L10n.parse(File(root, "android/app/src/main/assets/l10n-android/$code.strings").takeIf { it.exists() }?.readText().orEmpty())
            keys.filter { it !in table }.forEach { missing += "$code: $it" }
            // The same placeholders (%@, %lld, numbered or not) in the same number.
            val specifier = Regex("""%(\d+\$)?(@|lld|ld|d|s)""")
            fun kinds(text: String) = specifier.findAll(text).map { it.groupValues[2] }.sorted().toList()
            keys.filter { it in table && kinds(it) != kinds(table.getValue(it)) }.forEach { missing += "$code (placeholders): $it" }
        }
        println("${keys.size} texts in ${languages.size} languages")
        assertTrue("Missing translations:\n" + missing.joinToString("\n"), missing.isEmpty())
        assertNotNull(languages.firstOrNull())
    }
}
