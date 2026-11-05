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

/** An upstream that fails if it is ever opened. */
@UnstableApi
private object NoNetwork : androidx.media3.datasource.DataSource {
    override fun addTransferListener(transferListener: androidx.media3.datasource.TransferListener) = Unit
    override fun open(dataSpec: DataSpec): Long = throw AssertionError("network used for a downloaded song")
    override fun read(buffer: ByteArray, offset: Int, length: Int): Int = throw AssertionError("network used")
    override fun getUri(): Uri? = null
    override fun close() = Unit
}

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

    /** A download as the download manager makes it, then read back with no network, as the player does offline. */
    @Test
    fun downloadsAndPlaysOffline() {
        val videoId = "dQw4w9WgXcQ"
        try {
            runBlocking { Streams.resolve(videoId) }
        } catch (e: NoStreamException) {
            assumeTrue("YouTube refused the audio links on this network (${e.detail})", false)
            return
        }
        val context = org.robolectric.RuntimeEnvironment.getApplication()
        val folder = java.io.File(context.cacheDir, "download-check").apply { deleteRecursively() }
        val cache = androidx.media3.datasource.cache.SimpleCache(
            folder, androidx.media3.datasource.cache.NoOpCacheEvictor(), androidx.media3.database.StandaloneDatabaseProvider(context),
        )
        val writing = androidx.media3.datasource.cache.CacheDataSource.Factory()
            .setCache(cache).setUpstreamDataSourceFactory(com.onda.seaglass.playback.downloadDataSourceFactory())
        val item = androidx.media3.common.MediaItem.Builder().setUri(streamUri(videoId)).setCustomCacheKey(videoId).build()
        androidx.media3.exoplayer.offline.ProgressiveDownloader(item, writing).download(null)
        val stored = cache.getCachedBytes(videoId, 0, C.LENGTH_UNSET.toLong())
        println("Downloaded $stored bytes")
        assertTrue(stored > 100_000)

        // Read back from the cache alone: the upstream fails if anything is missing.
        val reading = androidx.media3.datasource.cache.CacheDataSource.Factory()
            .setCache(cache)
            .setCacheKeyFactory { spec -> spec.key ?: spec.uri.host!! }
            .setCacheWriteDataSinkFactory(null)
            .setUpstreamDataSourceFactory { NoNetwork }
            .createDataSource()
        val length = reading.open(DataSpec(streamUri(videoId)))
        val buffer = ByteArray(64 * 1024)
        var read = 0L
        while (true) {
            val count = reading.read(buffer, 0, buffer.size)
            if (count == C.RESULT_END_OF_INPUT) break
            read += count
        }
        reading.close()
        println("Read $read of $length bytes offline")
        assertEquals(stored, read)
        cache.release()
    }
}
