package com.onda.seaglass.data

import com.onda.seaglass.core.Http
import com.onda.seaglass.core.HttpException
import com.onda.seaglass.core.J
import com.onda.seaglass.core.L10n
import com.onda.seaglass.core.jsonOf
import com.onda.seaglass.core.tr
import com.onda.seaglass.model.AlbumPage
import com.onda.seaglass.model.ArtistPage
import com.onda.seaglass.model.CatalogResults
import com.onda.seaglass.model.MusicItem
import com.onda.seaglass.model.MusicShelf
import com.onda.seaglass.model.PlaylistPage
import com.onda.seaglass.model.Track
import com.onda.seaglass.model.folded
import com.onda.seaglass.model.uniqued
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.IOException

class NotFoundException : IOException(tr("Nessun brano trovato."))

/**
 * Minimal client for the YouTube Music web API (the "WEB_REMIX" InnerTube client), ported from the
 * iPhone app. Used for search, pages and radios; the audio itself comes from [Streams].
 */
object InnerTube {
    private const val BASE = "https://music.youtube.com/youtubei/v1/"
    private const val SONGS_FILTER = "EgWKAQIIAWoMEA4QChADEAQQCRAF"
    private const val ARTISTS_FILTER = "EgWKAQIgAWoMEA4QChADEAQQCRAF"
    private const val PLAYLISTS_FILTER = "EgWKAQIoAWoMEA4QChADEAQQCRAF"
    private const val USER_AGENT =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    private val kindLabels = setOf("Song", "Brano", "Canzone", "Video")

    private fun context(): JSONObject = jsonOf(
        "client" to jsonOf(
            "clientName" to "WEB_REMIX",
            "clientVersion" to "1.20250310.01.00",
            "hl" to L10n.locale.language.ifEmpty { "en" },
            "gl" to L10n.locale.country.ifEmpty { "US" },
        ),
    )

    suspend fun post(endpoint: String, body: JSONObject): JSONObject {
        body.put("context", context())
        val request = Request.Builder()
            .url("$BASE$endpoint?prettyPrint=false")
            .header("Origin", "https://music.youtube.com")
            .header("Referer", "https://music.youtube.com/")
            .header("User-Agent", USER_AGENT)
            .post(body.toString().toRequestBody("application/json".toMediaType()))
            .build()
        val text = try {
            Http.text(request)
        } catch (e: HttpException) {
            throw IOException(tr("YouTube Music non ha risposto correttamente (%lld).", e.status))
        }
        return JSONObject(text)
    }

    // MARK: Songs

    suspend fun searchSongs(query: String): List<Track> {
        val json = post("search", jsonOf("query" to query, "params" to SONGS_FILTER))
        return J.findAll("musicResponsiveListItemRenderer", json.opt("contents")).mapNotNull(::parseListItem).uniqued()
    }

    /** The radio YouTube Music builds when you start a song: the song itself followed by similar ones. */
    suspend fun radio(videoId: String): List<Track> {
        val json = post(
            "next",
            jsonOf(
                "videoId" to videoId,
                "playlistId" to "RDAMVM$videoId",
                "isAudioOnly" to true,
                "enablePersistentPlaylistPanel" to true,
            ),
        )
        return J.findAll("playlistPanelVideoRenderer", json.opt("contents")).mapNotNull(::parsePanelItem).uniqued()
    }

