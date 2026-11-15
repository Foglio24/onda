package com.onda.seaglass.audio

import org.bytedeco.ffmpeg.avcodec.AVCodecContext
import org.bytedeco.ffmpeg.avcodec.AVPacket
import org.bytedeco.ffmpeg.avformat.AVFormatContext
import org.bytedeco.ffmpeg.avformat.AVIOContext
import org.bytedeco.ffmpeg.avformat.Read_packet_Pointer_BytePointer_int
import org.bytedeco.ffmpeg.avformat.Seek_Pointer_long_int
import org.bytedeco.ffmpeg.avutil.AVChannelLayout
import org.bytedeco.ffmpeg.avutil.AVDictionary
import org.bytedeco.ffmpeg.avutil.AVFrame
import org.bytedeco.ffmpeg.global.avcodec.av_packet_alloc
import org.bytedeco.ffmpeg.global.avcodec.av_packet_free
import org.bytedeco.ffmpeg.global.avcodec.av_packet_unref
import org.bytedeco.ffmpeg.global.avcodec.avcodec_alloc_context3
import org.bytedeco.ffmpeg.global.avcodec.avcodec_find_decoder
import org.bytedeco.ffmpeg.global.avcodec.avcodec_flush_buffers
import org.bytedeco.ffmpeg.global.avcodec.avcodec_free_context
import org.bytedeco.ffmpeg.global.avcodec.avcodec_open2
import org.bytedeco.ffmpeg.global.avcodec.avcodec_parameters_to_context
import org.bytedeco.ffmpeg.global.avcodec.avcodec_receive_frame
import org.bytedeco.ffmpeg.global.avcodec.avcodec_send_packet
import org.bytedeco.ffmpeg.global.avformat.AVSEEK_FLAG_BACKWARD
import org.bytedeco.ffmpeg.global.avformat.AVSEEK_SIZE
import org.bytedeco.ffmpeg.global.avformat.av_find_best_stream
import org.bytedeco.ffmpeg.global.avformat.av_read_frame
import org.bytedeco.ffmpeg.global.avformat.av_seek_frame
import org.bytedeco.ffmpeg.global.avformat.avformat_alloc_context
import org.bytedeco.ffmpeg.global.avformat.avformat_close_input
import org.bytedeco.ffmpeg.global.avformat.avformat_find_stream_info
import org.bytedeco.ffmpeg.global.avformat.avformat_open_input
import org.bytedeco.ffmpeg.global.avformat.avio_alloc_context
import org.bytedeco.ffmpeg.global.avformat.avio_context_free
import org.bytedeco.ffmpeg.global.avutil.AVERROR_EOF
import org.bytedeco.ffmpeg.global.avutil.AVMEDIA_TYPE_AUDIO
import org.bytedeco.ffmpeg.global.avutil.AV_NOPTS_VALUE
import org.bytedeco.ffmpeg.global.avutil.AV_SAMPLE_FMT_FLT
import org.bytedeco.ffmpeg.global.avutil.av_channel_layout_default
import org.bytedeco.ffmpeg.global.avutil.av_dict_get
import org.bytedeco.ffmpeg.global.avutil.av_frame_alloc
import org.bytedeco.ffmpeg.global.avutil.av_frame_free
import org.bytedeco.ffmpeg.global.avutil.av_log_set_level
import org.bytedeco.ffmpeg.global.avutil.av_malloc
import org.bytedeco.ffmpeg.global.avutil.av_free
import org.bytedeco.ffmpeg.global.avutil.AV_LOG_QUIET
import org.bytedeco.ffmpeg.global.avutil.AV_DICT_IGNORE_SUFFIX
import org.bytedeco.ffmpeg.global.swresample.swr_alloc_set_opts2
import org.bytedeco.ffmpeg.global.swresample.swr_convert
import org.bytedeco.ffmpeg.global.swresample.swr_free
import org.bytedeco.ffmpeg.global.swresample.swr_init
import org.bytedeco.ffmpeg.swresample.SwrContext
import org.bytedeco.javacpp.BytePointer
import org.bytedeco.javacpp.FloatPointer
import org.bytedeco.javacpp.Pointer
import org.bytedeco.javacpp.PointerPointer
import java.io.Closeable
import java.io.IOException

