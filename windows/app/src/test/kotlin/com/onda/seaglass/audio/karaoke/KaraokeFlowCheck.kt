package com.onda.seaglass.audio.karaoke

import com.onda.seaglass.audio.AudioSink
import com.onda.seaglass.audio.Deck
import com.onda.seaglass.audio.Decoder
import com.onda.seaglass.audio.Engine
import com.onda.seaglass.audio.FileSource
import com.onda.seaglass.audio.NullSink
import com.onda.seaglass.model.Track
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import java.io.File
import java.io.RandomAccessFile
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.test.Test
import kotlin.test.assertTrue

/**
 * The karaoke end to end, as the app runs it: the real model (KARAOKE_MODEL, skipped without it), a
 * song decoded whole, separated piece by piece from where it plays, the status reaching "Ready", and
 * the engine's output then changed by it (the voice-like note reduced), without a step in the sound
 * where it comes in.
 */
class KaraokeFlowCheck {
    private class Capture : AudioSink {
        val samples = ShortArray(Decoder.RATE * 2 * 60)
        var frames = 0
        private val pace = NullSink(speed = 4.0)
        override fun write(buffer: ByteArray, bytes: Int) {
            pace.write(buffer, bytes)
            if (frames * 2 + bytes / 2 > samples.size) return
            for (i in 0 until bytes / 2) samples[frames * 2 + i] = ((buffer[i * 2].toInt() and 0xFF) or (buffer[i * 2 + 1].toInt() shl 8)).toShort()
            frames += bytes / 4
        }
        override val pendingFrames = 0
        override fun pause() {}
        override fun resume() {}
        override fun flush() {}
        override fun close() {}
    }

    /** A chord (the music) under a sung-like note (the voice): [seconds] of it, as 48 kHz stereo 16-bit WAV. */
    private fun song(seconds: Double): File {
        val file = File.createTempFile("seaglass-karaoke-song", ".wav").apply { deleteOnExit() }
        val frames = (seconds * Decoder.RATE).toInt()
        RandomAccessFile(file, "rw").use { out ->
            val data = frames * 4
            val header = java.nio.ByteBuffer.allocate(44).order(java.nio.ByteOrder.LITTLE_ENDIAN)
            header.put("RIFF".toByteArray()).putInt(36 + data).put("WAVEfmt ".toByteArray()).putInt(16).putShort(1).putShort(2)
                .putInt(Decoder.RATE).putInt(Decoder.RATE * 4).putShort(4).putShort(16).put("data".toByteArray()).putInt(data)
            out.write(header.array())
            val buffer = java.nio.ByteBuffer.allocate(data).order(java.nio.ByteOrder.LITTLE_ENDIAN)
            for (i in 0 until frames) {
                val t = i.toDouble() / Decoder.RATE
                val f0 = 220.0 * (1 + 0.01 * sin(2 * PI * 5.5 * t))
                var voice = 0.0
                for (h in 1..30) {
                    val f = f0 * h
                    voice += sin(2 * PI * f * t + h) * (1 / (1 + Math.pow((f - 800) / 500, 2.0)) + 0.5 / (1 + Math.pow((f - 2400) / 600, 2.0))) / h
                }
                val music = 0.12 * sin(2 * PI * 110 * t) + 0.08 * sin(2 * PI * 165 * t + 1)
                val value = ((0.3 * voice + music).coerceIn(-1.0, 1.0) * 32767).toInt().toShort()
                buffer.putShort(value).putShort(value)
            }
            out.write(buffer.array())
        }
        return file
    }

