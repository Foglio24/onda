package com.onda.seaglass.data

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.ui.graphics.Color
import com.onda.seaglass.core.tr
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONArray

/** The theme colours of the iPhone app's "Colore del tema". */
enum class Accent(val key: String, val color: Color) {
    PINK("pink", Color(1f, 0.31f, 0.6f)),
    RED("red", Color(0.96f, 0.23f, 0.25f)),
    ORANGE("orange", Color(1f, 0.58f, 0f)),
    YELLOW("yellow", Color(1f, 0.8f, 0.1f)),
    LIGHT_GREEN("lightGreen", Color(0.45f, 0.86f, 0.36f)),
    DARK_GREEN("darkGreen", Color(0.12f, 0.55f, 0.28f)),
    MINT("mint", Color(0f, 0.78f, 0.75f)),
    LIGHT_BLUE("lightBlue", Color(0.35f, 0.76f, 1f)),
    BLUE("blue", Color(0f, 0.48f, 1f)),
    INDIGO("indigo", Color(0.35f, 0.34f, 0.84f)),
    PURPLE("purple", Color(0.69f, 0.32f, 0.87f));

    val title: String
        get() = when (this) {
            PINK -> tr("Rosa")
            RED -> tr("Rosso")
            ORANGE -> tr("Arancione")
            YELLOW -> tr("Giallo")
            LIGHT_GREEN -> tr("Verde chiaro")
            DARK_GREEN -> tr("Verde scuro")
            MINT -> tr("Menta")
            LIGHT_BLUE -> tr("Azzurro")
            BLUE -> tr("Blu")
            INDIGO -> tr("Indaco")
            PURPLE -> tr("Viola")
        }
}

/** The iPhone app's audio qualities (Impostazioni → Audio). */
enum class AudioQuality(val key: String) {
    /** The best YouTube has: Dolby or AAC 256 kbps when offered, otherwise Opus ~160 kbps. */
    MAX("max"),
    /** AAC 128 kbps. */
    HIGH("high"),
    /** Opus ~70 kbps. */
    MEDIUM("medium"),
    /** HE-AAC 48 kbps. */
    LOW("low");

    val title: String
        get() = when (this) {
            MAX -> tr("Massima · Opus 160 kbps")
            HIGH -> tr("Alta · AAC 128 kbps")
            MEDIUM -> tr("Media · Opus 70 kbps")
            LOW -> tr("Risparmio · AAC 48 kbps")
        }

    companion object {
        fun of(key: String?, default: AudioQuality) = entries.firstOrNull { it.key == key } ?: default
    }
}

/** What happens between songs (Riproduzione → transitions), as on the iPhone. */
enum class SongTransition(val key: String) {
    /** Like the iPhone's: matched beats, or a blend or fade suited to the two songs. */
    AUTOMIX("autoMix"),
    /** The same overlap every time, of [Prefs.crossfadeSeconds]. */
    CROSSFADE("crossfade"),
    OFF("off");

    val title: String
        get() = when (this) {
            AUTOMIX -> tr("AutoMix")
            CROSSFADE -> tr("Dissolvenza incrociata")
            OFF -> tr("Nessuna")
        }
}

/** The app's settings, kept in SharedPreferences and observable from Compose. */
object Prefs {
    /** Null only in the JVM checks, which run without Android. */
    private var prefs: SharedPreferences? = null
    private var memoryVisitor: String? = null

    /** A boolean setting: its current value as a flow, and how to change it. */
    class Flag internal constructor(private val key: String, private val default: Boolean) {
        private val state = MutableStateFlow(default)
        val flow: StateFlow<Boolean> = state
        val value: Boolean get() = state.value
        internal fun load(prefs: SharedPreferences) { state.value = prefs.getBoolean(key, default) }
        fun set(on: Boolean) {
            state.value = on
            prefs?.edit()?.putBoolean(key, on)?.apply()
        }
    }

    /** A setting stored as text (an enum's key). */
    class Choice<T> internal constructor(private val key: String, private val default: T, private val decode: (String?) -> T, private val encode: (T) -> String) {
        private val state = MutableStateFlow(default)
        val flow: StateFlow<T> = state
        val value: T get() = state.value
        internal fun load(prefs: SharedPreferences) { state.value = decode(prefs.getString(key, null)) }
        fun set(value: T) {
            state.value = value
            prefs?.edit()?.putString(key, encode(value))?.apply()
        }
    }

    private fun quality(key: String, default: AudioQuality) =
        Choice(key, default, { AudioQuality.of(it, default) }, { it.key })

