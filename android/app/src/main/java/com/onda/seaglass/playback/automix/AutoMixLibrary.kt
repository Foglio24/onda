package com.onda.seaglass.playback.automix

import android.content.Context
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSpec
import com.onda.seaglass.playback.audioDataSourceFactory
import com.onda.seaglass.playback.streamUri
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.nio.ByteOrder
import java.util.concurrent.ConcurrentHashMap

/** A song's two ends as AutoMix needs them: its first and last minute. */
data class SongAnalysis(val videoId: String, val duration: Double, val head: WindowAnalysis, val tail: WindowAnalysis) {
    fun toJson(): JSONObject = JSONObject()
        .put("version", VERSION).put("videoId", videoId).put("duration", duration)
        .put("head", head.toJson()).put("tail", tail.toJson())

    companion object {
        const val VERSION = 1

        fun fromJson(json: JSONObject): SongAnalysis? = runCatching {
            if (json.getInt("version") != VERSION) return null
            SongAnalysis(
                json.getString("videoId"), json.getDouble("duration"),
                WindowAnalysis.fromJson(json.getJSONObject("head")), WindowAnalysis.fromJson(json.getJSONObject("tail")),
            )
        }.getOrNull()
    }
}

/**
 * AutoMix's analyses, made once per song and kept on disk. The song's audio is read through the
 * player's own data source (from the phone when downloaded, otherwise the same YouTube rendition the
 * player streams, so the beats fall where the player plays them), decoded with MediaCodec only
 * around its first and last minute.
 */
@OptIn(UnstableApi::class)
object AutoMixLibrary {
    private const val WINDOW = 60.0
    private const val TAG = "AutoMix"
    /** Hour-long mixes aren't analysed. */
    private const val LENGTH_LIMIT = 15 * 60.0

    private lateinit var folder: File
    private val memory = ConcurrentHashMap<String, SongAnalysis>()
    private val locks = ConcurrentHashMap<String, Mutex>()

    fun init(context: Context) {
        folder = File(context.cacheDir, "automix").apply { mkdirs() }
    }

    fun known(videoId: String): SongAnalysis? = memory[videoId] ?: load(videoId)?.also { memory[videoId] = it }

    private fun load(videoId: String): SongAnalysis? =
        runCatching { SongAnalysis.fromJson(JSONObject(File(folder, "$videoId.json").readText())) }.getOrNull()

    /** The song's analysis, made now unless it was before; null when it can't be. */
    suspend fun analysis(videoId: String): SongAnalysis? {
        known(videoId)?.let { return it }
        val lock = locks.getOrPut(videoId) { Mutex() }
        return lock.withLock {
            known(videoId) ?: withContext(Dispatchers.IO) {
                runCatching { analyze(videoId) }
                    .onFailure { Log.w(TAG, "Analysis of $videoId failed", it) }
                    .getOrNull()
            }?.also { result ->
                memory[videoId] = result
                runCatching { File(folder, "$videoId.json").writeText(result.toJson().toString()) }
                prune()
            }
        }
    }

    private suspend fun analyze(videoId: String): SongAnalysis? = coroutineScope {
        val file = File(folder, "$videoId.audio")
        try {
            fetch(videoId, file)
            val duration = durationOf(file) ?: return@coroutineScope null
            if (duration > LENGTH_LIMIT || duration < 30) return@coroutineScope null
            val head: Deferred<WindowAnalysis> = async(Dispatchers.Default) {
                Analyzer.analyze(decode(file, 0.0, WINDOW), 0.0)
            }
            val tailStart = maxOf(0.0, duration - WINDOW)
            val tail = async(Dispatchers.Default) { Analyzer.analyze(decode(file, tailStart, WINDOW), tailStart) }
            SongAnalysis(videoId, duration, head.await(), tail.await()).also {
                Log.i(TAG, "$videoId: ${"%.1f".format(it.head.tempo)}/${"%.1f".format(it.tail.tempo)} BPM, " +
                    "confidence ${"%.2f".format(it.head.confidence)}/${"%.2f".format(it.tail.confidence)}")
            }
        } finally {
            file.delete()
        }
    }

