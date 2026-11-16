package com.onda.seaglass.ui

import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performMouseInput
import androidx.compose.ui.test.rightClick
import androidx.compose.ui.test.runComposeUiTest
import com.onda.seaglass.model.MusicItem
import com.onda.seaglass.model.Track
import kotlin.test.Test
import kotlin.test.assertTrue

/** Right-click opens a song's menu where songs are listed, the search's results included. */
@OptIn(ExperimentalTestApi::class)
class ContextMenuTest {
    private val song = Track(videoId = "abcdefghijk", title = "Una canzone", artists = listOf("Un artista"), duration = 200.0)

    @Test
    fun rightClickOnASongRowOpensItsMenu() = runComposeUiTest {
        setContent { SeaglassTheme { TrackList(listOf(song), "test") } }
        onNodeWithText("Una canzone").performMouseInput { rightClick() }
        waitForIdle()
        assertTrue(onAllNodesWithText(com.onda.seaglass.core.tr("Riproduci dopo")).fetchSemanticsNodes().isNotEmpty(), "the menu opened")
    }

    @Test
    fun rightClickOnASongCardOpensItsMenu() = runComposeUiTest {
        // The search's top result, when it's a song.
        val item = MusicItem(MusicItem.Kind.SONG, song.videoId, song.title, song.artist, null, song)
        setContent { SeaglassTheme { ItemCard(item) {} } }
        onNodeWithText("Una canzone").performMouseInput { rightClick() }
        waitForIdle()
        assertTrue(onAllNodesWithText(com.onda.seaglass.core.tr("Riproduci dopo")).fetchSemanticsNodes().isNotEmpty(), "the menu opened")
    }
}
