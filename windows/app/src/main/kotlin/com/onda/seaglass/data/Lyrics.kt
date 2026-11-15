package com.onda.seaglass.data

import com.onda.seaglass.core.Http
import com.onda.seaglass.core.tr
import com.onda.seaglass.model.Track
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.abs

data class LyricLine(val index: Int, val time: Double, val text: String)

sealed interface LyricsState {
    data object Loading : LyricsState
    data object Unavailable : LyricsState
    data class Synced(val lines: List<LyricLine>) : LyricsState
    data class Plain(val text: String) : LyricsState
}

/** Lyrics from LRCLIB (https://lrclib.net), a free and open lyrics database, as on the iPhone. */
object Lyrics {
    private data class Record(val duration: Double?, val instrumental: Boolean, val plain: String?, val synced: String?)

    suspend fun lyrics(track: Track): LyricsState {
        var record: Record? = null
        // The exact-match endpoint needs album and duration.
        if (track.album != null && track.duration != null) {
            record = runCatching {
                fetch(
                    "get",
                    mapOf(
                        "artist_name" to track.primaryArtist,
                        "track_name" to track.title,
                        "album_name" to track.album,
                        "duration" to Math.round(track.duration).toString(),
                    ),
                )?.let { record(JSONObject(it)) }
            }.getOrNull()
        }
        if (record?.synced == null) {
            val results = runCatching {
                fetch("search", mapOf("artist_name" to track.primaryArtist, "track_name" to cleanTitle(track.title)))
                    ?.let { text -> JSONArray(text).let { array -> (0 until array.length()).map { record(array.getJSONObject(it)) } } }
            }.getOrNull() ?: emptyList()
            val best = results.minByOrNull { rank(it, track) }
            if (best?.synced != null || record == null) record = best ?: record
        }
        val found = record ?: return LyricsState.Unavailable
        if (found.instrumental) return LyricsState.Plain(tr("♪ Brano strumentale"))
        found.synced?.let { synced -> parseLrc(synced).takeIf { it.isNotEmpty() }?.let { return LyricsState.Synced(it) } }
        found.plain?.takeIf { it.isNotEmpty() }?.let { return LyricsState.Plain(it) }
        return LyricsState.Unavailable
    }

    private fun record(json: JSONObject) = Record(
        duration = json.optDouble("duration").takeIf { !it.isNaN() },
        instrumental = json.optBoolean("instrumental", false),
        plain = json.optString("plainLyrics").takeIf { it.isNotEmpty() && it != "null" },
        synced = json.optString("syncedLyrics").takeIf { it.isNotEmpty() && it != "null" },
    )

    private suspend fun fetch(path: String, query: Map<String, String>): String? {
        val url = "https://lrclib.net/api/$path".toHttpUrl().newBuilder().apply {
            query.forEach { (key, value) -> addQueryParameter(key, value) }
        }.build()
        val request = Request.Builder().url(url).header("User-Agent", "Seaglass/1.0 (personal Android build)").build()
        return Http.send(request) { if (it.code == 200) it.body.string() else null }
    }

    /** Lower is better: synced lyrics first, then the closest duration. */
    private fun rank(record: Record, track: Track): Double {
        var score = 0.0
        if (record.synced == null) score += 1_000
        if (record.synced == null && record.plain == null) score += 10_000
        score += if (record.duration != null && track.duration != null) abs(record.duration - track.duration) else 30.0
        return score
    }

    /** "Song (feat. X) [Remastered]" -> "Song", which LRCLIB matches more reliably. */
    private fun cleanTitle(title: String): String =
        title.replace(Regex("""\s*[(\[][^)\]]*[)\]]"""), "").trim().ifEmpty { title }

    /** Parses "[mm:ss.xx] text" lines; a line may carry several timestamps. */
    fun parseLrc(lrc: String): List<LyricLine> {
        val stamp = Regex("""\[(\d+):(\d+(?:[.:]\d+)?)]""")
        val timed = mutableListOf<Pair<Double, String>>()
        for (line in lrc.lines()) {
            val matches = stamp.findAll(line).toList()
            val last = matches.lastOrNull() ?: continue
            val text = line.substring(last.range.last + 1).trim()
            for (match in matches) {
                val minutes = match.groupValues[1].toDoubleOrNull() ?: 0.0
                val seconds = match.groupValues[2].replace(':', '.').toDoubleOrNull() ?: 0.0
                timed += (minutes * 60 + seconds) to text
            }
        }
        return timed.sortedBy { it.first }.mapIndexed { index, (time, text) -> LyricLine(index, time, text) }
    }
}
