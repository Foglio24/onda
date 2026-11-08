package com.onda.seaglass.playback.karaoke

import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import androidx.media3.common.util.UnstableApi
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlin.math.roundToLong

/**
 * The karaoke in the main player's audio, before the equalizer: the song's separated vocals
 * ([stems]) taken away from it, or all but they, by [vocalsGain] and [instrumentalGain] (1 and 1:
 * the song as it is). The player's samples are matched to the vocals' by their time in the song
 * (from the position each stream starts at, given when the player starts or jumps) and the offset
 * between the player's decoding and the separation's, which [Karaoke] measures from a moment of the
 * playing song this captures ([check]); until it has, after any jump or song change, the song plays
 * as it is. Where the vocals aren't separated yet, too. Changes of level are ramped over 20 ms.
 */
@OptIn(UnstableApi::class)
class KaraokeProcessor : BaseAudioProcessor() {
    @Volatile var stems: KaraokeStems? = null
    @Volatile var vocalsGain = 1f
    @Volatile var instrumentalGain = 1f
    /** Set while the samples mustn't change (bit-perfect output). */
    @Volatile var bypass = false

    /** A moment of the playing song for [Karaoke] to find the offset of. */
    class Check {
        val samples = ShortArray(FRAMES * 2)
        var frames = 0
        /** The song's frame (as the player counts) of its first sample, and the vocals it's for. */
        var frame = 0L
        var stems: KaraokeStems? = null
        /** Set by [Karaoke]: the offset to add to the player's frames, or null when they don't match. */
        var offset: Int? = null
        /** Set by [Karaoke] when the song couldn't be read to compare: tried again a little later. */
        var inconclusive = false
        /** IDLE → CAPTURED (here) → MEASURED (by [Karaoke]) → IDLE (here, once read). */
        @Volatile var state = IDLE

        companion object {
            const val FRAMES = 8192
            const val IDLE = 0
            const val CAPTURED = 1
            const val MEASURED = 2
        }
    }

    val check = Check()

    /** Raised when the player's frames didn't match the song's vocals (a song changed without a jump). */
    @Volatile var mismatches = 0
        private set

    private var channels = 0
    private var rate = 0
    /** The song's frame (as the player counts) of the next input frame; -1 unknown. */
    private var frame = -1L
    private var matched: KaraokeStems? = null
    private var offset = 0
    private var verified = false
    private var nextCheck = 0L
    private var level = 0f

    override fun onConfigure(inputAudioFormat: AudioProcessor.AudioFormat): AudioProcessor.AudioFormat {
        if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT) return AudioProcessor.AudioFormat.NOT_SET
        channels = inputAudioFormat.channelCount
        rate = inputAudioFormat.sampleRate
        return inputAudioFormat
    }

    override fun onFlush(streamMetadata: AudioProcessor.StreamMetadata) {
        val position = streamMetadata.positionOffsetUs
        frame = if (position == C.TIME_UNSET || position < 0) -1 else (position * rate / 1_000_000.0).roundToLong()
        // After a jump the offset is checked again before the vocals are used.
        verified = false
        nextCheck = 0
        level = 0f
    }

    override fun onReset() {
        frame = -1
        matched = null
        verified = false
        level = 0f
    }

    override fun queueInput(inputBuffer: ByteBuffer) {
        val size = inputBuffer.remaining()
        if (size == 0) return
        val output = replaceOutputBuffer(size)
        val frames = size / (2 * channels)
        val start = frame
        if (frame >= 0) frame += frames

        val song = stems
        if (song !== matched) {
            matched = song
            verified = false
            nextCheck = 0
        }
        val wantsChange = song != null && !bypass && channels == 2 && song.rate == rate && start >= 0 &&
            (vocalsGain != 1f || instrumentalGain != 1f)
        if (!wantsChange || song == null) {
            passThrough(inputBuffer, output)
            return
        }
        readCheck(song)
        // A moment to check the offset against: after a jump or a change of song, then every 5 s.
        if (check.state == Check.IDLE && start >= nextCheck) capture(inputBuffer, start, frames, song)
        val revision = song.revision
        val apply = verified && revision >= 0 && song.isReady(start + offset, frames)
        if (!apply && level == 0f) {
            passThrough(inputBuffer, output)
            return
        }
        val target = if (apply) 1f else 0f
        val step = 1f / (0.02f * rate)
        val vocals = vocalsGain
        val instrumental = instrumentalGain
        val input = inputBuffer.order(ByteOrder.nativeOrder())
        output.order(ByteOrder.nativeOrder())
        for (i in 0 until frames) {
            level = if (level < target) minOf(target, level + step) else maxOf(target, level - step)
            val at = (start + offset + i).toInt()
            val inside = at in 0 until song.frames
            for (c in 0..1) {
                val x = input.getShort() / 32768f
                val v = if (inside) (if (c == 0) song.left(at) else song.right(at)) else 0f
                // The song is vocals and the rest: each at its own volume.
                val changed = instrumental * (x - v) + vocals * v
                val y = x + (changed - x) * level
                output.putShort((y.coerceIn(-1f, 1f) * 32767f).roundToInt().toShort())
            }
        }
        output.flip()
    }

    private fun passThrough(input: ByteBuffer, output: ByteBuffer) {
        output.put(input)
        output.flip()
    }

    /** Copies a loud enough moment of the input for [Karaoke] to compare with the song. */
    private fun capture(input: ByteBuffer, start: Long, frames: Int, song: KaraokeStems) {
        val count = minOf(frames, Check.FRAMES)
        val position = input.position()
        val shorts = input.order(ByteOrder.nativeOrder()).asShortBuffer()
        var loud = 0L
        for (i in 0 until count * 2) {
            val value = shorts.get(i)
            check.samples[i] = value
            loud += abs(value.toInt())
        }
        input.position(position)
        // Quiet moments say nothing about the offset.
        if (loud / (count * 2) < 300 || count < 2048) return
        check.frames = count
        check.frame = start
        check.stems = song
        check.state = Check.CAPTURED
        nextCheck = start + rate * 5L
    }

    private fun readCheck(song: KaraokeStems) {
        if (check.state != Check.MEASURED) return
        val measured = check.offset
        if (check.stems === song && check.inconclusive) {
            nextCheck = check.frame + rate * 2L
        } else if (check.stems === song) {
            if (measured != null) {
                offset = measured
                verified = true
            } else {
                // Not the song the vocals are for at that point (or not at that time): stop until a jump.
                verified = false
                nextCheck = Long.MAX_VALUE
                mismatches++
            }
        }
        check.state = Check.IDLE
    }
}
