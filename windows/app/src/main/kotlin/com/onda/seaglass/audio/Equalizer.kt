package com.onda.seaglass.audio

import com.onda.seaglass.core.Prefs
import com.onda.seaglass.core.tr
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONArray
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt

/** The equalizer's six bands, as in Spotify: a low shelf, four peaks and a high shelf. */
object EqualizerBands {
    val frequencies = doubleArrayOf(60.0, 150.0, 400.0, 1_000.0, 2_400.0, 15_000.0)
    val labels = listOf("60", "150", "400", "1K", "2.4K", "15K")
    const val COUNT = 6
    /** Decibels a band can be raised or lowered. */
    const val LIMIT = 12f
    /** Width of the four peaks: neighbouring bands overlap a little, so curves stay smooth. */
    const val Q = 1.0
}

/** Spotify's equalizer presets on the six bands, in decibels (the iPhone app's), plus the user's own. */
enum class EqualizerPreset(val key: String, val gains: FloatArray?) {
    FLAT("flat", floatArrayOf(0f, 0f, 0f, 0f, 0f, 0f)),
    ACOUSTIC("acoustic", floatArrayOf(4f, 3f, 1f, 1f, 2.5f, 2.5f)),
    BASS_BOOSTER("bassBooster", floatArrayOf(5.5f, 4f, 1.5f, 0f, 0f, 0f)),
    BASS_REDUCER("bassReducer", floatArrayOf(-5.5f, -4f, -1.5f, 0f, 0f, 0f)),
    CLASSICAL("classical", floatArrayOf(4f, 3f, 0f, -1f, 1.5f, 3.5f)),
    DANCE("dance", floatArrayOf(3.5f, 5f, 1f, -0.5f, 2.5f, 3f)),
    DEEP("deep", floatArrayOf(4.5f, 2f, 1.5f, 0f, -2f, -4.5f)),
    ELECTRONIC("electronic", floatArrayOf(4f, 3.5f, -0.5f, 0.5f, 1.5f, 4.5f)),
    HIP_HOP("hipHop", floatArrayOf(5f, 4f, 0.5f, -1f, 1f, 2.5f)),
    JAZZ("jazz", floatArrayOf(3.5f, 2.5f, 1f, -1.5f, 1f, 3.5f)),
    LATIN("latin", floatArrayOf(3.5f, 1.5f, -1.5f, -1.5f, 1.5f, 4f)),
    LOUDNESS("loudness", floatArrayOf(6f, 3f, 0f, -1f, 1f, 4f)),
    LOUNGE("lounge", floatArrayOf(-2.5f, -1f, 0f, 1.5f, 0.5f, 1.5f)),
    PIANO("piano", floatArrayOf(2f, 1f, 2f, 2.5f, 3f, 2.5f)),
    POP("pop", floatArrayOf(-1f, 0.5f, 2.5f, 3f, 1f, -1f)),
    RNB("rnb", floatArrayOf(3f, 6f, 2f, -1f, 1.5f, 3f)),
    ROCK("rock", floatArrayOf(4.5f, 3f, -0.5f, -1f, 1.5f, 4f)),
    SMALL_SPEAKERS("smallSpeakers", floatArrayOf(5f, 3.5f, 2f, 0.5f, -1f, -3.5f)),
    SPOKEN_WORD("spokenWord", floatArrayOf(-3f, -1f, 2f, 3.5f, 3.5f, 0f)),
    TREBLE_BOOSTER("trebleBooster", floatArrayOf(0f, 0f, 0f, 1.5f, 4f, 5.5f)),
    TREBLE_REDUCER("trebleReducer", floatArrayOf(0f, 0f, 0f, -1.5f, -4f, -5.5f)),
    VOCAL_BOOSTER("vocalBooster", floatArrayOf(-1.5f, -2f, 1.5f, 3.5f, 3f, 0f)),
    CUSTOM("custom", null);

    val title: String
        get() = when (this) {
            FLAT -> tr("Piatto")
            ACOUSTIC -> tr("Acustica")
            BASS_BOOSTER -> tr("Più bassi")
            BASS_REDUCER -> tr("Meno bassi")
            CLASSICAL -> tr("Classica")
            DANCE -> tr("Dance")
            DEEP -> tr("Profondo")
            ELECTRONIC -> tr("Elettronica")
            HIP_HOP -> tr("Hip-Hop")
            JAZZ -> tr("Jazz")
            LATIN -> tr("Latino")
            LOUDNESS -> tr("Loudness")
            LOUNGE -> tr("Lounge")
            PIANO -> tr("Pianoforte")
            POP -> tr("Pop")
            RNB -> tr("R&B")
            ROCK -> tr("Rock")
            SMALL_SPEAKERS -> tr("Altoparlanti piccoli")
            SPOKEN_WORD -> tr("Parlato")
            TREBLE_BOOSTER -> tr("Più alti")
            TREBLE_REDUCER -> tr("Meno alti")
            VOCAL_BOOSTER -> tr("Più voce")
            CUSTOM -> tr("Personalizzato")
        }
}

