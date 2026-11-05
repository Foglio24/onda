package com.onda.seaglass

import com.onda.seaglass.playback.automix.MixFilter
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.log10
import kotlin.math.sin
import kotlin.math.sqrt

/** AutoMix's filters take away what they should and leave the rest. */
class MixFilterCheck {
    private fun gainDb(filter: MixFilter.Biquad, frequency: Double): Double {
        val rate = 48_000
        val state = DoubleArray(4)
        var input = 0.0
        var output = 0.0
        for (i in 0 until rate) {
            val x = sin(2 * PI * frequency * i / rate)
            val y = filter.process(x, state, 0)
            if (i > rate / 2) {
                input += x * x
                output += y * y
            }
        }
        return 10 * log10(output / input)
    }

    @Test
    fun bassCutAndHighPass() {
        val shelf = MixFilter.Biquad.lowShelf(48_000, 180.0, -30.0)
        val kick = gainDb(shelf, 50.0)
        val voice = gainDb(shelf, 2_000.0)
        println("Bass cut: 50 Hz ${"%.1f".format(kick)} dB, 2 kHz ${"%.1f".format(voice)} dB")
        assertTrue(kick < -24 && voice > -1)

        val highPass = MixFilter.Biquad.highPass(48_000, 1_200.0)
        val low = gainDb(highPass, 100.0)
        val high = gainDb(highPass, 6_000.0)
        println("High-pass at 1.2 kHz: 100 Hz ${"%.1f".format(low)} dB, 6 kHz ${"%.1f".format(high)} dB")
        assertTrue(low < -35 && high > -1)
        assertTrue(sqrt(1.0) == 1.0)
    }
}
