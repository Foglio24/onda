package com.onda.seaglass.playback.automix

import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import androidx.media3.common.util.UnstableApi
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * A player's filters for AutoMix: a low shelf that takes the bass away ([bassCut], 0 none … 1 all,
 * for passing the bass from one song to the other) and a high-pass that sweeps up through the song
 * ([highPass], 0 off … 1 up to about 1.2 kHz). Set from the main thread; read here per buffer.
 * At rest (both 0) the samples pass through untouched, which keeps bit-perfect output exact.
 */
@OptIn(UnstableApi::class)
class MixFilter : BaseAudioProcessor() {
    @Volatile var bassCut = 0f
    @Volatile var highPass = 0f

    private var shelf = Biquad()
    private var hpf = Biquad()
    private var channels = 0
    private var sampleRate = 0
    private var appliedBass = -1f
    private var appliedHigh = -1f
    // Filter state per channel: x1, x2, y1, y2 for each of the two biquads.
    private var state = DoubleArray(0)

    override fun onConfigure(inputAudioFormat: AudioProcessor.AudioFormat): AudioProcessor.AudioFormat {
        if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT) return AudioProcessor.AudioFormat.NOT_SET
        channels = inputAudioFormat.channelCount
        sampleRate = inputAudioFormat.sampleRate
        state = DoubleArray(channels * 8)
        appliedBass = -1f
        appliedHigh = -1f
        return inputAudioFormat
    }

    override fun queueInput(inputBuffer: ByteBuffer) {
        val size = inputBuffer.remaining()
        if (size == 0) return
        val output = replaceOutputBuffer(size)
        val bass = bassCut
        val high = highPass
        if (bass <= 0.001f && high <= 0.001f) {
            // Nothing to do: the bytes as they came (and the filters' memory cleared for next time).
            output.put(inputBuffer)
            if (appliedBass != 0f || appliedHigh != 0f) {
                state.fill(0.0)
                appliedBass = 0f
                appliedHigh = 0f
            }
            output.flip()
            return
        }
        if (bass != appliedBass) {
            // A low shelf at 180 Hz: from 0 dB down to -30 dB.
            shelf = Biquad.lowShelf(sampleRate, 180.0, -30.0 * bass)
            appliedBass = bass
        }
        if (high != appliedHigh) {
            hpf = Biquad.highPass(sampleRate, 30.0 * 40.0.pow(high.toDouble()))
            appliedHigh = high
        }
        val input = inputBuffer.order(ByteOrder.nativeOrder())
        output.order(ByteOrder.nativeOrder())
        val frames = size / (2 * channels)
        for (frame in 0 until frames) {
            for (channel in 0 until channels) {
                var x = input.getShort().toDouble()
                val s = channel * 8
                if (bass > 0.001f) x = shelf.process(x, state, s)
                if (high > 0.001f) x = hpf.process(x, state, s + 4)
                output.putShort(x.coerceIn(-32768.0, 32767.0).toInt().toShort())
            }
        }
        output.flip()
    }

    override fun onFlush() {
        state.fill(0.0)
    }

    override fun onReset() {
        bassCut = 0f
        highPass = 0f
        state = DoubleArray(0)
    }

    /** A second-order filter (RBJ's cookbook). */
    class Biquad(
        private val b0: Double = 1.0, private val b1: Double = 0.0, private val b2: Double = 0.0,
        private val a1: Double = 0.0, private val a2: Double = 0.0,
    ) {
        fun process(x: Double, state: DoubleArray, at: Int): Double {
            val y = b0 * x + b1 * state[at] + b2 * state[at + 1] - a1 * state[at + 2] - a2 * state[at + 3]
            state[at + 1] = state[at]
            state[at] = x
            state[at + 3] = state[at + 2]
            state[at + 2] = y
            return y
        }

        companion object {
            fun lowShelf(rate: Int, frequency: Double, gainDb: Double): Biquad {
                val a = 10.0.pow(gainDb / 40)
                val w = 2 * PI * frequency / rate
                val alpha = sin(w) / 2 * sqrt(2.0)
                val c = cos(w)
                val root = 2 * sqrt(a) * alpha
                val a0 = (a + 1) + (a - 1) * c + root
                return Biquad(
                    b0 = a * ((a + 1) - (a - 1) * c + root) / a0,
                    b1 = 2 * a * ((a - 1) - (a + 1) * c) / a0,
                    b2 = a * ((a + 1) - (a - 1) * c - root) / a0,
                    a1 = -2 * ((a - 1) + (a + 1) * c) / a0,
                    a2 = ((a + 1) + (a - 1) * c - root) / a0,
                )
            }

            fun highPass(rate: Int, frequency: Double): Biquad {
                val w = 2 * PI * frequency / rate
                val alpha = sin(w) / (2 * 0.7071)
                val c = cos(w)
                val a0 = 1 + alpha
                return Biquad(
                    b0 = (1 + c) / 2 / a0,
                    b1 = -(1 + c) / a0,
                    b2 = (1 + c) / 2 / a0,
                    a1 = -2 * c / a0,
                    a2 = (1 - alpha) / a0,
                )
            }
        }
    }
}
