package com.onda.seaglass.audio.karaoke

import com.onda.seaglass.audio.ByteSource
import com.onda.seaglass.audio.Deck
import com.onda.seaglass.audio.Decoder
import com.onda.seaglass.core.Log
import com.onda.seaglass.core.Paths
import com.onda.seaglass.core.tr
import com.onda.seaglass.model.Track
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
 * The AI karaoke, as on the iPhone and Android: the playing song's vocals separated by the UVR
 * MDX-Net "Voc_FT" model on this computer ([MdxSeparator], ONNX Runtime), a piece of about 5.8 s at a
 * time from where it plays (then the rest, then from the start), kept on disk for the newest songs
 * ([KaraokeStems]), and taken away from the song, or kept alone, in the deck's audio ([KaraokeTap]).
 * The song keeps playing meanwhile; the karaoke starts as soon as the separation is far enough ahead
 * of it. The next song is separated while this one plays, so its karaoke is there from its first note.
 */
@OptIn(ExperimentalCoroutinesApi::class)
object Karaoke {
    /** Songs this long or longer (an hour-long mix) aren't separated. */
    private const val LENGTH_LIMIT = 15 * 60
    private const val KEEP_SONGS = 3

    private val _mode = MutableStateFlow(KaraokeMode.OFF)
    val mode: StateFlow<KaraokeMode> = _mode.asStateFlow()
    private val _amount = MutableStateFlow(1f)
    val amount: StateFlow<Float> = _amount.asStateFlow()
    private val _status = MutableStateFlow<KaraokeStatus>(KaraokeStatus.Idle)
    val status: StateFlow<KaraokeStatus> = _status.asStateFlow()
    /** "12 pieces in 25 s", for the log. */
    @Volatile var lastRun: String? = null
        private set

    private var scope: CoroutineScope? = null
    private var position: () -> Double = { 0.0 }
    private var sourceFor: suspend (Track) -> (() -> ByteSource) = { throw IllegalStateException("Karaoke isn't started") }
    private var job: Job? = null
    private var watcher: Job? = null
    private var separator: MdxSeparator? = null
    /** One piece at a time, on its own thread (the model uses several of its own). */
    private val work = Dispatchers.Default.limitedParallelism(1)
    private var secondsPerPiece: Double? = null

    private val folder: File get() = File(Paths.cache, "Karaoke")

    /** The stems open now, by song, and the songs whose karaoke may play. */
    private val open = HashMap<String, KaraokeStems>()
    private val ready = HashSet<String>()
    private val taps = ArrayList<KaraokeTap>()

    private var currentTrack: Track? = null
    private var nextTrack: Track? = null
    private var working: Pair<String?, String?>? = null

    /** Called once by the player: where the playing song is (seconds) and how to read a song's bytes. */
    fun start(scope: CoroutineScope, position: () -> Double, sourceFor: suspend (Track) -> (() -> ByteSource)) {
        this.scope = scope
        this.position = position
        this.sourceFor = sourceFor
        watcher?.cancel()
        watcher = scope.launch { watch() }
    }

    fun setMode(mode: KaraokeMode) {
        _mode.value = mode
        applyGains()
        KaraokeLive.on = mode != KaraokeMode.OFF
        restart()
    }

    fun setAmount(amount: Float) {
        _amount.value = amount
        applyGains()
    }

    private fun applyGains() {
        val (vocals, instrumental) = _mode.value.gains(_amount.value)
        KaraokeLive.vocalsGain = vocals
        KaraokeLive.instrumentalGain = instrumental
    }

    /** Gives a new deck its tap, and the song's stems if they're there already. */
    fun attach(deck: Deck, track: Track) {
        val tap = KaraokeTap(track.videoId)
        synchronized(this) {
            tap.stems = open[track.videoId]
            tap.enabled = track.videoId in ready
            taps.add(tap)
            while (taps.size > 8) taps.removeAt(0)
        }
        deck.karaoke = tap
    }

    /** The song playing and the one after it (null for none): the player says it whenever they change. */
    fun songs(current: Track?, next: Track?) {
        val sameSong = currentTrack?.videoId == current?.videoId
        currentTrack = current
        nextTrack = next
        if (_mode.value == KaraokeMode.OFF) return
        // Only the next song changed (the queue was edited): the playing song's karaoke goes on meanwhile.
        if (working != (current?.videoId to next?.videoId)) restart(keepReady = sameSong)
    }

    private fun restart(keepReady: Boolean = false) {
        val scope = scope ?: return
        job?.cancel()
        working = null
        if (!keepReady) {
            synchronized(this) {
                ready.clear()
                for (tap in taps) tap.enabled = false
            }
        }
        if (_mode.value == KaraokeMode.OFF) {
            _status.value = KaraokeStatus.Idle
            // The model's memory is given back until karaoke is used again.
            val old = separator
            separator = null
            scope.launch(work) { runCatching { old?.close() } }
            return
        }
        val current = currentTrack ?: run {
            _status.value = KaraokeStatus.Idle
            return
        }
        val next = nextTrack
        working = current.videoId to next?.videoId
        _status.value = KaraokeStatus.Preparing(0.0, null)
        job = scope.launch { run(current, next) }
    }

