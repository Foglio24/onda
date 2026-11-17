package com.onda.seaglass.core

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONObject
import java.io.File
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption

/**
 * A JSON file of settings (%APPDATA%\Seaglass\settings.json): what UserDefaults is on the iPhone
 * and SharedPreferences on Android. Writes go to a temporary file first and replace the old one,
 * so a crash or power cut never leaves half a file. Keys are kept as earlier versions wrote them.
 */
class JsonStore(private val file: File) {
    private val values: JSONObject = runCatching { JSONObject(file.readText()) }.getOrElse { JSONObject() }

    @Synchronized fun string(key: String): String? = values.optString(key).takeIf { values.has(key) && !values.isNull(key) }
    @Synchronized fun boolean(key: String, default: Boolean) = if (values.has(key)) values.optBoolean(key, default) else default
    @Synchronized fun double(key: String, default: Double) = if (values.has(key)) values.optDouble(key, default) else default
    @Synchronized fun int(key: String, default: Int) = if (values.has(key)) values.optInt(key, default) else default
    @Synchronized fun json(key: String): Any? = if (values.has(key)) values.opt(key) else null

    @Synchronized
    fun set(key: String, value: Any?) {
        if (value == null) values.remove(key) else values.put(key, value)
        save()
    }

    private fun save() {
        file.parentFile?.mkdirs()
        val temporary = File(file.parentFile, file.name + ".tmp")
        temporary.writeText(values.toString(1))
        try {
            Files.move(temporary.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
        } catch (_: AtomicMoveNotSupportedException) {
            Files.move(temporary.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING)
        }
    }
}

/** The app's settings, each as a flow the interface follows. */
object Prefs {
    val store: JsonStore by lazy { JsonStore(File(Paths.data, "settings.json")) }

    class Setting<T>(private val key: String, default: T, private val read: (JsonStore, String, T) -> T) {
        private val flow by lazy { MutableStateFlow(read(store, key, default)) }
        val state: StateFlow<T> get() = flow
        var value: T
            get() = flow.value
            set(new) {
                flow.value = new
                store.set(key, new)
            }
    }

    private fun bool(key: String, default: Boolean) = Setting(key, default) { s, k, d -> s.boolean(k, d) }
    private fun double(key: String, default: Double) = Setting(key, default) { s, k, d -> s.double(k, d) }
    private fun int(key: String, default: Int) = Setting(key, default) { s, k, d -> s.int(k, d) }
    private fun text(key: String, default: String?) = Setting(key, default) { s, k, d -> s.string(k) ?: d }

    /** null: Windows's language. */
    val language = text("app.language", null)
    /** "system", "dark" or "light". */
    val theme = Setting("app.theme", "system") { s, k, d -> s.string(k) ?: d }
    /** "seaglass" or "classic", as the iPhone app's Aspetto. */
    val style = Setting("app.style", "seaglass") { s, k, d -> s.string(k) ?: d }
    val accent = Setting("app.accent", "pink") { s, k, d -> s.string(k) ?: d }

    val volume = double("player.volume", 0.8)
    val shuffle = bool("player.shuffle", false)
    /** "off", "all" or "one". */
    val repeat = Setting("player.repeat", "off") { s, k, d -> s.string(k) ?: d }
    /** "Volume uniforme": songs brought to the same loudness, as on the iPhone. */
    val normalizeVolume = bool("audio.normalize", true)
    /** "max", "high", "medium", "low": as the iPhone app's streaming quality. */
    val quality = Setting("audio.quality", "max") { s, k, d -> s.string(k) ?: d }
    /** "none", "crossfade", "automix". */
    val transition = Setting("audio.transition", "crossfade") { s, k, d -> s.string(k) ?: d }
    val crossfadeSeconds = double("audio.crossfade", 6.0)

    // AutoMix's options, as the iPhone and Mac app's Playback settings (same defaults).
    /** "Mix dal vivo": on, the options below shape the mixes; off, AutoMix plans as before them. */
    val liveMix = bool("automix.live", true)
    /** "automatic", "blend", "cut" or "fade". */
    val mixStyle = Setting("automix.style", "automatic") { s, k, d -> s.string(k) ?: d }
    /** The mix's longest length: 0 short (8 bars), 1 normal (16), 2 long (32). */
    val mixLength = int("automix.length", 1)
    /** How far the two songs' tempos may be apart for a mix on the beat: "gentle" 4 %, "normal" 8 %, "wide" 12 %. */
    val tempoBend = Setting("automix.tempoBend", "normal") { s, k, d -> s.string(k) ?: d }
    /** Bass, mids, highs and filters pass from one song to the other; off, only the volumes change. */
    val autoEqualiser = bool("automix.eq", true)
    /** An album's songs played in order are left as the album has them, not mixed. */
    val keepAlbum = bool("automix.keepAlbum", true)
    /** What Next does while AutoMix is on: "cut", "quick" or "onBeat". */
    val skipMix = Setting("automix.skip", "cut") { s, k, d -> s.string(k) ?: d }
    // Mix Lab.
    val labBass = bool("automix.lab.bass", true)
    val labBeatFade = bool("automix.lab.beatFade", false)
    val labEnergy = bool("automix.lab.energy", false)
    /** The progress bar shows where the mix will happen. */
    val transitionMark = bool("player.transitionMark", true)
    /** When the queue ends, play on with songs like the last one. */
    val autoRadio = bool("player.autoRadio", true)
    /** The output device's name, null for Windows's default. */
    val outputDevice = text("audio.device", null)

    /** Tempo's key lock, as on the iPhone: on, voices keep their pitch at any tempo; off, as a turntable. */
    val tempoKeyLock = bool("tempo.keyLock", true)
    /** How far Tempo's fader goes either way: 0.08, 0.15, 0.25 or 0.5 (as the iPhone's). */
    val tempoRange = double("tempo.range", 0.15)
    /** Panel widths, as the user dragged them (the library on the left, the panel on the right). */
    val leftPanelWidth = double("ui.leftWidth", 300.0)
    val rightPanelWidth = double("ui.rightWidth", 340.0)
    /** The right panel ("now", "queue", "lyrics" or "none"), as it was left. */
    val rightPanel = Setting("ui.rightPanel", "now") { s, k, d -> s.string(k) ?: d }

    val lyricsTranslate = bool("lyrics.translate", false)
    /** The language lyrics are translated into; empty for the app's. */
    val translationTarget = Setting("lyrics.translationTarget", "") { s, k, d -> s.string(k) ?: d }
    /** Keep playing in the notification area when the window is closed (as the Mac app does). */
    val keepPlayingInTray = bool("app.tray", true)
    val startWithWindows = bool("app.autostart", false)
    val autoUpdate = bool("app.autoUpdate", true)

    val sleepMinutes = int("player.sleep", 0)
    /** Leave out hour-long compilations uploaded as songs, as on the iPhone. */
    val skipLongMixes = bool("catalog.skipLongMixes", true)
    const val LONG_MIX_THRESHOLD = 20 * 60.0

    /** YouTube's visitor ID: the same one serves every song, so it is kept between launches. */
    var visitorData: String?
        get() = store.string("youtube.visitorData")
        set(value) = store.set("youtube.visitorData", value)
}
