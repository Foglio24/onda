package com.onda.seaglass.playback.karaoke

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/**
 * A complex FFT of [n] points, where n is a power of two or three times one (6144 for the karaoke's
 * model): radix-2 transforms of the three interleaved thirds, combined. Not thread-safe.
 */
class Fft(val n: Int) {
    private val thirds = n % 3 == 0
    private val m = if (thirds) n / 3 else n
    private val bits = Integer.numberOfTrailingZeros(m)
    private val reversed = IntArray(m) { Integer.reverse(it) ushr (32 - bits) }
    // e^(-2πik/m) for the radix-2 stages, and e^(-2πik/n) for combining the thirds.
    private val cosM = FloatArray(m / 2) { cos(2 * PI * it / m).toFloat() }
    private val sinM = FloatArray(m / 2) { sin(2 * PI * it / m).toFloat() }
    private val cosN = FloatArray(n) { cos(2 * PI * it / n).toFloat() }
    private val sinN = FloatArray(n) { sin(2 * PI * it / n).toFloat() }
    private val partRe = Array(3) { FloatArray(m) }
    private val partIm = Array(3) { FloatArray(m) }

    init {
        require(m > 1 && m and (m - 1) == 0) { "$n points: a power of two, or three times one" }
    }

    /** The DFT of [re] and [im] in place; [inverse] for the inverse, unscaled (multiply by 1/n). */
    fun transform(re: FloatArray, im: FloatArray, inverse: Boolean = false) {
        if (!thirds) {
            radix2(re, im, inverse)
            return
        }
        for (r in 0..2) {
            val pr = partRe[r]
            val pi = partIm[r]
            for (j in 0 until m) {
                pr[j] = re[3 * j + r]
                pi[j] = im[3 * j + r]
            }
            radix2(pr, pi, inverse)
        }
        val sign = if (inverse) 1f else -1f
        val a0r = partRe[0]
        val a0i = partIm[0]
        val a1r = partRe[1]
        val a1i = partIm[1]
        val a2r = partRe[2]
        val a2i = partIm[2]
        for (k in 0 until n) {
            val j = k % m
            // W^k and W^2k, W = e^(∓2πi/n).
            val w1r = cosN[k]
            val w1i = sign * sinN[k]
            val k2 = (2 * k) % n
            val w2r = cosN[k2]
            val w2i = sign * sinN[k2]
            re[k] = a0r[j] + (w1r * a1r[j] - w1i * a1i[j]) + (w2r * a2r[j] - w2i * a2i[j])
            im[k] = a0i[j] + (w1r * a1i[j] + w1i * a1r[j]) + (w2r * a2i[j] + w2i * a2r[j])
        }
    }

    private fun radix2(re: FloatArray, im: FloatArray, inverse: Boolean) {
        for (i in 0 until m) {
            val j = reversed[i]
            if (j > i) {
                val tr = re[i]
                re[i] = re[j]
                re[j] = tr
                val ti = im[i]
                im[i] = im[j]
                im[j] = ti
            }
        }
        val sign = if (inverse) 1f else -1f
        var size = 2
        while (size <= m) {
            val half = size / 2
            val step = m / size
            var start = 0
            while (start < m) {
                for (k in 0 until half) {
                    val wr = cosM[k * step]
                    val wi = sign * sinM[k * step]
                    val a = start + k
                    val b = a + half
                    val tr = wr * re[b] - wi * im[b]
                    val ti = wr * im[b] + wi * re[b]
                    re[b] = re[a] - tr
                    im[b] = im[a] - ti
                    re[a] += tr
                    im[a] += ti
                }
                start += size
            }
            size *= 2
        }
    }
}
