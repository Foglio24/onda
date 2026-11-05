package com.onda.seaglass.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Radio
import androidx.compose.material.icons.rounded.Shuffle
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import com.onda.seaglass.core.tr
import com.onda.seaglass.data.InnerTube
import com.onda.seaglass.data.Library
import com.onda.seaglass.model.AlbumPage
import com.onda.seaglass.model.ArtistPage
import com.onda.seaglass.model.MusicItem
import com.onda.seaglass.model.PlaylistPage
import com.onda.seaglass.model.Track
import com.onda.seaglass.playback.PlayerController
import kotlinx.coroutines.launch

sealed interface Load<out T> {
    data object Loading : Load<Nothing>
    data class Done<T>(val value: T) : Load<T>
    data class Failed(val message: String) : Load<Nothing>
}

/** Loads a page once per [key], with a way to try again. */
@Composable
fun <T> rememberLoad(key: Any, load: suspend () -> T): Pair<Load<T>, () -> Unit> {
    var attempt by remember { mutableIntStateOf(0) }
    var state by remember(key) { mutableStateOf<Load<T>>(Load.Loading) }
    LaunchedEffect(key, attempt) {
        state = Load.Loading
        state = runCatching { load() }.fold({ Load.Done(it) }, { Load.Failed(it.message ?: tr("errore sconosciuto")) })
    }
    return state to { attempt++ }
}

@Composable
private fun <T> PageContent(load: Load<T>, retry: () -> Unit, unavailable: String, content: LazyListScope.(T) -> Unit) {
    val top = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    Box(Modifier.fillMaxSize()) {
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = LocalBottomPadding.current)) {
            when (load) {
                is Load.Loading -> item { Spacer(Modifier.height(top + 120.dp)); Loading() }
                is Load.Failed -> item { Spacer(Modifier.height(top + 80.dp)); Message(unavailable, load.message, action = tr("Riprova"), onAction = retry) }
                is Load.Done -> content(load.value)
            }
        }
        GlassBackButton(Modifier.padding(top = top + 8.dp, start = 12.dp))
    }
}

