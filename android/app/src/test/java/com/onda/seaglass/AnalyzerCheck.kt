package com.onda.seaglass

import com.onda.seaglass.playback.automix.Analyzer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.sin
import kotlin.random.Random

/** AutoMix's beat tracking on a drum pattern made here, where the right answer is known. */
class AnalyzerCheck {
    /** A minute at [bpm]: a hi-hat on every beat, a kick on each bar's first, a little noise. */
    private fun pattern(bpm: Double, seconds: Double, firstBeat: Double = 0.37): FloatArray {
        val rate = Analyzer.SAMPLE_RATE
        val out = FloatArray((seconds * rate).toInt())
        val random = Random(4)
        for (i in out.indices) out[i] = (random.nextFloat() - 0.5f) * 0.01f
        val period = 60 / bpm
        var beat = 0
        var t = firstBeat
        while (t < seconds) {
            val start = (t * rate).toInt()
            val kick = beat % 4 == 0
            for (k in 0 until (0.12 * rate).toInt()) {
                val i = start + k
                if (i >= out.size) break
                val time = k.toDouble() / rate
                val hat = (random.nextFloat() - 0.5f) * 0.6f * exp(-time * 60).toFloat()
                val low = if (kick) (0.9 * sin(2 * PI * 60 * time) * exp(-time * 18)).toFloat() else 0f
                out[i] += hat + low
            }
            beat++
            t += period
        }
        return out
    }

    @Test
    fun findsTempoBeatsAndBars() {
        for (bpm in listOf(92.0, 124.0, 128.0, 140.0)) {
            val result = Analyzer.analyze(pattern(bpm, 60.0), offset = 100.0)
            println("$bpm BPM → ${"%.2f".format(result.tempo)} BPM, confidence ${"%.2f".format(result.confidence)}, ${result.beats.size} beats")
            assertEquals(bpm, result.tempo, 1.0)
            assertTrue(result.hasBeat)
            // Beats on the pattern's beats (100 s offset, first at 0.37 s), within 20 ms.
            val period = 60 / bpm
            val worst = result.beats.drop(2).dropLast(2).maxOf { b ->
                val phase = ((b - 100.37) / period)
                abs(phase - Math.round(phase)) * period
            }
            val mean = result.beats.drop(2).dropLast(2).map { b -> val ph = (b - 100.37) / period; (ph - Math.round(ph)) * period }.average()
            println("   beats within ${"%.1f".format(worst * 1000)} ms (mean ${"%.1f".format(mean * 1000)} ms)")
            assertTrue("beats off by ${worst * 1000} ms", worst < 0.02)
            // Downbeats on the kicks.
            val downbeatPhase = result.downbeats.drop(1).dropLast(1).map { d -> Math.round((d - 100.37) / period) % 4 }
            assertTrue("downbeats $downbeatPhase", downbeatPhase.all { it == 0L })
        }
    }

    @Test
    fun noBeatInNoise() {
        val random = Random(9)
        val noise = FloatArray(60 * Analyzer.SAMPLE_RATE) { (random.nextFloat() - 0.5f) * 0.3f }
        val result = Analyzer.analyze(noise, offset = 0.0)
        println("Noise → tempo ${result.tempo}, confidence ${result.confidence}")
        assertTrue(!result.hasBeat)
    }

    @Test
    fun findsWhereTheSoundIs() {
        val sound = pattern(120.0, 50.0)
        val withSilence = FloatArray(sound.size + 10 * Analyzer.SAMPLE_RATE)
        sound.copyInto(withSilence, destinationOffset = 4 * Analyzer.SAMPLE_RATE)
        val result = Analyzer.analyze(withSilence, offset = 0.0)
        println("Sound from ${result.soundStart} to ${result.soundEnd}")
        assertTrue(result.soundStart in 3.95..4.45)
        assertTrue(result.soundEnd in 53.5..54.2)
    }
}
