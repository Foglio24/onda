package com.onda.seaglass.data

import com.onda.seaglass.model.Track
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** The playlist importer: links, Spotify's and Apple Music's pages, files, and which recording is the same song. */
class PlaylistImportTest {
    @Test
    fun recognisesLinks() {
        assertEquals(PlaylistImport.Link.Spotify("playlist", "37i9dQZF1DXcBWIGoYBM5M"),
            PlaylistImport.parseLink("Ascolta su Spotify: https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M?si=abc123 bella"))
        assertEquals(PlaylistImport.Link.Spotify("album", "4aawyAB9vmqN3uQ7FjRGTy"),
            PlaylistImport.parseLink("https://open.spotify.com/intl-it/album/4aawyAB9vmqN3uQ7FjRGTy"))
        assertEquals(PlaylistImport.Link.Spotify("playlist", "abc"), PlaylistImport.parseLink("spotify:playlist:abc"))
        assertEquals(PlaylistImport.Link.YouTube("PLx0sYbCqOb8TBPRdmBHs5Iftvv9TPboYG"),
            PlaylistImport.parseLink("https://music.youtube.com/playlist?list=PLx0sYbCqOb8TBPRdmBHs5Iftvv9TPboYG"))
        assertTrue(PlaylistImport.parseLink("https://music.apple.com/it/playlist/x/pl.u-123") is PlaylistImport.Link.AppleMusic)
        assertEquals(PlaylistImport.Link.Spotify("short", "https://spotify.link/AbCdEf"), PlaylistImport.parseLink("https://spotify.link/AbCdEf"))
        assertNull(PlaylistImport.parseLink("https://open.spotify.com/track/123"))
        assertNull(PlaylistImport.parseLink("una playlist bellissima"))
    }

    private fun embed(count: Int): String {
        val tracks = (0 until count).joinToString(",") { i ->
            when (i) {
                1 -> """{"uri":"spotify:track:b","title":"","subtitle":"Nessuno"}"""
                else -> """{"uri":"spotify:track:$i","title":"Song $i","subtitle":"KAROL G,\u00a0Judeline","duration":225834}"""
            }
        }
        return """<html><head></head><body><script id="__NEXT_DATA__" type="application/json">""" +
            """{"props":{"pageProps":{"state":{"data":{"entity":{"name":"Today’s Top Hits","trackList":[$tracks]}}}}}}</script></body></html>"""
    }

    @Test
    fun readsSpotifysEmbedPage() {
        val source = PlaylistImport.parseSpotifyEmbed(embed(3))
        assertEquals("Today’s Top Hits", source.name)
        assertEquals(3, source.rows.size)
        assertEquals("Song 0", source.rows[0].title)
        assertEquals(listOf("KAROL G", "Judeline"), source.rows[0].artists, "artists split, the no-break space dropped")
        assertEquals(225.834, source.rows[0].duration ?: 0.0, 0.001)
        assertEquals(PlaylistImport.Issue.UNAVAILABLE, source.rows[1].issue, "a song without a title is kept, as unavailable")
        assertTrue(!source.mayBeTruncated)
        // The public page stops at 100: the summary says the playlist may be longer.
        assertTrue(PlaylistImport.parseSpotifyEmbed(embed(100)).mayBeTruncated)
        assertFailsWith<PlaylistImport.ImportException> { PlaylistImport.parseSpotifyEmbed("<html>changed</html>") }
    }

    @Test
    fun readsAppleMusicsPage() {
        val html = """<html><script type="application/ld+json">{"name":"Estate 2026"}</script>""" +
            """<script type="application/json" id="serialized-server-data">[{"data":{"sections":[{"items":[""" +
            """{"id":"track-lockup - 1","title":"Uno","artistName":"Artista A","duration":180000},""" +
            """{"id":"track-lockup - 2","title":"Due","subtitleLinks":[{"title":"Artista B"}]},""" +
            """{"id":"album-lockup - 3","title":"Non un brano"}]}]}}]</script></html>"""
        val source = PlaylistImport.parseAppleMusic(html)
        assertEquals("Estate 2026", source.name)
        assertEquals(listOf("Uno", "Due"), source.rows.map { it.title })
        assertEquals(listOf("Artista B"), source.rows[1].artists)
        assertEquals(180.0, source.rows[0].duration ?: 0.0, 0.001)
    }