    /** Songs of a public YouTube / YouTube Music playlist, following up to 10 pages of results. */
    suspend fun playlist(playlistId: String): PlaylistPage {
        val id = playlistId.removePrefix("VL")
        val firstPage = post("browse", jsonOf("browseId" to "VL$id"))
        val header = listOf(
            "musicResponsiveHeaderRenderer", "musicDetailHeaderRenderer",
            "musicEditablePlaylistDetailHeaderRenderer", "musicImmersiveHeaderRenderer",
        ).firstNotNullOfOrNull { J.first(it, firstPage) }
        val title = J.text(J.value(header, "title")) ?: ""
        val subtitle = listOfNotNull(J.text(J.value(header, "subtitle")), J.text(J.value(header, "secondSubtitle")))
            .joinToString(" • ")
        val artwork = thumbnail(J.value(header, "thumbnail"))

        var items = J.first("musicPlaylistShelfRenderer", firstPage.opt("contents"))?.let { J.array(it, "contents") }
            ?: emptyList()
        if (items.isEmpty()) {
            items = J.first("musicShelfRenderer", firstPage.opt("contents"))?.let { J.array(it, "contents") } ?: emptyList()
        }
        val tracks = mutableListOf<Track>()
        for (pageNumber in 0 until 10) {
            tracks += items.mapNotNull { J.obj(it, "musicResponsiveListItemRenderer") }.mapNotNull(::parseListItem)
            val token = items.firstNotNullOfOrNull {
                J.string(it, "continuationItemRenderer", "continuationEndpoint", "continuationCommand", "token")
            } ?: break
            val page = post("browse", jsonOf("continuation" to token))
            items = J.first("appendContinuationItemsAction", page)?.let { J.array(it, "continuationItems") } ?: emptyList()
            if (items.isEmpty()) break
        }
        if (tracks.isEmpty()) throw NotFoundException()
        return PlaylistPage(id, title, subtitle, artwork ?: tracks.first().artworkUrl, tracks.uniqued())
    }

    /** The playlist ID from a link such as `https://music.youtube.com/playlist?list=PL…`. */
    fun playlistId(link: String): String? = Regex("[?&]list=([A-Za-z0-9_-]+)").find(link)?.groupValues?.get(1)

    // MARK: Catalog

    /** The unfiltered search, which ranks artists and albums well; songs come from [searchSongs]. */
    suspend fun searchCatalog(query: String): CatalogResults {
        val json = post("search", jsonOf("query" to query))
        val top = J.first("musicCardShelfRenderer", json.opt("contents"))?.let(::cardItem)
        val seen = HashSet<String>().apply { top?.let { add(it.id) } }
        val artists = mutableListOf<MusicItem>()
        val albums = mutableListOf<MusicItem>()
        val playlists = mutableListOf<MusicItem>()
        for (row in J.findAll("musicResponsiveListItemRenderer", json.opt("contents"))) {
            val item = listItem(row) ?: continue
            if (!seen.add(item.id)) continue
            when (item.kind) {
                MusicItem.Kind.ARTIST -> artists += item
                MusicItem.Kind.ALBUM -> albums += item
                MusicItem.Kind.PLAYLIST -> playlists += item
                else -> Unit
            }
        }
        // Albums by the searched artist first, then albums and EPs before singles.
        val wanted = folded(query)
        val sortedAlbums = albums.withIndex().sortedWith(
            compareByDescending<IndexedValue<MusicItem>> { albumScore(it.value, wanted) }.thenBy { it.index },
        ).map { it.value }
        return CatalogResults(top, artists, sortedAlbums, playlists)
    }

    suspend fun searchPlaylists(query: String): List<MusicItem> {
        val json = post("search", jsonOf("query" to query, "params" to PLAYLISTS_FILTER))
        val seen = HashSet<String>()
        return J.findAll("musicResponsiveListItemRenderer", json.opt("contents")).mapNotNull(::listItem)
            .filter { it.kind == MusicItem.Kind.PLAYLIST && seen.add(it.id) }
    }

    private fun albumScore(album: MusicItem, query: String): Int {
        val parts = album.subtitle.split(" • ")
        var score = 0
        if (query.isNotEmpty() && parts.drop(1).any { folded(it).contains(query) }) score += 2
        if (parts.firstOrNull()?.let(::folded) in setOf("album", "ep")) score += 1
        return score
    }

    /** The YouTube Music page of an artist known only by name. */
    suspend fun artistId(name: String): String? {
        val json = post("search", jsonOf("query" to name, "params" to ARTISTS_FILTER))
        val artists = J.findAll("musicResponsiveListItemRenderer", json.opt("contents")).mapNotNull(::listItem)
            .filter { it.kind == MusicItem.Kind.ARTIST }
        return (artists.firstOrNull { it.title.equals(name, ignoreCase = true) } ?: artists.firstOrNull())?.id
    }