    @Test
    fun theKaraokeSeparatesWhereTheSongPlaysAndTakesTheVoiceOut() {
        val modelFile = System.getenv("KARAOKE_MODEL")?.let { File(it) }?.takeIf { it.isFile } ?: run {
            println("KARAOKE_MODEL isn't set: skipped")
            return
        }
        modelFile.copyTo(KaraokeModel.file().also { it.parentFile.mkdirs() }, overwrite = true)
        val wav = song(40.0)
        val track = Track(videoId = "abcdefghijk", title = "Una canzone", artists = listOf("Un artista"), duration = 40.0)
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val capture = Capture()
        try {
            Engine { capture }.use { engine ->
                engine.volume = 1f
                engine.listener = object : Engine.Listener {
                    override fun advanced(next: Deck) {}
                    override fun ended(deck: Deck) {}
                    override fun failed(deck: Deck, error: Exception) = throw AssertionError(error)
                }
                Karaoke.start(scope, { engine.position }) { { FileSource(wav) } }
                val deck = Deck(Decoder(FileSource(wav)), 1f, 0.0, tag = track)
                Karaoke.attach(deck, track)
                Karaoke.songs(track, null)
                Karaoke.setMode(KaraokeMode.NO_VOCALS)
                Karaoke.setAmount(1f)
                engine.play(deck)
                // Held at the start while the separation runs, so the check is about the result and not about
                // how fast this machine separates against the 4x speed of the silent output.
                engine.pause()
                val until = System.nanoTime() + 150_000_000_000
                var ready = false
                while (System.nanoTime() < until) {
                    if (Karaoke.status.value is KaraokeStatus.Ready) { ready = true; break }
                    Thread.sleep(100)
                }
                println("Karaoke status: ${Karaoke.status.value}")
                assertTrue(ready, "the karaoke became ready (status ${Karaoke.status.value})")
                engine.resume()
                val target = 7 * Decoder.RATE
                val playUntil = System.nanoTime() + 60_000_000_000
                while (capture.frames < target && System.nanoTime() < playUntil) Thread.sleep(50)
                engine.pause()
                assertTrue(capture.frames >= target, "captured ${capture.frames / Decoder.RATE} s")
                // The song as it is over the same stretch (the WAV's samples after its 44-byte header): the
                // engine's output must differ from it by what the karaoke took out, and be quieter.
                val from = Decoder.RATE
                val length = 4 * Decoder.RATE
                val original = FloatArray(length)
                RandomAccessFile(wav, "r").use { file ->
                    val bytes = ByteArray(length * 4)
                    file.seek(44L + from * 4L)
                    file.readFully(bytes)
                    for (i in 0 until length) original[i] = ((bytes[i * 4].toInt() and 0xFF) or (bytes[i * 4 + 1].toInt() shl 8)).toShort() / 32768f
                }
                var originalPower = 0.0
                var heardPower = 0.0
                var removedPower = 0.0
                for (i in 0 until length) {
                    val heard = capture.samples[(from + i) * 2] / 32768.0
                    originalPower += original[i] * original[i]
                    heardPower += heard * heard
                    removedPower += (original[i] - heard) * (original[i] - heard)
                }
                val originalRms = sqrt(originalPower / length)
                val heardRms = sqrt(heardPower / length)
                val removedRms = sqrt(removedPower / length)
                println("RMS of the song: %.4f, with the karaoke: %.4f, taken out: %.4f".format(originalRms, heardRms, removedRms))
                assertTrue(heardRms > 0.01, "not silent")
                assertTrue(removedRms > 0.1 * originalRms, "the karaoke took something out ($removedRms of $originalRms)")
                assertTrue(heardRms < originalRms, "and it is quieter ($heardRms against $originalRms)")
                // No step beyond the song's own where it comes in (the first second).
                var largest = 0
                for (i in 1 until Decoder.RATE) largest = maxOf(largest, abs(capture.samples[i * 2] - capture.samples[(i - 1) * 2]))
                var ownLargest = 0
                RandomAccessFile(wav, "r").use { file ->
                    val bytes = ByteArray(Decoder.RATE * 4)
                    file.seek(44L)
                    file.readFully(bytes)
                    var previous = 0
                    for (i in 0 until Decoder.RATE) {
                        val v = ((bytes[i * 4].toInt() and 0xFF) or (bytes[i * 4 + 1].toInt() shl 8)).toShort().toInt()
                        if (i > 0) ownLargest = maxOf(ownLargest, abs(v - previous))
                        previous = v
                    }
                }
                println("Largest step: $largest (the song's own: $ownLargest)")
                assertTrue(largest <= ownLargest * 1.2 + 50, "largest step $largest against the song's own $ownLargest")
            }
        } finally {
            Karaoke.setMode(KaraokeMode.OFF)
            scope.cancel()
        }
    }
}
