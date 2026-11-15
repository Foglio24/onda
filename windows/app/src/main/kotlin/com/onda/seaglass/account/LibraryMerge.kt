package com.onda.seaglass.account

import com.onda.seaglass.model.Playlist
import com.onda.seaglass.model.Track
import org.json.JSONArray
import org.json.JSONObject

/** What the account keeps of the library, in the iPhone app's format (LibrarySync.swift). */
data class LibrarySnapshot(
    val liked: List<Track> = emptyList(),
    val playlists: List<Playlist> = emptyList(),
    val history: List<Track> = emptyList(),
    /** The iPhone's listening preferences: Windows passes them through untouched (null: none here). */
    val preferences: JSONObject? = null,
) {
    val isEmpty: Boolean get() = liked.isEmpty() && playlists.isEmpty() && history.isEmpty()

    fun toJson(): JSONObject = JSONObject().apply {
        put("liked", JSONArray(liked.map(::trackJson)))
        put("playlists", JSONArray(playlists.map { playlist ->
            JSONObject().put("id", playlist.id.lowercase()).put("title", playlist.name).put("tracks", JSONArray(playlist.tracks.map(::trackJson)))
        }))
        put("history", JSONArray(history.map(::trackJson)))
        preferences?.let { put("preferences", it) }
    }

    /** Same content (preferences compared as JSON). */
    fun sameAs(other: LibrarySnapshot): Boolean = toJson().similar(other.toJson())

    companion object {
        fun fromJson(json: JSONObject?): LibrarySnapshot {
            json ?: return LibrarySnapshot()
            fun tracks(name: String) = json.optJSONArray(name)?.let { array -> (0 until array.length()).mapNotNull { trackFrom(array.optJSONObject(it)) } } ?: emptyList()
            val playlists = json.optJSONArray("playlists")?.let { array ->
                (0 until array.length()).mapNotNull { i ->
                    val item = array.optJSONObject(i) ?: return@mapNotNull null
                    val id = item.optString("id").takeIf { it.isNotEmpty() } ?: return@mapNotNull null
                    val tracks = item.optJSONArray("tracks")?.let { list -> (0 until list.length()).mapNotNull { trackFrom(list.optJSONObject(it)) } } ?: emptyList()
                    Playlist(id = id.lowercase(), name = item.optString("title").ifBlank { "Playlist" }, tracks = tracks)
                }
            } ?: emptyList()
            return LibrarySnapshot(tracks("liked"), playlists, tracks("history"), json.optJSONObject("preferences"))
        }

        /** A song as the iPhone app encodes it: `artist` joined, `primaryArtist` first. */
        fun trackJson(track: Track): JSONObject = JSONObject().apply {
            put("id", track.videoId)
            put("videoId", track.videoId)
            put("title", track.title)
            put("artist", track.artists.filter { it.isNotBlank() }.joinToString(", ").ifEmpty { track.artist })
            put("primaryArtist", track.primaryArtist)
            track.album?.let { put("album", it) }
            track.duration?.let { put("duration", it) }
            track.artworkUrl?.let { put("artworkURL", it) }
            track.artistId?.let { put("artistID", it) }
            track.albumId?.let { put("albumID", it) }
        }

        fun trackFrom(json: JSONObject?): Track? {
            json ?: return null
            // Songs only known from Last.fm (no video yet) can't play here: left on the account as they are.
            val videoId = json.optString("videoId").takeIf { Regex("^[A-Za-z0-9_-]{11}$").matches(it) } ?: return null
            val primary = json.optString("primaryArtist")
            val all = json.optString("artist")
            val artists = when {
                primary.isNotEmpty() && all.startsWith(primary) ->
                    listOf(primary) + all.removePrefix(primary).split(", ").map { it.trim() }.filter { it.isNotEmpty() }
                all.isNotEmpty() -> all.split(", ")
                else -> listOf(primary).filter { it.isNotEmpty() }
            }
            return Track(
                videoId = videoId,
                title = json.optString("title"),
                artists = artists,
                album = json.optString("album").takeIf { it.isNotEmpty() },
                duration = json.optDouble("duration").takeIf { !it.isNaN() },
                artworkUrl = json.optString("artworkURL").takeIf { it.startsWith("https://") },
                artistId = json.optString("artistID").takeIf { it.isNotEmpty() },
                albumId = json.optString("albumID").takeIf { it.isNotEmpty() },
            )
        }
    }
}

/**
 * Merges the library on this computer with the account's against what the two last agreed on
 * (the base), as the iPhone app's LibraryMerge: what one side added is added to the other, what
 * one side removed is removed from the other, and when both changed the same list both changes
 * are kept. Nothing here is removed unless it was removed on another device since the base.
 */
object LibraryMerge {
    const val HISTORY_LIMIT = 200

