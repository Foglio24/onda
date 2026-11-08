package com.onda.seaglass

import com.onda.seaglass.data.AudioQuality
import com.onda.seaglass.data.NoStreamException
import com.onda.seaglass.data.Streams
import com.onda.seaglass.playback.karaoke.Fft
import com.onda.seaglass.playback.karaoke.KaraokeModel
import com.onda.seaglass.playback.karaoke.MdxSeparator
import com.onda.seaglass.playback.karaoke.MdxSpectrogram
import com.onda.seaglass.playback.karaoke.Resample
import kotlinx.coroutines.runBlocking
import okhttp3.Request
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.net.URI
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.log10
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.random.Random

/**
 * The AI karaoke's sums: the FFT, the model's spectrograms (there and back give the piece again), the
 * sample rate conversion, and the real vocal model on a real song, run by ONNX Runtime as on the phone:
 * a voice found in the chorus and next to none in the instrumental intro.
 */
class KaraokeCheck {
    @Test
    fun fftMatchesTheDft() {
        for (n in listOf(2048, 6144)) {
            val random = Random(n)
            val re = FloatArray(n) { random.nextFloat() - 0.5f }
            val im = FloatArray(n) { random.nextFloat() - 0.5f }
            val fr = re.copyOf()
            val fi = im.copyOf()
            Fft(n).transform(fr, fi)
            var worst = 0.0
            for (k in listOf(0, 1, 7, n / 3, n / 2, n - 1)) {
                var sr = 0.0
                var si = 0.0
                for (t in 0 until n) {
                    val angle = -2 * PI * k.toLong() * t / n
                    sr += re[t] * cos(angle) - im[t] * sin(angle)
                    si += re[t] * sin(angle) + im[t] * cos(angle)
                }
                worst = maxOf(worst, abs(sr - fr[k]), abs(si - fi[k]))
            }
            println("FFT $n: within ${"%.1e".format(worst)} of the DFT")
            assertTrue(worst < 2e-3)
            // And back: the inverse (divided by n) gives the input again.
            Fft(n).transform(fr, fi, inverse = true)
            for (t in 0 until n) assertEquals(re[t].toDouble(), fr[t] / n.toDouble(), 1e-4)
        }
    }

    @Test
    fun spectrogramGoesThereAndBack() {
        // A piece of tones and noise below 20 kHz: the model's spectrogram of it, inverted, is the piece.
        val count = MdxSpectrogram.MAX_PIECE
        val random = Random(1)
        val samples = FloatArray(count * 2) {
            val t = (it / 2).toDouble() / MdxSpectrogram.SAMPLE_RATE
            (0.3 * sin(2 * PI * 440 * t) + 0.2 * sin(2 * PI * 3170 * t + it % 2) + 0.05 * (random.nextDouble() - 0.5)).toFloat()
        }
        val spectrogram = MdxSpectrogram()
        val values = FloatArray(MdxSpectrogram.SIZE)
        spectrogram.analyze(samples, 0, 2, count, 0, values)
        spectrogram.analyze(samples, 1, 2, count, 1, values)
        val left = spectrogram.synthesize(values, 0, count)
        val right = spectrogram.synthesize(values, 1, count)
        var worst = 0.0
        for (i in 0 until count) worst = maxOf(worst, abs(left[i] - samples[i * 2]).toDouble(), abs(right[i] - samples[i * 2 + 1]).toDouble())
        println("Spectrogram there and back: within ${"%.1e".format(worst)}")
        assertTrue(worst < 0.01)
    }

    @Test
    fun resamplingKeepsTheSound() {
        fun tone(rate: Int, seconds: Double) = FloatArray((seconds * rate).toInt() * 2) {
            val t = (it / 2).toDouble() / rate
            (0.5 * sin(2 * PI * 1000 * t) + 0.25 * sin(2 * PI * 9000 * t)).toFloat()
        }
        val source = tone(48_000, 1.0)
        val down = Resample.stereo(source, 48_000, 44_100)
        val expected = tone(44_100, 1.0)
        val back = Resample.stereo(down, 44_100, 48_000)
        var worstDown = 0.0
        var worstBack = 0.0
        // Away from the edges, where the filter runs out of samples.
        for (i in 200 until down.size / 2 - 200) worstDown = maxOf(worstDown, abs(down[i * 2] - expected[i * 2]).toDouble())
        for (i in 200 until back.size / 2 - 200) worstBack = maxOf(worstBack, abs(back[i * 2] - source[i * 2]).toDouble())
        println("48 → 44.1 kHz within ${"%.1f".format(20 * log10(worstDown / 0.75))} dB, and back within ${"%.1f".format(20 * log10(worstBack / 0.75))} dB")
        assertTrue(worstDown < 0.0075 && worstBack < 0.0075)
    }

