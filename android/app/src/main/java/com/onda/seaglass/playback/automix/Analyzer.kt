package com.onda.seaglass.playback.automix

import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.log10
import kotlin.math.log2
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * What AutoMix knows of one end of a song (its first or last minute): the tempo, where the beats
 * and the bars' downbeats fall, and where the sound starts and ends. Times are in the song's own
 * seconds.
 */
data class WindowAnalysis(
    val start: Double,
    val end: Double,
    /** Beats per minute; 0 when there's no steady beat. */
    val tempo: Double,
    val beats: List<Double>,
    val downbeats: List<Double>,
    /** How sure the beat is: 0 none … 1 a drum machine. */
    val confidence: Double,
    /** The first and last moments with sound (silence at the edges left out). */
    val soundStart: Double,
    val soundEnd: Double,
    /** Level in dB, one value every [ENERGY_STEP] seconds from [start]. */
    val energy: List<Float>,
) {
    val hasBeat: Boolean get() = tempo > 0 && confidence >= MIN_CONFIDENCE && beats.size >= 16

    /** The level at a time, in dB. */
    fun level(at: Double): Float {
        if (energy.isEmpty()) return -90f
        val index = ((at - start) / ENERGY_STEP).toInt().coerceIn(0, energy.size - 1)
        return energy[index]
    }

    fun toJson(): JSONObject = JSONObject()
        .put("start", start).put("end", end).put("tempo", tempo).put("confidence", confidence)
        .put("soundStart", soundStart).put("soundEnd", soundEnd)
        .put("beats", JSONArray(beats.map { (it * 1000).roundToInt() }))
        .put("downbeats", JSONArray(downbeats.map { (it * 1000).roundToInt() }))
        .put("energy", JSONArray(energy.map { it.roundToInt() }))

    companion object {
        const val ENERGY_STEP = 0.25
        const val MIN_CONFIDENCE = 0.35

        fun fromJson(json: JSONObject): WindowAnalysis {
            fun times(key: String) = json.getJSONArray(key).let { a -> (0 until a.length()).map { a.getInt(it) / 1000.0 } }
            val energy = json.getJSONArray("energy").let { a -> (0 until a.length()).map { a.getInt(it).toFloat() } }
            return WindowAnalysis(
                json.getDouble("start"), json.getDouble("end"), json.getDouble("tempo"),
                times("beats"), times("downbeats"), json.getDouble("confidence"),
                json.getDouble("soundStart"), json.getDouble("soundEnd"), energy,
            )
        }
    }
}

/**
 * Beat tracking in the way of Ellis (2007): an onset envelope from the spectral flux, the tempo
 * from its autocorrelation (weighted towards 120 BPM), the beats by dynamic programming (a beat
 * where the onsets are strong, about one period after the previous one), the bars' first beats
 * where the bass hits hardest. Runs on mono samples at [SAMPLE_RATE].
 */
object Analyzer {
    const val SAMPLE_RATE = 12_000
    private const val HOP = 120 // 100 frames a second
    private const val FFT = 1024
    private const val FRAME_RATE = SAMPLE_RATE.toDouble() / HOP

