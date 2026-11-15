package com.onda.seaglass.audio

import java.io.Closeable
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.locks.LockSupport
import javax.sound.sampled.AudioFormat
import javax.sound.sampled.AudioSystem
import javax.sound.sampled.DataLine
import javax.sound.sampled.SourceDataLine
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/** Where the mixed sound goes: Windows's audio output, or nowhere at real-time pace (tests, CI). */
interface AudioSink : Closeable {
    /** Blocks until there is room. [bytes] of 16-bit little-endian stereo at 48 kHz. */
    fun write(buffer: ByteArray, bytes: Int)
    /** Frames written but not heard yet: what the position subtracts. */
    val pendingFrames: Int
    fun pause()
    fun resume()
    /** Drops what is waiting to be heard (a seek, a new song). */
    fun flush()
}

/**
 * Windows's audio output through Java Sound (DirectSound): 48 kHz, 16-bit stereo, a fifth of a
 * second of buffer. [device] is a mixer's name from [devices]; null or unknown is Windows's default.
 */
class JavaSoundSink(device: String?) : AudioSink {
    companion object {
        val format = AudioFormat(Decoder.RATE.toFloat(), 16, Decoder.CHANNELS, true, false)

        /** The outputs that can play the engine's format, for Settings. */
        fun devices(): List<String> = runCatching {
            val info = DataLine.Info(SourceDataLine::class.java, format)
            AudioSystem.getMixerInfo().filter { AudioSystem.getMixer(it).isLineSupported(info) }.map { it.name }
                .filter { !it.startsWith("Port ") }
        }.getOrDefault(emptyList())
    }

    private val line: SourceDataLine = run {
        val info = DataLine.Info(SourceDataLine::class.java, format)
        val mixer = device?.let { name -> AudioSystem.getMixerInfo().firstOrNull { it.name == name } }
        val line = (mixer?.let { AudioSystem.getMixer(it).getLine(info) } ?: AudioSystem.getLine(info)) as SourceDataLine
        line.open(format, Decoder.RATE / 5 * 4)
        line.start()
        line
    }

    override fun write(buffer: ByteArray, bytes: Int) {
        var offset = 0
        while (offset < bytes) offset += line.write(buffer, offset, bytes - offset)
    }

    override val pendingFrames: Int get() = (line.bufferSize - line.available()) / 4
    override fun pause() = line.stop()
    override fun resume() = line.start()
    override fun flush() = line.flush()
    override fun close() {
        line.stop()
        line.close()
    }
}

/** Plays nothing, at real-time pace: for tests and machines without sound. */
class NullSink(private val speed: Double = 1.0) : AudioSink {
    private var started = System.nanoTime()
    private var written = 0L
    override fun write(buffer: ByteArray, bytes: Int) {
        written += bytes / 4
        val due = started + (written * 1_000_000_000.0 / Decoder.RATE / speed).toLong()
        val wait = due - System.nanoTime()
        if (wait > 0) LockSupport.parkNanos(wait)
    }
    override val pendingFrames = 0
    override fun pause() {}
    override fun resume() {
        started = System.nanoTime()
        written = 0
    }
    override fun flush() {}
    override fun close() {}
}

/**
 * One song being played: a thread decodes it ahead into a ring of [SECONDS] seconds, which the
 * audio thread reads. The two threads only share the ring's two counters (one writes each), so the
 * audio thread never waits on decoding or the network. A seek is a handshake: the audio thread
 * stops reading, the decoding thread empties the ring and refills it from the new place.
 */
