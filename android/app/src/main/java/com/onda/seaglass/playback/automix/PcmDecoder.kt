package com.onda.seaglass.playback.automix

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import java.io.File
import java.nio.ByteOrder

/** Part of a song decoded to interleaved stereo samples (-1…1) at [rate], from [start] seconds of its time. */
class Pcm(val samples: FloatArray, val rate: Int, val start: Double) {
    val frames: Int get() = samples.size / 2
    val end: Double get() = start + frames.toDouble() / rate
}

/** Decodes part of an audio file (Opus in WebM, AAC in MP4) with the phone's own decoders. */
internal object PcmDecoder {
    /**
     * Calls [sink] with each decoded frame from [from] seconds for [seconds]: its time, the frame's
     * samples as 16-bit values in [samples] at [offset] ([channels] of them) and the sample rate.
     * Decoding starts a little earlier than [from] (some codecs need a moment to settle after a jump).
     */
    fun decode(
        file: File, from: Double, seconds: Double,
        sink: (time: Double, samples: ShortArray, offset: Int, channels: Int, rate: Int) -> Unit,
    ) {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            extractor.setDataSource(file.path)
            val track = (0 until extractor.trackCount).first {
                extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
            }
            extractor.selectTrack(track)
            val format = extractor.getTrackFormat(track)
            val mime = format.getString(MediaFormat.KEY_MIME) ?: error("No audio type")
            var rate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            val startUs = (from * 1_000_000).toLong()
            val endUs = ((from + seconds) * 1_000_000).toLong()
            if (from > 0) extractor.seekTo(maxOf(0L, startUs - 250_000), MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            codec = MediaCodec.createDecoderByType(mime).apply {
                configure(format, null, null, 0)
                start()
            }
            val info = MediaCodec.BufferInfo()
            var frame = ShortArray(0)
            var inputDone = false
            var outputDone = false
            while (!outputDone) {
                if (!inputDone) {
                    val index = codec.dequeueInputBuffer(10_000)
                    if (index >= 0) {
                        val buffer = codec.getInputBuffer(index) ?: error("No input buffer")
                        val size = extractor.readSampleData(buffer, 0)
                        if (size < 0 || extractor.sampleTime > endUs + 500_000) {
                            codec.queueInputBuffer(index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(index, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                val index = codec.dequeueOutputBuffer(info, 10_000)
                when {
                    index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val output = codec.outputFormat
                        rate = output.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                        channels = output.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    }
                    index >= 0 -> {
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
                        val buffer = codec.getOutputBuffer(index)?.order(ByteOrder.nativeOrder())
                        if (buffer != null && info.size > 0) {
                            buffer.position(info.offset)
                            buffer.limit(info.offset + info.size)
                            val shorts = buffer.asShortBuffer()
                            val count = shorts.remaining()
                            if (frame.size < count) frame = ShortArray(count)
                            shorts.get(frame, 0, count)
                            val frames = count / channels
                            for (i in 0 until frames) {
                                val timeUs = info.presentationTimeUs + i * 1_000_000L / rate
                                // Frames before the window (decoded from the sync point before it) are skipped.
                                if (timeUs < startUs) continue
                                if (timeUs >= endUs) {
                                    outputDone = true
                                    break
                                }
                                sink(timeUs / 1_000_000.0, frame, i * channels, channels, rate)
                            }
                        }
                        codec.releaseOutputBuffer(index, false)
                    }
                }
            }
        } finally {
            runCatching { codec?.stop() }
            codec?.release()
            extractor.release()
        }
    }

    /** [seconds] of the file from [from], in stereo at the file's own rate (a mono song in both channels). */
    fun stereo(file: File, from: Double, seconds: Double): Pcm {
        var data = FloatArray(1 shl 18)
        var size = 0
        var first = Double.NaN
        var sampleRate = 0
        decode(file, from, seconds) { time, samples, offset, channels, rate ->
            if (first.isNaN()) first = time
            sampleRate = rate
            if (size + 2 > data.size) data = data.copyOf(data.size * 2)
            val left = samples[offset] / 32768f
            val right = if (channels > 1) samples[offset + 1] / 32768f else left
            data[size++] = left
            data[size++] = right
        }
        if (size == 0) error("No audio between $from s and ${from + seconds} s")
        return Pcm(data.copyOf(size), sampleRate, first)
    }
}