    suspend fun artist(browseId: String): ArtistPage {
        val json = post("browse", jsonOf("browseId" to browseId))
        val header = listOf("musicImmersiveHeaderRenderer", "musicVisualHeaderRenderer", "musicResponsiveHeaderRenderer")
            .firstNotNullOfOrNull { J.first(it, json.opt("header")) } ?: throw NotFoundException()
        var topSongs = emptyList<Track>()
        var songsPlaylistId: String? = null
        val shelves = mutableListOf<MusicShelf>()
        val sections = J.first("sectionListRenderer", json.opt("contents"))?.let { J.array(it, "contents") } ?: emptyList()
        for (section in sections) {
            val shelf = J.obj(section, "musicShelfRenderer")
            val carousel = J.obj(section, "musicCarouselShelfRenderer")
            if (shelf != null && topSongs.isEmpty()) {
                topSongs = J.objects(shelf, "contents").mapNotNull { J.obj(it, "musicResponsiveListItemRenderer") }
                    .mapNotNull(::parseListItem)
                songsPlaylistId = J.string(shelf, "title", "runs", 0, "navigationEndpoint", "browseEndpoint", "browseId")
                    ?: J.string(shelf, "bottomEndpoint", "browseEndpoint", "browseId")
            } else if (carousel != null) {
                val title = J.text(J.value(carousel, "header", "musicCarouselShelfBasicHeaderRenderer", "title")).orEmpty()
                val items = J.objects(carousel, "contents").mapNotNull { J.obj(it, "musicTwoRowItemRenderer") }
                    .mapNotNull(::twoRowItem)
                if (title.isNotEmpty() && items.isNotEmpty()) shelves += MusicShelf(title, items)
            }
        }
        return ArtistPage(
            name = J.text(header.opt("title")).orEmpty(),
            artworkUrl = thumbnail(header.opt("thumbnail")),
            about = J.text(header.opt("description")),
            topSongs = topSongs,
            songsPlaylistId = songsPlaylistId,
            shelves = shelves,
        )
    }

    suspend fun album(browseId: String): AlbumPage {
        val json = post("browse", jsonOf("browseId" to browseId))
        val header = J.first("musicResponsiveHeaderRenderer", json) ?: throw NotFoundException()
        val title = J.text(header.opt("title")).orEmpty()
        val artist = J.text(header.opt("straplineTextOne")).orEmpty()
        val artistId = J.string(header, "straplineTextOne", "runs", 0, "navigationEndpoint", "browseEndpoint", "browseId")
        val artwork = thumbnail(header.opt("thumbnail"))
        val rows = J.first("musicShelfRenderer", json.opt("contents"))?.let { J.objects(it, "contents") } ?: emptyList()
        val tracks = rows.mapNotNull { J.obj(it, "musicResponsiveListItemRenderer") }.mapNotNull { row ->
            val columns = J.objects(row, "flexColumns").mapNotNull { J.obj(it, "musicResponsiveListItemFlexColumnRenderer") }
            val name = J.text(J.value(columns.firstOrNull(), "text"))?.takeIf { it.isNotEmpty() } ?: return@mapNotNull null
            val videoId = J.string(row, "playlistItemData", "videoId") ?: return@mapNotNull null
            // Only the second column names artists (often empty: the album's artist); the third is play counts.
            val byline = parseByline(J.array(columns.getOrNull(1), "text", "runs"))
            val length = J.string(row, "fixedColumns", 0, "musicResponsiveListItemFixedColumnRenderer", "text", "runs", 0, "text")
                ?.let(::parseDuration)
            Track(
                videoId = videoId, title = name, artists = byline.artists.ifEmpty { listOf(artist) },
                album = title, duration = length, artworkUrl = artwork,
                artistId = byline.artistId ?: artistId, albumId = browseId,
            )
        }
        if (tracks.isEmpty()) throw NotFoundException()
        return AlbumPage(
            id = browseId, title = title, artist = artist, artistId = artistId,
            kindAndYear = J.text(header.opt("subtitle")).orEmpty(),
            details = J.text(header.opt("secondSubtitle")).orEmpty(),
            artworkUrl = artwork, tracks = tracks,
        )
    }