class Deck(
    val decoder: Decoder,
    /** The song's own level for "Volume uniforme" (1 = as it is). */
    @Volatile var gain: Float,
    startAt: Double = 0.0,
    /** Seconds; the container's when it knows, else what the catalogue says. */
    val duration: Double = decoder.duration,
    /** Who this deck plays, for the player (a queue entry). */
    val tag: Any? = null,
) : Closeable {
    companion object {
        const val SECONDS = 8
        private const val BLOCK = 2048
    }

    private val capacity = Decoder.RATE * SECONDS
    private val ring = FloatArray(capacity * Decoder.CHANNELS)
    private val written = AtomicLong(0)
    private val read = AtomicLong(0)

    @Volatile private var seekTo = startAt
    @Volatile var seekGeneration = if (startAt > 0) 1 else 0
        private set
    /** The generation the audio thread stopped reading for. */
    @Volatile var acknowledged = 0
    /** The generation whose audio is in the ring. */
    @Volatile private var ready = 0
    /** Frames of the song before the ring's start (where the last seek landed). */
    @Volatile private var baseFrame = 0L

    @Volatile var ended = false
        private set
    @Volatile var failure: Exception? = null
        private set
    @Volatile private var closed = false

    private val thread = Thread(::decodeLoop, "seaglass-decoder").apply {
        isDaemon = true
        priority = Thread.NORM_PRIORITY + 1
        start()
    }

    /** True while a seek is being served: the audio thread must not read. */
    val seeking: Boolean get() = seekGeneration != ready

    /** Seconds played, as handed to the mix (the sink's delay is the engine's to subtract). */
    val position: Double get() = (baseFrame + read.get()) / Decoder.RATE.toDouble()

    val buffered: Int get() = (written.get() - read.get()).toInt()

    /** Whether the audio thread may start it (a fade in or a gapless switch). */
    val isReady: Boolean get() = !seeking && (ended || buffered >= Decoder.RATE / 2)

    fun seek(seconds: Double) {
        seekTo = seconds.coerceIn(0.0, if (duration > 0) duration else Double.MAX_VALUE)
        ended = false
        seekGeneration += 1
    }

    /** On the audio thread: up to [frames] frames into [into]; 0 when there are none (yet). */
    fun read(into: FloatArray, frames: Int): Int {
        if (seeking) {
            acknowledged = seekGeneration
            return 0
        }
        val start = read.get()
        val available = (written.get() - start).toInt()
        val count = minOf(frames, available)
        if (count <= 0) return 0
        val offset = (start % capacity).toInt()
        val first = minOf(count, capacity - offset)
        System.arraycopy(ring, offset * 2, into, 0, first * 2)
        if (count > first) System.arraycopy(ring, 0, into, first * 2, (count - first) * 2)
        read.set(start + count)
        return count
    }

    /** Nothing left to hear: the decoder is done and the ring is empty. */
    val finished: Boolean get() = ended && !seeking && buffered == 0

    private fun decodeLoop() {
        val block = FloatArray(BLOCK * 2)
        var served = 0
        try {
            while (!closed) {
                val generation = seekGeneration
                if (generation != served) {
                    // Wait for the audio thread to stop reading, then start over from the new place.
                    // A deck that hasn't been heard yet (seeked before playing) needs no handshake.
                    while (!closed && acknowledged != generation && read.get() != 0L && seekGeneration == generation) {
                        LockSupport.parkNanos(1_000_000)
                    }
                    if (seekGeneration != generation) continue
                    val target = seekTo
                    decoder.seek(target)
                    baseFrame = (target * Decoder.RATE).toLong()
                    read.set(0)
                    written.set(0)
                    ended = false
                    served = generation
                    fill(block, Decoder.RATE / 4)
                    ready = generation
                    continue
                }
                if (ended || capacity - (written.get() - read.get()) < BLOCK) {
                    LockSupport.parkNanos(5_000_000)
                    continue
                }
                fill(block, BLOCK)
            }
        } catch (e: Exception) {
            failure = e
            ended = true
            ready = seekGeneration
        }
    }

    /** Decodes up to [frames] frames into the ring. */
    private fun fill(block: FloatArray, frames: Int) {
        var left = frames
        while (left > 0 && !closed) {
            val count = decoder.read(block, minOf(BLOCK, left, capacity - (written.get() - read.get()).toInt()))
            if (count == 0) {
                ended = true
                return
            }
            val start = written.get()
            val offset = (start % capacity).toInt()
            val first = minOf(count, capacity - offset)
            System.arraycopy(block, 0, ring, offset * 2, first * 2)
            if (count > first) System.arraycopy(block, first * 2, ring, 0, (count - first) * 2)
            written.set(start + count)
            left -= count
        }
    }

    override fun close() {
        closed = true
        thread.join(2_000)
        runCatching { decoder.close() }
    }
}

/**
 * The player's sound: one thread that mixes the playing deck (and the next one, during a
 * crossfade), runs the equalizer and the volume, and writes to the [AudioSink]. Everything the
 * other threads change is a volatile value read once per block; the thread allocates nothing.
 * Events (a song ended, the next one took over) go to [listener] on another thread.
 */
