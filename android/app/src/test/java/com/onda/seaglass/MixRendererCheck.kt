package com.onda.seaglass

import com.onda.seaglass.playback.automix.MixRenderer
import com.onda.seaglass.playback.automix.Pcm
import com.onda.seaglass.playback.automix.TransitionPlan
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.log10
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.random.Random

/**
 * AutoMix's rendered mixes: the next song's beats land on the outgoing song's in the file (after
 * its time stretch and a change of sample rate), the two songs' loudness together stays one song's,
 * peaks stay under full scale, and the file starts and ends with the songs as the players play them.
 */
class MixRendererCheck {
    private val outRate = 48_000
    private val inRate = 44_100

    /** Clicks on every beat (a short 3 kHz burst) at [bpm], from [first] seconds of the song's time. */
    private fun clicks(rate: Int, start: Double, seconds: Double, bpm: Double, first: Double, level: Float = 0.5f): Pcm {
        val frames = (seconds * rate).toInt()
        val samples = FloatArray(frames * 2)
        val beat = 60 / bpm
        var time = first
        while (time < start + seconds) {
            val at = ((time - start) * rate).toInt()
            for (i in 0 until (0.004 * rate).toInt()) {
                val f = at + i
                if (f < 0 || f >= frames) continue
                val v = (level * sin(2 * PI * 3000 * i / rate) * (1 - i / (0.004 * rate))).toFloat()
                samples[f * 2] = v
                samples[f * 2 + 1] = v
            }
            time += beat
        }
        return Pcm(samples, rate, start)
    }

    private fun noise(rate: Int, start: Double, seconds: Double, level: Float, seed: Int): Pcm {
        val random = Random(seed)
        val samples = FloatArray((seconds * rate).toInt() * 2) { (random.nextFloat() * 2 - 1) * level }
        return Pcm(samples, rate, start)
    }

    /** Times (seconds into [samples]) where clicks start: the level crossing [threshold], at most one per 0.2 s. */
    private fun onsets(samples: ShortArray, rate: Int, from: Double, to: Double, threshold: Int = 3000): List<Double> {
        val found = mutableListOf<Double>()
        var frame = (from * rate).toInt()
        val last = minOf(samples.size / 2, (to * rate).toInt())
        while (frame < last) {
            if (abs(samples[frame * 2].toInt()) > threshold) {
                found += frame.toDouble() / rate
                frame += (0.2 * rate).toInt()
            } else {
                frame++
            }
        }
        return found
    }

    private fun beatMatched(outStart: Double, bars: Int, beat: Double, inStart: Double, rate: Double) = TransitionPlan(
        style = TransitionPlan.Style.BEAT_MATCHED,
        outStart = outStart, outEnd = outStart + bars * 4 * beat, inStart = inStart, incomingRate = rate,
        bars = bars, swapStart = 0.45, swapEnd = 0.6, filterOut = 0.75, beatLength = beat,
    )

    @Test
    fun beatsLandTogether() {
        // 120 BPM going out (beats at whole half seconds), 116 BPM coming in from its beat at 2 s.
        val plan = beatMatched(outStart = 106.0, bars = 8, beat = 0.5, inStart = 2.0, rate = 120.0 / 116.0)
        val start = plan.outStart - MixRenderer.BEFORE
        val outgoing = clicks(outRate, start, plan.outEnd - start + 0.2, 120.0, first = 90.0)
        val incoming = clicks(inRate, plan.inStart, 40.0, 116.0, first = plan.inStart)
        val alone = MixRenderer.render(plan, outgoing, incoming, 0f, 1f)
        val mix = MixRenderer.render(plan, outgoing, incoming, 1f, 1f)
        assertEquals(outRate, mix.rate)
        println("Mix: ${"%.2f".format(mix.length)} s, the next song at ${"%.3f".format(mix.incomingAt)} s")
        assertEquals(MixRenderer.BEFORE, mix.incomingAt, 0.001)
        assertTrue(mix.length >= plan.outEnd - start + MixRenderer.AFTER - 0.5)

        // The next song's clicks, alone: on the outgoing song's grid (every 0.5 s from where it comes in).
        val heard = onsets(alone.samples, outRate, alone.incomingAt - 0.05, alone.length - 0.1)
        assertTrue("next song's beats found: ${heard.size}", heard.size >= 40)
        var worst = 0.0
        for (time in heard) {
            val off = (time - alone.incomingAt) - Math.round((time - alone.incomingAt) / 0.5) * 0.5
            worst = maxOf(worst, abs(off))
        }
        println("The next song's beats within ${"%.1f".format(worst * 1000)} ms of the outgoing song's")
        assertTrue("beats ${"%.1f".format(worst * 1000)} ms apart", worst < 0.006)

        // The players cross away from the beats: the takeover (the outgoing song alone) and every
        // moment for handing back (the next song alone) fall between clicks.
        val info = mix.write(java.io.File.createTempFile("mix", ".wav"))
        val beatOffset = (info.takeover - 90.0) % 0.5
        println("Takeover at ${"%.3f".format(info.takeover)} s, ${info.quietMoments.size} moments to hand back")
        assertTrue("takeover clear of the beats", beatOffset >= 0.0039 && beatOffset + MixRenderer.CROSSING <= 0.5)
        assertTrue(info.takeover in plan.outStart - 2.5..plan.outStart - 0.6)
        assertTrue(info.quietMoments.size >= 5)
        for (moment in info.quietMoments) {
            val off = (moment - info.incomingAt) % 0.5
            assertTrue("hand-back clear of the beats ($off)", off >= 0.0039 && off + MixRenderer.CROSSING <= 0.5)
        }

        // Where the file says the next song is: its time at a beat is one of its beats.
        for (time in heard.take(20)) {
            val songTime = mix.plan.inStart + (time - mix.incomingAt) * mix.plan.incomingRate
            val off = (songTime - plan.inStart) - Math.round((songTime - plan.inStart) / (60 / 116.0)) * (60 / 116.0)
            assertTrue("song time ${"%.3f".format(songTime)} off its beat by ${"%.1f".format(off * 1000)} ms", abs(off) < 0.008)
        }
    }

