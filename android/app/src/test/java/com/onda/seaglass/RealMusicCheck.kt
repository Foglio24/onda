package com.onda.seaglass

import com.onda.seaglass.core.Http
import com.onda.seaglass.data.AudioQuality
import com.onda.seaglass.data.NoStreamException
import com.onda.seaglass.data.Streams
import com.onda.seaglass.playback.automix.Analyzer
import kotlinx.coroutines.runBlocking
import okhttp3.Request
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * AutoMix's analysis on real songs whose tempo is known, decoded here with ffmpeg (the app decodes
 * with Android's MediaCodec). Skipped without ffmpeg or where YouTube refuses the network.
 */
class RealMusicCheck {
    private val songs = listOf(
        Triple("dQw4w9WgXcQ", "Never Gonna Give You Up", 113.0),
        Triple("kJQP7kiw5Fk", "Despacito", 89.0),
        Triple("9bZkp7q19f0", "Gangnam Style", 132.0),
    )

    private fun ffmpeg(): Boolean = runCatching { ProcessBuilder("ffmpeg", "-version").start().waitFor() == 0 }.getOrDefault(false)

    private fun download(videoId: String, file: File): Boolean = runBlocking {
        val resolved = try {
            Streams.resolve(videoId, AudioQuality.MEDIUM)
        } catch (e: NoStreamException) {
            println("$videoId refused: ${e.detail}")
            return@runBlocking false
        }
        val total = resolved.rendition.url.substringAfter("clen=").substringBefore('&').toLong()
        file.outputStream().use { out ->
            var position = 0L
            while (position < total) {
                val end = minOf(total, position + (1 shl 20)) - 1
                val request = Request.Builder().url(resolved.rendition.url).header("User-Agent", Streams.USER_AGENT)
                    .header("Range", "bytes=$position-$end").build()
                val bytes = Http.send(request) { if (it.code == 206 || it.code == 200) it.body.bytes() else ByteArray(0) }
                if (bytes.isEmpty()) {
                    println("$videoId: no audio from YouTube at byte $position")
                    break
                }
                out.write(bytes)
                position += bytes.size
            }
            if (position < total) return@runBlocking false
        }
        true
    }

    private fun decode(file: File, from: Double?, seconds: Double): FloatArray {
        val command = mutableListOf("ffmpeg", "-v", "error")
        if (from != null) command += listOf("-ss", "%.3f".format(java.util.Locale.ROOT, from))
        command += listOf("-i", file.path, "-t", "$seconds", "-ac", "1", "-ar", "${Analyzer.SAMPLE_RATE}", "-f", "f32le", "-")
        val process = ProcessBuilder(command).start()
        val bytes = process.inputStream.readBytes()
        process.waitFor()
        val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
        return FloatArray(buffer.remaining()).also { buffer.get(it) }
    }

    private fun duration(file: File): Double {
        val process = ProcessBuilder("ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", file.path).start()
        return process.inputStream.bufferedReader().readText().trim().toDouble().also { process.waitFor() }
    }

    @Test
    fun tempoOfRealSongs() {
        assumeTrue("ffmpeg not installed", ffmpeg())
        val folder = File(System.getProperty("java.io.tmpdir"), "seaglass-real-music").apply { mkdirs() }
        var checked = 0
        for ((videoId, name, bpm) in songs) {
            val file = File(folder, "$videoId.webm")
            if ((!file.exists() || file.length() == 0L) && !download(videoId, file)) {
                file.delete()
                continue
            }
            val length = duration(file)
            val head = Analyzer.analyze(decode(file, null, 60.0), 0.0)
            val tailStart = maxOf(0.0, length - 60)
            val tail = Analyzer.analyze(decode(file, tailStart, 60.0), tailStart)
            println(
                "$name (${"%.0f".format(length)} s, expected $bpm BPM): head ${"%.1f".format(head.tempo)} BPM " +
                    "(${"%.2f".format(head.confidence)}, sound from ${"%.2f".format(head.soundStart)} s, first downbeat " +
                    "${head.downbeats.firstOrNull()?.let { "%.2f".format(it) }}), tail ${"%.1f".format(tail.tempo)} BPM " +
                    "(${"%.2f".format(tail.confidence)}, sound until ${"%.2f".format(tail.soundEnd)} s)",
            )
            for (found in listOf(head, tail).filter { it.hasBeat }) {
                // Half or double the tempo is the same beat for mixing.
                val ratio = found.tempo / bpm
                val near = listOf(0.5, 1.0, 2.0).any { kotlin.math.abs(ratio - it) < 0.03 * it }
                assert(near) { "$name: ${found.tempo} BPM, expected $bpm" }
            }
            checked++
        }
        assumeTrue("no song could be downloaded here", checked > 0)
    }
}
