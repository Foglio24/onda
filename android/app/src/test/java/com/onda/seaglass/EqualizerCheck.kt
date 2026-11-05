package com.onda.seaglass

import com.onda.seaglass.playback.Equalizer
import com.onda.seaglass.playback.EqualizerBands
import com.onda.seaglass.playback.EqualizerPreset
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The equalizer's presets are Spotify's, and its filters do what the curve on screen says. */
class EqualizerCheck {
    @Test
    fun spotifyPresets() {
        val names = EqualizerPreset.entries.map { it.key }
        assertEquals(
            listOf(
                "flat", "acoustic", "bassBooster", "bassReducer", "classical", "dance", "deep", "electronic", "hipHop", "jazz",
                "latin", "loudness", "lounge", "piano", "pop", "rnb", "rock", "smallSpeakers", "spokenWord", "trebleBooster",
                "trebleReducer", "vocalBooster", "custom",
            ),
            names,
        )
        assertTrue(EqualizerPreset.entries.filter { it.gains != null }.all { it.gains!!.size == EqualizerBands.COUNT })
    }

    @Test
    fun responseFollowsTheBands() {
        // Each preset at its bands' centres: the band's gain less the preamp, within the overlap of neighbours.
        for (preset in EqualizerPreset.entries.filter { it.gains != null && it != EqualizerPreset.FLAT }) {
            val gains = preset.gains!!
            val preamp = 20 * kotlin.math.log10(Equalizer.preamp(gains).toDouble())
            val worst = EqualizerBands.frequencies.indices.maxOf { band ->
                val measured = Equalizer.response(gains, EqualizerBands.frequencies[band], 48_000.0)
                kotlin.math.abs(measured - (gains[band] + preamp))
            }
            println("${preset.key}: within ${"%.1f".format(worst)} dB of its bands")
            assertTrue("${preset.key} off by $worst dB", worst < 3.5)
            // Never louder than unity anywhere: the preamp keeps boosts from clipping.
            val loudest = (0..200).maxOf { Equalizer.response(gains, 20.0 * Math.pow(1000.0, it / 200.0), 48_000.0) }
            assertTrue("${preset.key} peaks at $loudest dB", loudest < 1.5)
        }
        assertEquals(0.0, Equalizer.response(FloatArray(6), 1_000.0), 1e-9)
    }
}
