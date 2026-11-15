package com.onda.seaglass.data

import com.onda.seaglass.audio.StreamSource
import com.onda.seaglass.core.Http
import com.onda.seaglass.core.Paths
import com.onda.seaglass.model.Track
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.concurrent.ConcurrentHashMap

/**
 * Songs kept on this computer (%LOCALAPPDATA%\Seaglass\Downloads): they play without a connection.
 * Each is its own file named by its video ID, beside an index of what they are; two download at
 * once, in the ranged pieces the player streams with. Only the user deletes them.
 */
object Downloads {
    enum class State { QUEUED, DOWNLOADING, DONE, FAILED }

    data class Item(val track: Track, val state: State, val progress: Float = 0f, val bytes: Long = 0, val file: String? = null) {
        val isComplete get() = state == State.DONE
        val isActive get() = state == State.QUEUED || state == State.DOWNLOADING
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val slots = Semaphore(2)
    private val jobs = ConcurrentHashMap<String, Job>()
    private val loudness = ConcurrentHashMap<String, Double>()
    private val indexFile by lazy { File(Paths.downloads, "index.json") }

    private val _items = MutableStateFlow<Map<String, Item>>(emptyMap())
    /** By video ID, newest first. */
    val items: StateFlow<Map<String, Item>> = _items

    fun init() {
        val array = runCatching { JSONArray(indexFile.readText()) }.getOrNull() ?: JSONArray()
        val map = LinkedHashMap<String, Item>()
        for (i in 0 until array.length()) {
            val entry = array.optJSONObject(i) ?: continue
            val track = Track.fromJson(entry.optJSONObject("track")) ?: continue
            val name = entry.optString("file").takeIf { it.isNotEmpty() }
            val file = name?.let { File(Paths.downloads, it) }
            // A download cut off by closing the app starts again; one whose file is gone is forgotten.
            val state = when {
                file != null && file.isFile -> State.DONE
                entry.optString("state") == "done" -> continue
                else -> State.QUEUED
            }
            map[track.videoId] = Item(track, state, if (state == State.DONE) 1f else 0f, file?.length() ?: 0, name)
            entry.optDouble("loudness").takeIf { !it.isNaN() }?.let { loudness[track.videoId] = it }
        }
        _items.value = map
        map.values.filter { it.state == State.QUEUED }.forEach { start(it.track) }
    }

    fun isComplete(videoId: String) = _items.value[videoId]?.isComplete == true
    fun file(videoId: String): File? = _items.value[videoId]?.takeIf { it.isComplete }?.file?.let { File(Paths.downloads, it) }
    fun loudness(videoId: String): Double? = loudness[videoId]

    fun download(tracks: List<Track>) {
        for (track in tracks) {
            if (!Paths.isVideoId(track.videoId)) continue
            val existing = _items.value[track.videoId]
            if (existing != null && existing.state != State.FAILED) continue
            put(Item(track, State.QUEUED))
            start(track)
        }
        save()
    }

    private fun start(track: Track) {
        jobs[track.videoId] = scope.launch {
            slots.withPermit {
                try {
                    fetch(track)
                } catch (e: Exception) {
                    ensureActive()
                    update(track.videoId) { it.copy(state = State.FAILED) }
                    save()
                } finally {
                    jobs.remove(track.videoId)
                }
            }
        }
    }

