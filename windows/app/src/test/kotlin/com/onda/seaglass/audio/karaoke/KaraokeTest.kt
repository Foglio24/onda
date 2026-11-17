package com.onda.seaglass.audio.karaoke

import java.io.File
import java.nio.ByteOrder
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.log10
import kotlin.math.sin
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * The AI karaoke's sums: the FFT, the model's spectrograms (there and back give the piece again), the
 * sample rate conversion, the song and vocals kept on disk, and the karaoke in a deck's audio
 * (the voice taken away, kept alone, and the switches that never click). The real model runs in
 * [KaraokeModelCheck] when its file is there.
 */
class KaraokeTest {
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

    // The stems and the tap.

    private val rate = KaraokeStems.RATE

    /** [seconds] of a song: an instrumental (a chord) and a voice (one tone). */
    private fun instrumental(frame: Int) = (0.15 * sin(2 * PI * 220.0 * frame / rate) + 0.1 * sin(2 * PI * 330.0 * frame / rate + 0.5)).toFloat()
    private fun voice(frame: Int) = (0.2 * sin(2 * PI * 1000.0 * frame / rate + 1.0)).toFloat()

    /** Stems of a [seconds] s song whose separation is exact (the vocals are the voice), all pieces done. */
    private fun stems(folder: File, seconds: Int, done: (Int) -> Boolean = { true }): KaraokeStems {
        val frames = seconds * rate
        var at = 0
        KaraokeStems.writeSong(folder, "song", Int.MAX_VALUE, { buffer, count ->
            val n = minOf(count, frames - at)
            for (i in 0 until n) {
                val v = instrumental(at + i) + voice(at + i)
                buffer[i * 2] = v
                buffer[i * 2 + 1] = v
            }
            at += n
            n
        })
        val stems = KaraokeStems.open(folder, "song", frames)
        for (k in 0 until stems.pieces) {
            if (!done(k)) continue
            val from = stems.start(k)
            val count = stems.end(k) - from
            stems.write(k, FloatArray(count * 2) { voice(from + it / 2) })
        }
        return stems
    }

    private fun folder(): File = java.nio.file.Files.createTempDirectory("seaglass-karaoke").toFile().apply { deleteOnExit() }

    /** The song as the deck hands it out ([frames] frames from [first]). */
    private fun deckAudio(first: Int, frames: Int) = FloatArray(frames * 2) { val v = instrumental(first + it / 2) + voice(first + it / 2); v }

    private fun rms(buffer: FloatArray, from: Int, to: Int, reference: (Int) -> Float, first: Int): Double {
        var sum = 0.0
        for (i in from until to) { val d = buffer[i * 2] - reference(first + i); sum += d * d }
        return Math.sqrt(sum / (to - from))
    }

    @Test
    fun theVoiceIsTakenAwayAndTheMusicStays() {
        val stems = stems(folder(), 30)
        assertTrue(stems.complete)
        val tap = KaraokeTap("song")
        tap.stems = stems
        tap.enabled = true
        KaraokeLive.on = true
        try {
            KaraokeLive.vocalsGain = 0f
            KaraokeLive.instrumentalGain = 1f
            val first = 10 * rate
            // Some blocks to let the 20 ms come-in pass, then the one measured.
            var buffer = FloatArray(0)
            var at = first
            repeat(6) { buffer = deckAudio(at, 2048); tap.process(buffer, 0, 2048, at.toLong()); at += 2048 }
            assertTrue(rms(buffer, 0, 2048, ::instrumental, at - 2048) < 0.002, "the music alone: ${rms(buffer, 0, 2048, ::instrumental, at - 2048)}")
            // The voice alone.
            KaraokeLive.vocalsGain = 1f
            KaraokeLive.instrumentalGain = 0f
            repeat(6) { buffer = deckAudio(at, 2048); tap.process(buffer, 0, 2048, at.toLong()); at += 2048 }
            assertTrue(rms(buffer, 0, 2048, ::voice, at - 2048) < 0.002, "the voice alone: ${rms(buffer, 0, 2048, ::voice, at - 2048)}")
            // Half way (Leggera): half of the voice stays.
            KaraokeLive.vocalsGain = 0.5f
            KaraokeLive.instrumentalGain = 1f
            repeat(6) { buffer = deckAudio(at, 2048); tap.process(buffer, 0, 2048, at.toLong()); at += 2048 }
            val half = { f: Int -> instrumental(f) + 0.5f * voice(f) }
            assertTrue(rms(buffer, 0, 2048, half, at - 2048) < 0.002)
        } finally {
            KaraokeLive.on = false
            KaraokeLive.vocalsGain = 1f
            KaraokeLive.instrumentalGain = 1f
        }
    }

    @Test
    fun switchingOnAndOffNeverClicks() {
        val stems = stems(folder(), 30)
        val tap = KaraokeTap("song")
        tap.stems = stems
        KaraokeLive.on = true
        KaraokeLive.vocalsGain = 0f
        KaraokeLive.instrumentalGain = 1f
        try {
            // The song's own step between two samples (a 1 kHz voice at 0.2 and a chord): never exceeded by much.
            var largest = 0f
            var previous = 0f
            var at = 5 * rate
            for (block in 0 until 120) {
                // Enabled for blocks 20..60 and 80..100: the voice goes and comes back, over 20 ms each time.
                tap.enabled = block in 20 until 60 || block in 80 until 100
                val buffer = deckAudio(at, 512)
                tap.process(buffer, 0, 512, at.toLong())
                for (i in 0 until 512) {
                    if (block > 0 || i > 0) largest = maxOf(largest, abs(buffer[i * 2] - previous))
                    previous = buffer[i * 2]
                }
                at += 512
            }
            val own = (2 * PI * 1000 / rate * 0.2 + 2 * PI * 330 / rate * 0.1 + 2 * PI * 220 / rate * 0.15).toFloat()
            assertTrue(largest < own * 1.3f, "the largest step $largest against the song's own $own")
        } finally {
            KaraokeLive.on = false
            KaraokeLive.vocalsGain = 1f
            KaraokeLive.instrumentalGain = 1f
        }
    }

    @Test
    fun whereThePiecesAreNotSeparatedTheSongPlaysAsItIs() {
        // Only the first piece is done: after it (and not enabled) the audio isn't touched.
        val stems = stems(folder(), 60) { it == 0 }
        val tap = KaraokeTap("song")
        tap.stems = stems
        tap.enabled = true
        KaraokeLive.on = true
        KaraokeLive.vocalsGain = 0f
        try {
            val at = 40 * rate
            val buffer = deckAudio(at, 2048)
            val copy = buffer.copyOf()
            tap.process(buffer, 0, 2048, at.toLong())
            assertTrue(buffer.contentEquals(copy), "an unseparated stretch is left as it is")
        } finally {
            KaraokeLive.on = false
            KaraokeLive.vocalsGain = 1f
        }
    }

    @Test
    fun theSongIsKeptWholeAndStemsComeBackAfterReopening() {
        val dir = folder()
        val first = stems(dir, 20) { it < 2 }
        val done = first.doneCount
        assertEquals(2, done)
        val frames = first.frames
        first.close()
        assertEquals(frames, KaraokeStems.songFrames(dir, "song"))
        val again = KaraokeStems.open(dir, "song", frames)
        assertEquals(done, again.doneCount, "the pieces separated before are still done")
        assertNotNull(again.songLeft(1000))
        again.close()
    }
}
