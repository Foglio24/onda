package com.onda.seaglass.playback

import android.content.ComponentName
import android.content.Context
import androidx.compose.ui.graphics.Color
import androidx.core.content.ContextCompat
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import androidx.palette.graphics.Palette
import coil3.SingletonImageLoader
import coil3.request.ImageRequest
import coil3.request.allowHardware
import coil3.toBitmap
import com.google.common.util.concurrent.ListenableFuture
import com.onda.seaglass.data.InnerTube
import com.onda.seaglass.data.Library
import com.onda.seaglass.data.Prefs
import com.onda.seaglass.data.Recommendations
import com.onda.seaglass.model.Track
import com.onda.seaglass.model.uniqued
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import org.json.JSONObject

/** The player as the screens see it: the queue, what plays, and every action on it. */
object PlayerController {
    data class State(
        val queue: List<Track> = emptyList(),
        val index: Int = -1,
        val isPlaying: Boolean = false,
        val isBuffering: Boolean = false,
        val durationMs: Long = 0,
        val shuffle: Boolean = false,
        val repeatMode: Int = Player.REPEAT_MODE_OFF,
    ) {
        val current: Track? get() = queue.getOrNull(index)
        val upNext: List<Track> get() = if (index < 0) emptyList() else queue.drop(index + 1)
    }

    private val _state = MutableStateFlow(State())
    val state: StateFlow<State> = _state

    /** The main colour of the playing song's artwork, for the backgrounds. */
    private val _artworkColor = MutableStateFlow<Color?>(null)
    val artworkColor: StateFlow<Color?> = _artworkColor

    /** Minutes left on the sleep timer (-1: end of the song), or null when it is off. */
    private val _sleepTimer = MutableStateFlow<Int?>(null)
    val sleepTimer: StateFlow<Int?> = _sleepTimer

    private lateinit var appContext: Context
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var future: ListenableFuture<MediaController>? = null
    private var controller: MediaController? = null
    private val pending = mutableListOf<(MediaController) -> Unit>()
    private var colorFor: String? = null
    private var timerJob: Job? = null
    private var stopAtEnd = false

    fun init(context: Context) {
        appContext = context.applicationContext
    }

    /** Connects to [PlaybackService], starting it if needed; actions wait for the connection. */
    private fun withController(action: (MediaController) -> Unit) {
        controller?.takeIf { it.isConnected }?.let { action(it); return }
        pending += action
        if (future != null) return
        val token = SessionToken(appContext, ComponentName(appContext, PlaybackService::class.java))
        val building = MediaController.Builder(appContext, token)
            .setListener(object : MediaController.Listener {
                override fun onDisconnected(controller: MediaController) {
                    this@PlayerController.controller = null
                    future = null
                }
            })
            .buildAsync()
        future = building
        building.addListener({
            val connected = runCatching { building.get() }.getOrNull()
            if (connected == null) {
                future = null
                pending.clear()
                return@addListener
            }
            controller = connected
            connected.addListener(listener)
            sync()
            val actions = pending.toList()
            pending.clear()
            actions.forEach { it(connected) }
        }, ContextCompat.getMainExecutor(appContext))
    }

    /** Called when the app opens: shows a song still playing in the background. */
    fun connect() = withController { }

    private val listener = object : Player.Listener {
        override fun onEvents(player: Player, events: Player.Events) {
            sync()
            if (stopAtEnd && events.contains(Player.EVENT_MEDIA_ITEM_TRANSITION)) {
                stopAtEnd = false
                _sleepTimer.value = null
                player.pause()
            }
        }
    }

    private fun sync() {
        val player = controller ?: return
        val queue = (0 until player.mediaItemCount).mapNotNull { player.getMediaItemAt(it).toTrack() }
        val index = if (queue.isEmpty()) -1 else player.currentMediaItemIndex
        _state.value = State(
            queue = queue,
            index = index,
            isPlaying = player.isPlaying || (player.playWhenReady && player.playbackState == Player.STATE_BUFFERING),
            isBuffering = player.playbackState == Player.STATE_BUFFERING,
            durationMs = player.duration.takeIf { it > 0 } ?: queue.getOrNull(index)?.duration?.times(1000)?.toLong() ?: 0,
            shuffle = player.shuffleModeEnabled,
            repeatMode = player.repeatMode,
        )
        updateArtworkColor(queue.getOrNull(index))
    }

    val positionMs: Long get() = controller?.currentPosition ?: 0
    val bufferedMs: Long get() = controller?.bufferedPosition ?: 0

    // MARK: Playing

    /** Plays [tracks] from [start]. */
    fun play(tracks: List<Track>, start: Int = 0, shuffle: Boolean = false) {
        if (tracks.isEmpty()) return
        val items = tracks.map { it.toMediaItem() }
        withController { player ->
            player.shuffleModeEnabled = shuffle
            val first = if (shuffle) tracks.indices.random() else start.coerceIn(tracks.indices)
            player.setMediaItems(items, first, 0)
            player.prepare()
            player.play()
        }
    }

