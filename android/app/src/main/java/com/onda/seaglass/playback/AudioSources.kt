package com.onda.seaglass.playback

import android.app.Notification
import android.app.PendingIntent
import android.content.Intent
import android.net.Uri
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.ResolvingDataSource
import androidx.media3.datasource.TransferListener
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.offline.Download
import androidx.media3.exoplayer.offline.DownloadManager
import androidx.media3.exoplayer.offline.DownloadNotificationHelper
import androidx.media3.exoplayer.offline.DownloadService
import androidx.media3.exoplayer.scheduler.Scheduler
import com.onda.seaglass.MainActivity
import com.onda.seaglass.R
import com.onda.seaglass.core.Http
import com.onda.seaglass.data.AudioQuality
import com.onda.seaglass.data.Downloads
import com.onda.seaglass.data.Prefs
import com.onda.seaglass.data.Streams
import kotlinx.coroutines.runBlocking

/** Songs play from `seaglass://<videoId>`: the link to the audio is looked up only when it's needed. */
fun streamUri(videoId: String): Uri = Uri.parse("seaglass://$videoId")

/** `seaglass://<videoId>` becomes the song's YouTube link at [quality] (on a loading thread), read in 1 MB ranges. */
@OptIn(UnstableApi::class)
private fun youTubeDataSourceFactory(quality: () -> AudioQuality?): DataSource.Factory {
    val http = OkHttpDataSource.Factory(Http.client).setUserAgent(Streams.USER_AGENT)
    val chunked = DataSource.Factory { ChunkedDataSource(http.createDataSource()) }
    return ResolvingDataSource.Factory(chunked) { spec: DataSpec ->
        val videoId = spec.uri.host
        if (spec.uri.scheme != "seaglass" || videoId == null) {
            spec
        } else {
            val chosen = quality()
            val resolved = runBlocking { if (chosen == null) Streams.resolve(videoId) else Streams.resolve(videoId, chosen) }
            spec.withUri(Uri.parse(resolved.rendition.url))
        }
    }
}

/** What downloads read: the song at the download quality. */
@OptIn(UnstableApi::class)
fun downloadDataSourceFactory(): DataSource.Factory = youTubeDataSourceFactory {
    Prefs.downloadQuality.value.let { if (it == AudioQuality.MEDIUM) AudioQuality.LOW else it }
}

/**
 * Where the player reads audio: a downloaded song from the phone, any other from YouTube at the
 * streaming quality. A song still downloading streams, so two renditions never mix.
 */
@OptIn(UnstableApi::class)
fun audioDataSourceFactory(): DataSource.Factory {
    val streaming = youTubeDataSourceFactory { null }
    val offline by lazy {
        CacheDataSource.Factory()
            .setCache(Downloads.cache)
            .setCacheKeyFactory { spec -> spec.key ?: spec.uri.host ?: spec.uri.toString() }
            .setCacheWriteDataSinkFactory(null)
            .setUpstreamDataSourceFactory(streaming)
    }
    return DataSource.Factory { SwitchingDataSource({ offline.createDataSource() }, streaming.createDataSource()) }
}

/** Opens each song from the phone when it's downloaded, otherwise from YouTube. */
@OptIn(UnstableApi::class)
private class SwitchingDataSource(makeOffline: () -> DataSource, private val streaming: DataSource) : DataSource {
    private val offline by lazy(makeOffline)
    private val listeners = mutableListOf<TransferListener>()
    private var current: DataSource? = null

    override fun addTransferListener(transferListener: TransferListener) {
        listeners += transferListener
        streaming.addTransferListener(transferListener)
    }

    override fun open(dataSpec: DataSpec): Long {
        val videoId = dataSpec.uri.host
        val downloaded = dataSpec.uri.scheme == "seaglass" && videoId != null && Downloads.isComplete(videoId)
        val source = if (downloaded) offline.also { o -> listeners.forEach(o::addTransferListener); listeners.clear() } else streaming
        current = source
        return source.open(dataSpec)
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int = current!!.read(buffer, offset, length)

    override fun getUri(): Uri? = current?.uri

    override fun getResponseHeaders(): Map<String, List<String>> = current?.responseHeaders ?: emptyMap()

    override fun close() {
        current?.close()
        current = null
    }
}

/** Runs the downloads in the background, with their progress in a notification. */
@OptIn(UnstableApi::class)
class SeaglassDownloadService : DownloadService(
    NOTIFICATION_ID, DEFAULT_FOREGROUND_NOTIFICATION_UPDATE_INTERVAL, Downloads.CHANNEL, 0, 0,
) {
    private val helper by lazy { DownloadNotificationHelper(this, Downloads.CHANNEL) }

    override fun getDownloadManager(): DownloadManager = Downloads.manager

    override fun getScheduler(): Scheduler? = null

    override fun getForegroundNotification(downloads: MutableList<Download>, notMetRequirements: Int): Notification {
        val open = PendingIntent.getActivity(
            this, 1, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return helper.buildProgressNotification(this, R.drawable.ic_download, open, null, downloads, notMetRequirements)
    }

    private companion object {
        const val NOTIFICATION_ID = 2
    }
}
