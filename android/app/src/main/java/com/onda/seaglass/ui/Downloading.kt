package com.onda.seaglass.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.DownloadDone
import androidx.compose.material.icons.rounded.Downloading
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.onda.seaglass.core.tr
import com.onda.seaglass.data.Downloads
import com.onda.seaglass.model.Track

/** A small mark beside a song: downloaded, or the progress of its download. */
@Composable
fun DownloadBadge(track: Track, modifier: Modifier = Modifier) {
    val items by Downloads.items.collectAsStateWithLifecycle()
    val item = items[track.videoId] ?: return
    val accent = LocalAccent.current
    Box(modifier.size(18.dp), contentAlignment = Alignment.Center) {
        when {
            item.isComplete -> Icon(Icons.Rounded.DownloadDone, tr("Scaricato"), tint = accent, modifier = Modifier.size(16.dp))
            item.isActive -> CircularProgressIndicator(
                progress = { item.percent / 100f }, color = accent, strokeWidth = 2.dp, modifier = Modifier.size(14.dp),
            )
        }
    }
}

/**
 * "Scarica tutta la playlist" for a page of songs: then its progress (a tap stops it), or that the
 * whole page is on the phone.
 */
@Composable
fun DownloadAllButton(tracks: List<Track>) {
    if (tracks.isEmpty()) return
    val items by Downloads.items.collectAsStateWithLifecycle()
    val done = tracks.count { items[it.videoId]?.isComplete == true }
    val active = tracks.count { items[it.videoId]?.isActive == true }
    val (title, icon) = when {
        done == tracks.size -> tr("Playlist scaricata") to Icons.Rounded.DownloadDone
        active > 0 -> tr("Download %lld/%lld · tocca per fermare", done, tracks.size) to Icons.Rounded.Downloading
        done > 0 -> tr("Scarica i restanti %lld", tracks.size - done) to Icons.Rounded.Download
        else -> tr("Scarica tutta la playlist") to Icons.Rounded.Download
    }
    PillButton(title, icon, Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(bottom = 8.dp)) {
        when {
            done == tracks.size -> Unit
            active > 0 -> Downloads.cancel(tracks)
            else -> Downloads.download(tracks)
        }
    }
}
