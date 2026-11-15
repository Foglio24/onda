package com.onda.seaglass.data

import org.junit.Assert.assertEquals
import org.junit.Test

class LyricsParseTest {
    @Test
    fun parsesLrcTimestamps() {
        val lines = Lyrics.parseLrc(
            """
            [00:12.00]Hello
            [00:15.50][00:16.00]World
            """.trimIndent(),
        )
        assertEquals(3, lines.size)
        assertEquals(12.0, lines[0].time, 0.01)
        assertEquals("Hello", lines[0].text)
        assertEquals("World", lines[1].text)
    }
}
