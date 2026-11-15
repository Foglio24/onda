package com.onda.seaglass.audio

/**
 * Plays a song faster or slower with its pitch kept (Tempo's key lock, as on the iPhone), by
 * WSOLA: overlapping windows of the song are laid one after the other at the output's pace, each
 * taken from where the song would be at that speed, moved by up to [TOLERANCE] samples to where it
 * best continues the window before (so the waveform never breaks). For the audio thread: every
 * buffer is allocated here, once.
 */
class TimeStretch {
    /** Where the song's frames come from (no boxing: called on the audio thread). */
    fun interface Frames {
        /** Up to [max] frames into [into] from frame [offset]; 0 when none yet. */
        fun read(into: FloatArray, offset: Int, max: Int): Int
    }

    companion object {
        /** Window length (~43 ms at 48 kHz) and the output's step: half a window, so Hann windows sum to one. */
        const val WINDOW = 2048
        const val HOP = WINDOW / 2
        const val TOLERANCE = 512
        /** The search compares every fourth sample of the overlap, mono. */
        private const val STRIDE = 4
        private const val INPUT = WINDOW * 4 + TOLERANCE * 2
    }

    private val hann = FloatArray(WINDOW) { (0.5 - 0.5 * Math.cos(2 * Math.PI * it / WINDOW)).toFloat() }
    /** Song frames (stereo) from [inputStart] on. */
    private val input = FloatArray(INPUT * 2)
    private var inputFrames = 0
    private var inputStart = 0L
    /** Where the next window should come from, in song frames, and where the last one was taken. */
    private var analysis = 0.0
    private var previous = -1L
    /** Overlap-add of the windows; the first [ready] frames are finished, from [readyOffset]. */
    private val overlap = FloatArray(WINDOW * 2)
    private val ready = FloatArray(HOP * 2)
    private var readyFrames = 0
    private var readyOffset = 0

    fun reset() {
        inputFrames = 0
        inputStart = 0
        analysis = 0.0
        previous = -1
        overlap.fill(0f)
        readyFrames = 0
        readyOffset = 0
    }

    /**
     * Fills [into] with up to [frames] frames of the song at [tempo] (1.15: 15 % faster), reading
     * the song through [source] (frames at its own speed).
     */
    fun process(into: FloatArray, frames: Int, tempo: Double, source: Frames): Int {
        var out = 0
        while (out < frames) {
            if (readyOffset < readyFrames) {
                val count = minOf(frames - out, readyFrames - readyOffset)
                System.arraycopy(ready, readyOffset * 2, into, out * 2, count * 2)
                readyOffset += count
                out += count
                continue
            }
            if (!step(tempo, source)) break
        }
        return out
    }

    /** Lays one more window; false when the song's frames aren't there yet. */
    private fun step(tempo: Double, source: Frames): Boolean {
        val target = Math.round(analysis)
        // The natural continuation of the last window, which the new one should match.
        val natural = if (previous < 0) target else previous + HOP
        val needEnd = maxOf(target + TOLERANCE + WINDOW, natural + WINDOW) + 1
        if (!fill(needEnd, source)) return false
        var best = target
        if (previous >= 0) {
            var bestScore = Double.NEGATIVE_INFINITY
            var delta = -TOLERANCE
            while (delta <= TOLERANCE) {
                val candidate = target + delta
                if (candidate >= inputStart) {
                    var score = 0.0
                    var k = 0
                    while (k < HOP) {
                        val a = frameMono(natural + k)
                        val b = frameMono(candidate + k)
                        score += a * b
                        k += STRIDE
                    }
                    if (score > bestScore) {
                        bestScore = score
                        best = candidate
                    }
                }
                delta += STRIDE
            }
        }
        // Lay the window, hand out the finished half, move on.
        val offset = (best - inputStart).toInt()
        for (i in 0 until WINDOW) {
            val w = hann[i]
            overlap[i * 2] += input[(offset + i) * 2] * w
            overlap[i * 2 + 1] += input[(offset + i) * 2 + 1] * w
        }
        System.arraycopy(overlap, 0, ready, 0, HOP * 2)
        System.arraycopy(overlap, HOP * 2, overlap, 0, HOP * 2)
        for (i in HOP * 2 until WINDOW * 2) overlap[i] = 0f
        readyFrames = HOP
        readyOffset = 0
        previous = best
        analysis += HOP * tempo
        return true
    }

    private fun frameMono(at: Long): Float {
        val i = (at - inputStart).toInt()
        return input[i * 2] + input[i * 2 + 1]
    }

    /** Has the song's frames up to [end] (exclusive) in [input], dropping what's no longer needed. */
    private fun fill(end: Long, source: Frames): Boolean {
        // Frames before the earliest a window can still use are dropped.
        val keepFrom = minOf(Math.round(analysis) - TOLERANCE, if (previous >= 0) previous + HOP else Long.MAX_VALUE)
        val drop = (keepFrom - inputStart).toInt()
        if (drop > 0 && drop <= inputFrames) {
            System.arraycopy(input, drop * 2, input, 0, (inputFrames - drop) * 2)
            inputFrames -= drop
            inputStart += drop
        }
        while (inputStart + inputFrames < end) {
            val room = INPUT - inputFrames
            if (room <= 0) return false
            val got = source.read(input, inputFrames, room)
            if (got <= 0) return false
            inputFrames += got
        }
        return true
    }
}
