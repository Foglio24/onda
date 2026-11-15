package com.onda.seaglass.audio

import java.io.File
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.sqrt
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** FFmpeg decoding of the formats the app plays: YouTube's Opus (WebM) and AAC, and local MP3 and FLAC. */
class DecoderTest {
    private fun fixture(name: String) = File(javaClass.classLoader.getResource("audio/$name")!!.toURI())

    private fun decodeAll(decoder: Decoder): FloatArray {
        val out = ArrayList<Float>()
        val block = FloatArray(1024 * Decoder.CHANNELS)
        while (true) {
            val frames = decoder.read(block, 1024)
            if (frames == 0) break
            for (i in 0 until frames * Decoder.CHANNELS) out.add(block[i])
        }
        return out.toFloatArray()
    }

    /** How strongly [samples] (left channel) contain a tone at [frequency]. */
    private fun toneLevel(samples: FloatArray, frequency: Double): Double {
        var re = 0.0
        var im = 0.0
        val frames = samples.size / 2
        for (i in 0 until frames) {
            val phase = 2 * PI * frequency * i / Decoder.RATE
            re += samples[i * 2] * kotlin.math.cos(phase)
            im += samples[i * 2] * kotlin.math.sin(phase)
        }
        return 2 * sqrt(re * re + im * im) / frames
    }

    @Test
    fun decodesEveryFormatTo48kStereo() {
        for (name in listOf("tone.webm", "tone.m4a", "tone.mp3", "tone.flac")) {
            Decoder(FileSource(fixture(name))).use { decoder ->
                assertTrue(abs(decoder.duration - 3.0) < 0.1, "$name: duration ${decoder.duration}")
                val samples = decodeAll(decoder)
                val seconds = samples.size / 2.0 / Decoder.RATE
                assertTrue(abs(seconds - 3.0) < 0.1, "$name: decoded $seconds s")
                val middle = samples.copyOfRange(Decoder.RATE * 2 / 2, Decoder.RATE * 2 * 2)
                val level = toneLevel(middle, 440.0)
                println("$name level $level")
                // ffmpeg's test tone has an amplitude of 1/8.
                assertTrue(level > 0.08 && level < 0.17, "$name: 440 Hz at $level")
                // The right channel too (the MP3 is mono, spread to both).
                assertTrue(abs(middle[1001] - middle[1000]) < 1f && abs(middle[2001]) <= 1f, "$name: stereo")
            }
        }
    }

    @Test
    fun readsTags() {
        Decoder(FileSource(fixture("tone.mp3"))).use { decoder ->
            assertEquals("Prova", decoder.tags["title"])
            assertEquals("Seaglass", decoder.tags["artist"])
            assertEquals("MP3", decoder.codecName)
        }
        Decoder(FileSource(fixture("tone.webm"))).use { assertEquals("Opus", it.codecName) }
    }

    @Test
    fun seeksExactly() {
        for (name in listOf("tone.webm", "tone.m4a", "tone.flac")) {
            Decoder(FileSource(fixture(name))).use { decoder ->
                decoder.seek(2.0)
                val rest = decodeAll(decoder)
                val seconds = rest.size / 2.0 / Decoder.RATE
                assertTrue(abs(seconds - 1.0) < 0.03, "$name: after seeking to 2 s, $seconds s left")
                decoder.seek(0.5)
                val again = decodeAll(decoder)
                assertTrue(abs(again.size / 2.0 / Decoder.RATE - 2.5) < 0.03, "$name: seeking back")
            }
        }
    }

    @Test
    fun refusesWhatIsNotAudio() {
        val junk = File.createTempFile("junk", ".bin").apply { writeBytes(ByteArray(4096) { (it * 31).toByte() }); deleteOnExit() }
        val failed = runCatching { Decoder(FileSource(junk)).close() }.isFailure
        assertTrue(failed, "a file that isn't audio is refused, not a crash")
    }
}
