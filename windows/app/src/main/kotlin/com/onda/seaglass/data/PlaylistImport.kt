package com.onda.seaglass.data

import com.onda.seaglass.core.Http
import com.onda.seaglass.core.tr
import com.onda.seaglass.model.Playlist
import com.onda.seaglass.model.Track
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.text.Normalizer
import java.util.concurrent.atomic.AtomicInteger

/**
 * Playlists brought in from elsewhere, as on the iPhone (Premium): a link to a public playlist or
 * album of Spotify, Apple Music, YouTube or YouTube Music, or a file (Spotify's own account data
 * export, or a CSV such as Exportify's) for Spotify playlists longer than the 100 songs its public
 * page shows. Spotify and Apple Music only give titles and artists: each song is then looked up on
 * YouTube Music, four at a time, with the iPhone's rules for what counts as the same song.
 */
object PlaylistImport {
    /** Why a row of the source isn't in the playlist (the iPhone's import report). */
    enum class Issue { NOT_FOUND, SEARCH_FAILED, DUPLICATE, UNAVAILABLE, UNSUPPORTED }

    /** One song of the source: what it said (a title, artists, maybe album and length). */
    data class Row(val title: String, val artists: List<String>, val album: String? = null, val duration: Double? = null, val issue: Issue? = null) {
        val primaryArtist: String get() = artists.firstOrNull { it.isNotBlank() }.orEmpty()
        val label: String get() = listOf(title, artists.filter { it.isNotBlank() }.joinToString(", ")).filter { it.isNotBlank() }.joinToString(" – ")
    }

    /** A playlist read from a page or a file, before its songs are looked up. */
    data class Source(val name: String?, val rows: List<Row>, val mayBeTruncated: Boolean = false, val service: String)

    /** A row and what became of it: the song found, or why not. */
    data class Entry(val row: Row, val match: Track?, val issue: Issue?)

    data class Outcome(val playlist: Playlist, val entries: List<Entry>, val mayBeTruncated: Boolean) {
        val toCheck: List<Entry> get() = entries.filter { it.issue != null }
    }

    class ImportException(message: String) : IOException(message)

    private const val USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"

    // MARK: Links

    sealed interface Link {
        data class YouTube(val id: String) : Link
        data class Spotify(val kind: String, val id: String) : Link
        data class AppleMusic(val url: String) : Link
    }

    /** What a pasted text points at (shared links often come with words around them). */
    fun parseLink(text: String): Link? {
        val trimmed = text.trim()
        val link = Regex("""https?://\S+""").find(trimmed)?.value ?: trimmed
        if (link.startsWith("spotify:")) {
            val parts = link.split(":")
            return if (parts.size >= 3 && parts[1] in listOf("playlist", "album") && parts[2].isNotBlank()) Link.Spotify(parts[1], parts[2]) else null
        }
        val uri = runCatching { java.net.URI(link) }.getOrNull()
        val host = uri?.host?.lowercase()
        if (host == null) return InnerTube.playlistId(trimmed)?.let { Link.YouTube(it) }
        if (host.endsWith("spotify.com")) {
            val parts = uri.path.orEmpty().split("/").filter { it.isNotEmpty() }
            for (kind in listOf("playlist", "album")) {
                val at = parts.indexOf(kind)
                if (at >= 0 && at + 1 < parts.size && parts[at + 1].matches(Regex("[A-Za-z0-9]+"))) return Link.Spotify(kind, parts[at + 1])
            }
            return null
        }
        if (host.endsWith("music.apple.com") || host.endsWith("itunes.apple.com")) return Link.AppleMusic(link)
        if (host.contains("youtube.com") || host.contains("youtu.be")) return InnerTube.playlistId(link)?.let { Link.YouTube(it) }
        // Spotify's short links (spotify.link, spoti.fi) are followed by [resolve].
        if (host.endsWith("spotify.link") || host.endsWith("spoti.fi")) return Link.Spotify("short", link)
        return null
    }

    private suspend fun resolve(link: Link): Link = when {
        link is Link.Spotify && link.kind == "short" -> withContext(Dispatchers.IO) {
            val request = Request.Builder().url(link.id).header("User-Agent", USER_AGENT).build()
            val final = Http.client.newCall(request).execute().use { it.request.url.toString() }
            (parseLink(final) as? Link.Spotify)?.takeIf { it.kind != "short" } ?: throw unsupported()
        }
        else -> link
    }