/**
 * The equalizer's settings (the player's equalizer button, or Settings), saved between launches
 * with the Android app's keys. The audio thread follows changes right away through [version] and
 * [activeGains], read once per block.
 */
object Equalizer {
    data class State(val isOn: Boolean = false, val preset: EqualizerPreset = EqualizerPreset.FLAT, val gains: FloatArray = FloatArray(6), val custom: FloatArray = FloatArray(6))

    private val _state = MutableStateFlow(State())
    val state: StateFlow<State> = _state

    /** Bumped on every change, for the audio thread. */
    @Volatile var version = 0
        private set
    /** What the audio thread uses: null when off or flat. */
    @Volatile var activeGains: FloatArray? = null
        private set

    fun load() {
        val store = Prefs.store
        val preset = EqualizerPreset.entries.firstOrNull { it.key == store.string("audio.equalizer.preset") } ?: EqualizerPreset.FLAT
        val custom = runCatching {
            val array = store.json("audio.equalizer.custom") as? JSONArray ?: JSONArray()
            FloatArray(EqualizerBands.COUNT) { array.optDouble(it, 0.0).toFloat() }
        }.getOrDefault(FloatArray(EqualizerBands.COUNT))
        _state.value = State(store.boolean("audio.equalizer.on", false), preset, (preset.gains ?: custom).copyOf(), custom)
        publish()
    }

    fun setOn(on: Boolean) = update(_state.value.copy(isOn = on))

    fun select(preset: EqualizerPreset) {
        val current = _state.value
        update(current.copy(isOn = true, preset = preset, gains = (preset.gains ?: current.custom).copyOf()))
    }

    /** Dragging a point of the curve makes it the user's own. */
    fun setGain(band: Int, value: Float) {
        val current = _state.value
        if (band !in 0 until EqualizerBands.COUNT) return
        val rounded = Math.round(value.coerceIn(-EqualizerBands.LIMIT, EqualizerBands.LIMIT) * 2) / 2f
        if (rounded == current.gains[band] && current.preset == EqualizerPreset.CUSTOM) return
        val custom = (if (current.preset == EqualizerPreset.CUSTOM) current.custom else current.gains).copyOf()
        custom[band] = rounded
        update(State(isOn = true, preset = EqualizerPreset.CUSTOM, gains = custom.copyOf(), custom = custom))
    }

    private fun update(state: State) {
        _state.value = state
        val store = Prefs.store
        store.set("audio.equalizer.on", state.isOn)
        store.set("audio.equalizer.preset", state.preset.key)
        store.set("audio.equalizer.custom", JSONArray(state.custom.map { it.toDouble() }))
        publish()
    }

    private fun publish() {
        val state = _state.value
        activeGains = if (state.isOn && state.gains.any { it != 0f }) state.gains.copyOf() else null
        version++
    }

    /** The overall volume that keeps raised bands from clipping: lowered by the largest boost. */
    fun preamp(gains: FloatArray): Float {
        val boost = max(0f, min(EqualizerBands.LIMIT, gains.maxOrNull() ?: 0f))
        return 10.0.pow(-boost / 20.0).toFloat()
    }

    /** The filter for one band: shelves for the first and last, peaks in between. */
    fun section(band: Int, gain: Float, sampleRate: Double): Biquad {
        val frequency = EqualizerBands.frequencies[band]
        val decibels = gain.coerceIn(-EqualizerBands.LIMIT, EqualizerBands.LIMIT).toDouble()
        return when (band) {
            0 -> Biquad.shelf(high = false, frequency, decibels, sampleRate)
            EqualizerBands.COUNT - 1 -> Biquad.shelf(high = true, frequency, decibels, sampleRate)
            else -> Biquad.peaking(frequency, decibels, EqualizerBands.Q, sampleRate)
        }
    }

    /** The whole equalizer's gain in decibels at a frequency, preamp included (for the curve on screen). */
    fun response(gains: FloatArray, frequency: Double, sampleRate: Double = 48_000.0): Double {
        var total = 20 * log10(preamp(gains).toDouble())
        for (band in 0 until EqualizerBands.COUNT) total += section(band, gains[band], sampleRate).response(frequency, sampleRate)
        return total
    }
}

