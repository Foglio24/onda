package com.onda.seaglass.playback

import android.app.PendingIntent
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.annotation.OptIn
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.HttpDataSource
import androidx.media3.datasource.ResolvingDataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.session.DefaultMediaNotificationProvider
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import com.onda.seaglass.MainActivity
import com.onda.seaglass.R
import com.onda.seaglass.core.Http
import com.onda.seaglass.data.InnerTube
import com.onda.seaglass.data.Library
import com.onda.seaglass.data.Prefs
import com.onda.seaglass.data.Recommendations
import com.onda.seaglass.data.Streams
import com.onda.seaglass.model.Track
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject

private const val TRACK_KEY = "seaglass.track"

/** A song as the player knows it: its ID, the details for the notification, and the whole [Track]. */
fun Track.toMediaItem(): MediaItem = MediaItem.Builder()
    .setMediaId(videoId)
    .setUri(streamUri(videoId))
    .setMediaMetadata(
        MediaMetadata.Builder()
            .setTitle(title)
            .setArtist(artist)
            .setAlbumTitle(album)
            .setArtworkUri(largeArtwork?.let(Uri::parse))
            .setIsPlayable(true)
            .setIsBrowsable(false)
            .setMediaType(MediaMetadata.MEDIA_TYPE_MUSIC)
            .setExtras(Bundle().apply { putString(TRACK_KEY, toJson().toString()) })
            .build(),
    )
    .build()

fun MediaItem.toTrack(): Track? =
    mediaMetadata.extras?.getString(TRACK_KEY)?.let { runCatching { Track.fromJson(JSONObject(it)) }.getOrNull() }

/** What the player tells the screens that isn't part of the player's own state. */
object PlaybackEvents {
    val error = MutableStateFlow<String?>(null)
    val radioLoading = MutableStateFlow(false)
}

/**
 * Plays in the background with a media notification and lock-screen controls (Media3). When the
 * queue is about to run out, "Radio automatica" adds similar songs, as on the iPhone.
 */
@OptIn(UnstableApi::class)
class PlaybackService : MediaSessionService() {
    private var session: MediaSession? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var extending = false
    private var retried: String? = null
    /** Songs that failed in a row: after a few, playback stops instead of running through the queue. */
    private var failures = 0
    private var transitions: Transitions? = null
    /** The main player's AutoMix filters (the next song's bass while the two play together). */
    private val mainFilter = com.onda.seaglass.playback.automix.MixFilter()
    private var detachBitPerfect: () -> Unit = {}