    /** A song and then a radio of similar ones (what a tap on a search result does). */
    fun playRadio(track: Track) {
        play(listOf(track))
        PlaybackEvents.radioLoading.value = true
        scope.launch {
            val radio = runCatching { InnerTube.radio(track.videoId) }.getOrDefault(emptyList())
            val similar = Recommendations.withoutLongMixes(radio).filter { it.videoId != track.videoId }.uniqued()
            withController { player ->
                // Only if the song is still the one the radio is for.
                if (player.mediaItemCount >= 1 && player.getMediaItemAt(0).mediaId == track.videoId) {
                    val present = (0 until player.mediaItemCount).map { player.getMediaItemAt(it).mediaId }.toSet()
                    player.addMediaItems(similar.filter { it.videoId !in present }.map { it.toMediaItem() })
                }
            }
            PlaybackEvents.radioLoading.value = false
        }
    }

    fun playNext(track: Track) = withController { player ->
        if (player.mediaItemCount == 0) {
            play(listOf(track))
        } else {
            player.addMediaItem(player.currentMediaItemIndex + 1, track.toMediaItem())
        }
    }

    fun addToQueue(track: Track) = withController { player ->
        if (player.mediaItemCount == 0) play(listOf(track)) else player.addMediaItem(track.toMediaItem())
    }

    fun toggle() = withController { player ->
        if (player.isPlaying) {
            player.pause()
        } else {
            if (player.playbackState == Player.STATE_IDLE) player.prepare()
            if (player.playbackState == Player.STATE_ENDED) player.seekToDefaultPosition(0)
            player.play()
        }
    }

    fun next() = withController { it.seekToNextMediaItem() }

    /** Back to the start of the song, or to the previous one in its first seconds. */
    fun previous() = withController { it.seekToPrevious() }

    fun seek(positionMs: Long) = withController { it.seekTo(positionMs) }

    fun skipTo(index: Int) = withController { player ->
        if (index in 0 until player.mediaItemCount) {
            player.seekToDefaultPosition(index)
            player.play()
        }
    }

    fun removeFromQueue(index: Int) = withController { player ->
        if (index in 0 until player.mediaItemCount && index != player.currentMediaItemIndex) player.removeMediaItem(index)
    }

    fun moveInQueue(from: Int, to: Int) = withController { player ->
        if (from in 0 until player.mediaItemCount && to in 0 until player.mediaItemCount) player.moveMediaItem(from, to)
    }

    fun clearUpNext() = withController { player ->
        val count = player.mediaItemCount
        if (player.currentMediaItemIndex + 1 < count) player.removeMediaItems(player.currentMediaItemIndex + 1, count)
    }

    fun toggleShuffle() = withController { it.shuffleModeEnabled = !it.shuffleModeEnabled }

    fun cycleRepeat() = withController { player ->
        player.repeatMode = when (player.repeatMode) {
            Player.REPEAT_MODE_OFF -> Player.REPEAT_MODE_ALL
            Player.REPEAT_MODE_ALL -> Player.REPEAT_MODE_ONE
            else -> Player.REPEAT_MODE_OFF
        }
    }

    // MARK: Resume

    data class ResumePoint(val tracks: List<Track>, val index: Int, val positionMs: Long) {
        val track: Track? get() = tracks.getOrNull(index)
    }

    /** Where playback stood when the app was last closed, when nothing plays now. */
    fun resumePoint(): ResumePoint? {
        val json = Prefs.resumeState?.let { runCatching { JSONObject(it) }.getOrNull() } ?: return null
        val tracks = Track.listFromJson(json.optJSONArray("tracks"))
        val index = json.optInt("index")
        if (index !in tracks.indices) return null
        return ResumePoint(tracks, index, json.optLong("position"))
    }

    fun resume(point: ResumePoint) {
        val items: List<MediaItem> = point.tracks.map { it.toMediaItem() }
        withController { player ->
            player.setMediaItems(items, point.index, point.positionMs)
            player.prepare()
            player.play()
        }
    }

    // MARK: Sleep timer

    /** Pauses after [minutes]; -1 pauses at the end of the song; null turns the timer off. */
    fun setSleepTimer(minutes: Int?) {
        timerJob?.cancel()
        stopAtEnd = minutes == -1
        _sleepTimer.value = minutes
        if (minutes == null || minutes < 0) return
        timerJob = scope.launch {
            var left = minutes
            while (left > 0) {
                delay(60_000)
                left -= 1
                _sleepTimer.value = left
            }
            _sleepTimer.value = null
            withController { it.pause() }
        }
    }

    // MARK: Artwork colour

    private fun updateArtworkColor(track: Track?) {
        val url = track?.mediumArtwork
        if (url == colorFor) return
        colorFor = url
        if (url == null) {
            _artworkColor.value = null
            return
        }
        scope.launch {
            val request = ImageRequest.Builder(appContext).data(url).allowHardware(false).size(96).build()
            val image = SingletonImageLoader.get(appContext).execute(request).image ?: return@launch
            val palette = kotlinx.coroutines.withContext(Dispatchers.Default) { Palette.from(image.toBitmap()).generate() }
            val swatch = palette.vibrantSwatch ?: palette.lightVibrantSwatch ?: palette.dominantSwatch ?: palette.mutedSwatch
            if (colorFor == url) _artworkColor.value = swatch?.rgb?.let { Color(it) }
        }
    }

    fun isLiked(track: Track) = Library.isLiked(track)
}
