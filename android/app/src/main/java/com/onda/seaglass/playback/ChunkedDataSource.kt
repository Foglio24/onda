package com.onda.seaglass.playback

import android.net.Uri
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener

/**
 * Reads a YouTube audio file in 1 MB ranges, one after the other. YouTube throttles a plain
 * full-file request to about playback speed but serves ranges at full speed (the iPhone app's
 * `ChunkedDownload` does the same), so songs buffer in a moment and the next one is ready early.
 * The file's size comes from the link's `clen` parameter; without it the request goes through as is.
 */
@OptIn(UnstableApi::class)
class ChunkedDataSource(private val upstream: DataSource) : DataSource {
    private var spec: DataSpec? = null
    private var position = 0L
    private var end = 0L
    private var chunkRemaining = 0L
    private var readInChunk = 0L
    private var chunked = false

    override fun addTransferListener(transferListener: TransferListener) = upstream.addTransferListener(transferListener)

    override fun open(dataSpec: DataSpec): Long {
        val total = dataSpec.uri.getQueryParameter("clen")?.toLongOrNull()
        chunked = total != null && dataSpec.uri.host?.endsWith("googlevideo.com") == true
        if (!chunked || total == null) return upstream.open(dataSpec)
        spec = dataSpec
        position = dataSpec.position
        end = if (dataSpec.length != C.LENGTH_UNSET.toLong()) minOf(total, position + dataSpec.length) else total
        openChunk()
        return end - dataSpec.position
    }

    private fun openChunk() {
        val length = minOf(CHUNK, end - position)
        val range = spec!!.buildUpon().setPosition(position).setLength(length).build()
        readInChunk = 0
        chunkRemaining = upstream.open(range).let { if (it == C.LENGTH_UNSET.toLong()) length else it }
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        if (!chunked) return upstream.read(buffer, offset, length)
        if (length == 0) return 0
        if (chunkRemaining == 0L) {
            upstream.close()
            if (position >= end) return C.RESULT_END_OF_INPUT
            openChunk()
        }
        val read = upstream.read(buffer, offset, minOf(length.toLong(), chunkRemaining).toInt())
        if (read == C.RESULT_END_OF_INPUT) {
            // The server ended the range early: carry on from where it stopped.
            val stalled = readInChunk == 0L
            chunkRemaining = 0
            return if (position >= end || stalled) C.RESULT_END_OF_INPUT else read(buffer, offset, length)
        }
        position += read
        readInChunk += read
        chunkRemaining -= read
        return read
    }

    override fun getUri(): Uri? = upstream.uri

    override fun getResponseHeaders(): Map<String, List<String>> = upstream.responseHeaders

    override fun close() {
        spec = null
        upstream.close()
    }

    private companion object {
        const val CHUNK = 1L shl 20
    }
}
