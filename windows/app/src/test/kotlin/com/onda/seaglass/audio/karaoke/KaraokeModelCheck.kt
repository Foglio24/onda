package com.onda.seaglass.audio.karaoke

import java.io.File
import java.security.MessageDigest
import kotlin.math.PI
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The real vocal model, run by ONNX Runtime as in the app. It needs the model's file (64 MB, not in
 * the repository): set KARAOKE_MODEL to its path; without it the check skips itself, as the live
 * checks do. Checks the file against the app's checksum, that the library loads and runs, how fast,
 * and that a voice-like sound is kept while drums are mostly dropped.
 */
class KaraokeModelCheck {
    private fun model(): File? = System.getenv("KARAOKE_MODEL")?.let { File(it) }?.takeIf { it.isFile }

    private fun rms(values: FloatArray) = sqrt(values.fold(0.0) { sum, v -> sum + v * v } / values.size)

    @Test
    fun theModelRunsAndSeparates() {
        val file = model() ?: run {
            println("KARAOKE_MODEL isn't set: skipped")
            return
        }
        val digest = MessageDigest.getInstance("SHA-256").digest(file.readBytes()).joinToString("") { "%02x".format(it) }
        assertEquals(KaraokeModel.SHA256, digest, "the model's checksum")
        val count = MdxSpectrogram.MAX_PIECE
        val rate = MdxSpectrogram.SAMPLE_RATE
        val random = Random(3)
        // Drums: noise bursts on a beat, with a low thump.
        val drums = FloatArray(count * 2)
        for (i in 0 until count) {
            val beat = 0.5
            val t = i.toDouble() / rate
            val inBeat = t % beat
            val v = (if (inBeat < 0.08) (random.nextDouble() - 0.5) * 0.8 * (1 - inBeat / 0.08) + 0.6 * sin(2 * PI * 60 * inBeat) * (1 - inBeat / 0.08) else 0.0).toFloat()
            drums[i * 2] = v
            drums[i * 2 + 1] = v
        }
        // A voice-like sound: a sung note (harmonics with a formant-like weighting and vibrato).
        val voice = FloatArray(count * 2)
        for (i in 0 until count) {
            val t = i.toDouble() / rate
            val f0 = 220.0 * (1 + 0.01 * sin(2 * PI * 5.5 * t))
            var v = 0.0
            for (h in 1..30) {
                val f = f0 * h
                val formant = 1.0 / (1 + Math.pow((f - 800) / 500, 2.0)) + 0.5 / (1 + Math.pow((f - 2400) / 600, 2.0))
                v += sin(2 * PI * f * t * (1 + 0.0) + h) * formant / h
            }
            voice[i * 2] = (0.35 * v).toFloat()
            voice[i * 2 + 1] = (0.35 * v).toFloat()
        }
        MdxSeparator(file, 4).use { separator ->
            val started = System.nanoTime()
            val fromDrums = separator.vocals(drums, 0, count)
            val seconds = (System.nanoTime() - started) / 1e9
            val fromVoice = separator.vocals(voice, 0, count)
            println("The model separated ${count / rate.toDouble()} s of sound in %.2f s (first run, with the session's warm-up)".format(seconds))
            assertEquals(count * 2, fromDrums.size)
            assertTrue(fromDrums.all { it.isFinite() } && fromVoice.all { it.isFinite() }, "finite output")
            val drumsKept = rms(fromDrums) / rms(drums)
            val voiceKept = rms(fromVoice) / rms(voice)
            println("Drums kept as vocals: %.0f %%, a sung-like note: %.0f %%".format(drumsKept * 100, voiceKept * 100))
            assertTrue(drumsKept < voiceKept, "the voice-like sound is kept more than the drums ($voiceKept against $drumsKept)")
        }
    }
}
