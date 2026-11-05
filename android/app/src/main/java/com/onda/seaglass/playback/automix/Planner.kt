package com.onda.seaglass.playback.automix

import com.onda.seaglass.core.tr
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * How AutoMix takes one song into the next, as the iPhone app's `TransitionPlan`. Times are in each
 * song's own seconds.
 */
data class TransitionPlan(
    val style: Style,
    /** Outgoing song's time when the next one starts, and when it has gone. */
    val outStart: Double,
    val outEnd: Double,
    /** Where the next song starts, in its own time. */
    val inStart: Double,
    /** The next song's speed while the two play together (1 unless the beats are matched). */
    val incomingRate: Double,
    /** Beat-matched: the outgoing song's bars the two play together. */
    val bars: Int? = null,
    /** Progress (0…1) over which the bass passes from one song to the other; null for none. */
    val swapStart: Double? = null,
    val swapEnd: Double? = null,
    /** Progress at which the next song starts coming in, and is fully in. */
    val fadeInFrom: Double = 0.0,
    val fadeIn: Double = 1.0,
    /** Progress at which the outgoing song starts going. */
    val fadeOutFrom: Double = 0.0,
    /** Progress from which a high-pass filter sweeps up through the outgoing song; null for none. */
    val filterOut: Double? = null,
    /** One beat of the outgoing song, in seconds (for keeping the two in step). */
    val beatLength: Double = 0.5,
) {
    enum class Style {
        /** Beats matched like a DJ: the next song comes in on a downbeat at the outgoing song's tempo. */
        BEAT_MATCHED,
        /** No beats to match: a long crossfade on the ending, filtered when the song has a beat. */
        BLEND,
        /** The song fades out on its own: the next one comes in during the fade. */
        FADE,
        /** No overlap: the next song starts as this one's sound ends, the silence between them left out. */
        GAPLESS,
    }

    val overlap: Double get() = outEnd - outStart

    fun progress(outgoingTime: Double): Double =
        if (overlap <= 0) (if (outgoingTime >= outStart) 1.0 else 0.0) else ((outgoingTime - outStart) / overlap).coerceIn(0.0, 1.0)

    /** The two songs' volumes, bass cuts (0 none … 1 all) and the outgoing song's high-pass (0 … 1). */
    data class Levels(val outgoing: Float, val incoming: Float, val outgoingBassCut: Float, val incomingBassCut: Float, val outgoingHighPass: Float)

    fun levels(progress: Double): Levels {
        val p = progress.coerceIn(0.0, 1.0)
        fun ramp(from: Double, to: Double) = if (to > from) ((p - from) / (to - from)).coerceIn(0.0, 1.0) else if (p >= from) 1.0 else 0.0
        // Equal-power curves: over the same stretch the two add up to a steady loudness.
        val comeIn = ramp(fadeInFrom, fadeIn)
        val goOut = ramp(fadeOutFrom, 1.0)
        var swap = 0.0
        if (swapStart != null && swapEnd != null) {
            val x = ramp(swapStart, swapEnd)
            swap = x * x * (3 - 2 * x)
        }
        var highPass = 0.0
        if (filterOut != null && p > filterOut) {
            val x = ramp(filterOut, 1.0)
            highPass = x * x * (3 - 2 * x)
        }
        val hasSwap = swapStart != null && swapEnd != null
        // The bass passes over at equal power, so the two together have one song's bass.
        return Levels(
            outgoing = cos(goOut * PI / 2).toFloat(),
            incoming = sin(comeIn * PI / 2).toFloat(),
            outgoingBassCut = if (hasSwap) (1 - cos(swap * PI / 2)).toFloat() else 0f,
            incomingBassCut = if (hasSwap) (1 - sin(swap * PI / 2)).toFloat() else 0f,
            outgoingHighPass = highPass.toFloat(),
        )
    }

    /** "a tempo, 8 battute", "dissolvenza di 9 s", for the player and the settings. */
    val description: String
        get() = when (style) {
            Style.BEAT_MATCHED -> tr("a tempo, %lld battute", bars ?: 0)
            Style.BLEND, Style.FADE -> tr("dissolvenza di %lld s", overlap.roundToInt())
            Style.GAPLESS -> tr("senza silenzio tra i brani")
        }
}

/**
 * Chooses the transition between two songs from the end of one and the start of the other, as the
 * iPhone app's planner does in its main lines: beats matched over 8 or 4 bars when both have a
 * steady beat at close tempos, the bass passing from one to the other half way; otherwise a long
 * crossfade (into the song's own fade-out when it has one), with no silence left between them.
 */
object Planner {
    /** Tempos closer than this (or at double or half of each other) are matched. */
    private const val MAX_TEMPO_CHANGE = 0.06