class Engine(private val sinkFactory: () -> AudioSink) : Closeable {
    interface Listener {
        /** [next] has taken over from the deck that was playing (closed by then). */
        fun advanced(next: Deck)
        /** The playing deck reached its end with nothing after it. */
        fun ended(deck: Deck)
        /** The playing deck failed (network, file). */
        fun failed(deck: Deck, error: Exception)
    }

    companion object {
        const val BLOCK = 1024
    }

    @Volatile var listener: Listener? = null
    @Volatile var current: Deck? = null
        private set
    @Volatile var next: Deck? = null
        private set
    @Volatile var playing = false
        private set
    /** 0…1, the player's volume slider (applied with a ramp, so it never clicks). */
    @Volatile var volume = 0.8f
    /** Seconds of the crossfade between songs; 0 = gapless. */
    @Volatile var crossfade = 0.0
    /** True while the next song is fading in. */
    @Volatile var fading = false
        private set

    private val events = Executors.newSingleThreadExecutor { Thread(it, "seaglass-engine-events").apply { isDaemon = true } }
    private val equalizer = EqualizerProcessor()
    @Volatile private var sink: AudioSink? = null
    @Volatile private var flushRequested = false
    @Volatile private var closed = false
    @Volatile private var sinkFailure: Exception? = null

    /** Frames the current deck has handed out of a fade's length, and that length. */
    private var fadeDone = 0
    private var fadeLength = 0
    private var appliedVolume = 0f

    private val thread = Thread(::renderLoop, "seaglass-audio").apply {
        isDaemon = true
        priority = Thread.MAX_PRIORITY
        start()
    }

    /** Plays [deck] now, dropping what was playing (and anything queued after it). */
    fun play(deck: Deck) {
        val old = current
        val queued = next
        next = null
        current = deck
        fading = false
        flushRequested = true
        playing = true
        if (old != null) events.execute { old.close() }
        if (queued != null && queued !== deck) events.execute { queued.close() }
    }

    /** What plays after the current deck: gapless, or faded in by [crossfade]. Replaces an earlier one. */
    fun queue(deck: Deck?) {
        val old = next
        if (fading && old != null) return
        next = deck
        if (old != null && old !== deck) events.execute { old.close() }
    }

    fun pause() {
        playing = false
    }

    fun resume() {
        if (current != null) playing = true
    }

    fun seek(seconds: Double) {
        val deck = current ?: return
        // A seek during a crossfade lands on the song coming in, which takes over at once.
        deck.seek(seconds)
        flushRequested = true
    }

    /** Stops and drops everything. */
    fun stop() {
        playing = false
        val old = current
        val queued = next
        current = null
        next = null
        fading = false
        flushRequested = true
        events.execute {
            old?.close()
            queued?.close()
        }
    }

    /** Where the listener is in the playing song, in seconds (the output's delay subtracted). */
    val position: Double
        get() {
            val deck = current ?: return 0.0
            val delay = (sink?.pendingFrames ?: 0) / Decoder.RATE.toDouble()
            return maxOf(0.0, deck.position - if (playing) delay else 0.0)
        }

    /** The output can't be opened (no device): the player says so. */
    val outputFailure: Exception? get() = sinkFailure

    /** Opens the output again, on another device (Settings). */
    fun reopenOutput() {
        val old = sink
        sink = null
        runCatching { old?.close() }
    }

    private fun renderLoop() {
        val mix = FloatArray(BLOCK * 2)
        val scratch = FloatArray(BLOCK * 2)
        val bytes = ByteArray(BLOCK * 4)
        var wasPlaying = false
        while (!closed) {
            val deck = current
            if (!playing || deck == null) {
                if (wasPlaying) sink?.pause()
                wasPlaying = false
                // A seek asked while paused still needs the audio thread's acknowledgement.
                deck?.let { if (it.seeking) it.acknowledged = it.seekGeneration }
                LockSupport.parkNanos(10_000_000)
                continue
            }
            val output = sink ?: openSink() ?: run {
                LockSupport.parkNanos(500_000_000)
                null
            } ?: continue
            if (flushRequested) {
                flushRequested = false
                output.flush()
            }
            if (!wasPlaying) {
                output.resume()
                wasPlaying = true
            }
            val frames = render(deck, mix, scratch)
            if (frames == 0) {
                // Waiting for the network or a seek: nothing to write yet.
                LockSupport.parkNanos(2_000_000)
                continue
            }
            equalizer.process(mix, frames)
            // The volume moves to its new value across the block, so a change never clicks.
            val target = volume * volume
            val start = appliedVolume
            for (frame in 0 until frames) {
                val level = start + (target - start) * (frame + 1) / frames
                for (channel in 0 until 2) {
                    val value = (mix[frame * 2 + channel] * level).coerceIn(-1f, 1f)
                    val sample = (value * 32767f).toInt()
                    val index = (frame * 2 + channel) * 2
                    bytes[index] = sample.toByte()
                    bytes[index + 1] = (sample shr 8).toByte()
                }
            }
            appliedVolume = target
            try {
                output.write(bytes, frames * 4)
            } catch (e: Exception) {
                sinkFailure = e
                runCatching { output.close() }
                sink = null
            }
        }
        runCatching { sink?.close() }
    }