    fun merge(local: LibrarySnapshot, base: LibrarySnapshot?, remote: LibrarySnapshot?): LibrarySnapshot {
        remote ?: return local
        // An account whose library emptied all at once is not taken as the user's deletions.
        val base = if (remote.isEmpty && base?.isEmpty == false) null else base
        return LibrarySnapshot(
            liked = mergeTracks(local.liked, base?.liked, remote.liked, addedFirst = true),
            playlists = mergePlaylists(local.playlists, base?.playlists, remote.playlists, base != null),
            history = mergeTracks(local.history, base?.history, remote.history, addedFirst = true).take(HISTORY_LIMIT),
            preferences = mergePreferences(local.preferences, base?.preferences, remote.preferences),
        )
    }

    private fun key(track: Track) = track.videoId

    fun mergeTracks(local: List<Track>, base: List<Track>?, remote: List<Track>, addedFirst: Boolean): List<Track> {
        if (base == null) {
            // Never synced with this account: everything from both.
            val seen = local.map(::key).toMutableSet()
            return deduplicated(local + remote.filter { seen.add(key(it)) })
        }
        val localKeys = local.map(::key)
        val baseKeys = base.map(::key)
        val remoteKeys = remote.map(::key)
        if (localKeys == baseKeys) return deduplicated(remote)
        if (remoteKeys == baseKeys) return deduplicated(local)
        val inBase = baseKeys.toSet()
        val removedRemotely = inBase - remoteKeys.toSet()
        val kept = local.filter { key(it) !in removedRemotely }
        val present = kept.map(::key).toMutableSet()
        val added = remote.filter { key(it) !in inBase && present.add(key(it)) }
        return deduplicated(if (addedFirst) added + kept else kept + added)
    }

    fun mergePlaylists(local: List<Playlist>, base: List<Playlist>?, remote: List<Playlist>, hasBase: Boolean): List<Playlist> {
        val baseById = (base ?: emptyList()).associateBy { it.id }
        val remoteById = remote.associateBy { it.id }
        val result = ArrayList<Playlist>()
        for (playlist in local) {
            val before = baseById[playlist.id]
            val theirs = remoteById[playlist.id]
            when {
                theirs != null -> result += mergePlaylist(playlist, before, theirs)
                // Deleted on another device: gone here too, unless it changed here since.
                before != null && hasBase -> if (!same(playlist, before)) result += playlist
                else -> result += playlist
            }
        }
        val localIds = local.map { it.id }.toSet()
        val added = ArrayList<Playlist>()
        val addedIds = HashSet<String>()
        for (playlist in remote) {
            if (playlist.id in localIds || !addedIds.add(playlist.id)) continue
            // Deleted here: stays deleted, unless another device changed it since.
            val before = baseById[playlist.id]
            if (before != null && same(playlist, before)) continue
            added += playlist
        }
        return added + result
    }

    private fun mergePlaylist(local: Playlist, base: Playlist?, remote: Playlist): Playlist {
        val name = if (base != null && local.name == base.name) remote.name else local.name
        return local.copy(name = name, tracks = mergeTracks(local.tracks, base?.tracks, remote.tracks, addedFirst = false))
    }

    private fun same(one: Playlist, other: Playlist) = one.name == other.name && one.tracks.map(::key) == other.tracks.map(::key)

    fun mergePreferences(local: JSONObject?, base: JSONObject?, remote: JSONObject?): JSONObject? {
        remote ?: return local
        local ?: return remote
        if (base == null) return JSONObject(remote.toString()).apply { local.keys().forEach { if (!has(it)) put(it, local.get(it)) } }
        val result = JSONObject(remote.toString())
        local.keys().forEach { key ->
            val value = local.get(key)
            if (!base.has(key) || base.get(key).toString() != value.toString() || !result.has(key)) result.put(key, value)
        }
        return result
    }

    private fun deduplicated(tracks: List<Track>): List<Track> {
        val seen = HashSet<String>()
        return tracks.filter { seen.add(key(it)) }
    }

    /** What the service accepts (server/account/src/sync.mjs): songs it would refuse stay on this computer only. */
    fun uploadable(snapshot: LibrarySnapshot): LibrarySnapshot {
        fun ok(track: Track) = Regex("^[A-Za-z0-9_-]{11}$").matches(track.videoId) && track.title.isNotBlank() && track.title.length <= 500 &&
            track.artist.length <= 500 && track.primaryArtist.length <= 255
        fun clean(track: Track) = track.copy(
            album = track.album?.takeIf { it.length <= 500 },
            duration = track.duration?.takeIf { it.isFinite() && it in 0.0..86_400.0 },
            artworkUrl = track.artworkUrl?.takeIf { it.startsWith("https://") && it.length <= 2048 },
            artistId = track.artistId?.takeIf { it.length <= 255 },
            albumId = track.albumId?.takeIf { it.length <= 255 },
        )
        return LibrarySnapshot(
            liked = snapshot.liked.filter(::ok).map(::clean).take(10_000),
            playlists = snapshot.playlists.take(1_000).map { playlist ->
                playlist.copy(name = playlist.name.trim().take(200).ifEmpty { "Playlist" }, tracks = playlist.tracks.filter(::ok).map(::clean).take(10_000))
            },
            history = snapshot.history.filter(::ok).map(::clean).take(HISTORY_LIMIT),
            preferences = snapshot.preferences,
        )
    }
}
