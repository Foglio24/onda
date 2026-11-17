package com.onda.seaglass.audio

import com.onda.seaglass.audio.automix.MixOptions
import com.onda.seaglass.audio.automix.Planner
import com.onda.seaglass.audio.automix.TransitionPlan
import com.onda.seaglass.audio.automix.WindowAnalysis
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** What Settings › AutoMix changes in the plan: styles, lengths, the tempo gap, the equaliser and Mix Lab. */
class AutoMixOptionsTest {
    /** A steady song's end (the last 80 s of 240) or start (the first 80 s) at [bpm], at [level] dB. */
    private fun window(start: Double, bpm: Double, level: Float = -14f): WindowAnalysis {
        val end = start + 80
        val beat = 60 / bpm
        val beats = generateSequence(start) { it + beat }.takeWhile { it < end }.toList()
        val downbeats = beats.filterIndexed { i, _ -> i % 4 == 0 }
        return WindowAnalysis(start, end, bpm, beats, downbeats, 0.9, start, end, List(320) { level })
    }

    private fun tail(bpm: Double, level: Float = -14f) = window(160.0, bpm, level)
    private fun head(bpm: Double, level: Float = -14f) = window(0.0, bpm, level)
    private fun plan(outgoing: WindowAnalysis, incoming: WindowAnalysis, options: MixOptions) = Planner.plan(outgoing, 240.0, incoming, options)

    @Test
    fun theMixLengthCapsTheBars() {
        assertEquals(8, plan(tail(120.0), head(120.0), MixOptions(maxBars = 8)).bars)
        assertEquals(16, plan(tail(120.0), head(120.0), MixOptions(maxBars = 16)).bars)
        val long = plan(tail(120.0), head(120.0), MixOptions(maxBars = 32))
        assertEquals(32, long.bars)
        assertTrue(abs(long.overlap - 64.0) < 0.5, "a 32-bar mix at 120 BPM is 64 s: ${long.overlap}")
    }

    @Test
    fun theTempoGapDecidesWhatIsMatched() {
        // 120 → 128 BPM is 6.7 % apart: matched at 8 % and 12 %, not at 4 %.
        assertTrue(plan(tail(120.0), head(128.0), MixOptions(tempoGap = 0.04)).style != TransitionPlan.Style.BEAT_MATCHED)
        assertEquals(TransitionPlan.Style.BEAT_MATCHED, plan(tail(120.0), head(128.0), MixOptions(tempoGap = 0.08)).style)
        // 120 → 140 BPM is 16.7 % apart: matched only as before the options (up to 25 %).
        assertTrue(plan(tail(120.0), head(140.0), MixOptions(tempoGap = 0.12)).style != TransitionPlan.Style.BEAT_MATCHED)
        assertEquals(TransitionPlan.Style.BEAT_MATCHED, plan(tail(120.0), head(140.0), MixOptions.LEGACY).style)
        // Each song covers half the gap: never more than the gap's half either way.
        val matched = plan(tail(120.0), head(128.0), MixOptions(tempoGap = 0.08))
        assertTrue(abs(kotlin.math.ln(matched.incomingRate)) <= kotlin.math.ln(1.08) + 1e-9, "ratio ${matched.incomingRate}")
    }

    @Test
    fun withoutTheEqualiserOnlyTheVolumesChange() {
        val full = plan(tail(120.0), head(120.0), MixOptions())
        assertNotNull(full.swapStart)
        assertNotNull(full.filterOut)
        val flat = plan(tail(120.0), head(120.0), MixOptions(equaliser = false))
        assertNull(flat.swapStart)
        assertNull(flat.swapEnd)
        assertNull(flat.filterOut)
        // Bass handover off, the equaliser on: the filter stays, the bass doesn't pass.
        val noBass = plan(tail(120.0), head(120.0), MixOptions(bassHandover = false))
        assertNull(noBass.swapStart)
        assertNotNull(noBass.filterOut)
    }

