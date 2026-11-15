package com.onda.seaglass.audio.automix

import com.onda.seaglass.audio.ByteSource
import com.onda.seaglass.audio.Decoder
import com.onda.seaglass.core.Paths
import org.json.JSONObject
import java.io.File
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

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
    private const val WINDOW = 60.0
    private val directory by lazy { File(Paths.cache, "AutoMix").apply { mkdirs() } }

    private fun file(id: String): File? {
        val safe = when {
            Paths.isVideoId(id) -> id
            id.startsWith("local:") && id.drop(6).all { it.isLetterOrDigit() } -> "local-" + id.drop(6)
            else -> return null
        }
        return File(directory, "$safe.json")
    }

    fun known(id: String): SongAnalysis? = file(id)?.let { runCatching { SongAnalysis.fromJson(JSONObject(it.readText())) }.getOrNull() }

    /** Analyses both ends of a song from its bytes (only the parts needed are read). */
    fun analyze(id: String, source: () -> ByteSource): SongAnalysis? {
        known(id)?.let { return it }
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

    fun plan(outgoing: SongAnalysis, incoming: SongAnalysis): TransitionPlan =
        Planner.plan(outgoing.tail, outgoing.duration, incoming.head)
}

/**
 * A [TransitionPlan] as the audio thread plays it: everything worked out beforehand, the levels
 * written into an array it owns, nothing allocated. In a beat-matched mix the tempo moves
 * gradually from the outgoing song's to the incoming one's across the mix, both songs following
 * it (their beats stay together): the outgoing one starts at its own speed, the incoming one ends
 * at its own, so nothing changes once the mix is over (as on the iPhone since 1.36.9).
 */
class Transition(val plan: TransitionPlan, outgoingTempo: Double) {
    val outStart = plan.outStart
    val outEnd = plan.outEnd
    private val matched = plan.style == TransitionPlan.Style.BEAT_MATCHED && outgoingTempo > 0 && plan.incomingRate > 0
    private val tempoOut = outgoingTempo
    /** The incoming song's tempo as heard against the outgoing one's (half or double already folded in). */
    private val tempoIn = if (matched) outgoingTempo / plan.incomingRate else 0.0

    fun progress(outgoingTime: Double): Double = plan.progress(outgoingTime)

    private fun tempo(p: Double): Double {
        val x = p.coerceIn(0.0, 1.0)
        return tempoOut + (tempoIn - tempoOut) * (x * x * (3 - 2 * x))
    }

    fun outgoingRate(p: Double): Double = if (matched) tempo(p) / tempoOut else 1.0
    /** Exactly 1 at the mix's end, so the song then plays untouched (see [com.onda.seaglass.audio.Deck.readAt]). */
    fun incomingRate(p: Double): Double = if (matched && p < 1.0) tempo(p) / tempoIn else 1.0

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
