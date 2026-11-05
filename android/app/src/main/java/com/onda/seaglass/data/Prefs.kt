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

/** The app's settings, kept in SharedPreferences and observable from Compose. */
object Prefs {
    /** Null only in the JVM checks, which run without Android. */
    private var prefs: SharedPreferences? = null
    private var memoryVisitor: String? = null

    private val _accent = MutableStateFlow(Accent.PINK)
    val accent: StateFlow<Accent> = _accent

    private val _artworkColors = MutableStateFlow(true)
    /** "Colori dalla copertina": the background takes the colour of the song playing. */
    val artworkColors: StateFlow<Boolean> = _artworkColors

    private val _autoRadio = MutableStateFlow(true)
    /** "Radio automatica": similar songs follow when the queue runs out. */
    val autoRadio: StateFlow<Boolean> = _autoRadio

    private val _skipLongMixes = MutableStateFlow(true)
    val skipLongMixes: StateFlow<Boolean> = _skipLongMixes

    private val _dataSaverFlow = MutableStateFlow(false)
    val dataSaverFlow: StateFlow<Boolean> = _dataSaverFlow

    private val _recentSearches = MutableStateFlow<List<String>>(emptyList())
    val recentSearches: StateFlow<List<String>> = _recentSearches

    const val LONG_MIX_THRESHOLD = 15 * 60.0

    fun init(context: Context) {
        val prefs = context.getSharedPreferences("seaglass", Context.MODE_PRIVATE)
        this.prefs = prefs
        _accent.value = Accent.entries.firstOrNull { it.key == prefs.getString("theme.accent", null) } ?: Accent.PINK
        _artworkColors.value = prefs.getBoolean("theme.dynamicColors", true)
        _autoRadio.value = prefs.getBoolean("radio.auto", true)
        _skipLongMixes.value = prefs.getBoolean("radio.skipLongMixes", true)
        _dataSaverFlow.value = prefs.getBoolean("audio.dataSaver", false)
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

    val dataSaver: Boolean get() = _dataSaverFlow.value

    fun setAccent(accent: Accent) {
        _accent.value = accent
        prefs?.edit()?.putString("theme.accent", accent.key)?.apply()
    }

    fun setArtworkColors(on: Boolean) {
        _artworkColors.value = on
        prefs?.edit()?.putBoolean("theme.dynamicColors", on)?.apply()
    }

    fun setAutoRadio(on: Boolean) {
        _autoRadio.value = on
        prefs?.edit()?.putBoolean("radio.auto", on)?.apply()
    }

    fun setSkipLongMixes(on: Boolean) {
        _skipLongMixes.value = on
        prefs?.edit()?.putBoolean("radio.skipLongMixes", on)?.apply()
    }

    fun setDataSaver(on: Boolean) {
        _dataSaverFlow.value = on
        prefs?.edit()?.putBoolean("audio.dataSaver", on)?.apply()
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
