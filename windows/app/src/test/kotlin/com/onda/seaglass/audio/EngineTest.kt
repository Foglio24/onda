package com.onda.seaglass.audio

import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** The engine end to end on a silent output running 4× real time: playing, seeking, gapless, crossfade, the end. */
class EngineTest {
    private fun fixture(name: String) = File(javaClass.classLoader.getResource("audio/$name")!!.toURI())
    private fun deck(name: String, startAt: Double = 0.0) = Deck(Decoder(FileSource(fixture(name))), 1f, startAt, tag = name)

    private class Recorder : Engine.Listener {
        val advanced = CountDownLatch(1)
        val ended = CountDownLatch(1)
        val next = AtomicReference<Deck?>()
        override fun advanced(next: Deck) {
            this.next.set(next)
            advanced.countDown()
        }
        override fun ended(deck: Deck) = ended.countDown()
        override fun failed(deck: Deck, error: Exception) = throw AssertionError("failed: $error")
    }

    @Test
    fun playsGaplessIntoTheNextSongThenEnds() {
        Engine { NullSink(speed = 4.0) }.use { engine ->
            val recorder = Recorder()
            engine.listener = recorder
            engine.play(deck("tone.webm"))
            engine.queue(deck("tone.m4a"))
            Thread.sleep(250)
            assertTrue(engine.playing && engine.position > 0.3, "playing: ${engine.position}")
            assertTrue(recorder.advanced.await(5, TimeUnit.SECONDS), "the next song takes over")
            assertEquals("tone.m4a", recorder.next.get()?.tag)
            assertTrue(engine.position < 1.0, "the new song starts from its beginning: ${engine.position}")
            assertTrue(recorder.ended.await(5, TimeUnit.SECONDS), "the end of the queue")
            assertTrue(!engine.playing)
        }
    }

    @Test
    fun crossfadesBeforeTheEnd() {
        Engine { NullSink(speed = 4.0) }.use { engine ->
            val recorder = Recorder()
            engine.listener = recorder
            engine.crossfade = 1.0
            engine.play(deck("tone.webm"))
            engine.queue(deck("tone.flac"))
            val started = System.nanoTime()
            var sawFade = false
            while (recorder.advanced.count > 0 && System.nanoTime() - started < 5_000_000_000) {
                if (engine.fading) sawFade = true
                Thread.sleep(5)
            }
            assertTrue(sawFade, "a crossfade happened")
            assertTrue(recorder.advanced.count == 0L, "the next song took over")
            // The fade began a second before the end, so the new song is already about a second in.
            assertTrue(engine.position > 0.7, "position after the fade: ${engine.position}")
        }
    }

    @Test
    fun seeksWhilePlayingAndWhilePaused() {
        Engine { NullSink(speed = 1.0) }.use { engine ->
            engine.play(deck("tone.flac"))
            Thread.sleep(200)
            engine.seek(2.0)
            Thread.sleep(200)
            assertTrue(abs(engine.position - 2.2) < 0.15, "after seeking while playing: ${engine.position}")
            engine.pause()
            engine.seek(0.5)
            Thread.sleep(150)
            assertTrue(abs(engine.position - 0.5) < 0.05, "after seeking while paused: ${engine.position}")
            engine.resume()
            Thread.sleep(200)
            assertTrue(engine.position in 0.6..0.9, "resumed from there: ${engine.position}")
        }
    }

    @Test
    fun startsPartWay() {
        Engine { NullSink(speed = 1.0) }.use { engine ->
            engine.play(deck("tone.m4a", startAt = 1.5))
            Thread.sleep(200)
            assertTrue(abs(engine.position - 1.7) < 0.15, "started at 1.5 s: ${engine.position}")
        }
    }
}