    // MARK: Parsing

    data class Byline(
        val artists: MutableList<String> = mutableListOf(),
        var album: String? = null,
        var duration: Double? = null,
        var artistId: String? = null,
        var albumId: String? = null,
    )

    /** A row of search results. */
    fun parseListItem(item: JSONObject): Track? {
        val columns = J.objects(item, "flexColumns").mapNotNull { J.obj(it, "musicResponsiveListItemFlexColumnRenderer") }
        val titleRun = J.value(columns.firstOrNull(), "text", "runs", 0) ?: return null
        val title = J.string(titleRun, "text") ?: return null
        val videoId = J.string(item, "playlistItemData", "videoId")
            ?: J.string(titleRun, "navigationEndpoint", "watchEndpoint", "videoId") ?: return null
        val byline = parseByline(columns.drop(1).flatMap { J.array(it, "text", "runs") })
        if (byline.duration == null) {
            byline.duration = J.string(item, "fixedColumns", 0, "musicResponsiveListItemFixedColumnRenderer", "text", "runs", 0, "text")
                ?.let(::parseDuration)
        }
        return Track(
            videoId = videoId, title = title, artists = byline.artists, album = byline.album,
            duration = byline.duration,
            artworkUrl = lastThumbnail(J.value(item, "thumbnail", "musicThumbnailRenderer", "thumbnail", "thumbnails")),
            artistId = byline.artistId, albumId = byline.albumId,
        )
    }

    /** A row of the "up next" panel returned by the `next` endpoint. */
    private fun parsePanelItem(item: JSONObject): Track? {
        val videoId = J.string(item, "videoId") ?: return null
        val title = J.string(item, "title", "runs", 0, "text") ?: return null
        val byline = parseByline(J.array(item, "longBylineText", "runs"))
        if (byline.artists.isEmpty()) J.string(item, "shortBylineText", "runs", 0, "text")?.let { byline.artists += it }
        val length = J.string(item, "lengthText", "runs", 0, "text")?.let(::parseDuration)
        return Track(
            videoId = videoId, title = title, artists = byline.artists, album = byline.album,
            duration = length ?: byline.duration,
            artworkUrl = lastThumbnail(J.value(item, "thumbnail", "thumbnails")),
            artistId = byline.artistId, albumId = byline.albumId,
        )
    }

    /** Bylines look like "Artist • Album • 3:45": links tell artists and albums apart. */
    fun parseByline(runs: List<Any>): Byline {
        val byline = Byline()
        val plain = mutableListOf<String>()
        for (run in runs) {
            val text = J.string(run, "text") ?: continue
            val pageType = J.string(
                run, "navigationEndpoint", "browseEndpoint", "browseEndpointContextSupportedConfigs",
                "browseEndpointContextMusicConfig", "pageType",
            ).orEmpty()
            val browseId = J.string(run, "navigationEndpoint", "browseEndpoint", "browseId")
            when (pageType) {
                "MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_USER_CHANNEL" -> {
                    byline.artists += text
                    if (byline.artistId == null && pageType == "MUSIC_PAGE_TYPE_ARTIST") byline.artistId = browseId
                }
                "MUSIC_PAGE_TYPE_ALBUM" -> {
                    byline.album = text
                    byline.albumId = browseId
                }
                else -> {
                    val trimmed = text.trim()
                    val duration = parseDuration(trimmed)
                    if (duration != null) byline.duration = duration
                    else if (trimmed.isNotEmpty() && trimmed !in setOf("•", "&", ",")) plain += trimmed
                }
            }
        }
        // Some artists (e.g. "Various Artists") have no link: the first plain run is the artist.
        if (byline.artists.isEmpty()) plain.firstOrNull { it !in kindLabels }?.let { byline.artists += it }
        return byline
    }

    fun lastThumbnail(thumbnails: Any?): String? = J.array(thumbnails).lastOrNull()?.let { J.string(it, "url") }