    override fun onCreate() {
        super.onCreate()
        val resolving = audioDataSourceFactory()
        val player = ExoPlayer.Builder(this, FilteredRenderers(this, mainFilter))
            .setMediaSourceFactory(DefaultMediaSourceFactory(resolving))
            .setAudioAttributes(
                AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MUSIC).build(),
                true,
            )
            .setHandleAudioBecomingNoisy(true)
            .setWakeMode(C.WAKE_MODE_NETWORK)
            .build()
        player.addListener(listener)
        transitions = Transitions(this, player, mainFilter, scope, gainOf = ::gainOf, allowed = { !BitPerfect.active }).also { it.start() }
        detachBitPerfect = BitPerfect.attach(this, player)
        // A song's loudness arrives with its link, on a loading thread.
        Streams.onLoudness = { videoId -> scope.launch { if (player.currentMediaItem?.mediaId == videoId) applyVolume() } }
        scope.launch {
            Prefs.normalizeVolume.flow.collect { applyVolume() }
        }
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).putExtra(MainActivity.OPEN_PLAYER, true)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        session = MediaSession.Builder(this, player)
            .setSessionActivity(open)
            .setCallback(callback)
            .build()
        setMediaNotificationProvider(
            DefaultMediaNotificationProvider.Builder(this).build().apply { setSmallIcon(R.drawable.ic_notification) },
        )
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = session

    /**
     * The app swiped away from the recent apps: the music stops with it, as on the iPhone (where
     * closing the app from the switcher stops playback). Where it was stays for "Riprendi".
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        saveResumeState()
        pauseAllPlayersAndStopSelf()
    }

    override fun onDestroy() {
        saveResumeState()
        Streams.onLoudness = null
        transitions?.release()
        detachBitPerfect()
        scope.cancel()
        session?.run {
            player.release()
            release()
        }
        session = null
        super.onDestroy()
    }

    /** Items from controllers arrive without their link: it is rebuilt from the song's ID. */
    private val callback = object : MediaSession.Callback {
        override fun onAddMediaItems(
            mediaSession: MediaSession,
            controller: MediaSession.ControllerInfo,
            mediaItems: MutableList<MediaItem>,
        ): ListenableFuture<MutableList<MediaItem>> = Futures.immediateFuture(
            mediaItems.map { it.buildUpon().setUri(streamUri(it.mediaId)).build() }.toMutableList(),
        )
    }

    private val listener = object : Player.Listener {
        override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
            PlaybackEvents.error.value = null
            retried = null
            if (reason != Player.MEDIA_ITEM_TRANSITION_REASON_REPEAT) mediaItem?.toTrack()?.let(Library::recordPlay)
            applyVolume()
            extendIfNeeded()
            saveResumeState()
        }

        override fun onPlaybackStateChanged(playbackState: Int) {
            if (playbackState == Player.STATE_ENDED) extendIfNeeded(resume = true)
        }

        override fun onIsPlayingChanged(isPlaying: Boolean) {
            if (isPlaying) failures = 0 else saveResumeState()
        }

        override fun onPlayerError(error: PlaybackException) {
            val player = session?.player ?: return
            val videoId = player.currentMediaItem?.mediaId
            val status = (error.cause as? HttpDataSource.InvalidResponseCodeException)?.responseCode
            // Links expire after a few hours: look the song up again once.
            if (videoId != null && retried != videoId && (status == 403 || status == 410 || status == 404)) {
                retried = videoId
                Streams.invalidate(videoId)
                player.prepare()
                return
            }
            PlaybackEvents.error.value = error.cause?.message ?: error.message
            failures += 1
            if (failures < 3 && player.hasNextMediaItem()) {
                player.seekToNextMediaItem()
                player.prepare()
            }
        }
    }

    /** "Volume uniforme": every song at YouTube's reference loudness (the crossfade sets its own volumes). */
    private fun gainOf(videoId: String): Float =
        if (Prefs.normalizeVolume.value && !BitPerfect.active) Streams.gain(Streams.loudness(videoId)) else 1f

    private fun applyVolume() {
        val player = session?.player ?: return
        if (transitions?.fading == true) return
        player.volume = player.currentMediaItem?.mediaId?.let(::gainOf) ?: 1f
    }

    /** Similar songs after the last one, when "Radio automatica" is on and the queue is about to end. */
    private fun extendIfNeeded(resume: Boolean = false) {
        val player = session?.player ?: return
        if (extending || !Prefs.autoRadio.value || player.repeatMode != Player.REPEAT_MODE_OFF) return
        val remaining = if (player.shuffleModeEnabled) {
            if (player.hasNextMediaItem()) 2 else 0
        } else {
            player.mediaItemCount - 1 - player.currentMediaItemIndex
        }
        if (remaining >= 2) return
        val seed = player.currentMediaItem?.mediaId ?: return
        extending = true
        PlaybackEvents.radioLoading.value = true
        scope.launch {
            val radio = runCatching { InnerTube.radio(seed) }.getOrDefault(emptyList())
            val present = (0 until player.mediaItemCount).map { player.getMediaItemAt(it).mediaId }.toSet()
            val history = Library.history.value.take(20).map { it.videoId }.toSet()
            val fresh = Recommendations.withoutLongMixes(radio).filter { it.videoId !in present && it.videoId !in history }
                .ifEmpty { radio.filter { it.videoId !in present } }
                .take(25)
            if (fresh.isNotEmpty()) {
                player.addMediaItems(fresh.map { it.toMediaItem() })
                if (resume && player.playbackState == Player.STATE_ENDED) {
                    player.seekToNextMediaItem()
                    player.prepare()
                    player.play()
                }
            }
            extending = false
            PlaybackEvents.radioLoading.value = false
        }
    }

    /** The queue and where it stood, for "Riprendi da dove eri". */
    private fun saveResumeState() {
        val player = session?.player ?: return
        if (player.mediaItemCount == 0) return
        val index = player.currentMediaItemIndex
        val start = maxOf(0, index - 20)
        val tracks = (start until minOf(player.mediaItemCount, index + 80)).mapNotNull { player.getMediaItemAt(it).toTrack() }
        Prefs.resumeState = JSONObject()
            .put("tracks", JSONArray().apply { tracks.forEach { put(it.toJson()) } })
            .put("index", index - start)
            .put("position", player.currentPosition)
            .toString()
    }
}