    // The real model.

    private fun model(): File? {
        System.getenv("KARAOKE_MODEL")?.let { path -> File(path).takeIf { it.exists() }?.let { return it } }
        val file = File(System.getProperty("java.io.tmpdir"), "seaglass-karaoke/${KaraokeModel.FILE_NAME}")
        if (file.length() != KaraokeModel.SIZE) {
            file.parentFile?.mkdirs()
            runCatching { URI(KaraokeModel.URL).toURL().openStream().use { input -> file.outputStream().use { input.copyTo(it) } } }
                .onFailure { println("Model download failed: $it") }
        }
        if (!file.exists()) return null
        val digest = MessageDigest.getInstance("SHA-256").digest(file.readBytes()).joinToString("") { "%02x".format(it) }
        assertEquals("the model's checksum", KaraokeModel.SHA256, digest)
        return file
    }

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
                val bytes = com.onda.seaglass.core.Http.send(request) { if (it.code == 206 || it.code == 200) it.body.bytes() else ByteArray(0) }
                if (bytes.isEmpty()) break
                out.write(bytes)
                position += bytes.size
            }
            position >= total
        }
    }

    /** Interleaved stereo at 44.1 kHz from [from] for [seconds], decoded by ffmpeg. */
    private fun decode(file: File, from: Double, seconds: Double): FloatArray {
        val command = listOf(
            "ffmpeg", "-v", "error", "-ss", "%.3f".format(java.util.Locale.ROOT, from), "-i", file.path,
            "-t", "$seconds", "-ac", "2", "-ar", "44100", "-f", "f32le", "-",
        )
        val process = ProcessBuilder(command).start()
        val bytes = process.inputStream.readBytes()
        process.waitFor()
        val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
        return FloatArray(buffer.remaining()).also { buffer.get(it) }
    }

    private fun rms(samples: FloatArray): Double = sqrt(samples.sumOf { it.toDouble() * it } / samples.size)

    @Test
    fun findsTheVoiceInARealSong() {
        assumeTrue("ffmpeg not installed", ffmpeg())
        val modelFile = model()
        assumeTrue("model not available", modelFile != null)
        val song = File(System.getProperty("java.io.tmpdir"), "seaglass-real-music/dQw4w9WgXcQ.webm").apply { parentFile?.mkdirs() }
        if (song.length() == 0L && !download("dQw4w9WgXcQ", song)) song.delete()
        assumeTrue("YouTube refused the song", song.exists())
        MdxSeparator(modelFile!!, Runtime.getRuntime().availableProcessors().coerceAtMost(4)).use { separator ->
            val count = MdxSpectrogram.MAX_PIECE
            // The instrumental intro, then the first chorus ("Never gonna give you up…").
            for ((label, from, voiced) in listOf(Triple("intro", 1.0, false), Triple("chorus", 43.0, true))) {
                val piece = decode(song, from, count / 44_100.0 + 0.1)
                assertTrue(piece.size >= count * 2)
                val started = System.nanoTime()
                val vocals = separator.vocals(piece, 0, count)
                val seconds = (System.nanoTime() - started) / 1e9
                val share = rms(vocals) / rms(piece.copyOf(count * 2))
                println("$label: the voice at ${"%.1f".format(20 * log10(share))} dB of the song (${"%.1f".format(seconds)} s for ${"%.1f".format(count / 44_100.0)} s)")
                if (voiced) assertTrue("a voice in the chorus", share > 0.25) else assertTrue("no voice in the intro", share < 0.12)
                // The rest (the song minus the voice) has less voice in it than the song.
                if (voiced) {
                    val instrumental = FloatArray(count * 2) { piece[it] - vocals[it] }
                    assertTrue(rms(instrumental) < rms(piece.copyOf(count * 2)))
                }
            }
        }
    }
}