/**
 * Decodes a song's file with FFmpeg into interleaved stereo float samples at [RATE]: Opus and AAC
 * from YouTube, and MP3, FLAC, ALAC, WAV, OGG and the like from the user's own folder. The bytes
 * come from a [ByteSource], so a stream plays while it downloads. Used from one thread at a time.
 */
class Decoder(private val source: ByteSource) : Closeable {
    companion object {
        const val RATE = 48_000
        const val CHANNELS = 2
        private const val IO_BUFFER = 64 * 1024

        init {
            av_log_set_level(AV_LOG_QUIET)
        }
    }

    /** Seconds, from the container (0 when it doesn't say). */
    val duration: Double

    /** Tags of a local file (title, artist, album…), lower-cased keys. */
    val tags: Map<String, String>

    /** "Opus", "AAC", "FLAC"… */
    val codecName: String

    private var position = 0L
    private val readBytes = ByteArray(IO_BUFFER)
    /** Which decoder FFmpeg's I/O callbacks are reading for (see [Io]). */
    private val id = Io.register(this)

    /**
     * FFmpeg's read and seek callbacks. JavaCPP gives each callback type only a few native
     * entry points, taken until the collector frees their objects: one pair per decoder ran out as
     * soon as a few songs were open (a crossfade, the next song), and opening failed. So there is
     * one pair for the whole app, and FFmpeg's `opaque` pointer carries the decoder's [id].
     */
    private object Io {
        private val decoders = java.util.concurrent.ConcurrentHashMap<Long, Decoder>()
        private val nextId = java.util.concurrent.atomic.AtomicLong(1)

        fun register(decoder: Decoder): Long = nextId.getAndIncrement().also { decoders[it] = decoder }
        fun unregister(id: Long) = decoders.remove(id)

        /** A pointer whose address is the decoder's id: never dereferenced, only handed back. */
        fun opaque(id: Long): Pointer = object : Pointer() {
            init { address = id }
        }

        val reader = object : Read_packet_Pointer_BytePointer_int() {
            override fun call(opaque: Pointer?, buffer: BytePointer, size: Int): Int =
                decoders[opaque?.address() ?: 0L]?.readPacket(buffer, size) ?: AVERROR_EOF
        }
        val seeker = object : Seek_Pointer_long_int() {
            override fun call(opaque: Pointer?, offset: Long, whence: Int): Long =
                decoders[opaque?.address() ?: 0L]?.seekBytes(offset, whence) ?: -1
        }
    }

    private fun readPacket(buffer: BytePointer, size: Int): Int {
        val count = try {
            source.read(position, readBytes, 0, minOf(size, readBytes.size))
        } catch (e: IOException) {
            failure = e
            return AVERROR_EOF
        }
        if (count <= 0) return AVERROR_EOF
        buffer.position(0).put(readBytes, 0, count)
        position += count
        return count
    }

    private fun seekBytes(offset: Long, whence: Int): Long {
        if (whence and AVSEEK_SIZE != 0) return source.size
        position = when (whence and 3) {
            0 -> offset
            1 -> position + offset
            2 -> if (source.size >= 0) source.size + offset else return -1
            else -> return -1
        }
        return position
    }

    @Volatile private var failure: IOException? = null
    private val io: AVIOContext
    private val format: AVFormatContext
    private val codec: AVCodecContext
    private val stream: Int
    private val timeBase: Double
    private var swr: SwrContext? = null
    private val packet: AVPacket = av_packet_alloc()
    private val frame: AVFrame = av_frame_alloc()
    private val outLayout = AVChannelLayout().also { av_channel_layout_default(it, CHANNELS) }
    private var converted = FloatPointer(8192L * CHANNELS)
    private var convertedFrames = 8192