    fun analyze(samples: FloatArray, offset: Double): WindowAnalysis {
        val frames = max(0, (samples.size - FFT) / HOP)
        val duration = samples.size.toDouble() / SAMPLE_RATE
        if (frames < 200) return silent(offset, duration)

        // Spectral flux (all of it, and below 150 Hz for the kick) and the level of each frame.
        val window = FloatArray(FFT) { (0.5 - 0.5 * cos(2 * PI * it / FFT)).toFloat() }
        val re = DoubleArray(FFT)
        val im = DoubleArray(FFT)
        val bins = FFT / 2
        val maxBin = (4_000.0 * FFT / SAMPLE_RATE).toInt()
        val bassBin = (150.0 * FFT / SAMPLE_RATE).toInt()
        var previous = DoubleArray(bins)
        val flux = DoubleArray(frames)
        val bass = DoubleArray(frames)
        val levels = DoubleArray(frames)
        for (f in 0 until frames) {
            val base = f * HOP
            var power = 0.0
            for (i in 0 until FFT) {
                val s = samples[base + i]
                re[i] = (s * window[i]).toDouble()
                im[i] = 0.0
                if (i < HOP) power += s * s
            }
            levels[f] = 10 * log10(power / HOP + 1e-10)
            fft(re, im)
            val current = DoubleArray(bins)
            var total = 0.0
            var low = 0.0
            for (k in 1 until maxBin) {
                val magnitude = ln(1 + 100 * sqrt(re[k] * re[k] + im[k] * im[k]))
                current[k] = magnitude
                val rise = magnitude - previous[k]
                if (rise > 0) {
                    total += rise
                    if (k <= bassBin) low += rise
                }
            }
            flux[f] = total
            bass[f] = low
            previous = current
        }
        val onset = normalize(flux)
        val kick = normalize(bass)

        val (period, confidence) = tempo(onset)
        val beats = if (period > 0) clean(track(onset, period)) else IntArray(0)
        // The flux of a frame rises most when an attack is three quarters into its window (where
        // the Hann window grows fastest from one frame to the next); a parabola through the
        // neighbouring onsets places the beat between frames.
        val beatTimes = beats.map { f ->
            val a = if (f > 0) onset[f - 1] else 0.0
            val b = onset[f]
            val c = if (f + 1 < onset.size) onset[f + 1] else 0.0
            val shift = if (a - 2 * b + c < 0) (0.5 * (a - c) / (a - 2 * b + c)).coerceIn(-0.5, 0.5) else 0.0
            offset + ((f + shift) * HOP + 0.75 * FFT) / SAMPLE_RATE
        }
        // Downbeats: of the four places in a bar, the one whose beats have the strongest kick.
        var phase = 0
        if (beats.size >= 8) {
            var best = -1.0
            for (p in 0 until 4) {
                var sum = 0.0
                var count = 0
                for (i in p until beats.size step 4) {
                    sum += kick[beats[i]] + 0.5 * onset[beats[i]]
                    count++
                }
                val score = if (count > 0) sum / count else 0.0
                if (score > best) {
                    best = score
                    phase = p
                }
            }
        }
        val downbeats = beatTimes.filterIndexed { index, _ -> index % 4 == phase }

        // Where the sound is: within 35 dB of the window's loud parts.
        val sorted = levels.sorted()
        val loud = sorted[(sorted.size * 0.9).toInt().coerceAtMost(sorted.size - 1)]
        val threshold = loud - 35
        val first = levels.indexOfFirst { it > threshold }.coerceAtLeast(0)
        val last = levels.indexOfLast { it > threshold }.coerceAtLeast(first)
        val step = (WindowAnalysis.ENERGY_STEP * FRAME_RATE).toInt()
        val energy = (0 until frames step step).map { start ->
            val end = min(frames, start + step)
            var power = 0.0
            for (f in start until end) power += Math.pow(10.0, levels[f] / 10)
            (10 * log10(power / (end - start) + 1e-10)).toFloat()
        }
        // The tempo from the beats themselves (a straight line through them, least squares): far
        // more exact than the autocorrelation's peak, which matters over eight bars.
        var tempo = if (period > 0) 60 * FRAME_RATE / period else 0.0
        if (beatTimes.size >= 8) {
            val n = beatTimes.size
            val meanIndex = (n - 1) / 2.0
            val meanTime = beatTimes.average()
            var num = 0.0
            var den = 0.0
            for (i in 0 until n) {
                num += (i - meanIndex) * (beatTimes[i] - meanTime)
                den += (i - meanIndex) * (i - meanIndex)
            }
            val fitted = num / den
            if (fitted > 0 && abs(60 / fitted - tempo) < tempo * 0.05) tempo = 60 / fitted
        }
        return WindowAnalysis(
            start = offset,
            end = offset + duration,
            tempo = tempo,
            beats = beatTimes,
            downbeats = downbeats,
            confidence = confidence,
            soundStart = offset + first / FRAME_RATE,
            soundEnd = offset + (last + 1) / FRAME_RATE,
            energy = energy,
        )
    }

    private fun silent(offset: Double, duration: Double) =
        WindowAnalysis(offset, offset + duration, 0.0, emptyList(), emptyList(), 0.0, offset, offset + duration, emptyList())

    /** Onsets above their local average, in units of their spread. */
    private fun normalize(values: DoubleArray): DoubleArray {
        val n = values.size
        val out = DoubleArray(n)
        val half = FRAME_RATE.toInt() / 2
        var sum = 0.0
        val prefix = DoubleArray(n + 1)
        for (i in 0 until n) prefix[i + 1] = prefix[i] + values[i]
        for (i in 0 until n) {
            val a = max(0, i - half)
            val b = min(n, i + half + 1)
            val mean = (prefix[b] - prefix[a]) / (b - a)
            out[i] = max(0.0, values[i] - mean)
            sum += out[i] * out[i]
        }
        val spread = sqrt(sum / n) + 1e-9
        for (i in 0 until n) out[i] /= spread
        return out
    }

