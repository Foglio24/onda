package com.onda.seaglass.playback

import android.content.Context
import android.net.Uri
import android.os.SystemClock
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
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
import com.onda.seaglass.playback.automix.MixInfo
import com.onda.seaglass.playback.automix.Planner
import com.onda.seaglass.playback.automix.TransitionPlan
import com.onda.seaglass.playback.karaoke.KaraokeProcessor
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlin.math.abs

/**
 * A player whose audio passes through the [karaoke] (the main player's only), the equalizer and
 * [filter] (AutoMix's bass and high-pass filters).
 */
@OptIn(UnstableApi::class)
class FilteredRenderers(
    context: Context,
    private val filter: MixFilter,
    private val karaoke: KaraokeProcessor? = null,
) : DefaultRenderersFactory(context) {
    override fun buildAudioSink(context: Context, enableFloatOutput: Boolean, enableAudioTrackPlaybackParams: Boolean): AudioSink =
        DefaultAudioSink.Builder(context)
            // The karaoke first (it works on the song as decoded), then the equalizer, then AutoMix's filters.
            .setAudioProcessors(listOfNotNull(karaoke, EqualizerProcessor(), filter).toTypedArray())
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
 * second player plays, muted and kept in step with the main one, the same music: the playing song
 * itself, or, for AutoMix's beat-matched mixes, the mix rendered ahead of time into a file (which
 * starts with the song alone, see [MixRenderer]). Shortly before the transition it takes over,
 * audibly, while the main player moves to the next song:
 * - for a crossfade or a blend, the two players cross: the next song comes in as the hidden player's
 *   song fades (and, for AutoMix, is filtered);
 * - for a beat-matched mix, the file plays the mix with its beats matched sample for sample, while
 *   the main player plays the next song muted, at the mix's tempo, falling in step with the file;
 *   once the file has only the next song left, the main player takes it back. Afterwards the next
 *   song glides back to its own tempo.
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
    private enum class Phase { IDLE, PREPARED, SYNCING, FADING, MIXING, GLIDING }

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
    /** The beat-matched plan's mix, once rendered. */
    private var mix: MixInfo? = null
    /** The transition the hidden player was readied for, kept from then on, and its mix. */
    private var locked: TransitionPlan? = null
    private var lockedMix: MixInfo? = null
    /** The outgoing song's time at the hidden player's 0 (the mix's start, or 0 for the song itself). */
    private var faderOffset = 0.0
    private var active: TransitionPlan? = null
    private var incomingId = ""
    private var outgoingId = ""
    private var glideFrom = 1f
    private var glideStarted = 0L
    private var switching = false
    /** The second half of a handover between the players, made on the next step (40 ms later). */
    private var crossing: (() -> Unit)? = null
    private var seeks = 0
    private var lastSeek = 0L
    /** How long the main player takes to sound after a seek, learnt from its seeks. */
    private var seekLatency = 0.15
    private var inStep = 0

    /** True while the transition sets the main player's volume (so nothing else should). */
    val fading: Boolean
        get() = switching || crossing != null || phase == Phase.FADING || phase == Phase.MIXING

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
            // A seek or a skip by the user (not the transition's own moves) ends it.
            if (!switching && reason == Player.DISCONTINUITY_REASON_SEEK) stop()
        }

        override fun onRepeatModeChanged(repeatMode: Int) = stop()

        override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
            if (!switching && phase != Phase.GLIDING) stop()
            plan = null
            planFor = null
            mix = null
            TransitionInfo.next.value = null
        }
    }

    private fun mode(): SongTransition = if (allowed()) Prefs.transition.value else SongTransition.OFF

    private fun createFader(): ExoPlayer = fader ?: ExoPlayer.Builder(context, FilteredRenderers(context, faderFilter))
        // Songs through the player's own data source, rendered mixes from their files.
        .setMediaSourceFactory(DefaultMediaSourceFactory(DefaultDataSource.Factory(context, audioDataSourceFactory())))
        // No audio focus of its own: it would pause the main player.
        .setAudioAttributes(AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MUSIC).build(), false)
        .setWakeMode(C.WAKE_MODE_NETWORK)
        .build()
        .also { fader = it }

    private fun tick() {
        crossing?.let {
            crossing = null
            it()
            return
        }
        when (phase) {
            Phase.FADING -> return fade()
            Phase.MIXING -> return followMix()
            Phase.GLIDING -> return glide()
            else -> Unit
        }
        val current = main.currentMediaItem
        val key = current?.let { "${main.currentMediaItemIndex}:${it.mediaId}" }
        if (preparedFor != null && preparedFor != key) stop()
        val mode = mode()
        if (mode == SongTransition.OFF || current == null || !main.isPlaying || key == null || key == gaveUp) return
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
        if (mode == SongTransition.AUTOMIX && planFor != "$key>${next.mediaId}") requestPlan(key, current.mediaId, next.mediaId)
        val seconds = Prefs.crossfadeSeconds.value.toDouble()
        val simple = TransitionPlan(
            style = TransitionPlan.Style.BLEND, outStart = duration / 1000.0 - seconds, outEnd = duration / 1000.0,
            inStart = 0.0, incomingRate = 1.0,
        )
        // Once the hidden player is readied for a transition, that's the one made.
        val chosen = locked ?: choose(mode, simple, position)
        val rendered = if (locked != null) lockedMix else mix?.takeIf { it.plan == chosen }
        TransitionInfo.next.value = if (mode == SongTransition.AUTOMIX) "${tr("AutoMix")} · ${chosen.description}" else chosen.description
        val handover = handoverTime(chosen, rendered)
        if (handover < position + 0.2 && phase == Phase.IDLE) {
            // Too late for this one (a seek near the end): the song ends as it is.
            if (position > handover + 1) gaveUp = key
            return
        }
        when {
            position < handover - 14 -> return
            preparedFor != key -> prepare(current, key, chosen, rendered, handover)
            position >= handover -> handOver(chosen, rendered, nextIndex, current.mediaId)
            position >= syncFrom(handover, rendered) -> keepInStep()
        }
    }

    /** AutoMix's plan when it can be made in time (a beat-matched one once its mix is rendered), else [simple]. */
    private fun choose(mode: SongTransition, simple: TransitionPlan, position: Double): TransitionPlan {
        val automix = plan?.takeIf { mode == SongTransition.AUTOMIX } ?: return simple
        if (automix.style == TransitionPlan.Style.BEAT_MATCHED && mix?.plan != automix) return simple
        // Too close to get the hidden player ready for it (the plan came late): the plain blend.
        return if (position > handoverTime(automix, mix) - 2.5) simple else automix
    }

    /** When the hidden player takes over: for a beat-matched mix, at a quiet moment just before it. */
    private fun handoverTime(plan: TransitionPlan, rendered: MixInfo?): Double =
        if (rendered != null) maxOf(rendered.takeover, rendered.start + 3.0) else plan.outStart

    /** When the hidden player starts playing, muted, to fall in step: from the mix's start, or 3 s ahead. */
    private fun syncFrom(handover: Double, rendered: MixInfo?): Double =
        if (rendered != null) minOf(rendered.start + 0.3, handover - 2.0) else handover - 3.0

    private fun prepare(current: MediaItem, key: String, chosen: TransitionPlan, rendered: MixInfo?, handover: Double) {
        val player = createFader()
        faderFilter.bassCut = 0f
        faderFilter.highPass = 0f
        player.volume = 0f
        player.setPlaybackSpeed(1f)
        if (rendered != null) {
            player.setMediaItem(MediaItem.fromUri(Uri.fromFile(rendered.file)))
            faderOffset = rendered.start
        } else {
            player.setMediaItem(current, ((handover - 3) * 1000).toLong().coerceAtLeast(0))
            faderOffset = 0.0
        }
        player.prepare()
        preparedFor = key
        locked = chosen
        lockedMix = rendered
        phase = Phase.PREPARED
    }

    /** Asks for both songs' analyses (in the background), plans the transition and renders a beat-matched one. */
    private fun requestPlan(key: String, outgoing: String, incoming: String) {
        val target = "$key>$incoming"
        if (planFor == target) return
        planFor = target
        plan = null
        mix = null
        analysing?.cancel()
        analysing = scope.launch {
            val out = AutoMixLibrary.analysis(outgoing)
            val into = AutoMixLibrary.analysis(incoming)
            if (planFor != target || out == null || into == null) return@launch
            val made = Planner.plan(out.tail, out.duration, into.head).also {
                Log.i(TAG, "Plan $outgoing → $incoming: ${it.style} ${it.description}, out ${"%.2f".format(it.outStart)}–" +
                    "${"%.2f".format(it.outEnd)}, in ${"%.2f".format(it.inStart)}, rate ${"%.4f".format(it.incomingRate)}")
            }
            plan = made
            if (made.style == TransitionPlan.Style.BEAT_MATCHED) {
                val rendered = AutoMixLibrary.render(made, outgoing, incoming, gainOf)
                if (planFor == target && plan == made) mix = rendered
            }
        }
    }

    /** The hidden player plays muted, nudging its speed until it runs with the main player. */
    private fun keepInStep() {
        val player = fader ?: return
        val offset = (faderOffset * 1000).toLong()
        if (!player.isPlaying) {
            if (player.playbackState != Player.STATE_READY) return
            player.seekTo((main.currentPosition - offset + 120).coerceAtLeast(0))
            player.play()
            phase = Phase.SYNCING
            return
        }
        val drift = player.currentPosition + offset - main.currentPosition
        val speed = if (abs(drift) <= 12) 1f else (1f - drift / 1000f).coerceIn(0.85f, 1.15f)
        if (abs(player.playbackParameters.speed - speed) > 0.001f) player.setPlaybackSpeed(speed)
    }

    /**
     * The hidden player takes over, audibly: half and half for a moment (the two play the same music,
     * a few milliseconds apart at most), then all its own; the main player moves to the next song.
     */
    private fun handOver(plan: TransitionPlan, rendered: MixInfo?, nextIndex: Int, outgoing: String) {
        val player = fader
        if (player == null || !player.isPlaying) {
            // Not ready in time (a slow connection): this song ends without a transition.
            stop()
            gaveUp = main.currentMediaItem?.let { "${main.currentMediaItemIndex}:${it.mediaId}" }
            return
        }
        Log.i(TAG, "Taking over within ${player.currentPosition + (faderOffset * 1000).toLong() - main.currentPosition} ms")
        active = plan
        outgoingId = outgoing
        val gain = gainOf(outgoing)
        // The mix has the songs' volumes in it; the song itself plays at its volume.
        val full = if (rendered != null) 1f else gain
        player.setPlaybackSpeed(1f)
        player.volume = full * 0.5f
        main.volume = gain * 0.5f
        val automix = mode() == SongTransition.AUTOMIX
        val missed = automix && this.plan?.style == TransitionPlan.Style.BEAT_MATCHED && rendered == null
        TransitionInfo.last.value = when {
            missed -> "${tr("AutoMix")} · ${tr("Mix non riuscito: dissolvenza semplice")}"
            automix -> "${tr("AutoMix")} · ${plan.description}"
            else -> plan.description
        }
        phase = if (rendered != null) Phase.MIXING else Phase.FADING
        crossing = {
            player.volume = full
            main.volume = 0f
            switching = true
            when {
                rendered != null -> {
                    // Into the next song where the file will have it in a moment, at the mix's tempo.
                    val ahead = rendered.incomingTime(player.currentPosition / 1000.0 + 1.0)
                    main.seekTo(nextIndex, (maxOf(0.0, ahead) * 1000).toLong())
                    main.setPlaybackSpeed(plan.incomingRate.toFloat())
                }
                plan.inStart > 0.5 -> main.seekTo(nextIndex, (plan.inStart * 1000).toLong())
                else -> main.seekToDefaultPosition(nextIndex)
            }
            switching = false
            incomingId = main.currentMediaItem?.mediaId.orEmpty()
            seeks = 0
            inStep = 0
            lastSeek = SystemClock.elapsedRealtime()
        }
    }

    /**
     * While the file plays the mix: the main player, muted, plays the next song where the file has it
     * (far off it jumps there, allowing for the time a jump takes to sound; close, it changes speed a
     * little). Once the file has only the next song left and the two are in step, it takes it back.
     */
    private fun followMix() {
        val player = fader ?: return stop()
        val mix = lockedMix ?: return stop()
        val mixTime = player.currentPosition / 1000.0
        val rate = mix.plan.incomingRate
        val target = mix.incomingTime(mixTime)
        var drift: Double? = null
        if (main.isPlaying && SystemClock.elapsedRealtime() - lastSeek > 500 && target > 0.3) {
            val off = main.currentPosition / 1000.0 - target
            drift = off
            if (abs(off) > 0.06 && seeks < 6 && mixTime < mix.length - 2.5) {
                // (Negative when the player reports a seek's position before it sounds.)
                if (seeks > 0) seekLatency = (seekLatency - off / rate).coerceIn(-0.5, 1.0)
                switching = true
                main.seekTo((mix.incomingTime(mixTime + seekLatency) * 1000).toLong())
                switching = false
                main.setPlaybackSpeed(rate.toFloat())
                seeks++
                lastSeek = SystemClock.elapsedRealtime()
            } else {
                val correction = (off * 1.5).coerceIn(-0.1, 0.1)
                val speed = (rate * (1 - correction)).toFloat()
                if (abs(main.playbackParameters.speed - speed) > 0.002f) main.setPlaybackSpeed(speed)
            }
            inStep = if (mixTime >= mix.mixEnd && abs(off) <= 0.02) inStep + 1 else 0
        }
        // In step: back at the next quiet moment (the crossing lands on it on the next step).
        val quiet = mix.quietMoments.firstOrNull { it >= mixTime }
        val atQuiet = quiet == null || quiet - mixTime <= 0.045
        val ended = player.playbackState == Player.STATE_ENDED || !player.isPlaying
        if (inStep >= 3 && atQuiet || mixTime >= mix.length - 1.0 || ended) handBack(mix, drift)
    }

    /** The main player takes the next song back from the file: half and half for a moment, then all its own. */
    private fun handBack(mix: MixInfo, drift: Double?) {
        val player = fader
        Log.i(TAG, "Handing back " + (drift?.let { "within ${"%.0f".format(it * 1000)} ms" } ?: "out of step") +
            " after $seeks jumps (seek latency ${"%.0f".format(seekLatency * 1000)} ms)")
        val gain = gainOf(incomingId)
        main.setPlaybackSpeed(mix.plan.incomingRate.toFloat())
        player?.volume = 0.5f
        main.volume = gain * 0.5f
        crossing = { finishMix() }
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
        if (outTime >= plan.outEnd || player.playbackState == Player.STATE_ENDED || !player.isPlaying && outTime > plan.outStart) {
            finishMix()
        }
    }

    private fun finishMix() {
        fader?.let {
            it.stop()
            it.clearMediaItems()
            it.setPlaybackSpeed(1f)
        }
        faderFilter.bassCut = 0f
        faderFilter.highPass = 0f
        mainFilter.bassCut = 0f
        mainFilter.highPass = 0f
        main.volume = gainOf(incomingId)
        preparedFor = null
        active = null
        locked = null
        lockedMix = null
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
        val wasMixing = phase == Phase.FADING || phase == Phase.MIXING || phase == Phase.GLIDING || crossing != null
        crossing = null
        preparedFor = null
        active = null
        locked = null
        lockedMix = null
        fader?.let {
            it.stop()
            it.clearMediaItems()
            it.setPlaybackSpeed(1f)
        }
        faderFilter.bassCut = 0f
        faderFilter.highPass = 0f
        mainFilter.bassCut = 0f
        mainFilter.highPass = 0f
        if (wasMixing) {
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
    }
}
