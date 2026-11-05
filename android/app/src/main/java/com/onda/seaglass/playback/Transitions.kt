package com.onda.seaglass.playback

import android.content.Context
import android.os.SystemClock
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.DefaultAudioSink
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import com.onda.seaglass.core.tr
import com.onda.seaglass.data.Prefs
import com.onda.seaglass.data.SongTransition
import com.onda.seaglass.playback.automix.AutoMixLibrary
import com.onda.seaglass.playback.automix.MixFilter
import com.onda.seaglass.playback.automix.Planner
import com.onda.seaglass.playback.automix.TransitionPlan
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlin.math.abs

/** A player whose audio passes through the equalizer and [filter] (AutoMix's bass and high-pass filters). */
@OptIn(UnstableApi::class)
class FilteredRenderers(context: Context, private val filter: MixFilter) : DefaultRenderersFactory(context) {
    override fun buildAudioSink(context: Context, enableFloatOutput: Boolean, enableAudioTrackPlaybackParams: Boolean): AudioSink =
        DefaultAudioSink.Builder(context)
            // The equalizer first, then AutoMix's filters.
            .setAudioProcessors(arrayOf(EqualizerProcessor(), filter))
            .setEnableFloatOutput(false)
            .setEnableAudioTrackPlaybackParams(enableAudioTrackPlaybackParams)
            .build()
}

/** What the screens show of the transitions: the next one planned, and the last made. */
object TransitionInfo {
    val next = MutableStateFlow<String?>(null)
    val last = MutableStateFlow<String?>(null)
}

/**
 * The transitions between songs: AutoMix (beats matched like a DJ, or a blend or fade chosen from
 * the two songs, see [Planner]) and the plain crossfade.
 *
 * The queue stays in the main player (the one the notification and the screens control). A hidden
 * second player loads the playing song and plays it muted, kept in step with the main one (it speeds
 * up or slows down slightly, unheard). Shortly before the transition it takes over the song, audibly,
 * while the main player moves to the next song: for AutoMix to its first downbeat, at the outgoing
 * song's tempo, where it plays muted until it's in step with the outgoing song's beats; then the two
 * cross: the next song comes in, the bass passes from one to the other, the outgoing song is filtered
 * and fades. Afterwards the next song glides back to its own tempo.
 *
 * Songs of the same album follow each other as on the album, with no transition.
 */
