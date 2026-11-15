package com.onda.seaglass.audio

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals

class DecoderStressTest {
    private fun fixture(name: String) = File(javaClass.classLoader.getResource("audio/$name")!!.toURI())

    @Test
    fun opensManyTimesWhileOthersDecodeAndTheCollectorRuns() {
        val failures = java.util.concurrent.atomic.AtomicInteger()
        val threads = (0 until 4).map { t ->
            Thread {
                repeat(60) { i ->
                    val name = listOf("tone.m4a", "tone.webm", "tone.flac", "tone.mp3")[(i + t) % 4]
                    try {
                        Decoder(FileSource(fixture(name))).use { d ->
                            val block = FloatArray(2048)
                            repeat(5) { d.read(block, 1024) }
                        }
                    } catch (e: Exception) {
                        failures.incrementAndGet()
                        println("FAIL $name: $e")
                    }
                    if (i % 10 == 0) System.gc()
                }
            }.apply { start() }
        }
        threads.forEach { it.join() }
        assertEquals(0, failures.get())
    }
}
