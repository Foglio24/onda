package com.onda.seaglass.playback.karaoke

import android.content.Context
import android.os.SystemClock
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import com.onda.seaglass.core.tr
import com.onda.seaglass.playback.BitPerfect
import com.onda.seaglass.playback.automix.AutoMixLibrary
import com.onda.seaglass.playback.automix.PcmDecoder
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToLong
import kotlin.math.sqrt

/** Karaoke: the song as it is, without its voice, or its voice alone, as on the iPhone. */
enum class KaraokeMode {
    OFF, NO_VOCALS, VOCALS_ONLY;

    val title: String
        get() = when (this) {
            OFF -> tr("Normale")
            NO_VOCALS -> tr("Senza voce")
            VOCALS_ONLY -> tr("Solo voce")
        }

    /** The vocals' and the rest's volumes; [amount] 1 removes the other part completely. */
    fun gains(amount: Float): Pair<Float, Float> = when (this) {
        OFF -> 1f to 1f
        NO_VOCALS -> (1 - amount) to 1f
        VOCALS_ONLY -> 1f to (1 - amount)
    }
}

sealed interface KaraokeStatus {
    data object Idle : KaraokeStatus
    /** The model being downloaded (the first time). */
    data class Downloading(val progress: Double) : KaraokeStatus
    /** Separating the song where it plays: the share of the song done and, once known, the seconds left. */
    data class Preparing(val progress: Double, val remaining: Double?) : KaraokeStatus
    data object Ready : KaraokeStatus
    data class Failed(val message: String) : KaraokeStatus
}

/**
 * The AI karaoke: the playing song's vocals separated by the UVR MDX-Net "Voc_FT" model on the phone
 * ([MdxSeparator], as the iPhone app does with Core ML), a piece of about 5.8 s at a time from where
 * it plays (then the rest, then from the start), kept on disk for the newest songs ([KaraokeStems]),
 * and taken away from the song, or kept alone, in the main player's audio ([KaraokeProcessor]). The
 * song keeps playing meanwhile; the karaoke starts as soon as the piece playing is separated.
 */
@OptIn(UnstableApi::class, ExperimentalCoroutinesApi::class)
object Karaoke {
    private const val TAG = "Karaoke"
    /** Songs this long or longer (an hour-long mix) aren't separated. */
    private const val LENGTH_LIMIT = 15 * 60.0
    private const val KEEP_SONGS = 3

    private val _mode = MutableStateFlow(KaraokeMode.OFF)
    val mode: StateFlow<KaraokeMode> = _mode.asStateFlow()
    private val _amount = MutableStateFlow(1f)
    val amount: StateFlow<Float> = _amount.asStateFlow()
    private val _status = MutableStateFlow<KaraokeStatus>(KaraokeStatus.Idle)
    val status: StateFlow<KaraokeStatus> = _status.asStateFlow()
    /** "12 pezzi in 25 s", for the logs. */
    @Volatile var lastRun: String? = null
        private set

    private lateinit var context: Context
    private var player: ExoPlayer? = null
    private var processor: KaraokeProcessor? = null
    private var scope: CoroutineScope? = null
    private var job: Job? = null
    private var checker: Job? = null
    private var stems: KaraokeStems? = null
    private var audio: File? = null
    private var separator: MdxSeparator? = null
    /** One piece at a time, on its own thread (the model uses several of its own). */
    private val work = Dispatchers.Default.limitedParallelism(1)
    private var seenMismatches = 0
    private var secondsPerPiece: Double? = null
    private var lastJump = 0L

    fun setMode(mode: KaraokeMode) {
        _mode.value = mode
        applyGains()
        restart()
    }

    fun setAmount(amount: Float) {
        _amount.value = amount
        applyGains()
    }

    private fun applyGains() {
        val (vocals, instrumental) = _mode.value.gains(_amount.value)
        processor?.vocalsGain = vocals
        processor?.instrumentalGain = instrumental
    }

