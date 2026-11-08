package com.onda.seaglass

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import com.onda.seaglass.playback.karaoke.KaraokeProcessor
import com.onda.seaglass.playback.karaoke.KaraokeStems
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.file.Files
import kotlin.math.PI
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * The karaoke in the player's audio: the vocals stored piece by piece in any order (crossfaded where
 * pieces overlap, ready only where separated), and the processor taking the voice away from the
 * playing song once its offset is confirmed, ramped, and leaving the song as it is otherwise.
 */
class KaraokeProcessorCheck {
    private val rate = 48_000

    private fun folder(): File = Files.createTempDirectory("karaoke").toFile()

    private fun voice(frame: Int) = (0.3 * sin(2 * PI * 440 * frame / rate)).toFloat()
    private fun band(frame: Int) = (0.2 * sin(2 * PI * 97 * frame / rate)).toFloat()

    /** Writes the voice into piece [k] of [stems] (the separation's result, here exact). */
    private fun separate(stems: KaraokeStems, k: Int, value: ((Int) -> Float)? = null) {
        val from = stems.start(k)
        val count = stems.end(k) - from
        stems.write(k, FloatArray(count * 2) { (value ?: ::voice)(from + it / 2) })
    }

    @Test
    fun piecesInAnyOrder() {
        val frames = rate * 20
        val dir = folder()
        val stems = KaraokeStems.open(dir, "dQw4w9WgXcQ", rate, frames)
        println("${stems.pieces} pieces of 20 s")
        assertTrue(stems.pieces >= 4)
        // The piece playing first, then the next, then the first: readiness follows what's done.
        separate(stems, 2) { 0.5f }
        assertTrue(stems.isReady(stems.start(2) + 2L * KaraokeStems.BLOCK, 100))
        assertFalse(stems.isReady(stems.start(1) + 10L, 100))
        separate(stems, 1) { -0.5f }
        separate(stems, 0) { 0.25f }
        // Across the seam between 1 and 2: 1 fades out as 2 comes in.
        val seam = stems.start(2)
        val shared = (KaraokeStems.OVERLAP.toLong() * rate / 44_100).toInt()
        assertEquals(-0.5f, stems.left(seam), 0.001f)
        assertEquals(0f, stems.left(seam + shared / 2), 0.01f)
        assertEquals(0.5f, stems.left(seam + shared + 10), 0.001f)
        for (k in 3 until stems.pieces) separate(stems, k)
        assertTrue(stems.complete)
        assertTrue(stems.isReady(0, frames))
        stems.close()
        // Opened again: everything is still there.
        val again = KaraokeStems.open(dir, "dQw4w9WgXcQ", rate, frames)
        assertTrue(again.complete)
        assertEquals(0.25f, again.left(100), 0.001f)
        again.close()
    }

    @Test
    fun takesTheVoiceAwayOnceInStep() {
        val frames = rate * 12
        val stems = KaraokeStems.open(folder(), "dQw4w9WgXcQ", rate, frames)
        for (k in 0 until stems.pieces) separate(stems, k)
        val processor = KaraokeProcessor()
        processor.configure(AudioProcessor.AudioFormat(rate, 2, C.ENCODING_PCM_16BIT))
        val start = rate * 3
        processor.flush(AudioProcessor.StreamMetadata(start * 1_000_000L / rate))
        processor.stems = stems
        processor.enabled = true
        processor.vocalsGain = 0f
        processor.instrumentalGain = 1f

        var frame = start
        fun play(count: Int): FloatArray {
            val input = ByteBuffer.allocateDirect(count * 4).order(ByteOrder.nativeOrder())
            for (i in 0 until count) {
                val x = ((voice(frame + i) + band(frame + i)) * 32767).toInt().toShort()
                input.putShort(x)
                input.putShort(x)
            }
            input.flip()
            processor.queueInput(input)
            val output = processor.output.order(ByteOrder.nativeOrder())
            val left = FloatArray(count)
            for (i in 0 until count) {
                left[i] = output.getShort() / 32768f
                output.getShort()
            }
            frame += count
            return left
        }
        fun voiceLeft(samples: FloatArray, from: Int): Double {
            // How much of the voice is left: the output against the band alone.
            var error = 0.0
            var energy = 0.0
            for (i in samples.indices) {
                val e = samples[i] - band(from + i)
                error += e * e
                energy += voice(from + i).toDouble() * voice(from + i)
            }
            return sqrt(error / energy)
        }

        // Before the offset is confirmed, the song plays as it is (and a moment is captured to check).
        val first = play(4096)
        assertTrue("as it is before the check", voiceLeft(first, frame - 4096) > 0.95)
        assertEquals(KaraokeProcessor.Check.CAPTURED, processor.check.state)
        assertEquals(start.toLong(), processor.check.frame)
        // The check finds the player and the separation in step.
        processor.check.offset = 0
        processor.check.state = KaraokeProcessor.Check.MEASURED
        play(2048)
        play(rate / 50)
        val later = play(4096)
        val left = voiceLeft(later, frame - 4096)
        println("Voice left once in step: ${"%.4f".format(left)}")
        assertTrue(left < 0.01)

        // A check that doesn't match (another song) stops it, ramped, and asks for a jump.
        processor.flush(AudioProcessor.StreamMetadata(frame * 1_000_000L / rate))
        val mismatches = processor.mismatches
        play(4096)
        processor.check.offset = null
        processor.check.state = KaraokeProcessor.Check.MEASURED
        play(2048)
        assertEquals(mismatches + 1, processor.mismatches)
        val after = play(4096)
        assertTrue(voiceLeft(after, frame - 4096) > 0.95)
        stems.close()
    }

    @Test
    fun startsOnlyWhenItCanStayAhead() {
        val karaoke = com.onda.seaglass.playback.karaoke.Karaoke
        // Faster than the music: a few seconds ahead are enough.
        assertFalse(karaoke.canPlay(ahead = 2.0, left = 180.0, pace = 0.5))
        assertTrue(karaoke.canPlay(ahead = 5.0, left = 180.0, pace = 0.5))
        // Not measured yet: wait.
        assertFalse(karaoke.canPlay(ahead = 5.0, left = 180.0, pace = null))
        // Half as fast again as the music, 100 s left: it needs 55 s ahead.
        assertFalse(karaoke.canPlay(ahead = 30.0, left = 100.0, pace = 1.5))
        assertTrue(karaoke.canPlay(ahead = 56.0, left = 100.0, pace = 1.5))
        // Everything to the end separated.
        assertTrue(karaoke.canPlay(ahead = 20.0, left = 0.0, pace = 3.0))
    }

    @Test
    fun leavesTheSongAloneWhenOff() {
        val stems = KaraokeStems.open(folder(), "dQw4w9WgXcQ", rate, rate * 8)
        for (k in 0 until stems.pieces) separate(stems, k)
        val processor = KaraokeProcessor()
        processor.configure(AudioProcessor.AudioFormat(rate, 2, C.ENCODING_PCM_16BIT))
        processor.flush(AudioProcessor.StreamMetadata(0))
        processor.stems = stems
        val input = ByteBuffer.allocateDirect(4096 * 4).order(ByteOrder.nativeOrder())
        repeat(4096 * 2) { input.putShort((it * 7 % 2000 - 1000).toShort()) }
        input.flip()
        val copy = ByteBuffer.allocate(input.remaining()).put(input.duplicate()).flip()
        processor.queueInput(input)
        val output = processor.output
        assertEquals(copy, output)
        stems.close()
    }
}
