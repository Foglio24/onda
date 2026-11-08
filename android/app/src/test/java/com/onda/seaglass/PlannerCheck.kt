package com.onda.seaglass

import com.onda.seaglass.playback.automix.Analyzer
import com.onda.seaglass.playback.automix.Planner
import com.onda.seaglass.playback.automix.TransitionPlan
import com.onda.seaglass.playback.automix.WindowAnalysis
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.sin
import kotlin.random.Random

/** AutoMix's choices between two songs, on drum patterns made here. */
class PlannerCheck {
    /** [seconds] of a pattern at [bpm], with silence after [soundUntil] (song time from [offset]). */
    private fun window(bpm: Double, offset: Double, seconds: Double = 60.0, soundFrom: Double = 0.0, soundUntil: Double = seconds): WindowAnalysis {
        val rate = Analyzer.SAMPLE_RATE
        val out = FloatArray((seconds * rate).toInt())
        val random = Random(bpm.toInt())
        val period = 60 / bpm
        var t = soundFrom + 0.21
        var beat = 0
        while (t < soundUntil) {
            val start = (t * rate).toInt()
            for (k in 0 until (0.1 * rate).toInt()) {
                val i = start + k
                if (i >= out.size || (i.toDouble() / rate) > soundUntil) break
                val time = k.toDouble() / rate
                out[i] += (random.nextFloat() - 0.5f) * 0.5f * exp(-time * 60).toFloat()
                if (beat % 4 == 0) out[i] += (0.9 * sin(2 * PI * 60 * time) * exp(-time * 18)).toFloat()
            }
            beat++
            t += period
        }
        for (i in out.indices) if (i.toDouble() / rate in soundFrom..soundUntil) out[i] += (random.nextFloat() - 0.5f) * 0.02f
        return Analyzer.analyze(out, offset)
    }

    /** Through the mix, each outgoing beat lands on an incoming beat (played at the plan's rate). */
    private fun assertInStep(plan: TransitionPlan, outgoing: WindowAnalysis, incoming: WindowAnalysis) {
        val outBeats = outgoing.beats.filter { it >= plan.outStart - 0.01 && it <= plan.outEnd + 0.01 }
        val worst = outBeats.maxOf { b ->
            val inTime = plan.inStart + (b - plan.outStart) * plan.incomingRate
            incoming.beats.minOf { abs(it - inTime) } / plan.incomingRate
        }
        println("   ${outBeats.size} beats in step within ${"%.1f".format(worst * 1000)} ms")
        assertTrue("beats off by ${worst * 1000} ms", worst < 0.02)
        // The next song's first beat in the mix is a downbeat, on an outgoing downbeat.
        assertTrue(incoming.downbeats.any { abs(it - plan.inStart) < 0.005 })
        assertTrue(outgoing.downbeats.any { abs(it - plan.outStart) < 0.005 })
    }

    @Test
    fun matchesCloseTempos() {
        val duration = 240.0
        // The outgoing song's last minute: beats until 236 s, then 4 s of silence.
        val outgoing = window(124.0, duration - 60, soundUntil = 56.0)
        val incoming = window(126.0, 0.0, soundFrom = 1.5)
        val plan = Planner.plan(outgoing, duration, incoming)
        println("124 → 126 BPM: ${plan.style}, ${plan.bars} bars, out ${"%.2f".format(plan.outStart)}–${"%.2f".format(plan.outEnd)}, in ${"%.2f".format(plan.inStart)}, rate ${"%.4f".format(plan.incomingRate)}")
        assertEquals(TransitionPlan.Style.BEAT_MATCHED, plan.style)
        assertEquals(8, plan.bars)
        assertEquals(126.0 / 124.0, 1 / plan.incomingRate, 0.01)
        assertTrue(plan.outEnd <= duration - 4 + 0.01)
        assertTrue(plan.inStart in 1.5..3.5)
        assertInStep(plan, outgoing, incoming)

        // The levels: the next song in, the bass passing over half way, the outgoing song out.
        val start = plan.levels(0.0)
        val middle = plan.levels(0.52)
        val end = plan.levels(1.0)
        assertEquals(1f, start.outgoing, 0.001f)
        assertEquals(0f, start.incoming, 0.001f)
        assertTrue(start.incomingBassCut > 0.9f && start.outgoingBassCut < 0.01f)
        assertTrue(middle.incoming > 0.6f && middle.outgoing > 0.6f)
        assertTrue(end.outgoing < 0.01f && end.incoming > 0.99f && end.outgoingBassCut > 0.9f && end.incomingBassCut < 0.01f)
        assertSteady(plan)
    }

    /** All along the mix the two songs' volumes add up to one song's loudness (equal power, within 0.2 dB). */
    private fun assertSteady(plan: TransitionPlan) {
        for (step in 0..100) {
            val levels = plan.levels(step / 100.0)
            val power = levels.outgoing * levels.outgoing + levels.incoming * levels.incoming
            assertEquals("power at ${step}%", 1.0, power.toDouble(), 0.05)
        }
    }

    @Test
    fun matchesHalfTempo() {
        val outgoing = window(124.0, 180.0)
        val incoming = window(62.5, 0.0)
        println("62.5 BPM analysed as ${incoming.tempo} (${incoming.confidence}), ${incoming.beats.size} beats, ${incoming.downbeats.size} downbeats, from ${incoming.soundStart}")
        val plan = Planner.plan(outgoing, 240.0, incoming)
        println("124 → 62.5 BPM: ${plan.style}, rate ${"%.4f".format(plan.incomingRate)}")
        assertEquals(TransitionPlan.Style.BEAT_MATCHED, plan.style)
        assertEquals(124.0 / 125.0, plan.incomingRate, 0.01)
    }

    @Test
    fun blendsDistantTempos() {
        val outgoing = window(124.0, 180.0, soundUntil = 58.0)
        val incoming = window(90.0, 0.0, soundFrom = 2.0)
        val plan = Planner.plan(outgoing, 240.0, incoming)
        println("124 → 90 BPM: ${plan.style}, ${"%.1f".format(plan.overlap)} s, in ${"%.2f".format(plan.inStart)}")
        assertEquals(TransitionPlan.Style.BLEND, plan.style)
        assertEquals(1.0, plan.incomingRate, 0.0)
        assertSteady(plan)
        // No silence: the mix ends with the sound, the next song starts with its own.
        assertEquals(238.0, plan.outEnd, 0.15)
        assertTrue(plan.inStart in 1.9..2.4)
    }
}
