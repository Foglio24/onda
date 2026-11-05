package com.onda.seaglass.data

import com.onda.seaglass.core.Http
import com.onda.seaglass.core.J
import com.onda.seaglass.core.L10n
import com.onda.seaglass.core.jsonOf
import com.onda.seaglass.core.tr
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap

/** [detail] is YouTube's own answer ("LOGIN_REQUIRED: …"), for diagnostics. */
class NoStreamException(val detail: String? = null) : IOException(tr("Nessuno stream audio riproducibile per questo brano."))

/**
 * A song's audio links, as the iPhone app's `DirectStreams` finds them: one request to YouTube's
 * player as its visionOS app, which answers with direct links to every audio rendition as long as
 * it carries a visitor ID. The same visitor ID serves every song, so it is kept between launches.
 */
object Streams {
    data class Rendition(val url: String, val mime: String, val bitrate: Int) {
        val isOpus get() = "opus" in mime
        val isAac get() = "mp4a" in mime
        val isDolby get() = "ec-3" in mime || "ac-3" in mime

        /** "Opus · 160 kbps". */
        val label: String
            get() {
                val name = when {
                    isOpus -> "Opus"
                    isAac -> "AAC"
                    else -> "Dolby Digital Plus"
                }
                return if (bitrate > 0) "$name · ${(bitrate / 1000.0).toInt()} kbps" else name
            }
    }

    data class Resolved(val rendition: Rendition, val expires: Long, val loudness: Double? = null)

    private const val ENDPOINT = "https://www.youtube.com/youtubei/v1/player?prettyPrint=false"
    private const val CLIENT_VERSION = "1.02"
    const val USER_AGENT =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    /** By "videoId|quality". */
    private val cache = ConcurrentHashMap<String, Resolved>()
    private val lastPlayed = ConcurrentHashMap<String, Rendition>()
    private val loudnessByVideo = ConcurrentHashMap<String, Double>()

    /** Told (on the loading thread) when a song's loudness becomes known, for "Volume uniforme". */
    @Volatile var onLoudness: ((String) -> Unit)? = null

    /** The last link handed to the player for each song, for the format shown in the player. */
    fun current(videoId: String): Rendition? = lastPlayed[videoId]

    /** Decibels above YouTube's reference level (-14 LUFS), when known. */
    fun loudness(videoId: String): Double? = loudnessByVideo[videoId] ?: Downloads.loudness(videoId)

    fun rememberLoudness(videoId: String, decibels: Double) {
        loudnessByVideo[videoId] = decibels
    }

    fun invalidate(videoId: String) {
        cache.keys.removeAll { it.startsWith("$videoId|") }
    }

    /** The audio link for streaming now: at the Wi-Fi or the cellular quality. */
    suspend fun resolve(videoId: String): Resolved = resolve(videoId, Network.streamingQuality())

    suspend fun resolve(videoId: String, quality: AudioQuality): Resolved {
        val key = "$videoId|${quality.key}|${Prefs.preferDolby.value}"
        cache[key]?.takeIf { it.expires > System.currentTimeMillis() }?.let {
            lastPlayed[videoId] = it.rendition
            return it
        }
        val stored = Prefs.visitorData
        var json = request(videoId, stored)
        if (!isPlayable(json)) {
            // Without a visitor ID (or with an old one) YouTube refuses, and hands out a new one.
            val fresh = J.string(json, "responseContext", "visitorData")
            if (fresh == null || fresh == stored) throw NoStreamException(refusal(json))
            Prefs.visitorData = fresh
            json = request(videoId, fresh)
        }
        if (!isPlayable(json)) throw NoStreamException(refusal(json))
        val renditions = parse(json)
        val chosen = choose(renditions, quality) ?: throw NoStreamException()
        val loudness = loudness(json)
        // Links are signed for about six hours; keep a margin.
        val lifetime = J.value(json, "streamingData", "expiresInSeconds").toString().toDoubleOrNull() ?: 21_600.0
        val resolved = Resolved(chosen, System.currentTimeMillis() + (maxOf(3_600.0, lifetime - 1_800) * 1000).toLong(), loudness)
        cache[key] = resolved
        lastPlayed[videoId] = chosen
        if (loudness != null) {
            loudnessByVideo[videoId] = loudness
            onLoudness?.invoke(videoId)
        }
        return resolved
    }