    val accentChoice = Choice("theme.accent", Accent.PINK, { k -> Accent.entries.firstOrNull { it.key == k } ?: Accent.PINK }, { it.key })
    val accent: StateFlow<Accent> get() = accentChoice.flow

    /** "Colori dalla copertina": the background takes the colour of the song playing. */
    val artworkColorsFlag = Flag("theme.dynamicColors", true)
    val artworkColors: StateFlow<Boolean> get() = artworkColorsFlag.flow

    /** "Radio automatica": similar songs follow when the queue runs out. */
    val autoRadioFlag = Flag("radio.auto", true)
    val autoRadio: StateFlow<Boolean> get() = autoRadioFlag.flow

    val skipLongMixesFlag = Flag("radio.skipLongMixes", true)
    val skipLongMixes: StateFlow<Boolean> get() = skipLongMixesFlag.flow

    val wifiQuality = quality("audio.quality.wifi", AudioQuality.MAX)
    val cellularQuality = quality("audio.quality.cellular", AudioQuality.HIGH)
    val downloadQuality = quality("audio.quality.download", AudioQuality.MAX)

    /** "Dolby quando disponibile". */
    val preferDolby = Flag("audio.preferDolby", true)
    /** "Volume uniforme": every song at YouTube's reference loudness. */
    val normalizeVolume = Flag("audio.normalizeVolume", true)
    /** Bit-perfect output to a USB DAC (Android 14 and later). */
    val bitPerfect = Flag("audio.bitPerfect", false)

    val transition = Choice("playback.transition", SongTransition.AUTOMIX, { k -> SongTransition.entries.firstOrNull { it.key == k } ?: SongTransition.AUTOMIX }, { it.key })
    private val crossfadeState = MutableStateFlow(6f)
    /** Seconds of overlap with "Dissolvenza incrociata". */
    val crossfadeSeconds: StateFlow<Float> = crossfadeState

    /** "Traduci i testi": the language lyrics are translated into ("" = the app's language). */
    val translationTarget = Choice("lyrics.translationTarget", "", { it ?: "" }, { it })

    private val _recentSearches = MutableStateFlow<List<String>>(emptyList())
    val recentSearches: StateFlow<List<String>> = _recentSearches

    const val LONG_MIX_THRESHOLD = 15 * 60.0

    fun init(context: Context) {
        val prefs = context.getSharedPreferences("seaglass", Context.MODE_PRIVATE)
        this.prefs = prefs
        listOf(artworkColorsFlag, autoRadioFlag, skipLongMixesFlag, preferDolby, normalizeVolume, bitPerfect).forEach { it.load(prefs) }
        listOf(accentChoice, wifiQuality, cellularQuality, downloadQuality, transition, translationTarget).forEach { it.load(prefs) }
        crossfadeState.value = prefs.getFloat("playback.crossfade", 6f)
        _recentSearches.value = runCatching {
            val array = JSONArray(prefs.getString("search.recent", "[]"))
            (0 until array.length()).map { array.getString(it) }
        }.getOrDefault(emptyList())
    }

    var visitorData: String?
        get() = prefs?.getString("youtube.visitorData", null) ?: memoryVisitor
        set(value) {
            memoryVisitor = value
            prefs?.edit()?.putString("youtube.visitorData", value)?.apply()
        }

    fun setAccent(accent: Accent) = accentChoice.set(accent)
    fun setArtworkColors(on: Boolean) = artworkColorsFlag.set(on)
    fun setAutoRadio(on: Boolean) = autoRadioFlag.set(on)
    fun setSkipLongMixes(on: Boolean) = skipLongMixesFlag.set(on)

    fun setCrossfadeSeconds(seconds: Float) {
        crossfadeState.value = seconds
        prefs?.edit()?.putFloat("playback.crossfade", seconds)?.apply()
    }

    fun addRecentSearch(query: String) {
        val trimmed = query.trim()
        if (trimmed.isEmpty()) return
        val list = (listOf(trimmed) + _recentSearches.value.filterNot { it.equals(trimmed, ignoreCase = true) }).take(12)
        _recentSearches.value = list
        prefs?.edit()?.putString("search.recent", JSONArray(list).toString())?.apply()
    }

    fun clearRecentSearches() {
        _recentSearches.value = emptyList()
        prefs?.edit()?.remove("search.recent")?.apply()
    }

    /** Where playback was, to offer "Riprendi da dove eri" after the app was closed. */
    var resumeState: String?
        get() = prefs?.getString("player.resume", null)
        set(value) {
            prefs?.edit()?.putString("player.resume", value)?.apply()
        }
}