    private fun thumbnail(value: Any?): String? =
        lastThumbnail(J.value(J.first("musicThumbnailRenderer", value), "thumbnail", "thumbnails"))

    fun parseDuration(text: String): Double? {
        val parts = text.split(":")
        if (parts.size !in 2..3) return null
        var total = 0.0
        for (part in parts) total = total * 60 + (part.toDoubleOrNull() ?: return null)
        return total
    }

    private fun kind(browseEndpoint: JSONObject): MusicItem.Kind? =
        when (J.string(browseEndpoint, "browseEndpointContextSupportedConfigs", "browseEndpointContextMusicConfig", "pageType")) {
            "MUSIC_PAGE_TYPE_ARTIST" -> MusicItem.Kind.ARTIST
            "MUSIC_PAGE_TYPE_ALBUM" -> MusicItem.Kind.ALBUM
            "MUSIC_PAGE_TYPE_PLAYLIST" -> MusicItem.Kind.PLAYLIST
            "MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE" -> MusicItem.Kind.PODCAST
            else -> null
        }

    /** A search row that opens a page (artist, album, playlist). Song rows give null. */
    private fun listItem(row: JSONObject): MusicItem? {
        val endpoint = J.obj(row, "navigationEndpoint", "browseEndpoint") ?: return null
        val browseId = J.string(endpoint, "browseId") ?: return null
        val kind = kind(endpoint) ?: return null
        val columns = J.objects(row, "flexColumns").mapNotNull { J.obj(it, "musicResponsiveListItemFlexColumnRenderer") }
        val title = J.text(J.value(columns.firstOrNull(), "text"))?.takeIf { it.isNotEmpty() } ?: return null
        var parts = columns.drop(1).mapNotNull { J.text(J.value(it, "text")) }.joinToString(" • ").split(" • ")
        // "Artista • 67,8 Mln ascoltatori mensili": the section already says it's an artist.
        if (kind == MusicItem.Kind.ARTIST && parts.size > 1) parts = parts.drop(1)
        return MusicItem(
            kind, browseId, title, parts.joinToString(" • "),
            lastThumbnail(J.value(row, "thumbnail", "musicThumbnailRenderer", "thumbnail", "thumbnails")),
        )
    }

    /** The search's top result card, when it is an artist, album or playlist. */
    private fun cardItem(card: JSONObject): MusicItem? {
        val endpoint = J.obj(card, "title", "runs", 0, "navigationEndpoint", "browseEndpoint") ?: return null
        val browseId = J.string(endpoint, "browseId") ?: return null
        val kind = kind(endpoint) ?: return null
        val title = J.text(card.opt("title")) ?: return null
        return MusicItem(
            kind, browseId, title, J.text(card.opt("subtitle")).orEmpty(),
            lastThumbnail(J.value(card, "thumbnail", "musicThumbnailRenderer", "thumbnail", "thumbnails")),
        )
    }

    /** A card of an artist page's carousels: a page to open, or a song or video to play. */
    private fun twoRowItem(item: JSONObject): MusicItem? {
        val title = J.text(item.opt("title"))?.takeIf { it.isNotEmpty() } ?: return null
        val subtitle = J.text(item.opt("subtitle")).orEmpty()
        val artwork = lastThumbnail(J.value(item, "thumbnailRenderer", "musicThumbnailRenderer", "thumbnail", "thumbnails"))
        val endpoint = J.obj(item, "navigationEndpoint", "browseEndpoint")
        if (endpoint != null) {
            val browseId = J.string(endpoint, "browseId")
            val kind = kind(endpoint)
            if (browseId != null && kind != null) return MusicItem(kind, browseId, title, subtitle, artwork)
        }
        val videoId = J.string(item, "navigationEndpoint", "watchEndpoint", "videoId") ?: return null
        val byline = parseByline(J.array(item, "subtitle", "runs"))
        val track = Track(
            videoId = videoId, title = title, artists = byline.artists, album = byline.album,
            duration = byline.duration, artworkUrl = artwork, artistId = byline.artistId, albumId = byline.albumId,
        )
        return MusicItem(MusicItem.Kind.SONG, videoId, title, subtitle, artwork, track)
    }
}