    private fun unsupported() = ImportException(tr("Link non riconosciuto. Incolla il link di una playlist o di un album di YouTube Music, Spotify o Apple Music."))
    private fun unreadable() = ImportException(tr("Non riesco a leggere la playlist. Controlla che sia pubblica."))

    private suspend fun fetch(url: String): String = withContext(Dispatchers.IO) {
        val request = Request.Builder().url(url).header("User-Agent", USER_AGENT).header("Accept-Language", "it-IT,it;q=0.9,en;q=0.8").build()
        Http.client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) throw unreadable()
            response.body.string()
        }
    }

    /** The JSON inside the first `<script …>` whose attributes contain [marker]. */
    private fun scriptJson(html: String, marker: String): Any? {
        val at = html.indexOf(marker).takeIf { it >= 0 } ?: return null
        val open = html.indexOf('>', at).takeIf { it >= 0 } ?: return null
        val close = html.indexOf("</script>", open).takeIf { it >= 0 } ?: return null
        val text = html.substring(open + 1, close).trim()
        return runCatching { if (text.startsWith("[")) JSONArray(text) else JSONObject(text) }.getOrNull()
    }

    /** Spotify's embed page carries the first 100 songs as JSON, no account needed. */
    fun parseSpotifyEmbed(html: String): Source {
        val json = scriptJson(html, "id=\"__NEXT_DATA__\"") as? JSONObject ?: throw unreadable()
        val entity = json.optJSONObject("props")?.optJSONObject("pageProps")?.optJSONObject("state")
            ?.optJSONObject("data")?.optJSONObject("entity") ?: throw unreadable()
        val items = entity.optJSONArray("trackList") ?: JSONArray()
        val rows = (0 until items.length()).map { index ->
            val item = items.optJSONObject(index)
            val title = item?.optString("title").orEmpty().trim()
            if (item == null || title.isEmpty()) {
                Row(tr("Brano non disponibile %lld", index + 1), emptyList(), issue = Issue.UNAVAILABLE)
            } else {
                // "KAROL G, Judeline" (the separator's space is often a no-break one).
                val artists = item.optString("subtitle").split(",").map { it.replace(' ', ' ').trim() }.filter { it.isNotEmpty() }
                val milliseconds = item.optDouble("duration", Double.NaN)
                Row(title, artists, duration = if (milliseconds.isNaN() || milliseconds <= 0) null else milliseconds / 1000)
            }
        }
        return Source(entity.optString("name").takeIf { it.isNotBlank() }, rows, mayBeTruncated = items.length() >= 100, service = "Spotify")
    }

    /** Apple Music's public page embeds its track list in the "serialized-server-data" script. */
    fun parseAppleMusic(html: String): Source {
        val json = scriptJson(html, "id=\"serialized-server-data\"") ?: throw unreadable()
        val items = ArrayList<JSONObject>()
        fun walk(value: Any?) {
            when (value) {
                is JSONObject -> {
                    if (value.optString("id").startsWith("track-lockup") && value.opt("title") is String) items.add(value)
                    value.keys().forEach { walk(value.opt(it)) }
                }
                is JSONArray -> for (i in 0 until value.length()) walk(value.opt(i))
            }
        }
        walk(json)
        val rows = items.mapNotNull { item ->
            val title = item.optString("title").trim().takeIf { it.isNotEmpty() } ?: return@mapNotNull null
            val artist = item.optString("artistName").takeIf { it.isNotBlank() }
                ?: item.optJSONArray("subtitleLinks")?.optJSONObject(0)?.optString("title").orEmpty()
            val milliseconds = item.optDouble("duration", Double.NaN)
            Row(title, listOf(artist.trim()).filter { it.isNotEmpty() }, duration = if (milliseconds.isNaN() || milliseconds <= 0) null else milliseconds / 1000)
        }
        val name = (scriptJson(html, "application/ld+json") as? JSONObject)?.optString("name")?.takeIf { it.isNotBlank() }
        return Source(name, rows, service = "Apple Music")
    }

    // MARK: Importing

    /** Imports what [text] links to; [progress] gets what's being done ("Ricerca su YouTube Music: 12/80"). */
    suspend fun importLink(text: String, progress: (String) -> Unit): Outcome {
        progress(tr("Lettura della playlist…"))
        return when (val link = resolve(parseLink(text) ?: throw unsupported())) {
            is Link.YouTube -> {
                val page = InnerTube.playlist(link.id)
                if (page.tracks.isEmpty()) throw ImportException(tr("La playlist è vuota."))
                val playlist = Library.createPlaylist(page.title.ifBlank { tr("Playlist importata") }, page.tracks)
                Outcome(playlist, page.tracks.map { Entry(Row(it.title, it.artists, it.album, it.duration), it, null) }, false)
            }
            is Link.Spotify -> importSource(parseSpotifyEmbed(fetch("https://open.spotify.com/embed/${link.kind}/${link.id}")), progress)
            is Link.AppleMusic -> importSource(parseAppleMusic(fetch(link.url)), progress)
        }
    }

    /** Looks [source]'s songs up on YouTube Music and makes the playlist of those found. */
    suspend fun importSource(source: Source, progress: (String) -> Unit): Outcome {
        if (source.rows.isEmpty()) throw ImportException(tr("La playlist è vuota."))
        val done = AtomicInteger()
        progress(tr("Ricerca su YouTube Music: %lld/%lld", 0, source.rows.size))
        val limit = Semaphore(4)
        val matches = coroutineScope {
            source.rows.map { row ->
                async(Dispatchers.IO) {
                    val result = if (row.issue != null) {
                        null to row.issue
                    } else {
                        limit.withPermit {
                            try {
                                val found = bestMatch(row)
                                found to (if (found == null) Issue.NOT_FOUND else null)
                            } catch (e: Exception) {
                                if (e is kotlinx.coroutines.CancellationException) throw e
                                null to Issue.SEARCH_FAILED
                            }
                        }
                    }
                    progress(tr("Ricerca su YouTube Music: %lld/%lld", done.incrementAndGet(), source.rows.size))
                    result
                }
            }.awaitAll()
        }
        // The same recording twice (a song in two versions on Spotify, one on YouTube) is kept once.
        val seen = HashSet<String>()
        val entries = source.rows.mapIndexed { index, row ->
            val (track, issue) = matches[index]
            when {
                track == null -> Entry(row, null, issue ?: Issue.NOT_FOUND)
                !seen.add(track.videoId) -> Entry(row, track, Issue.DUPLICATE)
                else -> Entry(row, track, null)
            }
        }
        val found = entries.filter { it.issue == null }.mapNotNull { it.match }
        val name = source.name ?: tr("Playlist da %@", source.service)
        val playlist = Library.createPlaylist(name, found)
        return Outcome(playlist, entries, source.mayBeTruncated)
    }

    /** The YouTube Music recording of [row], by the artist and the title, then the title and the artist. */
    suspend fun bestMatch(row: Row): Track? {
        val base = Matching.baseTitle(row.title)
        val queries = listOf("${row.primaryArtist} $base".trim(), "${row.title} ${row.primaryArtist}".trim())
            .filter { it.isNotEmpty() }.distinctBy { Matching.key(it) }
        for (query in queries) {
            Matching.best(InnerTube.searchSongs(query), row)?.let { return it }
        }
        return null
    }

    /** Recordings to choose from for a row that wasn't matched, the likeliest first. */
    suspend fun suggestions(row: Row): List<Track> =
        InnerTube.searchSongs("${row.primaryArtist} ${row.title}".trim()).sortedByDescending { Matching.score(it, row) }.take(8)

    /** Adds [track] to the imported [playlistId] where [entry] stood among the songs found. */
    fun resolve(outcome: Outcome, entry: Entry, track: Track): Boolean {
        val playlist = Library.playlist(outcome.playlist.id) ?: return false
        if (playlist.tracks.any { it.videoId == track.videoId }) return false
        val position = outcome.entries.indexOf(entry)
        // After the songs found before it that are still in the playlist.
        val before = outcome.entries.take(maxOf(0, position)).mapNotNull { it.takeIf { e -> e.issue == null }?.match?.videoId }.toSet()
        val at = playlist.tracks.indexOfLast { it.videoId in before } + 1
        Library.insertTrack(track, at, playlist.id)
        return true
    }

    /** The iPhone's rules for "the same song": title and artist agree, versions (live, remix…) too, length close. */
    object Matching {
        fun key(text: String): String =
            Normalizer.normalize(text.lowercase(), Normalizer.Form.NFD).replace(Regex("\\p{M}+"), "").filter { it.isLetterOrDigit() }

        private fun normalized(text: String): String =
            Normalizer.normalize(text.lowercase(), Normalizer.Form.NFD).replace(Regex("\\p{M}+"), "").replace("&", "and").trim()

        /** The title without "(feat. …)", "[Remastered]" or " - Radio Edit". */
        fun baseTitle(title: String): String {
            val cleaned = title.replace(Regex("""\s*[(\[][^)\]]*[)\]]"""), "").replace(Regex("""\s+-\s+.*$"""), "").trim()
            return cleaned.ifEmpty { title }
        }

        private val versions = listOf("live", "remix", "acoustic", "instrumental", "karaoke", "sped up", "slowed", "cover")

        private fun variants(title: String): Set<String> {
            val value = normalized(title)
            return versions.filter { Regex("\\b" + Regex.escape(it) + "\\b").containsMatchIn(value) }.toSet()
        }

        fun best(results: List<Track>, wanted: Row): Track? {
            val wantedArtist = key(wanted.primaryArtist)
            val wantedTitle = key(baseTitle(wanted.title))
            if (wantedArtist.length < 2 || wantedTitle.isEmpty()) return null
            val wantedVariants = variants(wanted.title)
            return results.take(25).filter { candidate ->
                if (candidate.videoId.isBlank() || variants(candidate.title) != wantedVariants) return@filter false
                val a = candidate.duration
                val b = wanted.duration
                if (a != null && b != null && Math.abs(a - b) > maxOf(15.0, b * 0.15)) return@filter false
                val title = key(baseTitle(candidate.title))
                val artist = key(candidate.artists.joinToString(" "))
                val primary = key(candidate.primaryArtist)
                val shorter = minOf(title.length, wantedTitle.length)
                val longer = maxOf(title.length, wantedTitle.length)
                val titleMatches = title == wantedTitle || (shorter >= 4 && shorter.toDouble() / maxOf(1, longer) >= 0.65 &&
                    (title.contains(wantedTitle) || wantedTitle.contains(title)))
                val artistMatches = if (wantedArtist.length < 3) primary == wantedArtist
                else artist.contains(wantedArtist) || (primary.length >= 3 && wantedArtist.contains(primary))
                titleMatches && artistMatches
            }.maxByOrNull { score(it, wanted) }
        }

        fun score(candidate: Track, wanted: Row): Int {
            var score = 0
            val wantedArtist = normalized(wanted.primaryArtist)
            val artists = normalized(candidate.artists.joinToString(", "))
            val main = normalized(candidate.primaryArtist)
            if (wantedArtist.isNotEmpty() && (artists.contains(wantedArtist) || (main.isNotEmpty() && wantedArtist.contains(main)))) score += 3
            val candidateTitle = normalized(baseTitle(candidate.title))
            val wantedTitle = normalized(baseTitle(wanted.title))
            if (candidateTitle == wantedTitle) score += 3
            else if (candidateTitle.isNotEmpty() && wantedTitle.isNotEmpty() && (candidateTitle.contains(wantedTitle) || wantedTitle.contains(candidateTitle))) score += 2
            val a = candidate.duration
            val b = wanted.duration
            if (a != null && b != null) {
                val difference = Math.abs(a - b)
                score += when {
                    difference <= 3 -> 2
                    difference <= 10 -> 1
                    difference > 40 -> -2
                    else -> 0
                }
            }
            return score
        }
    }
}

