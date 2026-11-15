package com.onda.seaglass.playback

import com.onda.seaglass.data.InnerTube
import com.onda.seaglass.data.Library
import com.onda.seaglass.data.NoStreamException
import com.onda.seaglass.data.Streams
import com.onda.seaglass.model.Track
import javafx.application.Platform
import javafx.scene.media.Media
import javafx.scene.media.MediaPlayer
import javafx.util.Duration
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Queue + playback for Windows. Resolves YouTube audio like Android (`Streams`), plays AAC via
 * JavaFX Media (toolkit started once, no JavaFX window).
 */
object PlayerController {
    data class State(
        val track: Track? = null,
        val queue: List<Track> = emptyList(),
        val index: Int = 0,
        val playing: Boolean = false,
        val positionSec: Double = 0.0,
        val durationSec: Double = 0.0,
        val format: String? = null,
        val error: String? = null,
        val loading: Boolean = false,
        val volume: Double = 1.0,
        val shuffle: Boolean = false,
        val repeatQueue: Boolean = false,
    )

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val _state = MutableStateFlow(State())
    val state: StateFlow<State> = _state.asStateFlow()

    private var player: MediaPlayer? = null
    private var loadJob: Job? = null
    private val fxReady = AtomicBoolean(false)

    init {
        ensureFx()
    }

    fun play(tracks: List<Track>, startAt: Int = 0) {
        if (tracks.isEmpty()) return
        val index = startAt.coerceIn(0, tracks.lastIndex)
        _state.value = _state.value.copy(queue = tracks, index = index, error = null)
        loadAndPlay(tracks[index])
    }

    fun playRadio(seed: Track) {
        scope.launch {
            _state.value = _state.value.copy(loading = true, error = null)
            val radio = withContext(Dispatchers.IO) {
                runCatching { InnerTube.radio(seed.videoId) }.getOrDefault(listOf(seed))
            }.ifEmpty { listOf(seed) }
            play(radio, 0)
        }
    }

    fun toggle() {
        val p = player ?: return
        runOnFx {
            if (p.status == MediaPlayer.Status.PLAYING) {
                p.pause()
                _state.value = _state.value.copy(playing = false)
            } else {
                p.play()
                _state.value = _state.value.copy(playing = true)
            }
        }
    }

    fun next() {
        val s = _state.value
        if (s.queue.isEmpty()) return
        val i = when {
            s.shuffle -> s.queue.indices.random()
            s.index + 1 < s.queue.size -> s.index + 1
            s.repeatQueue -> 0
            else -> return
        }
        _state.value = s.copy(index = i)
        loadAndPlay(s.queue[i])
    }

    fun setVolume(value: Double) {
        val v = value.coerceIn(0.0, 1.0)
        _state.value = _state.value.copy(volume = v)
        runOnFx { player?.volume = v }
    }

    fun toggleShuffle() {
        _state.value = _state.value.copy(shuffle = !_state.value.shuffle)
    }

    fun toggleRepeat() {
        _state.value = _state.value.copy(repeatQueue = !_state.value.repeatQueue)
    }

    fun previous() {
        val s = _state.value
        if (s.positionSec > 3) {
            seek(0.0)
            return
        }
        if (s.index > 0) {
            val i = s.index - 1
            _state.value = s.copy(index = i)
            loadAndPlay(s.queue[i])
        }
    }

    fun seek(seconds: Double) {
        runOnFx { player?.seek(Duration.seconds(seconds)) }
        _state.value = _state.value.copy(positionSec = seconds)
    }

    fun stop() {
        loadJob?.cancel()
        runOnFx {
            player?.stop()
            player?.dispose()
            player = null
        }
        _state.value = _state.value.copy(playing = false, track = null, positionSec = 0.0)
    }

    private fun loadAndPlay(track: Track) {
        loadJob?.cancel()
        loadJob = scope.launch {
            _state.value = _state.value.copy(track = track, loading = true, error = null, playing = false, positionSec = 0.0)
            try {
                val resolved = withContext(Dispatchers.IO) { Streams.resolve(track.videoId) }
                startMedia(track, resolved.rendition.url, resolved.rendition.label)
            } catch (e: NoStreamException) {
                _state.value = _state.value.copy(loading = false, error = e.message ?: e.toString())
            } catch (e: Exception) {
                _state.value = _state.value.copy(loading = false, error = e.message ?: e.toString())
            }
        }
    }

    private fun startMedia(track: Track, url: String, format: String) {
        ensureFx()
        runOnFx {
            player?.stop()
            player?.dispose()
            val media = Media(url)
            val mp = MediaPlayer(media)
            player = mp
            mp.volume = _state.value.volume
            mp.setOnReady {
                val dur = mp.totalDuration?.toSeconds()?.takeIf { !it.isNaN() } ?: track.duration ?: 0.0
                Library.recordPlay(track)
                _state.value = _state.value.copy(
                    loading = false,
                    playing = true,
                    durationSec = dur,
                    format = format,
                )
                mp.play()
            }
            mp.setOnError {
                _state.value = _state.value.copy(
                    loading = false,
                    playing = false,
                    error = mp.error?.message ?: "Errore di riproduzione",
                )
            }
            mp.currentTimeProperty().addListener { _, _, now ->
                _state.value = _state.value.copy(positionSec = now.toSeconds())
            }
            mp.setOnEndOfMedia { next() }
        }
    }

    private fun ensureFx() {
        if (fxReady.get()) return
        synchronized(fxReady) {
            if (fxReady.get()) return
            val latch = CountDownLatch(1)
            try {
                Platform.startup {
                    fxReady.set(true)
                    latch.countDown()
                }
            } catch (_: IllegalStateException) {
                fxReady.set(true)
                latch.countDown()
            }
            latch.await(5, TimeUnit.SECONDS)
        }
    }

    private fun runOnFx(block: () -> Unit) {
        if (Platform.isFxApplicationThread()) block()
        else Platform.runLater(block)
    }
}