    @Test
    fun readsExportifysCsv() {
        val csv = "\uFEFF\"Track URI\",\"Track Name\",\"Album Name\",\"Artist Name(s)\",\"Release Date\",\"Duration (ms)\"\r\n" +
            "\"spotify:track:1\",\"Hello, World\",\"Album \"\"Live\"\"\",\"Artist A,Artist B\",\"2020\",\"201000\"\r\n" +
            "\"spotify:track:2\",\"\",\"\",\"\",\"\",\"\"\r\n" +
            "\"spotify:track:3\",\"Line\nbreak\",\"X\",\"C\",\"2021\",\"0\"\r\n"
        val sources = PlaylistImportFile.read(csv.toByteArray(), "C:\\Users\\me\\Downloads\\Road trip.csv")
        assertEquals(1, sources.size)
        val source = sources.first()
        assertEquals("Road trip", source.name)
        assertEquals(3, source.rows.size)
        assertEquals("Hello, World", source.rows[0].title)
        assertEquals("Album \"Live\"", source.rows[0].album)
        assertEquals(listOf("Artist A", "Artist B"), source.rows[0].artists)
        assertEquals(201.0, source.rows[0].duration ?: 0.0, 0.001)
        assertEquals(PlaylistImport.Issue.UNAVAILABLE, source.rows[1].issue)
        assertEquals("Line\nbreak", source.rows[2].title)
        assertNull(source.rows[2].duration, "0 ms is no length")
        assertFailsWith<PlaylistImportFile.FileException> { PlaylistImportFile.read("a,b\n1,2\n".toByteArray(), "x.csv") }
        assertFailsWith<PlaylistImportFile.FileException> { PlaylistImportFile.read("\"Track Name\",\"Artist\"\n\"open".toByteArray(), "x.csv") }
    }

    @Test
    fun readsSpotifysAccountDataExport() {
        val json = """{"playlists":[{"name":"Corsa","items":[
            {"track":{"trackName":"Run","artistName":"Runner","albumName":"Fast"}},
            {"episode":{"episodeName":"Puntata 1","showName":"Il podcast"}},
            {"track":{"trackName":"  "}}
        ]},{"name":"Vuota","items":[]}]}"""
        val sources = PlaylistImportFile.read(json.toByteArray(), "Playlist1.json")
        assertEquals(listOf("Corsa", "Vuota"), sources.map { it.name })
        val rows = sources.first().rows
        assertEquals("Run", rows[0].title)
        assertEquals(listOf("Runner"), rows[0].artists)
        assertEquals(PlaylistImport.Issue.UNSUPPORTED, rows[1].issue, "a podcast episode isn't looked up")
        assertEquals(PlaylistImport.Issue.UNAVAILABLE, rows[2].issue)
    }

    private fun track(id: String, title: String, artist: String, duration: Double? = null) = Track(id, title, listOf(artist), duration = duration)

    @Test
    fun findsTheSameSongAndNotAnotherVersion() {
        val wanted = PlaylistImport.Row("Blinding Lights", listOf("The Weeknd"), duration = 200.0)
        val results = listOf(
            track("live0000001", "Blinding Lights (Live)", "The Weeknd", 210.0),
            track("cover000001", "Blinding Lights", "Somebody Else", 200.0),
            track("right000001", "Blinding Lights", "The Weeknd", 201.0),
        )
        assertEquals("right000001", PlaylistImport.Matching.best(results, wanted)?.videoId)
        // A live version is right when the live version is wanted.
        assertEquals("live0000001", PlaylistImport.Matching.best(results, wanted.copy(title = "Blinding Lights - Live")) ?.videoId
            ?: PlaylistImport.Matching.best(results, wanted.copy(title = "Blinding Lights (Live)"))?.videoId)
        // Far longer than the original: another recording.
        assertNull(PlaylistImport.Matching.best(listOf(track("long0000001", "Blinding Lights", "The Weeknd", 400.0)), wanted))
        // "(feat. …)" and " - Remastered" don't stand in the way; accents neither.
        assertEquals("ok000000001", PlaylistImport.Matching.best(
            listOf(track("ok000000001", "Despacito", "Luis Fonsi", 228.0)),
            PlaylistImport.Row("Despacito (feat. Daddy Yankee) - Remastered", listOf("Luis Fonsí"), duration = 229.0),
        )?.videoId)
    }

    @Test
    fun liveSpotifyPlaylistIsReadAndMatched() = runBlocking {
        if (System.getProperty("seaglass.live") != "true") return@runBlocking
        val html = runCatching {
            okhttp3.Request.Builder().url("https://open.spotify.com/embed/playlist/37i9dQZF1DXcBWIGoYBM5M")
                .header("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)").build()
                .let { com.onda.seaglass.core.Http.client.newCall(it).execute().use { r -> r.body.string() } }
        }.getOrElse {
            println("skip: Spotify refused this machine ($it)")
            return@runBlocking
        }
        val source = PlaylistImport.parseSpotifyEmbed(html)
        println("spotify: ${source.name}, ${source.rows.size} songs, first ${source.rows.firstOrNull()?.label}")
        assertTrue(source.rows.size >= 10, "a public playlist's songs")
        // A song YouTube Music has had for years. From some networks its song search answers only
        // other people's uploads (no duration, another channel as the artist), which the iPhone's
        // rules rightly refuse: then the check stops there.
        val songs = runCatching { InnerTube.searchSongs("The Weeknd Blinding Lights") }.getOrElse {
            println("skip: YouTube refused this machine ($it)")
            return@runBlocking
        }
        if (songs.none { it.primaryArtist == "The Weeknd" && it.duration != null }) {
            println("skip: YouTube Music's song search answers only uploads from this machine")
            return@runBlocking
        }
        val match = PlaylistImport.bestMatch(PlaylistImport.Row("Blinding Lights", listOf("The Weeknd"), duration = 200.0))
        println("match: ${match?.title} – ${match?.artist}")
        assertTrue(match?.primaryArtist == "The Weeknd", "the song found on YouTube Music: $match")
    }
}