    private class KaraokeException(message: String) : Exception(message)

    private suspend fun run(current: Track, next: Track?) {
        try {
            val model = if (KaraokeModel.isReady()) KaraokeModel.file() else {
                _status.value = KaraokeStatus.Downloading(0.0)
                KaraokeModel.ensure { progress -> _status.value = KaraokeStatus.Downloading(progress) }
            }
            _status.value = KaraokeStatus.Preparing(0.0, null)
            val stems = prepare(current)
            val separator = separator ?: withContext(work) {
                MdxSeparator(model, Runtime.getRuntime().availableProcessors().coerceIn(1, 4))
            }.also { separator = it }
            val started = System.nanoTime()
            var made = 0
            secondsPerPiece = null
            report(stems, null)
            while (!stems.complete) {
                val piece = nextPiece(stems)
                val pieceStarted = System.nanoTime()
                withContext(work) { separatePiece(separator, stems, piece) }
                made++
                secondsPerPiece = (System.nanoTime() - started) / 1e9 / made
                report(stems, secondsPerPiece)
                Log.info("Karaoke ${current.videoId}: piece ${piece + 1}/${stems.pieces} in ${(System.nanoTime() - pieceStarted) / 1_000_000} ms")
            }
            lastRun = "$made pieces in ${(System.nanoTime() - started) / 1_000_000_000} s"
            Log.info("Karaoke ${current.videoId} separated: $lastRun")
            report(stems, secondsPerPiece)
            if (next != null) prepareNext(separator, next)
        } catch (e: CancellationException) {
            throw e
        } catch (e: OutOfMemoryError) {
            Log.warn("Karaoke ran out of memory", e)
            _status.value = KaraokeStatus.Failed(tr("Memoria insufficiente per il karaoke: chiudi qualche app e riprova."))
        } catch (e: KaraokeException) {
            _status.value = KaraokeStatus.Failed(e.message ?: tr("La separazione di voce e musica non è riuscita."))
        } catch (e: Throwable) {
            Log.warn("Karaoke failed", e)
            _status.value = KaraokeStatus.Failed(tr("La separazione di voce e musica non è riuscita."))
        }
    }

    /** The song decoded whole (if it isn't already) and its stems opened, given to the decks that play it. */
    private suspend fun prepare(track: Track): KaraokeStems {
        val id = track.videoId
        synchronized(this) { open[id] }?.let { return it }
        if (!Paths.isVideoId(id) && !(id.startsWith("local:") && id.drop(6).all { it.isLetterOrDigit() })) {
            throw KaraokeException(tr("Non riesco a leggere l'audio del brano."))
        }
        val name = if (Paths.isVideoId(id)) id else "local-" + id.drop(6)
        val stems = withContext(work) {
            KaraokeStems.prune(folder, KEEP_SONGS, except = name)
            val frames = KaraokeStems.songFrames(folder, name) ?: run {
                val source = sourceFor(track)
                withContext(Dispatchers.IO) {
                    runCatching {
                        Decoder(source()).use { decoder ->
                            KaraokeStems.writeSong(folder, name, LENGTH_LIMIT * Decoder.RATE, { buffer, count -> decoder.read(buffer, count) })
                        }
                    }.getOrElse { error ->
                        if (error is java.io.IOException && error.message == "The song is too long") {
                            throw KaraokeException(tr("La separazione di voce e musica non è riuscita."))
                        }
                        Log.warn("Karaoke: the song couldn't be decoded", error)
                        throw KaraokeException(tr("Non riesco a leggere l'audio del brano."))
                    }
                }
            }
            KaraokeStems.open(folder, name, frames)
        }
        synchronized(this) {
            open[id] = stems
            for (tap in taps) if (tap.videoId == id) tap.stems = stems
            // Only the songs playing and next stay open.
            val keep = setOfNotNull(id, currentTrack?.videoId, nextTrack?.videoId)
            open.keys.filter { it !in keep }.forEach { old -> open.remove(old)?.close(); ready.remove(old) }
        }
        return stems
    }

    /** The next song separated now too, so its karaoke is ready from its first note. */
    private suspend fun prepareNext(separator: MdxSeparator, track: Track) {
        runCatching {
            val stems = prepare(track)
            withContext(work) {
                for (k in 0 until stems.pieces) if (!stems.isDone(k)) separatePiece(separator, stems, k)
            }
            synchronized(this) {
                ready.add(track.videoId)
                for (tap in taps) if (tap.videoId == track.videoId) tap.enabled = true
            }
            Log.info("Karaoke ${track.videoId} (next) separated")
        }.onFailure { if (it is CancellationException) throw it else Log.warn("Karaoke of the next song ${track.videoId} failed", it) }
    }

