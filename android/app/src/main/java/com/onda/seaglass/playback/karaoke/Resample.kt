package com.onda.seaglass.playback.karaoke

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.min
import kotlin.math.sin

/**
 * Sample rate conversion of interleaved stereo audio with a windowed-sinc filter (32 taps, a
 * Blackman window, the cutoff just under the lower Nyquist): between YouTube's 48 kHz and the karaoke
 * model's 44.1 kHz, both ways, with the time of the first frame kept.
 */
object Resample {
    private const val HALF = 16
    private const val PHASES = 512

    fun stereo(input: FloatArray, fromRate: Int, toRate: Int): FloatArray {
        if (fromRate == toRate) return input.copyOf()
        val inFrames = input.size / 2
        val outFrames = (inFrames.toLong() * toRate / fromRate).toInt()
        val cutoff = min(1.0, toRate.toDouble() / fromRate) * 0.97
        // The filter at PHASES + 1 fractional offsets, linearly interpolated between.
        val table = Array(PHASES + 1) { phase ->
            val fraction = phase.toDouble() / PHASES
            FloatArray(2 * HALF) { tap ->
                val x = (tap - HALF + 1) - fraction
                val sinc = if (abs(x) < 1e-9) 1.0 else sin(PI * cutoff * x) / (PI * cutoff * x)
                val w = (x + HALF) / (2 * HALF)
                val blackman = if (w <= 0 || w >= 1) 0.0 else 0.42 - 0.5 * cos(2 * PI * w) + 0.08 * cos(4 * PI * w)
                (cutoff * sinc * blackman).toFloat()
            }
        }
        val output = FloatArray(outFrames * 2)
        val step = fromRate.toDouble() / toRate
        for (j in 0 until outFrames) {
            val time = j * step
            val base = floor(time).toInt()
            val position = (time - base) * PHASES
            val phase = position.toInt()
            val mix = (position - phase).toFloat()
            val a = table[phase]
            val b = table[min(phase + 1, PHASES)]
            var left = 0f
            var right = 0f
            for (tap in 0 until 2 * HALF) {
                val frame = base + tap - HALF + 1
                if (frame < 0 || frame >= inFrames) continue
                val h = a[tap] + (b[tap] - a[tap]) * mix
                left += input[frame * 2] * h
                right += input[frame * 2 + 1] * h
            }
            output[j * 2] = left
            output[j * 2 + 1] = right
        }
        return output
    }
}
