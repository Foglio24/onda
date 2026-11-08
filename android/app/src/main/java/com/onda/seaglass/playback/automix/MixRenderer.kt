package com.onda.seaglass.playback.automix

import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.SonicAudioProcessor
import androidx.media3.common.util.UnstableApi
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt

/**
 * An AutoMix mix rendered ahead of time, as the iPhone app does: the outgoing song alone for
 * [MixRenderer.BEFORE] seconds, then the two together as the [plan] says, then the next song alone
 * for [MixRenderer.AFTER] seconds. Beats matched in the file stay matched, sample for sample, whatever
 * the players do; the players only have to take over from the song and hand back to the next one,
 * where each plays the same music as the file.
 */
data class MixInfo(
    val plan: TransitionPlan,
    val file: File,
    /** The outgoing song's time at the file's start. */
    val start: Double,
    /** Seconds of audio in the file. */
    val length: Double,
    /** Seconds into the file where the next song comes in (at its time [TransitionPlan.inStart]). */
    val incomingAt: Double,
) {
    /** Seconds into the file when the outgoing song has gone. */
    val mixEnd: Double get() = plan.outEnd - start

    /** The next song's own time at [mixTime] seconds into the file. */
    fun incomingTime(mixTime: Double): Double = plan.inStart + (mixTime - incomingAt) * plan.incomingRate
}

/** The mix's samples (interleaved stereo, 16-bit) at [rate], before they're written to a file. */
class RenderedMix(val plan: TransitionPlan, val samples: ShortArray, val rate: Int, val start: Double, val incomingAt: Double) {
    val length: Double get() = samples.size / 2.0 / rate

    /** Writes a WAV file and describes it. */
    fun write(file: File): MixInfo {
        RandomAccessFile(file, "rw").use { out ->
            out.setLength(0)
            val data = samples.size * 2
            val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
            header.put("RIFF".toByteArray()).putInt(36 + data).put("WAVE".toByteArray())
            header.put("fmt ".toByteArray()).putInt(16).putShort(1).putShort(2).putInt(rate).putInt(rate * 4).putShort(4).putShort(16)
            header.put("data".toByteArray()).putInt(data)
            out.write(header.array())
            val bytes = ByteBuffer.allocate(64 * 1024).order(ByteOrder.LITTLE_ENDIAN)
            var index = 0
            while (index < samples.size) {
                bytes.clear()
                while (index < samples.size && bytes.remaining() >= 2) bytes.putShort(samples[index++])
                out.write(bytes.array(), 0, bytes.position())
            }
        }
        return MixInfo(plan, file, start, length, incomingAt)
    }
}

@OptIn(UnstableApi::class)
object MixRenderer {
    /** Seconds of the outgoing song alone at the start, for the hidden player to fall in step with the song. */
    const val BEFORE = 6.0
    /** Seconds of the next song alone at the end, for the main player to fall in step with the file. */
    const val AFTER = 10.0
    /** Peaks of the two songs together are kept under this. */
    private const val CEILING = 0.98f
    private const val BLOCK = 128

    /**
     * Mixes [outgoing] (from [BEFORE] seconds before the mix to its end) and [incoming] (from the
     * plan's start in it) at the outgoing song's sample rate. The next song is time-stretched to the
     * plan's rate with its pitch kept; each song gets its gain ("Volume uniforme"), its volume curve,
     * its bass cut and, for the outgoing one, the high-pass, as the plan sets them along the mix.
     */
    fun render(plan: TransitionPlan, outgoing: Pcm, incoming: Pcm, outgoingGain: Float, incomingGain: Float): RenderedMix {
        val rate = outgoing.rate
        val start = outgoing.start
        val stretched = stretch(incoming, plan.incomingRate, rate)
        // The decoded part of the next song may start a frame after the plan's point in it.
        val incomingAt = plan.outStart - start + (incoming.start - plan.inStart) / plan.incomingRate
        val incomingOffset = (incomingAt * rate).roundToInt()
        val wanted = ((plan.outEnd - start + AFTER) * rate).roundToInt()
        val frames = min(wanted, incomingOffset + stretched.size / 2)
        require(frames > incomingOffset + rate) { "Not enough of the next song" }
        val mix = FloatArray(frames * 2)

        val outState = DoubleArray(16)
        val inState = DoubleArray(16)
        var block = 0
        while (block < frames) {
            val end = min(frames, block + BLOCK)
            val from = plan.levels(plan.progress(start + block.toDouble() / rate))
            val to = plan.levels(plan.progress(start + end.toDouble() / rate))
            val middle = plan.levels(plan.progress(start + (block + end) / 2.0 / rate))
            val outShelf = if (middle.outgoingBassCut > 0.001f) MixFilter.Biquad.lowShelf(rate, 180.0, -30.0 * middle.outgoingBassCut) else null
            val outHigh = if (middle.outgoingHighPass > 0.001f) MixFilter.Biquad.highPass(rate, 30.0 * 40.0.pow(middle.outgoingHighPass.toDouble())) else null
            val inShelf = if (middle.incomingBassCut > 0.001f) MixFilter.Biquad.lowShelf(rate, 180.0, -30.0 * middle.incomingBassCut) else null
            for (frame in block until end) {
                val t = (frame - block).toFloat() / (end - block)
                val outLevel = (from.outgoing + (to.outgoing - from.outgoing) * t) * outgoingGain
                val inLevel = (from.incoming + (to.incoming - from.incoming) * t) * incomingGain
                for (channel in 0..1) {
                    var a = if (frame < outgoing.frames) outgoing.samples[frame * 2 + channel].toDouble() else 0.0
                    if (outShelf != null) a = outShelf.process(a, outState, channel * 8)
                    if (outHigh != null) a = outHigh.process(a, outState, channel * 8 + 4)
                    val bFrame = frame - incomingOffset
                    var b = if (bFrame >= 0 && bFrame < stretched.size / 2) stretched[bFrame * 2 + channel].toDouble() else 0.0
                    if (inShelf != null) b = inShelf.process(b, inState, channel * 8)
                    mix[frame * 2 + channel] = (a * outLevel + b * inLevel).toFloat()
                }
            }
            block = end
        }
        limit(mix, rate)
        val samples = ShortArray(mix.size) { (mix[it].coerceIn(-1f, 1f) * 32767f).roundToInt().toShort() }
        return RenderedMix(plan, samples, rate, start, incomingAt)
    }