    @Test
    fun aCutIsOnADownbeatAndTooShortToHear() {
        val outgoing = tail(120.0)
        val cut = plan(outgoing, head(120.0), MixOptions(style = MixOptions.Style.CUT))
        assertEquals(TransitionPlan.Style.CUT, cut.style)
        assertTrue(cut.overlap in 0.01..0.06, "the cut's overlap ${cut.overlap}")
        assertTrue(outgoing.downbeats.any { abs(it - cut.outStart) < 1e-9 }, "starts on a downbeat: ${cut.outStart}")
        assertTrue(cut.outStart > 120.0, "the song keeps its first half")
    }

    @Test
    fun aPlainFadeHasNoFilterAndNoBassPassing() {
        val fade = plan(tail(120.0), head(120.0), MixOptions(style = MixOptions.Style.FADE))
        assertTrue(fade.style == TransitionPlan.Style.BLEND || fade.style == TransitionPlan.Style.FADE, "style ${fade.style}")
        assertNull(fade.swapStart)
        assertNull(fade.filterOut)
        assertTrue(fade.overlap >= 6, "a real fade: ${fade.overlap}")
    }

    @Test
    fun blendNeverCutsAndStillMatchesBeats() {
        assertEquals(TransitionPlan.Style.BEAT_MATCHED, plan(tail(120.0), head(124.0), MixOptions(style = MixOptions.Style.BLEND)).style)
        val far = plan(tail(120.0), head(171.0), MixOptions(style = MixOptions.Style.BLEND))
        assertTrue(far.overlap >= 6, "no cut: ${far.overlap}")
    }

    @Test
    fun fadeOnTheBeatStartsOnADownbeat() {
        // 118 BPM: the bars don't fall on whole seconds, so a fade ending at 240 s starts off the bars unless told.
        val outgoing = tail(118.0)
        val loose = plan(outgoing, head(120.0), MixOptions(style = MixOptions.Style.FADE, fadeOnBeat = false))
        assertEquals(232.0, loose.outStart, 1e-9, "a fade of 8 s back from the end: $loose")
        val onBeat = plan(outgoing, head(120.0), MixOptions(style = MixOptions.Style.FADE, fadeOnBeat = true))
        assertTrue(outgoing.downbeats.any { abs(it - onBeat.outStart) < 1e-9 }, "starts on a downbeat: ${onBeat.outStart}")
    }

    @Test
    fun energyOpensARisingSongSoonerAndHoldsBackAFallingOne() {
        val steady = plan(tail(120.0), head(120.0), MixOptions())
        val rising = plan(tail(120.0, -16f), head(120.0, -9f), MixOptions(byEnergy = true))
        assertTrue(rising.fadeIn < steady.fadeIn, "a louder next song comes in sooner: ${rising.fadeIn} vs ${steady.fadeIn}")
        val falling = plan(tail(120.0, -9f), head(120.0, -16f), MixOptions(byEnergy = true))
        assertTrue(falling.fadeInFrom > 0.0, "a quieter next song waits: ${falling.fadeInFrom}")
        // Without the option, or with similar levels, nothing changes.
        assertEquals(steady.fadeIn, plan(tail(120.0, -16f), head(120.0, -9f), MixOptions(byEnergy = false)).fadeIn, 1e-12)
        assertEquals(steady.fadeIn, plan(tail(120.0), head(120.0), MixOptions(byEnergy = true)).fadeIn, 1e-12)
    }

    @Test
    fun beforeTheOptionsNothingChanged() {
        // "Mix dal vivo" off: tempos up to 25 % apart, 16 bars at most, everything handed over.
        val legacy = plan(tail(120.0), head(120.0), MixOptions.LEGACY)
        assertEquals(16, legacy.bars)
        assertNotNull(legacy.swapStart)
        assertNotNull(legacy.filterOut)
    }
}