    /** The beat period in frames (with a fraction), and how clear it is. */
    private fun tempo(onset: DoubleArray): Pair<Double, Double> {
        val minLag = (60 * FRAME_RATE / 180).toInt() // 180 BPM
        val maxLag = (60 * FRAME_RATE / 70).toInt() + 1 // 70 BPM
        val n = onset.size
        if (n < maxLag * 4) return 0.0 to 0.0
        val raw = DoubleArray(maxLag * 2 + 2)
        for (lag in minLag / 2..min(maxLag * 2 + 1, n - 1)) {
            var sum = 0.0
            for (t in 0 until n - lag) sum += onset[t] * onset[t + lag]
            raw[lag] = sum / (n - lag)
        }
        var bestLag = 0
        var bestScore = 0.0
        for (lag in minLag..maxLag) {
            val bpm = 60 * FRAME_RATE / lag
            // A beat also shows at twice its period; prefer tempos near 120 BPM, as listeners do.
            val weight = exp(-0.5 * (log2(bpm / 120) / 0.9).let { it * it })
            val score = (raw[lag] + 0.5 * raw[lag * 2] + 0.25 * raw[lag / 2]) * weight
            if (score > bestScore) {
                bestScore = score
                bestLag = lag
            }
        }
        if (bestLag == 0) return 0.0 to 0.0
        // Parabolic interpolation around the peak.
        val a = raw[bestLag - 1]
        val b = raw[bestLag]
        val c = raw[bestLag + 1]
        val shift = if (a - 2 * b + c != 0.0) 0.5 * (a - c) / (a - 2 * b + c) else 0.0
        val period = bestLag + shift.coerceIn(-0.5, 0.5)
        val mean = (minLag..maxLag).map { raw[it] }.average()
        // How clear the pulse is: at its period, or at twice it (a half-tempo song heard at double).
        val peak = max(raw[bestLag], raw[min(raw.size - 1, bestLag * 2)])
        val confidence = ((peak / (mean + 1e-9) - 1) / 2).coerceIn(0.0, 1.0)
        return period to confidence
    }

    /** Beats by dynamic programming: strong onsets about one period apart. */
    private fun track(onset: DoubleArray, period: Double): IntArray {
        val n = onset.size
        val score = DoubleArray(n)
        val back = IntArray(n) { -1 }
        val tightness = 100.0
        val lo = (period / 2).roundToInt()
        val hi = (period * 2).roundToInt()
        for (t in 0 until n) {
            var best = 0.0
            var from = -1
            for (prev in max(0, t - hi)..t - lo) {
                if (prev < 0) continue
                val gap = (t - prev) / period
                val value = score[prev] - tightness * ln(gap).let { it * it }
                if (from < 0 || value > best) {
                    best = value
                    from = prev
                }
            }
            score[t] = onset[t] + if (from >= 0 && best > 0) best else 0.0
            back[t] = if (from >= 0 && best > 0) from else -1
        }
        // The last beat: the best score in the last period.
        var end = n - 1
        for (t in max(0, n - period.roundToInt()) until n) if (score[t] > score[end]) end = t
        val beats = ArrayList<Int>()
        var t = end
        while (t >= 0) {
            beats += t
            t = back[t]
        }
        beats.reverse()
        return beats.toIntArray()
    }

    /**
     * Drops the beats off the grid at the window's edges (a pickup, a fill, the first hit of a song
     * before its beat starts): there the tracker follows onsets that aren't the pulse, and a bar
     * counted from one of them would be out by a fraction of a beat.
     */
    private fun clean(beats: IntArray): IntArray {
        if (beats.size < 8) return beats
        val gaps = beats.toList().zipWithNext { a, b -> b - a }
        val median = gaps.sorted()[gaps.size / 2].toDouble()
        fun regular(a: Int, b: Int) = abs((b - a) - median) <= median * 0.1
        var first = 0
        while (first < beats.size - 4 && !(regular(beats[first], beats[first + 1]) && regular(beats[first + 1], beats[first + 2]))) first++
        var last = beats.size - 1
        while (last > first + 4 && !(regular(beats[last - 1], beats[last]) && regular(beats[last - 2], beats[last - 1]))) last--
        return beats.copyOfRange(first, last + 1)
    }

    /** In-place radix-2 FFT. */
    private fun fft(re: DoubleArray, im: DoubleArray) {
        val n = re.size
        var j = 0
        for (i in 1 until n) {
            var bit = n shr 1
            while (j and bit != 0) {
                j = j xor bit
                bit = bit shr 1
            }
            j = j xor bit
            if (i < j) {
                var tmp = re[i]; re[i] = re[j]; re[j] = tmp
                tmp = im[i]; im[i] = im[j]; im[j] = tmp
            }
        }
        var length = 2
        while (length <= n) {
            val angle = -2 * PI / length
            val wr = cos(angle)
            val wi = sin(angle)
            var start = 0
            while (start < n) {
                var cr = 1.0
                var ci = 0.0
                for (k in 0 until length / 2) {
                    val a = start + k
                    val b = a + length / 2
                    val tr = re[b] * cr - im[b] * ci
                    val ti = re[b] * ci + im[b] * cr
                    re[b] = re[a] - tr
                    im[b] = im[a] - ti
                    re[a] += tr
                    im[a] += ti
                    val next = cr * wr - ci * wi
                    ci = cr * wi + ci * wr
                    cr = next
                }
                start += length
            }
            length = length shl 1
        }
    }
}