    private fun openSink(): AudioSink? = try {
        sinkFactory().also {
            sink = it
            sinkFailure = null
        }
    } catch (e: Exception) {
        // No output device (LineUnavailableException, IllegalArgumentException): the player says so.
        sinkFailure = e
        null
    }

    /** Mixes one block into [mix]; returns its frames (0: nothing to play right now). */
    private fun render(deck: Deck, mix: FloatArray, scratch: FloatArray): Int {
        val failure = deck.failure
        if (failure != null && deck.buffered == 0) {
            playing = false
            current = null
            events.execute { listener?.failed(deck, failure) }
            return 0
        }
        val frames = deck.read(scratch, BLOCK)
        val following = next
        // The crossfade starts when the song has that long left and the next one is ready.
        val fadeSeconds = crossfade
        if (!fading && following != null && fadeSeconds > 0 && deck.duration > 0 && following.isReady) {
            val left = deck.duration - deck.position
            if (left <= fadeSeconds && left > 0.05) {
                fading = true
                fadeDone = 0
                fadeLength = (left * Decoder.RATE).toInt().coerceAtLeast(BLOCK)
            }
        }
        if (fading && following != null) {
            // The song going out: cos²+sin² = 1, so the two together keep the loudness.
            for (frame in 0 until frames) {
                val x = ((fadeDone + frame).toFloat() / fadeLength).coerceIn(0f, 1f)
                val out = cos(x * PI / 2).toFloat() * deck.gain
                mix[frame * 2] = scratch[frame * 2] * out
                mix[frame * 2 + 1] = scratch[frame * 2 + 1] * out
            }
            for (i in frames * 2 until BLOCK * 2) mix[i] = 0f
            val incoming = following.read(scratch, BLOCK)
            for (frame in 0 until incoming) {
                val x = ((fadeDone + frame).toFloat() / fadeLength).coerceIn(0f, 1f)
                val gain = sin(x * PI / 2).toFloat() * following.gain
                mix[frame * 2] += scratch[frame * 2] * gain
                mix[frame * 2 + 1] += scratch[frame * 2 + 1] * gain
            }
            fadeDone += maxOf(frames, incoming)
            if (deck.finished || fadeDone >= fadeLength) takeOver(deck, following)
            return maxOf(frames, incoming)
        }
        for (frame in 0 until frames) {
            mix[frame * 2] = scratch[frame * 2] * deck.gain
            mix[frame * 2 + 1] = scratch[frame * 2 + 1] * deck.gain
        }
        if (frames < BLOCK && deck.finished) {
            if (following != null && following.isReady) {
                // Gapless: the next song goes on in the same block.
                val more = following.read(scratch, BLOCK - frames)
                for (frame in 0 until more) {
                    mix[(frames + frame) * 2] = scratch[frame * 2] * following.gain
                    mix[(frames + frame) * 2 + 1] = scratch[frame * 2 + 1] * following.gain
                }
                takeOver(deck, following)
                return frames + more
            }
            if (following == null) {
                playing = false
                events.execute { listener?.ended(deck) }
            }
        }
        return frames
    }

    private fun takeOver(old: Deck, new: Deck) {
        current = new
        next = null
        fading = false
        events.execute {
            old.close()
            listener?.advanced(new)
        }
    }

    override fun close() {
        closed = true
        thread.join(1_000)
        current?.close()
        next?.close()
        events.shutdown()
    }
}