    fun plan(outgoing: WindowAnalysis, duration: Double, incoming: WindowAnalysis): TransitionPlan {
        val soundEnd = min(outgoing.soundEnd, duration)
        val soundStart = max(0.0, incoming.soundStart)
        beatMatched(outgoing, soundEnd, incoming, soundStart)?.let { return it }

        val fade = fadeOut(outgoing, soundEnd)
        if (fade != null) {
            // The song fades out by itself: the next one comes in during the fade.
            val (fadeStart, fadeEnd) = fade
            val start = fadeStart + (fadeEnd - fadeStart) * 0.35
            return TransitionPlan(
                style = TransitionPlan.Style.FADE,
                outStart = start, outEnd = fadeEnd, inStart = soundStart, incomingRate = 1.0,
                fadeInFrom = 0.0, fadeIn = 0.6, fadeOutFrom = 0.3,
            )
        }
        // A blend: up to 10 s, on the last of the sound, filtered when the song has a beat.
        val length = min(10.0, max(4.0, (soundEnd - outgoing.start) / 3))
        if (soundEnd - length < outgoing.start) {
            return TransitionPlan(TransitionPlan.Style.GAPLESS, soundEnd, soundEnd, soundStart, 1.0)
        }
        return TransitionPlan(
            style = TransitionPlan.Style.BLEND,
            outStart = soundEnd - length, outEnd = soundEnd, inStart = soundStart, incomingRate = 1.0,
            fadeInFrom = 0.0, fadeIn = 0.55, fadeOutFrom = 0.4,
            filterOut = if (outgoing.hasBeat) 0.5 else null,
        )
    }

    private fun beatMatched(outgoing: WindowAnalysis, soundEnd: Double, incoming: WindowAnalysis, soundStart: Double): TransitionPlan? {
        if (!outgoing.hasBeat || !incoming.hasBeat) return null
        // The next song's tempo as heard against this one's (a song at half or double tempo has the same pulse).
        val rate = listOf(1.0, 2.0, 0.5)
            .map { multiple -> outgoing.tempo / (incoming.tempo * multiple) to multiple }
            .minByOrNull { abs(it.first - 1) }
            ?.takeIf { abs(it.first - 1) <= MAX_TEMPO_CHANGE }
            ?: return null
        val incomingRate = rate.first
        val beat = 60 / outgoing.tempo
        val bar = beat * 4
        // The last downbeat before the sound ends (one beat of margin) ends the mix.
        val downbeats = outgoing.downbeats.filter { it <= soundEnd - beat * 0.5 }
        if (downbeats.size < 5) return null
        // The next song's first downbeat with sound, and enough of its beats to keep in step.
        val entry = incoming.downbeats.firstOrNull { it >= soundStart - beat * 0.25 } ?: return null
        for (bars in listOf(8, 4)) {
            val endIndex = downbeats.size - 1
            val startIndex = endIndex - bars
            if (startIndex < 0) continue
            val outStart = downbeats[startIndex]
            val outEnd = downbeats[endIndex]
            // The whole mix inside the analysed minute, and the next song's part too.
            if (outStart < outgoing.start + 2 || outEnd - outStart < bar * bars * 0.9) continue
            val incomingNeeded = (outEnd - outStart) / incomingRate
            if (entry + incomingNeeded > incoming.end) continue
            return TransitionPlan(
                style = TransitionPlan.Style.BEAT_MATCHED,
                outStart = outStart, outEnd = outEnd, inStart = entry, incomingRate = incomingRate,
                bars = bars,
                swapStart = 0.45, swapEnd = 0.6,
                fadeInFrom = 0.0, fadeIn = 0.35,
                fadeOutFrom = 0.65,
                filterOut = 0.75,
                beatLength = beat,
            )
        }
        return null
    }

    /** Where the song's own fade-out starts and ends, when the level falls steadily by 12 dB or more. */
    private fun fadeOut(outgoing: WindowAnalysis, soundEnd: Double): Pair<Double, Double>? {
        if (outgoing.energy.size < 40) return null
        // The level a few seconds before the end, against the last 30 s's loud parts.
        val step = WindowAnalysis.ENERGY_STEP
        val endIndex = ((soundEnd - outgoing.start) / step).toInt().coerceAtMost(outgoing.energy.size - 1)
        val from = max(0, endIndex - (30 / step).toInt())
        val body = outgoing.energy.subList(from, max(from + 1, endIndex - (10 / step).toInt())).sorted()
        if (body.isEmpty()) return null
        val loud = body[(body.size * 0.8).toInt().coerceAtMost(body.size - 1)]
        // Walk back from the end while it's quieter than the body by 2 dB or more.
        var start = endIndex
        while (start > from && outgoing.energy[start] < loud - 2) start--
        val fadeStart = outgoing.start + start * step
        val length = soundEnd - fadeStart
        val depth = loud - outgoing.energy[max(0, endIndex - 4)]
        return if (length in 5.0..20.0 && depth >= 12) fadeStart to soundEnd else null
    }
}
