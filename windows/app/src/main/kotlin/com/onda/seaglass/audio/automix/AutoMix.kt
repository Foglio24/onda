package com.onda.seaglass.audio.automix

import com.onda.seaglass.audio.ByteSource
import com.onda.seaglass.audio.Decoder
import com.onda.seaglass.core.Paths
import org.json.JSONObject
import java.io.File
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/** What AutoMix knows of a song: its length and both ends. */
data class SongAnalysis(val id: String, val duration: Double, val head: WindowAnalysis, val tail: WindowAnalysis) {
    fun toJson(): JSONObject = JSONObject().put("id", id).put("duration", duration).put("head", head.toJson()).put("tail", tail.toJson())

    companion object {
        fun fromJson(json: JSONObject): SongAnalysis? = runCatching {
            SongAnalysis(json.getString("id"), json.getDouble("duration"), WindowAnalysis.fromJson(json.getJSONObject("head")), WindowAnalysis.fromJson(json.getJSONObject("tail")))
        }.getOrNull()
    }
}

/**
 * AutoMix on Windows: each song's first and last minute analysed (tempo, beats, bars, where the
 * sound starts and ends, the level; the Android app's analyzer), kept on disk, and the passage
 * from one song to the next planned by the Android app's planner. The engine plays the plan live
 * on its two decks ([Transition]), sample by sample.
 */
object AutoMix {
    /** The part of each end analysed: enough for a mix of 32 bars at up to about 100 BPM. */
    private const val WINDOW = 80.0
    private val directory by lazy { File(Paths.cache, "AutoMix").apply { mkdirs() } }

    private fun safeName(id: String): String? = when {
        Paths.isVideoId(id) -> id
        id.startsWith("local:") && id.drop(6).all { it.isLetterOrDigit() } -> "local-" + id.drop(6)
        else -> null
    }

    /** An end's last 80 seconds ("-w80"), as kept since 1.5.0. */
    private fun file(id: String): File? = safeName(id)?.let { File(directory, "$it-w80.json") }

    /** What earlier versions kept: 60 seconds. Still read (a 60 s window plans everything but a 32-bar mix). */
    private fun oldFile(id: String): File? = safeName(id)?.let { File(directory, "$it.json") }

    fun known(id: String): SongAnalysis? =
        listOfNotNull(file(id), oldFile(id)).firstNotNullOfOrNull { f -> runCatching { SongAnalysis.fromJson(JSONObject(f.readText())) }.getOrNull() }

    /** Whether the analysis covers the whole window (or the whole song, when it is shorter). */
    private fun isFull(analysis: SongAnalysis) = analysis.tail.end - analysis.tail.start >= minOf(WINDOW, analysis.duration) - 1.0

    fun analyze(id: String, source: () -> ByteSource): SongAnalysis? = analyze(id, false, source)

    /**
     * Analyses both ends of a song from its bytes (only the parts needed are read). With [full] (a
     * "Lunga" mix) an analysis of only 60 seconds, as earlier versions kept, is made again.
     */
    fun analyze(id: String, full: Boolean, source: () -> ByteSource): SongAnalysis? {
        known(id)?.takeIf { !full || isFull(it) }?.let { return it }
        val analysis = runCatching {
            val (duration, head) = Decoder(source()).use { decoder -> decoder.duration to window(decoder, 0.0) }
            if (duration <= 0) return@runCatching null
            val tailStart = maxOf(0.0, duration - WINDOW)
            val tail = Decoder(source()).use { decoder ->
                decoder.seek(tailStart)
                window(decoder, tailStart)
            }
            SongAnalysis(id, duration, head, tail)
        }.getOrNull() ?: return null
        file(id)?.let { runCatching { it.writeText(analysis.toJson().toString()) } }
        // The new analysis replaces the old file's.
        oldFile(id)?.let { runCatching { it.delete() } }
        return analysis
    }

    /** [WINDOW] seconds from where the decoder is, as mono at the analyzer's rate, analysed. */
    private fun window(decoder: Decoder, offset: Double): WindowAnalysis {
        val factor = Decoder.RATE / Analyzer.SAMPLE_RATE
        val out = FloatArray((WINDOW * Analyzer.SAMPLE_RATE).toInt())
        val block = FloatArray(4096 * 2)
        var produced = 0
        var accumulator = 0f
        var count = 0
        while (produced < out.size) {
            val frames = decoder.read(block, 4096)
            if (frames == 0) break
            for (i in 0 until frames) {
                // Mono, then the average of each four samples (a low-pass enough for beat tracking).
                accumulator += (block[i * 2] + block[i * 2 + 1]) * 0.5f
                if (++count == factor) {
                    if (produced < out.size) out[produced++] = accumulator / factor
                    accumulator = 0f
                    count = 0
                }
            }
        }
        return Analyzer.analyze(if (produced == out.size) out else out.copyOf(produced), offset)
    }

