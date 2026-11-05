package com.onda.seaglass.data

import android.content.Context
import com.onda.seaglass.core.tr
import com.onda.seaglass.model.Track
import com.onda.seaglass.model.uniqued
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.time.LocalDate
import kotlin.random.Random

/** A mood of the Home: YouTube Music searches, one a day. */
data class Mood(val title: String, val queries: List<String>, val tint: Long)

/**
 * The Home's daily recommendations, a lighter version of the iPhone app's: the songs listened to
 * lately meet YouTube Music's radios. They change once a day; pulling the Home down draws new ones.
 */
object Recommendations {
    private lateinit var picksFile: File

    fun init(context: Context) {
        picksFile = File(context.filesDir, "quick-picks.json")
    }

    val today: Long get() = LocalDate.now().toEpochDay()

    val moods: List<Mood>
        get() = listOf(
            Mood(tr("Relax"), listOf("chill relax songs", "acoustic chill", "chill pop", "soft rock chill", "lofi chill beats"), 0xFF34C7B5),
            Mood(tr("Concentrazione"), listOf("lofi focus study", "deep focus instrumental", "piano focus", "ambient study music", "chillhop study"), 0xFF5856D6),
            Mood(tr("Allenamento"), listOf("workout gym motivation songs", "running songs", "hip hop workout", "edm workout", "rock workout"), 0xFFFF9500),
            Mood(tr("Festa"), listOf("party dance hits", "dance pop party", "reggaeton party", "house party hits", "2000s party songs"), 0xFFFF4F99),
            Mood(tr("Malinconia"), listOf("sad songs", "sad pop ballads", "heartbreak songs", "sad indie", "acoustic sad songs"), 0xFF007AFF),
            Mood(tr("Energia"), listOf("upbeat energetic songs", "feel good songs", "happy upbeat pop", "good vibes songs", "summer hits"), 0xFFFFCC00),
            Mood(tr("Italiana"), listOf("hit italiane", "pop italiano", "rap italiano", "cantautori italiani", "indie italiano"), 0xFF34C759),
            Mood(tr("Anni '80"), listOf("80s hits", "80s synthpop", "80s rock anthems", "italo disco", "80s dance hits"), 0xFFAF52DE),
        )

    /** Today's "Scelti per te", worked out once a day and kept; [refresh] draws new ones. */
    suspend fun quickPicks(refresh: Boolean): List<Track> = withContext(Dispatchers.IO) {
        val day = today
        val history = Library.history.value
        val saved = runCatching { JSONObject(picksFile.readText()) }.getOrNull()
        val savedTracks = Track.listFromJson(saved?.optJSONArray("tracks"))
        if (!refresh && saved?.optLong("day") == day && savedTracks.isNotEmpty() &&
            (saved.optBoolean("personal") || history.isEmpty())
        ) {
            return@withContext savedTracks
        }
        val random = Random(if (refresh) System.nanoTime() else day)
        // One seed per artist among the songs played lately, favourites as a fallback.
        val candidates = (history.take(40) + Library.liked.value.take(40)).distinctBy { it.primaryArtist.lowercase() }
        val seeds = candidates.shuffled(random).take(4)
        val tracks = if (seeds.isEmpty()) {
            val query = listOf("top hits", "hit del momento", "viral hits", "new music friday", "top 50 italia").random(random)
            withoutLongMixes(runCatching { InnerTube.searchSongs(query) }.getOrDefault(emptyList())).take(20)
        } else {
            val recent = history.take(15).map { it.videoId }.toSet()
            val radios = radios(seeds)
            // Take turns between the radios so no artist fills the shelf.
            val mixed = mutableListOf<Track>()
            val iterators = radios.map { it.drop(1).shuffled(random).iterator() }
            while (mixed.size < 60 && iterators.any { it.hasNext() }) {
                for (iterator in iterators) if (iterator.hasNext()) mixed += iterator.next()
            }
            mixed.uniqued().filter { it.videoId !in recent }.take(20)
        }
        if (tracks.isEmpty()) return@withContext savedTracks
        runCatching {
            picksFile.writeText(
                JSONObject().put("day", day).put("personal", seeds.isNotEmpty()).put("tracks", Track.listToJson(tracks)).toString(),
            )
        }
        tracks
    }

    /** A mood's songs: one of its searches (a different one each day), with the radios of the top results. */
    suspend fun moodTracks(mood: Mood): List<Track> {
        val random = Random(today * 31 + mood.queries.first().hashCode())
        val query = mood.queries.random(random)
        val found = withoutLongMixes(InnerTube.searchSongs(query))
        if (found.isEmpty()) throw NotFoundException()
        val radios = radios(found.take(3))
        return (listOf(found) + radios).flatten().uniqued().shuffled(random).take(60)
    }

    /** The seeds' radios, fetched at the same time; a radio that fails is left out. */
    private suspend fun radios(seeds: List<Track>): List<List<Track>> = coroutineScope {
        seeds.map { seed -> async { runCatching { InnerTube.radio(seed.videoId) }.getOrDefault(emptyList()) } }
            .awaitAll().map(::withoutLongMixes)
    }

    /** Drops hour-long compilations uploaded as "songs", unless the user turned the filter off. */
    fun withoutLongMixes(tracks: List<Track>): List<Track> =
        if (!Prefs.skipLongMixes.value) tracks else tracks.filter { (it.duration ?: 0.0) <= Prefs.LONG_MIX_THRESHOLD }
}