/**
 * Playlist files, as the iPhone reads them: Spotify's account data export (Playlist1.json, every
 * playlist of the account) or a CSV with a title and an artist column (Exportify's, and most
 * others). Every row is kept, unreadable ones as "unavailable", so the summary can show them.
 */
object PlaylistImportFile {
    class FileException(message: String) : IOException(message)

    fun read(bytes: ByteArray, fileName: String): List<PlaylistImport.Source> {
        var text = String(bytes, Charsets.UTF_8)
        if (text.startsWith("﻿")) text = text.drop(1)
        val trimmed = text.trimStart()
        if (trimmed.startsWith("{")) {
            val root = runCatching { JSONObject(trimmed) }.getOrNull()
            val lists = root?.optJSONArray("playlists") ?: throw unsupported()
            return (0 until lists.length()).mapNotNull { lists.optJSONObject(it) }.map { list ->
                val name = clean(list.optString("name")) ?: tr("Playlist importata")
                val items = list.optJSONArray("items") ?: JSONArray()
                val rows = (0 until items.length()).map { index ->
                    val item = items.optJSONObject(index) ?: JSONObject()
                    val song = item.optJSONObject("track") ?: item.optJSONObject("localTrack")
                    val title = clean(song?.optString("trackName"))
                    val episode = item.optJSONObject("episode")
                    val episodeTitle = clean(episode?.optString("episodeName"))
                    when {
                        song != null && title != null -> PlaylistImport.Row(
                            title, listOfNotNull(clean(song.optString("artistName"))), clean(song.optString("albumName")),
                        )
                        // A podcast episode in a playlist: listed, not looked up (as on the iPhone).
                        episodeTitle != null -> PlaylistImport.Row(
                            episodeTitle, listOfNotNull(clean(episode?.optString("showName"))), issue = PlaylistImport.Issue.UNSUPPORTED,
                        )
                        else -> unavailable(index + 1)
                    }
                }
                PlaylistImport.Source(name, rows, service = "Spotify")
            }
        }
        val records = csv(text).filter { row -> row.any { clean(it) != null } }
        val header = records.firstOrNull() ?: throw unsupported()
        val names = header.map(::key)
        fun index(keys: List<String>) = names.indexOfFirst { it in keys }.takeIf { it >= 0 }
        val title = index(listOf("trackname", "tracktitle", "songname", "songtitle", "title")) ?: throw unsupported()
        val artist = index(listOf("artistnames", "artistname", "artist", "artists")) ?: throw unsupported()
        val album = index(listOf("albumname", "album"))
        val milliseconds = index(listOf("trackdurationms", "durationms"))
        fun field(row: List<String>, at: Int?) = at?.let { row.getOrNull(it) }?.let(::clean)
        val rows = records.drop(1).mapIndexed { index, row ->
            val name = field(row, title) ?: return@mapIndexed unavailable(index + 1)
            // "A, B", "A,B" (Exportify) or "A; B".
            val artists = (field(row, artist) ?: "").split(",", ";").map { it.trim() }.filter { it.isNotEmpty() }
            val duration = field(row, milliseconds)?.toDoubleOrNull()?.takeIf { it > 0 }?.let { it / 1000 }
            PlaylistImport.Row(name, artists, field(row, album), duration)
        }
        val name = fileName.substringAfterLast('/').substringAfterLast('\\').substringBeforeLast('.').ifBlank { tr("Playlist importata") }
        return listOf(PlaylistImport.Source(name, rows, service = "File"))
    }