@OptIn(UnstableApi::class)
class Transitions(
    private val context: Context,
    private val main: ExoPlayer,
    private val mainFilter: MixFilter,
    private val scope: CoroutineScope,
    /** The volume a song plays at ("Volume uniforme"), by video ID. */
    private val gainOf: (String) -> Float,
    /** False while bit-perfect output is on: it can't change the samples. */
    private val allowed: () -> Boolean,
) {
    private enum class Phase { IDLE, PREPARED, SYNCING, ALIGNING, FADING, GLIDING }

    private val faderFilter = MixFilter()
    private var fader: ExoPlayer? = null
    private var loop: Job? = null
    private var phase = Phase.IDLE
    /** "index:videoId" of the song being taken out. */
    private var preparedFor: String? = null
    private var gaveUp: String? = null
    private var plan: TransitionPlan? = null
    private var planFor: String? = null
    private var analysing: Job? = null
    private var incomingId = ""
    private var outgoingId = ""
    private var fadeStarted = 0L
    private var glideFrom = 1f
    private var glideStarted = 0L
    private var switching = false

    /** True while the transition sets the volumes. */
    val fading: Boolean get() = phase == Phase.ALIGNING || phase == Phase.FADING

    fun start() {
        main.addListener(listener)
        loop = scope.launch {
            while (isActive) {
                runCatching { tick() }.onFailure { Log.w(TAG, "Transition step failed", it) }
                delay(if (phase == Phase.IDLE || phase == Phase.PREPARED) 120 else 40)
            }
        }
    }

    fun release() {
        loop?.cancel()
        analysing?.cancel()
        main.removeListener(listener)
        fader?.release()
        fader = null
    }

    private val listener = object : Player.Listener {
        override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
            if (!playWhenReady) stop()
        }

        override fun onPositionDiscontinuity(oldPosition: Player.PositionInfo, newPosition: Player.PositionInfo, reason: Int) {
            // A seek or a skip by the user (not the transition's own move to the next song) ends it.
            if (!switching && reason == Player.DISCONTINUITY_REASON_SEEK) stop()
        }

        override fun onRepeatModeChanged(repeatMode: Int) = stop()

        override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
            if (!switching && phase != Phase.GLIDING) stop()
            plan = null
            planFor = null
            TransitionInfo.next.value = null
        }
    }

    private fun mode(): SongTransition = if (allowed()) Prefs.transition.value else SongTransition.OFF

    private fun createFader(): ExoPlayer = fader ?: ExoPlayer.Builder(context, FilteredRenderers(context, faderFilter))
        .setMediaSourceFactory(DefaultMediaSourceFactory(audioDataSourceFactory()))
        // No audio focus of its own: it would pause the main player.
        .setAudioAttributes(AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MUSIC).build(), false)
        .setWakeMode(C.WAKE_MODE_NETWORK)
        .build()
        .also { fader = it }

    private suspend fun tick() {
        when (phase) {
            Phase.ALIGNING -> return align()
            Phase.FADING -> return fade()
            Phase.GLIDING -> return glide()
            else -> Unit
        }
        val current = main.currentMediaItem
        val key = current?.let { "${main.currentMediaItemIndex}:${it.mediaId}" }
        if (preparedFor != null && preparedFor != key) stop()
        val mode = mode()
        if (mode == SongTransition.OFF || current == null || !main.isPlaying || key == gaveUp) return
        if (main.repeatMode == Player.REPEAT_MODE_ONE || !main.hasNextMediaItem()) return
        val duration = main.duration
        if (duration == C.TIME_UNSET || duration < 45_000) return
        val nextIndex = main.nextMediaItemIndex
        val next = main.getMediaItemAt(nextIndex)
        if (sameAlbum(current, next)) {
            TransitionInfo.next.value = tr("come nell'album")
            return
        }
        val position = main.currentPosition / 1000.0

        // The plan: AutoMix's from the two songs' analyses (asked for well ahead), else a crossfade.
        if (mode == SongTransition.AUTOMIX && planFor != "$key>${next.mediaId}") requestPlan(key!!, current.mediaId, next.mediaId)
        val seconds = Prefs.crossfadeSeconds.value.toDouble()
        val fallback = TransitionPlan(
            style = TransitionPlan.Style.BLEND, outStart = duration / 1000.0 - seconds, outEnd = duration / 1000.0,
            inStart = 0.0, incomingRate = 1.0,
        )
        val simple = if (mode == SongTransition.AUTOMIX) fallback.copy(fadeOutFrom = 0.3, fadeIn = 0.7) else fallback
        // Seconds before the mix when the hidden player takes over the song: AutoMix needs a moment
        // for the next song to start and fall in step, muted.
        fun lead(p: TransitionPlan) = if (p.style == TransitionPlan.Style.BEAT_MATCHED || p.inStart > 0.5) LEAD else 0.0
        var chosen = if (mode == SongTransition.AUTOMIX) plan ?: simple else simple
        // AutoMix's plan came too late (a slow analysis), or the hidden player isn't in step yet when
        // it should take over: the plain crossfade at the end instead.
        val due = chosen.outStart - lead(chosen)
        val late = position > due + 1.0 || (position > due && (phase != Phase.SYNCING || fader?.isPlaying != true))
        if (chosen !== simple && late) chosen = simple
        TransitionInfo.next.value = if (mode == SongTransition.AUTOMIX) "${tr("AutoMix")} · ${chosen.description}" else chosen.description
        val lead = lead(chosen)
        val handover = chosen.outStart - lead
        if (handover < position + 0.2 && phase == Phase.IDLE) {
            // Too late for this one (a seek near the end): the song ends as it is.
            if (position > handover + 1) gaveUp = key
            return
        }
        when {
            position < handover - 14 -> return
            preparedFor != key -> {
                val player = createFader()
                faderFilter.bassCut = 0f
                faderFilter.highPass = 0f
                player.volume = 0f
                player.setPlaybackSpeed(1f)
                player.setMediaItem(current, ((handover - 3) * 1000).toLong().coerceAtLeast(0))
                player.prepare()
                preparedFor = key
                phase = Phase.PREPARED
            }
            position >= handover -> handOver(chosen, lead, nextIndex, current.mediaId)
            position >= handover - 3 -> keepInStep()
        }
    }

    /** Asks for both songs' analyses (in the background) and plans the transition when they're there. */
    private fun requestPlan(key: String, outgoing: String, incoming: String) {
        val target = "$key>$incoming"
        if (planFor == target) return
        planFor = target
        plan = null
        analysing?.cancel()
        analysing = scope.launch {
            val out = AutoMixLibrary.analysis(outgoing)
            val into = AutoMixLibrary.analysis(incoming)
            if (planFor != target || out == null || into == null) return@launch
            plan = Planner.plan(out.tail, out.duration, into.head).also {
                Log.i(TAG, "Plan $outgoing → $incoming: ${it.style} ${it.description}, out ${"%.2f".format(it.outStart)}–" +
                    "${"%.2f".format(it.outEnd)}, in ${"%.2f".format(it.inStart)}, rate ${"%.4f".format(it.incomingRate)}")
            }
        }
    }

    /** The hidden copy plays muted, nudging its speed until it runs with the main player. */
    private fun keepInStep() {
        val player = fader ?: return
        if (!player.isPlaying) {
            if (player.playbackState != Player.STATE_READY) return
            player.seekTo(main.currentPosition + 120)
            player.play()
            phase = Phase.SYNCING
            return
        }
        val drift = player.currentPosition - main.currentPosition
        val speed = if (abs(drift) <= 12) 1f else (1f - drift / 1000f).coerceIn(0.85f, 1.15f)
        if (abs(player.playbackParameters.speed - speed) > 0.001f) player.setPlaybackSpeed(speed)
    }

    private var active: TransitionPlan? = null

    /** The hidden player takes the song over, audibly; the main one moves to the next song. */
    private fun handOver(plan: TransitionPlan, lead: Double, nextIndex: Int, outgoing: String) {
        val player = fader
        if (player == null || !player.isPlaying) {
            // Not ready in time (a slow connection): this song ends without a transition.
            stop()
            gaveUp = main.currentMediaItem?.let { "${main.currentMediaItemIndex}:${it.mediaId}" }
            return
        }
        active = plan
        outgoingId = outgoing
        player.setPlaybackSpeed(1f)
        player.volume = gainOf(outgoing)
        main.volume = 0f
        switching = true
        if (lead > 0) {
            val start = plan.inStart - lead * plan.incomingRate
            main.seekTo(nextIndex, (start * 1000).toLong().coerceAtLeast(0))
            main.setPlaybackSpeed(plan.incomingRate.toFloat())
        } else {
            main.seekToDefaultPosition(nextIndex)
        }
        switching = false
        incomingId = main.currentMediaItem?.mediaId.orEmpty()
        TransitionInfo.last.value = (if (mode() == SongTransition.AUTOMIX) "${tr("AutoMix")} · " else "") + plan.description
        phase = if (lead > 0) Phase.ALIGNING else Phase.FADING
        alignSeeks = 0
        lastAlignSeek = SystemClock.elapsedRealtime()
        fadeStarted = SystemClock.elapsedRealtime()
    }

    /** Where the next song should be now, in its own seconds, from the outgoing song's position. */
    private fun target(plan: TransitionPlan, outgoingTime: Double) = plan.inStart + (outgoingTime - plan.outStart) * plan.incomingRate

    private var alignSeeks = 0
    private var lastAlignSeek = 0L
    /** How long the next song takes to sound after a seek, learnt from the seeks themselves. */
    private var seekLatency = 0.15

    /**
     * Before the mix: the next song, muted, falls in step with the outgoing song's beats. Far off,
     * it jumps there (it's muted, nothing is heard), allowing for the time a seek takes to sound,
     * which each jump measures for the next; close, it changes speed a little.
     */
    private fun align() {
        val plan = active ?: return stop()
        val player = fader ?: return stop()
        val outTime = player.currentPosition / 1000.0
        val settled = SystemClock.elapsedRealtime() - lastAlignSeek > 450
        if (main.isPlaying && settled) {
            val drift = main.currentPosition / 1000.0 - target(plan, outTime)
            if (abs(drift) > 0.05 && alignSeeks < 4 && plan.outStart - outTime > 1.2) {
                // (Negative when the player reports a seek's position before it sounds.)
                if (alignSeeks > 0) seekLatency = (seekLatency - drift / plan.incomingRate).coerceIn(-0.5, 0.8)
                val goal = target(plan, outTime + seekLatency)
                switching = true
                main.seekTo((goal * 1000).toLong())
                switching = false
                main.setPlaybackSpeed(plan.incomingRate.toFloat())
                alignSeeks++
                lastAlignSeek = SystemClock.elapsedRealtime()
            } else {
                nudge(plan, outTime, strength = 1.5, limit = 0.12)
            }
        }
        if (outTime >= plan.outStart) {
            val drift = main.currentPosition / 1000.0 - target(plan, outTime)
            Log.i(TAG, "In step within ${"%.0f".format(drift * 1000)} ms after $alignSeeks jumps (seek latency ${"%.0f".format(seekLatency * 1000)} ms)")
            if (!main.isPlaying || abs(drift) > 0.08) {
                // Couldn't fall in step in time: a short crossfade at the song's own tempo instead.
                Log.i(TAG, "Not in step (${"%.0f".format(drift * 1000)} ms): short crossfade")
                TransitionInfo.last.value = "${tr("AutoMix")} · ${tr("Mix non riuscito: dissolvenza semplice")}"
                main.setPlaybackSpeed(1f)
                active = plan.copy(
                    style = TransitionPlan.Style.BLEND, outEnd = plan.outStart + 3, incomingRate = 1.0,
                    swapStart = null, swapEnd = null, fadeInFrom = 0.0, fadeIn = 1.0, fadeOutFrom = 0.0, filterOut = null,
                )
            }
            phase = Phase.FADING
        }
    }

    /** Keeps the next song on the outgoing song's beats by changing its speed a little. */
    private fun nudge(plan: TransitionPlan, outTime: Double, strength: Double, limit: Double) {
        val drift = main.currentPosition / 1000.0 - target(plan, outTime)
        val correction = (drift * strength).coerceIn(-limit, limit)
        val speed = (plan.incomingRate * (1 - correction)).toFloat()
        if (abs(main.playbackParameters.speed - speed) > 0.002f) main.setPlaybackSpeed(speed)
    }

    /** The mix itself: volumes, the bass passing over and the outgoing song's filter, by its progress. */
    private fun fade() {
        val plan = active ?: return stop()
        val player = fader ?: return stop()
        // The crossfade's clock is the outgoing song; if it stops early, the mix ends.
        val outTime = player.currentPosition / 1000.0
        val levels = plan.levels(plan.progress(outTime))
        player.volume = gainOf(outgoingId) * levels.outgoing
        main.volume = gainOf(incomingId) * levels.incoming
        faderFilter.bassCut = levels.outgoingBassCut
        faderFilter.highPass = levels.outgoingHighPass
        mainFilter.bassCut = levels.incomingBassCut
        if (plan.style == TransitionPlan.Style.BEAT_MATCHED && main.isPlaying) nudge(plan, outTime, strength = 0.6, limit = 0.03)
        if (outTime >= plan.outEnd || player.playbackState == Player.STATE_ENDED || !player.isPlaying && outTime > plan.outStart) {
            finishMix(plan)
        }
    }

    private fun finishMix(plan: TransitionPlan) {
        fader?.let {
            it.stop()
            it.clearMediaItems()
        }
        faderFilter.bassCut = 0f
        faderFilter.highPass = 0f
        mainFilter.bassCut = 0f
        mainFilter.highPass = 0f
        main.volume = gainOf(incomingId)
        preparedFor = null
        active = null
        if (abs(main.playbackParameters.speed - 1f) > 0.001f) {
            // The next song glides back to its own tempo over about eight bars.
            glideFrom = main.playbackParameters.speed
            glideStarted = SystemClock.elapsedRealtime()
            phase = Phase.GLIDING
        } else {
            phase = Phase.IDLE
        }
    }

    private fun glide() {
        val t = ((SystemClock.elapsedRealtime() - glideStarted) / 12_000f).coerceIn(0f, 1f)
        val speed = glideFrom + (1f - glideFrom) * t
        // Small steps, not every frame: each change of speed passes through the audio pipeline.
        if (t >= 1f || abs(main.playbackParameters.speed - speed) > 0.0015f) main.setPlaybackSpeed(if (t >= 1f) 1f else speed)
        if (t >= 1f) phase = Phase.IDLE
    }

    /** Ends any transition: the hidden player stops, the main one plays at its volume and speed. */
    fun stop() {
        val wasMixing = phase != Phase.IDLE && phase != Phase.PREPARED && phase != Phase.SYNCING
        preparedFor = null
        active = null
        fader?.let {
            it.stop()
            it.clearMediaItems()
            it.setPlaybackSpeed(1f)
        }
        faderFilter.bassCut = 0f
        faderFilter.highPass = 0f
        mainFilter.bassCut = 0f
        mainFilter.highPass = 0f
        if (wasMixing || phase == Phase.GLIDING) {
            main.setPlaybackSpeed(1f)
            main.volume = main.currentMediaItem?.mediaId?.let(gainOf) ?: 1f
        }
        phase = Phase.IDLE
    }

    private fun sameAlbum(a: MediaItem, b: MediaItem): Boolean {
        val first = a.toTrack()?.albumId ?: return false
        return first == b.toTrack()?.albumId
    }

    private companion object {
        const val TAG = "Transitions"
        /** Seconds before the mix when the next song starts, muted, to fall in step. */
        const val LEAD = 6.0
    }
}