    private suspend fun fetch(track: Track) {
        update(track.videoId) { it.copy(state = State.DOWNLOADING, progress = 0f) }
        val resolved = Streams.resolve(track.videoId, Streams.AudioQuality.MAX)
        val rendition = resolved.rendition
        if (rendition.size <= 0) throw IOException("Unknown size")
        val name = track.videoId + if (rendition.isOpus) ".webm" else ".m4a"
        val partial = File(Paths.downloads, "$name.part")
        partial.outputStream().use { out ->
            var from = 0L
            while (from < rendition.size) {
                kotlinx.coroutines.currentCoroutineContext().ensureActive()
                val to = minOf(rendition.size, from + StreamSource.CHUNK) - 1
                val bytes = Http.client.newCall(Request.Builder().url("${rendition.url}&range=$from-$to").build()).execute().use {
                    if (!it.isSuccessful) throw IOException("HTTP ${it.code}")
                    it.body.bytes()
                }
                out.write(bytes)
                from += bytes.size
                if (bytes.isEmpty()) throw IOException("Empty piece")
                update(track.videoId) { it.copy(progress = (from.toDouble() / rendition.size).toFloat(), bytes = from) }
            }
        }
        Files.move(partial.toPath(), File(Paths.downloads, name).toPath(), StandardCopyOption.REPLACE_EXISTING)
        resolved.loudness?.let { loudness[track.videoId] = it }
        update(track.videoId) { it.copy(state = State.DONE, progress = 1f, file = name, bytes = rendition.size) }
        save()
    }

    /** Stops the downloads of [tracks] that haven't finished. */
    fun cancel(tracks: List<Track>) {
        for (track in tracks) {
            val item = _items.value[track.videoId] ?: continue
            if (item.isActive) remove(track)
        }
    }

    /** Deletes the song's file: only ever asked by the user. */
    fun remove(track: Track) {
        jobs.remove(track.videoId)?.cancel()
        val item = _items.value[track.videoId] ?: return
        item.file?.let { File(Paths.downloads, it).delete() }
        File(Paths.downloads, track.videoId + ".webm.part").delete()
        File(Paths.downloads, track.videoId + ".m4a.part").delete()
        _items.value = _items.value - track.videoId
        save()
    }

    val bytes: Long get() = _items.value.values.filter { it.isComplete }.sumOf { it.bytes }

    private fun put(item: Item) {
        _items.value = mapOf(item.track.videoId to item) + (_items.value - item.track.videoId)
    }

    @Synchronized
    private fun update(videoId: String, change: (Item) -> Item) {
        val item = _items.value[videoId] ?: return
        _items.value = _items.value + (videoId to change(item))
    }

    @Synchronized
    private fun save() {
        val array = JSONArray()
        for (item in _items.value.values) {
            array.put(JSONObject().apply {
                put("track", item.track.toJson())
                put("state", if (item.isComplete) "done" else "queued")
                item.file?.let { put("file", it) }
                loudness[item.track.videoId]?.let { put("loudness", it) }
            })
        }
        val temporary = File(Paths.downloads, "index.json.tmp")
        temporary.writeText(array.toString())
        Files.move(temporary.toPath(), indexFile.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
    }
}

/**
 * Songs streamed recently, whole, in %LOCALAPPDATA%\Seaglass\Cache\Songs: playing one again (or
 * seeking far in it) needs no network. Kept to [LIMIT] bytes, the oldest played going first.
 */
object SongCache {
    private const val LIMIT = 600L * 1024 * 1024
    private val directory by lazy { File(Paths.cache, "Songs").apply { mkdirs() } }

    fun file(videoId: String): File? {
        if (!Paths.isVideoId(videoId)) return null
        return directory.listFiles { file -> file.name.startsWith("$videoId.") && !file.name.endsWith(".tmp") }
            ?.firstOrNull()?.also { it.setLastModified(System.currentTimeMillis()) }
    }

    fun store(videoId: String, extension: String, bytes: ByteArray) {
        if (!Paths.isVideoId(videoId)) return
        runCatching {
            val temporary = File(directory, "$videoId.$extension.tmp")
            temporary.writeBytes(bytes)
            Files.move(temporary.toPath(), File(directory, "$videoId.$extension").toPath(), StandardCopyOption.REPLACE_EXISTING)
            trim()
        }
    }

    private fun trim() {
        val files = directory.listFiles()?.sortedByDescending { it.lastModified() } ?: return
        var total = 0L
        for (file in files) {
            total += file.length()
            if (total > LIMIT) file.delete()
        }
    }

    fun clear() {
        directory.listFiles()?.forEach { it.delete() }
    }

    val bytes: Long get() = directory.listFiles()?.sumOf { it.length() } ?: 0
}