    fun plan(outgoing: SongAnalysis, incoming: SongAnalysis, options: MixOptions = MixOptions.LEGACY): TransitionPlan =
        Planner.plan(outgoing.tail, outgoing.duration, incoming.head, options)
}

/**
 * A [TransitionPlan] as the audio thread plays it: everything worked out beforehand, the levels
 * written into an array it owns, nothing allocated. A beat-matched mix goes as on the iPhone: the
 * two songs meet halfway between their tempos (each changing by at most 12 %). Over the 16 beats
 * before the mix the outgoing song glides to that tempo ([rateBefore]); during the mix both play at
 * it, so their beats stay together ([outgoingRate], [incomingRate]); over the 16 beats after it the
 * incoming song glides back to its own tempo ([rateAfter]), then plays untouched.
 */
class Transition(val plan: TransitionPlan, outgoingTempo: Double) {
    val outStart = plan.outStart
    val outEnd = plan.outEnd
    private val matched = plan.style == TransitionPlan.Style.BEAT_MATCHED && outgoingTempo > 0 && plan.incomingRate > 0
    /** The rates of the two songs while together: the incoming one's over the outgoing one's is the plan's ratio. */
    val mixOutgoingRate = if (matched) 1 / sqrt(plan.incomingRate) else 1.0
    val mixIncomingRate = if (matched) sqrt(plan.incomingRate) else 1.0
    /** Where (in the outgoing song) its glide to the meeting tempo starts: 16 of its beats before the mix. */
    val glideStart = if (matched) maxOf(0.0, outStart - 16 * plan.beatLength) else outStart
    /** How long (in the incoming song) its glide back to its own tempo lasts: 16 of its own beats. */
    val settleLength = if (matched && mixIncomingRate != 1.0) 16 * plan.beatLength * plan.incomingRate else 0.0

    fun progress(outgoingTime: Double): Double = plan.progress(outgoingTime)

    /**
     * The outgoing song's rate at [position] before the mix: 1, then gliding to the meeting tempo.
     * A plan that arrived after [glideStart] glides from where the song was then ([from]), shorter.
     */
    fun rateBefore(position: Double, from: Double = glideStart): Double {
        val start = maxOf(glideStart, from)
        if (!matched || position <= start) return 1.0
        if (position >= outStart || start >= outStart) return mixOutgoingRate
        val x = (position - start) / (outStart - start)
        return 1.0 + (mixOutgoingRate - 1.0) * (x * x * (3 - 2 * x))
    }

    fun outgoingRate(p: Double): Double = mixOutgoingRate
    fun incomingRate(p: Double): Double = mixIncomingRate

    /**
     * The incoming song's rate [played] seconds of it after the mix: from the mix's rate back to 1,
     * exactly 1 once the glide is over (so the song then plays untouched, see
     * [com.onda.seaglass.audio.Deck.readAt]).
     */
    fun rateAfter(played: Double): Double {
        if (settleLength <= 0 || played >= settleLength || played < 0) return 1.0
        val x = played / settleLength
        return mixIncomingRate + (1.0 - mixIncomingRate) * (x * x * (3 - 2 * x))
    }

    /**
     * The levels at progress [p], into [into]: outgoing volume, incoming volume, outgoing bass
     * cut, incoming bass cut, outgoing high-pass (as [TransitionPlan.levels], without allocating).
     */
    fun levels(p: Double, into: FloatArray) {
        val x = p.coerceIn(0.0, 1.0)
        fun ramp(from: Double, to: Double) = if (to > from) ((x - from) / (to - from)).coerceIn(0.0, 1.0) else if (x >= from) 1.0 else 0.0
        val comeIn = ramp(plan.fadeInFrom, plan.fadeIn)
        val goOut = ramp(plan.fadeOutFrom, 1.0)
        val swapStart = plan.swapStart
        val swapEnd = plan.swapEnd
        var swap = 0.0
        if (swapStart != null && swapEnd != null) {
            val s = ramp(swapStart, swapEnd)
            swap = s * s * (3 - 2 * s)
        }
        var highPass = 0.0
        val filterOut = plan.filterOut
        if (filterOut != null && x > filterOut) {
            val h = ramp(filterOut, 1.0)
            highPass = h * h * (3 - 2 * h)
        }
        val hasSwap = swapStart != null && swapEnd != null
        into[0] = cos(goOut * PI / 2).toFloat()
        into[1] = sin(comeIn * PI / 2).toFloat()
        into[2] = if (hasSwap) (1 - cos(swap * PI / 2)).toFloat() else 0f
        into[3] = if (hasSwap) (1 - sin(swap * PI / 2)).toFloat() else 0f
        into[4] = highPass.toFloat()
    }
}