/** A glass pill button ("Riproduci", "Casuale"). */
@Composable
fun PillButton(title: String, icon: ImageVector, modifier: Modifier = Modifier, filled: Boolean = false, onClick: () -> Unit) {
    val accent = LocalAccent.current
    val content: @Composable () -> Unit = {
        Row(
            Modifier.fillMaxSize().clickable(onClick = onClick).padding(horizontal = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.Center,
        ) {
            Icon(icon, null, tint = if (filled) Color.White else accent, modifier = Modifier.size(22.dp))
            Spacer(Modifier.size(8.dp))
            Text(title, fontWeight = FontWeight.SemiBold, color = if (filled) Color.White else accent, maxLines = 1)
        }
    }
    if (filled) {
        Box(modifier.height(48.dp).clip(RoundedCornerShape(24.dp)).background(accent)) { content() }
    } else {
        GlassSurface(modifier.height(48.dp), corner = 24.dp) { content() }
    }
}

@Composable
private fun PlayButtons(tracks: List<Track>) {
    Row(Modifier.padding(horizontal = 16.dp, vertical = 12.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        PillButton(tr("Riproduci"), Icons.Rounded.PlayArrow, Modifier.weight(1f), filled = true) { PlayerController.play(tracks) }
        PillButton(tr("Casuale"), Icons.Rounded.Shuffle, Modifier.weight(1f)) { PlayerController.play(tracks, shuffle = true) }
    }
}

/** A centred header: artwork, title and the lines below it (albums and playlists). */
@Composable
private fun CenteredHeader(artwork: String?, title: String, lines: List<String>, onLineClick: ((Int) -> Unit)? = null) {
    val top = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    Column(
        Modifier.fillMaxWidth().padding(top = top + 56.dp, start = 24.dp, end = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Artwork(artwork, Modifier.widthIn(max = 260.dp).fillMaxWidth(0.68f).aspectRatio(1f), RoundedCornerShape(14.dp))
        Spacer(Modifier.height(18.dp))
        Text(title, style = MaterialTheme.typography.headlineSmall, textAlign = TextAlign.Center)
        lines.forEachIndexed { index, line ->
            if (line.isEmpty()) return@forEachIndexed
            val clickable = onLineClick != null && index == 0
            Text(
                line,
                color = if (clickable) LocalAccent.current else Secondary,
                fontSize = if (index == 0) 17.sp else 14.sp,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(top = 4.dp).then(if (clickable) Modifier.clickable { onLineClick?.invoke(index) } else Modifier),
            )
        }
    }
}

@Composable
fun ArtistScreen(id: String) {
    val app = LocalApp.current
    val (load, retry) = rememberLoad(id) { InnerTube.artist(id) }
    var showAll by remember { mutableStateOf(false) }
    PageContent<ArtistPage>(load, retry, tr("Artista non disponibile")) { page ->
        item {
            Box(Modifier.fillMaxWidth().aspectRatio(1.1f)) {
                AsyncImage(page.artworkUrl, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                Box(
                    Modifier.fillMaxSize().background(
                        Brush.verticalGradient(0.4f to Color.Transparent, 1f to Background),
                    ),
                )
                Text(
                    page.name, style = MaterialTheme.typography.displaySmall, maxLines = 2, overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.align(Alignment.BottomStart).padding(horizontal = 16.dp, vertical = 8.dp),
                )
            }
        }
        item {
            Row(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                PillButton(tr("Riproduci"), Icons.Rounded.PlayArrow, Modifier.weight(1f), filled = true) {
                    PlayerController.play(page.topSongs)
                }
                PillButton(tr("Radio dell'artista"), Icons.Rounded.Radio, Modifier.weight(1f)) {
                    page.topSongs.firstOrNull()?.let(PlayerController::playRadio)
                }
            }
        }
        if (page.topSongs.isNotEmpty()) {
            item {
                SectionHeader(
                    tr("Brani più ascoltati"),
                    action = page.songsPlaylistId?.let { tr("Tutti i brani") },
                ) { page.songsPlaylistId?.let { app.open("playlist/$it") } }
            }
            val songs = if (showAll) page.topSongs else page.topSongs.take(5)
            itemsIndexed(songs, key = { _, track -> track.videoId }) { index, track ->
                TrackRow(track, onClick = { PlayerController.play(page.topSongs, index) })
            }
        }
        page.shelves.forEach { shelf ->
            val items = shelf.items.filter { it.kind != MusicItem.Kind.PODCAST }
            if (items.isNotEmpty()) item(key = "shelf" + shelf.title) {
                ItemShelf(shelf.title, items, cardWidth = if (items.all { it.kind == MusicItem.Kind.ARTIST }) 120.dp else 150.dp)
            }
        }
        page.about?.takeIf { it.isNotBlank() }?.let { about ->
            item {
                Column(Modifier.padding(16.dp)) {
                    Text(tr("Informazioni"), style = SectionTitle)
                    Spacer(Modifier.height(8.dp))
                    var expanded by remember { mutableStateOf(false) }
                    Text(
                        about, color = Secondary, fontSize = 15.sp, maxLines = if (expanded) Int.MAX_VALUE else 6,
                        overflow = TextOverflow.Ellipsis, modifier = Modifier.clickable { expanded = !expanded },
                    )
                }
            }
        }
    }
}

@Composable
fun AlbumScreen(id: String) {
    val app = LocalApp.current
    val (load, retry) = rememberLoad(id) { InnerTube.album(id) }
    PageContent<AlbumPage>(load, retry, tr("Album non disponibile")) { album ->
        item {
            CenteredHeader(album.artworkUrl, album.title, listOf(album.artist, album.kindAndYear, album.details)) {
                album.artistId?.let { app.open("artist/$it") }
            }
        }
        item { PlayButtons(album.tracks) }
        itemsIndexed(album.tracks, key = { _, track -> track.videoId }) { index, track ->
            TrackRow(track, onClick = { PlayerController.play(album.tracks, index) }, number = index + 1, showArtwork = false)
        }
    }
}

@Composable
fun PlaylistScreen(id: String) {
    val app = LocalApp.current
    val scope = rememberCoroutineScope()
    val (load, retry) = rememberLoad(id) { InnerTube.playlist(id) }
    PageContent<PlaylistPage>(load, retry, tr("Playlist non disponibile")) { page ->
        item { CenteredHeader(page.artworkUrl, page.title, listOf(page.subtitle, tr("%lld brani", page.tracks.size))) }
        item { PlayButtons(page.tracks) }
        item {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center) {
                androidx.compose.material3.TextButton(onClick = {
                    scope.launch {
                        Library.createPlaylist(page.title, page.tracks)
                        app.toast(tr("Salvato"))
                    }
                }) { Text(tr("Salva come playlist"), color = LocalAccent.current) }
            }
        }
        itemsIndexed(page.tracks, key = { index, track -> "$index" + track.videoId }) { index, track ->
            TrackRow(track, onClick = { PlayerController.play(page.tracks, index) })
        }
    }
}
