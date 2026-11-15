package com.onda.seaglass.data

import com.onda.seaglass.core.Http
import com.onda.seaglass.core.HttpException
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
 * Same as Android/iOS DirectStreams: VISIONOS `player` → direct adaptiveFormats URLs, with a
 * persisted visitor ID. Windows prefers AAC so JavaFX Media can play it (Opus is less reliable there).
 */
object Streams {
    data class Rendition(val url: String, val mime: String, val bitrate: Int) {
        val isOpus get() = "opus" in mime
        val isAac get() = "mp4a" in mime
        val isDolby get() = "ec-3" in mime || "ac-3" in mime
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

    private val cache = ConcurrentHashMap<String, Resolved>()
    private val lastPlayed = ConcurrentHashMap<String, Rendition>()

    fun current(videoId: String): Rendition? = lastPlayed[videoId]

    fun invalidate(videoId: String) {
        cache.keys.removeAll { it.startsWith("$videoId|") }
    }

    fun resolve(videoId: String): Resolved = resolve(videoId, Prefs.streamingQuality)

    fun resolve(videoId: String, quality: AudioQuality): Resolved {
        val key = "$videoId|${quality.key}|${Prefs.preferDolby}"
        cache[key]?.takeIf { it.expires > System.currentTimeMillis() }?.let {
            lastPlayed[videoId] = it.rendition
            return it
        }
        val stored = Prefs.visitorData
        var json = request(videoId, stored)
        if (!isPlayable(json)) {
            val fresh = J.string(json, "responseContext", "visitorData")
            if (fresh == null || fresh == stored) throw NoStreamException(refusal(json))
            Prefs.visitorData = fresh
            json = request(videoId, fresh)
        }
        if (!isPlayable(json)) throw NoStreamException(refusal(json))
        val renditions = parse(json)
        // Prefer AAC on Windows for the desktop media stack.
        val chosen = choose(renditions, quality, preferAac = true) ?: throw NoStreamException()
        val lifetime = J.value(json, "streamingData", "expiresInSeconds").toString().toDoubleOrNull() ?: 21_600.0
        val resolved = Resolved(chosen, System.currentTimeMillis() + (maxOf(3_600.0, lifetime - 1_800) * 1000).toLong())
        cache[key] = resolved
        lastPlayed[videoId] = chosen
        return resolved
    }

    fun choose(renditions: List<Rendition>, quality: AudioQuality, preferAac: Boolean = false): Rendition? {
        val opus = renditions.filter { it.isOpus }
        val aac = renditions.filter { it.isAac }
        fun closest(list: List<Rendition>, target: Int) = list.minByOrNull { kotlin.math.abs(it.bitrate - target) }
        if (preferAac && aac.isNotEmpty()) {
            return when (quality) {
                AudioQuality.MAX -> aac.filter { it.bitrate >= 200_000 }.maxByOrNull { it.bitrate } ?: aac.maxByOrNull { it.bitrate }
                AudioQuality.HIGH -> closest(aac.filter { it.bitrate < 200_000 }, 128_000) ?: aac.maxByOrNull { it.bitrate }
                AudioQuality.MEDIUM, AudioQuality.LOW -> aac.minByOrNull { it.bitrate }
            } ?: opus.maxByOrNull { it.bitrate }
        }
        return when (quality) {
            AudioQuality.MAX ->
                aac.filter { it.bitrate >= 200_000 }.maxByOrNull { it.bitrate }
                    ?: opus.maxByOrNull { it.bitrate }
                    ?: aac.maxByOrNull { it.bitrate }
            AudioQuality.HIGH -> closest(aac.filter { it.bitrate < 200_000 }, 128_000) ?: opus.maxByOrNull { it.bitrate } ?: aac.firstOrNull()
            AudioQuality.MEDIUM -> closest(opus, 70_000) ?: aac.minByOrNull { it.bitrate }
            AudioQuality.LOW -> aac.minByOrNull { it.bitrate } ?: opus.minByOrNull { it.bitrate }
        }
    }

    private fun isPlayable(json: JSONObject) = J.string(json, "playabilityStatus", "status") == "OK"

    private fun refusal(json: JSONObject): String =
        listOfNotNull(J.string(json, "playabilityStatus", "status"), J.string(json, "playabilityStatus", "reason")).joinToString(": ")

    private fun request(videoId: String, visitor: String?): JSONObject {
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
        } catch (e: HttpException) {
            throw NoStreamException("HTTP ${e.status}")
        } catch (e: IOException) {
            throw NoStreamException(e.message)
        }
    }

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