    /** Called by the playback service with its player and the processor in its audio. */
    fun attach(context: Context, player: ExoPlayer, processor: KaraokeProcessor, scope: CoroutineScope) {
        this.context = context.applicationContext
        this.player = player
        this.processor = processor
        this.scope = scope
        applyGains()
        player.addListener(listener)
        checker = scope.launch { watch() }
        restart()
    }

    fun detach() {
        player?.removeListener(listener)
        job?.cancel()
        checker?.cancel()
        processor?.stems = null
        stems?.close()
        stems = null
        val old = separator
        separator = null
        scope?.launch(work) { runCatching { old?.close() } }
        player = null
        processor = null
        scope = null
    }

    private val listener = object : Player.Listener {
        override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) = restart()
    }

    /** Starts (or stops) separating the playing song, as the mode and the song say. */
    private fun restart() {
        val player = player ?: return
        val scope = scope ?: return
        job?.cancel()
        processor?.stems = null
        processor?.enabled = false
        stems?.close()
        stems = null
        audio = null
        if (_mode.value == KaraokeMode.OFF) {
            _status.value = KaraokeStatus.Idle
            // The model's memory is given back until karaoke is used again.
            val old = separator
            separator = null
            scope.launch(work) { runCatching { old?.close() } }
            return
        }
        val videoId = player.currentMediaItem?.mediaId
        if (videoId == null) {
            _status.value = KaraokeStatus.Idle
            return
        }
        if (BitPerfect.active) {
            _status.value = KaraokeStatus.Failed(tr("Il karaoke non funziona con l'uscita bit-perfect."))
            return
        }
        _status.value = KaraokeStatus.Preparing(0.0, null)
        job = scope.launch { separate(videoId) }
    }

    private suspend fun separate(videoId: String) {
        try {
            val model = if (KaraokeModel.isReady(context)) KaraokeModel.file(context) else {
                _status.value = KaraokeStatus.Downloading(0.0)
                KaraokeModel.ensure(context) { progress -> _status.value = KaraokeStatus.Downloading(progress) }
            }
            _status.value = KaraokeStatus.Preparing(0.0, null)
            val file = AutoMixLibrary.songAudio(videoId) ?: throw KaraokeException(tr("Non riesco a leggere l'audio del brano."))
            val opened = withContext(work) {
                // The rate the song decodes at (a song in HE-AAC says half of it), and its length.
                val rate = runCatching { PcmDecoder.stereo(file, 0.0, 0.2).rate }.getOrNull()
                    ?: throw KaraokeException(tr("Non riesco a leggere l'audio del brano."))
                val duration = durationOf(file) ?: throw KaraokeException(tr("Non riesco a leggere l'audio del brano."))
                if (duration > LENGTH_LIMIT) throw KaraokeException(tr("La separazione di voce e musica non è riuscita."))
                val folder = File(context.cacheDir, "karaoke")
                KaraokeStems.prune(folder, KEEP_SONGS, except = videoId)
                KaraokeStems.open(folder, videoId, rate, (duration * rate).toInt())
            }
            stems = opened
            audio = file
            processor?.stems = opened
            val separator = separator ?: withContext(work) {
                MdxSeparator(model, Runtime.getRuntime().availableProcessors().coerceIn(1, 4))
            }.also { separator = it }
            val started = SystemClock.elapsedRealtime()
            var made = 0
            secondsPerPiece = null
            report(opened, null)
            while (!opened.complete) {
                val piece = nextPiece(opened)
                val pieceStarted = SystemClock.elapsedRealtime()
                withContext(work) { separatePiece(separator, opened, file, piece) }
                made++
                secondsPerPiece = (SystemClock.elapsedRealtime() - started) / 1000.0 / made
                report(opened, secondsPerPiece)
                Log.i(TAG, "$videoId: piece ${piece + 1}/${opened.pieces} in ${SystemClock.elapsedRealtime() - pieceStarted} ms")
            }
            lastRun = "$made pieces in ${(SystemClock.elapsedRealtime() - started) / 1000} s"
            Log.i(TAG, "$videoId separated: $lastRun")
            report(opened, secondsPerPiece)
            prepareNext(separator)
        } catch (e: CancellationException) {
            throw e
        } catch (e: OutOfMemoryError) {
            Log.w(TAG, "Karaoke of $videoId ran out of memory", e)
            _status.value = KaraokeStatus.Failed(tr("Memoria insufficiente per il karaoke: chiudi qualche app e riprova."))
        } catch (e: KaraokeException) {
            _status.value = KaraokeStatus.Failed(e.message ?: tr("La separazione di voce e musica non è riuscita."))
        } catch (e: Throwable) {
            Log.w(TAG, "Karaoke of $videoId failed", e)
            _status.value = KaraokeStatus.Failed(tr("La separazione di voce e musica non è riuscita."))
        }
    }

    private class KaraokeException(message: String) : Exception(message)

    /**
     * The next song in the queue separated now too, while this one plays, so its karaoke is ready from
     * its first note (on phones slower than the music, that's where it can start).
     */
    private suspend fun prepareNext(separator: MdxSeparator) {
        val player = player ?: return
        if (!player.hasNextMediaItem()) return
        val videoId = player.getMediaItemAt(player.nextMediaItemIndex).mediaId
        runCatching {
            val file = AutoMixLibrary.songAudio(videoId) ?: return
            withContext(work) {
                val rate = PcmDecoder.stereo(file, 0.0, 0.2).rate
                val duration = durationOf(file) ?: return@withContext
                if (duration > LENGTH_LIMIT) return@withContext
                val folder = File(context.cacheDir, "karaoke")
                KaraokeStems.prune(folder, KEEP_SONGS, except = videoId)
                KaraokeStems.open(folder, videoId, rate, (duration * rate).toInt()).use { next ->
                    for (k in 0 until next.pieces) {
                        if (!next.isDone(k)) separatePiece(separator, next, file, k)
                    }
                }
            }
            Log.i(TAG, "$videoId (next) separated")
        }.onFailure { if (it is CancellationException) throw it else Log.w(TAG, "Karaoke of the next song $videoId failed", it) }
    }

    /** The song's frame playing now (the separation's count). */
    private fun playingFrame(stems: KaraokeStems): Int =
        ((player?.currentPosition ?: 0L) / 1000.0 * stems.rate).toInt().coerceIn(0, stems.frames - 1)

    /** The piece to separate next: the one playing (or the next after it) first, then the rest in order. */
    private fun nextPiece(stems: KaraokeStems): Int {
        // A piece's worth ahead of where it plays now, as playback moves on while it's separated.
        val playing = stems.pieceAt(playingFrame(stems))
        for (k in playing until stems.pieces) if (!stems.isDone(k)) return k
        for (k in 0 until playing) if (!stems.isDone(k)) return k
        return playing
    }

    /**
     * Whether the karaoke can play without gaps from here: [ahead] seconds separated from where the song
     * plays, [left] seconds still to separate after them, at [pace] seconds of work per second of music.
     * Faster than the music, a few seconds ahead are enough; slower, the separation must be far enough
     * ahead to reach the end before playback catches up with it (the gap shrinks by (pace - 1) seconds
     * for each second separated).
     */
    internal fun canPlay(ahead: Double, left: Double, pace: Double?): Boolean = when {
        left <= 0 -> ahead > 0.5
        pace == null -> false
        else -> ahead >= max(3.0, left * (pace - 1) * 1.1)
    }

    /**
     * Turns the karaoke on once the separation is far enough ahead of where the song plays to stay
     * ahead until the end, at the speed it goes on this phone (on a phone faster than the music, a
     * few seconds ahead; slower, enough to make up for it, or the whole rest of the song); off again
     * when playback jumps where it isn't. Says how it's going meanwhile.
     */
    private fun report(stems: KaraokeStems, secondsPerPiece: Double?) {
        val processor = processor ?: return
        val frame = playingFrame(stems)
        // How far the separated part goes on, without a gap, from where it plays.
        var end = frame
        while (end < stems.frames && stems.isReady(end.toLong(), min(KaraokeStems.BLOCK, stems.frames - end))) end += KaraokeStems.BLOCK
        val ahead = (min(end, stems.frames) - frame).toDouble() / stems.rate
        val left = (stems.frames - min(end, stems.frames)).toDouble() / stems.rate
        // Seconds of work per second of music.
        val pieceSeconds = (if (stems.pieces > 1) stems.modelStart(1) else stems.modelCount(0)).coerceAtLeast(1) /
            MdxSpectrogram.SAMPLE_RATE.toDouble()
        val pace = secondsPerPiece?.let { it / pieceSeconds }
        if (canPlay(ahead, left, pace) || processor.enabled && ahead > 0.5) {
            processor.enabled = true
            _status.value = KaraokeStatus.Ready
            return
        }
        processor.enabled = false
        val remaining = when {
            secondsPerPiece == null -> null
            pace != null && pace <= 1 -> secondsPerPiece * (stems.pieceAt(frame)..min(stems.pieces - 1, stems.pieceAt(frame) + 1)).count { !stems.isDone(it) }
            // Slower than the music: it plays once the rest of the song is separated.
            else -> secondsPerPiece * (0 until stems.pieces).count { !stems.isDone(it) }
        }
        _status.value = KaraokeStatus.Preparing(stems.doneCount.toDouble() / stems.pieces, remaining)
    }

    /**
     * One piece: the song decoded at its own rate around it, converted to the model's 44.1 kHz (from a
     * frame where the two rates meet, so nothing shifts by a fraction of a sample), separated, and the
     * vocals converted back and stored.
     */
    private fun separatePiece(separator: MdxSeparator, stems: KaraokeStems, file: File, k: Int) {
        val rate = stems.rate
        val common = gcd(rate, MdxSpectrogram.SAMPLE_RATE)
        val modelUnit = MdxSpectrogram.SAMPLE_RATE / common
        val songUnit = rate / common
        val margin = rate / 20
        val first = max(0, (stems.start(k) - margin) / songUnit * songUnit)
        val last = min(stems.frames, stems.end(k) + margin)
        val pcm = PcmDecoder.stereo(file, first.toDouble() / rate - 0.005, (last - first).toDouble() / rate + 0.02)
        // The decoded frames from `first` on (decoding may start a frame or so off).
        val firstDecoded = (pcm.start * rate).roundToLong().toInt()
        val song = FloatArray((last - first) * 2)
        for (i in 0 until last - first) {
            val source = first + i - firstDecoded
            if (source < 0 || source >= pcm.frames) continue
            song[i * 2] = pcm.samples[source * 2]
            song[i * 2 + 1] = pcm.samples[source * 2 + 1]
        }
        val atModelRate = if (rate == MdxSpectrogram.SAMPLE_RATE) song else Resample.stereo(song, rate, MdxSpectrogram.SAMPLE_RATE)
        val count = stems.modelCount(k)
        val from = stems.modelStart(k) - first / songUnit * modelUnit
        val input = FloatArray(count * 2)
        for (i in 0 until count * 2) {
            val index = from * 2 + i
            if (index in atModelRate.indices) input[i] = atModelRate[index]
        }
        val vocals = separator.vocals(input, 0, count)
        val back = if (rate == MdxSpectrogram.SAMPLE_RATE) vocals else Resample.stereo(vocals, MdxSpectrogram.SAMPLE_RATE, rate)
        stems.write(k, back)
    }

    /**
     * Meanwhile: measures the offset between the player's frames and the separation's when the
     * processor asks (a jump, a new song, every few seconds), jumps the player to where it is when
     * its frames don't match the song any more (after a song followed another with no jump), and
     * reads the vocals ahead of where they play.
     */
    private suspend fun watch() {
        var lastTouch = 0L
        while (kotlinx.coroutines.currentCoroutineContext().isActive) {
            delay(60)
            val processor = processor ?: continue
            val check = processor.check
            if (check.state == KaraokeProcessor.Check.CAPTURED) {
                val song = check.stems
                val file = audio
                val result = if (song != null && song === stems && file != null) {
                    withContext(Dispatchers.IO) { runCatching { measure(song, file, check) } }
                } else {
                    Result.success(null)
                }
                check.offset = result.getOrNull()
                check.inconclusive = result.isFailure
                check.state = KaraokeProcessor.Check.MEASURED
                Log.i(TAG, "Offset at ${check.frame}: " + (result.exceptionOrNull()?.let { "not read ($it)" } ?: result.getOrNull() ?: "no match"))
            }
            if (processor.mismatches != seenMismatches) {
                seenMismatches = processor.mismatches
                val now = SystemClock.elapsedRealtime()
                if (_mode.value != KaraokeMode.OFF && now - lastJump > 15_000) {
                    // A jump to where it plays gives the processor the song's time again.
                    lastJump = now
                    player?.let { it.seekTo(it.currentPosition) }
                }
            }
            val song = stems
            val now = SystemClock.elapsedRealtime()
            if (song != null && now - lastTouch > 500) {
                lastTouch = now
                val frame = playingFrame(song)
                withContext(Dispatchers.IO) { song.touch(frame, song.rate * 8) }
                // Playback may reach what isn't separated yet (or a jump may land there) between pieces.
                if (job?.isActive == true && _status.value !is KaraokeStatus.Downloading) report(song, secondsPerPiece)
            }
        }
    }

    /**
     * The offset (in frames) from the player's count to the separation's, found by comparing the
     * moment captured with the song decoded around it: roughly on a coarse grid, then frame by frame.
     * Null when nothing matches well (not this song, or not this moment of it).
     */
    private fun measure(stems: KaraokeStems, file: File, check: KaraokeProcessor.Check): Int? {
        val rate = stems.rate
        val search = rate * 15 / 100
        val frames = check.frames
        val from = max(0L, check.frame - search)
        val pcm = PcmDecoder.stereo(file, from.toDouble() / rate, (frames + 2 * search).toDouble() / rate + 0.02)
        val base = (pcm.start * rate).roundToLong()
        val song = FloatArray(pcm.frames) { pcm.samples[it * 2] + pcm.samples[it * 2 + 1] }
        val heard = FloatArray(frames) { (check.samples[it * 2] + check.samples[it * 2 + 1]) / 32768f }
        fun correlation(lag: Int, stride: Int): Double {
            // The heard moment against the song from frame (check.frame + lag).
            var xy = 0.0
            var xx = 0.0
            var yy = 0.0
            val offset = (check.frame + lag - base).toInt()
            var i = 0
            while (i < frames) {
                val j = offset + i
                if (j in song.indices) {
                    val x = heard[i]
                    val y = song[j]
                    xy += x * y
                    xx += x * x
                    yy += y * y
                }
                i += stride
            }
            return if (xx > 0 && yy > 0) xy / sqrt(xx * yy) else 0.0
        }
        var best = 0
        var bestScore = -1.0
        var lag = -search
        while (lag <= search) {
            val score = correlation(lag, 4)
            if (score > bestScore) {
                bestScore = score
                best = lag
            }
            lag += 4
        }
        // Then frame by frame around the best.
        val coarse = best
        var score = correlation(coarse, 1)
        for (fine in coarse - 6..coarse + 6) {
            val value = correlation(fine, 1)
            if (value > score) {
                score = value
                best = fine
            }
        }
        return if (score > 0.95) best else null
    }

    private fun durationOf(file: File): Double? {
        val extractor = android.media.MediaExtractor()
        return try {
            extractor.setDataSource(file.path)
            val track = (0 until extractor.trackCount).firstOrNull {
                extractor.getTrackFormat(it).getString(android.media.MediaFormat.KEY_MIME)?.startsWith("audio/") == true
            } ?: return null
            val format = extractor.getTrackFormat(track)
            if (format.containsKey(android.media.MediaFormat.KEY_DURATION)) format.getLong(android.media.MediaFormat.KEY_DURATION) / 1_000_000.0 else null
        } finally {
            extractor.release()
        }
    }

    private fun gcd(a: Int, b: Int): Int = if (b == 0) a else gcd(b, a % b)
}
