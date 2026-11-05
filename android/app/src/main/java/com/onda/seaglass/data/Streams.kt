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

class NoStreamException : IOException(tr("Nessuno stream audio riproducibile per questo brano."))

/**
 * A song's audio links, as the iPhone app's `DirectStreams` finds them: one request to YouTube's
 * player as its visionOS app, which answers with direct links to every audio rendition as long as
 * it carries a visitor ID. The same visitor ID serves every song, so it is kept between launches.
 */
object Streams {
    data class Rendition(val url: String, val mime: String, val bitrate: Int) {
        val isOpus get() = "opus" in mime
        val isAac get() = "mp4a" in mime

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

    data class Resolved(val rendition: Rendition, val expires: Long)

    private const val ENDPOINT = "https://www.youtube.com/youtubei/v1/player?prettyPrint=false"
    private const val CLIENT_VERSION = "1.02"
    const val USER_AGENT =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    private val cache = ConcurrentHashMap<String, Resolved>()

    /** The last link handed to the player for each song, for "Formato audio" in the player. */
    fun current(videoId: String): Rendition? = cache[videoId]?.rendition

    fun invalidate(videoId: String) {
        cache.remove(videoId)
    }

    suspend fun resolve(videoId: String): Resolved {
        cache[videoId]?.takeIf { it.expires > System.currentTimeMillis() }?.let { return it }
        val stored = Prefs.visitorData
        var json = request(videoId, stored)
        if (!isPlayable(json)) {
            // Without a visitor ID (or with an old one) YouTube refuses, and hands out a new one.
            val fresh = J.string(json, "responseContext", "visitorData")
            if (fresh == null || fresh == stored) throw NoStreamException()
            Prefs.visitorData = fresh
            json = request(videoId, fresh)
        }
        if (!isPlayable(json)) throw NoStreamException()
        val renditions = parse(json)
        val chosen = choose(renditions) ?: throw NoStreamException()
        // Links are signed for about six hours; keep a margin.
        val lifetime = J.value(json, "streamingData", "expiresInSeconds").toString().toDoubleOrNull() ?: 21_600.0
        val resolved = Resolved(chosen, System.currentTimeMillis() + (maxOf(3_600.0, lifetime - 1_800) * 1000).toLong())
        cache[videoId] = resolved
        return resolved
    }

    /** Opus at the best bitrate (the quality the iPhone app calls "Massima"), or AAC; less on "Risparmio dati". */
    private fun choose(renditions: List<Rendition>): Rendition? {
        val playable = renditions.filter { it.isOpus || it.isAac }
        return if (Prefs.dataSaver) {
            playable.filter { it.isAac }.minByOrNull { it.bitrate } ?: playable.minByOrNull { it.bitrate }
        } else {
            playable.filter { it.isOpus }.maxByOrNull { it.bitrate } ?: playable.maxByOrNull { it.bitrate }
        }
    }

    private fun isPlayable(json: JSONObject) = J.string(json, "playabilityStatus", "status") == "OK"

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
            throw NoStreamException()
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
