package com.onda.seaglass.playback

import android.content.Context
import android.os.SystemClock
import androidx.annotation.OptIn
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import com.onda.seaglass.data.Prefs
import com.onda.seaglass.data.SongTransition
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin

/**
 * "Dissolvenza incrociata": the last seconds of a song overlap the start of the next one.
 *
 * The queue stays in the main player (the one the notification and the screens control). A second,
 * hidden player loads the same song a few seconds before the fade and plays it muted, kept in step
 * with the main one (it speeds up or slows down slightly, unheard, until they match). At the fade it
 * takes over the end of the song while the main player moves on to the next one, which ExoPlayer
 * has already buffered: one fades out as the other fades in, with equal-power curves.
 *
 * Songs of the same album follow each other without a fade, as on the iPhone ("Come nell'album").
 */
@OptIn(UnstableApi::class)
class Crossfader(
    private val context: Context,
    private val main: ExoPlayer,
    private val scope: CoroutineScope,
    /** The volume a song plays at ("Volume uniforme"), by video ID. */
    private val gainOf: (String) -> Float,
    /** False while bit-perfect output is on: it can't change the volume. */
    private val allowed: () -> Boolean,
) {
    private var fader: ExoPlayer? = null
    private var loop: Job? = null
    /** "index:videoId" of the song the hidden player is ready for. */
    private var preparedFor: String? = null
    private var syncing = false
    /** A song whose fade couldn't be prepared in time: it ends without one. */
    private var gaveUp: String? = null

    /** True during a fade: the volumes are the fade's. */
    var fading = false
        private set
    private var switching = false

    fun start() {
        main.addListener(listener)
        loop = scope.launch {
            while (isActive) {
                runCatching { tick() }
                delay(if (syncing) 60 else 120)
            }
        }
    }

    fun release() {
        loop?.cancel()
        main.removeListener(listener)
        fader?.release()
        fader = null
    }

    private fun enabled() = Prefs.transition.value == SongTransition.CROSSFADE && allowed()

    private val listener = object : Player.Listener {
        override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
            if (!playWhenReady) stop()
        }

        override fun onPositionDiscontinuity(oldPosition: Player.PositionInfo, newPosition: Player.PositionInfo, reason: Int) {
            // A seek or a skip by the user (not the fade's own move to the next song) ends any fade.
            if (!switching && reason == Player.DISCONTINUITY_REASON_SEEK) stop()
        }

        override fun onRepeatModeChanged(repeatMode: Int) = stop()
    }

    private fun createFader(): ExoPlayer = fader ?: ExoPlayer.Builder(context)
        .setMediaSourceFactory(DefaultMediaSourceFactory(audioDataSourceFactory()))
        // No audio focus of its own: it would pause the main player.
        .setAudioAttributes(AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MUSIC).build(), false)
        .setWakeMode(C.WAKE_MODE_NETWORK)
        .build()
        .also { fader = it }

    private suspend fun tick() {
        if (fading) return
        val current = main.currentMediaItem
        val key = current?.let { "${main.currentMediaItemIndex}:${it.mediaId}" }
        if (preparedFor != null && preparedFor != key) stop()
        if (!enabled() || current == null || !main.isPlaying || key == gaveUp) return
        if (main.repeatMode == Player.REPEAT_MODE_ONE || !main.hasNextMediaItem()) return
        val duration = main.duration
        val fadeMs = (Prefs.crossfadeSeconds.value * 1000).toLong()
        if (duration == C.TIME_UNSET || duration < fadeMs * 2 + 15_000) return
        val nextIndex = main.nextMediaItemIndex
        if (sameAlbum(current, main.getMediaItemAt(nextIndex))) return

        val position = main.currentPosition
        val fadeStart = duration - fadeMs
        when {
            position < fadeStart - 12_000 -> return
            preparedFor != key -> {
                // The hidden player loads the song, paused near where it will be heard.
                val player = createFader()
                player.volume = 0f
                player.setMediaItem(current, fadeStart - 3_000)
                player.prepare()
                preparedFor = key
            }
            position >= fadeStart -> fade(fadeMs, nextIndex, current.mediaId)
            position >= fadeStart - 3_000 -> keepInStep()
        }
    }

    /** Plays the hidden copy muted, nudging its speed until it runs with the main player. */
    private fun keepInStep() {
        val player = fader ?: return
        if (!player.isPlaying) {
            if (player.playbackState != Player.STATE_READY) return
            player.seekTo(main.currentPosition + 120)
            player.play()
            syncing = true
            return
        }
        val drift = player.currentPosition - main.currentPosition
        val speed = when {
            abs(drift) <= 12 -> 1f
            else -> (1f - drift / 1000f).coerceIn(0.85f, 1.15f)
        }
        if (abs(player.playbackParameters.speed - speed) > 0.001f) player.setPlaybackSpeed(speed)
    }

    private suspend fun fade(fadeMs: Long, nextIndex: Int, outgoingId: String) {
        val player = fader
        if (player == null || !player.isPlaying) {
            // Not ready in time (a slow connection): no fade for this song.
            stop()
            gaveUp = main.currentMediaItem?.let { "${main.currentMediaItemIndex}:${it.mediaId}" }
            return
        }
        fading = true
        syncing = false
        val outGain = gainOf(outgoingId)
        player.setPlaybackSpeed(1f)
        player.volume = outGain
        main.volume = 0f
        switching = true
        main.seekToDefaultPosition(nextIndex)
        switching = false
        val incomingId = main.currentMediaItem?.mediaId.orEmpty()
        val started = SystemClock.elapsedRealtime()
        while (fading) {
            val t = ((SystemClock.elapsedRealtime() - started).toFloat() / fadeMs).coerceIn(0f, 1f)
            player.volume = outGain * cos(t * PI.toFloat() / 2)
            main.volume = gainOf(incomingId) * sin(t * PI.toFloat() / 2)
            if (t >= 1f) break
            delay(30)
        }
        stop()
    }

    /** Ends any fade or preparation: the hidden player stops and the main one plays at its volume. */
    fun stop() {
        syncing = false
        preparedFor = null
        fader?.let {
            it.stop()
            it.clearMediaItems()
            it.setPlaybackSpeed(1f)
        }
        if (fading) {
            fading = false
            main.volume = main.currentMediaItem?.mediaId?.let(gainOf) ?: 1f
        }
    }

    private fun sameAlbum(a: MediaItem, b: MediaItem): Boolean {
        val first = a.toTrack()?.albumId ?: return false
        return first == b.toTrack()?.albumId
    }
}
