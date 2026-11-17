package com.onda.seaglass.audio.karaoke

/** The karaoke's mode, as on the iPhone: the song as it is, without its voice, or its voice alone. */
enum class KaraokeMode {
    OFF, NO_VOCALS, VOCALS_ONLY;

    /** The vocals' and the rest's volumes; [amount] 1 removes the other part completely. */
    fun gains(amount: Float): Pair<Float, Float> = when (this) {
        OFF -> 1f to 1f
        NO_VOCALS -> (1 - amount) to 1f
        VOCALS_ONLY -> 1f to (1 - amount)
    }
}

/** What the audio thread reads of the karaoke's settings: plain volatile numbers, no locks. */
object KaraokeLive {
    @Volatile var on = false
    @Volatile var vocalsGain = 1f
    @Volatile var instrumentalGain = 1f
}

/**
 * The karaoke in one deck's audio, on the audio thread, where the deck hands out its frames (so every
 * path after it, plain playback, AutoMix's tempo glides, Tempo's time stretch and both decks of a
 * crossfade, plays the karaoke'd sound; the equalizer and the volume come later). Where the song's
 * stems are ready it replaces the deck's samples with `vocalsGain · vocals + instrumentalGain ·
 * (song − vocals)`, both from the stems' own decode of the song, which has the deck's frames exactly.
 * It comes in and goes out over 20 ms (so a song that isn't separated yet, or a switch, never
 * clicks), and the gains change over 20 ms too. Allocates and locks nothing.
 */
class KaraokeTap(val videoId: String) {
    /** The song's stems, once decoded (set from another thread). */
    @Volatile var stems: KaraokeStems? = null
    /**
     * Set by [Karaoke] when the separation is far enough ahead of where the song plays to stay ahead to
     * the end, so the karaoke doesn't come and go with the pieces separated.
     */
    @Volatile var enabled = false

    // Audio thread only.
    private var blend = 0f
    private var vocals = 1f
    private var instrumental = 1f

    /**
     * Applies the karaoke to [frames] interleaved stereo frames of [buffer] from frame [offset], the
     * first of which is the song's frame [firstFrame].
     */
    fun process(buffer: FloatArray, offset: Int, frames: Int, firstFrame: Long) {
        val on = KaraokeLive.on
        val stems = stems
        val active = on && enabled && stems != null && stems.revision >= 0 && firstFrame >= 0 && stems.isReady(firstFrame, frames)
        if (!active && blend == 0f) {
            // Gains follow the settings even while not heard, so a change doesn't jump when it comes in.
            vocals = KaraokeLive.vocalsGain
            instrumental = KaraokeLive.instrumentalGain
            return
        }
        if (stems == null) return
        val target = if (active) 1f else 0f
        val vocalsTarget = KaraokeLive.vocalsGain
        val instrumentalTarget = KaraokeLive.instrumentalGain
        for (i in 0 until frames) {
            blend = step(blend, target)
            vocals = step(vocals, vocalsTarget)
            instrumental = step(instrumental, instrumentalTarget)
            val frame = firstFrame + i
            if (frame < 0 || frame >= stems.frames) continue
            val f = frame.toInt()
            val index = (offset + i) * 2
            val vl = stems.left(f)
            val vr = stems.right(f)
            val l = vocals * vl + instrumental * (stems.songLeft(f) - vl)
            val r = vocals * vr + instrumental * (stems.songRight(f) - vr)
            buffer[index] = buffer[index] * (1 - blend) + l * blend
            buffer[index + 1] = buffer[index + 1] * (1 - blend) + r * blend
        }
    }

    /** One frame's step toward [target]: 20 ms from one end to the other. */
    private fun step(value: Float, target: Float): Float =
        if (value < target) minOf(target, value + STEP) else maxOf(target, value - STEP)

    private companion object {
        const val STEP = 1f / 960
    }
}