    /**
     * The next song at [speed] (its pitch kept) and at [outputRate], through Media3's Sonic, the same
     * time stretch the player uses for the glide back to the song's own tempo.
     */
    fun stretch(pcm: Pcm, speed: Double, outputRate: Int): FloatArray {
        if (abs(speed - 1) < 1e-6 && pcm.rate == outputRate) return pcm.samples
        val sonic = SonicAudioProcessor()
        sonic.setSpeed(speed.toFloat())
        sonic.setPitch(1f)
        if (pcm.rate != outputRate) sonic.setOutputSampleRateHz(outputRate)
        sonic.configure(AudioProcessor.AudioFormat(pcm.rate, 2, C.ENCODING_PCM_16BIT))
        sonic.flush(AudioProcessor.StreamMetadata.DEFAULT)
        var out = FloatArray(((pcm.samples.size / speed) * outputRate / pcm.rate).toInt() + 8192)
        var size = 0
        fun drain() {
            val output = sonic.output.order(ByteOrder.nativeOrder())
            while (output.remaining() >= 2) {
                if (size == out.size) out = out.copyOf(out.size * 2)
                out[size++] = output.getShort() / 32768f
            }
        }
        val chunk = ByteBuffer.allocateDirect(8192 * 4).order(ByteOrder.nativeOrder())
        var index = 0
        while (index < pcm.samples.size) {
            chunk.clear()
            while (index < pcm.samples.size && chunk.remaining() >= 2) {
                chunk.putShort((pcm.samples[index++].coerceIn(-1f, 1f) * 32767f).roundToInt().toShort())
            }
            chunk.flip()
            while (chunk.hasRemaining()) {
                sonic.queueInput(chunk)
                drain()
            }
        }
        sonic.queueEndOfStream()
        while (!sonic.isEnded) drain()
        sonic.reset()
        return out.copyOf(size - size % 2)
    }

    /**
     * Brings the peaks of the two songs together under [CEILING]: a gain that comes down just before
     * a peak (5 ms ahead) and back up over 150 ms. Where only one song plays at its gain it's untouched
     * (its own peaks are under the ceiling), so the file starts and ends at the songs' very level.
     */
    private fun limit(mix: FloatArray, rate: Int) {
        val step = 64
        val frames = mix.size / 2
        val blocks = frames / step + 2
        val need = FloatArray(blocks) { 1f }
        for (frame in 0 until frames) {
            val peak = max(abs(mix[frame * 2]), abs(mix[frame * 2 + 1]))
            if (peak > CEILING) {
                val b = frame / step
                need[b] = min(need[b], CEILING / peak)
            }
        }
        val ahead = max(1, (0.005 * rate / step).roundToInt())
        val release = 1f / max(1f, (0.15f * rate / step))
        val gain = FloatArray(blocks)
        for (b in 0 until blocks) {
            var g = 1f
            for (k in max(0, b - 1)..min(blocks - 1, b + ahead)) g = min(g, need[k])
            gain[b] = if (b > 0) min(g, gain[b - 1] + release) else g
        }
        for (frame in 0 until frames) {
            val b = frame / step
            val g = gain[b] + (gain[b + 1] - gain[b]) * ((frame % step).toFloat() / step)
            if (g < 1f) {
                mix[frame * 2] *= g
                mix[frame * 2 + 1] *= g
            }
        }
    }
}
