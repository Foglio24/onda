package com.onda.seaglass.audio.automix

import com.onda.seaglass.core.tr
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.ln
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
        // Equal-power curves: over the same stretch (the whole mix, unless the song fades out by itself)
        // the two add up to a steady loudness, with no rise or dip in the middle.
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
 * iPhone app's planner does in its main lines: beats matched when both have a steady beat at tempos
 * up to 12 % apart (counting half and double time), over 16 bars when the tempos are close, 8 or 4
 * otherwise, the bass passing from one to the other on a downbeat half way; otherwise a crossfade on
 * the song's ending (longer into its own fade-out, on a downbeat when it has a beat), with no silence
 * left between them.
 */
object Planner {
    /** Tempos further apart than this are crossfaded, not matched (the iPhone's limit for AutoMix). */
    private const val MAX_TEMPO_CHANGE = 0.12
    /** Tempos this close get the longest mixes. */
    private const val CLOSE_TEMPO = 0.06
    /** The longest beat-matched overlap, in seconds (as on the iPhone). */
    private const val LONGEST_OVERLAP = 48.0

    fun plan(outgoing: WindowAnalysis, duration: Double, incoming: WindowAnalysis): TransitionPlan {
        val soundEnd = min(outgoing.soundEnd, duration)
        val soundStart = max(0.0, incoming.soundStart)
        beatMatched(outgoing, duration, soundEnd, incoming, soundStart)?.let { return it }
        return blend(outgoing, duration, soundEnd, incoming, soundStart)
    }

    /** The next song's tempo as heard against this one's: the ratio to play it at (half or double folded in). */
    fun tempoRatio(outgoing: WindowAnalysis, incoming: WindowAnalysis): Double? {
        if (outgoing.tempo <= 0 || incoming.tempo <= 0) return null
        return listOf(1.0, 2.0, 0.5)
            .map { multiple -> outgoing.tempo / (incoming.tempo * multiple) }
            .minByOrNull { abs(ln(it)) }
            ?.takeIf { abs(ln(it)) <= ln(1 + MAX_TEMPO_CHANGE) }
    }

    private fun beatMatched(
        outgoing: WindowAnalysis, duration: Double, soundEnd: Double, incoming: WindowAnalysis, soundStart: Double,
    ): TransitionPlan? {
        if (!outgoing.hasBeat || !incoming.hasBeat) return null
        val incomingRate = tempoRatio(outgoing, incoming) ?: return null
        val beat = 60 / outgoing.tempo
        val bar = beat * 4
        // The last downbeat before the sound ends (half a beat of margin) ends the mix.
        val downbeats = outgoing.downbeats.filter { it <= soundEnd - beat * 0.5 }
        if (downbeats.size < 5) return null
        // The next song's first downbeat with sound, and enough of its beats to keep in step.
        val entry = incoming.downbeats.firstOrNull { it >= soundStart - beat * 0.25 } ?: return null
        val close = abs(ln(incomingRate)) <= ln(1 + CLOSE_TEMPO)
        for (bars in if (close) listOf(16, 8, 4) else listOf(8, 4)) {
            val endIndex = downbeats.size - 1
            val startIndex = endIndex - bars
            if (startIndex < 0) continue
            val outStart = downbeats[startIndex]
            val outEnd = downbeats[endIndex]
            val overlap = outEnd - outStart
            // The whole mix inside the analysed minute, on a steady grid, and at most 48 s long.
            if (outStart < outgoing.start + 2 || overlap < bar * bars * 0.9 || overlap > bar * bars * 1.1 || overlap > LONGEST_OVERLAP) continue
            // The song keeps at least its first half.
            if (outStart < duration * 0.5) continue
            val incomingNeeded = overlap / incomingRate
            if (entry + incomingNeeded > incoming.end) continue
            // The bass passes over in one beat, on the downbeat half way through.
            val swapStart = ((downbeats[startIndex + bars / 2] - outStart) / overlap).coerceIn(0.2, 0.8)
            val swapEnd = min(1.0, swapStart + beat / overlap)
            return TransitionPlan(
                style = TransitionPlan.Style.BEAT_MATCHED,
                outStart = outStart, outEnd = outEnd, inStart = entry, incomingRate = incomingRate,
                bars = bars,
                swapStart = swapStart, swapEnd = swapEnd,
                // The next song is fully in by the swap; the one leaving goes over the whole mix.
                fadeInFrom = 0.0, fadeIn = swapStart, fadeOutFrom = 0.0,
                filterOut = 0.75,
                beatLength = beat,
            )
        }
        return null
    }

