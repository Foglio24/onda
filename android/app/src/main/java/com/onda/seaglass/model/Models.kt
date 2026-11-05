package com.onda.seaglass.model

import com.onda.seaglass.core.tr
import org.json.JSONArray
import org.json.JSONObject
import java.text.Normalizer
import java.util.UUID

/** A song as the app knows it (the iPhone app's `Track`). */
data class Track(
    val videoId: String,
    val title: String,
    val artists: List<String>,
    val album: String? = null,
    /** Seconds. */
    val duration: Double? = null,
    val artworkUrl: String? = null,
    /** YouTube Music pages of the first artist and of the album, when known. */
    val artistId: String? = null,
    val albumId: String? = null,
) {
    val id: String get() = videoId

    val artist: String
        get() = artists.filter { it.isNotBlank() }.joinToString(", ").ifEmpty { tr("Artista sconosciuto") }

    val primaryArtist: String get() = artists.firstOrNull { it.isNotBlank() }.orEmpty()

    val subtitle: String get() = listOfNotNull(artist, album).filter { it.isNotEmpty() }.joinToString(" · ")

    val mediumArtwork: String? get() = resized(226)
    val largeArtwork: String? get() = resized(1080)

    val shareUrl: String get() = "https://music.youtube.com/watch?v=$videoId"

    /** YouTube Music artwork URLs carry their size as a `=wNNN-hNNN` suffix. */
    fun resized(size: Int): String? {
        val url = artworkUrl ?: return null
        return sizeSuffix.find(url)?.let { url.replaceRange(it.range, "=w$size-h$size") } ?: url
    }

    fun toJson(): JSONObject = JSONObject().apply {
        put("videoId", videoId)
        put("title", title)
        put("artists", JSONArray(artists))
        album?.let { put("album", it) }
        duration?.let { put("duration", it) }
        artworkUrl?.let { put("artwork", it) }
        artistId?.let { put("artistId", it) }
        albumId?.let { put("albumId", it) }
    }

    companion object {
        private val sizeSuffix = Regex("""=w\d+-h\d+""")

        fun fromJson(json: JSONObject?): Track? {
            json ?: return null
            val videoId = json.optString("videoId").takeIf { it.isNotEmpty() } ?: return null
            val artists = json.optJSONArray("artists")?.let { array -> (0 until array.length()).map { array.optString(it) } }
                ?: emptyList()
            return Track(
                videoId = videoId,
                title = json.optString("title"),
                artists = artists,
                album = json.optString("album").takeIf { it.isNotEmpty() },
                duration = json.optDouble("duration").takeIf { !it.isNaN() },
                artworkUrl = json.optString("artwork").takeIf { it.isNotEmpty() },
                artistId = json.optString("artistId").takeIf { it.isNotEmpty() },
                albumId = json.optString("albumId").takeIf { it.isNotEmpty() },
            )
        }

        fun listFromJson(array: JSONArray?): List<Track> =
            if (array == null) emptyList() else (0 until array.length()).mapNotNull { fromJson(array.optJSONObject(it)) }

        fun listToJson(tracks: List<Track>): JSONArray = JSONArray().apply { tracks.forEach { put(it.toJson()) } }
    }
}

fun List<Track>.uniqued(): List<Track> {
    val seen = HashSet<String>()
    return filter { seen.add(it.videoId) }
}

/** An entry of YouTube Music other than a plain song row: an artist, an album, a playlist, or a song card. */
data class MusicItem(
    val kind: Kind,
    /** The page's browse ID ("UC…" artists, "MPREb_…" albums, "VL…" playlists), or the video ID. */
    val id: String,
    val title: String,
    val subtitle: String,
    val artworkUrl: String?,
    val track: Track? = null,
) {
    enum class Kind { ARTIST, ALBUM, PLAYLIST, PODCAST, SONG }
}

data class MusicShelf(val title: String, val items: List<MusicItem>)

data class ArtistPage(
    val name: String,
    val artworkUrl: String?,
    val about: String?,
    val topSongs: List<Track>,
    /** The playlist with all of the artist's songs. */
    val songsPlaylistId: String?,
    val shelves: List<MusicShelf>,
)

data class AlbumPage(
    val id: String,
    val title: String,
    val artist: String,
    val artistId: String?,
    /** "Album • 2013". */
    val kindAndYear: String,
    /** "4 brani • 23 minuti". */
    val details: String,
    val artworkUrl: String?,
    val tracks: List<Track>,
)

data class PlaylistPage(val id: String, val title: String, val subtitle: String, val artworkUrl: String?, val tracks: List<Track>)

/** Artists, albums and playlists found by a search, with YouTube Music's top result when it is one of them. */
data class CatalogResults(
    val top: MusicItem? = null,
    val artists: List<MusicItem> = emptyList(),
    val albums: List<MusicItem> = emptyList(),
    val playlists: List<MusicItem> = emptyList(),
) {
    val isEmpty: Boolean get() = top == null && artists.isEmpty() && albums.isEmpty() && playlists.isEmpty()
}

/** A playlist made in the app. */
data class Playlist(val id: String = UUID.randomUUID().toString(), val name: String, val tracks: List<Track> = emptyList()) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("id", id)
        put("name", name)
        put("tracks", Track.listToJson(tracks))
    }

    companion object {
        fun fromJson(json: JSONObject?): Playlist? {
            json ?: return null
            return Playlist(
                id = json.optString("id").ifEmpty { UUID.randomUUID().toString() },
                name = json.optString("name"),
                tracks = Track.listFromJson(json.optJSONArray("tracks")),
            )
        }
    }
}

/** Lower case, without accents: "Beyoncé" and "beyonce" compare equal. */
fun folded(text: String): String =
    Normalizer.normalize(text, Normalizer.Form.NFD).replace(Regex("\\p{M}+"), "").lowercase().trim()

/** Only the letters and digits, folded: "AC/DC" and "ac dc" are both "acdc". */
fun nameKey(text: String): String = folded(text).filter { it.isLetterOrDigit() }

fun formatDuration(seconds: Double?): String {
    val total = (seconds ?: return "").toLong().coerceAtLeast(0)
    val h = total / 3600
    val m = (total % 3600) / 60
    val s = total % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
}
