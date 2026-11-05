package com.onda.seaglass

import com.onda.seaglass.data.AudioQuality
import com.onda.seaglass.data.Streams
import org.junit.Assert.assertEquals
import org.junit.Test

/** Each quality picks the rendition the iPhone app would, from what YouTube offers. */
class QualityCheck {
    private fun r(mime: String, kbps: Int) = Streams.Rendition("https://example/$mime/$kbps", mime, kbps * 1000)

    private val offered = listOf(
        r("audio/webm; codecs=\"opus\"", 50), r("audio/webm; codecs=\"opus\"", 70), r("audio/webm; codecs=\"opus\"", 160),
        r("audio/mp4; codecs=\"mp4a.40.5\"", 48), r("audio/mp4; codecs=\"mp4a.40.2\"", 128),
        r("audio/mp4; codecs=\"ec-3\"", 384),
    )

    @Test
    fun choices() {
        assertEquals(384_000, Streams.choose(offered, AudioQuality.MAX, dolby = true)!!.bitrate)
        assertEquals(160_000, Streams.choose(offered, AudioQuality.MAX, dolby = false)!!.bitrate)
        assertEquals(128_000, Streams.choose(offered, AudioQuality.HIGH, dolby = true)!!.bitrate)
        assertEquals(70_000, Streams.choose(offered, AudioQuality.MEDIUM, dolby = true)!!.bitrate)
        assertEquals(48_000, Streams.choose(offered, AudioQuality.LOW, dolby = true)!!.bitrate)
        // AAC 256 kbps, when offered, is "Massima" without Dolby.
        val premium = offered + r("audio/mp4; codecs=\"mp4a.40.2\"", 256)
        assertEquals(256_000, Streams.choose(premium, AudioQuality.MAX, dolby = false)!!.bitrate)
        // Only Opus: "Alta" falls back to the best Opus.
        val opusOnly = offered.filter { "opus" in it.mime }
        assertEquals(160_000, Streams.choose(opusOnly, AudioQuality.HIGH, dolby = false)!!.bitrate)
    }

    @Test
    fun loudnessGain() {
        assertEquals(1f, Streams.gain(null))
        assertEquals(1f, Streams.gain(-3.0))
        assertEquals(0.5012f, Streams.gain(6.0), 0.001f)
    }
}