/** One second-order section (Robert Bristow-Johnson's Audio EQ Cookbook), a0 = 1. */
data class Biquad(val b0: Double = 1.0, val b1: Double = 0.0, val b2: Double = 0.0, val a1: Double = 0.0, val a2: Double = 0.0) {
    val isIdentity get() = b0 == 1.0 && b1 == 0.0 && b2 == 0.0 && a1 == 0.0 && a2 == 0.0

    fun response(frequency: Double, sampleRate: Double): Double {
        val w = 2 * PI * frequency / sampleRate
        val c1 = cos(w); val s1 = sin(w); val c2 = cos(2 * w); val s2 = sin(2 * w)
        val nRe = b0 + b1 * c1 + b2 * c2
        val nIm = -(b1 * s1 + b2 * s2)
        val dRe = 1 + a1 * c1 + a2 * c2
        val dIm = -(a1 * s1 + a2 * s2)
        return 10 * log10((nRe * nRe + nIm * nIm) / (dRe * dRe + dIm * dIm))
    }

    companion object {
        fun peaking(frequency: Double, gain: Double, q: Double, sampleRate: Double): Biquad {
            if (gain == 0.0) return Biquad()
            val a = 10.0.pow(gain / 40)
            val w = 2 * PI * min(frequency, sampleRate * 0.45) / sampleRate
            val c = cos(w)
            val alpha = sin(w) / (2 * q)
            val a0 = 1 + alpha / a
            return Biquad((1 + alpha * a) / a0, -2 * c / a0, (1 - alpha * a) / a0, -2 * c / a0, (1 - alpha / a) / a0)
        }

        /** A shelf with slope 1: half the gain at `frequency`, all of it well below (low) or above (high). */
        fun shelf(high: Boolean, frequency: Double, gain: Double, sampleRate: Double): Biquad {
            if (gain == 0.0) return Biquad()
            val a = 10.0.pow(gain / 40)
            val w = 2 * PI * min(frequency, sampleRate * 0.45) / sampleRate
            val c = cos(w)
            val root = 2 * sqrt(a) * sin(w) / 2 * sqrt(2.0)
            return if (high) {
                val a0 = (a + 1) - (a - 1) * c + root
                Biquad(
                    a * ((a + 1) + (a - 1) * c + root) / a0, -2 * a * ((a - 1) + (a + 1) * c) / a0,
                    a * ((a + 1) + (a - 1) * c - root) / a0, 2 * ((a - 1) - (a + 1) * c) / a0, ((a + 1) - (a - 1) * c - root) / a0,
                )
            } else {
                val a0 = (a + 1) + (a - 1) * c + root
                Biquad(
                    a * ((a + 1) - (a - 1) * c + root) / a0, 2 * a * ((a - 1) - (a + 1) * c) / a0,
                    a * ((a + 1) - (a - 1) * c - root) / a0, -2 * ((a - 1) + (a + 1) * c) / a0, ((a + 1) + (a - 1) * c - root) / a0,
                )
            }
        }
    }
}

/**
 * The equalizer on the engine's mixed audio (interleaved stereo floats), on the audio thread: no
 * allocation per block, settings picked up through [Equalizer.version]. Off, samples pass untouched.
 */
class EqualizerProcessor(private val sampleRate: Double = 48_000.0) {
    private var version = -1
    private var sections = Array(EqualizerBands.COUNT) { Biquad() }
    private var preamp = 1.0
    private var active = false
    /** Transposed direct form II memory: two values per section and channel. */
    private val memory = DoubleArray(2 * EqualizerBands.COUNT * 2)

    fun process(samples: FloatArray, frames: Int) {
        if (Equalizer.version != version) {
            version = Equalizer.version
            val gains = Equalizer.activeGains
            val wasActive = active
            active = gains != null
            if (gains != null) {
                sections = Array(EqualizerBands.COUNT) { Equalizer.section(it, gains[it], sampleRate) }
                preamp = Equalizer.preamp(gains).toDouble()
            }
            if (!wasActive) memory.fill(0.0)
        }
        if (!active) return
        for (frame in 0 until frames) {
            for (channel in 0 until 2) {
                val index = frame * 2 + channel
                var x = samples[index] * preamp
                val base = channel * EqualizerBands.COUNT * 2
                for (band in 0 until EqualizerBands.COUNT) {
                    val f = sections[band]
                    if (f.isIdentity) continue
                    val m = base + band * 2
                    val y = f.b0 * x + memory[m]
                    memory[m] = f.b1 * x - f.a1 * y + memory[m + 1]
                    memory[m + 1] = f.b2 * x - f.a2 * y
                    x = y
                }
                samples[index] = x.toFloat()
            }
        }
    }

    fun reset() = memory.fill(0.0)
}
