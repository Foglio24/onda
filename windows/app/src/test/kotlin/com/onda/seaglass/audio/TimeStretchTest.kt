package com.onda.seaglass.audio

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.test.Test
import kotlin.test.assertTrue

/** Tempo's key lock: faster or slower, the same note, and the waveform never breaks. */
class TimeStretchTest {
    private fun tone(seconds: Double, frequency: Double) = FloatArray((seconds * Decoder.RATE).toInt() * 2) { i ->
        (0.5 * sin(2 * PI * frequency * (i / 2) / Decoder.RATE)).toFloat()
    }

    private fun stretch(input: FloatArray, tempo: Double): FloatArray {
        var read = 0
        val source = TimeStretch.Frames { into, offset, max ->
            val count = minOf(max, input.size / 2 - read, 1024)
            System.arraycopy(input, read * 2, into, offset * 2, count * 2)
            read += count
            count
        }
        val stretcher = TimeStretch()
        val out = ArrayList<Float>()
        val block = FloatArray(1024 * 2)
        while (true) {
            val n = stretcher.process(block, 1024, tempo, source)
            if (n == 0) break
            for (i in 0 until n * 2) out.add(block[i])
        }
        return out.toFloatArray()
    }

    /** Strength of [frequency] in the left channel. */
    private fun level(samples: FloatArray, frequency: Double): Double {
        var re = 0.0
        var im = 0.0
        val frames = samples.size / 2
        for (i in 0 until frames) {
            val phase = 2 * PI * frequency * i / Decoder.RATE
            re += samples[i * 2] * cos(phase)
            im += samples[i * 2] * sin(phase)
        }
        return 2 * sqrt(re * re + im * im) / frames
    }

    @Test
    fun keepsThePitchAndChangesTheLength() {
        val input = tone(6.0, 440.0)
        for (tempo in listOf(0.85, 1.0, 1.15)) {
            val out = stretch(input, tempo)
            val seconds = out.size / 2.0 / Decoder.RATE
            assertTrue(abs(seconds - 6.0 / tempo) < 0.2, "at $tempo: $seconds s (expected ${6.0 / tempo})")
            val middle = out.copyOfRange(Decoder.RATE * 2, Decoder.RATE * 2 * 3)
            val same = level(middle, 440.0)
            val shifted = level(middle, 440.0 * tempo)
            assertTrue(same > 0.4, "at $tempo the note is still 440 Hz: $same")
            if (tempo != 1.0) assertTrue(shifted < same * 0.3, "and not ${440 * tempo} Hz: $shifted")
            var largest = 0f
            for (i in 2 until middle.size / 2) largest = maxOf(largest, abs(middle[i * 2] - middle[(i - 1) * 2]))
            val own = (2 * PI * 440 / Decoder.RATE * 0.5).toFloat()
            assertTrue(largest < own * 1.6, "at $tempo no break in the waveform: step $largest, own $own")
        }
    }
}