    private fun unsupported() = FileException(tr("File non riconosciuto. Scegli un file Playlist di Spotify in JSON oppure un CSV con titolo e artista."))

    private fun clean(value: String?): String? = value?.trim()?.takeIf { it.isNotEmpty() }

    private fun key(text: String): String = text.lowercase().filter { it.isLetterOrDigit() }

    private fun unavailable(number: Int) = PlaylistImport.Row(tr("Brano non disponibile %lld", number), emptyList(), issue = PlaylistImport.Issue.UNAVAILABLE)

    /** CSV with commas, CRLF, quoted commas and line breaks, and doubled quotes (RFC 4180). */
    fun csv(text: String): List<List<String>> {
        val records = ArrayList<List<String>>()
        var row = ArrayList<String>()
        val field = StringBuilder()
        var quoted = false
        var atFieldStart = true
        var i = 0
        while (i < text.length) {
            val char = text[i]
            if (quoted) {
                if (char == '"') {
                    if (i + 1 < text.length && text[i + 1] == '"') {
                        field.append('"')
                        i++
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(char)
                }
            } else if (char == '"' && atFieldStart) {
                quoted = true
                atFieldStart = false
            } else if (char == ',') {
                row.add(field.toString())
                field.clear()
                atFieldStart = true
            } else if (char == '\n' || char == '\r') {
                // \r\n counts once.
                if (char == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++
                row.add(field.toString())
                records.add(row)
                row = ArrayList()
                field.clear()
                atFieldStart = true
            } else {
                field.append(char)
                atFieldStart = false
            }
            i++
        }
        if (quoted) throw FileException(tr("Il file CSV non è leggibile. Controlla che sia esportato correttamente."))
        if (row.isNotEmpty() || field.isNotEmpty()) {
            row.add(field.toString())
            records.add(row)
        }
        return records
    }
}
