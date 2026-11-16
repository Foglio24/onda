package com.onda.seaglass.data

import com.onda.seaglass.model.MusicItem
import com.onda.seaglass.model.Track
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class RecentSearchesTest {
    private val song = Track(videoId = "abcdefghijk", title = "Song", artists = listOf("Artist"), duration = 200.0)

    @Test
    fun newestFirstOnceEachAndAtMostTwenty() {
        var list = emptyList<RecentSearches.Entry>()
        list = RecentSearches.adding(list, RecentSearches.Entry.query("queen"))
        list = RecentSearches.adding(list, RecentSearches.Entry.song(song))
        list = RecentSearches.adding(list, RecentSearches.Entry.query("queen"))
        assertEquals(listOf("query:queen", "song:abcdefghijk"), list.map { it.id }, "picked again: moved to the top, not twice")
        repeat(30) { list = RecentSearches.adding(list, RecentSearches.Entry.query("q$it")) }
        assertEquals(RecentSearches.LIMIT, list.size)
        assertEquals("query:q29", list.first().id)
    }

    @Test
    fun entriesSurviveTheirFileAndOpenTheirPages() {
        val artist = RecentSearches.Entry.item(MusicItem(MusicItem.Kind.ARTIST, "UC123", "Queen", "Artista", "https://img/a"))!!
        val entries = listOf(RecentSearches.Entry.query("bohemian"), RecentSearches.Entry.song(song), artist)
        val read = entries.map { RecentSearches.Entry.fromJson(org.json.JSONObject(it.toJson().toString())) }
        assertEquals(entries, read)
        assertEquals(Route("UC123", MusicItem.Kind.ARTIST), read[2]?.item?.let { Route(it.id, it.kind) })
        assertEquals("abcdefghijk", read[1]?.track?.videoId)
        // A song entry without its song, or an unknown kind, is skipped rather than kept broken.
        assertNull(RecentSearches.Entry.fromJson(org.json.JSONObject("""{"kind":"song","key":"x","title":"t"}""")))
        assertNull(RecentSearches.Entry.fromJson(org.json.JSONObject("""{"kind":"episode","key":"x"}""")))
        assertNull(RecentSearches.Entry.item(MusicItem(MusicItem.Kind.PODCAST, "p", "P", "", null)))
    }

    private data class Route(val id: String, val kind: MusicItem.Kind)
}
