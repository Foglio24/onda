package com.onda.seaglass.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class StreamsChooseTest {
    @Test
    fun prefersAacWhenAsked() {
        val renditions = listOf(
            Streams.Rendition("https://example/o", "audio/webm; codecs=\"opus\"", 160_000),
            Streams.Rendition("https://example/a", "audio/mp4; codecs=\"mp4a.40.2\"", 128_000),
        )
        val chosen = Streams.choose(renditions, AudioQuality.HIGH, preferAac = true)
        assertEquals("https://example/a", chosen?.url)
        assertTrue(chosen!!.isAac)
    }
}