    /** Decoded samples not yet handed out (interleaved). */
    private var pending = FloatArray(0)
    private var pendingStart = 0
    private var pendingEnd = 0
    private var ended = false
    /** Samples to drop after a seek, to land exactly on the asked time. */
    private var skipFrames = 0L

    init {
        val buffer = BytePointer(av_malloc(IO_BUFFER.toLong()))
        io = avio_alloc_context(buffer, IO_BUFFER, 0, Io.opaque(id), Io.reader, null, Io.seeker)
        format = avformat_alloc_context()
        format.pb(io)
        format.flags(format.flags() or 0x0080) // AVFMT_FLAG_CUSTOM_IO: the I/O is ours
        if (avformat_open_input(format, null as String?, null, null as AVDictionary?) < 0) {
            Io.unregister(id)
            av_free(io.buffer())
            avio_context_free(io)
            throw failure ?: IOException("Unsupported audio file")
        }
        try {
            if (avformat_find_stream_info(format, null as PointerPointer<*>?) < 0) throw IOException("Unreadable audio file")
            stream = av_find_best_stream(format, AVMEDIA_TYPE_AUDIO, -1, -1, null as PointerPointer<*>?, 0)
            if (stream < 0) throw IOException("No audio in the file")
            val parameters = format.streams(stream).codecpar()
            val decoder = avcodec_find_decoder(parameters.codec_id()) ?: throw IOException("Unsupported audio codec")
            codec = avcodec_alloc_context3(decoder)
            avcodec_parameters_to_context(codec, parameters)
            if (avcodec_open2(codec, decoder, null as AVDictionary?) < 0) throw IOException("Couldn't open the audio codec")
            codecName = when (val name = decoder.name()?.string.orEmpty()) {
                "libopus", "opus" -> "Opus"
                "aac", "aac_fixed" -> "AAC"
                "mp3", "mp3float" -> "MP3"
                else -> name.uppercase()
            }
            val base = format.streams(stream).time_base()
            timeBase = base.num().toDouble() / base.den()
            val streamDuration = format.streams(stream).duration()
            duration = when {
                format.duration() > 0 -> format.duration() / 1_000_000.0
                streamDuration > 0 -> streamDuration * timeBase
                else -> 0.0
            }
            tags = readTags(format.metadata()) + readTags(format.streams(stream).metadata())
        } catch (e: Throwable) {
            avformat_close_input(format)
            Io.unregister(id)
            av_free(io.buffer())
            avio_context_free(io)
            throw e
        }
    }

    private fun readTags(dictionary: AVDictionary?): Map<String, String> {
        dictionary ?: return emptyMap()
        val result = HashMap<String, String>()
        var entry = av_dict_get(dictionary, "", null, AV_DICT_IGNORE_SUFFIX)
        while (entry != null) {
            val key = entry.key()?.string?.lowercase()
            val value = entry.value()?.string
            if (key != null && value != null) result.putIfAbsent(key, value)
            entry = av_dict_get(dictionary, "", entry, AV_DICT_IGNORE_SUFFIX)
        }
        return result
    }

    /** Fills [into] with up to [frames] stereo frames; returns how many, 0 at the end of the song. */
    fun read(into: FloatArray, frames: Int): Int {
        var written = 0
        while (written < frames) {
            if (pendingStart >= pendingEnd) {
                if (ended || !decodeMore()) break
                continue
            }
            val available = (pendingEnd - pendingStart) / CHANNELS
            val take = minOf(available, frames - written)
            System.arraycopy(pending, pendingStart, into, written * CHANNELS, take * CHANNELS)
            pendingStart += take * CHANNELS
            written += take
        }
        failure?.let { if (written == 0) throw it }
        return written
    }

