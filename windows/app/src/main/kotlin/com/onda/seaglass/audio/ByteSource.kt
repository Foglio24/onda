package com.onda.seaglass.audio

import com.onda.seaglass.core.Http
import okhttp3.Request
import java.io.Closeable
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.TimeUnit

/** The bytes of a song's file, read at any position: a file on disk, or a stream on YouTube's servers. */
interface ByteSource : Closeable {
    /** In bytes, or -1 when unknown. */
    val size: Long

    /** Up to [length] bytes at [position]; -1 at the end. Blocks until they are there. */
    fun read(position: Long, into: ByteArray, offset: Int, length: Int): Int
}

class FileSource(file: File) : ByteSource {
    private val handle = RandomAccessFile(file, "r")
    override val size: Long = handle.length()

    @Synchronized
    override fun read(position: Long, into: ByteArray, offset: Int, length: Int): Int {
        if (position >= size) return -1
        handle.seek(position)
        return handle.read(into, offset, length)
    }

    override fun close() = handle.close()
}

/**
 * A song streamed from YouTube's servers, as the iPhone and Android apps fetch it: in pieces of
 * [CHUNK] bytes with the `range` parameter (whole-file requests are throttled to real time), a few
 * at once ahead of where it is read, kept in memory once fetched so seeking back costs nothing.
 * When every piece is there, [onComplete] gets the whole file (the cache keeps it).
 */
class StreamSource(
    private val url: String,
    override val size: Long,
    private val onComplete: ((ByteArray) -> Unit)? = null,
) : ByteSource {
    companion object {
        const val CHUNK = 512 * 1024
        private const val AHEAD = 4
        private val pool = Executors.newFixedThreadPool(6) { runnable ->
            Thread(runnable, "seaglass-stream").apply { isDaemon = true }
        }
    }

    private val chunkCount = ((size + CHUNK - 1) / CHUNK).toInt()
    private val chunks = ConcurrentHashMap<Int, ByteArray>()
    private val pending = ConcurrentHashMap<Int, Future<ByteArray>>()
    @Volatile private var closed = false
    @Volatile private var completed = false

    init {
        require(size > 0) { "A stream needs its length" }
        for (index in 0 until minOf(AHEAD, chunkCount)) fetch(index)
    }

    /** Fraction of the file fetched, for the scrubber's buffered part. */
    val fetched: Double get() = chunks.size.toDouble() / chunkCount

    override fun read(position: Long, into: ByteArray, offset: Int, length: Int): Int {
        if (position >= size) return -1
        val index = (position / CHUNK).toInt()
        val chunk = chunk(index)
        for (ahead in 1..AHEAD) if (index + ahead < chunkCount) fetch(index + ahead)
        val start = (position - index.toLong() * CHUNK).toInt()
        val count = minOf(length, chunk.size - start)
        System.arraycopy(chunk, start, into, offset, count)
        return count
    }

    private fun chunk(index: Int): ByteArray {
        chunks[index]?.let { return it }
        var attempt = 0
        while (true) {
            if (closed) throw IOException("closed")
            val future = fetch(index)
            try {
                return future.get(30, TimeUnit.SECONDS)
            } catch (e: Exception) {
                pending.remove(index, future)
                attempt += 1
                if (attempt >= 3) throw IOException(com.onda.seaglass.core.tr("Errore di rete"), e)
                Thread.sleep(400L * attempt)
            }
        }
    }

    private fun fetch(index: Int): Future<ByteArray> {
        chunks[index]?.let { done -> return java.util.concurrent.CompletableFuture.completedFuture(done) }
        return pending.computeIfAbsent(index) {
            pool.submit<ByteArray> {
                if (closed) throw IOException("closed")
                val from = index.toLong() * CHUNK
                val to = minOf(size, from + CHUNK) - 1
                val request = Request.Builder().url("$url&range=$from-$to").build()
                val bytes = Http.client.newCall(request).execute().use { response ->
                    if (!response.isSuccessful) throw IOException("HTTP ${response.code}")
                    response.body.bytes()
                }
                if (bytes.size.toLong() != to - from + 1) throw IOException("Short piece: ${bytes.size}")
                chunks[index] = bytes
                pending.remove(index)
                if (chunks.size == chunkCount) finish()
                bytes
            }
        }
    }

    @Synchronized
    private fun finish() {
        if (completed || closed) return
        completed = true
        val handler = onComplete ?: return
        val whole = ByteArray(size.toInt())
        for (index in 0 until chunkCount) {
            val chunk = chunks[index] ?: return
            System.arraycopy(chunk, 0, whole, index * CHUNK, chunk.size)
        }
        runCatching { handler(whole) }
    }

    override fun close() {
        closed = true
        pending.values.forEach { it.cancel(true) }
        pending.clear()
    }
}