    @Test
    fun almostTheSameTempo() {
        // A song into itself: a change of tempo too small for the time stretch to make.
        val plan = beatMatched(outStart = 60.0, bars = 4, beat = 0.5, inStart = 0.5, rate = 0.99995)
        val start = plan.outStart - MixRenderer.BEFORE
        val mix = MixRenderer.render(
            plan, noise(outRate, start, plan.outEnd - start + 0.2, 0.3f, 5), noise(outRate, plan.inStart, 30.0, 0.3f, 6), 1f, 1f,
        )
        assertTrue(mix.length > plan.outEnd - start)
    }

    @Test
    fun startsAndEndsAsTheSongs() {
        val plan = beatMatched(outStart = 60.0, bars = 4, beat = 0.5, inStart = 0.5, rate = 1.0)
        val start = plan.outStart - MixRenderer.BEFORE
        val outgoing = noise(outRate, start, plan.outEnd - start + 0.2, 0.3f, seed = 1)
        val incoming = noise(outRate, plan.inStart, 30.0, 0.3f, seed = 2)
        val mix = MixRenderer.render(plan, outgoing, incoming, 0.8f, 0.6f)
        // Before the next song comes in, the file is the outgoing song at its volume, sample for sample.
        val before = (mix.incomingAt * outRate).toInt() - 10
        var worst = 0
        for (i in 0 until before * 2) worst = maxOf(worst, abs(mix.samples[i] - Math.round(outgoing.samples[i] * 0.8f * 32767)))
        assertTrue("start differs by $worst", worst <= 1)
        // At the end, only the next song at its volume.
        val last = mix.samples.size / 2 - 1
        val songFrame = last - (mix.incomingAt * outRate).toInt()
        val expected = Math.round(incoming.samples[songFrame * 2] * 0.6f * 32767)
        assertTrue("end ${mix.samples[last * 2]} vs $expected", abs(mix.samples[last * 2] - expected) <= 2)
    }

    @Test
    fun loudnessStaysSteady() {
        // Two songs of noise at the same level: together, all along the mix, they're as loud as one.
        val plan = beatMatched(outStart = 60.0, bars = 8, beat = 0.5, inStart = 0.0, rate = 1.0).copy(swapStart = null, swapEnd = null, filterOut = null)
        val start = plan.outStart - MixRenderer.BEFORE
        val mix = MixRenderer.render(
            plan, noise(outRate, start, plan.outEnd - start + 0.2, 0.25f, 3), noise(outRate, 0.0, 40.0, 0.25f, 4), 1f, 1f,
        )
        val one = rms(mix.samples, 0.5, 5.0)
        var low = 0.0
        var high = 0.0
        var t = mix.incomingAt
        while (t < plan.outEnd - start) {
            val db = 20 * log10(rms(mix.samples, t, t + 0.5) / one)
            low = minOf(low, db)
            high = maxOf(high, db)
            t += 0.5
        }
        println("Along the mix: ${"%.2f".format(low)} … ${"%.2f".format(high)} dB from one song")
        assertTrue(low > -1.0 && high < 1.0)
    }

    @Test
    fun peaksStayUnderFullScale() {
        val plan = beatMatched(outStart = 60.0, bars = 4, beat = 0.5, inStart = 0.0, rate = 1.0)
        val start = plan.outStart - MixRenderer.BEFORE
        fun tone(frequency: Double, from: Double, seconds: Double) = Pcm(
            FloatArray((seconds * outRate).toInt() * 2) { (0.97 * sin(2 * PI * frequency * (it / 2) / outRate)).toFloat() },
            outRate, from,
        )
        val mix = MixRenderer.render(plan, tone(440.0, start, plan.outEnd - start + 0.2), tone(660.0, 0.0, 30.0), 1f, 1f)
        val peak = mix.samples.maxOf { abs(it.toInt()) }
        println("Peak ${"%.3f".format(peak / 32767.0)} of full scale")
        assertTrue(peak <= 32767 * 0.985)
    }

    private fun rms(samples: ShortArray, from: Double, to: Double): Double {
        var sum = 0.0
        var count = 0
        for (frame in (from * outRate).toInt() until minOf(samples.size / 2, (to * outRate).toInt())) {
            val v = samples[frame * 2] / 32768.0
            sum += v * v
            count++
        }
        return sqrt(sum / count)
    }
}