    /** Moves to [seconds], exactly: FFmpeg lands on the packet before, the rest is decoded and dropped. */
    fun seek(seconds: Double) {
        val target = (maxOf(0.0, seconds) / timeBase).toLong()
        av_seek_frame(format, stream, target, AVSEEK_FLAG_BACKWARD)
        avcodec_flush_buffers(codec)
        swr?.let { swr_free(it) }
        swr = null
        pendingStart = 0
        pendingEnd = 0
        ended = false
        failure = null
        // The frames up to the target are dropped as they come, from the first frame's own time.
        skipFrames = -1
        seekTarget = maxOf(0.0, seconds)
    }

    private var seekTarget = 0.0

    /** Decodes the next packets until some samples come out; false at the end. */
    private fun decodeMore(): Boolean {
        while (true) {
            val received = avcodec_receive_frame(codec, frame)
            if (received == 0) {
                convert()
                if (pendingEnd > pendingStart) return true
                continue
            }
            if (received == AVERROR_EOF) {
                ended = true
                return false
            }
            // EAGAIN: it needs another packet.
            val read = av_read_frame(format, packet)
            if (read < 0) {
                avcodec_send_packet(codec, null)
                val last = avcodec_receive_frame(codec, frame)
                if (last == 0) {
                    convert()
                    if (pendingEnd > pendingStart) return true
                }
                ended = true
                return false
            }
            if (packet.stream_index() == stream) avcodec_send_packet(codec, packet)
            av_packet_unref(packet)
        }
    }

    private fun convert() {
        val context = swr ?: setUpResampler()
        val inFrames = frame.nb_samples()
        val outCapacity = (inFrames.toLong() * RATE / maxOf(1, frame.sample_rate()) + 256).toInt()
        if (outCapacity > convertedFrames) {
            converted.close()
            converted = FloatPointer(outCapacity.toLong() * CHANNELS)
            convertedFrames = outCapacity
        }
        val out = PointerPointer<Pointer>(1).put(0, converted)
        val count = swr_convert(context, out, convertedFrames, frame.extended_data(), inFrames)
        out.close()
        if (count <= 0) return
        var start = 0
        if (skipFrames != 0L) {
            if (skipFrames < 0) {
                // The first frame after a seek: how far before the target it starts.
                val pts = frame.best_effort_timestamp().takeIf { it != AV_NOPTS_VALUE } ?: frame.pts()
                val at = if (pts == AV_NOPTS_VALUE) seekTarget else pts * timeBase
                skipFrames = maxOf(0L, ((seekTarget - at) * RATE).toLong())
            }
            val drop = minOf(skipFrames, count.toLong()).toInt()
            skipFrames -= drop
            start = drop
            if (start >= count) return
        }
        val samples = (count - start) * CHANNELS
        if (pending.size < samples) pending = FloatArray(samples)
        converted.position((start * CHANNELS).toLong()).get(pending, 0, samples)
        converted.position(0)
        pendingStart = 0
        pendingEnd = samples
    }

    private fun setUpResampler(): SwrContext {
        // Filled in by swr_alloc_set_opts2 (FFmpeg's SwrContext**).
        val context = SwrContext()
        val input = frame.ch_layout()
        val status = swr_alloc_set_opts2(context, outLayout, AV_SAMPLE_FMT_FLT, RATE, input, frame.format(), frame.sample_rate(), 0, null)
        if (status < 0 || swr_init(context) < 0) throw IOException("Couldn't convert the audio")
        swr = context
        return context
    }

    override fun close() {
        Io.unregister(id)
        swr?.let { swr_free(it) }
        swr = null
        av_frame_free(frame)
        av_packet_free(packet)
        avcodec_free_context(codec)
        avformat_close_input(format)
        // With our own I/O, FFmpeg leaves it (and its buffer, maybe reallocated) to us.
        av_free(io.buffer())
        avio_context_free(io)
        converted.close()
        source.close()
    }
}