    /**
     * A crossfade on the song's ending, as the iPhone's: into its own fade-out when it has one
     * (6 to 12 s, the next song fully in within 3 s), otherwise 8 s (more under a quiet intro); the
     * next song starts on a downbeat when this one has a beat, the bass passing over and this song
     * filtered away.
     */
    private fun blend(
        outgoing: WindowAnalysis, duration: Double, soundEnd: Double, incoming: WindowAnalysis, soundStart: Double,
    ): TransitionPlan {
        val step = WindowAnalysis.ENERGY_STEP
        val end = soundEnd
        val inStart = max(0.0, soundStart - 0.01)
        // How long the song has been fading: back from its end to the last moment at nearly full loudness.
        val body = bodyLoudness(outgoing, end)
        var fadeStart = end
        var time = end - 1
        while (time >= max(outgoing.start, end - 20)) {
            if (outgoing.level(time) >= body - 3) break
            fadeStart = time
            time -= step
        }
        val fade = end - fadeStart
        // A quiet start of the next song can come in earlier, under this one's ending.
        val incomingBody = bodyLoudness(incoming, incoming.end)
        var softIntro = 0.0
        var probe = soundStart
        while (probe < soundStart + 6 && incoming.level(probe) < incomingBody - 10) {
            softIntro += step
            probe += step
        }
        val rhythmic = outgoing.hasBeat
        val style = if (fade >= 4) TransitionPlan.Style.FADE else TransitionPlan.Style.BLEND
        var overlap = if (style == TransitionPlan.Style.FADE) min(12.0, max(6.0, fade)) else min(12.0, 8 + softIntro)
        // Short songs keep their first ten seconds and half; the overlap stays inside the analysed minute.
        overlap = min(overlap, max(0.0, end - max(outgoing.start + 1, duration * 0.5)))
        if (overlap < 1) return TransitionPlan(TransitionPlan.Style.GAPLESS, end, end, inStart, 1.0)
        var outStart = end - overlap
        if (rhythmic) {
            // On a steady beat, the next song starts on a downbeat: the one giving at least that overlap.
            val earliest = max(outgoing.start + 1, duration * 0.5)
            outgoing.downbeats.lastOrNull { it <= outStart && it >= earliest }?.let { outStart = it }
        }
        val length = end - outStart
        return TransitionPlan(
            style = style,
            outStart = outStart, outEnd = end, inStart = inStart, incomingRate = 1.0,
            swapStart = if (rhythmic) 0.45 else null, swapEnd = if (rhythmic) 0.55 else null,
            fadeInFrom = 0.0, fadeIn = if (style == TransitionPlan.Style.FADE) min(1.0, 3 / length) else 0.5,
            fadeOutFrom = 0.0,
            filterOut = if (rhythmic) 0.4 else null,
            beatLength = if (outgoing.tempo > 0) 60 / outgoing.tempo else 0.5,
        )
    }

    /** The song's loud parts (the 80th percentile of its level) over the 30 s before [end]. */
    private fun bodyLoudness(analysis: WindowAnalysis, end: Double): Float {
        val step = WindowAnalysis.ENERGY_STEP
        if (analysis.energy.isEmpty()) return -90f
        val endIndex = ((end - analysis.start) / step).toInt().coerceIn(1, analysis.energy.size)
        val from = max(0, endIndex - (30 / step).toInt())
        val body = analysis.energy.subList(from, endIndex).sorted()
        return body[(body.size * 0.8).toInt().coerceAtMost(body.size - 1)]
    }
}
