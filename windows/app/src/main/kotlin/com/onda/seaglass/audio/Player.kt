package com.onda.seaglass.audio

import com.onda.seaglass.core.Prefs
import com.onda.seaglass.core.tr
import com.onda.seaglass.data.Downloads
import com.onda.seaglass.data.InnerTube
import com.onda.seaglass.data.Library
import com.onda.seaglass.data.LocalMusic
import com.onda.seaglass.data.SongCache
import com.onda.seaglass.data.Streams
import com.onda.seaglass.model.Track
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.concurrent.atomic.AtomicLong

/** A song in the queue: the same song can be in it twice, so each entry has its own ID. */
data class QueueEntry(val track: Track, val id: Long = nextEntryId.incrementAndGet(), val added: Boolean = false)

private val nextEntryId = AtomicLong()

/**
 * The player: the queue, what plays and how. It finds each song's sound (a download, the cache
 * of recent songs, a song of the user's own or YouTube's stream), hands it to the [Engine] and
 * opens the next one ahead, so songs follow without a gap or with a crossfade. As on the Mac,
 * the queue goes on by itself with a radio of the last song. State is for the interface: it
 * changes on these calls and on the engine's events, never per audio buffer.
 */
object Player {
    enum class Repeat(val key: String) { OFF("off"), ALL("all"), ONE("one") }