    /**
     * The rendition for [quality], as the iPhone app chooses: "Massima" is Dolby (when wanted and
     * the phone decodes it) or AAC 256 kbps when YouTube offers them, otherwise the best Opus;
     * "Alta" AAC 128 kbps; "Media" Opus ~70 kbps; "Risparmio" HE-AAC 48 kbps.
     */
    fun choose(renditions: List<Rendition>, quality: AudioQuality, dolby: Boolean = Prefs.preferDolby.value && AudioSupport.dolby): Rendition? {
        val opus = renditions.filter { it.isOpus }
        val aac = renditions.filter { it.isAac }
        fun closest(list: List<Rendition>, target: Int) = list.minByOrNull { kotlin.math.abs(it.bitrate - target) }
        return when (quality) {
            AudioQuality.MAX ->
                (if (dolby) renditions.filter { it.isDolby }.maxByOrNull { it.bitrate } else null)
                    ?: aac.filter { it.bitrate >= 200_000 }.maxByOrNull { it.bitrate }
                    ?: opus.maxByOrNull { it.bitrate }
                    ?: aac.maxByOrNull { it.bitrate }
            AudioQuality.HIGH -> closest(aac.filter { it.bitrate < 200_000 }, 128_000) ?: opus.maxByOrNull { it.bitrate } ?: aac.firstOrNull()
            AudioQuality.MEDIUM -> closest(opus, 70_000) ?: aac.minByOrNull { it.bitrate }
            AudioQuality.LOW -> aac.minByOrNull { it.bitrate } ?: opus.minByOrNull { it.bitrate }
        }
    }

    /** Decibels above -14 LUFS, as YouTube measures the song. */
    private fun loudness(json: JSONObject): Double? {
        val config = J.obj(json, "playerConfig", "audioConfig") ?: return null
        config.optDouble("loudnessDb").takeIf { !it.isNaN() }?.let { return it }
        val absolute = config.optDouble("trackAbsoluteLoudnessLkfs").takeIf { !it.isNaN() } ?: return null
        return absolute - config.optDouble("loudnessTargetLkfs", -14.0)
    }

    /** The volume that brings a song down to the reference level; quieter songs stay as they are. */
    fun gain(decibels: Double?): Float {
        if (decibels == null || decibels <= 0.1) return 1f
        return Math.pow(10.0, -minOf(decibels, 20.0) / 20).toFloat()
    }

    private fun isPlayable(json: JSONObject) = J.string(json, "playabilityStatus", "status") == "OK"

    private fun refusal(json: JSONObject): String =
        listOfNotNull(J.string(json, "playabilityStatus", "status"), J.string(json, "playabilityStatus", "reason")).joinToString(": ")

    private suspend fun request(videoId: String, visitor: String?): JSONObject {
        val client = jsonOf(
            "clientName" to "VISIONOS",
            "clientVersion" to CLIENT_VERSION,
            "deviceMake" to "Apple",
            "deviceModel" to "RealityDevice17,1",
            "osName" to "visionOS",
            "osVersion" to "26.5.23O471",
            "hl" to L10n.locale.language.ifEmpty { "en" },
            "visitorData" to visitor,
        )
        val body = jsonOf(
            "videoId" to videoId,
            "contentCheckOk" to true,
            "racyCheckOk" to true,
            "context" to jsonOf("client" to client),
        )
        val request = Request.Builder()
            .url(ENDPOINT)
            .header("User-Agent", USER_AGENT)
            .header("X-YouTube-Client-Name", "101")
            .header("X-YouTube-Client-Version", CLIENT_VERSION)
            .apply { if (visitor != null) header("X-Goog-Visitor-Id", visitor) }
            .post(body.toString().toRequestBody("application/json".toMediaType()))
            .build()
        return try {
            JSONObject(Http.text(request))
        } catch (e: IOException) {
            throw NoStreamException(e.message)
        }
    }

    /** The audio renditions with a direct link, leaving out dubbed tracks and dynamic-range-compressed copies. */
    private fun parse(json: JSONObject): List<Rendition> =
        J.objects(json, "streamingData", "adaptiveFormats").mapNotNull { format ->
            val mime = format.optString("mimeType")
            val url = format.optString("url")
            if (!mime.startsWith("audio/") || url.isEmpty()) return@mapNotNull null
            if (format.optBoolean("isDrc", false)) return@mapNotNull null
            if (J.value(format, "audioTrack", "audioIsDefault") == false) return@mapNotNull null
            val bitrate = format.optInt("averageBitrate").takeIf { it > 0 } ?: format.optInt("bitrate")
            Rendition(url, mime, bitrate)
        }
}
