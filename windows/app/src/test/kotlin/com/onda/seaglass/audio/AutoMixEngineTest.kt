package com.onda.seaglass.audio

import com.onda.seaglass.audio.automix.AutoMix
import com.onda.seaglass.audio.automix.Transition
import com.onda.seaglass.audio.automix.TransitionPlan
import java.io.File
import java.io.RandomAccessFile
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.log10
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * AutoMix in the engine, sample by sample: across a mix the sound never jumps (no step between two
 * samples beyond the songs' own, no rise or dip in loudness), and after it the next song is heard
 * exactly as it is (back at its own speed, through no filter).
 */
class AutoMixEngineTest {
    /** Every frame the engine writes, as 16-bit stereo, at 20 times real time (the next song is queued in time). */
    private class Capture : AudioSink {
        val samples = ShortArray(Decoder.RATE * 2 * 40)
        var frames = 0
        private val pace = NullSink(speed = 20.0)
        override fun write(buffer: ByteArray, bytes: Int) {
            pace.write(buffer, bytes)
            // Keeps the first 40 s (the test runs faster than real time and plays on after).
            if (frames * 2 + bytes / 2 > samples.size) return
            for (i in 0 until bytes / 2) {
                samples[frames * 2 + i] = ((buffer[i * 2].toInt() and 0xFF) or (buffer[i * 2 + 1].toInt() shl 8)).toShort()
            }
            frames += bytes / 4
        }
        override val pendingFrames = 0
        override fun pause() {}
        override fun resume() {}
        override fun flush() {}
        override fun close() {}
    }

    /** A WAV file of [seconds] of [signal] (time in seconds → sample), stereo 48 kHz 16-bit. */
    private fun wav(seconds: Double, signal: (Double) -> Double): File {
        val file = File.createTempFile("seaglass-automix", ".wav").apply { deleteOnExit() }
        val frames = (seconds * Decoder.RATE).toInt()
        RandomAccessFile(file, "rw").use { out ->
            val data = frames * 4
            val header = java.nio.ByteBuffer.allocate(44).order(java.nio.ByteOrder.LITTLE_ENDIAN)
            header.put("RIFF".toByteArray()).putInt(36 + data).put("WAVEfmt ".toByteArray()).putInt(16).putShort(1).putShort(2)
                .putInt(Decoder.RATE).putInt(Decoder.RATE * 4).putShort(4).putShort(16).put("data".toByteArray()).putInt(data)
            out.write(header.array())
            val buffer = java.nio.ByteBuffer.allocate(data).order(java.nio.ByteOrder.LITTLE_ENDIAN)
            for (i in 0 until frames) {
                val value = (signal(i.toDouble() / Decoder.RATE).coerceIn(-1.0, 1.0) * 32767).toInt().toShort()
                buffer.putShort(value).putShort(value)
            }
            out.write(buffer.array())
        }
        return file
    }

    private fun play(plan: TransitionPlan, a: File, b: File, startAt: Double, outgoingTempo: Double): Pair<Capture, Deck> {
        val capture = Capture()
        val advanced = CountDownLatch(1)
        val next = AtomicReference<Deck>()
        Engine { capture }.use { engine ->
            engine.volume = 1f
            engine.listener = object : Engine.Listener {
                override fun advanced(next: Deck) { nextDeck(next); advanced.countDown() }
                fun nextDeck(deck: Deck) = next.set(deck)
                override fun ended(deck: Deck) {}
                override fun failed(deck: Deck, error: Exception) = throw AssertionError(error)
            }
            val first = Deck(Decoder(FileSource(a)), 1f, startAt)
            val second = Deck(Decoder(FileSource(b)), 1f, plan.inStart)
            engine.play(first)
            engine.queue(second, Transition(plan, outgoingTempo))
            assertTrue(advanced.await(30, TimeUnit.SECONDS), "the next song took over")
            // A few seconds of the next song alone after the mix.
            val until = System.nanoTime() + 3_000_000_000
            while (capture.frames < (plan.outEnd - startAt + 4) * Decoder.RATE && System.nanoTime() < until) Thread.sleep(5)
            engine.pause()
        }
        return capture to next.get()
    }

    /** The largest step between two samples in a stretch, and the loudness in 50 ms windows. */
    private fun largestStep(samples: ShortArray, from: Int, to: Int): Int {
        var largest = 0
        for (i in from + 1 until to) largest = maxOf(largest, abs(samples[i * 2] - samples[(i - 1) * 2]))
        return largest
    }

    private fun loudness(samples: ShortArray, from: Int, to: Int): Double {
        var sum = 0.0
        for (i in from until to) sum += samples[i * 2].toDouble() * samples[i * 2]
        return 10 * log10(sum / (to - from) + 1e-9)
    }

    @Test
    fun aBeatMatchedMixGlidesWithoutJumpsAndEndsOnTheUntouchedSong() {
        // Two tones of the same loudness, uncorrelated, as two songs.
        val a = wav(70.0) { t -> 0.25 * sin(2 * PI * 220 * t) }
        val b = wav(70.0) { t -> 0.25 * sin(2 * PI * 331 * t + 1.0) }
        val plan = TransitionPlan(
            style = TransitionPlan.Style.BEAT_MATCHED, outStart = 62.0, outEnd = 69.0, inStart = 2.0, incomingRate = 1.04,
            bars = 4, swapStart = 0.45, swapEnd = 0.6, filterOut = 0.75, beatLength = 0.5,
        )
        val (capture, next) = play(plan, a, b, startAt = 60.0, outgoingTempo = 120.0)
        val frames = capture.frames
        assertTrue(frames > 10 * Decoder.RATE, "captured ${frames / Decoder.RATE} s")
        // Each song alone moves by at most 2π·f·A per sample: 0.25·sin at 331 Hz → about 0.011 of full scale.
        val ownStep = (2 * PI * 331 * 1.05 / Decoder.RATE * 0.25 * 32767).toInt()
        val step = largestStep(capture.samples, 1, frames)
        assertTrue(step <= ownStep * 2.2 + 8, "largest step between two samples $step (the songs' own: about $ownStep)")
        // Loudness in 50 ms windows through the whole capture: no window more than 3 dB off its neighbour.
        val window = Decoder.RATE / 20
        var worst = 0.0
        var previous = loudness(capture.samples, 0, window)
        var at = window
        while (at + window <= frames) {
            val level = loudness(capture.samples, at, at + window)
            worst = maxOf(worst, abs(level - previous))
            previous = level
            at += window
        }
        assertTrue(worst < 3.0, "loudness jumps by $worst dB between 50 ms windows")
        // After the mix: the next song's own samples, one for one (back at its speed, through nothing).
        val takeOverFrame = ((plan.outEnd - 60.0) * Decoder.RATE).toInt()
        val check = takeOverFrame + Decoder.RATE / 2
        val expected = Decoder(FileSource(b)).use { decoder ->
            // Where the next song was at that moment: find the alignment by matching a stretch.
            val all = FloatArray(Decoder.RATE * 70 * 2)
            var got = 0
            val block = FloatArray(8192 * 2)
            while (true) {
                val n = decoder.read(block, 8192)
                if (n == 0) break
                System.arraycopy(block, 0, all, got * 2, minOf(n * 2, all.size - got * 2))
                got += n
            }
            all
        }
        val probe = IntArray(64) { capture.samples[(check + it) * 2].toInt() }
        var match = -1
        for (offset in 0 until 70 * Decoder.RATE - 64) {
            var ok = true
            for (k in 0 until 64) {
                if (abs((expected[(offset + k) * 2] * 32767).toInt() - probe[k]) > 1) { ok = false; break }
            }
            if (ok) { match = offset; break }
        }
        assertTrue(match > 0, "the next song's own samples are found after the mix")
        var mismatches = 0
        for (k in 0 until Decoder.RATE) {
            if (abs((expected[(match + k) * 2] * 32767).toInt() - capture.samples[(check + k) * 2]) > 1) mismatches++
        }
        assertEquals(0, mismatches, "a second after the mix, every sample is the next song's own")
    }

    @Test
    fun aBlendKeepsTheLoudnessAndNeverSteps() {
        val a = wav(70.0) { t -> 0.25 * sin(2 * PI * 196 * t) }
        val b = wav(70.0) { t -> 0.25 * sin(2 * PI * 293 * t + 0.5) }
        val plan = TransitionPlan(TransitionPlan.Style.BLEND, outStart = 63.0, outEnd = 69.5, inStart = 0.0, incomingRate = 1.0, filterOut = 0.5)
        val (capture, _) = play(plan, a, b, startAt = 61.0, outgoingTempo = 0.0)
        val frames = capture.frames
        val ownStep = (2 * PI * 293 / Decoder.RATE * 0.25 * 32767).toInt()
        val step = largestStep(capture.samples, 1, frames)
        assertTrue(step <= ownStep * 2.2 + 8, "largest step $step (own about $ownStep)")
        val window = Decoder.RATE / 20
        var worst = 0.0
        var previous = loudness(capture.samples, 0, window)
        var at = window
        while (at + window <= frames) {
            val level = loudness(capture.samples, at, at + window)
            worst = maxOf(worst, abs(level - previous))
            previous = level
            at += window
        }
        assertTrue(worst < 3.0, "loudness jumps by $worst dB between 50 ms windows")
    }

    @Test
    fun analysesBeatsAndPlansABeatMatchedMix() {
        // Clicks on every beat (a bass thump every bar) over a quiet tone: 120 and 124 BPM.
        fun beats(bpm: Double) = wav(70.0) { t ->
            val beat = 60 / bpm
            val inBeat = t % beat
            val bar = (t / beat).toInt() % 4 == 0
            val click = if (inBeat < 0.03) sin(2 * PI * (if (bar) 60.0 else 2000.0) * inBeat) * (1 - inBeat / 0.03) * 0.8 else 0.0
            click + 0.05 * sin(2 * PI * 440 * t)
        }
        val a = beats(120.0)
        val b = beats(124.0)
        val first = AutoMix.analyze("local:aaaa") { FileSource(a) } ?: error("no analysis")
        val second = AutoMix.analyze("local:bbbb") { FileSource(b) } ?: error("no analysis")
        assertTrue(abs(first.tail.tempo - 120) < 2, "tempo of the first: ${first.tail.tempo}")
        assertTrue(abs(second.head.tempo - 124) < 2, "tempo of the second: ${second.head.tempo}")
        val plan = AutoMix.plan(first, second)
        assertEquals(TransitionPlan.Style.BEAT_MATCHED, plan.style, "plan: $plan")
        assertTrue(abs(plan.incomingRate - 120.0 / 124.0) < 0.02, "the next song slowed to the first's tempo: ${plan.incomingRate}")
    }
}