    data class State(
        val queue: List<QueueEntry> = emptyList(),
        val index: Int = -1,
        val isPlaying: Boolean = false,
        val isLoading: Boolean = false,
        /** Seconds, the song's length as the decoder or the catalogue says. */
        val duration: Double = 0.0,
        /** "Opus · 160 kbps", "FLAC", "Download". */
        val format: String? = null,
        val error: String? = null,
        val shuffle: Boolean = false,
        val repeat: Repeat = Repeat.OFF,
        /** Where the queue came from ("Brani preferiti", an album…). */
        val source: String? = null,
        /** When the sleep timer stops the music (epoch milliseconds), or 0. */
        val sleepAt: Long = 0,
        /** The sleep timer waits for the song to end. */
        val sleepAtEnd: Boolean = false,
    ) {
        val current: Track? get() = queue.getOrNull(index)?.track
        val upcoming: List<QueueEntry> get() = if (index < 0) queue else queue.drop(index + 1)
        val history: List<QueueEntry> get() = if (index <= 0) emptyList() else queue.take(index)
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val _state = MutableStateFlow(State())
    val state: StateFlow<State> = _state

    private val _position = MutableStateFlow(0.0)
    /** Seconds into the song, four times a second while it plays (for the scrubber and lyrics). */
    val position: StateFlow<Double> = _position

    val engine = Engine { if (headless) NullSink() else JavaSoundSink(Prefs.outputDevice.value) }

    /** Tests and CI screenshots: no sound card. */
    @Volatile var headless = System.getProperty("seaglass.headless") == "true"

    private var loadJob: Job? = null
    private var prepareJob: Job? = null
    private var ticker: Job? = null
    private var sleepJob: Job? = null
    /** The queue entry the engine's next deck plays. */
    @Volatile private var preparedFor: Long = -1
    /** The order before shuffling, to go back to it. */
    private var unshuffled: List<QueueEntry>? = null

    fun init() {
        engine.volume = Prefs.volume.value.toFloat()
        _state.value = _state.value.copy(shuffle = Prefs.shuffle.value, repeat = Repeat.entries.firstOrNull { it.key == Prefs.repeat.value } ?: Repeat.OFF)
        engine.listener = object : Engine.Listener {
            override fun advanced(next: Deck) {
                scope.launch(Dispatchers.Main) { onAdvanced(next) }
            }
            override fun ended(deck: Deck) {
                scope.launch(Dispatchers.Main) { onEnded() }
            }
            override fun failed(deck: Deck, error: Exception) {
                scope.launch(Dispatchers.Main) { onFailed(error) }
            }
        }
        scope.launch {
            Prefs.transition.state.collect { applyCrossfade() }
        }
        scope.launch {
            Prefs.crossfadeSeconds.state.collect { applyCrossfade() }
        }
    }

    private fun applyCrossfade() {
        engine.crossfade = if (Prefs.transition.value == "crossfade") Prefs.crossfadeSeconds.value.coerceIn(1.0, 12.0) else 0.0
    }

    // MARK: Playing

    /** Plays [tracks] from [startAt]; with shuffle on, that song first and the rest shuffled. */
    fun play(tracks: List<Track>, startAt: Int = 0, source: String? = null, shuffled: Boolean? = null) {
        if (tracks.isEmpty()) return
        val shuffle = shuffled ?: _state.value.shuffle
        var entries = tracks.map { QueueEntry(it) }
        var index = startAt.coerceIn(0, entries.lastIndex)
        unshuffled = null
        if (shuffle) {
            unshuffled = entries
            val first = entries[index]
            entries = listOf(first) + (entries - first).shuffled()
            index = 0
        }
        if (shuffled != null) setShuffleFlag(shuffled)
        _state.value = _state.value.copy(queue = entries, index = index, source = source, error = null)
        load(entries[index])
    }

    fun toggle() {
        val current = _state.value
        when {
            current.current == null -> return
            current.isPlaying -> pause()
            engine.current == null -> current.queue.getOrNull(current.index)?.let { load(it) }
            else -> resume()
        }
    }

    fun pause() {
        engine.pause()
        _state.value = _state.value.copy(isPlaying = false)
        _position.value = engine.position
        stopTicker()
    }

    fun resume() {
        engine.resume()
        _state.value = _state.value.copy(isPlaying = true)
        startTicker()
    }

    fun seek(seconds: Double) {
        engine.seek(seconds)
        _position.value = seconds
    }

    /** Next: the following song now (cutting a crossfade short). */
    fun next() {
        val current = _state.value
        val target = current.index + 1
        when {
            target < current.queue.size -> jump(target)
            current.repeat == Repeat.ALL && current.queue.isNotEmpty() -> jump(0)
            else -> extendWithRadio(andPlay = true)
        }
    }

    /** Previous: back to the song's start after three seconds, otherwise the song before. */
    fun previous() {
        val current = _state.value
        if (engine.position > 3 || current.index <= 0) {
            seek(0.0)
            if (!current.isPlaying) resume()
        } else {
            jump(current.index - 1)
        }
    }

    /** Plays the queue's [index] now. */
    fun jump(index: Int) {
        val current = _state.value
        val entry = current.queue.getOrNull(index) ?: return
        _state.value = current.copy(index = index, error = null)
        load(entry)
    }

    // MARK: The queue

    /** "Riproduci dopo": after the songs added with it before, as on the iPhone. */
    fun playNext(track: Track) {
        val current = _state.value
        if (current.current == null) return play(listOf(track))
        var at = current.index + 1
        while (at < current.queue.size && current.queue[at].added) at++
        val queue = current.queue.toMutableList().apply { add(at, QueueEntry(track, added = true)) }
        _state.value = current.copy(queue = queue)
        prepareNext()
    }

    fun addToQueue(tracks: List<Track>) {
        val current = _state.value
        if (current.current == null) return play(tracks)
        _state.value = current.copy(queue = current.queue + tracks.map { QueueEntry(it) })
        prepareNext()
    }

    fun removeFromQueue(entryId: Long) {
        val current = _state.value
        val at = current.queue.indexOfFirst { it.id == entryId }
        if (at < 0 || at == current.index) return
        val queue = current.queue.filterNot { it.id == entryId }
        _state.value = current.copy(queue = queue, index = if (at < current.index) current.index - 1 else current.index)
        prepareNext()
    }

    /** Moves an upcoming song (positions in the whole queue). */
    fun move(from: Int, to: Int) {
        val current = _state.value
        if (from == current.index || to <= current.index || from !in current.queue.indices || to !in current.queue.indices) return
        val queue = current.queue.toMutableList()
        queue.add(to, queue.removeAt(from))
        _state.value = current.copy(queue = queue)
        prepareNext()
    }

    fun clearUpcoming() {
        val current = _state.value
        _state.value = current.copy(queue = current.queue.take(current.index + 1))
        prepareNext()
    }

    fun setShuffle(on: Boolean) {
        val current = _state.value
        setShuffleFlag(on)
        val playing = current.queue.getOrNull(current.index) ?: return
        if (on) {
            unshuffled = current.queue
            val rest = current.upcoming.shuffled()
            _state.value = _state.value.copy(queue = current.history + playing + rest)
        } else {
            val original = unshuffled ?: return
            val at = original.indexOfFirst { it.id == playing.id }
            if (at >= 0) _state.value = _state.value.copy(queue = original, index = at)
            unshuffled = null
        }
        prepareNext()
    }

    private fun setShuffleFlag(on: Boolean) {
        Prefs.shuffle.value = on
        _state.value = _state.value.copy(shuffle = on)
    }

    fun cycleRepeat() {
        val next = when (_state.value.repeat) {
            Repeat.OFF -> Repeat.ALL
            Repeat.ALL -> Repeat.ONE
            Repeat.ONE -> Repeat.OFF
        }
        Prefs.repeat.value = next.key
        _state.value = _state.value.copy(repeat = next)
        prepareNext()
    }

    fun setVolume(value: Double) {
        val clamped = value.coerceIn(0.0, 1.0)
        engine.volume = clamped.toFloat()
        Prefs.volume.value = clamped
    }

    // MARK: Sleep timer

    /** Stops the music in [minutes] (0: off; -1: at the end of the song). */
    fun setSleepTimer(minutes: Int) {
        sleepJob?.cancel()
        when {
            minutes == 0 -> _state.value = _state.value.copy(sleepAt = 0, sleepAtEnd = false)
            minutes < 0 -> _state.value = _state.value.copy(sleepAt = 0, sleepAtEnd = true)
            else -> {
                val at = System.currentTimeMillis() + minutes * 60_000L
                _state.value = _state.value.copy(sleepAt = at, sleepAtEnd = false)
                sleepJob = scope.launch(Dispatchers.Main) {
                    delay(minutes * 60_000L)
                    pause()
                    _state.value = _state.value.copy(sleepAt = 0)
                }
            }
        }
    }

    // MARK: Loading

    private fun load(entry: QueueEntry) {
        loadJob?.cancel()
        prepareJob?.cancel()
        preparedFor = -1
        val track = entry.track
        _state.value = _state.value.copy(isLoading = true, isPlaying = true, error = null, duration = track.duration ?: 0.0, format = null)
        _position.value = 0.0
        loadJob = scope.launch {
            try {
                val (deck, format) = withContext(Dispatchers.IO) { open(entry) }
                if (!isActive) {
                    deck.close()
                    return@launch
                }
                withContext(Dispatchers.Main) {
                    engine.play(deck)
                    _state.value = _state.value.copy(isLoading = false, duration = deck.duration.takeIf { it > 0 } ?: (track.duration ?: 0.0), format = format)
                    startTicker()
                    if (!track.isLocal) Library.recordPlay(track)
                    prepareNext()
                }
            } catch (e: Exception) {
                if (!isActive) return@launch
                withContext(Dispatchers.Main) { onFailed(e) }
            }
        }
    }

    /** The song's sound and how the player names its format. */
    private suspend fun open(entry: QueueEntry, startAt: Double = 0.0): Pair<Deck, String> {
        val track = entry.track
        val normalize = Prefs.normalizeVolume.value
        LocalMusic.file(track)?.let { file ->
            val decoder = Decoder(FileSource(file))
            return Deck(decoder, 1f, startAt, decoder.duration.takeIf { it > 0 } ?: (track.duration ?: 0.0), entry) to decoder.codecName
        }
        val local = Downloads.file(track.videoId) ?: SongCache.file(track.videoId)
        if (local != null) {
            val decoder = Decoder(FileSource(local))
            val gain = if (normalize) Streams.gain(Streams.loudness(track.videoId)) else 1f
            val label = if (Downloads.isComplete(track.videoId)) tr("Scaricato") + " · " + decoder.codecName else decoder.codecName
            return Deck(decoder, gain, startAt, duration(decoder, track), entry) to label
        }
        val resolved = Streams.resolve(track.videoId)
        val rendition = resolved.rendition
        val extension = if (rendition.isOpus) "webm" else "m4a"
        val source = if (rendition.size > 0) {
            StreamSource(rendition.url, rendition.size) { bytes -> SongCache.store(track.videoId, extension, bytes) }
        } else {
            throw java.io.IOException(tr("Nessuno stream audio riproducibile per questo brano."))
        }
        val decoder = try {
            Decoder(source)
        } catch (e: Exception) {
            source.close()
            // An expired or refused link: ask YouTube again next time.
            Streams.invalidate(track.videoId)
            throw e
        }
        val gain = if (normalize) Streams.gain(resolved.loudness) else 1f
        return Deck(decoder, gain, startAt, duration(decoder, track), entry) to rendition.label
    }

    private fun duration(decoder: Decoder, track: Track) = decoder.duration.takeIf { it > 0 } ?: (track.duration ?: 0.0)

    /** The entry that plays after the current one, if any (repeat and shuffle included). */
    private fun following(): QueueEntry? {
        val current = _state.value
        return when {
            current.repeat == Repeat.ONE -> current.queue.getOrNull(current.index)?.let { it.copy(id = nextEntryId.incrementAndGet()) }
                ?.also { repeatOneEntry = it }
            current.index + 1 < current.queue.size -> current.queue[current.index + 1]
            current.repeat == Repeat.ALL -> current.queue.firstOrNull()
            else -> null
        }
    }

    /** "Ripeti brano" plays the same song again as a fresh deck: this is its stand-in entry. */
    private var repeatOneEntry: QueueEntry? = null

    /** Opens the next song ahead of time, so it follows without a gap (or fades in). */
    private fun prepareNext() {
        prepareJob?.cancel()
        val current = _state.value
        if (current.current == null) return
        // Fewer than three songs left: the radio of the last one is added, as on the Mac.
        if (current.repeat == Repeat.OFF && current.queue.size - current.index <= 3) extendWithRadio(andPlay = false)
        val entry = following()
        if (entry == null || _state.value.sleepAtEnd) {
            preparedFor = -1
            engine.queue(null)
            return
        }
        if (entry.id == preparedFor && engine.next != null) return
        prepareJob = scope.launch {
            // Opened in the last half minute of the song, not the moment it starts.
            while (isActive) {
                val left = _state.value.duration - engine.position
                if (_state.value.duration > 0 && left <= 30) break
                delay(1_000)
            }
            val opened = runCatching { withContext(Dispatchers.IO) { open(entry) } }.getOrNull() ?: return@launch
            if (!isActive) {
                opened.first.close()
                return@launch
            }
            withContext(Dispatchers.Main) {
                preparedFor = entry.id
                preparedFormat = opened.second
                engine.queue(opened.first)
            }
        }
    }

    @Volatile private var preparedFormat: String? = null

    private var radioJob: Job? = null

    private fun extendWithRadio(andPlay: Boolean) {
        if (radioJob?.isActive == true) return
        val seed = _state.value.queue.lastOrNull()?.track ?: return
        if (seed.isLocal) return
        radioJob = scope.launch {
            val radio = runCatching { InnerTube.radio(seed.videoId) }.getOrDefault(emptyList())
            withContext(Dispatchers.Main) {
                val current = _state.value
                val known = current.queue.map { it.track.videoId }.toSet()
                val fresh = radio.filter { it.videoId !in known }.take(25)
                if (fresh.isEmpty()) return@withContext
                _state.value = current.copy(queue = current.queue + fresh.map { QueueEntry(it) })
                if (andPlay) jump(current.queue.size) else prepareNext()
            }
        }
    }

    // MARK: The engine's events

    private fun onAdvanced(next: Deck) {
        val current = _state.value
        val entry = next.tag as? QueueEntry
        val index = when {
            entry == null -> current.index + 1
            entry.id == repeatOneEntry?.id -> current.index
            else -> current.queue.indexOfFirst { it.id == entry.id }.takeIf { it >= 0 } ?: (current.index + 1)
        }
        _state.value = current.copy(
            index = index.coerceAtMost(current.queue.lastIndex),
            duration = next.duration,
            format = preparedFormat,
            isLoading = false,
        )
        preparedFor = -1
        _state.value.current?.let { if (!it.isLocal) Library.recordPlay(it) }
        if (_state.value.sleepAtEnd) {
            pause()
            _state.value = _state.value.copy(sleepAtEnd = false)
        }
        prepareNext()
    }

    private fun onEnded() {
        stopTicker()
        _state.value = _state.value.copy(isPlaying = false)
        _position.value = _state.value.duration
        if (_state.value.sleepAtEnd) {
            _state.value = _state.value.copy(sleepAtEnd = false)
            return
        }
        // The radio didn't come in time: try it now.
        if (_state.value.index + 1 >= _state.value.queue.size) extendWithRadio(andPlay = true)
    }

    private fun onFailed(error: Exception) {
        val message = error.message?.takeIf { error !is java.io.IOException || "HTTP" !in it } ?: tr("Impossibile riprodurre il brano.")
        _state.value = _state.value.copy(isLoading = false, isPlaying = false, error = message)
        stopTicker()
        // As on the iPhone, a song that can't play is skipped after a moment.
        scope.launch(Dispatchers.Main) {
            val failedIndex = _state.value.index
            delay(2_500)
            val current = _state.value
            if (current.index == failedIndex && current.error != null && failedIndex + 1 < current.queue.size) jump(failedIndex + 1)
        }
    }

    private fun startTicker() {
        if (ticker?.isActive == true) return
        ticker = scope.launch {
            while (isActive) {
                _position.value = engine.position
                if (engine.outputFailure != null && _state.value.error == null) {
                    _state.value = _state.value.copy(error = tr("Nessuna uscita audio disponibile."))
                }
                delay(250)
            }
        }
    }

    private fun stopTicker() {
        ticker?.cancel()
        ticker = null
    }

    fun shutdown() {
        engine.close()
    }
}

/** Songs of the user's own have a "local:" ID; YouTube's are 11 characters. */
val Track.isLocal: Boolean get() = videoId.startsWith("local:")
