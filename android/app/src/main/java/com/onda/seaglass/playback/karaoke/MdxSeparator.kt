package com.onda.seaglass.playback.karaoke

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import kotlin.math.PI
import kotlin.math.cos

/**
 * The spectrograms of the UVR MDX-Net "Voc_FT" vocal model, as the iPhone app's `MDXSeparator`
 * computes them (and UVR and sherpa-onnx before it): a centred STFT (reflect padding) with a periodic
 * Hann window of 6144 points every 1024, of which the model takes the 3072 bins below Nyquist and 256
 * frames, real and imaginary parts per channel; the inverse divides by the windows' overlap, as
 * torch.istft does. A piece of at most [MAX_PIECE] frames sits in the middle of the segment, away from
 * its edges. Not thread-safe.
 */
class MdxSpectrogram {
    companion object {
        const val SAMPLE_RATE = 44_100
        const val FFT = 6144
        const val HOP = 1024
        const val BINS = 3072
        const val FRAMES = 256
        /** Song frames that make up the model's input. */
        const val SEGMENT = HOP * (FRAMES - 1)
        /** Frames left at both ends of the segment, where the STFT has too little context. */
        const val TRIM = FFT / 2
        /** The longest piece separated in one go (about 5.8 s). */
        const val MAX_PIECE = SEGMENT - 2 * TRIM
        /** Floats in the model's input and output: 4 channels (left and right, real and imaginary). */
        const val SIZE = 4 * BINS * FRAMES
    }

    private val fft = Fft(FFT)
    private val window = FloatArray(FFT) { (0.5 - 0.5 * cos(2 * PI * it / FFT)).toFloat() }
    private val synthesisWindow = FloatArray(FFT) { window[it] / FFT }
    private val outputLength = FFT + HOP * (FRAMES - 1)
    private val inverseEnvelope: FloatArray
    private val segment = FloatArray(SEGMENT)
    private val padded = FloatArray(SEGMENT + FFT)
    private val re = FloatArray(FFT)
    private val im = FloatArray(FFT)
    private val overlapAdd = FloatArray(outputLength)

    init {
        val envelope = FloatArray(outputLength)
        for (frame in 0 until FRAMES) for (i in 0 until FFT) envelope[frame * HOP + i] += window[i] * window[i]
        inverseEnvelope = FloatArray(outputLength) { if (envelope[it] > 1e-11f) 1 / envelope[it] else 1f }
    }

    /**
     * Writes the spectrogram of one channel of a piece ([count] frames of [samples] from [offset],
     * every [stride]th value) into [into] (the model's layout: channel, bin, frame), as channels
     * 2·[channel] (real) and 2·[channel]+1 (imaginary).
     */
    fun analyze(samples: FloatArray, offset: Int, stride: Int, count: Int, channel: Int, into: FloatArray) {
        require(count in 1..MAX_PIECE)
        segment.fill(0f)
        for (i in 0 until count) segment[TRIM + i] = samples[offset + i * stride]
        val half = FFT / 2
        // Reflect padding (as torch.stft with center=True): the edge sample isn't repeated.
        for (i in 0 until half) {
            padded[i] = segment[half - i]
            padded[half + SEGMENT + i] = segment[SEGMENT - 2 - i]
        }
        System.arraycopy(segment, 0, padded, half, SEGMENT)
        val realPlane = 2 * channel * BINS * FRAMES
        val imagPlane = (2 * channel + 1) * BINS * FRAMES
        for (frame in 0 until FRAMES) {
            val start = frame * HOP
            for (i in 0 until FFT) {
                re[i] = padded[start + i] * window[i]
                im[i] = 0f
            }
            fft.transform(re, im)
            for (bin in 0 until BINS) {
                into[realPlane + bin * FRAMES + frame] = re[bin]
                into[imagPlane + bin * FRAMES + frame] = im[bin]
            }
        }
    }

    /** The inverse of [spectrogram]'s channels 2·[channel] and 2·[channel]+1, cut back to the piece. */
    fun synthesize(spectrogram: FloatArray, channel: Int, count: Int): FloatArray {
        val realPlane = 2 * channel * BINS * FRAMES
        val imagPlane = (2 * channel + 1) * BINS * FRAMES
        overlapAdd.fill(0f)
        for (frame in 0 until FRAMES) {
            // Bins 0..<3072 from the model, Nyquist zero, the rest mirrored (conjugate): a real result.
            for (bin in 0 until BINS) {
                re[bin] = spectrogram[realPlane + bin * FRAMES + frame]
                im[bin] = spectrogram[imagPlane + bin * FRAMES + frame]
            }
            re[FFT / 2] = 0f
            im[FFT / 2] = 0f
            im[0] = 0f
            for (bin in 1 until FFT / 2) {
                re[FFT - bin] = re[bin]
                im[FFT - bin] = -im[bin]
            }
            fft.transform(re, im, inverse = true)
            val target = frame * HOP
            for (i in 0 until FFT) overlapAdd[target + i] += re[i] * synthesisWindow[i]
        }
        val start = FFT / 2 + TRIM
        return FloatArray(count) { overlapAdd[start + it] * inverseEnvelope[start + it] }
    }
}

/**
 * The karaoke's vocal model, run by ONNX Runtime on the phone's processor: the vocals of a stereo
 * piece at 44.1 kHz. Not thread-safe: one piece at a time.
 */
class MdxSeparator(model: File, threads: Int) : AutoCloseable {
    // No usage data to Microsoft (its starter is also left out of the app's manifest).
    private val environment = OrtEnvironment.getEnvironment().apply { runCatching { setTelemetry(false) } }
    private val session: OrtSession = environment.createSession(
        model.path,
        OrtSession.SessionOptions().apply {
            setIntraOpNumThreads(threads)
            setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
        },
    )
    private val inputName = session.inputNames.first()
    private val spectrogram = MdxSpectrogram()
    private val input = FloatArray(MdxSpectrogram.SIZE)
    private val output = FloatArray(MdxSpectrogram.SIZE)
    private val buffer: FloatBuffer = ByteBuffer.allocateDirect(MdxSpectrogram.SIZE * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()
    private val shape = longArrayOf(1, 4, MdxSpectrogram.BINS.toLong(), MdxSpectrogram.FRAMES.toLong())

    /** The vocals of [count] interleaved stereo frames of [samples] from frame [from], as interleaved stereo. */
    fun vocals(samples: FloatArray, from: Int, count: Int): FloatArray {
        spectrogram.analyze(samples, from * 2, 2, count, 0, input)
        spectrogram.analyze(samples, from * 2 + 1, 2, count, 1, input)
        buffer.clear()
        buffer.put(input)
        buffer.flip()
        OnnxTensor.createTensor(environment, buffer, shape).use { tensor ->
            session.run(mapOf(inputName to tensor)).use { result ->
                val values = (result.get(0) as OnnxTensor).floatBuffer
                require(values.remaining() == MdxSpectrogram.SIZE) { "Unexpected model output" }
                values.get(output)
            }
        }
        val left = spectrogram.synthesize(output, 0, count)
        val right = spectrogram.synthesize(output, 1, count)
        return FloatArray(count * 2) { if (it % 2 == 0) left[it / 2] else right[it / 2] }
    }

    override fun close() {
        session.close()
    }
}