    /** The whole file, through the player's data source (1 MB ranges, or the phone's copy). */
    private fun fetch(videoId: String, file: File) {
        val source = audioDataSourceFactory().createDataSource()
        try {
            source.open(DataSpec(streamUri(videoId)))
            file.outputStream().use { out ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val read = source.read(buffer, 0, buffer.size)
                    if (read == C.RESULT_END_OF_INPUT) break
                    out.write(buffer, 0, read)
                }
            }
        } finally {
            source.close()
        }
    }

    private fun durationOf(file: File): Double? {
        val extractor = MediaExtractor()
        return try {
            extractor.setDataSource(file.path)
            val track = (0 until extractor.trackCount).firstOrNull {
                extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
            } ?: return null
            val format = extractor.getTrackFormat(track)
            if (format.containsKey(MediaFormat.KEY_DURATION)) format.getLong(MediaFormat.KEY_DURATION) / 1_000_000.0 else null
        } finally {
            extractor.release()
        }
    }

    /** [seconds] of the file from [from], as mono samples at the analyser's rate. */
    private fun decode(file: File, from: Double, seconds: Double): FloatArray {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            extractor.setDataSource(file.path)
            val track = (0 until extractor.trackCount).first {
                extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
            }
            extractor.selectTrack(track)
            val format = extractor.getTrackFormat(track)
            val mime = format.getString(MediaFormat.KEY_MIME)!!
            var rate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            val startUs = (from * 1_000_000).toLong()
            val endUs = ((from + seconds) * 1_000_000).toLong()
            if (from > 0) extractor.seekTo(startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            codec = MediaCodec.createDecoderByType(mime).apply {
                configure(format, null, null, 0)
                start()
            }
            val out = Resampler(Analyzer.SAMPLE_RATE)
            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var outputDone = false
            while (!outputDone) {
                if (!inputDone) {
                    val index = codec.dequeueInputBuffer(10_000)
                    if (index >= 0) {
                        val buffer = codec.getInputBuffer(index)!!
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
                        val buffer = codec.getOutputBuffer(index)!!.order(ByteOrder.nativeOrder())
                        buffer.position(info.offset)
                        buffer.limit(info.offset + info.size)
                        val shorts = buffer.asShortBuffer()
                        val frames = shorts.remaining() / channels
                        // Samples before the window (after seeking to the previous sync point) are skipped.
                        val firstFrameUs = info.presentationTimeUs
                        for (i in 0 until frames) {
                            val timeUs = firstFrameUs + i * 1_000_000L / rate
                            if (timeUs < startUs) continue
                            if (timeUs >= endUs) {
                                outputDone = true
                                break
                            }
                            var sum = 0f
                            for (c in 0 until channels) sum += shorts.get(i * channels + c)
                            out.add(sum / channels / 32768f, rate)
                        }
                        codec.releaseOutputBuffer(index, false)
                    }
                }
            }
            return out.samples()
        } finally {
            runCatching { codec?.stop() }
            codec?.release()
            extractor.release()
        }
    }

    /** Keeps the newest 500 analyses. */
    private fun prune() {
        val files = folder.listFiles { f -> f.name.endsWith(".json") } ?: return
        if (files.size <= 500) return
        files.sortedBy { it.lastModified() }.take(files.size - 500).forEach { it.delete() }
    }

    /** Averages samples down to the analyser's rate (a box filter is enough for finding beats). */
    private class Resampler(private val target: Int) {
        private var data = FloatArray(1 shl 16)
        private var size = 0
        private var position = 0.0
        private var sum = 0f
        private var count = 0

        fun add(sample: Float, rate: Int) {
            sum += sample
            count++
            position += target.toDouble() / rate
            if (position >= 1) {
                position -= 1
                if (size == data.size) data = data.copyOf(size * 2)
                data[size++] = sum / count
                sum = 0f
                count = 0
            }
        }

        fun samples(): FloatArray = data.copyOf(size)
    }
}
