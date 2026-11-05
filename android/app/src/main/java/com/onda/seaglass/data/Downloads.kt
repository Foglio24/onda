package com.onda.seaglass.data

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.cache.NoOpCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import androidx.media3.exoplayer.offline.Download
import androidx.media3.exoplayer.offline.DownloadManager
import androidx.media3.exoplayer.offline.DownloadRequest
import androidx.media3.exoplayer.offline.DownloadService
import com.onda.seaglass.core.tr
import com.onda.seaglass.model.Track
import com.onda.seaglass.playback.SeaglassDownloadService
import com.onda.seaglass.playback.downloadDataSourceFactory
import com.onda.seaglass.playback.streamUri
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONObject
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/**
 * Songs kept on the phone (Media3's download manager): they play without a connection, from the
 * download quality's rendition. A download survives the app being closed and resumes where it
 * stopped; its notification shows the progress.
 */
@OptIn(UnstableApi::class)
object Downloads {
    data class Item(val track: Track, val state: Int, val percent: Float, val bytes: Long, val started: Long) {
        val isComplete get() = state == Download.STATE_COMPLETED
        val isActive get() = state == Download.STATE_QUEUED || state == Download.STATE_DOWNLOADING || state == Download.STATE_RESTARTING
        val isFailed get() = state == Download.STATE_FAILED
    }

    const val CHANNEL = "downloads"

    lateinit var cache: SimpleCache
        private set
    lateinit var manager: DownloadManager
        private set
    private lateinit var appContext: Context
    private lateinit var loudnessFile: File

    private val _items = MutableStateFlow<Map<String, Item>>(emptyMap())
    /** By video ID. */
    val items: StateFlow<Map<String, Item>> = _items

    /** Read by the player's loading thread, to play a song from the phone. */
    private val completed = ConcurrentHashMap.newKeySet<String>()
    private val loudness = ConcurrentHashMap<String, Double>()
    private val handler = Handler(Looper.getMainLooper())

    fun init(context: Context) {
        appContext = context.applicationContext
        val database = StandaloneDatabaseProvider(appContext)
        cache = SimpleCache(File(appContext.filesDir, "downloads"), NoOpCacheEvictor(), database)
        manager = DownloadManager(appContext, database, cache, downloadDataSourceFactory(), Executors.newFixedThreadPool(2)).apply {
            maxParallelDownloads = 2
            addListener(object : DownloadManager.Listener {
                override fun onDownloadChanged(manager: DownloadManager, download: Download, finalException: Exception?) {
                    if (download.state == Download.STATE_COMPLETED) saveLoudness(download.request.id)
                    refresh()
                }
                override fun onDownloadRemoved(manager: DownloadManager, download: Download) = refresh()
                override fun onInitialized(manager: DownloadManager) = refresh()
            })
        }
        loudnessFile = File(appContext.filesDir, "download-loudness.json")
        runCatching {
            val json = JSONObject(loudnessFile.readText())
            json.keys().forEach { key -> loudness[key] = json.getDouble(key) }
        }
        appContext.getSystemService(NotificationManager::class.java)
            ?.createNotificationChannel(NotificationChannel(CHANNEL, tr("Download"), NotificationManager.IMPORTANCE_LOW))
    }

    /** Re-reads every download; while some run, again every half second for their progress. */
    private fun refresh() {
        val map = LinkedHashMap<String, Item>()
        manager.downloadIndex.getDownloads().use { cursor ->
            while (cursor.moveToNext()) {
                val download = cursor.download
                val track = runCatching { Track.fromJson(JSONObject(String(download.request.data))) }.getOrNull() ?: continue
                map[download.request.id] = Item(
                    track, download.state, download.percentDownloaded.coerceAtLeast(0f), download.bytesDownloaded, download.startTimeMs,
                )
            }
        }
        completed.clear()
        map.values.filter { it.isComplete }.forEach { completed += it.track.videoId }
        _items.value = map
        handler.removeCallbacks(poll)
        if (map.values.any { it.isActive }) handler.postDelayed(poll, 500)
    }

    private val poll = Runnable { refresh() }

    fun isComplete(videoId: String) = videoId in completed

    fun loudness(videoId: String): Double? = loudness[videoId]

    private fun saveLoudness(videoId: String) {
        val value = Streams.loudness(videoId) ?: return
        loudness[videoId] = value
        runCatching { loudnessFile.writeText(JSONObject(loudness as Map<*, *>).toString()) }
    }

    fun download(tracks: List<Track>) {
        for (track in tracks) {
            val existing = _items.value[track.videoId]
            if (existing != null && !existing.isFailed) continue
            val request = DownloadRequest.Builder(track.videoId, streamUri(track.videoId))
                .setCustomCacheKey(track.videoId)
                .setData(track.toJson().toString().toByteArray())
                .build()
            DownloadService.sendAddDownload(appContext, SeaglassDownloadService::class.java, request, false)
        }
    }

    fun remove(track: Track) = DownloadService.sendRemoveDownload(appContext, SeaglassDownloadService::class.java, track.videoId, false)

    fun removeAll() = DownloadService.sendRemoveAllDownloads(appContext, SeaglassDownloadService::class.java, false)

    /** Stops the downloads of [tracks] that haven't finished (the playlist's "tocca per fermare"). */
    fun cancel(tracks: List<Track>) {
        tracks.filter { _items.value[it.videoId]?.isActive == true }.forEach(::remove)
    }

    /** Space taken by the downloaded songs. */
    val bytes: Long get() = runCatching { cache.cacheSpace }.getOrDefault(0)
}
