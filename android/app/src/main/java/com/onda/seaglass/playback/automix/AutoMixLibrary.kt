package com.onda.seaglass.playback.automix

import android.content.Context
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.SystemClock
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSpec
import com.onda.seaglass.data.Streams
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
        // Mixes are made for the songs about to play: none from before is any use.
        folder.listFiles { f -> f.name.startsWith("mix-") || f.name.endsWith(".part") }?.forEach { it.delete() }
    }

    fun known(videoId: String): SongAnalysis? =
        if (!isVideoId(videoId)) null else memory[videoId] ?: load(videoId)?.also { memory[videoId] = it }

    private fun load(videoId: String): SongAnalysis? =
        runCatching { SongAnalysis.fromJson(JSONObject(File(folder, "$videoId.json").readText())) }.getOrNull()

    /** The song's analysis, made now unless it was before; null when it can't be. */
    suspend fun analysis(videoId: String): SongAnalysis? {
        if (!isVideoId(videoId)) return null
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

    /**
     * The [plan]'s mix between two songs, rendered into a file (see [MixRenderer]) with each song at
     * the volume [gainOf] gives it; null when it can't be made.
     */
    suspend fun render(plan: TransitionPlan, outgoingId: String, incomingId: String, gainOf: (String) -> Float): MixInfo? {
        if (!isVideoId(outgoingId) || !isVideoId(incomingId)) return null
        return withContext(Dispatchers.IO) {
            runCatching {
                val started = SystemClock.elapsedRealtime()
                val outgoingFile = locks.getOrPut(outgoingId) { Mutex() }.withLock { audio(outgoingId) }
                val incomingFile = locks.getOrPut(incomingId) { Mutex() }.withLock { audio(incomingId) }
                // The volumes come with the songs' links: make sure both are known.
                for (id in listOf(outgoingId, incomingId)) if (Streams.loudness(id) == null) runCatching { Streams.resolve(id) }
                val from = maxOf(0.0, plan.outStart - MixRenderer.BEFORE)
                val outgoing = PcmDecoder.stereo(outgoingFile, from, plan.outEnd - from + 0.2)
                val incomingSeconds = (plan.outEnd - plan.outStart + MixRenderer.AFTER) * plan.incomingRate + 0.5
                val incoming = PcmDecoder.stereo(incomingFile, plan.inStart, incomingSeconds)
                val mix = withContext(Dispatchers.Default) {
                    MixRenderer.render(plan, outgoing, incoming, gainOf(outgoingId), gainOf(incomingId))
                }
                val file = File(folder, "mix-${System.currentTimeMillis()}.wav")
                val info = mix.write(file)
                pruneMixes(keep = file)
                Log.i(TAG, "Mix $outgoingId → $incomingId rendered in ${SystemClock.elapsedRealtime() - started} ms: " +
                    "${"%.1f".format(info.length)} s, the next song at ${"%.2f".format(info.incomingAt)} s")
                info
            }.onFailure { Log.w(TAG, "Mix of $outgoingId → $incomingId failed", it) }.getOrNull()
        }
    }

    private suspend fun analyze(videoId: String): SongAnalysis? = coroutineScope {
        val file = audio(videoId)
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
    }

    /** The song's audio file, as the player plays it (for the karaoke too); null for what isn't a YouTube song. */
    suspend fun songAudio(videoId: String): File? {
        if (!isVideoId(videoId)) return null
        return withContext(Dispatchers.IO) { locks.getOrPut(videoId) { Mutex() }.withLock { audio(videoId) } }
    }

    /**
     * The song's audio, as the player plays it: kept for the newest few songs (the mix is made from
     * it), otherwise read again. Call with the song's lock held.
     */
    private fun audio(videoId: String): File {
        val file = File(folder, "$videoId.audio")
        if (file.length() > 0) {
            file.setLastModified(System.currentTimeMillis())
            return file
        }
        val part = File(folder, "$videoId.part")
        try {
            fetch(videoId, part)
            if (!part.renameTo(file)) error("Couldn't keep the audio of $videoId")
        } finally {
            part.delete()
        }
        // The newest four songs' audio stays.
        folder.listFiles { f -> f.name.endsWith(".audio") }
            ?.sortedByDescending { it.lastModified() }?.drop(4)?.forEach { it.delete() }
        return file
    }

    /** The newest two mixes stay: the one playing and the next. */
    private fun pruneMixes(keep: File) {
        folder.listFiles { f -> f.name.startsWith("mix-") && f != keep }
            ?.sortedByDescending { it.lastModified() }?.drop(1)?.forEach { it.delete() }
    }

    /** A YouTube video ID: these name files here, so nothing else is let through. */
    private fun isVideoId(id: String) = id.length == 11 && id.all { it.isLetterOrDigit() && it.code < 128 || it == '-' || it == '_' }

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
        val out = Resampler(Analyzer.SAMPLE_RATE)
        PcmDecoder.decode(file, from, seconds) { _, samples, offset, channels, rate ->
            var sum = 0f
            for (c in 0 until channels) sum += samples[offset + c]
            out.add(sum / channels / 32768f, rate)
        }
        return out.samples()
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