    /** The song's frame playing now (the separation's count). */
    private fun playingFrame(stems: KaraokeStems): Int =
        (position() * stems.rate).toInt().coerceIn(0, stems.frames - 1)

    /** The piece to separate next: the one playing first, then the rest in order, then from the start. */
    private fun nextPiece(stems: KaraokeStems): Int {
        val playing = stems.pieceAt(playingFrame(stems))
        for (k in playing until stems.pieces) if (!stems.isDone(k)) return k
        for (k in 0 until playing) if (!stems.isDone(k)) return k
        return playing
    }

    /**
     * Whether the karaoke can play without gaps from here: [ahead] seconds separated from where the song
     * plays, [left] seconds still to separate after them, at [pace] seconds of work per second of music.
     * Faster than the music, a few seconds ahead are enough; slower, the separation must be far enough
     * ahead to reach the end before playback catches up with it.
     */
    internal fun canPlay(ahead: Double, left: Double, pace: Double?): Boolean = when {
        left <= 0 -> ahead > 0.5
        pace == null -> false
        else -> ahead >= max(3.0, left * (pace - 1) * 1.1)
    }

    /** Turns the karaoke on once the separation is far enough ahead of the song to stay ahead; says how it goes. */
    private fun report(stems: KaraokeStems, secondsPerPiece: Double?) {
        val id = stems.videoId
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
        val enabled = synchronized(this) { id in ready }
        if (canPlay(ahead, left, pace) || enabled && ahead > 0.5) {
            synchronized(this) {
                ready.add(id)
                for (tap in taps) if (tap.videoId == id) tap.enabled = true
            }
            _status.value = KaraokeStatus.Ready
            return
        }
        synchronized(this) {
            ready.remove(id)
            for (tap in taps) if (tap.videoId == id) tap.enabled = false
        }
        val remaining = when {
            secondsPerPiece == null -> null
            pace != null && pace <= 1 -> secondsPerPiece * (stems.pieceAt(frame)..min(stems.pieces - 1, stems.pieceAt(frame) + 1)).count { !stems.isDone(it) }
            // Slower than the music: it plays once the rest of the song is separated.
            else -> secondsPerPiece * (0 until stems.pieces).count { !stems.isDone(it) }
        }
        _status.value = KaraokeStatus.Preparing(stems.doneCount.toDouble() / stems.pieces, remaining)
    }

    /**
     * One piece: the song's stored decode around it, converted to the model's 44.1 kHz (from a frame
     * where the two rates meet, so nothing shifts by a fraction of a sample), separated, and the
     * vocals converted back and stored.
     */
    private fun separatePiece(separator: MdxSeparator, stems: KaraokeStems, k: Int) {
        val rate = stems.rate
        val common = gcd(rate, MdxSpectrogram.SAMPLE_RATE)
        val modelUnit = MdxSpectrogram.SAMPLE_RATE / common
        val songUnit = rate / common
        val margin = rate / 20
        val first = max(0, (stems.start(k) - margin) / songUnit * songUnit)
        val last = min(stems.frames, stems.end(k) + margin)
        val song = FloatArray((last - first) * 2)
        for (i in 0 until last - first) {
            song[i * 2] = stems.songLeft(first + i)
            song[i * 2 + 1] = stems.songRight(first + i)
        }
        val atModelRate = Resample.stereo(song, rate, MdxSpectrogram.SAMPLE_RATE)
        val count = stems.modelCount(k)
        val from = stems.modelStart(k) - first / songUnit * modelUnit
        val input = FloatArray(count * 2)
        for (i in 0 until count * 2) {
            val index = from * 2 + i
            if (index in atModelRate.indices) input[i] = atModelRate[index]
        }
        val vocals = separator.vocals(input, 0, count)
        stems.write(k, Resample.stereo(vocals, MdxSpectrogram.SAMPLE_RATE, rate))
    }

    /**
     * Meanwhile: reads the vocals ahead of where they play (so the audio thread finds those pages in
     * memory, never waiting on the disk), and says how it goes when playback reaches what isn't
     * separated yet (or a jump lands there) between pieces.
     */
    private suspend fun watch() {
        while (true) {
            delay(500)
            val id = currentTrack?.videoId ?: continue
            val stems = synchronized(this) { open[id] } ?: continue
            val frame = playingFrame(stems)
            withContext(Dispatchers.IO) { stems.touch(frame, stems.rate * 8) }
            if (job?.isActive == true && _status.value !is KaraokeStatus.Downloading) report(stems, secondsPerPiece)
        }
    }

    private fun gcd(a: Int, b: Int): Int = if (b == 0) a else gcd(b, a % b)
}
