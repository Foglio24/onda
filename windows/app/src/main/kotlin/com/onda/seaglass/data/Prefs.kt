package com.onda.seaglass.data

import java.io.File
import java.util.Properties

enum class AudioQuality(val key: String) {
    MAX("max"),
    HIGH("high"),
    MEDIUM("medium"),
    LOW("low"),
}

/** Lightweight prefs under AppData\Local\Seaglass (visitorData for streams, update mode). */
object Prefs {
    private val file = File(System.getProperty("user.home"), "AppData/Local/Seaglass/prefs.properties")
    private val props = Properties()

    init {
        if (file.isFile) runCatching { file.inputStream().use { props.load(it) } }
    }

    private fun save() {
        file.parentFile?.mkdirs()
        file.outputStream().use { props.store(it, "Seaglass Windows") }
    }

    var visitorData: String?
        get() = props.getProperty("youtube.visitorData")
        set(value) {
            if (value == null) props.remove("youtube.visitorData") else props.setProperty("youtube.visitorData", value)
            save()
        }

    var preferDolby: Boolean
        get() = props.getProperty("audio.preferDolby", "false").toBoolean()
        set(value) {
            props.setProperty("audio.preferDolby", value.toString())
            save()
        }

    var streamingQuality: AudioQuality
        get() = AudioQuality.entries.firstOrNull { it.key == props.getProperty("audio.quality") } ?: AudioQuality.HIGH
        set(value) {
            props.setProperty("audio.quality", value.key)
            save()
        }
}
