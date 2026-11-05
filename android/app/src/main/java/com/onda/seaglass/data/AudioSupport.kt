package com.onda.seaglass.data

import android.content.Context
import android.media.MediaCodecList
import android.net.ConnectivityManager

/** What this phone can play, and how it's connected. */
object AudioSupport {
    /** A Dolby Digital Plus decoder (Dolby Atmos plays through it where the phone supports it). */
    val dolby: Boolean by lazy {
        runCatching {
            MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.any { info ->
                !info.isEncoder && info.supportedTypes.any { it.equals("audio/eac3", true) || it.equals("audio/eac3-joc", true) }
            }
        }.getOrDefault(false)
    }

    /** Dolby Atmos (E-AC-3 JOC) itself. */
    val atmos: Boolean by lazy {
        runCatching {
            MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.any { info ->
                !info.isEncoder && info.supportedTypes.any { it.equals("audio/eac3-joc", true) }
            }
        }.getOrDefault(false)
    }
}

/** Wi-Fi or cellular, for the quality to stream at. */
object Network {
    private var connectivity: ConnectivityManager? = null

    fun init(context: Context) {
        connectivity = context.getSystemService(ConnectivityManager::class.java)
    }

    /** A metered connection (cellular, a hotspot) uses "Rete cellulare". */
    val isMetered: Boolean get() = connectivity?.isActiveNetworkMetered ?: false

    fun streamingQuality(): AudioQuality = if (isMetered) Prefs.cellularQuality.value else Prefs.wifiQuality.value
}
