package com.onda.seaglass.audio

import java.io.File
import java.io.RandomAccessFile
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.test.Test
import kotlin.test.assertTrue

/**
 * Tempo through the engine, as the user hears it: with the key lock on, a song 10 % faster keeps
 * its notes (a 440 Hz tone stays 440 Hz); with it off, it plays as a turntable (484 Hz).
 */
class TempoKeyLockTest {
    /** Keeps what the engine writes from the second second on, at four times real time. */
    private class Capture : AudioSink {
        val samples = FloatArray(Decoder.RATE * 2)
        var frames = 0
        private var skipped = 0
        private val pace = NullSink(speed = 4.0)
        override fun write(buffer: ByteArray, bytes: Int) {
            pace.write(buffer, bytes)
            for (i in 0 until bytes / 4) {
                // The first second is left out: the volume's ramp and the stretcher's start.
                if (skipped < Decoder.RATE) {
                    skipped++
                    continue
                }
                if (frames * 2 >= samples.size) return
                val value = ((buffer[i * 4].toInt() and 0xFF) or (buffer[i * 4 + 1].toInt() shl 8)).toShort()
                samples[frames * 2] = value / 32768f
                samples[frames * 2 + 1] = value / 32768f
                frames++
            }
        }
        override val pendingFrames = 0
        override fun pause() {}
        override fun resume() {}
        override fun flush() {}
        override fun close() {}
    }

    private fun tone(seconds: Double, frequency: Double): File {
        val file = File.createTempFile("seaglass-tempo", ".wav").apply { deleteOnExit() }
        val frames = (seconds * Decoder.RATE).toInt()
        RandomAccessFile(file, "rw").use { out ->
            val data = frames * 4
            val header = java.nio.ByteBuffer.allocate(44).order(java.nio.ByteOrder.LITTLE_ENDIAN)
            header.put("RIFF".toByteArray()).putInt(36 + data).put("WAVEfmt ".toByteArray()).putInt(16).putShort(1).putShort(2)
                .putInt(Decoder.RATE).putInt(Decoder.RATE * 4).putShort(4).putShort(16).put("data".toByteArray()).putInt(data)
            out.write(header.array())
            val buffer = java.nio.ByteBuffer.allocate(data).order(java.nio.ByteOrder.LITTLE_ENDIAN)
            for (i in 0 until frames) {
                val value = (0.4 * sin(2 * PI * frequency * i / Decoder.RATE) * 32767).toInt().toShort()
                buffer.putShort(value).putShort(value)
            }
            out.write(buffer.array())
        }
        return file
    }

    /** How strong [frequency] is in the left channel (a single DFT bin). */
    private fun level(samples: FloatArray, frames: Int, frequency: Double): Double {
        var re = 0.0
        var im = 0.0
        for (i in 0 until frames) {
            val phase = 2 * PI * frequency * i / Decoder.RATE
            re += samples[i * 2] * cos(phase)
            im += samples[i * 2] * sin(phase)
        }
        return 2 * sqrt(re * re + im * im) / frames
    }

    private fun play(keyLock: Boolean): Capture {
        val capture = Capture()
        Engine { capture }.use { engine ->
            engine.volume = 1f
            engine.tempo = 1.1
            engine.keyLock = keyLock
            engine.play(Deck(Decoder(FileSource(tone(10.0, 440.0))), 1f))
            val until = System.nanoTime() + 10_000_000_000
            while (capture.frames < Decoder.RATE && System.nanoTime() < until) Thread.sleep(5)
            engine.pause()
        }
        assertTrue(capture.frames >= Decoder.RATE, "a second captured: ${capture.frames}")
        return capture
    }

    @Test
    fun keyLockKeepsThePitchAndTurntableModeRaisesIt() {
        val locked = play(keyLock = true)
        val keptOwn = level(locked.samples, locked.frames, 440.0)
        val keptRaised = level(locked.samples, locked.frames, 484.0)
        assertTrue(keptOwn > 0.2 && keptRaised < keptOwn * 0.2, "key lock on: 440 Hz $keptOwn, 484 Hz $keptRaised")

        val turntable = play(keyLock = false)
        val turntableOwn = level(turntable.samples, turntable.frames, 440.0)
        val turntableRaised = level(turntable.samples, turntable.frames, 484.0)
        assertTrue(turntableRaised > 0.2 && turntableOwn < turntableRaised * 0.2, "key lock off: 440 Hz $turntableOwn, 484 Hz $turntableRaised")
    }
}
