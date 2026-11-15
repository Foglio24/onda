package com.onda.seaglass.account

import com.onda.seaglass.model.Playlist
import com.onda.seaglass.model.Track
import org.json.JSONObject
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** The iPhone app's merge rules: only what another device removed since the base is removed here. */
class LibraryMergeTest {
    private fun t(id: String) = Track(id.padEnd(11, 'x'), "Song $id", listOf("Artist $id"))
    private fun ids(list: List<Track>) = list.map { it.videoId.trimEnd('x') }

    @Test
    fun firstSyncJoinsBoth() {
        val merged = LibraryMerge.merge(LibrarySnapshot(liked = listOf(t("a"), t("b"))), null, LibrarySnapshot(liked = listOf(t("b"), t("c"))))
        assertEquals(listOf("a", "b", "c"), ids(merged.liked))
    }

    @Test
    fun removalsOnOtherDevicesAndAdditionsHereAreBothKept() {
        val base = LibrarySnapshot(liked = listOf(t("a"), t("b")))
        val remote = LibrarySnapshot(liked = listOf(t("d"), t("a")))
        val local = LibrarySnapshot(liked = listOf(t("c"), t("a"), t("b")))
        assertEquals(listOf("d", "c", "a"), ids(LibraryMerge.merge(local, base, remote).liked))
    }

    @Test
    fun anEmptiedAccountDoesNotEmptyThisComputer() {
        val base = LibrarySnapshot(liked = listOf(t("a")))
        val merged = LibraryMerge.merge(LibrarySnapshot(liked = listOf(t("a"), t("b"))), base, LibrarySnapshot())
        assertEquals(listOf("a", "b"), ids(merged.liked))
    }

    @Test
    fun songsTheServiceRefusesStayHere() {
        val local = Track("local:abc", "Mine", listOf("Me"))
        val upload = LibraryMerge.uploadable(LibrarySnapshot(liked = listOf(local, t("a"))))
        assertEquals(listOf("a"), ids(upload.liked))
        // Next sync: the account doesn't have it, the base doesn't either, so it stays.
        val merged = LibraryMerge.merge(LibrarySnapshot(liked = listOf(local, t("a"))), upload, upload)
        assertTrue(merged.liked.any { it.videoId == "local:abc" })
    }

    @Test
    fun playlistsDeletedElsewhereGoUnlessChangedHere() {
        val p = Playlist(id = "11111111-1111-1111-1111-111111111111", name = "Mix", tracks = listOf(t("a")))
        val base = LibrarySnapshot(playlists = listOf(p))
        assertTrue(LibraryMerge.merge(LibrarySnapshot(playlists = listOf(p)), base, LibrarySnapshot(liked = listOf(t("z")))).playlists.isEmpty())
        val changed = p.copy(tracks = listOf(t("a"), t("b")))
        assertEquals(1, LibraryMerge.merge(LibrarySnapshot(playlists = listOf(changed)), base, LibrarySnapshot(liked = listOf(t("z")))).playlists.size)
    }

    @Test
    fun readsAndWritesTheIPhonesFormat() {
        val json = JSONObject("""{"liked":[{"id":"dQw4w9WgXcQ","videoId":"dQw4w9WgXcQ","title":"Song","artist":"Tyler, The Creator, Kali","primaryArtist":"Tyler, The Creator","artworkURL":"https://x/y.jpg","duration":200}],
            "playlists":[{"id":"A1B2C3D4-0000-0000-0000-000000000000","title":"Road","tracks":[]}],"history":[],"preferences":{"player.crossfade":6}}""")
        val snapshot = LibrarySnapshot.fromJson(json)
        val track = snapshot.liked.single()
        assertEquals(listOf("Tyler, The Creator", "Kali"), track.artists, "a name with a comma stays whole")
        assertEquals("a1b2c3d4-0000-0000-0000-000000000000", snapshot.playlists.single().id)
        val back = snapshot.toJson()
        assertEquals("Tyler, The Creator", back.getJSONArray("liked").getJSONObject(0).getString("primaryArtist"))
        assertEquals(6, back.getJSONObject("preferences").getInt("player.crossfade"), "the iPhone's preferences pass through")
    }
}
