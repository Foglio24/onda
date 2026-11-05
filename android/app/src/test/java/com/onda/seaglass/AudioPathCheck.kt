package com.onda.seaglass

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSpec
import com.onda.seaglass.data.NoStreamException
import com.onda.seaglass.data.Streams
import com.onda.seaglass.playback.audioDataSourceFactory
import com.onda.seaglass.playback.streamUri
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * The player's own data source (`seaglass://` → YouTube link → 1 MB ranges) reading a real song:
 * the whole file, byte for byte as long as YouTube says, and from the middle as a seek asks.
 * Skipped where YouTube refuses audio links to the network (CI's data centre).
 */
@UnstableApi
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class AudioPathCheck {
    @Test
    fun readsWholeSongInRanges() {
        val videoId = "dQw4w9WgXcQ"
        val resolved = try {
            runBlocking { Streams.resolve(videoId) }
        } catch (e: NoStreamException) {
            println("Stream refused here: ${e.detail}")
            assumeTrue("YouTube refused the audio links on this network (${e.detail})", false)
            return
        }
        val total = Uri.parse(resolved.rendition.url).getQueryParameter("clen")!!.toLong()
        println("Rendition: ${resolved.rendition.label} (${resolved.rendition.mime}), $total bytes")

        val source = audioDataSourceFactory().createDataSource()
        val length = source.open(DataSpec(streamUri(videoId)))
        assertEquals(total, length)
        val buffer = ByteArray(64 * 1024)
        var read = 0L
        var first: ByteArray? = null
        while (true) {
            val count = source.read(buffer, 0, buffer.size)
            if (count == C.RESULT_END_OF_INPUT) break
            if (first == null) first = buffer.copyOf(4)
            read += count
        }
        source.close()
        println("Read $read bytes in 1 MB ranges")
        assertEquals(total, read)
        if (resolved.rendition.isOpus) {
            // A WebM file starts with the EBML header.
            assertTrue(first!!.contentEquals(byteArrayOf(0x1A, 0x45, 0xDF.toByte(), 0xA3.toByte())))
        }

        // A seek: from the middle to the end.
        val middle = total / 2
        val rest = source.open(DataSpec.Builder().setUri(streamUri(videoId)).setPosition(middle).build())
        assertEquals(total - middle, rest)
        var tail = 0L
        while (true) {
            val count = source.read(buffer, 0, buffer.size)
            if (count == C.RESULT_END_OF_INPUT) break
            tail += count
        }
        source.close()
        println("Read $tail bytes from the middle")
        assertEquals(total - middle, tail)
    }
}
